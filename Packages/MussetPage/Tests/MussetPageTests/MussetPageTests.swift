import XCTest
@testable import MussetPage

/// The repository (template, fonts) and the fixture books, which live in the main checkout and are never modified.
enum Repo {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static var template: String { (try? String(contentsOf: root.appendingPathComponent("Musset/Resources/Typst/musset.typ"), encoding: .utf8)) ?? "" }
    static var fonts: URL { root.appendingPathComponent("Musset/Resources/Fonts") }

    static func fixture(_ book: String) throws -> URL {
        if let env = ProcessInfo.processInfo.environment["MUSSET_FIXTURES"] {
            return URL(fileURLWithPath: env).appendingPathComponent(book)
        }
        var dir = root
        for _ in 0..<6 {
            let u = dir.appendingPathComponent("fixtures/\(book)")
            if FileManager.default.fileExists(atPath: u.path) { return u }
            dir.deleteLastPathComponent()
        }
        throw XCTSkip("fixtures/\(book) is not here")
    }

    /// A fixture book's chapters, in the manifest's order.
    static func chapters(_ book: String) throws -> [BookSource.Chapter] {
        let dir = try fixture(book)
        let data = try Data(contentsOf: dir.appendingPathComponent(".musset/book.json"))
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let list = json["chapters"] as! [[String: Any]]
        return try list.filter { ($0["excludeFromExport"] as? Bool) != true }.map {
            BookSource.Chapter(id: $0["id"] as! String, markdown: try String(contentsOf: dir.appendingPathComponent($0["file"] as! String), encoding: .utf8))
        }
    }

    static func source(_ chapters: [BookSource.Chapter], layout: PageLayout) -> BookSource {
        BookSource(chapters: chapters, template: template, title: "Conatus", author: "Musset", lang: "fr", layout: layout,
                   sceneBreak: "blank", fontDirectories: [fonts], systemFonts: false)
    }
}

final class MussetPageTests: XCTestCase {
    static let print = PageLayout(paper: ("130mm", "200mm"), margins: ["inside": "20mm", "outside": "15mm", "top": "17mm", "bottom": "21mm"],
                                  size: "10.8pt", numbered: false, titlePage: false, facing: true)

    /// What a page's glyphs show, read back from the Markdown.
    func shown(_ book: TypesetBook, page: Int) -> String {
        book.glyphs(page: page).filter { $0.footnote == nil }.map { book.text(chapter: $0.chapter, range: $0.range) }.joined()
    }

    func utf16Range(of phrase: String, in md: String) throws -> Range<Int> {
        let r = try XCTUnwrap((md as NSString).range(of: phrase).toOptional)
        return r.location..<(r.location + r.length)
    }

    /// A highlight on a phrase covers that phrase's words on the page, and the ink under it is really there.
    func testHighlightLandsOnTheWords() throws {
        let chapters = try Array(Repo.chapters("conatus").prefix(4))
        let book = try TypesetBook(Repo.source(chapters, layout: Self.print))
        let nice = try XCTUnwrap(chapters.firstIndex { $0.id == "03_nice" })
        for phrase in ["Ambre Solaire", "Negresco", "sandales méduse"] {
            let range = try utf16Range(of: phrase, in: chapters[nice].markdown)
            let mark = Mark(id: phrase, chapter: "03_nice", range: range, kind: .highlight, ink: .amber)
            let page = book.page(for: PageAnchor(chapter: mark.chapter, offset: range.lowerBound))
            let covered = book.glyphs(page: page).filter { $0.chapter == nice && $0.footnote == nil && $0.range.overlaps(range) }
            // Read back in order, the glyphs under the mark spell the phrase (a hyphen where a word was broken).
            let text = covered.map { book.text(chapter: $0.chapter, range: $0.range) }.joined()
            // (Spaces where a line ends are not drawn, so compare without them.)
            XCTAssertEqual(text.filter { !$0.isWhitespace && $0 != "-" }, phrase.filter { !$0.isWhitespace }, "page \(page + 1)")
            let lines = book.lineRects(page: page, chapter: nice, range: range)
            XCTAssertFalse(lines.isEmpty)
            XCTAssertLessThanOrEqual(lines.count, 2)
            // Under each box there is ink: the box sits on the printed words, not beside them.
            let image = try XCTUnwrap(book.render(page: page, scale: 2))
            for line in lines { XCTAssertGreaterThan(inkCoverage(image, line, scale: 2), 0.08, "\(phrase) on page \(page + 1)") }
            // And the words just outside the phrase are not covered.
            let before = book.glyphs(page: page).filter { $0.chapter == nice && $0.range.upperBound <= range.lowerBound }.last
            if let before { XCTAssertFalse(lines.contains { $0.intersection(before.rect).width > 1 }) }
        }
    }

    /// The share of dark pixels in a box of the page.
    func inkCoverage(_ image: CGImage, _ r: CGRect, scale: CGFloat) -> Double {
        let w = image.width, h = image.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var dark = 0, all = 0
        for y in Int(r.minY * scale)..<min(h, Int(r.maxY * scale)) {
            for x in Int(r.minX * scale)..<min(w, Int(r.maxX * scale)) {
                all += 1
                if px[(y * w + x) * 4] < 128 { dark += 1 }
            }
        }
        return all == 0 ? 0 : Double(dark) / Double(all)
    }

    /// Recomposed on other pages and at other sizes, the book opens on the page holding the same words.
    func testReflowKeepsThePosition() throws {
        let chapters = try Array(Repo.chapters("conatus").prefix(6))
        let first = try TypesetBook(Repo.source(chapters, layout: Self.print))
        for start in [3, first.pageCount / 2, first.pageCount - 2] {
            let anchor = try XCTUnwrap(first.anchor(page: start))
            let c = try XCTUnwrap(first.source.chapterIndex(anchor.chapter))
            for (w, h, size) in [(300.0, 460.0, 11.0), (520.0, 400.0, 14.0), (220.0, 420.0, 9.0)] {
                let layout = PageLayout.points(width: w, height: h, top: 30, bottom: 36, inside: 30, outside: 24, size: size, facing: false)
                let book = try TypesetBook(Repo.source(chapters, layout: layout))
                let page = book.page(for: anchor)
                let here = book.glyphs(page: page).filter { $0.chapter == c && $0.footnote == nil }
                XCTAssertTrue(here.contains { $0.range.contains(anchor.offset) || $0.range.lowerBound == anchor.offset },
                              "\(w)×\(h) at \(size)pt: page \(page + 1) lacks offset \(anchor.offset) of \(anchor.chapter)")
            }
        }
    }

    /// The reader keeps its place when the window changes size and when the text grows.
    @MainActor func testReaderModelKeepsItsPlaceAcrossResizes() async throws {
        let chapters = try Array(Repo.chapters("conatus").prefix(5))
        let model = ReaderModel(source: Repo.source(chapters, layout: PageLayout()))
        model.setViewport(CGSize(width: 1200, height: 800))
        try await waitForBook(model)
        model.go(to: 9)
        let anchor = try XCTUnwrap(model.anchor)
        let c = try XCTUnwrap(model.book?.source.chapterIndex(anchor.chapter))
        func check(_ what: String) throws {
            let book = try XCTUnwrap(model.book)
            let shown = model.visiblePages.compactMap { $0 }.flatMap { book.glyphs(page: $0) }
            XCTAssertTrue(shown.contains { $0.chapter == c && ($0.range.contains(anchor.offset) || $0.range.lowerBound == anchor.offset) }, what)
            XCTAssertEqual(model.anchor, anchor, what)
        }
        XCTAssertTrue(model.spread)
        let before = model.book
        model.setViewport(CGSize(width: 600, height: 900))
        try await waitForBook(model, replacing: before)
        XCTAssertFalse(model.spread)
        try check("narrow window")
        let narrow = model.book
        model.textSize = 22
        try await waitForBook(model, replacing: narrow)
        try check("larger text")
    }

    /// Turning pages while a reflow is on its way: the reflow lands on the page turned to, not the one before.
    @MainActor func testPageTurnDuringReflowIsKept() async throws {
        let chapters = try Array(Repo.chapters("conatus").prefix(5))
        let model = ReaderModel(source: Repo.source(chapters, layout: PageLayout()))
        model.setViewport(CGSize(width: 1200, height: 800))
        try await waitForBook(model)
        let before = model.book
        model.setViewport(CGSize(width: 1000, height: 760))
        model.go(to: 15)
        let anchor = try XCTUnwrap(model.anchor)
        try await waitForBook(model, replacing: before)
        XCTAssertEqual(model.anchor, anchor)
        let book = try XCTUnwrap(model.book)
        let c = try XCTUnwrap(book.source.chapterIndex(anchor.chapter))
        let shown = model.visiblePages.compactMap { $0 }.flatMap { book.glyphs(page: $0) }
        XCTAssertTrue(shown.contains { $0.chapter == c && ($0.range.contains(anchor.offset) || $0.range.lowerBound == anchor.offset) })
    }

    @MainActor func waitForBook(_ model: ReaderModel, replacing old: TypesetBook? = nil) async throws {
        for _ in 0..<300 {
            if let b = model.book, b !== old, !model.composing { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("the book was not composed: \(model.error ?? "")")
    }

    /// Dragging from a word to another selects the text between them, and the menu's action reports it.
    @MainActor func testSelectionReportsTheText() async throws {
        let chapters = try Array(Repo.chapters("conatus").prefix(4))
        let model = ReaderModel(source: Repo.source(chapters, layout: Self.print))
        model.fit = .print
        model.setViewport(CGSize(width: 1200, height: 800))
        try await waitForBook(model)
        let book = try XCTUnwrap(model.book)
        let nice = try XCTUnwrap(book.source.chapterIndex("03_nice"))
        let range = try utf16Range(of: "Ambre Solaire", in: chapters[nice].markdown)
        let page = book.page(for: PageAnchor(chapter: "03_nice", offset: range.lowerBound))
        let glyphs = book.glyphs(page: page).filter { $0.chapter == nice && $0.range.overlaps(range) }
        let a = try XCTUnwrap(glyphs.first?.rect), b = try XCTUnwrap(glyphs.last?.rect)
        model.select(page: page, from: CGPoint(x: a.minX + 1, y: a.midY), to: CGPoint(x: b.maxX - 1, y: b.midY))
        model.finishSelection()
        var got: (SelectionAction, TextSelection)?
        model.onAction = { got = ($0, $1) }
        model.perform(.highlight(.teal))
        XCTAssertEqual(got?.0, .highlight(.teal))
        XCTAssertEqual(got?.1.text, "Ambre Solaire")
        XCTAssertEqual(got?.1.range, range)
        XCTAssertNil(model.selection)
    }

    /// Footnotes: their numbers are found, their text is kept for the bubble.
    func testFootnotes() throws {
        let md = "# Un\n\nIl pleuvait^[Comme toujours à Brest.] sur la ville.\n"
        let book = try TypesetBook(Repo.source([.init(id: "un", markdown: md)], layout: Self.print))
        XCTAssertEqual(book.footnotes.map(\.text), ["Comme toujours à Brest."])
        XCTAssertGreaterThanOrEqual(book.glyphs(page: 0).filter { $0.footnote == 0 }.count, 2)
        XCTAssertTrue(shown(book, page: 0).contains("Il pleuvait sur la ville"))
    }

    /// The hand-drawn wobble is the same at every redraw, and differs from one mark to the next.
    func testSeededJitter() {
        var a = SeededRandom("mark-1"), b = SeededRandom("mark-1"), c = SeededRandom("mark-2")
        let r = CGRect(x: 10, y: 10, width: 200, height: 12)
        XCTAssertEqual(MarkLayer.marker(r, &a).description, MarkLayer.marker(r, &b).description)
        XCTAssertNotEqual(MarkLayer.marker(r, &a).description, MarkLayer.marker(r, &c).description)
    }
}

extension NSRange {
    var toOptional: NSRange? { location == NSNotFound ? nil : self }
}
