import XCTest
@testable import Musset

@MainActor
final class ChatActionTests: XCTestCase {
    func testScoresAndBlocks() {
        let reply = """
        Le chapitre tient, mais la fin explique.

        ```notes
        [{"quote": "C’était heureux, c’était bleu.", "kind": "critique", "note": "[Langue] nomme l’émotion"}]
        ```

        ```scores
        {"criteria": [{"name": "Nécessité", "score": 17, "max": 20, "comment": "réelle"}, {"name": "Langue", "score": 15, "max": 20}],
         "total": 78, "max": 100, "threshold": 80, "eliminatory": []}
        ```
        """
        XCTAssertEqual(stripMachineBlocks(reply), "Le chapitre tient, mais la fin explique.")
        XCTAssertEqual(ChatModel.noteBlocks(in: reply).count, 1)
    }

    /// While the reply streams, an unfinished block shows what is being done, never its JSON.
    func testUnfinishedBlocksShowProgress() {
        let streaming = """
        Le chapitre tient.

        ```notes
        [{"quote": "Il avait la meilleure du marché.", "kind": "praise", "note": "[Maîtrise] …"},
         {"quote": "Le sac plastique Decathlon se remplissait de billets.", "kind": "pr
        """
        let shown = stripMachineBlocks(streaming)
        XCTAssertFalse(shown.contains("quote"))
        XCTAssertTrue(shown.hasPrefix("Le chapitre tient."))
        XCTAssertTrue(shown.hasSuffix("*") && shown.contains("2"), shown)
        XCTAssertFalse(stripMachineBlocks("Bien.\n\n```scores\n{\"criteria\": [").contains("criteria"))
        // A block fenced ```json is still the notes.
        let json = "Vu.\n\n```json\n[{\"quote\": \"Il avait la meilleure du marché.\", \"kind\": \"praise\", \"note\": \"x\"}]\n```"
        XCTAssertEqual(stripMachineBlocks(json), "Vu.")
        XCTAssertEqual(ChatModel.noteBlocks(in: json).count, 1)
    }

    func testPromptsUseTheRubricAndAnnotate() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("musset-act-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".musset"), withIntermediateDirectories: true)
        try "# Un\n\nTexte.\n".write(to: root.appendingPathComponent("01.md"), atomically: true, encoding: .utf8)
        let manifest = BookManifest(title: "T", chapters: [ChapterEntry(id: "01", file: "01.md", title: "Un"), ChapterEntry(id: "02", file: "02.md", title: "Deux")])
        try BookStore(root: root).saveManifest(manifest)
        let session = BookSession(root: root, manifest: manifest)
        // Nothing is written into the book at open: the old Markdown rubric is only read, where a book still has one.
        XCTAssertNil(Rubric.load(root))
        XCTAssertTrue(ChatAction.continuity.prompt(book: session, selection: "").contains("`02.md`"))
        XCTAssertTrue(ChatAction.style.prompt(book: session, selection: "un passage").contains("Work only on the passage"))
    }

    /// Live: « Critique (rubric) » on 03_nice with Claude Haiku: a blind reading lands in the chat, its notes in the chapter. MUSSET_LIVE=1.
    func testLiveCritique() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MUSSET_LIVE"] == "1")
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("fixtures/conatus")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("musset-crit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".musset"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.copyItem(at: fixture.appendingPathComponent("03_nice.md"), to: root.appendingPathComponent("03_nice.md"))
        let manifest = BookManifest(title: "Le Sel", chapters: [ChapterEntry(id: "03_nice", file: "03_nice.md", title: "Nice")])
        try BookStore(root: root).saveManifest(manifest)
        let session = BookSession(root: root, manifest: manifest)
        session.open("03_nice")
        let chat = ChatModel()
        chat.attach(root)
        let start = Date()
        chat.runAction(.critique, session: session, selection: "", model: ProcessInfo.processInfo.environment["MUSSET_LIVE_MODEL"] ?? "haiku")
        while Date().timeIntervalSince(start) < 420 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            if !chat.reader.running { break }
        }
        if let e = chat.reader.lastError { print("CRIT error: \(e)") }
        let reply = try XCTUnwrap(chat.messages.last { $0.role == .assistant })
        let reading = try XCTUnwrap(reply.reading)
        print("CRIT \(Int(Date().timeIntervalSince(start)))s total \(reading.total), unverified \(reading.scores.filter(\.unverified).count), notes \(reply.notesAdded ?? -1)")
        print("CRIT overview: \(reply.text)")
        for a in reading.axes { print("CRIT axis \(a.title) [\(a.criterionId ?? "") +\(reading.gain(a.criterionId ?? "") ?? 0)] \(a.why) >> \(a.direction) «\(a.quote ?? "")»") }
        print("CRIT keep: \(reading.advice?.keep ?? "")")
        for s in reading.scores { print("CRIT \(s.criterionId) \(s.score)/20 reservation=\(s.reservation != nil) strength=\(s.strength != nil)") }
        for n in session.notes.ordered.prefix(6) { print("CRIT   \(n.kind) «\(n.anchor.quote.prefix(50))» — \(n.body.prefix(110))") }
        XCTAssertEqual(Reading.load(root, "03_nice").count, 1)
        XCTAssertTrue(ScoreHistory.load(root, "03_nice").isEmpty, "nothing in the former history")
        XCTAssertGreaterThan(reply.notesAdded ?? 0, 0)
    }
}

@MainActor
final class WritingPartnerTests: XCTestCase {
    func testEveryAIPromptForbidsRewrites() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("musset-wp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "# Un\n\nTexte.\n".write(to: root.appendingPathComponent("01.md"), atomically: true, encoding: .utf8)
        let session = BookSession(root: root, manifest: BookManifest(title: "T", chapters: [ChapterEntry(id: "01", file: "01.md", title: "Un")]))
        for action in ChatAction.allCases {
            XCTAssertTrue(action.prompt(book: session, selection: "").contains("not a ghostwriter"), action.rawValue)
        }
        XCTAssertTrue(Annotator.prompt(task: .critique, custom: "", root: URL(fileURLWithPath: "/tmp"), book: "T", chapter: "Un", text: "x", agents: "").contains("not a ghostwriter"))
    }

    /// Live: asked outright to rewrite, the agent critiques instead. MUSSET_LIVE=1.
    func testLiveRefusesToRewrite() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MUSSET_LIVE"] == "1")
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("fixtures/conatus/03_nice.md")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("musset-wp2-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixture, to: root.appendingPathComponent("03_nice.md"))
        let session = BookSession(root: root, manifest: BookManifest(title: "Le Sel", chapters: [ChapterEntry(id: "03_nice", file: "03_nice.md", title: "Nice")]))
        let chat = ChatModel()
        chat.attach(root)
        chat.input = "Réécris le premier paragraphe pour qu'il soit plus fort."
        chat.send(session: session, selection: "", model: "haiku")
        let start = Date()
        while Date().timeIntervalSince(start) < 120 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            if !chat.running, chat.messages.contains(where: { $0.role == .assistant && !$0.text.isEmpty }) { break }
        }
        let reply = try XCTUnwrap(chat.messages.last { $0.role == .assistant }).text
        print("PARTNER reply:\n\(reply)")
        XCTAssertFalse(reply.contains("```revision"))
    }
}
