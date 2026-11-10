import XCTest
@testable import Musset

@MainActor
final class HistoryTests: XCTestCase {
    func testASentenceCutComesOutAsARemovalWithItsSurroundings() throws {
        let old = "# T\nLa porte du fond. Le froid imbibait les murs du couloir. Il a toussé.\nFin."
        let new = "# T\nLa porte du fond. Il a toussé.\nFin."
        let c = try XCTUnwrap(TextDiff.changes(old: old, new: new).first)
        XCTAssertEqual(TextDiff.changes(old: old, new: new).count, 1)
        XCTAssertEqual(c.kind, .removed)
        XCTAssertEqual(c.old.trimmingCharacters(in: .whitespaces), "Le froid imbibait les murs du couloir.")
        guard case .exact(let r, let text) = TextRestore.undo(c, in: new) else { return XCTFail("the surroundings are all there") }
        XCTAssertEqual((new as NSString).replacingCharacters(in: r, with: text), old, "it goes back exactly, spaces too")
    }

    func testAWordChangedAndAParagraphAdded() throws {
        let cs = TextDiff.changes(old: "Il marchait sans se retourner.\nFin.", new: "Il avançait sans se retourner.\nFin.\nClara n’a rien répondu.")
        XCTAssertEqual(cs.map(\.kind), [.modified, .added])
        XCTAssertEqual(cs[0].old, "marchait")
        XCTAssertEqual(cs[0].new, "avançait")
        XCTAssertEqual(cs[1].new, "Clara n’a rien répondu.\n")
        guard case .exact(let r, let t) = TextRestore.undo(cs[0], in: "Il avançait sans se retourner.\nFin.") else { return XCTFail() }
        XCTAssertEqual(("Il avançait sans se retourner.\nFin." as NSString).replacingCharacters(in: r, with: t), "Il marchait sans se retourner.\nFin.")
    }

    func testWhenTheTextAroundChangedTheAuthorChooses() throws {
        let c = TextChange(kind: .removed, old: "Le froid imbibait les murs.\n", new: "", before: "…la porte du fond.\n", after: "Il a toussé.", paragraph: 1)
        guard case .choose(let places, _) = TextRestore.undo(c, in: "Tout a changé ici.\nIl a toussé.\nFin.") else { return XCTFail() }
        XCTAssertTrue(places.first?.hint.contains("Il a toussé") == true, "it says why")
        XCTAssertLessThanOrEqual(places.count, 3)
        XCTAssertEqual(TextRestore.undo(c, in: "Ailleurs.\nLe froid imbibait les murs.\nFin."), .alreadyThere)
    }

    private func book(_ text: String) throws -> BookSession {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try text.write(to: root.appendingPathComponent("01.md"), atomically: true, encoding: .utf8)
        try "# Deux\n\nAutre chapitre.\n".write(to: root.appendingPathComponent("02.md"), atomically: true, encoding: .utf8)
        let m = BookManifest(title: "T", chapters: [ChapterEntry(id: "01", file: "01.md", title: "Un"), ChapterEntry(id: "02", file: "02.md", title: "Deux")])
        try BookStore(root: root).saveManifest(m)
        try GitService(root: root).initRepo()
        let s = BookSession(root: root, manifest: m)
        s.pendingCommit = true
        s.commitNow("musset: first")
        return s
    }

    func testThePhraseThatNoLongerExistsIsFound() throws {
        let s = try book("# Un\n\nLe froid imbibait les murs. Il a toussé.\n")
        s.replaceText(s.text.replacingOccurrences(of: "imbibait", with: "gagnait")); s.commitNow("musset: edit")
        s.replaceText("# Un\n\nIl a toussé.\n"); s.commitNow("musset: edit")
        let events = s.historyReader.phrase("le froid", chapter: "01", file: "01.md")
        XCTAssertEqual(events.map(\.kind), [.written, .changed, .removed])
        XCTAssertTrue(events[2].text.contains("gagnait"), "the last words it had")
        XCTAssertEqual(s.historyReader.phrase("FROID IMBIBAIT", chapter: "01", file: "01.md").first?.kind, .written, "case and accents don't matter")
        XCTAssertEqual(s.historyReader.phrase("jamais écrit", chapter: "01", file: "01.md"), [])
    }

    func testAPassageShowsItsStates() throws {
        let s = try book("# Un\n\nLe froid imbibait les murs du long couloir.\n\nAutre chose qui ne bouge pas.\n")
        s.replaceText(s.text.replacingOccurrences(of: "imbibait", with: "gagnait")); s.commitNow("musset: edit")
        let states = s.historyReader.states(of: "Le froid gagnait les murs du long couloir.", file: "01.md")
        XCTAssertEqual(states.map(\.text), ["Le froid gagnait les murs du long couloir.", "Le froid imbibait les murs du long couloir."])
    }

    func testCommitsCloseTogetherAreOneSitting() {
        func c(_ id: String, _ minutes: Double) -> GitService.Commit { .init(id: id, date: Date(timeIntervalSince1970: minutes * 60), subject: "") }
        let s = HistoryReader.sittings(["01": [c("d", 300), c("c", 290), c("a", 10)], "02": [c("e", 295), c("b", 12)]])
        XCTAssertEqual(s.map(\.tip.id), ["d", "b"])
        XCTAssertEqual(s[0].chapters, ["01", "02"])
        XCTAssertEqual(s[0].base, "a", "what the sitting started from")
        XCTAssertNil(s[1].base)
    }

    func testGoingBackAddsACommitAndAMilestoneAndErasesNothing() throws {
        let s = try book("# Un\n\nPremier état.\n")
        let first = try XCTUnwrap(s.git.resolve("HEAD"))
        s.replaceText("# Un\n\nDeuxième état, bien plus long que le premier.\n"); s.commitNow("musset: edit")
        let second = try XCTUnwrap(s.git.resolve("HEAD"))
        XCTAssertLessThan(s.goBackPreview(to: first, chapters: ["01"]).words, 0)
        s.goBack(to: first, label: "hier", chapters: ["01"], order: false)
        XCTAssertTrue(s.text.contains("Premier état"))
        XCTAssertNotEqual(s.git.resolve("HEAD"), first, "a new commit")
        XCTAssertTrue(s.git.isAncestor(second, of: "HEAD"), "today's text stays in the line")
        XCTAssertTrue(s.jalons.contains { $0.title.contains("hier") }, "a milestone first")
    }

    func testBringingASittingChoosesWhatItChangedAndKeepsWhatCameAfter() throws {
        let s = try book("# Un\n\nPremier.\n\nDeuxième.\n")
        let base = try XCTUnwrap(s.git.resolve("HEAD"))
        s.replaceText("# Un\n\nPremier.\n\nDeuxième repris.\n"); s.commitNow("musset: edit")
        let tip = try XCTUnwrap(s.git.resolve("HEAD"))
        s.replaceText("# Un\n\nPremier revu.\n\nDeuxième.\n"); s.commitNow("musset: edit")
        let chapters = s.prepareBring(rev: tip, base: base)
        XCTAssertEqual(chapters.map(\.id), ["01"])
        let picks = Dictionary(uniqueKeysWithValues: chapters[0].blocks.compactMap { b in b.suggested.map { (b.id, $0) } })
        let out = ParagraphMerge.result(chapters[0].blocks, picks: picks)
        XCTAssertTrue(out.contains("Deuxième repris."), out)
        XCTAssertTrue(out.contains("Premier revu."), "what came after stays: " + out)
        s.applyBring(["01": out], message: "musset: bring")
        XCTAssertEqual(s.text, out)
        // A state, without a base: nothing changes unless the author picks.
        let plain = s.prepareBring(rev: base, base: nil)
        XCTAssertTrue(plain[0].blocks.filter(\.isChange).allSatisfy { $0.suggested == .mine })
    }
}
