import XCTest
@testable import Musset

/// Chapter versions: one writes in any of them, the book reads only its own, and choosing can be undone.
@MainActor
final class ChapterVersionTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("musset-versions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "# Amiens\n\nElle arrivait avec le train de seize heures huit.\n".write(to: root.appendingPathComponent("amiens.md"), atomically: true, encoding: .utf8)
        try "# Nyons\n\nLes oliviers.\n".write(to: root.appendingPathComponent("nyons.md"), atomically: true, encoding: .utf8)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func session() throws -> BookSession {
        let git = GitService(root: root)
        try git.initRepo()
        let m = BookManifest(title: "T", chapters: [ChapterEntry(id: "amiens", file: "amiens.md", title: "Amiens"),
                                                    ChapterEntry(id: "nyons", file: "nyons.md", title: "Nyons")])
        try BookStore(root: root).saveManifest(m)
        _ = try git.commit(paths: ["amiens.md", "nyons.md", ".musset"], message: "start")
        let s = BookSession(root: root, manifest: m)
        s.open("amiens")
        return s
    }

    private func bookFile() throws -> String { try String(contentsOf: root.appendingPathComponent("amiens.md"), encoding: .utf8) }

    func testWritingAnotherVersionLeavesTheBookAlone() throws {
        let s = try session()
        s.tryAnotherVersion(named: "J’y vais", blank: false, currentName: "Elle vient à Paris")
        XCTAssertEqual(s.versions, ["Elle vient à Paris", "J’y vais"])
        XCTAssertEqual(s.openAlternate, "J’y vais")
        XCTAssertEqual(s.selectedChapter?.activeVersion, "Elle vient à Paris", "the book keeps its version")
        XCTAssertEqual(s.versionCounts["amiens"], 2)

        s.textDidChange(s.text + "\nJe prends le train pour Amiens.")
        s.flushSave()
        XCTAssertFalse(try bookFile().contains("Je prends le train"), "the book's chapter is untouched")
        let ch = try XCTUnwrap(s.selectedChapter)
        XCTAssertTrue(s.store.readVersion(ch, "J’y vais").contains("Je prends le train"))
        XCTAssertFalse(s.editorText(of: "amiens").contains("Je prends le train"), "what the book reads is the book's version")
        XCTAssertEqual(s.chapterWords["amiens"], BookStore.wordCount(ParagraphCodec.decode(try bookFile())))

        // Coming back to the chapter, the editor opens where one was writing.
        s.open("nyons")
        s.open("amiens")
        XCTAssertEqual(s.openAlternate, "J’y vais")
        XCTAssertTrue(s.text.contains("Je prends le train"))
    }

    func testPutInTheBookAndUndo() throws {
        let s = try session()
        s.tryAnotherVersion(named: "J’y vais", blank: false, currentName: "Elle vient à Paris")
        s.textDidChange(s.text + "\nJe prends le train pour Amiens.")

        let done = try XCTUnwrap(s.putInBook("J’y vais"))
        XCTAssertEqual(done.previous, "Elle vient à Paris")
        XCTAssertEqual(s.selectedChapter?.activeVersion, "J’y vais")
        XCTAssertTrue(try bookFile().contains("Je prends le train"), "the unsaved line went in with it")
        XCTAssertNil(s.openAlternate, "the editor now writes the book's version")
        XCTAssertEqual(s.versions.sorted(), ["Elle vient à Paris", "J’y vais"], "nothing lost")

        s.undoVersionSwitch()
        XCTAssertEqual(s.selectedChapter?.activeVersion, "Elle vient à Paris")
        XCTAssertFalse(try bookFile().contains("Je prends le train"))
        XCTAssertNil(s.lastVersionSwitch)
    }

    func testPuttingTheSideVersionInKeepsTheEditorOnItsOwn() throws {
        let s = try session()
        s.tryAnotherVersion(named: "J’y vais", blank: false, currentName: "Paris")
        s.tryAnotherVersion(named: "Courte", blank: true)
        XCTAssertEqual(s.openAlternate, "Courte")
        XCTAssertEqual(s.text.trimmingCharacters(in: .whitespacesAndNewlines), "# Amiens", "a blank page keeps the chapter's title")
        s.showBeside("J’y vais")
        XCTAssertEqual(s.reference, "J’y vais")

        s.putInBook("J’y vais")
        XCTAssertEqual(s.selectedChapter?.activeVersion, "J’y vais")
        XCTAssertEqual(s.openAlternate, "Courte", "still writing the blank page")
        XCTAssertEqual(s.reference, "J’y vais", "the side shows the book's version now")
    }

    func testTrashAndBack() throws {
        let s = try session()
        s.tryAnotherVersion(named: "J’y vais", blank: false, currentName: "Paris")
        s.versionToTrash("J’y vais")
        XCTAssertEqual(s.versions, ["Paris"])
        XCTAssertNil(s.openAlternate)
        XCTAssertNil(s.versionCounts["amiens"])
        let item = try XCTUnwrap(s.trash.first)
        XCTAssertEqual(item.kind, .version)
        XCTAssertTrue(s.trashPreview(item).contains("seize heures huit"))

        s.versionToTrash("Paris")
        XCTAssertEqual(s.trash.count, 1, "the book's own version can't go")

        XCTAssertTrue(s.restoreFromTrash(item.id))
        XCTAssertEqual(s.versions, ["Paris", "J’y vais"])
        XCTAssertTrue(s.trash.isEmpty)
    }

    func testRenamingTheOpenVersionKeepsItOpen() throws {
        let s = try session()
        s.tryAnotherVersion(named: "J’y vais", blank: false)
        XCTAssertEqual(s.versions.first, "main")
        XCTAssertEqual(BookSession.versionLabel("main"), "Première version")
        s.renameVersion("J’y vais", to: "Le train")
        XCTAssertEqual(s.openAlternate, "Le train")
        XCTAssertEqual(s.versions, ["main", "Le train"])
    }
}
