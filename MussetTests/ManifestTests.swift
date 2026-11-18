import XCTest
@testable import Musset

/// `book.json` is read by one type in both apps: what the Mac app wrote stays readable, and a reader takes what it understands.
final class ManifestTests: XCTestCase {
    /// What the iOS reader's own smaller type used to read: a title, chapters, and little else.
    func testAManifestWithOnlyWhatTheReaderNeededStillReads() throws {
        let json = #"{"title":"Le Sel","chapters":[{"id":"01","file":"01.md","title":"Le port"},{"id":"02","file":"02.md","title":"Nice","excludeFromExport":true}],"sceneBreak":"asterism"}"#
        let m = try BookManifest.forReading(Data(json.utf8))
        XCTAssertEqual(m.title, "Le Sel")
        XCTAssertEqual(m.chapters.map(\.id), ["01", "02"])
        XCTAssertEqual(m.chapters.map(\.excludeFromExport), [false, true])
        XCTAssertEqual(m.chapters[0].activeVersion, "main")
        XCTAssertEqual(m.sceneBreak, .asterism)
        XCTAssertEqual(m.author, "")
        XCTAssertNil(m.parts)
    }

    /// A manifest as the Mac app writes it, with parts, special pages and a layout from the LaTeX days.
    func testAFullManifestReadsTheSameInBothAppsAndWritesBackUnchanged() throws {
        let json = #"""
        {"title":"Le Sel","author":"Jeanne Martin","lang":"fr-FR","contact":"j@example.org","formatVersion":1,
         "chapters":[{"id":"01","file":"01.md","title":"Le port","activeVersion":"main","excludeFromExport":false,"status":"done","part":"P1"}],
         "drafts":[{"id":"09","file":"09.md","title":"Écarté","activeVersion":"main","excludeFromExport":false}],
         "parts":[{"id":"P1","title":"La fuite"}],
         "front":{"dedication":"À Louise","cover":{"style":"typographic","genre":"roman","publisher":"","ground":"#F3EEE2","accent":"#9B2F26","inPDF":true}},
         "shelf":"finished","sceneBreak":"blank",
         "exports":[{"id":"mine","name":"Poche","format":"pdf","template":"blanche","geometry":"paperwidth=110mm,paperheight=178mm,inner=18mm,outer=12mm","numberSections":true,"cropMarks":false,"includeContact":false,"extraArgs":[]}]}
        """#
        let mac = try JSONDecoder().decode(BookManifest.self, from: Data(json.utf8))
        let reader = try BookManifest.forReading(Data(json.utf8))
        XCTAssertEqual(mac, reader)
        XCTAssertEqual(mac.parts?.first?.title, "La fuite")
        XCTAssertEqual(mac.label(of: mac.parts![0]), "I. La fuite")
        XCTAssertEqual(mac.front?.dedication, "À Louise")
        XCTAssertEqual(mac.exports.first?.style, "book")
        XCTAssertEqual(mac.exports.first?.paper, PagePaper(width: "110mm", height: "178mm"))
        XCTAssertEqual(mac.chapters[0].status, .done)
        let again = try JSONDecoder().decode(BookManifest.self, from: JSONEncoder().encode(mac))
        XCTAssertEqual(again, mac)
    }

    /// A setting from a newer Musset: the Mac app, which would save over it, refuses the book; a reader reads on.
    func testAReaderLeavesOutWhatItCannotReadAndTheMacAppRefuses() throws {
        let json = #"{"title":"T","chapters":[{"id":"01","file":"01.md","title":"Un","status":"proofed"}],"sceneBreak":"fleuron","exports":[{"id":"x","name":"X","format":"audiobook"}]}"#
        XCTAssertThrowsError(try JSONDecoder().decode(BookManifest.self, from: Data(json.utf8)))
        let m = try BookManifest.forReading(Data(json.utf8))
        XCTAssertNil(m.sceneBreak)
        XCTAssertNil(m.chapters[0].status)
        XCTAssertEqual(m.exports, [])
        XCTAssertEqual(m.chapters[0].title, "Un")
    }
}
