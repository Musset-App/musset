import XCTest
@testable import Musset

final class ScoringTests: XCTestCase {
    private func library() -> ScoringLibrary { .shared }
    private func score(_ id: String, _ s: Int, unverified: Bool = false) -> Reading.Score {
        Reading.Score(criterionId: id, label: id, score: s, anchor: "15", quotes: [], justification: "", unverified: unverified)
    }

    func testLibraryLoads() {
        XCTAssertEqual(library().criteria.filter { $0.polarity == "bonus" }.count, 61)
        XCTAssertEqual(library().presets.count, 13)
        for p in library().presets {
            XCTAssertEqual(p.chapter.items.reduce(0) { $0 + $1.weight }, 100, p.id)
            for i in p.chapter.items {
                XCTAssertEqual(library().criterion(i.criterionId)?.scopes.contains("chapter"), true, i.criterionId)
                XCTAssertEqual(library().criterion(i.criterionId)?.anchors?.count, 4, i.criterionId)
            }
        }
    }

    func testNormalizeIsExactAndWhole() {
        let n = Scoring.normalize(["a": 1, "b": 1, "c": 1, "d": 0])
        XCTAssertEqual(n.values.reduce(0, +), 100)
        XCTAssertNil(n["d"])
        XCTAssertEqual(n["a"], 34, "ties go by name")
    }

    func testTotalLeavesOutWhatIsUnverified() {
        let w = ["a": 50, "b": 50]
        XCTAssertEqual(Scoring.total(weights: w, scores: [score("a", 20), score("b", 10)]), 75)
        XCTAssertEqual(Scoring.total(weights: w, scores: [score("a", 20), score("b", 0, unverified: true)]), 100)
        XCTAssertNil(Scoring.total(weights: w, scores: [score("a", 0, unverified: true)]))
        XCTAssertEqual(Scoring.points(score: 17, weight: 15), 12.75)
    }

    func testMigrationKeepsTheAuthorsRules() throws {
        let b = try XCTUnwrap(Bareme(migrating: "# B\\n\\n**Seuil de travail : 80/100.** En dessous…\\n\\n## Risques éliminatoires\\n\\n- Un ton d’article.".replacingOccurrences(of: "\\n", with: "\n")))
        XCTAssertEqual(b.threshold, 80)
        XCTAssertTrue(b.rules.hasPrefix("## Risques éliminatoires"))
        XCTAssertTrue(b.rules.contains("Un ton d’article"))
        XCTAssertEqual(b.presetId, "litterature-blanche")
        XCTAssertTrue(b.calibration.contains("L'Étranger"))
    }

    func testBaremeRoundTripCarriesItsCriteria() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("musset-bareme-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let b = try XCTUnwrap(Bareme(migrating: nil))
        try b.save(root)
        let back = try XCTUnwrap(Bareme.forBook(root))
        XCTAssertEqual(back.chapter, b.chapter)
        XCTAssertEqual(back.criteria.first { $0.id == "phrase" }?.anchors?["19"], library().criterion("phrase")?.anchors?["19"])
    }

    private func inputs(_ b: Bareme, book: String = "LIVRE ENTIER", previous: Reading.Advice? = nil) -> CritiqueSkill.Inputs {
        .init(bareme: b, criteria: b.chapter.compactMap { b.criterion($0.criterionId) }, title: "T", position: 1, count: 2, book: book, plan: "PLAN", chapter: "Texte du chapitre.",
              previous: previous, changes: "- Nouveau ou modifié : x", margin: "MARGE")
    }

    func testTheSkillShipsAndCarriesEverythingInOnePrompt() throws {
        let raw = CritiqueSkill.template(root: nil)
        XCTAssertFalse(raw.isEmpty)
        XCTAssertFalse(raw.hasPrefix("---"), "the front matter stays out of the prompt")
        let b = try XCTUnwrap(Bareme(migrating: nil))
        let p = CritiqueSkill.render(raw, inputs(b))
        for part in ["LIVRE ENTIER", "PLAN", "Texte du chapitre.", "MARGE", "L'Étranger de Camus vaudrait 90/100", "Ne réécris rien", "\"overview\"", "\"scores\"", "\"notes\""] {
            XCTAssertTrue(p.contains(part), part)
        }
        XCTAssertFalse(p.contains("{{"), "every placeholder is filled")
        XCTAssertFalse(p.contains("\"weight\"") || p.contains("21"), "no weight reaches the reader")
        XCTAssertFalse(p.contains("## Ton dernier avis"), "no memory on a first reading")
    }

    func testTheMemoryHoldsAdviceNeverAScore() throws {
        let b = try XCTUnwrap(Bareme(migrating: nil))
        let previous = Reading.Advice(overview: "Vue passée.", axes: [.init(title: "Axe ancien", why: "w", direction: "d")], keep: "Garder ceci.")
        let p = CritiqueSkill.render(CritiqueSkill.template(root: nil), inputs(b, previous: previous))
        for part in ["## Ton dernier avis", "Axe ancien", "Garder ceci.", "Nouveau ou modifié"] { XCTAssertTrue(p.contains(part), part) }
    }

    func testABookCanCarryItsOwnSkill() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("musset-skill-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent(".musset/skills/bareme-critique")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "---\nname: x\n---\n\nÀ ma façon : {{TITLE}}".write(to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        let b = try XCTUnwrap(Bareme(migrating: nil))
        XCTAssertEqual(CritiqueSkill.render(CritiqueSkill.template(root: root), inputs(b)), "À ma façon : T")
    }

    func testTheBooksOwnBracesAreLeftAlone() throws {
        let b = try XCTUnwrap(Bareme(migrating: nil))
        XCTAssertTrue(CritiqueSkill.render("{{BOOK}}", inputs(b, book: "un {{TITLE}} dans le texte")).contains("{{TITLE}}"))
    }

    func testAQuoteIsFoundThroughTypography() {
        let text = "Il a dit\u{00A0}: l’appartement\nétait vide."
        XCTAssertNotNil(ReadingCheck.locate("dit : l'appartement était vide.", in: text))
        XCTAssertNil(ReadingCheck.locate("l’appartement était plein", in: text))
    }

    func testSixPointsOfSeverityReachTheCeiling() {
        XCTAssertEqual(Scoring.penalty(severities: [3, 3, 2], max: 4), 4)
        XCTAssertEqual(Scoring.penalty(severities: [1], max: 6), 1)
        XCTAssertEqual(Scoring.penalty(severities: [], max: 4), 0)
    }

    func testAPenaltyComesOffTheTotalAndNeverBelowZero() {
        let score = { (id: String, s: Int) in Reading.Score(criterionId: id, label: id, score: s, anchor: "15", quotes: [], justification: "") }
        XCTAssertEqual(Scoring.total(weights: ["a": 50, "b": 50], scores: [score("a", 20), score("b", 10)], penalty: 5), 70)
        XCTAssertEqual(Scoring.total(weights: ["a": 100], scores: [score("a", 1)], penalty: 20), 0)
    }

    func testOnlyAFaultWithItsProofCosts() throws {
        let b = try XCTUnwrap(Bareme(migrating: nil))
        let raw = #"{"scores": [], "maluses": [{"criterionId": "m_cliche", "severity": 3, "quote": "Un texte", "why": "Usé."}, {"criterionId": "m_cliche", "severity": 3, "quote": "Un texte", "why": "Encore."}, {"criterionId": "m_cliche", "severity": 2, "quote": "absent du chapitre", "why": "x"}, {"criterionId": "m_cliche", "severity": 9, "quote": "court", "why": "x"}, {"criterionId": "inconnu", "severity": 1, "quote": "court", "why": "x"}, {"criterionId": "m_repetition", "severity": "1", "quote": "court", "why": "Redit."}]}"#
        let m = ReadingCheck.maluses(try XCTUnwrap(ReadingCheck.parse(raw)?.maluses), bareme: b, text: "Un texte court.")
        XCTAssertEqual(m.map(\.criterionId), ["m_cliche", "m_repetition"])
        XCTAssertEqual(m[0].hits.count, 1)
        XCTAssertEqual(m[0].points, 2, "severity 3 on a ceiling of 4")
        XCTAssertEqual(m[1].points, 0.5, "severity 1 on a ceiling of 3")
    }

    func testAReadingFromBeforeMalusesStillLoads() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("musset-old-reading-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = Reading.url(root, "01")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"[{"agent": "claude", "baremeName": "B", "baremeVersion": 1, "date": "2026-11-03T00:56:16Z", "id": "804D5927-735F-4C1B-881C-DB299C0ECF75", "model": "opus", "risks": [], "scores": [], "textHash": "h", "total": 70, "weights": {}}]"#.write(to: file, atomically: true, encoding: .utf8)
        let r = try XCTUnwrap(Reading.load(root, "01").first)
        XCTAssertNil(r.maluses)
    }

    func testThePromptListsTheFaultsButNotWhatTheyCost() throws {
        var b = try XCTUnwrap(Bareme(migrating: nil))
        b.maluses = [MalusItem(criterionId: "m_cliche", maxPenalty: 77)]
        let p = CritiqueSkill.render(CritiqueSkill.template(root: nil), inputs(b))
        XCTAssertTrue(p.contains("m_cliche — Cliché"))
        XCTAssertTrue(p.contains("Gravité 3 :"))
        XCTAssertFalse(p.contains("77"))
    }

    private let phrase = Criterion(id: "phrase", version: 1, label: "Phrase", family: "langue", polarity: "bonus", definition: "", question: "", scopes: ["chapter"], requiresQuote: true, genreHints: [], builtin: true)

    private func answer(_ s: Int, anchor: String, quote: String, advice: Bool = true) -> String {
        #"Voici : {"scores": [{"criterionId": "phrase", "anchor": "\#(anchor)", "score": \#(s), "quotes": ["\#(quote)"], "justification": "Parce que."}]\#(advice ? #", "overview": "Vue.", "axes": [{"title": "T", "why": "W", "direction": "D", "steps": [{"action": "Couper", "quote": "\#(quote)", "detail": "Cette phrase tombe."}]}], "keep": "K", "notes": []"# : "")}"#
    }

    func testAllComesInOneCallWhenTheAnswerStands() async throws {
        let calls = Calls()
        let r = try await ChapterReader.runSession([phrase], text: "Un texte court.", prompt: "tout") { [self] message, session in
            calls.add(message, session)
            return (answer(14, anchor: "15", quote: "Un texte"), "s1")
        }
        XCTAssertEqual(calls.messages, ["tout"], "book, chapter and instructions go once")
        XCTAssertEqual(r.scores.first?.score, 14)
        XCTAssertEqual(r.advice?.overview, "Vue.")
    }

    func testACorrectionStaysInTheSameSession() async throws {
        let calls = Calls()
        let r = try await ChapterReader.runSession([phrase], text: "Un texte court.", prompt: "tout") { [self] message, session in
            calls.add(message, session)
            return calls.messages.count == 1 ? (answer(18, anchor: "15", quote: "Un texte"), "s1") : (answer(14, anchor: "15", quote: "Un texte", advice: false), nil)
        }
        XCTAssertEqual(calls.messages.count, 2)
        XCTAssertEqual(calls.sessions, [nil, "s1"], "the same session, resumed")
        XCTAssertFalse(calls.messages[1].contains("tout"), "nothing is sent twice")
        XCTAssertEqual(r.scores.first?.score, 14)
        XCTAssertEqual(r.scores.first?.unverified, false)
        XCTAssertEqual(r.advice?.overview, "Vue.", "the advice of the first answer stays")
    }

    func testAnInventedQuoteEndsUnverified() async throws {
        let calls = Calls()
        let r = try await ChapterReader.runSession([phrase], text: "Un texte court.", prompt: "tout") { [self] message, session in
            calls.add(message, session)
            return (answer(14, anchor: "15", quote: "jamais écrit"), "s1")
        }
        XCTAssertEqual(calls.messages.count, 2, "one more chance, no more")
        XCTAssertEqual(r.scores.first?.unverified, true)
    }

    func testMissingAdviceIsAskedForInTheSession() async throws {
        let calls = Calls()
        let r = try await ChapterReader.runSession([phrase], text: "Un texte court.", prompt: "tout") { [self] message, session in
            calls.add(message, session)
            return calls.messages.count == 1 ? (answer(14, anchor: "15", quote: "Un texte", advice: false), "s1") : (#"{"overview": "Vue.", "axes": []}"#, "s1")
        }
        XCTAssertEqual(calls.messages.count, 2)
        XCTAssertEqual(r.advice?.overview, "Vue.")
        XCTAssertEqual(r.scores.count, 1, "the score already given is not given again")
    }

    func testReadingsAreStoredApartFromOldScores() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("musset-reading-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let r = Reading(agent: "claude", model: "opus", textHash: "h", baremeVersion: 1, baremeName: "B", weights: ["a": 100], scores: [score("a", 12)], total: 60)
        try Reading.append(r, root: root, chapter: "01")
        XCTAssertEqual(Reading.load(root, "01").first?.total, 60)
        XCTAssertTrue(ScoreHistory.load(root, "01").isEmpty)
    }

    func testAxesFollowWhatCostsTheMostWhenThereIsNoAdvice() {
        var a = score("small", 10), b = score("big", 10), c = score("free", 10)
        a.suggestion = "Piste a."; b.suggestion = "Piste b."; b.reservation = .init(quote: "x", note: "Pourquoi b.")
        c.suggestion = nil
        var r = Reading(agent: "claude", model: "", textHash: "h", baremeVersion: 1, baremeName: "B", weights: ["small": 10, "big": 40, "free": 50], scores: [a, b, c], total: 50)
        XCTAssertEqual(r.axes.map(\.criterionId), ["big", "small"])
        XCTAssertEqual(r.axes.first?.why, "Pourquoi b.")
        XCTAssertEqual(r.gain("big"), 14)
        r.advice = .init(overview: "Vue.", axes: [.init(title: "Un axe", why: "w", direction: "d")])
        XCTAssertEqual(r.axes.map(\.title), ["Un axe"])
    }

    func testAGestureMustPointAtTheText() throws {
        let raw = #"{"overview": "Vue.", "axes": [{"title": "T", "why": "W", "direction": "D", "steps": [{"action": "Couper", "quote": "absent", "detail": "x"}, {"action": "Déplacer", "quote": "Un texte", "target": "absent aussi", "detail": "y"}]}]}"#
        let a = try XCTUnwrap(CritiqueSkill.advice(in: raw, text: "Un texte court."))
        let steps = try XCTUnwrap(a.advice.axes[0].steps)
        XCTAssertEqual(steps.map(\.action), ["Déplacer"])
        XCTAssertNil(steps[0].target)
    }

    /// An axis without a gesture on the text is asked again, once, and only that axis changes.
    func testAVagueAxisIsAskedAgainOnce() async throws {
        let first = #"{"scores": [{"criterionId": "phrase", "anchor": "15", "score": 14, "quotes": ["Un texte"], "justification": "Parce que."}], "overview": "Vue.", "axes": [{"title": "Vague", "why": "W", "direction": "D"}, {"title": "Net", "why": "W", "direction": "D", "steps": [{"action": "Couper", "quote": "court", "detail": "a"}]}], "keep": "K"}"#
        let second = #"{"axes": [{"title": "Vague", "why": "W2", "direction": "D2", "steps": [{"action": "Condenser", "quote": "Un texte", "detail": "b"}]}]}"#
        let calls = Calls()
        let r = try await ChapterReader.runSession([phrase], text: "Un texte court.", prompt: "p") { message, session in
            calls.add(message, session)
            return (calls.messages.count == 1 ? first : second, "s1")
        }
        XCTAssertEqual(calls.messages.count, 2)
        XCTAssertTrue(calls.messages[1].contains("« Vague »"))
        XCTAssertEqual(r.advice?.axes.map(\.title), ["Vague", "Net"])
        XCTAssertEqual(r.advice?.axes[0].steps?.first?.action, "Condenser")
        XCTAssertEqual(r.advice?.overview, "Vue.")
    }

    func testAnOldReadingIsNotConcrete() {
        var r = Reading(agent: "claude", model: "m", textHash: "h", baremeVersion: 1, baremeName: "b", weights: [:], scores: [], total: 50)
        XCTAssertTrue(r.hasConcreteAdvice, "nothing advised, nothing to redo")
        r.advice = .init(overview: "o", axes: [.init(title: "T", why: "w", direction: "d")])
        XCTAssertFalse(r.hasConcreteAdvice)
    }

    func testAdviceDropsAQuoteThatIsNotInTheText() throws {
        let raw = #"Voici {"overview": "Vue.", "axes": [{"title": "T", "why": "W", "direction": "D", "quote": "absent"}, {"title": "T2", "why": "W", "direction": "D", "quote": "Un texte"}], "keep": "K", "notes": [{"quote": "Un texte", "note": "[Réserve] Phrase : x."}, {"resolves": "abcd1234", "note": "réglé"}]}"#
        let a = try XCTUnwrap(CritiqueSkill.advice(in: raw, text: "Un texte court."))
        XCTAssertNil(a.advice.axes[0].quote)
        XCTAssertEqual(a.advice.axes[1].quote, "Un texte")
        XCTAssertEqual(a.notes.count, 2)
        XCTAssertEqual(a.notes[1].resolves, "abcd1234")
        XCTAssertNil(CritiqueSkill.advice(in: "rien", text: "x"))
    }

    func testChangesSayWhatMoved() {
        XCTAssertEqual(ChapterReader.changes(from: "Un.\nDeux.\n", to: "Un.\nTrois.\n"), "- Retiré ou modifié : Deux.\n- Nouveau ou modifié : Trois.")
        XCTAssertEqual(ChapterReader.changes(from: "Un.\n", to: "Un.\n"), "")
    }

    func testTheConversationHearsTheReadingWithoutScoring() {
        let r = Reading(agent: "claude", model: "", textHash: "h", baremeVersion: 1, baremeName: "B", weights: ["a": 100], scores: [score("a", 12)], total: 60)
        let summary = ChapterReader.summary(of: r, chapter: "Nice")
        XCTAssertTrue(summary.contains("60/100") && summary.contains("Do not give a score"))
    }

}

private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var m: [String] = [], s: [String?] = []
    var messages: [String] { lock.withLock { m } }
    var sessions: [String?] { lock.withLock { s } }
    func add(_ message: String, _ session: String?) { lock.withLock { m.append(message); s.append(session) } }
}

@MainActor
final class BlindReadingNotesTests: XCTestCase {
    private func session() throws -> (BookSession, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("musset-pins-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "Un texte court.\n\nUne autre phrase ici.\n".write(to: root.appendingPathComponent("01.md"), atomically: true, encoding: .utf8)
        try "Le deuxième chapitre.\n".write(to: root.appendingPathComponent("02.md"), atomically: true, encoding: .utf8)
        let s = BookSession(root: root, manifest: BookManifest(title: "T", chapters: [ChapterEntry(id: "01", file: "01.md", title: "Un"), ChapterEntry(id: "02", file: "02.md", title: "Deux")]))
        s.open("01")
        return (s, root)
    }
    private func reading() -> Reading { Reading(agent: "claude", model: "", textHash: "h", baremeVersion: 1, baremeName: "B", weights: [:], scores: [], total: 50) }

    /// Notes stay from one reading to the next: a second reading adds to them, it does not start over.
    func testNotesAccumulateWithoutStacking() throws {
        let (s, root) = try session()
        defer { try? FileManager.default.removeItem(at: root) }
        let items = [Annotator.Item(quote: "Un texte", note: "[Réserve] Phrase : x."), Annotator.Item(quote: "Une autre", note: "[Réussite] Phrase : y.")]
        XCTAssertEqual(ChapterReader.pinNotes(items, of: reading(), chapter: "01", in: s), .init(placed: 2, skipped: 0))
        XCTAssertEqual(ChapterReader.pinNotes([items[0], .init(quote: "phrase ici", note: "[Réserve] Densité : z.")], of: reading(), chapter: "01", in: s), .init(placed: 1, skipped: 1))
        XCTAssertEqual(s.notes.notes.count, 3)
        XCTAssertEqual(ChapterReader.pinNotes(items, of: reading(), chapter: "02", in: s), .none, "another chapter's notes are not loaded")
    }

    func testEachFaultIsPinnedOnItsPassageWithoutLimit() throws {
        let (s, root) = try session()
        defer { try? FileManager.default.removeItem(at: root) }
        let words = ["Un texte", "Une autre", "phrase ici"]
        let malus = Reading.Malus(criterionId: "m_cliche", label: "Cliché", points: 1, hits: words.map { .init(severity: 1, quote: $0, why: "Usé.") })
        let items = ReadingCheck.notes(for: [malus])
        XCTAssertEqual(items.first?.note, "[Malus] Cliché : Usé.")
        XCTAssertEqual(ChapterReader.pinNotes(items, of: reading(), chapter: "01", in: s).placed, 3)
        XCTAssertEqual(ChapterReader.pinNotes(items, of: reading(), chapter: "01", in: s).placed, 0, "a passage already noted gets no second note")
    }

    func testANoteStretchedOverTheChapterBlocksNothing() throws {
        let (s, root) = try session()
        defer { try? FileManager.default.removeItem(at: root) }
        s.textDidChange(String(repeating: "Une phrase assez longue pour remplir le chapitre. ", count: 60))
        let whole = NSRange(location: 0, length: (s.text as NSString).length)
        _ = s.notes.add(range: whole, text: s.text, author: .claude, kind: .fact, body: "x", run: "r")
        s.notes.setStatus(try XCTUnwrap(s.notes.notes.first).id, .resolved)
        XCTAssertFalse(s.notes.blocksNewNote(at: NSRange(location: 10, length: 20), quote: "assez longue pour"))
    }

    func testTheEditorCanCloseAnOpenNote() throws {
        let (s, root) = try session()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = ChapterReader.pinNotes([.init(quote: "Un texte", note: "[Réserve] Phrase : x.")], of: reading(), chapter: "01", in: s)
        let note = try XCTUnwrap(s.notes.notes.first)
        let id = String(note.id.uuidString.prefix(8)).lowercased()
        XCTAssertEqual(ChapterReader.pinNotes([.init(note: "Réglé.", resolves: id)], of: reading(), chapter: "01", in: s), .init(placed: 0, skipped: 0, resolved: 1))
        XCTAssertEqual(s.notes.notes.first?.status, .resolved)
    }

    /// The reader has the whole book, except the chapter it is reading, given apart.
    func testTheBookIsGivenWholeBelowTheLimit() throws {
        let (s, root) = try session()
        defer { try? FileManager.default.removeItem(at: root) }
        let book = ChapterReader.bookContext(s, chapter: "01")
        XCTAssertTrue(book.contains("Le deuxième chapitre."))
        XCTAssertFalse(book.contains("Un texte court."))
        XCTAssertFalse(ChapterReader.bookContext(s, chapter: "01", limit: 5).contains("Le deuxième chapitre."), "past the limit, the plan stands in")
    }

    /// The same text is not read twice; a changed one is. MUSSET_LIVE_STABILITY=<chapter id in fixtures/conatus> prints two readings of one text.
    func testLiveStability() throws {
        guard let id = ProcessInfo.processInfo.environment["MUSSET_LIVE_STABILITY"] else { throw XCTSkip("set MUSSET_LIVE_STABILITY") }
        let fm = FileManager.default
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("fixtures/conatus")
        let root = fm.temporaryDirectory.appendingPathComponent("musset-stable-\(UUID().uuidString)")
        try fm.createDirectory(at: root.appendingPathComponent(".musset"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        for item in ["book.json", "plot.json", "notes", "bareme.json"] { try fm.copyItem(at: fixture.appendingPathComponent(".musset/\(item)"), to: root.appendingPathComponent(".musset/\(item)")) }
        let manifest = try BookStore(root: root).loadManifest()
        for ch in manifest.chapters { try? fm.copyItem(at: fixture.appendingPathComponent(ch.file), to: root.appendingPathComponent(ch.file)) }
        let s = BookSession(root: root, manifest: manifest)
        s.open(id)
        print("STABLE book \(ChapterReader.bookContext(s, chapter: id).count) chars")
        let reader = ChapterReader()
        let engine: AgentKind = ProcessInfo.processInfo.environment["MUSSET_LIVE_ENGINE"] == "codex" ? .codex : .claude
        for pass in 1...(Int(ProcessInfo.processInfo.environment["MUSSET_LIVE_PASSES"] ?? "") ?? 2) {
            let start = Date()
            var result: ChapterReader.PinResult?
            reader.read(s, engine: engine, model: engine == .claude ? "opus" : "", force: true) { _, _, pins in result = pins }
            while reader.running, Date().timeIntervalSince(start) < 500 { RunLoop.main.run(until: Date().addingTimeInterval(0.5)) }
            if let e = reader.lastError { print("STABLE error \(e)") }
            let r = try XCTUnwrap(Reading.load(root, id).last)
            print("STABLE pass \(pass) \(Int(Date().timeIntervalSince(start)))s total \(r.total) notes \(String(describing: result))")
            print("STABLE scores " + r.scores.map { "\($0.criterionId) \($0.score)" }.joined(separator: ", "))
            print("STABLE overview \(r.advice?.overview ?? "none")")
            for m in r.maluses ?? [] { print("STABLE malus \(m.label) -\(m.points) " + m.hits.map { "[\($0.severity)] \($0.quote) >> \($0.why)" }.joined(separator: " | ")) }
            for a in r.advice?.axes ?? [] {
                print("STABLE axis \(a.title) >> \(a.why) >> \(a.direction)")
                for st in a.steps ?? [] { print("STABLE   \(st.action) « \(st.quote) »\(st.target.map { " → « \($0) »" } ?? "") : \(st.detail)") }
            }
        }
    }
}
