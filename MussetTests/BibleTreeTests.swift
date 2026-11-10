import XCTest
@testable import Musset

/// The Bible as a file tree: folders at any depth, renamed, moved and deleted, with Musset's own folders kept in place.
@MainActor
final class BibleTreeTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("musset-tree-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "# A\n\nLe texte.\n".write(to: root.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func session() throws -> BookSession {
        let git = GitService(root: root)
        try git.initRepo()
        let m = BookManifest(title: "T", chapters: [ChapterEntry(id: "a", file: "a.md", title: "A")])
        try BookStore(root: root).saveManifest(m)
        _ = try git.commit(paths: ["a.md", ".musset"], message: "start")
        return BookSession(root: root, manifest: m)
    }

    private func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent("bible/" + path).path)
    }

    func testFoldersNestAndKeepTheirTypedNames() throws {
        let s = try session()
        let world = try XCTUnwrap(s.newBibleFolder(named: "Le monde", in: ""))
        let cities = try XCTUnwrap(s.newBibleFolder(named: "Villes / ports", in: world))
        XCTAssertEqual(cities, "Le monde/Villes - ports")
        XCTAssertEqual(s.newBibleFolder(named: "Le monde", in: ""), "Le monde 2", "a taken name gets a number")
        XCTAssertNil(s.newBibleFolder(named: " .. ", in: ""))
        XCTAssertTrue(s.bible.folders.contains(cities))
        XCTAssertEqual(BibleStore.children(of: world, in: s.bible.folders), [cities])
        // Musset's folders stay first, then the author's, by name.
        XCTAssertEqual(Array(BibleStore.children(of: "", in: s.bible.folders).prefix(BibleStore.standardFolders.count)), BibleStore.standardFolders)
        XCTAssertEqual(BibleStore.folderLabel(cities), "Villes - ports")
    }

    func testRenameMovesWhatIsInside() throws {
        let s = try session()
        let folder = try XCTUnwrap(s.newBibleFolder(named: "Idées", in: ""))
        let sheet = try s.bible.create(title: "Une idée", kind: .note, folder: folder)
        let renamed = try XCTUnwrap(s.renameBibleFolder(folder, to: "Pistes"))
        XCTAssertEqual(renamed, "Pistes")
        XCTAssertNotNil(s.bible.entry(path: "Pistes/" + (sheet.path as NSString).lastPathComponent))
        XCTAssertEqual(s.renameBibleFolder(renamed, to: "pistes"), "pistes", "a change of case only")
        XCTAssertTrue(exists("pistes"))
        _ = s.newBibleFolder(named: "Autre", in: "")
        XCTAssertNil(s.renameBibleFolder("Autre", to: "pistes"))
        XCTAssertNotNil(s.lastError, "a taken name is refused, not merged")
        XCTAssertEqual(BookSession.retarget("Idées/une-idee.md", from: "Idées", to: "Pistes"), "Pistes/une-idee.md")
        XCTAssertEqual(BookSession.retarget("Idées 2/x.md", from: "Idées", to: "Pistes"), "Idées 2/x.md")
    }

    func testSystemFoldersStayButHoldAnything() throws {
        let s = try session()
        for folder in BibleStore.standardFolders {
            XCTAssertTrue(BibleStore.isSystem(folder))
            XCTAssertNil(s.renameBibleFolder(folder, to: "x"))
            XCTAssertNil(s.moveBibleFolder(folder, into: "chutes"))
            XCTAssertFalse(s.deleteBibleFolder(folder))
        }
        let sub = try XCTUnwrap(s.newBibleFolder(named: "Famille", in: "personnages"))
        XCTAssertFalse(BibleStore.isSystem(sub), "a folder the author made inside one is theirs")
        let sheet = try s.bible.create(title: "Tante Rose", kind: .character)
        XCTAssertEqual(s.moveBibleEntry(sheet.path, toFolder: sub), "personnages/Famille/tante-rose.md")
    }

    func testFoldersMoveButNeverIntoThemselves() throws {
        let s = try session()
        let a = try XCTUnwrap(s.newBibleFolder(named: "A", in: ""))
        let b = try XCTUnwrap(s.newBibleFolder(named: "B", in: a))
        XCTAssertNil(s.moveBibleFolder(a, into: b))
        XCTAssertNil(s.moveBibleFolder(a, into: a))
        XCTAssertEqual(s.moveBibleFolder(b, into: "lieux"), "lieux/B")
        XCTAssertEqual(s.moveBibleFolder("lieux/B", into: ""), "B")
        XCTAssertTrue(exists("B") && !exists("A/B"))
    }

    func testADocumentMovesWithItsKeptPassages() throws {
        let s = try session()
        let file = root.appendingPathComponent("bible/documents/source.pdf")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("%PDF".utf8).write(to: file)
        try "> passage gardé\n".write(to: URL(fileURLWithPath: file.path + ".md"), atomically: true, encoding: .utf8)
        s.bible.reload()
        let target = try XCTUnwrap(s.newBibleFolder(named: "Sources", in: ""))
        XCTAssertEqual(s.moveBibleEntry("documents/source.pdf", toFolder: target), "Sources/source.pdf")
        XCTAssertTrue(exists("Sources/source.pdf") && exists("Sources/source.pdf.md"))
        XCTAssertFalse(exists("documents/source.pdf.md"))
    }

    func testDeletingAFolderSendsItsSheetsToTheBooksTrash() throws {
        let s = try session()
        let folder = try XCTUnwrap(s.newBibleFolder(named: "Vieilles idées", in: ""))
        let inner = try XCTUnwrap(s.newBibleFolder(named: "Plus vieilles", in: folder))
        _ = try s.bible.create(title: "Une", kind: .note, folder: folder)
        _ = try s.bible.create(title: "Deux", kind: .note, folder: inner)
        XCTAssertTrue(s.deleteBibleFolder(folder))
        XCTAssertFalse(exists(folder))
        XCTAssertEqual(Set(s.trash.map(\.title)), ["Une", "Deux"])
        XCTAssertFalse(s.bible.folders.contains { BibleStore.isInside($0, folder) })
        // Each comes back where it was, folders included.
        let deux = try XCTUnwrap(s.trash.first { $0.title == "Deux" })
        XCTAssertTrue(s.restoreFromTrash(deux.id))
        XCTAssertNotNil(s.bible.entries.first { $0.title == "Deux" && $0.folder == inner })
    }

    func testFolderDragWire() {
        XCTAssertEqual(ShelfDrag(wire: ShelfDrag.folder("Le monde/Villes").wire), .folder("Le monde/Villes"))
        // A folder dropped on Drafts or Trash moves nothing.
        XCTAssertFalse((try? session())!.drop([ShelfDrag.folder("x").wire], on: .trash).accepted)
    }
}
