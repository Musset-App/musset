import XCTest
@testable import Musset

/// The synopsis and the plan: planned chapters, and the debate that judges the book against them.
@MainActor
final class SynopsisPlanTests: XCTestCase {
    private func book() throws -> BookSession {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("musset-plan-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try "# The Ferry\n\nNora crossed. Nora waited. Nora, Nora, Nora.".write(to: root.appendingPathComponent("01.md"), atomically: true, encoding: .utf8)
        try "# The Salt Works\n\nNora found Tom on the roof.".write(to: root.appendingPathComponent("02.md"), atomically: true, encoding: .utf8)
        var m = BookManifest(title: "Salt", chapters: [ChapterEntry(id: "01", file: "01.md", title: "The Ferry"),
                                                       ChapterEntry(id: "02", file: "02.md", title: "The Salt Works")])
        m.lang = "en"
        try BookStore(root: root).saveManifest(m)
        try GitService(root: root).initRepo()
        return BookSession(root: root, manifest: m)
    }

    func testPlannedChaptersBecomeRealOnes() throws {
        let s = try book()
        s.addPlanned("The Drying Room")
        let id = try XCTUnwrap(s.plot.planned?.first?.id)
        s.updatePlanned(id, synopsis: "She finds the deed.")
        XCTAssertEqual(PlotGrid.load(s.root).planned?.first?.synopsis, "She finds the deed.", "kept in plot.json")
        XCTAssertEqual(s.manifest.chapters.count, 2, "a planned chapter is not in the manifest")

        s.startWriting(id)
        XCTAssertNil(s.plot.planned)
        let new = try XCTUnwrap(s.manifest.chapters.last)
        XCTAssertEqual(new.title, "The Drying Room")
        XCTAssertEqual(s.plot.chapterSynopsis(new.id), "She finds the deed.")
        XCTAssertEqual(s.selectedChapterID, new.id)
    }

    func testTheDebateReadsThePlan() throws {
        let s = try book()
        XCTAssertNil(s.planForDebate, "no plan, nothing added")
        s.plot.synopsis = "Nora crosses to tell Tom their father died."
        s.plot.setChapterSynopsis("01", "The crossing.")
        s.addPlanned("Low Water")
        let plan = try XCTUnwrap(s.planForDebate)
        XCTAssertTrue(plan.contains("Nora crosses to tell Tom"))
        XCTAssertTrue(plan.contains("« The Ferry » (écrit) — The crossing."))
        XCTAssertTrue(plan.contains("2. « Low Water » (pas encore écrit)"))
        XCTAssertTrue(plan.contains("ne compte jamais contre le livre"))

        let table = s.debateTable(critics: Array(Critic.panel.prefix(2)), chapters: s.manifest.chapters, wholeBook: true,
                                  stage: .finished, agent: .claude, model: "")
        XCTAssertEqual(table.againstPlan, true)
        XCTAssertEqual(table.stage, .incomplete, "chapters still planned: unfinished")
        XCTAssertTrue(table.context.contains("Low Water"))
        XCTAssertTrue(table.prompt(for: table.critics[0], opening: true).contains("Potentiel ★"))
    }

    func testTwoRatingsAndTheOldOne() {
        let both = CriticTableRecord.rating(in: "It holds.\n\nÉcrit ★ 3/5\nPotentiel ★ 4/5\n")
        XCTAssertEqual(both.stars, 3)
        XCTAssertEqual(both.potential, 4)
        XCTAssertEqual(both.text, "It holds.")
        let one = CriticTableRecord.rating(in: "It holds.\n★ 2/5")
        XCTAssertEqual(one.stars, 2)
        XCTAssertNil(one.potential)
        XCTAssertEqual(one.text, "It holds.")
        XCTAssertNil(CriticTableRecord.rating(in: "No rating here.").stars)
    }

    func testTheHintNamesWhoThePlanForgets() async throws {
        let s = try book()
        try s.bible.create(title: "Nora", kind: .character)
        try s.bible.create(title: "Tom", kind: .character)
        s.refreshBibleMentions()
        for _ in 0..<100 where s.bible.writtenChapters == 0 { try? await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNil(s.synopsisHint, "no plan yet, nothing to say")
        s.plot.synopsis = "Tom sells the works."
        XCTAssertTrue(s.synopsisHint?.contains("Nora") == true, s.synopsisHint ?? "nil")
    }
}
