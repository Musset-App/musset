import CoreGraphics
import Foundation
import Observation

/// The words the reader shows, in the host's language (the app passes its own translations).
public struct PageStrings: Sendable {
    public var highlight = "Highlight"
    public var underline = "Underline"
    public var note = "Note"
    public var suggest = "Suggest"
    public var notePlaceholder = "Your note"
    public var suggestPlaceholder = "What it should say"
    public var add = "Add"
    public var markSelection = "Mark the selection"
    public var previousPage = "Previous page"
    public var nextPage = "Next page"
    public var textSize = "Text size"
    public var night = "Night"
    public var composing = "Composing…"
    /// "Pages 41–42 of 112" / "Page 42 of 112".
    public var pages: @Sendable (_ first: Int, _ last: Int, _ count: Int) -> String = { first, last, count in
        first == last ? "Page \(first) of \(count)" : "Pages \(first)–\(last) of \(count)"
    }
    public init() {}
}

/// How the page is set.
public enum PageFit: String, Hashable, Sendable, CaseIterable {
    /// Pages cut to the window, at the chosen text size: reflows when either changes.
    case reflow
    /// The book's own page (the export's), scaled to fit.
    case print
}

/// Day or night: the paper, the ink, and the desk around the page.
public struct PageTheme: Hashable, Sendable {
    public var paper: UInt32
    public var ink: UInt32
    public var desk: UInt32
    public var isNight: Bool

    public static let day = PageTheme(paper: 0xFFFEFB, ink: 0x1A1A18, desk: 0xECEAE4, isNight: false)
    public static let night = PageTheme(paper: 0x1E1D1B, ink: 0xE4DFD3, desk: 0x121211, isNight: true)
}

/// The state of a reader: the book composed for the current window and text size, the page shown, the marks.
@MainActor @Observable
public final class ReaderModel {
    public var source: BookSource { didSet { if source != oldValue { compose(delay: 0) } } }
    public var marks: [Mark]
    public var theme: PageTheme = .day
    /// The text's size on screen, in points (reflow).
    public var textSize: Double = 17 { didSet { if textSize != oldValue { compose() } } }
    public var fit: PageFit = .reflow { didSet { if fit != oldValue { compose(delay: 0) } } }
    /// An editor may suggest a change; a reader only marks and notes.
    public var canSuggest = true
    public var strings = PageStrings()
    /// Called when the reader marks a selection. The host turns it into an annotation, and a `Mark`.
    public var onAction: ((SelectionAction, TextSelection) -> Void)?
    /// The reader's own ink: the menu offers one Highlight in it, not every ink. Nil: all of them.
    public var ownInk: Ink?
    /// Called when a mark (its lines, its marker or its margin note) is tapped, in place of the note's bubble:
    /// the host opens the mark's conversation.
    public var onOpen: ((Mark) -> Void)?
    /// Called on a double click (a double tap) on the text, with the place under it.
    public var onDoubleTap: ((PageAnchor) -> Void)?

    public private(set) var book: TypesetBook?
    public private(set) var composing = false
    public private(set) var error: String?
    /// The first page shown (of the spread).
    public private(set) var page = 0
    /// Where the reader is, kept across reflows.
    public private(set) var anchor: PageAnchor?
    /// Two pages side by side.
    public private(set) var spread = false
    /// Page thumbnails, filled in after each composition.
    public private(set) var thumbnails: [Int: CGImage] = [:]

    /// The selection being made: page, glyph indices (in the page's glyphs), and its line boxes.
    struct Selection: Equatable {
        var page: Int
        var chapter: Int
        var range: Range<Int>
        var lines: [CGRect]
        var finished = false
    }
    var selection: Selection?
    /// A footnote or margin note open in a bubble: page, where (page points), what.
    struct Bubble: Equatable {
        var page: Int
        var point: CGPoint
        var text: String
        var caption: String?
    }
    var bubble: Bubble?

    private var viewport: CGSize = .zero
    private var composedFor: String?
    private var task: Task<Void, Never>?
    private var thumbTask: Task<Void, Never>?
    /// Base size of the text in Typst points; the page is scaled so it shows at `textSize`.
    static let baseSize = 11.0

    public init(source: BookSource, marks: [Mark] = [], anchor: PageAnchor? = nil) {
        self.source = source
        self.marks = marks
        self.anchor = anchor
    }

    // MARK: Layout

    /// The size given to the pages (the view, without the thumbnails).
    func setViewport(_ size: CGSize) {
        guard size.width > 40, size.height > 40, size != viewport else { return }
        let first = viewport == .zero
        viewport = size
        compose(delay: first ? 0 : 0.25)
    }

    /// The room for one page, in view points.
    var slot: CGSize {
        let w = viewport.width, h = viewport.height
        let wide = w >= 720 && w > h * 1.15
        let pageH = max(100, h - (wide ? 32 : 16))
        if wide {
            let pageW = min((w - 48) / 2, pageH * 0.68)
            return CGSize(width: pageW, height: pageH)
        }
        // A phone: the page is the screen. A narrow window: a book's proportions.
        let pageW = w < 500 ? w - 8 : min(w - 32, pageH * 0.72)
        return CGSize(width: max(100, pageW), height: pageH)
    }

    var wantsSpread: Bool { viewport.width >= 720 && viewport.width > viewport.height * 1.15 }

    /// The source as composed for this window: in reflow, a page the slot's shape at the text size.
    private func composedSource() -> BookSource {
        var s = source
        guard fit == .reflow else { return s }
        let k = textSize / Self.baseSize
        let w = slot.width / k, h = slot.height / k
        s.layout = .points(width: w, height: h, top: h * 0.075, bottom: h * 0.085, inside: w * (wantsSpread ? 0.115 : 0.09),
                           outside: w * (wantsSpread ? 0.085 : 0.09), size: Self.baseSize, facing: wantsSpread)
        return s
    }

    private func key(_ s: BookSource) -> String {
        "\(fit)|\(s.layout)|\(source.chapters.count)|\(source.hashValue)"
    }

    /// Composes again (after a short pause while the window is being resized), keeping the place.
    func compose(delay: Double = 0.25) {
        guard viewport != .zero else { return }
        let s = composedSource()
        let k = key(s)
        guard k != composedFor else { spread = wantsSpread; return }
        task?.cancel()
        task = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard let self, !Task.isCancelled else { return }
            self.composing = true
            let result = await Task.detached(priority: .userInitiated) { Result { try TypesetBook(s) } }.value
            guard !Task.isCancelled else { return }
            self.composing = false
            switch result {
            case .success(let b):
                // The reader's place as it is now (they may have turned pages meanwhile), not the start of the
                // page shown: successive reflows must not drift.
                let keep = self.anchor ?? self.currentAnchor()
                self.book = b
                self.error = nil
                self.composedFor = k
                self.spread = self.wantsSpread
                self.selection = nil
                self.bubble = nil
                self.go(to: keep.map { b.page(for: $0) } ?? 0, keepAnchor: keep)
                self.makeThumbnails()
                TypesetBook.evictCache(maxAge: 10)
            case .failure(let e):
                self.error = e.localizedDescription
            }
        }
    }

    private func currentAnchor() -> PageAnchor? {
        if let book, let a = visiblePages.compactMap({ $0 }).lazy.compactMap({ book.anchor(page: $0) }).first { return a }
        return anchor
    }

    // MARK: Pages

    /// The pages shown: (left, right) in a spread, a single page otherwise.
    public var visiblePages: [Int?] {
        guard let book, book.pageCount > 0 else { return [] }
        let p = min(page, book.pageCount - 1)
        guard spread else { return [p] }
        // Page 1 is a recto, alone on the right; then versos on the left.
        if p == 0 { return [nil, 0] }
        let left = p % 2 == 1 ? p : p - 1
        return [left, left + 1 < book.pageCount ? left + 1 : nil]
    }

    public func go(to target: Int) { go(to: target, keepAnchor: nil) }

    private func go(to target: Int, keepAnchor: PageAnchor?) {
        guard let book, book.pageCount > 0 else { return }
        var p = max(0, min(target, book.pageCount - 1))
        if spread, p > 0, p % 2 == 0 { p -= 1 }
        page = p
        selection = nil
        bubble = nil
        anchor = keepAnchor ?? visiblePages.compactMap { $0 }.lazy.compactMap { book.anchor(page: $0) }.first ?? anchor
    }

    /// Goes to a place in the text.
    public func go(to anchor: PageAnchor) {
        guard let book else { self.anchor = anchor; return }
        go(to: book.page(for: anchor), keepAnchor: anchor)
    }

    public func next() {
        guard let last = visiblePages.compactMap({ $0 }).last else { return }
        go(to: last + 1)
    }

    public func previous() {
        guard let first = visiblePages.compactMap({ $0 }).first, first > 0 else { return }
        go(to: spread ? max(0, first - 2) : first - 1)
    }

    public var pageLabel: String {
        let shown = visiblePages.compactMap { $0 }
        guard let book, let a = shown.first, let b = shown.last else { return "" }
        return strings.pages(a + 1, b + 1, book.pageCount)
    }

    /// Pages holding a mark, with the ink of the first one.
    var markedPages: [Int: Ink] {
        guard let book else { return [:] }
        var out: [Int: Ink] = [:]
        for m in marks {
            let p = book.page(for: PageAnchor(chapter: m.chapter, offset: m.range.lowerBound))
            if out[p] == nil { out[p] = m.ink }
        }
        return out
    }

    private func makeThumbnails() {
        thumbTask?.cancel()
        thumbnails = [:]
        guard let book else { return }
        let theme = theme
        thumbTask = Task { [weak self] in
            for i in 0..<book.pageCount {
                guard !Task.isCancelled else { return }
                let size = book.pageSizes[i]
                let scale = 96 / max(size.height, 1)
                let image = await Task.detached(priority: .utility) { book.render(page: i, scale: scale, paper: theme.paper, ink: theme.ink) }.value
                guard let self, !Task.isCancelled, self.book === book else { return }
                self.thumbnails[i] = image
            }
        }
    }

    /// Redraws the thumbnails in the new theme.
    func themeChanged() { makeThumbnails() }

    // MARK: Selecting and marking

    func select(page: Int, from a: CGPoint, to b: CGPoint) {
        guard let book else { return }
        let glyphs = book.glyphs(page: page)
        guard let i = Self.nearest(glyphs, a), let j = Self.nearest(glyphs, b) else { return }
        let lo = min(i, j), hi = max(i, j)
        let chapter = glyphs[i].chapter
        let picked = glyphs[lo...hi].filter { $0.chapter == chapter && $0.footnote == nil }
        guard let start = picked.map(\.range.lowerBound).min(), let end = picked.map(\.range.upperBound).max(), end > start else { return }
        selection = Selection(page: page, chapter: chapter, range: start..<end, lines: book.lineRects(page: page, chapter: chapter, range: start..<end))
        bubble = nil
    }

    func finishSelection() {
        selection?.finished = true
    }

    func clearSelection() { selection = nil }

    var selectedText: TextSelection? {
        guard let s = selection, let book else { return nil }
        return TextSelection(chapter: book.source.chapters[s.chapter].id, range: s.range,
                             text: book.text(chapter: s.chapter, range: s.range))
    }

    func perform(_ action: SelectionAction) {
        guard let sel = selectedText else { return }
        onAction?(action, sel)
        selection = nil
    }

    /// A tap: a footnote's number opens it, a note's lines open the note; elsewhere it clears.
    func tap(page: Int, at p: CGPoint, notesInMargin: Bool) {
        guard let book else { return }
        if selection != nil { selection = nil; return }
        if bubble != nil { bubble = nil; return }
        let glyphs = book.glyphs(page: page)
        if let g = glyphs.first(where: { $0.footnote != nil && $0.rect.insetBy(dx: -4, dy: -4).contains(p) }), let k = g.footnote,
           book.footnotes.indices.contains(k) {
            bubble = Bubble(page: page, point: CGPoint(x: g.rect.midX, y: g.rect.maxY), text: book.footnotes[k].text)
            return
        }
        if let onOpen {
            if let m = book.placed(marks, page: page).first(where: { $0.lines.contains { $0.insetBy(dx: -2, dy: -2).contains(p) } })?.mark {
                onOpen(m)
            }
            return
        }
        if !notesInMargin {
            for (m, lines) in book.placed(marks.filter { $0.note != nil }, page: page) where lines.contains(where: { $0.insetBy(dx: -2, dy: -2).contains(p) }) {
                bubble = Bubble(page: page, point: CGPoint(x: p.x, y: (lines.first?.maxY ?? p.y)), text: m.note ?? "", caption: m.person)
                return
            }
        }
    }

    func doubleTap(page: Int, at p: CGPoint) {
        guard let onDoubleTap, let book else { return }
        let glyphs = book.glyphs(page: page)
        guard let i = Self.nearest(glyphs, p), book.source.chapters.indices.contains(glyphs[i].chapter) else { return }
        selection = nil
        onDoubleTap(PageAnchor(chapter: book.source.chapters[glyphs[i].chapter].id, offset: glyphs[i].range.lowerBound))
    }

    func openNote(_ m: Mark, page: Int, at p: CGPoint) {
        if let onOpen { onOpen(m); return }
        bubble = Bubble(page: page, point: p, text: m.note ?? "", caption: m.person)
    }

    static func nearest(_ glyphs: [PageGlyph], _ p: CGPoint) -> Int? {
        var best: (Int, CGFloat)?
        for (i, g) in glyphs.enumerated() where g.footnote == nil && g.chapter >= 0 {
            let dx = max(g.rect.minX - p.x, 0, p.x - g.rect.maxX)
            let dy = max(g.rect.minY - p.y, 0, p.y - g.rect.maxY)
            // A line counts more than a column: dragging along a line should not jump to the next one.
            let d = dx + dy * 3
            if d == 0 { return i }
            if best == nil || d < best!.1 { best = (i, d) }
        }
        return best?.0
    }
}
