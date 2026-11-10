import XCTest
@testable import Musset

/// The author's own rules, checked by the AI: a library shared by books, notes in the margin, the text untouched.
@MainActor
final class CheckerTests: XCTestCase {
    private var root: URL!
    private var library: URL!
    private var savedFolder: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("musset-checkers-\(UUID().uuidString)")
        root = base.appendingPathComponent("book")
        library = base.appendingPathComponent("library")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        savedFolder = CheckerLibrary.folder
        CheckerLibrary.folder = library
        try "# La Penderie\n\nAgacé, j’ai fini par éteindre le poste. Le bois a commencé à s’effriter.\n\nLe menuisier avait fait du bon boulot.\n"
            .write(to: root.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        CheckerLibrary.folder = savedFolder
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }

    private func session() throws -> BookSession {
        let git = GitService(root: root)
        try git.initRepo()
        let m = BookManifest(title: "Le Sel", chapters: [ChapterEntry(id: "a", file: "a.md", title: "Le Grenier")])
        try BookStore(root: root).saveManifest(m)
        _ = try git.commit(paths: ["a.md", ".musset"], message: "start")
        let s = BookSession(root: root, manifest: m)
        s.open("a")
        return s
    }

    private let rules = Checker(id: "le-sel", name: "Le Sel — règles", rules: "7. Aucune émotion nommée.\n19. Aucun verbe filtre : commencer à.")

    func testAnOutsideRemarkOnAFlaggedPassageJoinsItsNote() {
        let text = "Peut-être on avait perdu la clef, juste un problème."
        let merged = CheckerRunner.merged([CheckerFinding(quote: "Peut-être on avait perdu la clef", comment: "Règle 26.")],
                                          outside: [CheckerFinding(quote: "on avait perdu", comment: "Syntaxe."), CheckerFinding(quote: "un problème", comment: "Autre.")],
                                          in: text, french: true)
        XCTAssertEqual(merged.map(\.comment), ["Règle 26.\nHors règles : Syntaxe.", "Hors règles : Autre."])
    }

    func testTheLibraryKeepsNameAndRulesAsWritten() throws {
        try CheckerLibrary.save(rules)
        XCTAssertEqual(CheckerLibrary.load("le-sel"), rules)
        XCTAssertEqual(CheckerLibrary.all().map(\.name), ["Le Sel — règles"])
        XCTAssertEqual(CheckerLibrary.newID(for: "Le Sel"), "le-sel-2")
        XCTAssertTrue(try String(contentsOf: CheckerLibrary.url("le-sel"), encoding: .utf8).hasPrefix("---\nname: Le Sel — règles\n---\n\n7."))
    }

    func testABookKeepsACopyForAnotherMac() throws {
        try CheckerLibrary.save(rules)
        var book = BookCheckers()
        book.set(rules, on: true)
        try book.save(root)
        try CheckerLibrary.delete("le-sel")
        XCTAssertEqual(BookCheckers.load(root).checkers, [rules], "the library lost it, the book still has it")
        book.set(rules, on: false)
        XCTAssertTrue(book.checkers.isEmpty)
    }

    func testFindingsReadEvenWithFrenchQuotesInside() throws {
        let raw = #"```json {"items": [{"quote": "Agacé", "comment": "Règle 7 (émotion nommée). C'est sans doute voulu : l'humour "noir" du chapitre. Tu le gardes ?", "intended": true, "leads": []}, {"quote": "a commencé à s’effriter", "comment": "Règle 19 (« commencer à »).", "pistes": ["« Le bois s’est effrité. »", "Couper."]}], "outside": [{"quote": "", "comment": "rien"}]} ```"#
        let found = try XCTUnwrap(CheckerPrompt.parse(raw))
        XCTAssertEqual(found.items.count, 2)
        XCTAssertTrue(found.items[0].intended)
        XCTAssertEqual(found.items[1].leads, ["« Le bois s’est effrité. »", "Couper."], "« pistes » is understood too")
        XCTAssertTrue(found.outside.isEmpty, "an outside remark needs a passage")
        XCTAssertEqual(found.items[1].body(french: true), "Règle 19 (« commencer à »).\nPistes :\n– « Le bois s’est effrité. »\n– Couper.")
        XCTAssertFalse(found.items[0].body(french: true).contains("Pistes"))
    }

    func testARunPutsNotesInTheMarginAndLeavesTheText() async throws {
        let s = try session()
        let before = s.text
        var prompts: [String] = []
        s.checks.voice = { prompt in
            prompts.append(prompt)
            return #"{"items": [{"quote": "Agacé", "comment": "Règle 7.", "intended": true, "leads": []}, {"quote": "a commencé à s’effriter", "comment": "Règle 19.", "leads": ["Couper."]}, {"quote": "pas dans le texte", "comment": "Règle 1.", "leads": []}], "outside": [{"quote": "du bon boulot", "comment": "Hors règles."}]}"#
        }
        s.checks.run(rules, session: s, engine: .claude, model: "")
        let deadline = Date().addingTimeInterval(10)
        while s.checks.running != nil && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }

        XCTAssertEqual(s.text, before, "a checker never touches the text")
        let mine = s.notes.notes.filter { $0.source == "Le Sel — règles" }
        XCTAssertEqual(mine.count, 3)
        XCTAssertTrue(mine.contains { $0.body.hasPrefix("Hors règles : ") }, "a remark outside the rules says so")
        XCTAssertEqual(mine.first { $0.anchor.quote.contains("Agacé") }?.kind, .question, "a deliberate breach asks")
        XCTAssertTrue(s.checks.status?.contains("1 passage introuvable") == true, s.checks.status ?? "")
        let prompt = try XCTUnwrap(prompts.first)
        XCTAssertTrue(prompt.contains("19. Aucun verbe filtre"), "the rules go verbatim")
        XCTAssertTrue(prompt.contains("Le menuisier avait fait"))

        // Again: the open notes give way, an answered one stays.
        s.notes.reply(try XCTUnwrap(mine.first { $0.anchor.quote.contains("Agacé") }).id, author: .me, body: "Je le garde.")
        s.checks.run(rules, session: s, engine: .claude, model: "")
        while s.checks.running != nil && Date() < deadline.addingTimeInterval(10) { try await Task.sleep(nanoseconds: 20_000_000) }
        let again = s.notes.notes.filter { $0.source == "Le Sel — règles" }
        XCTAssertEqual(again.count, 4, "3 new ones and the answered one")
        XCTAssertEqual(again.filter { !$0.replies.isEmpty }.count, 1)
    }
}

/// A real run on a copy of a book: MUSSET_CHECKER_BOOK, MUSSET_CHECKER_CHAPTER, MUSSET_CHECKER_ID (in this Mac's library), MUSSET_CHECKER_MODEL.
final class CheckerRealTests: XCTestCase {
    @MainActor
    func testOnARealChapter() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["MUSSET_CHECKER_BOOK"], let chapterID = env["MUSSET_CHECKER_CHAPTER"], let id = env["MUSSET_CHECKER_ID"] else { throw XCTSkip("not set") }
        let book = URL(fileURLWithPath: path)
        let checker = try XCTUnwrap(CheckerLibrary.load(id))
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("musset-checker-real-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: copy) }
        try FileManager.default.createDirectory(at: copy.appendingPathComponent(".musset"), withIntermediateDirectories: true)
        let manifest = try JSONDecoder().decode(BookManifest.self, from: Data(contentsOf: book.appendingPathComponent(".musset/book.json")))
        for ch in manifest.chapters { try FileManager.default.copyItem(at: book.appendingPathComponent(ch.file), to: copy.appendingPathComponent(ch.file)) }
        let plot = (try? JSONDecoder().decode(PlotGrid.self, from: Data(contentsOf: book.appendingPathComponent(".musset/plot.json")))) ?? PlotGrid()
        let chapter = try XCTUnwrap(manifest.chapters.first { $0.id == chapterID })
        let text = BookStore.stripHTMLComments(try String(contentsOf: book.appendingPathComponent(chapter.file), encoding: .utf8))
        let others = manifest.chapters.filter { $0.id != chapterID }.map { "- \($0.title) — `\($0.file)`" }.joined(separator: "\n")
        let prompt = CheckerPrompt.prompt(checker, book: manifest.title, chapter: chapter.title, file: chapter.file, text: text,
                                          people: GrammarArbiter.facts(plot: plot), others: others, french: true)
        let start = Date()
        let raw = try await Agents.oneShot(.claude, prompt: prompt, model: env["MUSSET_CHECKER_MODEL"] ?? "opus", cwd: copy, tools: "Read,Grep,Glob")
        let found = try XCTUnwrap(CheckerPrompt.parse(raw), String(raw.prefix(500)))
        print("SECONDS", Int(Date().timeIntervalSince(start)))
        for f in found.items + found.outside {
            print("FINDING", ReadingCheck.locate(f.quote, in: text) == nil ? "MISSING" : "ok", "«\(f.quote)»")
            print(f.body(french: true).split(separator: "\n").map { "    " + $0 }.joined(separator: "\n"))
        }
        print("COUNT items", found.items.count, "outside", found.outside.count)
    }
}
