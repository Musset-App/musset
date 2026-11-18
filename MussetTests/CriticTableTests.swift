import XCTest
@testable import Musset

@MainActor
final class CriticTableTests: XCTestCase {
    private var root: URL!
    override func setUp() { root = FileManager.default.temporaryDirectory.appendingPathComponent("musset-table-\(UUID())") }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private func record(_ kind: CriticTableRecord.Kind, _ critics: [Critic]) -> CriticTableRecord {
        CriticTableRecord(id: "t", kind: kind, title: "Nice", critics: critics, agent: .claude, model: "", context: "LE TEXTE")
    }
    private let a = Critic(id: "a", name: "Ana", horizon: "x"), b = Critic(id: "b", name: "Bea", horizon: "y")

    private struct Call { var who: String; var prompt: String; var session: String? }

    /// A fake voice answering at once, recording what each voice was told.
    private func table(_ r: CriticTableRecord, failResumeOnce: Bool = false) -> (CriticTable, () -> [Call]) {
        var calls: [Call] = []
        var failed = false
        let t = CriticTable(record: r, root: root) { _, prompt, session, _, _, system, onEvent, onDone in
            let who = r.critics.first { system.contains("« \($0.name) »") }?.id ?? r.critics[0].id
            calls.append(Call(who: who, prompt: prompt, session: session))
            if failResumeOnce, session != nil, !failed {
                failed = true
                onDone(1, "no session")
                return nil
            }
            onEvent(.session("s-\(who)"))
            onEvent(.textDelta("réponse \(calls.count)"))
            onDone(0, "")
            return nil
        }
        return (t, { calls })
    }

    private func settle(_ t: CriticTable) async {
        for _ in 0..<200 where t.running { try? await Task.sleep(nanoseconds: 5_000_000) }
    }

    func testEachGivesTheirViewAloneThenTheyArgue() async {
        let (t, calls) = table(record(.debate, [a, b]))
        t.openDebate()
        await settle(t)
        XCTAssertEqual(calls().map(\.who), ["a", "b", "a", "b"])
        XCTAssertEqual(t.record.turns.map(\.critic), ["a", "b", "a", "b"])
        XCTAssertEqual(t.record.turns.map { $0.opening == true }, [true, true, false, false])
        // The views are given blind, with the text.
        XCTAssertTrue(calls()[1].prompt.contains("LE TEXTE"))
        XCTAssertFalse(calls()[1].prompt.contains("Ana :"))
        // Then each hears what the others said, never again the text, never their own words.
        XCTAssertEqual(calls()[2].session, "s-a")
        XCTAssertFalse(calls()[2].prompt.contains("LE TEXTE"))
        XCTAssertTrue(calls()[2].prompt.contains("Bea : réponse 2"))
        XCTAssertFalse(calls()[2].prompt.contains("Ana :"))
        XCTAssertTrue(calls()[3].prompt.contains("Ana : réponse 1"))
        XCTAssertTrue(calls()[3].prompt.contains("Ana : réponse 3"))

        t.say("Et la fin ?")
        await settle(t)
        XCTAssertEqual(calls().count, 6)
        XCTAssertTrue(calls()[4].prompt.contains("L’auteur : Et la fin ?") || calls()[4].prompt.contains("The author : Et la fin ?"), calls()[4].prompt)
        XCTAssertFalse(calls()[4].prompt.contains("Ana : réponse 1"), "already heard")
        XCTAssertEqual(CriticTableRecord.load(root, "t")?.turns.count, 7, "kept on disk")
    }

    func testReaderAnswersOnlyWhenSpokenTo() async {
        let (t, calls) = table(record(.reader, [a]))
        XCTAssertTrue(calls().isEmpty)
        t.say("Pourquoi 2,8 en densité ?")
        await settle(t)
        XCTAssertEqual(calls().count, 1)
        XCTAssertTrue(calls()[0].prompt.contains("LE TEXTE"))
        XCTAssertEqual(t.record.turns.map(\.critic), [nil, "a"])
    }

    func testALostSessionStartsAgainWithEverything() async {
        var r = record(.debate, [a, b])
        r.sessions["a"] = "gone"
        r.heard["a"] = 0
        r.turns = [.init(critic: "b", text: "Déjà dit.")]
        let (t, calls) = table(r, failResumeOnce: true)
        t.anotherRound()
        await settle(t)
        XCTAssertNil(t.lastError)
        XCTAssertEqual(calls()[0].session, "gone")
        XCTAssertNil(calls()[1].session)
        XCTAssertTrue(calls()[1].prompt.contains("LE TEXTE"))
        XCTAssertTrue(calls()[1].prompt.contains("Déjà dit."))
    }

    /// Each first view ends with its stars; the line is shown as stars, not as text.
    func testFirstViewsGiveStars() {
        let r = CriticTableRecord.rating(in: "Ça tient.\n\n★ 4/5\n")
        XCTAssertEqual(r.stars, 4)
        XCTAssertEqual(r.text, "Ça tient.")
        XCTAssertEqual(CriticTableRecord.rating(in: "Note : 2/5").stars, 2)
        XCTAssertNil(CriticTableRecord.rating(in: "Le chapitre 3/5 du livre tient, sans plus.").stars)
        XCTAssertNil(CriticTableRecord.rating(in: "Rien.").stars)
        var rec = record(.debate, [a, b])
        rec.turns = [.init(critic: "a", text: "Oui.\n★ 5/5", opening: true), .init(critic: "b", text: "Non.\n★ 2/5", opening: true),
                     .init(critic: "a", text: "Je maintiens. ★ 1/5")]
        XCTAssertEqual(rec.stars(of: "a"), 5, "only the first view counts")
        XCTAssertEqual(rec.meanStars, 3.5)
        XCTAssertTrue(rec.prompt(for: a, opening: true).contains("★ 3/5"))
    }

    /// A draft is judged as one: the voices are told so, once, with the text.
    func testTheStageReachesTheVoices() {
        var rec = record(.debate, [a, b])
        XCTAssertFalse(rec.prompt(for: a, opening: true).contains("first draft"))
        rec.stage = .draft
        XCTAssertTrue(rec.prompt(for: a, opening: true).contains("first draft"))
        rec.sessions["a"] = "s"
        XCTAssertFalse(rec.prompt(for: a).contains("first draft"), "said once, with the text")
        XCTAssertNil(CriticTableRecord.Stage.finished.instruction)
    }

    func testTheRewriteRuleHoldsAtEveryTable() {
        for kind in [CriticTableRecord.Kind.reader, .debate] {
            XCTAssertTrue(record(kind, [a, b]).system(for: a).contains(WritingPartner.noRewrites))
        }
        XCTAssertTrue(record(.debate, [a, b]).system(for: a).contains("imagined"))
        XCTAssertEqual(Set(Critic.panel.map(\.id)).count, Critic.panel.count)
        XCTAssertEqual(ChatAction.allCases.first, .critique)
    }
}
