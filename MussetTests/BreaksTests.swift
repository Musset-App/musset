import XCTest
@testable import Musset

/// Return, again and again: a paragraph, a scene, a chapter; Backspace and ⌘Z step back.
@MainActor
final class BreaksTests: XCTestCase {
    func testReturnOnAnEmptyParagraphMakesAScene() throws {
        // "Il pleuvait.\n|": the caret on the empty paragraph a first Return made.
        let text = "# Un\nIl pleuvait.\n"
        let step = try XCTUnwrap(Breaks.onReturn(text, caret: (text as NSString).length, lang: "fr"))
        XCTAssertEqual(step, .scene(at: (text as NSString).length, marker: "<!-- scene: Scène 2 -->"), "the prose before is scene 1")
    }

    func testTheSceneTitleCountsTheScenesBefore() throws {
        let text = "# Un\nA.\n<!-- scene: Le bal -->\nB.\n<!-- scene: Scène 3 -->\nC.\n"
        guard case let .scene(_, marker)? = Breaks.onReturn(text, caret: (text as NSString).length, lang: "de") else { return XCTFail() }
        XCTAssertEqual(marker, "<!-- scene: Szene 4 -->", "in the book's language")
    }

    func testReturnBelowASceneSplitsTheChapter() throws {
        let text = "# Un\nIl pleuvait.\n<!-- scene: Scène 2 -->\n\nLa suite.\n"
        let caret = (text as NSString).range(of: "-->\n").location + 4
        let step = try XCTUnwrap(Breaks.onReturn(text, caret: caret, lang: "fr"))
        XCTAssertEqual(step, .chapter(before: "# Un\nIl pleuvait.", after: "La suite.\n"))
    }

    func testOrdinaryReturnsStayReturns() {
        let ns = "# Un\nIl pleuvait.\nLa suite." as NSString
        XCTAssertNil(Breaks.onReturn(ns as String, caret: ns.range(of: "pleuvait.").location + 9, lang: "fr"), "at the end of a line of prose")
        let afterHeading = "# Un\n"
        XCTAssertNil(Breaks.onReturn(afterHeading, caret: 5, lang: "fr"), "right under the title")
        let blank = "# Un\nA.\n\n"
        XCTAssertNil(Breaks.onReturn(blank, caret: (blank as NSString).length, lang: "fr"), "a blank line already in the book keeps its meaning")
        XCTAssertNil(Breaks.onReturn("", caret: 0, lang: "fr"))
    }

    func testBackspaceBelowASceneTakesItAway() throws {
        let text = "A.\n<!-- scene: Scène 2 -->\n"
        let r = try XCTUnwrap(Breaks.onBackspace(text, caret: (text as NSString).length))
        XCTAssertEqual((text as NSString).replacingCharacters(in: r, with: ""), "A.\n", "back to the empty paragraph")
        XCTAssertNil(Breaks.onBackspace("A.\nB", caret: 3))
    }

    func testChapterTitlesInEveryLanguage() {
        XCTAssertEqual(Breaks.chapterTitle(8, lang: "fr-FR"), "Chapitre 8")
        XCTAssertEqual(Breaks.chapterTitle(2, lang: "pt-BR"), "Capítulo 2")
        XCTAssertEqual(Breaks.chapterTitle(3, lang: "en-GB"), "Chapter 3")
    }

    /// The split on a book in a temporary folder: the new chapter after the open one, and ⌘Z putting it back.
    func testSplitAndUndo() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("breaks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "# Un\n\nIl pleuvait.\n\nLa suite.\n".write(to: root.appendingPathComponent("01_un.md"), atomically: true, encoding: .utf8)
        try "# Deux\n\nPlus tard.\n".write(to: root.appendingPathComponent("02_deux.md"), atomically: true, encoding: .utf8)
        var manifest = BookManifest(title: "Livre", chapters: [ChapterEntry(id: "01_un", file: "01_un.md", title: "Un"),
                                                               ChapterEntry(id: "02_deux", file: "02_deux.md", title: "Deux")])
        manifest.lang = "fr-FR"
        let session = BookSession(root: root, manifest: manifest)
        session.open("01_un")
        let original = session.text
        XCTAssertTrue(session.canSplitChapter)

        let split = try XCTUnwrap(session.splitChapter(before: "# Un\nIl pleuvait.", after: "La suite."))
        XCTAssertEqual(session.manifest.chapters.map(\.title), ["Un", "Chapitre 2", "Deux"], "right after the chapter split")
        XCTAssertEqual(session.selectedChapterID, split.created, "the new chapter is open")
        XCTAssertEqual(session.text, "# Chapitre 2\nLa suite.")
        XCTAssertEqual(session.pendingSelection, NSRange(location: 2, length: 10), "its title selected to type over")
        let created = try XCTUnwrap(session.manifest.chapters.first { $0.id == split.created })
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent(created.file), encoding: .utf8), "# Chapitre 2\n\nLa suite.")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("01_un.md"), encoding: .utf8), "# Un\n\nIl pleuvait.")

        session.undoSplit(split)
        XCTAssertEqual(session.manifest.chapters.map(\.id), ["01_un", "02_deux"])
        XCTAssertEqual(session.selectedChapterID, "01_un")
        XCTAssertEqual(session.text, original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(created.file).path), "the file Musset made is gone")
    }
}
