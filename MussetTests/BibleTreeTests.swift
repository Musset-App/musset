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

    func testWhatIsKeptByPathFollowsASheetThatMoves() throws {
        let tom = try session().bible.create(title: "Tom", kind: .character).path
        var facts = BookFacts()
        facts.entities[tom] = .init(facts: [.init(text: "Tom is eleven.", chapter: "a", quote: "Le texte")], aliases: ["le petit"])
        try facts.save(root)
        let s = BookSession(root: root, manifest: try BookStore(root: root).loadManifest())
        XCTAssertNotNil(s.keeper.entity(tom))
        let world = try XCTUnwrap(s.newBibleFolder(named: "Le monde", in: ""))
        s.workspace.open(.sheet(tom), in: .newTab)
        s.workspace.open(.folder(world), in: .newTab)
        s.saveLayout(named: "Bible")
        let window = s.newWindow(with: .sheet(tom))
        let board = try s.bible.createBoard("Mur")
        var canvas = JSONCanvas()
        canvas.nodes = [.init(type: .file, x: 0, y: 0, width: 243, height: 90, file: tom), .init(type: .text, x: 300, y: 0, width: 200, height: 90, text: "Une idée")]
        try canvas.write(s.bible.store.url(board.path))

        func tabs(_ saved: Workspace.Saved?) -> [PaneTab] { saved?.root.panes.flatMap(\.tabs) ?? [] }
        func check(_ sheet: String, _ folder: String, _ old: String) {
            XCTAssertNotNil(s.bible.entry(path: sheet))
            XCTAssertEqual(s.keeper.entity(sheet)?.facts.map(\.text), ["Tom is eleven."], "what the book says")
            XCTAssertNil(s.keeper.entity(old))
            XCTAssertEqual(BookFacts.load(root).entities.keys.sorted(), [sheet])
            XCTAssertTrue(s.mainWorkspace.panes.flatMap(\.tabs).contains(.sheet(sheet)), "the open tab")
            XCTAssertTrue(s.mainWorkspace.panes.flatMap(\.tabs).contains(.folder(folder)))
            XCTAssertEqual(s.workspace(forWindow: window).panes.flatMap(\.tabs), [.sheet(sheet)], "another window's")
            XCTAssertTrue(tabs(s.state.layouts?["Bible"]).contains(.sheet(sheet)), "a named layout's")
            XCTAssertTrue(tabs(s.state.layouts?["Bible"]).contains(.folder(folder)))
            XCTAssertFalse(tabs(s.state.layouts?["Bible"]).contains(.sheet(old)))
            XCTAssertEqual(JSONCanvas.read(s.bible.store.url(board.path)).nodes.map(\.file), [sheet, nil], "its card on the board")
        }

        let moved = try XCTUnwrap(s.moveBibleEntry(tom, toFolder: world))
        XCTAssertNotEqual(moved, tom)
        check(moved, world, tom)
        XCTAssertEqual(s.boardsRewritten, 1)
        // A folder renamed takes what it holds along.
        let renamed = try XCTUnwrap(s.renameBibleFolder(world, to: "Monde"))
        let inside = BookSession.retarget(moved, from: world, to: renamed)
        check(inside, renamed, moved)
        // Into another folder, and what was kept still follows.
        let deep = try XCTUnwrap(s.newBibleFolder(named: "Ailleurs", in: ""))
        let nested = try XCTUnwrap(s.moveBibleFolder(renamed, into: deep))
        check(BookSession.retarget(inside, from: renamed, to: nested), nested, inside)
        // Kept with the book: the layout comes back with the right tabs.
        s.close()
        let again = BookSession(root: root, manifest: try BookStore(root: root).loadManifest())
        XCTAssertTrue(again.mainWorkspace.panes.flatMap(\.tabs).contains(.sheet(BookSession.retarget(inside, from: renamed, to: nested))))
    }

    func testFolderDragWire() {
        XCTAssertEqual(ShelfDrag(wire: ShelfDrag.folder("Le monde/Villes").wire), .folder("Le monde/Villes"))
        // A folder dropped on Drafts or Trash moves nothing.
        XCTAssertFalse((try? session())!.drop([ShelfDrag.folder("x").wire], on: .trash).accepted)
    }
}
