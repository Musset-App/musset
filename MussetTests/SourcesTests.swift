import XCTest
@testable import Musset

/// Sources: highlights kept from PDFs, author-date bibliography, where each source is cited.
@MainActor
final class SourcesTests: XCTestCase {
    func testKeptPassagesAreHighlights() {
        let kept = Highlights.parse("> The pans were raked at four-hour intervals.\n(p. 88)\n\n> A transfer is complete on registration.\n(p. 12)\n\n")
        XCTAssertEqual(kept, [.init(text: "The pans were raked at four-hour intervals.", page: 88),
                              .init(text: "A transfer is complete on registration.", page: 12)])
    }

    func testAuthorsAreInvertedForTheBibliography() {
        XCTAssertEqual(CitationPages.inverted("M. Hartley"), "Hartley, M.")
        XCTAssertEqual(CitationPages.inverted("M. Hartley; R. Abbott"), "Hartley, M., and R. Abbott")
        XCTAssertEqual(CitationPages.inverted("M. Hartley; R. Abbott; E. Nakamura"), "Hartley, M., R. Abbott, and E. Nakamura")
        XCTAssertEqual(CitationPages.inverted("Land Registry"), "Registry, Land")
        XCTAssertEqual(CitationPages.inverted("Hartley, Margaret"), "Hartley, Margaret")
        XCTAssertEqual(CitationPages.inverted(""), "")
        XCTAssertEqual(CitationPages.entry(author: "Hartley, M.", year: "1994", title: "The Salt Coast", publisher: "Harbour Press"),
                       "Hartley, M. 1994. *The Salt Coast*. Harbour Press.")
    }

    func testIsbnIsKept() {
        let m = Reference(title: "The Salt Coast", author: "M. Hartley", year: "1994", isbn: "9780000000002").meta(taken: [])
        XCTAssertEqual(m["isbn"], "9780000000002")
        XCTAssertEqual(m["citekey"], "m1994")
    }

    func testWhereASourceIsCited() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("musset-sources-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try "The pans were raked every four hours [@hartley1994, p. 88]. And again [@hartley1994].".write(to: root.appendingPathComponent("01.md"), atomically: true, encoding: .utf8)
        try "Nothing cited here, except [@morel1998].".write(to: root.appendingPathComponent("02.md"), atomically: true, encoding: .utf8)
        var m = BookManifest(title: "Salt", chapters: [ChapterEntry(id: "01", file: "01.md", title: "One"), ChapterEntry(id: "02", file: "02.md", title: "Two")])
        m.lang = "en"
        try BookStore(root: root).saveManifest(m)
        let s = BookSession(root: root, manifest: m)
        let e = try s.bible.create(title: "The Salt Coast", kind: .reference, folder: BibleStore.documents,
                                   meta: ["citekey": "hartley1994", "author": "M. Hartley", "year": "1994"])
        XCTAssertEqual(References.citeCount(of: e, in: s), 2)
        XCTAssertEqual(References.missing(in: s), ["morel1998"])
        let places = References.places(of: "hartley1994", in: s)
        XCTAssertEqual(places.count, 2)
        XCTAssertTrue(places.allSatisfy { $0.chapter == "01" })
        XCTAssertTrue(places[0].excerpt.contains("raked every four hours"))
        // Counted again only when the text changed.
        s.open("01")
        s.text += " Once more [@hartley1994]."
        XCTAssertEqual(References.citeCount(of: e, in: s), 3)
    }
}
