import MussetPage
import SwiftUI

/// Reading mode: the chapter or the whole book set as it will be printed (a 120×188 mm book or an A4 page), on the
/// reading engine's pages, as spreads. The book's open conversations are drawn on their passages; selecting marks a
/// new one, tapping a mark opens it, and a double click goes back to writing at that place.
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
    var style = Typesetting.style(UserDefaults.standard.string(forKey: "reviewStyle") ?? "book") {
        didSet { UserDefaults.standard.set(style, forKey: "reviewStyle") }
    }
    /// The pages, once there is something to set.
    private(set) var reader: ReaderModel?
    var error: String?
    /// The chapters' texts as composed: marks are placed in these.
    @ObservationIgnored private(set) var texts: [String: String] = [:]

    var building: Bool { reader?.composing ?? false }

    func build(session: BookSession) {
        session.flushSave()
        let m = session.manifest
        let chapters: [ChapterEntry] = scope == .chapter
            ? [session.selectedChapter].compactMap { $0 }
            : m.chapters.filter { !$0.excludeFromExport }
        guard !chapters.isEmpty else { return }
        guard let template = try? Typesetting.template() else { error = "musset.typ is not in the app."; return }
        let list = m.typesetChapters(chapters.map { (id: $0.id, text: session.editorText(of: $0.id)) }, groups: scope == .book)
        texts = Dictionary(list.map { ($0.id, $0.markdown) }, uniquingKeysWith: { a, _ in a })
        let source = BookSource(chapters: list, template: template, style: style, title: m.title, author: m.author, lang: m.lang,
                                layout: PageLayout(numbered: true, titlePage: false), sceneBreak: m.sceneBreak?.rawValue,
                                pages: scope == .book ? Typesetting.pages(m, coverImage: nil) : SpecialPages(),
                                fontDirectories: Typesetting.fonts(bookRoot: session.root), resourceDirectory: session.root, form: m.typesetForm, text: m.typesetText)
        error = nil
        if let reader {
            reader.source = source
        } else {
            let r = ReaderModel(source: source)
            r.fit = .print
            r.strings = .musset
            reader = r
        }
    }

    /// The open conversations on the pages, where their passages stand now.
    func showConversations(_ session: BookSession) {
        guard let reader else { return }
        let collab = Collab.shared
        let name = { (u: String) in u == collab.username ? L("You") : collab.circle.first { $0.username == u }?.name ?? u }
        let marks = session.talk.threads.filter { !$0.isResolved }.compactMap { t in texts[t.chapter].flatMap { t.pageMark(in: $0, name: name) } }
        if marks != reader.marks { reader.marks = marks }
        reader.ownInk = collab.username.map(Person.ink)
    }
}

struct ReviewView: View {
    let app: AppState
    let session: BookSession
    let model: ReviewModel
    let bridge: EditorBridge
    /// Beside the editor: sets the pages again after a pause in typing and follows the caret.
    var sideBySide = false

    var body: some View {
        VStack(spacing: 0) {
            if let reader = model.reader {
                PageView(model: reader, showsThumbnails: !sideBySide)
            } else {
                Text(L("Nothing to show yet.")).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            bar
        }
        .background(Color(nsColor: .underPageBackgroundColor))
        .task(id: buildKey) {
            // Beside the editor, wait for a pause in typing before setting the pages again.
            if sideBySide && model.reader != nil { try? await Task.sleep(nanoseconds: 900_000_000) }
            guard !Task.isCancelled else { return }
            model.build(session: session)
            wire()
            follow()
        }
        .onChange(of: session.talk.threads) { _, _ in model.showConversations(session) }
        .onChange(of: focusKey) { _, _ in if sideBySide { follow() } }
    }

    /// One bar under the pages: what to typeset, with which template, where you are, and export.
    private var bar: some View {
        HStack(spacing: 10) {
            Segmented(options: ReviewModel.Scope.allCases.map { ($0, $0.label) },
                      selection: Binding(get: { model.scope }, set: { model.scope = $0 }))
                .frame(width: 150).layoutPriority(1)
            PopMenu([PopItem(title: L("Book 120×188 mm"), checked: model.style == "book") { model.style = "book" },
                     PopItem(title: L("A4 page"), checked: model.style == "fullpage") { model.style = "fullpage" }]) {
                (Text(model.style == "book" ? L("Book 120×188 mm") : L("A4 page")) + Text("  ") + Text(Image(systemName: "chevron.down")).font(.ui(9)))
                    .lineLimit(1).fixedSize()
                    .padding(.horizontal, 10).frame(height: 26)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: Radius.row))
                    .overlay(RoundedRectangle(cornerRadius: Radius.row).strokeBorder(Ink.hairline))
            }
            if model.building { ProgressView().controlSize(.small) }
            if let e = model.error ?? model.reader?.error { Text(e).foregroundStyle(Ink.error).lineLimit(2).textSelection(.enabled) }
            Spacer()
            if let reader = model.reader, reader.book != nil {
                Text(reader.pageLabel).monospacedDigit().lineLimit(1).fixedSize()
                Toggle(isOn: Binding(get: { reader.theme.isNight }, set: { reader.theme = $0 ? .night : .day })) { Image(systemName: "moon") }
                    .toggleStyle(.button).buttonStyle(.plain).help(L("Night"))
            }
            Button { app.showExport = true } label: {
                Text(L("Export…")).font(.ui(12, .medium)).lineLimit(1).fixedSize()
                    .foregroundStyle(Color(nsColor: .textBackgroundColor))
                    .padding(.horizontal, 12).frame(height: 26)
                    .background(Color.primary, in: RoundedRectangle(cornerRadius: Radius.row))
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

    private var focusKey: Int { sideBySide ? bridge.selectedRange.location : session.savedSelection }

    /// The pages open where you are writing, and beside the editor stay there.
    private func follow() {
        guard let ch = session.selectedChapterID else { return }
        model.reader?.go(to: PageAnchor(chapter: ch, offset: focusKey))
    }

    /// What the pages ask of the book: a new conversation, an open one, the place to write at.
    private func wire() {
        guard let reader = model.reader else { return }
        model.showConversations(session)
        let shared = Collab.shared.link(session.git) != nil
        reader.onAction = shared ? { [weak session] action, sel in
            guard let session else { return }
            if session.selectedChapterID != sel.chapter { session.open(sel.chapter) }
            let (kind, body) = action.talk
            let me = Collab.shared.username ?? ""
            session.startTalk(on: NSRange(location: sel.range.lowerBound, length: sel.range.count), body: body, mark: kind,
                              color: Person.palette.firstIndex(of: Person.color(me)) ?? 0, tone: nil)
        } : nil
        reader.onOpen = { [weak app, weak session] mark in
            guard let app, let session, let t = session.talk.threads.first(where: { $0.id.uuidString == mark.id }) else { return }
            go(to: t.chapter, NSRange(location: mark.range.lowerBound, length: mark.range.count), app: app, session: session)
            app.inspectorTab = .edits
            app.showInspector = true
        }
        reader.onDoubleTap = { [weak app, weak session] place in
            guard let app, let session else { return }
            go(to: place.chapter, NSRange(location: place.offset, length: 0), app: app, session: session)
        }
    }

    private func go(to chapter: String, _ range: NSRange, app: AppState, session: BookSession) {
        if !sideBySide { app.reviewMode = false }
        if chapter != session.selectedChapterID { session.open(chapter) }
        session.pendingSelection = range
    }
}
