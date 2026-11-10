import XCTest
@testable import Musset

@MainActor
final class VersionFromScratchTests: XCTestCase {
    private func book() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("musset-scratch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "Le premier jet.\n\nUn deuxième paragraphe.\n".write(to: root.appendingPathComponent("01.md"), atomically: true, encoding: .utf8)
        return root
    }

    private func manifest() -> BookManifest {
        BookManifest(title: "T", chapters: [ChapterEntry(id: "01", file: "01.md", title: "Un")])
    }

    func testABlankPageWithTheOldTextBeside() throws {
        let root = try book()
        let session = BookSession(root: root, manifest: manifest())
        session.open("01")
        session.newVersionFromScratch("01")

        let ch = try XCTUnwrap(session.selectedChapter)
        let day = { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; return f.string(from: Date()) }()
        XCTAssertEqual(ch.activeVersion, "\(day)-1")
        XCTAssertEqual(session.text, "")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("01.md"), encoding: .utf8), "")
        XCTAssertEqual(session.reference, "main")
        XCTAssertTrue(session.referenceText.contains("Le premier jet."))

        // A second one the same day takes the next number, the first draft still beside.
        session.newVersionFromScratch("01")
        XCTAssertEqual(session.selectedChapter?.activeVersion, "\(day)-2")
        XCTAssertEqual(session.reference, "\(day)-1")
        session.showBeside("main")

        // The side version comes back with the chapter, after a relaunch.
        session.close()
        let again = BookSession(root: root, manifest: session.manifest)
        again.open("01")
        XCTAssertEqual(again.reference, "main")

        // Making it active closes it: the editor shows it.
        again.activateVersion("main")
        XCTAssertNil(again.reference)
    }

    func testTheCaretIsRememberedAcrossRelaunch() async throws {
        let root = try book()
        let session = BookSession(root: root, manifest: manifest())
        session.open("01")
        session.rememberSelection(7)
        try await Task.sleep(nanoseconds: 1_700_000_000)   // written without close(), as after a forced quit
        let again = BookSession(root: root, manifest: manifest())
        again.open("01")
        XCTAssertEqual(again.savedSelection, 7)
    }
}
