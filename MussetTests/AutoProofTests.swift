import AppKit
import SwiftUI
import XCTest
@testable import Musset

@MainActor
final class AutoProofTests: XCTestCase {
    /// Settings ▸ Proofreading writes the defaults; the proofreader that is running takes the switch at once, and a
    /// switch flipped on the proofreader (the Notes panel's) is what Settings then shows.
    func testASwitchInSettingsReachesTheRunningProofreader() {
        let d = UserDefaults.standard
        let keys = ["autoProofread", "autoCorrect", "autoTypography"]
        let saved = keys.map { d.object(forKey: $0) }
        defer { for (k, v) in zip(keys, saved) { d.set(v, forKey: k) } }
        for k in keys { d.set(true, forKey: k) }
        let proof = AutoProofreader()
        XCTAssertTrue(proof.enabled && proof.autoCorrect && proof.typography)
        d.set(false, forKey: "autoProofread")
        XCTAssertFalse(proof.enabled, "switched off in Settings: off at once")
        XCTAssertTrue(proof.autoCorrect && proof.typography, "the others stay")
        d.set(false, forKey: "autoCorrect")
        d.set(false, forKey: "autoTypography")
        XCTAssertFalse(proof.autoCorrect)
        XCTAssertFalse(proof.typography)
        d.set(true, forKey: "autoProofread")
        XCTAssertTrue(proof.enabled, "and back on")
        proof.typography = true
        XCTAssertEqual(d.object(forKey: "autoTypography") as? Bool, true, "the Notes panel's switch is the same one")
    }

    func testMatchingKeepsCurlyApostrophes() {
        let src = "Mais on est jamais trop prudent, dit l’homme."
        let raw = #"[{"original":"on est jamais","replacement":"on n'est jamais","reason":"négation","kind":"suggest"},{"original":"dit l'homme","replacement":"dit l'Homme","reason":"x","kind":"obvious"}]"#
        let fixes = Proofreader.parse(raw, source: src, offset: 0)
        XCTAssertEqual(fixes.count, 2)
        XCTAssertEqual(fixes[0].replacement, "on n’est jamais")   // follows the paragraph's ’
        XCTAssertEqual(fixes[1].replacement, "dit l’Homme")
        XCTAssertFalse(fixes[0].isObvious)
        XCTAssertTrue(fixes[1].isObvious)
    }

    /// Regression: each replacement moves the caret, and the selection callback used to start a second
    /// pass mid-loop, so later fixes landed off by a few characters (« PPuis il y avaitle », « sœur » eating its comma).
    func testAutoCorrectDoesNotCorruptNeighbouringText() throws {
        let p1 = "À gauche, celle de ma soeur, des affiches de Man Ray.\n"
        let p2 = "Puis il y a avait le long couloir que mon père avait du utiliser, et nous sommes arrivé à Chaumont.\n"
        let p3 = "Ma mère tirait un fils aux boucles d’or. Sa manière de dire *Jungle*\u{00A0}: nous.\n"
        let last = "\nDernier paragraphe où se trouve le curseur.\n"
        let text = p1 + "\n" + p2 + "\n" + p3 + last

        func fix(_ o: String, _ r: String) -> [String: String] { ["original": o, "replacement": r, "reason": "x", "kind": "obvious"] }
        let cache: [String: [[String: String]]] = [
            AutoProofreader.hash(p1, lang: "fr"): [fix("ma soeur", "ma sœur")],
            AutoProofreader.hash(p2, lang: "fr"): [fix("il y a avait le", "il y avait le"), fix("avait du utiliser", "avait dû utiliser"), fix("sommes arrivé", "sommes arrivés")],
            // A fix for a word that is not there as a whole word must not touch « nous ».
            AutoProofreader.hash(p3, lang: "fr"): [fix("nou", "nous")],
        ]
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("musset-reentry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".musset/proof"), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["cache": cache, "ignored": []]).write(to: root.appendingPathComponent(".musset/proof/cache.json"))

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        let tv = ZenTextView(usingTextLayoutManager: false)
        tv.frame = window.contentView!.bounds
        tv.allowsUndo = true
        window.contentView!.addSubview(tv)
        let bridge = EditorBridge(), proof = AutoProofreader()
        proof.enabled = true; proof.autoCorrect = true
        bridge.textView = tv; bridge.proof = proof; proof.bridge = bridge; tv.bridge = bridge
        proof.attach(root: root, lang: "fr")
        tv.string = text
        // Caret at the start of the last paragraph: every fix above shifts it, as when writing at the end of a chapter.
        tv.setSelectedRange(NSRange(location: (text as NSString).length - 10, length: 0))
        let reentry = SelectionReentry(proof)
        tv.delegate = reentry

        proof.selectionChanged()
        XCTAssertEqual(tv.string, text
            .replacingOccurrences(of: "ma soeur", with: "ma sœur")
            .replacingOccurrences(of: "il y a avait le", with: "il y avait le")
            .replacingOccurrences(of: "avait du utiliser", with: "avait dû utiliser")
            .replacingOccurrences(of: "sommes arrivé", with: "sommes arrivés"))
        XCTAssertEqual(proof.corrections.count, 4)
        withExtendedLifetime(reentry) {}
    }

    /// Regression: two identical paragraphs in one batch crashed the app (duplicate dictionary key).
    func testIdenticalParagraphsInOneBatch() {
        let proof = AutoProofreader()
        proof.enabled = true
        proof.attach(root: FileManager.default.temporaryDirectory.appendingPathComponent("musset-dup-\(UUID().uuidString)"), lang: "fr")
        let text = "Il a dit oui.\n\nIl a dit oui.\n"
        let batch = proof.paragraphs(of: text)
        XCTAssertEqual(batch.count, 2)
        proof.running = 1
        proof.receive(.success(#"[{"original":"dit oui","replacement":"dit « oui »","reason":"x","kind":"suggest"}]"#), batch: batch)
        XCTAssertEqual(proof.issues(in: text).count, 2)
    }

    /// The author's words and overrides hide issues, survive reopening the book and reach the AI prompt.
    func testDictionaryAndOverrides() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("musset-dict-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".musset"), withIntermediateDirectories: true)
        let text = "Le goût de l’horchata, dit-il, nou partons.\n"
        let proof = AutoProofreader()
        proof.enabled = true
        proof.attach(root: root, lang: "fr")
        let batch = proof.paragraphs(of: text)
        proof.running = 1
        proof.receive(.success(#"[{"original":"l’horchata","replacement":"l’orgeat","reason":"mot inconnu","message":"Ce mot n’existe pas en français.","kind":"suggest"},{"original":"nou partons","replacement":"nous partons","reason":"faute de frappe","kind":"obvious"}]"#), batch: batch)
        XCTAssertEqual(proof.issues(in: text).count, 2)
        XCTAssertEqual(proof.issues(in: text)[0].fix.message, "Ce mot n’existe pas en français.")

        proof.learn("horchata")
        XCTAssertEqual(proof.issues(in: text).map(\.fix.original), ["nou partons"])
        proof.ignore(proof.issues(in: text)[0].fix)
        XCTAssertTrue(proof.issues(in: text).isEmpty)

        var lt = ProofFix(original: "dit-il", replacement: "dit‑il", reason: "x", source: "lt", rule: "FR_DASH")
        lt.kind = "suggest"
        proof.disableRule("FR_DASH")
        XCTAssertTrue(proof.isSuppressed(lt))

        // Reopen the book: everything is still there.
        let again = AutoProofreader()
        again.attach(root: root, lang: "fr")
        XCTAssertEqual(again.dictionary, ["horchata"])
        XCTAssertTrue(again.ignored.contains("nou partons→nous partons"))
        XCTAssertTrue(again.disabledRules.contains("FR_DASH"))
        XCTAssertTrue(try String(contentsOf: root.appendingPathComponent(".musset/dictionary.txt"), encoding: .utf8).contains("horchata\n"))
        XCTAssertTrue(Proofreader.prompt(text: "x", lang: "fr", dictionary: again.dictionary).contains("never flag them: horchata"))
    }

    /// Renders the hover card for a LanguageTool issue. Opt in with MUSSET_SNAPSHOT=<dir>.
    func testIssueCardSnapshot() throws {
        guard let dir = ProcessInfo.processInfo.environment["MUSSET_SNAPSHOT"] else { throw XCTSkip("set MUSSET_SNAPSHOT") }
        let fix = ProofFix(original: "nou", replacement: "ou", reason: "Faute de frappe", kind: "suggest", alternatives: ["nom", "où", "nous"],
                           source: "lt", message: "Faute de frappe possible trouvée.", rule: "FR_SPELLING_RULE")
        let p = AutoProofreader.Paragraph(range: NSRange(location: 0, length: 10), text: "et nou partons", hash: "h")
        let card = IssueCard(issue: .init(range: NSRange(location: 3, length: 3), fix: fix, paragraph: p), proof: AutoProofreader()) {}
        let host = NSHostingView(rootView: card.environment(\.colorScheme, .light))
        host.appearance = NSAppearance(named: .aqua)
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.backgroundColor = .windowBackgroundColor
        host.layoutSubtreeIfNeeded()
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: dir).appendingPathComponent("issuecard.png"))
    }

    func testFixesMatchWholeWordsOnly() {
        XCTAssertEqual(ProofFix(original: "nou", replacement: "nous", reason: "").locate(in: "nous partons").location, NSNotFound)
        XCTAssertEqual(ProofFix(original: "nou", replacement: "nous", reason: "").locate(in: "et nou partons").location, 3)
        XCTAssertEqual(ProofFix(original: "« oui", replacement: "« Oui", reason: "").locate(in: "dit-il « oui »").location, 7)
    }

    /// Live: background proofreading of the whole 03_nice chapter through Haiku. Opt in with MUSSET_LIVE=1.
    func testLiveBackgroundProofreading() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MUSSET_LIVE"] == "1")
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/conatus/03_nice.md")
        let lines = try String(contentsOf: fixture, encoding: .utf8).components(separatedBy: "\n")
        let text = lines.joined(separator: "\n") + "\n\nDernier paragraphe où se trouve le curseur.\n"

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("musset-auto-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        let tv = ZenTextView(usingTextLayoutManager: false)
        tv.frame = window.contentView!.bounds
        tv.allowsUndo = true
        window.contentView!.addSubview(tv)
        let bridge = EditorBridge(), proof = AutoProofreader()
        proof.enabled = true; proof.autoCorrect = true
        bridge.textView = tv; bridge.proof = proof; proof.bridge = bridge; tv.bridge = bridge
        UserDefaults.standard.set("claude", forKey: "proofEngine")
        UserDefaults.standard.set("haiku", forKey: "proofModel")
        proof.attach(root: root, lang: "fr")
        tv.string = text
        tv.setSelectedRange(NSRange(location: (text as NSString).length - 5, length: 0))
        proof.chapterOpened()

        let deadline = Date().addingTimeInterval(150)
        var started = false
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            if proof.running > 0 { started = true }
            if started && proof.running == 0 { break }
        }
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        XCTAssertNil(proof.lastError)
        for c in proof.corrections.reversed() { print("AUTO «\(c.original)» → «\(c.replacement)» (\(c.reason))") }
        for i in proof.issues(in: tv.string) { print("REVIEW «\(i.fix.original)» → «\(i.fix.replacement)» (\(i.fix.reason)) [\(i.fix.kind ?? "-")]") }
        print("TOTAL auto:", proof.corrections.count, "review:", proof.issues(in: tv.string).count)
        XCTAssertGreaterThan(proof.corrections.count, 0)
        // Undo puts the whole batch back.
        tv.undoManager?.undo()
        print("UNDO restored original:", tv.string == text)
    }
}

/// Calls the proofreader on every selection change, like the editor's coordinator does.
@MainActor
private final class SelectionReentry: NSObject, NSTextViewDelegate {
    let proof: AutoProofreader
    init(_ proof: AutoProofreader) { self.proof = proof }
    func textViewDidChangeSelection(_ notification: Notification) { proof.selectionChanged() }
}

final class SearchTests: XCTestCase {
    func testSearchIgnoresCaseAndAccents() {
        let text = "Le Père lisait. Mon pere aussi. PÈRE !"
        XCTAssertEqual(BookSearch.ranges(of: "père", in: text).count, 3)
        XCTAssertEqual(BookSearch.ranges(of: "p", in: text).count, 0) // one letter: no search
    }
}
