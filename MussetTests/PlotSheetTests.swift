import XCTest
@testable import Musset

/// A character is modelled once: a name of the plot grid that has a sheet in the Bible is that sheet.
@MainActor
final class PlotSheetTests: XCTestCase {
    /// A plot file as Musset wrote it before tags pointed at sheets: names, aliases and notes all in the tag.
    private let oldPlot = #"""
    {"columns":[{"id":"main","title":"Synopsis","ai":true},{"id":"characters","title":"Personnages","ai":true},{"id":"motifs","title":"Motifs","ai":true},{"id":"notes","title":"Notes","ai":false}],
     "index":[{"name":"Tom","column":"characters","aliases":["Tommy","the brother"],"note":"Nora's brother","by":"claude"},
              {"name":"Old Pellow","column":"characters","aliases":["Pellow"],"note":"the ferryman","by":"me"},
              {"name":"salt","column":"motifs","aliases":[],"note":"","by":"claude"}],
     "rows":{"01":{"":{"cells":{"characters":{"text":"","by":"claude","tags":["Tom","Old Pellow"]}}}}}}
    """#

    private func book() throws -> BookSession {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("musset-plotsheet-\(UUID())")
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".musset"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try "Tom came down to the ferry. Old Pellow waited.".write(to: root.appendingPathComponent("01.md"), atomically: true, encoding: .utf8)
        var m = BookManifest(title: "Salt", chapters: [ChapterEntry(id: "01", file: "01.md", title: "The Ferry")])
        m.lang = "en"
        try BookStore(root: root).saveManifest(m)
        try oldPlot.write(to: PlotGrid.url(root), atomically: true, encoding: .utf8)
        try BibleModel(root: root).create(title: "Tom", kind: .character, aliases: ["Tommy"])
        let git = GitService(root: root)
        try git.initRepo()
        _ = try git.commit(paths: ["*"], message: "start")
        return BookSession(root: root, manifest: m)
    }

    private func tag(_ s: BookSession, _ name: String) -> PlotGrid.Tag? { s.plot.tags.first { $0.name == name } }
    private func cellTags(_ s: BookSession) -> [String] { s.plot.row("01", "").cells["characters"]?.tags ?? [] }

    func testAnOldPlotFileLinksItsTagsToTheirSheetsAndSavesInTheNewForm() throws {
        let s = try book()
        let onDisk = try Data(contentsOf: PlotGrid.url(s.root))
        let sheet = try XCTUnwrap(s.bible.entry(named: "Tom"))
        let tom = try XCTUnwrap(tag(s, "Tom"))
        XCTAssertEqual(tom.sheet, sheet.path)
        XCTAssertEqual(tom.sheetAliases, ["Tommy"], "read from the sheet")
        XCTAssertEqual(tom.aliases, ["the brother"], "only what the reading found beyond the sheet")
        XCTAssertEqual(tom.note, "Nora's brother")
        XCTAssertEqual(s.plot.canonical("tommy", column: "characters"), "Tom")
        XCTAssertEqual(s.bible.tagsWithoutSheet(s.plot).map(\.name), ["Old Pellow"])
        XCTAssertEqual(try Data(contentsOf: PlotGrid.url(s.root)), onDisk, "opening the book writes nothing")

        s.savePlot()
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: PlotGrid.url(s.root))) as? [String: Any])
        let index = try XCTUnwrap(raw["index"] as? [[String: Any]])
        let saved = try XCTUnwrap(index.first { $0["name"] as? String == "Tom" })
        XCTAssertEqual(saved["sheet"] as? String, sheet.path)
        XCTAssertEqual(saved["aliases"] as? [String], ["the brother"], "the sheet's own alias is no longer written twice")
        XCTAssertNil(saved["sheetAliases"])
        // Read again, the same book.
        var again = PlotGrid.load(s.root)
        again.bind(to: s.bible.entries)
        XCTAssertEqual(again, s.plot)
    }

    func testATagWithoutASheetIsUntouched() throws {
        let s = try book()
        s.savePlot()
        let old = try JSONDecoder().decode(PlotGrid.self, from: Data(oldPlot.utf8))
        XCTAssertEqual(tag(s, "Old Pellow"), old.tags.first { $0.name == "Old Pellow" })
        XCTAssertEqual(tag(s, "salt"), old.tags.first { $0.name == "salt" })
        XCTAssertEqual(PlotGrid.load(s.root).tags.first { $0.name == "Old Pellow" }, old.tags.first { $0.name == "Old Pellow" }, "written back as it was")
        let bible = s.root.appendingPathComponent(BibleStore.folderName)
        let files = FileManager.default.enumerator(at: bible, includingPropertiesForKeys: nil)?.compactMap { ($0 as? URL)?.lastPathComponent }.filter { $0.hasSuffix(".md") } ?? []
        XCTAssertEqual(files.count, 1, "no sheet is made behind the author's back: \(files)")
    }

    func testRenamingASheetRenamesWhatTheGridShows() throws {
        let s = try book()
        var sheet = try XCTUnwrap(s.bible.entry(named: "Tom"))
        sheet.title = "Thomas"
        try s.bible.save(sheet)
        XCTAssertNil(tag(s, "Tom"))
        let thomas = try XCTUnwrap(tag(s, "Thomas"))
        XCTAssertEqual(thomas.sheet, sheet.path)
        XCTAssertEqual(thomas.by, "claude", "the sheet was renamed, the tag is still the reading's")
        XCTAssertEqual(cellTags(s), ["Thomas", "Old Pellow"])
        XCTAssertEqual(s.plot.canonical("Tom", column: "characters"), "Thomas", "the old name still finds them")

        // The whole-book rename patches the sheet; the grid follows it.
        let plan = RenamePlan.make(try XCTUnwrap(s.bible.entry(path: sheet.path)), to: "Ewan", in: s)
        XCTAssertNotNil(s.applyRename(plan))
        XCTAssertEqual(tag(s, "Ewan")?.sheet, sheet.path)
        XCTAssertEqual(cellTags(s), ["Ewan", "Old Pellow"])
        XCTAssertEqual(PlotGrid.load(s.root).row("01", "").cells["characters"]?.tags, ["Ewan", "Old Pellow"], "saved")
    }

    func testRenamingASheetsTagFromTheGridRenamesTheSheet() throws {
        let s = try book()
        s.renameTag(try XCTUnwrap(tag(s, "Tom")), to: "Thomas")
        XCTAssertEqual(s.bible.entries.filter { !$0.isFile }.map(\.title), ["Thomas"])
        XCTAssertEqual(cellTags(s), ["Thomas", "Old Pellow"])
        // A name without a sheet is renamed where it is.
        s.renameTag(try XCTUnwrap(tag(s, "Old Pellow")), to: "Pellow")
        XCTAssertEqual(cellTags(s), ["Thomas", "Pellow"])
        XCTAssertEqual(s.bible.entries.filter { !$0.isFile }.count, 1)
    }

    func testMovingASheetKeepsTheLink() throws {
        let s = try book()
        let sheet = try XCTUnwrap(s.bible.entry(named: "Tom"))
        // A second sheet of the same name: only the path tells them apart.
        try s.bible.create(title: "Tom", kind: .place)
        let folder = try XCTUnwrap(s.newBibleFolder(named: "Famille", in: sheet.folder))
        let moved = try XCTUnwrap(s.moveBibleEntry(sheet.path, toFolder: folder))
        XCTAssertNotEqual(moved, sheet.path)
        XCTAssertEqual(tag(s, "Tom")?.sheet, moved)
        XCTAssertEqual(PlotGrid.load(s.root).tags.first { $0.name == "Tom" }?.sheet, moved, "saved with the move")
        XCTAssertEqual(cellTags(s), ["Tom", "Old Pellow"])

        var grid = s.plot
        XCTAssertTrue(grid.retarget { $0 == moved ? "elsewhere/tom.md" : $0 })
        XCTAssertEqual(grid.tags.first { $0.name == "Tom" }?.sheet, "elsewhere/tom.md")
    }

    func testATagGivenASheetHandsItItsAliasesAndASheetGoneFreesTheTag() throws {
        let s = try book()
        let pellow = try XCTUnwrap(tag(s, "Old Pellow"))
        let sheet = try s.bible.sheet(for: pellow)
        XCTAssertEqual(sheet.aliases, ["Pellow"])
        XCTAssertEqual(tag(s, "Old Pellow")?.sheet, sheet.path)
        XCTAssertEqual(tag(s, "Old Pellow")?.aliases, [], "the sheet is where its aliases are written now")
        XCTAssertEqual(tag(s, "Old Pellow")?.allAliases, ["Pellow"])
        XCTAssertTrue(s.bible.tagsWithoutSheet(s.plot).isEmpty)

        try s.bible.trash(sheet.path)
        XCTAssertNil(tag(s, "Old Pellow")?.sheet)
        XCTAssertEqual(s.bible.tagsWithoutSheet(s.plot).map(\.name), ["Old Pellow"])
        XCTAssertEqual(cellTags(s), ["Tom", "Old Pellow"])
    }

    /// Two names of the grid that one sheet answers to (a name and a nickname the reading listed apart) stay two.
    func testTwoTagsOfOneSheetAreNotMergedBehindTheAuthorsBack() throws {
        let s = try book()
        s.plot.index = s.plot.tags + [.init(name: "Tommy", column: "characters", by: "claude")]
        s.bindPlot()
        XCTAssertEqual(tag(s, "Tommy")?.sheet, tag(s, "Tom")?.sheet)
        XCTAssertNotNil(tag(s, "Tom"))
        XCTAssertTrue(s.bible.tagsWithoutSheet(s.plot).map(\.name) == ["Old Pellow"])
    }
}
