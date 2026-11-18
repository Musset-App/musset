import XCTest
@testable import Musset

@MainActor
final class ShelfTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("musset-shelf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in ["a", "b", "c"] { try "# \(name.uppercased())\n\nLe texte de \(name), en quatre mots.\n".write(to: root.appendingPathComponent("\(name).md"), atomically: true, encoding: .utf8) }
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func session() throws -> BookSession {
        let git = GitService(root: root)
        try git.initRepo()
        let m = BookManifest(title: "T", chapters: ["a", "b", "c"].map { ChapterEntry(id: $0, file: "\($0).md", title: $0.uppercased()) })
        try BookStore(root: root).saveManifest(m)
        _ = try git.commit(paths: ["a.md", "b.md", "c.md", ".musset"], message: "start")
        return BookSession(root: root, manifest: m)
    }

    func testWireRoundTripsAndIgnoresForeignText() {
        let id = UUID()
        for drag in [ShelfDrag.chapter("01_a"), .note(chapter: "01|a", id: id), .sheet("chutes/x|y.md"), .trashed(id)] {
            XCTAssertEqual(ShelfDrag(wire: drag.wire), drag)
        }
        XCTAssertNil(ShelfDrag(wire: "un bout de texte glissé de la page"))
        XCTAssertNil(ShelfDrag(wire: "a"))
    }

    func testForeignTextDropMovesNothing() throws {
        let s = try session()
        XCTAssertFalse(s.drop(["a"], on: .trash).accepted)
        XCTAssertEqual(s.manifest.chapters.count, 3)
        XCTAssertTrue(s.trash.isEmpty)
    }

    func testChapterToDraftsLeavesTheBookButKeepsItsFileAndStaysOpen() throws {
        let s = try session()
        let before = s.bookWordCount
        s.open("b")
        XCTAssertTrue(s.drop([ShelfDrag.chapter("b").wire], on: .drafts).accepted)
        XCTAssertEqual(s.manifest.chapters.map(\.id), ["a", "c"])
        XCTAssertEqual(s.draftChapters.map(\.id), ["b"])
        XCTAssertLessThan(s.bookWordCount, before)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("b.md").path))
        XCTAssertEqual(s.selectedChapter?.id, "b")
        // Still written and saved, in the file it always had.
        s.textDidChange(s.text + "\nAjout.")
        s.flushSave()
        XCTAssertTrue(try String(contentsOf: root.appendingPathComponent("b.md"), encoding: .utf8).contains("Ajout."))
        // The manifest on disk agrees; old manifests without the field still read.
        XCTAssertEqual(try BookStore(root: root).loadManifest().drafts?.map(\.id), ["b"])

        s.dropOnBook([ShelfDrag.chapter("b").wire], at: 0)
        XCTAssertEqual(s.manifest.chapters.map(\.id), ["b", "a", "c"])
        XCTAssertTrue(s.draftChapters.isEmpty)
    }

    func testChapterTrashAndRestoreToItsPlace() throws {
        let s = try session()
        s.open("b")
        s.drop([ShelfDrag.chapter("b").wire], on: .trash)
        XCTAssertEqual(s.manifest.chapters.map(\.id), ["a", "c"])
        XCTAssertEqual(s.selectedChapter?.id, "c", "the neighbour opens")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("b.md").path))
        XCTAssertEqual(TrashStore(root: root).load().map(\.title), ["B"])

        XCTAssertTrue(s.restoreFromTrash(s.trash[0].id))
        XCTAssertEqual(s.manifest.chapters.map(\.id), ["a", "b", "c"])
        XCTAssertTrue(s.trash.isEmpty)
    }

    func testTrashedChapterDraggedToDraftsAndToAPlace() throws {
        let s = try session()
        s.drop([ShelfDrag.chapter("c").wire], on: .trash)
        s.drop([ShelfDrag.trashed(s.trash[0].id).wire], on: .drafts)
        XCTAssertEqual(s.draftChapters.map(\.id), ["c"])
        XCTAssertTrue(s.trash.isEmpty)
        s.drop([ShelfDrag.chapter("c").wire], on: .trash)
        s.dropOnBook([ShelfDrag.trashed(s.trash[0].id).wire], at: 0)
        XCTAssertEqual(s.manifest.chapters.map(\.id), ["c", "a", "b"])
    }

    func testNoteToTrashComesBackAndNoteToDraftsBecomesADraft() throws {
        let s = try session()
        let note = s.notes.addPlain("Vérifier le cartable dans la cour", kind: .todo, in: "a")
        s.drop([ShelfDrag.note(chapter: "a", id: note.id).wire], on: .trash)
        XCTAssertTrue(s.notes.notes(of: "a").isEmpty)
        XCTAssertTrue(s.restoreFromTrash(s.trash[0].id))
        XCTAssertEqual(s.notes.notes(of: "a").map(\.id), [note.id])

        s.drop([ShelfDrag.note(chapter: "a", id: note.id).wire], on: .drafts)
        XCTAssertTrue(s.notes.notes(of: "a").isEmpty)
        XCTAssertEqual(s.draftSheets.map(\.title), ["Vérifier le cartable dans la cour"])
        XCTAssertEqual(s.draftSheets.first?.kind, .draft)
        XCTAssertEqual(s.draftSheets.first?.meta["from"], "a")
    }

    func testBibleEntryToDraftsAndThroughTheTrash() throws {
        let s = try session()
        let e = try s.bible.create(title: "Idée", kind: .note)
        let moved = s.drop([ShelfDrag.sheet(e.path).wire], on: .drafts).sheets[e.path]
        XCTAssertEqual(moved, .some("brouillons/idee.md"))
        XCTAssertEqual(s.draftSheets.first?.kind, .draft)

        let path = "brouillons/idee.md"
        s.drop([ShelfDrag.sheet(path).wire], on: .trash)
        XCTAssertTrue(s.draftSheets.isEmpty)
        XCTAssertTrue(s.trashPreview(s.trash[0]).contains("Idée"))
        XCTAssertTrue(s.restoreFromTrash(s.trash[0].id))
        XCTAssertEqual(s.draftSheets.map(\.path), [path])
    }

    func testEmptyingCommitsTheFileAway() throws {
        let s = try session()
        s.drop([ShelfDrag.chapter("c").wire], on: .trash)
        XCTAssertNotNil(s.git.show("HEAD", path: "c.md"))
        s.deleteFromTrash(Set(s.trash.map(\.id)))
        XCTAssertTrue(s.trash.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("c.md").path))
        XCTAssertNil(s.git.show("HEAD", path: "c.md"))
        XCTAssertNotNil(s.git.show("HEAD~1", path: "c.md"), "the history keeps it")
    }

    func testAChapterDeletedForGoodTakesItsPlotAndItsPlaceAlong() throws {
        let s = try session()
        s.plot.update("c", "") { $0.status = .done }
        s.plot.setChapterSynopsis("c", "Where it ends.")
        s.plot.setChapterSynopsis("a", "Where it starts.")
        s.savePlot()
        s.state.selections["c"] = 12
        s.drop([ShelfDrag.chapter("c").wire], on: .trash)
        XCTAssertNotNil(s.plot.rows["c"], "in the Trash it can still come back whole")
        s.deleteFromTrash(Set(s.trash.map(\.id)))
        XCTAssertNil(s.plot.rows["c"])
        XCTAssertEqual(s.plot.chapterSynopses, ["a": "Where it starts."])
        XCTAssertNil(s.state.selections["c"])
        XCTAssertNil(s.scenes["c"])
        let onDisk = PlotGrid.load(root)
        XCTAssertNil(onDisk.rows["c"])
        XCTAssertEqual(onDisk.chapterSynopses, ["a": "Where it starts."])
        XCTAssertFalse(s.git.show("HEAD", path: ".musset/plot.json")?.contains("Where it ends.") ?? true, "committed with the emptied Trash")
    }

    /// `trash.json` as Musset has always written it: read into the item's payload, and written back the same, byte for byte.
    func testTheTrashFileKeepsItsForm() throws {
        let file = """
        [
          {
            "chapter" : {
              "activeVersion" : "main",
              "excludeFromExport" : false,
              "file" : "ch/c.md",
              "id" : "c",
              "status" : "done",
              "title" : "C"
            },
            "date" : "2026-11-02T10:00:00Z",
            "id" : "0E1F2A3B-0000-4000-8000-000000000001",
            "index" : 2,
            "kind" : "chapter",
            "title" : "C",
            "wasDraft" : false
          },
          {
            "date" : "2026-11-02T10:05:00Z",
            "id" : "0E1F2A3B-0000-4000-8000-000000000002",
            "kind" : "sheet",
            "sheetPath" : "personnages/tom.md",
            "title" : "Tom"
          },
          {
            "date" : "2026-11-02T10:06:00Z",
            "id" : "0E1F2A3B-0000-4000-8000-000000000003",
            "kind" : "version",
            "title" : "C — Paris",
            "versionChapter" : "c",
            "versionName" : "Paris"
          }
        ]
        """
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".musset"), withIntermediateDirectories: true)
        let url = root.appendingPathComponent(".musset/trash.json")
        try Data(file.utf8).write(to: url)
        let store = TrashStore(root: root)
        let items = store.load()
        XCTAssertEqual(items.map(\.kind), [.chapter, .sheet, .version])
        XCTAssertEqual(items[0].payload, .chapter(ChapterEntry(id: "c", file: "ch/c.md", title: "C", status: .done), index: 2, wasDraft: false))
        XCTAssertEqual(items[1].payload, .sheet(path: "personnages/tom.md"))
        XCTAssertEqual(items[2].payload, .version(chapter: "c", name: "Paris"))
        try store.save(items)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), file)

        // A note, and a chapter from before `wasDraft` was written: the same bytes as the flat item Musset had.
        struct Flat: Codable {
            var id: UUID, kind: String, title: String, date: Date
            var chapter: ChapterEntry? = nil, index: Int? = nil, wasDraft: Bool? = nil
            var note: Note? = nil, noteChapter: String? = nil
            var sheetPath: String? = nil, versionChapter: String? = nil, versionName: String? = nil
        }
        let note = Note(author: .me, kind: .todo, body: "À revoir", anchor: NoteAnchor(quote: "le quai", prefix: "sur ", suffix: " désert", start: 4, version: nil))
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let flat = [Flat(id: UUID(), kind: "note", title: "À revoir", date: date, index: 1, note: note, noteChapter: "a"),
                    Flat(id: UUID(), kind: "chapter", title: "B", date: date, chapter: ChapterEntry(id: "b", file: "b.md", title: "B"))]
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let before = try enc.encode(flat)
        try before.write(to: url)
        let read = store.load()
        guard case .note(let back, "a", 1) = read[0].payload else { return XCTFail("\(read[0].payload)") }
        XCTAssertEqual(back.body, "À revoir")
        XCTAssertEqual(read[1].payload, .chapter(ChapterEntry(id: "b", file: "b.md", title: "B"), index: nil, wasDraft: nil))
        try store.save(read)
        XCTAssertEqual(try Data(contentsOf: url), before)

        // One item that cannot be read does not empty the Trash.
        try Data(file.replacingOccurrences(of: "\"sheetPath\" : \"personnages/tom.md\",\n    ", with: "").utf8).write(to: url)
        XCTAssertEqual(store.load().map(\.kind), [.chapter, .version])
    }

    func testAddChapterDoesNotAdoptATrashedFile() throws {
        let s = try session()
        s.addChapter(title: "Nouveau")
        let id = s.manifest.chapters.last!.id
        s.drop([ShelfDrag.chapter(id).wire], on: .trash)
        s.addChapter(title: "Nouveau")
        XCTAssertNotEqual(s.manifest.chapters.last!.id, id)
    }
}

@MainActor
final class DraftSheetToBookTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("musset-sheetbook-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in ["a", "b"] { try "# \(name.uppercased())\n\nTexte.\n".write(to: root.appendingPathComponent("\(name).md"), atomically: true, encoding: .utf8) }
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func session() throws -> BookSession {
        let git = GitService(root: root)
        try git.initRepo()
        let m = BookManifest(title: "T", chapters: ["a", "b"].map { ChapterEntry(id: $0, file: "\($0).md", title: $0.uppercased()) })
        try BookStore(root: root).saveManifest(m)
        _ = try git.commit(paths: ["a.md", "b.md", ".musset"], message: "start")
        return BookSession(root: root, manifest: m)
    }

    /// « Interlude 2 », written as a draft sheet, dropped between A and B.
    func testADraftSheetDroppedOnTheBookBecomesAChapterThere() throws {
        let s = try session()
        let sheet = try s.bible.create(title: "Interlude 2", kind: .draft, body: "# ✽\n\n> *Un chemin dans la pinède.*  \n")
        s.dropOnBook([ShelfDrag.sheet(sheet.path).wire], at: 1)
        XCTAssertEqual(s.manifest.chapters.map(\.title), ["A", "Interlude 2", "B"])
        let chapter = s.manifest.chapters[1]
        let text = try String(contentsOf: root.appendingPathComponent(chapter.file), encoding: .utf8)
        XCTAssertEqual(text, "# ✽\n\n> *Un chemin dans la pinède.*  \n", "its own heading kept, nothing added")
        XCTAssertNil(s.bible.entry(path: sheet.path), "no longer a draft")
        XCTAssertEqual(s.trash.map(\.title), ["Interlude 2"], "but the sheet waits in the Trash")
        XCTAssertEqual(try BookStore(root: root).loadManifest().chapters.map(\.title), ["A", "Interlude 2", "B"])
    }

    func testAHeadingIsAddedWhenTheDraftHasNone() throws {
        let s = try session()
        let sheet = try s.bible.create(title: "Fragment", kind: .draft, body: "Une phrase.")
        let id = try XCTUnwrap(s.sheetToBook(sheet.path))
        let file = try XCTUnwrap(s.manifest.chapters.first { $0.id == id }?.file)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8), "# Fragment\n\nUne phrase.\n")
        XCTAssertEqual(s.manifest.chapters.last?.id, id, "with no place given, at the end")
    }

    func testOtherSheetsDoNotBecomeChapters() throws {
        let s = try session()
        let character = try s.bible.create(title: "Rose", kind: .character)
        s.dropOnBook([ShelfDrag.sheet(character.path).wire], at: 0)
        XCTAssertEqual(s.manifest.chapters.map(\.title), ["A", "B"])
        XCTAssertNotNil(s.bible.entry(path: character.path))
    }
}
