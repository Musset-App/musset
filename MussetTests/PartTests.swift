import PDFKit
import XCTest
@testable import Musset

/// Parts (I, II, III…): chapters grouped in runs, numbered by order, printed on a page of their own.
@MainActor
final class PartTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("musset-parts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in ["a", "b", "c", "d", "e"] {
            try "# \(name.uppercased())\n\nLe texte de \(name).\n".write(to: root.appendingPathComponent("\(name).md"), atomically: true, encoding: .utf8)
        }
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func session() throws -> BookSession {
        let git = GitService(root: root)
        try git.initRepo()
        let m = BookManifest(title: "T", chapters: ["a", "b", "c", "d", "e"].map { ChapterEntry(id: $0, file: "\($0).md", title: $0.uppercased()) })
        try BookStore(root: root).saveManifest(m)
        _ = try git.commit(paths: ["a.md", "b.md", "c.md", "d.md", "e.md", ".musset"], message: "start")
        return BookSession(root: root, manifest: m)
    }

    private func layout(_ s: BookSession) -> [String] {
        s.manifest.chapters.map { ch in (ch.part.map { s.manifest.numeral(of: $0) } ?? "-") + ch.id }
    }

    func testRomanNumerals() {
        XCTAssertEqual([1, 2, 3, 4, 9, 14, 40].map(BookManifest.roman), ["I", "II", "III", "IV", "IX", "XIV", "XL"])
    }

    func testANewPartTakesTheRestOfWhereItStarts() throws {
        let s = try session()
        let one = try XCTUnwrap(s.newPart(startingAt: "a"))
        XCTAssertEqual(layout(s), ["Ia", "Ib", "Ic", "Id", "Ie"])
        let two = try XCTUnwrap(s.newPart(startingAt: "d", title: "La fuite"))
        XCTAssertEqual(layout(s), ["Ia", "Ib", "Ic", "IId", "IIe"])
        XCTAssertEqual(s.manifest.label(of: try XCTUnwrap(s.manifest.parts?.first { $0.id == two })), "II. La fuite")
        // A part made earlier in the book takes I: numerals follow the book's order.
        s.newPart(startingAt: "b")
        XCTAssertEqual(layout(s), ["Ia", "IIb", "IIc", "IIId", "IIIe"])
        XCTAssertEqual(s.manifest.numeral(of: one), "I")
        XCTAssertEqual(try BookStore(root: root).loadManifest().chapters.compactMap(\.part).count, 5, "saved")
    }

    func testChaptersMoveInAndOutKeepingEachPartInOneRun() throws {
        let s = try session()
        let one = try XCTUnwrap(s.newPart(startingAt: "b"))
        let two = try XCTUnwrap(s.newPart(startingAt: "d"))
        XCTAssertEqual(layout(s), ["-a", "Ib", "Ic", "IId", "IIe"])
        s.movePart(of: "a", to: two)
        XCTAssertEqual(layout(s), ["Ib", "Ic", "IId", "IIe", "IIa"], "at the end of the part")
        s.movePart(of: "b", to: nil)
        XCTAssertEqual(layout(s), ["Ic", "-b", "IId", "IIe", "IIa"], "just after the part it leaves")
        // A drop between rows: the place, and the part of the row above.
        s.dropOnBook([ShelfDrag.chapter("b").wire], at: 4, part: .some(two))
        XCTAssertEqual(layout(s), ["Ic", "IId", "IIe", "IIb", "IIa"])
        s.deletePart(one)
        XCTAssertEqual(layout(s), ["-c", "Id", "Ie", "Ib", "Ia"], "its chapters stay, outside any part; II becomes I")
    }

    func testPartPagesInThePrintedBook() throws {
        let s = try session()
        s.newPart(startingAt: "a")
        s.newPart(startingAt: "c", title: "La fuite")
        s.toggleExport("c")
        let openings = s.manifest.partOpenings
        XCTAssertEqual(openings["a"]?.numeral, "I")
        XCTAssertNil(openings["c"], "not printed")
        XCTAssertEqual(openings["d"]?.numeral, "II", "the part opens on its first printed chapter")
        XCTAssertEqual(openings["d"]?.title, "La fuite")

        let typst = TypstMarkup.document(title: "T", author: "A", contact: nil, lang: "fr",
                                         layout: TypstLayout(style: "blanche", geometry: nil, fontSize: nil, crop: false, numbered: false, titlePage: false),
                                         chapters: [("a", "# A\n\nTexte."), ("d", "# D\n\nTexte.")], markers: false, parts: openings)
        let page = try XCTUnwrap(typst.range(of: #"#part-page("II", "La fuite")"#))
        XCTAssertLessThan(page.lowerBound, try XCTUnwrap(typst.range(of: "= D")).lowerBound)

        let word = WordManuscript.source(s.manifest, store: BookStore(root: root)).text
        XCTAssertTrue(word.contains("::: {custom-style=\"PartNumber\"}\nII\n:::\n\n::: {custom-style=\"PartTitle\"}\nLa fuite\n:::\n\n::: {#"),
                      "before the chapter's bookmark, outside it")
        XCTAssertTrue(BookStore(root: root).concatenatedManuscript(s.manifest, stripComments: true).contains("# II. La fuite {.unnumbered .part}"))
    }

    /// The template itself: Musset's own typst compiles a book with parts.
    func testThePartPageCompiles() async throws {
        let typst = TypstMarkup.document(title: "T", author: "A", contact: nil, lang: "fr",
                                         layout: TypstLayout(style: "blanche", geometry: nil, fontSize: nil, crop: false, numbered: false, titlePage: false),
                                         chapters: [("a", "# A\n\nTexte."), ("b", "# B\n\nTexte.")], markers: false,
                                         parts: ["a": ("I", ""), "b": ("II", "La fuite")])
        let dir = root.appendingPathComponent("typst", isDirectory: true)
        let main = try TypstRunner.prepare(dir: dir, source: typst, bookRoot: root)
        let pdf = dir.appendingPathComponent("out.pdf")
        try await TypstRunner.compile(main: main, output: pdf, bookRoot: root)
        XCTAssertGreaterThan((try FileManager.default.attributesOfItem(atPath: pdf.path)[.size] as? Int) ?? 0, 1000)
    }

    /// Single pages: the same left margin on every page, halfway between inside and outside. Facing: inside on the right of a verso.
    func testSingleAndFacingPages() async throws {
        func leftEdges(facing: Bool) async throws -> [CGFloat] {
            var layout = TypstLayout(style: "blanche", geometry: nil, fontSize: nil, crop: false, numbered: false, titlePage: false)
            layout.facing = facing
            let typst = TypstMarkup.document(title: "T", author: "A", contact: nil, lang: "fr", layout: layout,
                                             chapters: [("a", "# A\n\nTexte."), ("b", "# B\n\nTexte.")], markers: false)
            let dir = root.appendingPathComponent("typst-\(facing)", isDirectory: true)
            let main = try TypstRunner.prepare(dir: dir, source: typst, bookRoot: root)
            let pdf = dir.appendingPathComponent("out.pdf")
            try await TypstRunner.compile(main: main, output: pdf, bookRoot: root)
            let doc = try XCTUnwrap(PDFDocument(url: pdf))
            return doc.findString("Texte.", withOptions: []).compactMap { sel in sel.pages.first.map { sel.bounds(for: $0).minX } }
        }
        let mm = 72 / 25.4
        let indent = 4 * mm  // French indents every paragraph, the first too
        let single = try await leftEdges(facing: false)
        XCTAssertEqual(single.count, 2)
        for x in single { XCTAssertEqual(x, 17 * mm + indent, accuracy: 1.5, "(20 + 14) / 2 mm") }
        let facing = try await leftEdges(facing: true)
        XCTAssertEqual(facing.count, 2)
        XCTAssertEqual(facing[0], 20 * mm + indent, accuracy: 1.5, "a recto: inside on the left")
        XCTAssertEqual(facing[1], 14 * mm + indent, accuracy: 1.5, "a verso: outside on the left")
    }
}
