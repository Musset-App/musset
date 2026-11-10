import PDFKit
import SwiftUI

/// Reading mode: the chapter or the whole book typeset as it will be printed (Typst, Blanche or Classique),
/// read as spreads. Double-click a passage to go back to writing at that place.
@MainActor
@Observable
final class ReviewModel {
    enum Scope: String, CaseIterable, Identifiable {
        case chapter, book
        var id: String { rawValue }
        var label: String { self == .chapter ? L("Chapter") : L("Book") }
    }

    var scope = Scope(rawValue: UserDefaults.standard.string(forKey: "reviewScope") ?? "") ?? .chapter {
        didSet { UserDefaults.standard.set(scope.rawValue, forKey: "reviewScope") }
    }
    var style = UserDefaults.standard.string(forKey: "reviewStyle") ?? "blanche" {
        didSet { UserDefaults.standard.set(style, forKey: "reviewStyle") }
    }
    var document: PDFDocument?
    var markers: [TypstRunner.Marker] = []
    var building = false
    var error: String?
    var seconds: Double?
    @ObservationIgnored private var lastKey: String?

    func build(session: BookSession, force: Bool = false) async {
        session.flushSave()
        let chapters: [ChapterEntry] = scope == .chapter
            ? [session.selectedChapter].compactMap { $0 }
            : session.manifest.chapters.filter { !$0.excludeFromExport }
        let texts = chapters.map { (id: $0.id, text: session.editorIsBook($0.id) ? session.text : ParagraphCodec.decode(session.chapterText($0))) }
        let key = "\(scope.rawValue)|\(style)|\(session.manifest.sceneBreak?.rawValue ?? "")|\(String(describing: session.manifest.front))|\(String(describing: session.manifest.partOpenings.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value.numeral)\($0.value.title)" }))|" + PangramClient.sha(texts.map { $0.id + $0.text }.joined())
        guard force || key != lastKey || document == nil else { return }
        let m = session.manifest
        let layout = TypstLayout(style: style, geometry: nil, fontSize: nil, crop: false, numbered: true, titlePage: false)
        let pages = TypstMarkup.specialPages(m, coverImage: nil)
        let source = TypstMarkup.document(title: m.title, author: m.author, contact: nil, lang: m.lang, layout: layout,
                                          chapters: CitationPages.apply(to: texts, root: session.root, lang: m.lang), markers: true, sceneBreak: m.sceneBreak ?? .none,
                                          front: scope == .book ? pages.front : "", back: scope == .book ? pages.back : "",
                                          parts: scope == .book ? m.partOpenings : [:])
        building = true
        error = nil
        let start = Date()
        do {
            try session.store.ensureMussetDir()
            let dir = session.root.appendingPathComponent(".musset/typst/review", isDirectory: true)
            let main = try TypstRunner.prepare(dir: dir, source: source, bookRoot: session.root)
            let pdf = dir.appendingPathComponent("review.pdf")
            async let compiled: Void = TypstRunner.compile(main: main, output: pdf, bookRoot: session.root)
            async let found = TypstRunner.markers(main: main, bookRoot: session.root)
            try await compiled
            markers = try await found
            if let data = try? Data(contentsOf: pdf) { document = PDFDocument(data: data) }
            lastKey = key
            seconds = Date().timeIntervalSince(start)
        } catch {
            self.error = error.localizedDescription
        }
        building = false
    }

    /// The paragraph at a page position (page index from 0, y in points from the top).
    func marker(page: Int, y: Double) -> TypstRunner.Marker? {
        let onPage = markers.filter { $0.page == page + 1 }
        if let m = onPage.last(where: { $0.y <= y + 2 }) { return m }
        if let m = onPage.first { return m }
        return markers.last { $0.page <= page + 1 }
    }

    /// Where a text offset of a chapter landed.
    func position(chapter: String, offset: Int) -> TypstRunner.Marker? {
        markers.last { $0.ch == chapter && $0.off <= offset } ?? markers.first { $0.ch == chapter }
    }
}

struct ReviewView: View {
    let app: AppState
    let session: BookSession
    let model: ReviewModel
    let bridge: EditorBridge
    /// Beside the editor: re-typesets after a pause in typing and follows the caret.
    var sideBySide = false

    var body: some View {
        VStack(spacing: 0) {
            if let doc = model.document {
                ReviewPDF(document: doc, focus: focusPage, onDoubleClick: jump)
            } else {
                VStack(spacing: 10) {
                    if model.building { ProgressView(); Text(L("Typesetting…")).foregroundStyle(.secondary) }
                    else if model.error == nil { Text(L("Nothing to show yet.")).foregroundStyle(.secondary) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            bar
        }
        .background(Color(nsColor: .underPageBackgroundColor))
        .task(id: buildKey) {
            // Beside the editor, wait for a pause in typing before typesetting again.
            if sideBySide && model.document != nil { try? await Task.sleep(nanoseconds: 900_000_000) }
            guard !Task.isCancelled else { return }
            await model.build(session: session)
        }
    }

    /// One bar under the pages: what to typeset, with which template, where you are, and export.
    private var bar: some View {
        HStack(spacing: 10) {
            Segmented(options: ReviewModel.Scope.allCases.map { ($0, $0.label) },
                      selection: Binding(get: { model.scope }, set: { model.scope = $0 }))
                .frame(width: 150).layoutPriority(1)
            PopMenu([PopItem(title: "Blanche", checked: model.style == "blanche") { model.style = "blanche" },
                     PopItem(title: "Classique", checked: model.style == "classique") { model.style = "classique" }]) {
                (Text(model.style == "blanche" ? "Blanche" : "Classique") + Text("  ") + Text(Image(systemName: "chevron.down")).font(.ui(9)))
                    .lineLimit(1).fixedSize()
                    .padding(.horizontal, 10).frame(height: 26)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Ink.hairline))
            }
            if model.building { ProgressView().controlSize(.small) }
            if let e = model.error { Text(e).foregroundStyle(.red).lineLimit(2).textSelection(.enabled) }
            Spacer()
            if let s = model.seconds, !model.building {
                let pages = Text(L("\(model.document?.pageCount ?? 0) pages")).monospacedDigit()
                let time = Text(L("typeset in ") + String(format: "%.1f", s).replacingOccurrences(of: ".", with: UILang.locale.decimalSeparator ?? ".") + " s")
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { pages; time.foregroundStyle(.tertiary) }.fixedSize()
                    pages.fixedSize()
                    EmptyView()
                }
            }
            Button { Task { await model.build(session: session, force: true) } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.plain).foregroundStyle(.secondary).help(L("Typeset again"))
            Button { app.showExport = true } label: {
                Text(L("Export…")).font(.ui(12, .medium)).lineLimit(1).fixedSize()
                    .foregroundStyle(Color(nsColor: .textBackgroundColor))
                    .padding(.horizontal, 12).frame(height: 26)
                    .background(Color.primary, in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            if !sideBySide {
                Button(L("Back to Writing")) { app.reviewMode = false }.keyboardShortcut(.escape, modifiers: []).hidden().frame(width: 0)
            }
        }
        .font(.ui(12)).foregroundStyle(.secondary)
        .padding(.horizontal, 16).frame(height: 44)
        .background(Ink.panel)
        .overlay(alignment: .top) { Divider() }
    }

    private var buildKey: String {
        "\(model.scope.rawValue)|\(model.style)|\(session.selectedChapterID ?? "")" + (sideBySide ? "|\(session.text.hashValue)" : "")
    }

    /// The page holding the caret's paragraph: reading starts, and beside the editor stays, where you are writing.
    private var focusPage: Int? {
        guard let ch = session.selectedChapterID else { return nil }
        let caret = sideBySide ? bridge.selectedRange.location : session.savedSelection
        return model.position(chapter: ch, offset: caret).map { $0.page - 1 }
    }

    private func jump(page: Int, y: Double) {
        guard let m = model.marker(page: page, y: y) else { return }
        if !sideBySide { app.reviewMode = false }
        if m.ch != session.selectedChapterID { session.open(m.ch) }
        session.pendingSelection = NSRange(location: m.off, length: 0)
    }
}

/// PDFKit spread view with double-click → (page, y from top).
struct ReviewPDF: NSViewRepresentable {
    let document: PDFDocument
    let focus: Int?
    let onDoubleClick: (Int, Double) -> Void

    func makeNSView(context: Context) -> ClickablePDFView {
        let v = ClickablePDFView()
        v.displayMode = .singlePageContinuous
        v.displaysAsBook = false
        v.displaysPageBreaks = true
        v.autoScales = false
        v.backgroundColor = .underPageBackgroundColor
        v.onDoubleClick = onDoubleClick
        return v
    }

    func updateNSView(_ v: ClickablePDFView, context: Context) {
        v.onDoubleClick = onDoubleClick
        let c = context.coordinator
        if v.document !== document {
            // Keep the page being read when the document is re-typeset.
            let reading = v.currentPage.flatMap { v.document?.index(for: $0) }
            v.document = document
            v.fitPages(force: true)
            if let reading, c.focus == focus, let page = document.page(at: min(reading, document.pageCount - 1)) { v.go(to: page) }
        }
        if focus != c.focus, let focus, let page = document.page(at: max(0, min(focus, document.pageCount - 1))) {
            c.focus = focus
            if v.currentPage !== page { v.go(to: page) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator {
        var focus: Int?
    }
}

final class ClickablePDFView: PDFView {
    var onDoubleClick: ((Int, Double) -> Void)?
    private var fittedSize: NSSize = .zero

    /// One whole page at a time, never cropped: the largest scale at which a page fits the view.
    static func fit(page: NSSize, in view: NSSize, padding: CGFloat = 24) -> CGFloat {
        let w = view.width - padding * 2, h = view.height - padding * 2
        guard w > 0, h > 0, page.width > 0, page.height > 0 else { return 1 }
        return min(h / page.height, w / page.width)
    }

    func fitPages(force: Bool = false) {
        guard let page = document?.page(at: 0), force || bounds.size != fittedSize else { return }
        fittedSize = bounds.size
        let current = currentPage
        let scale = Self.fit(page: page.bounds(for: .mediaBox).size, in: bounds.size)
        if displayMode != .singlePageContinuous { displayMode = .singlePageContinuous }
        autoScales = false
        if abs(scaleFactor - scale) > 0.001 { scaleFactor = scale }
        if let current { go(to: current) }
    }

    override func layout() {
        super.layout()
        fitPages()
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2, let doc = document {
            let p = convert(event.locationInWindow, from: nil)
            if let page = self.page(for: p, nearest: true) {
                let inPage = convert(p, to: page)
                let height = page.bounds(for: .mediaBox).height
                onDoubleClick?(doc.index(for: page), Double(height - inPage.y))
                return
            }
        }
        super.mouseDown(with: event)
    }
}
