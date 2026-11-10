import AppKit
import XCTest
@testable import Musset

/// The LanguageTool bundled in Musset, run on this Mac: no network, no AI.
final class LocalProofTests: XCTestCase {
    private func check(_ text: String, lang: String, words: [String] = []) async throws -> [ProofFix] {
        try await LocalProofreader.check([text], lang: lang, words: words)[0]
    }

    private func find(_ fixes: [ProofFix], _ original: String, file: StaticString = #filePath, line: UInt = #line) throws -> ProofFix {
        try XCTUnwrap(fixes.first { $0.original == original }, "no issue on « \(original) » in \(fixes.map(\.original))", file: file, line: line)
    }

    // MARK: French

    func testFrenchAgreement() async throws {
        let text = "Les enfant sont partis tôt. Elle est allé au marché avec des pomme."
        let fixes = try await check(text, lang: "fr")
        XCTAssertEqual(try find(fixes, "Les enfant").replacement, "Les enfants", "the fix that keeps the author's first word comes first")
        XCTAssertEqual(try find(fixes, "allé").replacement, "allée")
        XCTAssertEqual(try find(fixes, "des pomme").replacement, "des pommes")
        let f = try find(fixes, "Les enfant")
        XCTAssertEqual(f.source, "lt")
        XCTAssertTrue(f.isLanguageTool)                      // blue, never applied automatically
        XCTAssertFalse(f.isObvious)
        XCTAssertEqual(f.checkerName, "LanguageTool")
        XCTAssertEqual(f.anchor, 0)
        XCTAssertNotNil(f.rule)
        XCTAssertFalse(f.message?.isEmpty ?? true)
        XCTAssertTrue(GrammarArbiter.applies(to: f), "agreement waits for the AI's word")
        // The fix locates itself in the paragraph, as the editor does to underline it.
        XCTAssertEqual(f.locate(in: text as NSString), NSRange(location: 0, length: 10))
    }

    /// Musset's typography owns these spaces: the checker stays out of them, dialogue dashes included.
    func testFrenchNonBreakingSpacesAreLeftToTypography() async throws {
        let fixes = try await check("— Il dit : « bonjour » et s’en va ; puis ?", lang: "fr")
        XCTAssertEqual(fixes.map(\.original), [])
    }

    func testForeignSentencesAreNotCheckedAsFrench() async throws {
        let fixes = try await check("— How do you fucking dare to book the cheapest room ? Les enfant sont partis.", lang: "fr")
        XCTAssertEqual(fixes.map(\.original), ["Les enfant"])
    }

    func testEveryLanguageIsChecked() async throws {
        for (lang, text, wrong) in [("de-DE", "Ich habe das Buch gelest.", "gelest"), ("es-ES", "Los niño come manzanas.", "Los niño"),
                                    ("it-IT", "Ero stanco, perche era tardi.", "perche"), ("pt-BR", "Eles vai na escola.", "Eles vai"),
                                    ("pt-PT", "Eles foi ao mercado.", "Eles foi"), ("en-GB", "I like the color.", "color"),
                                    ("de-CH", "Er geht auf die Straße.", "Straße")] {
            let fixes = try await check(text, lang: lang)
            XCTAssertTrue(fixes.contains { $0.original == wrong }, "\(lang): \(fixes.map(\.original))")
        }
        let clean = try await check("Das ist ein ganz normaler Satz ohne Fehler.", lang: "de-DE")
        XCTAssertTrue(clean.isEmpty, "\(clean.map(\.original))")
    }

    // MARK: Typed apostrophes

    @MainActor
    func testApostropheCurlsAsItIsTyped() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("musset-apos-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let (window, tv, proof, bridge) = arbiterEditor(root: root, text: "J")
        let saved = proof.typography
        defer { proof.typography = saved }
        proof.typography = true
        func type(_ s: String) {
            tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
            tv.insertText(s, replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        type("'"); type("ai dit ")
        XCTAssertEqual(tv.string, "J’ai dit ")
        type("'")
        XCTAssertEqual(tv.string, "J’ai dit '", "an opening quote after a space stays as typed")
        proof.typography = false
        tv.string = "l"
        type("'")
        XCTAssertEqual(tv.string, "l'", "typography off: as typed")
        withExtendedLifetime((window, bridge)) {}
    }

    // MARK: Accents, corrected without the AI

    func testAccentOnly() {
        XCTAssertEqual(LocalProofreader.accentOnly("soeur", candidates: ["sœur", "cœur", "sœurs"]), "sœur")
        XCTAssertEqual(LocalProofreader.accentOnly("ecole", candidates: ["école", "écoles"]), "école")
        XCTAssertNil(LocalProofreader.accentOnly("meme", candidates: ["même", "mème", "mémé"]), "several ways to write it")
        XCTAssertNil(LocalProofreader.accentOnly("gallerie", candidates: ["gallérie", "galerie"].filter { $0 == "galerie" }), "not an accent")
        XCTAssertNil(LocalProofreader.accentOnly("card", candidates: ["Card"]), "a capital is not an accent")
    }

    @MainActor
    func testAccentsAreCorrectedWithoutTheAIButNotEnglishWords() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("musset-accents-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let (window, tv, proof, bridge) = arbiterEditor(root: root, text: "Ma sœur va à l’ecole.\n\nIl a écouté le beat de the room avec un debit.\n")
        proof.autoCorrect = true
        proof.chapterOpened()
        let deadline = Date().addingTimeInterval(20)
        while !tv.string.contains("école") && Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertEqual(tv.string, "Ma sœur va à l’école.\n\nIl a écouté le beat de the room avec un debit.\n")
        XCTAssertTrue(proof.corrections.contains { $0.original == "ecole" }, "listed, so the author can see and undo it")
        withExtendedLifetime((window, bridge)) {}
    }

    // MARK: The AI's word on grammar alerts

    @MainActor
    private func arbiterEditor(root: URL, text: String) -> (NSWindow, ZenTextView, AutoProofreader, EditorBridge) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        let tv = ZenTextView(usingTextLayoutManager: false)
        tv.frame = window.contentView!.bounds
        window.contentView!.addSubview(tv)
        let bridge = EditorBridge(), proof = AutoProofreader()
        proof.enabled = true
        bridge.textView = tv; bridge.proof = proof; proof.bridge = bridge; tv.bridge = bridge
        proof.attach(root: root, lang: "fr")
        tv.string = text
        return (window, tv, proof, bridge)
    }

    @MainActor
    func testOnlyConfirmedAlertsAreShown() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("musset-arbiter-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let text = "Les enfant sont partis.\n\nElle a vu des pomme.\n"
        let (window, tv, proof, bridge) = arbiterEditor(root: root, text: text)
        var prompts: [String] = []
        let answered = expectation(description: "the AI was asked")
        proof.arbiterVoice = { prompt in
            prompts.append(prompt)
            answered.fulfill()
            // The first is real, the second isn't.
            return #"[{"id": 1, "real": true}, {"id": 2, "real": false}]"#
        }
        proof.chapterOpened()
        await fulfillment(of: [answered], timeout: 30)
        let deadline = Date().addingTimeInterval(5)
        while proof.issues(in: tv.string).isEmpty && Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }

        XCTAssertEqual(proof.issues(in: tv.string).map(\.fix.original), ["Les enfant"])
        let prompt = try XCTUnwrap(prompts.first)
        XCTAssertTrue(prompt.contains("⟦Les enfant⟧"), prompt)
        XCTAssertTrue(prompt.contains("Elle a vu des"), "the neighbouring paragraph goes with it")

        // The answers outlive the session: nothing is asked twice.
        proof.save()
        let (window2, tv2, again, bridge2) = arbiterEditor(root: root, text: text)
        again.arbiterVoice = { _ in XCTFail("asked again"); return "[]" }
        again.chapterOpened()
        let deadline2 = Date().addingTimeInterval(20)
        while again.issues(in: tv2.string).isEmpty && Date() < deadline2 { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertEqual(again.issues(in: tv2.string).map(\.fix.original), ["Les enfant"])
        withExtendedLifetime((window, window2, bridge, bridge2)) {}
    }

    @MainActor
    func testAlertsShowUncheckedWhenTheAIFails() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("musset-arbiter-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let (window, tv, proof, bridge) = arbiterEditor(root: root, text: "Les enfant sont partis.\n")
        proof.arbiterVoice = { _ in throw NSError(domain: "Musset", code: 127) }
        proof.chapterOpened()
        let deadline = Date().addingTimeInterval(20)
        while proof.issues(in: tv.string).isEmpty && Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertEqual(proof.issues(in: tv.string).map(\.fix.original), ["Les enfant"])
        withExtendedLifetime((window, bridge)) {}
    }

    /// Chapters are only read, never written. MUSSET_PROOF_BOOK points at the book;
    /// MUSSET_ARBITER_REAL=<model> also asks the real AI, in a temporary folder.
    func testOnTheRealBook() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["MUSSET_PROOF_BOOK"] else { throw XCTSkip("MUSSET_PROOF_BOOK not set") }
        let book = URL(fileURLWithPath: path)
        let manifest = try JSONDecoder().decode(BookManifest.self, from: Data(contentsOf: book.appendingPathComponent(".musset/book.json")))
        let plot = (try? JSONDecoder().decode(PlotGrid.self, from: Data(contentsOf: book.appendingPathComponent(".musset/plot.json")))) ?? PlotGrid()
        var items: [GrammarArbiter.Item] = []
        var kinds: [String: Int] = [:]
        var foreign: [String] = []
        var promoted: [ProofFix] = []
        for chapter in manifest.chapters {
            guard let text = try? String(contentsOf: book.appendingPathComponent(chapter.file), encoding: .utf8) else { continue }
            let paragraphs = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("<!--") }
            let results = try await LocalProofreader.check(paragraphs, lang: "fr", words: [])
            for (i, fixes) in results.enumerated() {
                foreign += LocalProofreader.foreignSentences(in: paragraphs[i]).map { (paragraphs[i] as NSString).substring(with: $0) }
                for fix in fixes {
                    kinds[fix.reason, default: 0] += 1
                    let auto = await LocalProofreader.promotingAccents(fix)
                    if auto.isObvious { promoted.append(auto) }
                    if GrammarArbiter.applies(to: fix) {
                        items.append(.init(id: items.count + 1, fix: fix, paragraph: paragraphs[i], before: i > 0 ? paragraphs[i - 1] : "", after: i + 1 < paragraphs.count ? paragraphs[i + 1] : ""))
                    }
                }
            }
        }
        print("KINDS", kinds.sorted { $0.value > $1.value })
        print("FOREIGN", foreign.count)
        for fix in promoted { print("AUTO:", fix.original, "→", fix.replacement) }
        for s in foreign { print("  FOREIGN:", s.prefix(90)) }
        guard let model = env["MUSSET_ARBITER_REAL"] else { return }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("musset-arbiter-real-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // The AI proofreader on a woman's line next to the male narrator, and on the narrator himself.
        if let proofModel = env["MUSSET_PROOF_REAL"] {
            let passage = "« Je suis désolée, c’était un peu déprimant. » Elle m’avait rejoint. « Tu as du feu ? »\n\nLe soir, je suis rentrée seule et je me suis couchée tôt."
            let raw = try await Agents.oneShot(.claude, prompt: Proofreader.prompt(text: passage, lang: "fr", people: GrammarArbiter.facts(plot: plot)), model: proofModel, cwd: dir)
            for fix in await AutoProofreader.decode(raw) { print("PROOF", proofModel, fix.original, "→", fix.replacement, "|", fix.kind ?? "") }
        }
        let raw = try await Agents.oneShot(.claude, prompt: GrammarArbiter.prompt(items: items, facts: GrammarArbiter.facts(plot: plot)), model: model, cwd: dir)
        let verdicts = GrammarArbiter.decode(raw)
        for item in items {
            print("VERDICT", model, verdicts[item.id].map(String.init) ?? "-", item.fix.reason, "|", item.fix.original, "→", item.fix.replacement, "|", item.paragraph.prefix(70))
        }
        // Control: real mistakes, mixed with two of the book's false alerts, in one batch as the app sends them.
        let wrong = ["Les enfant sont partis tôt ce matin-là.", "Ses longs cheveux noir tombaient sur ses épaules.",
                     "Tous les mardi soirs, il allait au cinéma.", "Elle ramassait les pomme tombées dans la cour.",
                     "Il continuait à fumer dès La Paz au quotidien.", "Je veux manger des frites ou aller se promener à manger.",
                     "Ma mère et ma sœur étaient assis à la table.", "Il a acheter une voiture la semaine dernière."]
        var control: [GrammarArbiter.Item] = []
        for sentence in wrong {
            let fixes = try await LocalProofreader.check([sentence], lang: "fr", words: [])[0]
            for fix in fixes where GrammarArbiter.applies(to: fix) {
                control.append(.init(id: control.count + 1, fix: fix, paragraph: sentence, before: "", after: ""))
            }
            if !fixes.contains(where: GrammarArbiter.applies) { print("CONTROL unflagged:", sentence) }
        }
        control += items.prefix(2).enumerated().map { .init(id: control.count + $0.offset + 1, fix: $0.element.fix, paragraph: $0.element.paragraph, before: $0.element.before, after: $0.element.after) }
        let answer = GrammarArbiter.decode(try await Agents.oneShot(.claude, prompt: GrammarArbiter.prompt(items: control, facts: GrammarArbiter.facts(plot: plot)), model: model, cwd: dir))
        for item in control {
            print("CONTROL", model, answer[item.id].map(String.init) ?? "-", item.fix.original, "→", item.fix.replacement, "|", item.paragraph.prefix(60))
        }
    }

    /// Musset's typography owns apostrophes: the checker stays out of them.
    func testFrenchApostrophes() async throws {
        let fixes = try await check("Il entre dans l'école, puis j'ai vu qu'il riait.", lang: "fr")
        XCTAssertTrue(fixes.isEmpty, "\(fixes.map(\.original))")
        let curly = try await check("Il entre dans l’école, puis j’ai vu qu’il riait.", lang: "fr")
        XCTAssertTrue(curly.isEmpty, "\(curly.map(\.original))")
    }

    func testFrenchSpellingAndBookDictionary() async throws {
        let text = "Il marchait dans la ruee avec Chocolatt et son chocolatt."
        let fixes = try await check(text, lang: "fr")
        XCTAssertTrue(try find(fixes, "ruee").choices.contains("rue"))
        XCTAssertFalse(try find(fixes, "ruee").reason.isEmpty)
        XCTAssertFalse(GrammarArbiter.applies(to: try find(fixes, "ruee")), "spelling doesn't wait for the AI")
        XCTAssertTrue(try find(fixes, "chocolatt").choices.contains("chocolat"))
        XCTAssertFalse(fixes.contains { $0.original == "Chocolatt" })     // capitalised: probably a name
        let taught = try await check(text, lang: "fr", words: ["chocolatt"])
        XCTAssertFalse(taught.contains { $0.original == "chocolatt" })
        XCTAssertTrue(taught.contains { $0.original == "ruee" })
    }

    // MARK: English

    func testEnglishGrammarAndSpelling() async throws {
        let fixes = try await check("He go to the store yesterday. This is is a test. I will recieve it.", lang: "en")
        XCTAssertEqual(try find(fixes, "go").replacement, "goes")
        XCTAssertEqual(try find(fixes, "is is").replacement, "is")
        XCTAssertTrue(try find(fixes, "recieve").choices.contains("receive"))
        let f = try find(fixes, "go")
        XCTAssertEqual(f.checkerName, "LanguageTool")
        XCTAssertTrue(f.isLanguageTool)
    }

    /// Ranges must come back in UTF-16 units for NSString, past characters outside the BMP.
    func testEnglishOffsetsAfterEmojiAndAccents() async throws {
        let text = "🙂 Café au lait — he go home."
        let fixes = try await check(text, lang: "en")
        let f = try find(fixes, "go")
        XCTAssertEqual((text as NSString).substring(with: NSRange(location: f.anchor, length: 2)), "go")
    }

    func testEnglishBookDictionary() async throws {
        let text = "The glimmerwick shone over the harbour."
        let flagged = try await check(text, lang: "en")
        XCTAssertTrue(flagged.contains { $0.original == "glimmerwick" }, "\(flagged.map(\.original))")
        let taught = try await check(text, lang: "en", words: ["glimmerwick"])
        XCTAssertFalse(taught.contains { $0.original == "glimmerwick" })
    }

    func testMussetsSixLanguagesOnly() async throws {
        for lang in ["de", "fr-CA", "en-GB", "es-419", "it", "pt-PT"] { XCTAssertTrue(LocalProofreader.supports(lang), lang) }
        XCTAssertFalse(LocalProofreader.supports("nl"))
        let none = try await check("Dit is een test met een fout.", lang: "nl")
        XCTAssertTrue(none.isEmpty)
    }

    // MARK: The book's exceptions

    /// Disabled rules and kept fixes from `.musset/proof-exceptions.json`, and words from `.musset/dictionary.txt`,
    /// hide local issues the same way they hide LanguageTool's.
    @MainActor
    func testBookExceptionsApplyToLocalIssues() async throws {
        let fixes = try await check("Les enfant sont partis. Il entre dans l’école avec son chocolatt. Elle est allé au marché.", lang: "fr")
        let agreement = try find(fixes, "Les enfant"), typo = try find(fixes, "allé")
        let spelling = try find(fixes, "chocolatt")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("musset-local-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".musset"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "chocolatt\n".write(to: root.appendingPathComponent(".musset/dictionary.txt"), atomically: true, encoding: .utf8)
        let exceptions = ["ignored": [agreement.ignoreKey], "disabledRules": [try XCTUnwrap(typo.rule)]]
        try JSONSerialization.data(withJSONObject: exceptions).write(to: root.appendingPathComponent(".musset/proof-exceptions.json"))

        let proof = AutoProofreader()
        proof.attach(root: root, lang: "fr")
        XCTAssertTrue(proof.isSuppressed(agreement))
        XCTAssertTrue(proof.isSuppressed(typo))
        XCTAssertTrue(proof.isSuppressed(spelling))
        let other = try await check("Ils sont allé au marché avec des pomme.", lang: "fr")
        XCTAssertFalse(proof.isSuppressed(try find(other, "des pomme")))
    }

    /// The whole loop with the AI unavailable (as when the claude CLI is not installed): the editor still gets
    /// LanguageTool's issues, with no network involved.
    @MainActor
    func testEditorIssuesWithoutAI() async throws {
        let saved = UserDefaults.standard.string(forKey: "ruleChecker")
        defer { UserDefaults.standard.set(saved, forKey: "ruleChecker") }
        UserDefaults.standard.removeObject(forKey: "ruleChecker")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("musset-offline-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        let tv = ZenTextView(usingTextLayoutManager: false)
        tv.frame = window.contentView!.bounds
        window.contentView!.addSubview(tv)
        let bridge = EditorBridge(), proof = AutoProofreader()
        proof.enabled = true; proof.autoCorrect = true
        bridge.textView = tv; bridge.proof = proof; proof.bridge = bridge; tv.bridge = bridge
        proof.attach(root: root, lang: "fr")
        tv.string = "Les enfant sont partis.\n\nElle est allé au marché.\n"

        // The first AI request fails the way Shell reports a missing CLI; the AI then pauses.
        proof.running = 1
        proof.receive(.failure(NSError(domain: "Musset", code: 127, userInfo: [NSLocalizedDescriptionKey: "claude not found on PATH"])),
                      batch: proof.paragraphs(of: tv.string))
        XCTAssertNotNil(proof.lastError)
        proof.chapterOpened()

        let deadline = Date().addingTimeInterval(20)
        while proof.issues(in: tv.string).count < 2 && Date() < deadline { try await Task.sleep(nanoseconds: 100_000_000) }
        let issues = proof.issues(in: tv.string)
        XCTAssertEqual(issues.map(\.fix.original), ["Les enfant", "allé"])
        XCTAssertTrue(issues.allSatisfy { $0.fix.checkerName == "LanguageTool" })
        XCTAssertEqual(tv.string, "Les enfant sont partis.\n\nElle est allé au marché.\n")   // suggestions only, never applied
        XCTAssertNil(proof.languageToolError)
        withExtendedLifetime(window) {}
    }

    func testDefaultCheckerIsLocal() {
        let saved = UserDefaults.standard.string(forKey: "ruleChecker")
        defer { UserDefaults.standard.set(saved, forKey: "ruleChecker") }
        UserDefaults.standard.removeObject(forKey: "ruleChecker")
        XCTAssertEqual(LocalProofreader.checker, .local)
    }
}
