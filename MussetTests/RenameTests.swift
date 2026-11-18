import XCTest
@testable import Musset

/// Renaming a character everywhere: previewed, written in one commit, taken back in one undo.
@MainActor
final class RenameTests: XCTestCase {
    private var root: URL!

    private func book() throws -> BookSession {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("musset-rename-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { [root] in try? FileManager.default.removeItem(at: root!) }
        try "Tom’s van was by the weighing house. “Tommy,” their mother used to say.".write(to: root.appendingPathComponent("01.md"), atomically: true, encoding: .utf8)
        try "Tom said nothing. The roof leaked.".write(to: root.appendingPathComponent("02.md"), atomically: true, encoding: .utf8)
        var m = BookManifest(title: "Salt", chapters: [ChapterEntry(id: "01", file: "01.md", title: "The Ferry"),
                                                       ChapterEntry(id: "02", file: "02.md", title: "The Salt Works")])
        m.lang = "en"
        try BookStore(root: root).saveManifest(m)
        let git = GitService(root: root)
        try git.initRepo()
        _ = try git.commit(paths: ["01.md", "02.md", ".musset"], message: "start")
        let s = BookSession(root: root, manifest: m)
        s.open("01")
        try s.bible.create(title: "Tom", kind: .character, aliases: ["Tommy"])
        try s.bible.create(title: "Nora", kind: .character, body: "Sister of Tom.\n")
        let r = (s.text as NSString).range(of: "Tom’s van")
        s.notes.add(range: r, text: s.text, author: .me, kind: .note, body: "Is Tom’s van blue?")
        s.plot.synopsis = "Tom sold the works."
        s.plot.index = [PlotGrid.Tag(name: "Tom", column: "characters", aliases: ["Tommy"])]
        s.savePlot()
        s.commitNow("setup")
        return s
    }

    private func commits() -> Int {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", root.path, "rev-list", "--count", "HEAD"]
        let out = Pipe()
        p.standardOutput = out
        try? p.run()
        p.waitUntilExit()
        return Int(String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
    }

    func testPreviewSortsWhatIsSureFromWhatToCheck() throws {
        let s = try book()
        let tom = try XCTUnwrap(s.bible.entry(named: "Tom"))
        let plan = RenamePlan.make(tom, to: "Ewan", in: s)
        XCTAssertEqual(plan.hits.count, 3)
        XCTAssertEqual(plan.sure.map(\.form), ["Tom", "Tom"])
        XCTAssertEqual(plan.toCheck.map(\.form), ["Tommy"], "a nickname is the author's call")
        XCTAssertEqual(plan.elsewhere.bible, 2, "the sheet's title and Nora's sheet")
        XCTAssertEqual(plan.elsewhere.notes, 1)
        XCTAssertEqual(plan.elsewhere.plot, 2, "the synopsis and the grid's index")
        XCTAssertEqual(plan.count, 7, "two in the text, Tommy unchanged")
    }

    func testRenameEverywhereInOneCommitAndUndoInOne() throws {
        let s = try book()
        let before = commits()
        let tom = try XCTUnwrap(s.bible.entry(named: "Tom"))
        var plan = RenamePlan.make(tom, to: "Ewan", in: s)
        plan.aliasTo["Tommy"] = "Ewie"
        let undo = try XCTUnwrap(s.applyRename(plan))

        XCTAssertEqual(s.text, "Ewan’s van was by the weighing house. “Ewie,” their mother used to say.")
        XCTAssertEqual(s.editorText(of: "02"), "Ewan said nothing. The roof leaked.")
        let ewan = try XCTUnwrap(s.bible.entry(named: "Ewan"))
        XCTAssertEqual(ewan.aliases, ["Ewie"])
        XCTAssertEqual(s.bible.entry(named: "Nora")?.body, "Sister of Ewan.\n")
        let note = try XCTUnwrap(s.notes.notes.first)
        XCTAssertEqual(note.body, "Is Ewan’s van blue?")
        XCTAssertTrue(note.anchor.quote.contains("Ewan"))
        XCTAssertNotNil(s.notes.live[note.id], "the note still finds its passage")
        XCTAssertEqual(s.plot.synopsis, "Ewan sold the works.")
        let tag = try XCTUnwrap(s.plot.tags.first)
        XCTAssertEqual(tag.name, "Ewan")
        XCTAssertFalse(tag.aliases.contains("Tom"), "the old name doesn't keep pointing at them")
        XCTAssertEqual(commits(), before + 1, "one commit for the whole rename")

        s.undoRename(undo)
        XCTAssertEqual(s.text, "Tom’s van was by the weighing house. “Tommy,” their mother used to say.")
        XCTAssertEqual(s.editorText(of: "02"), "Tom said nothing. The roof leaked.")
        XCTAssertNotNil(s.bible.entry(named: "Tom"))
        XCTAssertEqual(s.bible.entry(named: "Nora")?.body, "Sister of Tom.\n")
        XCTAssertEqual(s.notes.notes.first?.body, "Is Tom’s van blue?")
        XCTAssertEqual(s.plot.synopsis, "Tom sold the works.")
        XCTAssertEqual(s.plot.tags.first?.name, "Tom")
        XCTAssertEqual(commits(), before + 2)
    }

    func testAnUntickedPlaceStays() throws {
        let s = try book()
        let tom = try XCTUnwrap(s.bible.entry(named: "Tom"))
        var plan = RenamePlan.make(tom, to: "Ewan", in: s)
        let second = try XCTUnwrap(plan.hits.first { $0.chapter == "02" })
        plan.skipped.insert(second.id)
        s.applyRename(plan)
        XCTAssertEqual(s.editorText(of: "02"), "Tom said nothing. The roof leaked.")
        XCTAssertTrue(s.text.hasPrefix("Ewan’s van"))
    }

    func testOrdinaryWordAfterAnArticleIsToCheck() throws {
        let s = try book()
        s.text = "Rose came in. She smelled the rose. Then the Rose fell from the vase."
        s.flushSave()
        let rose = try s.bible.create(title: "Rose", kind: .character)
        let plan = RenamePlan.make(rose, to: "Iris", in: s)
        XCTAssertEqual(plan.hits.count, 2, "lowercase rose is never her")
        XCTAssertEqual(plan.toCheck.count, 2, "sentence start and after « the »: both ordinary words too")
    }
}

@MainActor
final class RenameSheetTextTests: XCTestCase {
    func testExcerptsReadAsTheReaderSeesThem() {
        XCTAssertEqual(RenameSheet.readable("Nobody had {~~ever locked~>locked~~}{@Claire} anything, {++its back doors++}{@Claire} open, nothing {--left--}{@Claire} to take."),
                       "Nobody had locked anything, its back doors open, nothing  to take.")
    }
}
