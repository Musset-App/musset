import AppKit
import SwiftUI
import XCTest
@testable import Musset

final class AnchoringTests: XCTestCase {
    let text = "Le soir, mon père lisait Le Monde dans le salon. Ma mère découpait les légumes, la clope au bec."

    private func anchor(_ quote: String, in t: String) -> NoteAnchor {
        Anchoring.capture((t as NSString).range(of: quote), in: t as NSString, version: "main")
    }

    private func found(_ a: NoteAnchor, in t: String) -> String? {
        Anchoring.resolve(a, in: t).map { (t as NSString).substring(with: $0) }
    }

    func testExactAndMoved() {
        let a = anchor("Ma mère découpait les légumes", in: text)
        XCTAssertEqual(found(a, in: text), "Ma mère découpait les légumes")
        let moved = "Un ajout au début. " + text
        XCTAssertEqual(found(a, in: moved), "Ma mère découpait les légumes")
    }

    func testDuplicateQuotePicksTheRightOne() {
        let t = "Il pleuvait. Mon père dormait. Il pleuvait. Ma mère riait."
        let ns = t as NSString
        let second = ns.range(of: "Il pleuvait", options: .backwards)
        let a = Anchoring.capture(second, in: ns, version: nil)
        let edited = "Dehors, " + t   // both copies move
        let r = Anchoring.resolve(a, in: edited)!
        XCTAssertEqual(r.location, (edited as NSString).range(of: "Il pleuvait", options: .backwards).location)
    }

    func testRewrittenPassageIsFoundFuzzily() {
        let a = anchor("Ma mère découpait les légumes, la clope au bec", in: text)
        let rewritten = text.replacingOccurrences(of: "découpait les légumes", with: "coupait les légumes")
        XCTAssertNotNil(found(a, in: rewritten))
        let gone = "Le soir, mon père lisait Le Monde dans le salon."
        XCTAssertNil(found(a, in: gone))
    }

    func testAdjustThroughEdits() {
        let r = NSRange(location: 10, length: 5)              // [10, 15)
        // Insert 3 characters before, at the start, inside, at the end, after.
        XCTAssertEqual(Anchoring.adjust(r, edited: NSRange(location: 2, length: 3), delta: 3), NSRange(location: 13, length: 5))
        XCTAssertEqual(Anchoring.adjust(r, edited: NSRange(location: 10, length: 3), delta: 3), NSRange(location: 13, length: 5))
        XCTAssertEqual(Anchoring.adjust(r, edited: NSRange(location: 12, length: 3), delta: 3), NSRange(location: 10, length: 8))
        XCTAssertEqual(Anchoring.adjust(r, edited: NSRange(location: 15, length: 3), delta: 3), r)
        XCTAssertEqual(Anchoring.adjust(r, edited: NSRange(location: 20, length: 3), delta: 3), r)
        // Delete 2 characters before, inside; delete the whole passage.
        XCTAssertEqual(Anchoring.adjust(r, edited: NSRange(location: 4, length: 0), delta: -2), NSRange(location: 8, length: 5))
        XCTAssertEqual(Anchoring.adjust(r, edited: NSRange(location: 11, length: 0), delta: -2), NSRange(location: 10, length: 3))
        XCTAssertNil(Anchoring.adjust(r, edited: NSRange(location: 8, length: 0), delta: -10))
        // Replace a word that is the whole passage (auto-correct): the note stays on the new word.
        XCTAssertEqual(Anchoring.adjust(r, edited: NSRange(location: 10, length: 4), delta: -1), NSRange(location: 10, length: 4))
        // A paste over more than the passage: the note does not take over the new text.
        XCTAssertNil(Anchoring.adjust(r, edited: NSRange(location: 2, length: 9000), delta: 8980))
    }
}

final class PlanTests: XCTestCase {
    func testOldGridsGetTheNewColumns() {
        var g = PlotGrid()
        g.columns = [.init(id: "characters", title: "Personnages"), .init(id: "main", title: "Intrigue principale"),
                     .init(id: "sub", title: "Intrigue secondaire"), .init(id: "motifs", title: "Motifs"),
                     .init(id: "hidden", title: "Intrigue cachée", ai: false), .init(id: "mine", title: "Lieux")]
        g.migrateColumns()
        XCTAssertEqual(g.columns.map(\.id), ["main", "characters", "motifs", "sub", "hidden", "notes", "mine"])
        XCTAssertEqual(g.columns[0].title, "Synopsis")
        XCTAssertFalse(g.columns[5].ai)
        g.columns.swapAt(0, 1)
        g.migrateColumns()
        XCTAssertEqual(g.columns[0].id, "characters", "the author's order stays once migrated")
    }

    func testFilledFollowsTheColumns() {
        var g = PlotGrid()
        g.update("c", "s") { $0.cells["main"] = .init(text: "x"); $0.cells["motifs"] = .init(tags: ["piano"]); $0.cells["sub"] = .init(text: "") }
        XCTAssertEqual(g.filled("c", "s"), [true, false, true, false, false, false])
    }

    func testChapterSynopsisRoundTrip() throws {
        var g = PlotGrid()
        g.setChapterSynopsis("c", "Le père debout.")
        let back = try JSONDecoder().decode(PlotGrid.self, from: JSONEncoder().encode(g))
        XCTAssertEqual(back.chapterSynopsis("c"), "Le père debout.")
        g.setChapterSynopsis("c", "")
        XCTAssertNil(g.chapterSynopses)
    }

}

@MainActor
final class NoteStoreTests: XCTestCase {

    /// A resolved note keeps its point settled even once its passage is rewritten; a pass resolves what the text fixed.
    func testResolvedStaysSettledAndFixedNotesResolve() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("musset-settled-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let text = "Le soir, mon père lisait Le Monde dans le salon. Ma mère découpait les légumes. On était très heureux ce soir-là."
        try text.write(to: root.appendingPathComponent("01.md"), atomically: true, encoding: .utf8)
        let session = BookSession(root: root, manifest: BookManifest(title: "T", chapters: [ChapterEntry(id: "01", file: "01.md", title: "Un")]))
        session.open("01")
        let first = [Annotator.Item(quote: "On était très heureux ce soir-là", note: "[Explication] Nommé.", kind: "critique"),
                     Annotator.Item(quote: "Ma mère découpait les légumes", note: "[Rythme] Plat.", kind: "critique")]
        XCTAssertEqual(Annotator.add(first, to: session, author: .claude, defaultKind: .critique, scope: nil, run: "a"), 2)
        let settled = try XCTUnwrap(session.notes.notes.first { $0.anchor.quote.hasPrefix("On était") })
        let open = try XCTUnwrap(session.notes.notes.first { $0.anchor.quote.hasPrefix("Ma mère") })
        session.notes.setStatus(settled.id, .resolved)

        // Its passage disappears from the text: still listed for the AI, and a new note on a close quote is refused.
        session.notes.resolveAll(in: "Le soir, mon père lisait Le Monde dans le salon. Ma mère découpait les légumes. On était heureux.")
        XCTAssertTrue(session.notes.notes.first { $0.id == settled.id }!.orphaned)
        XCTAssertTrue(session.notes.blocksNewNote(at: NSRange(location: 0, length: 3), quote: "On était très heureux"))
        let list = Annotator.existingNotes(session)
        XCTAssertTrue(list.contains("RESOLVED"))
        XCTAssertTrue(list.contains("#\(settled.id.uuidString.prefix(8).lowercased())"))

        // The AI says the open note is fixed: it is resolved, with the reason in its thread.
        let short = String(open.id.uuidString.prefix(8))
        let items = Annotator.parse(##"[{"resolves": "#\##(short)", "note": "La phrase a gagné un geste."}]"##)
        XCTAssertEqual(items.count, 1)
        session.notes.lastAutoResolved = 0
        XCTAssertEqual(Annotator.add(items, to: session, author: .claude, defaultKind: .critique, scope: nil, run: "b"), 0)
        let after = try XCTUnwrap(session.notes.notes.first { $0.id == open.id })
        XCTAssertEqual(after.status, .resolved)
        XCTAssertEqual(after.replies.last?.body, "La phrase a gagné un geste.")
        XCTAssertEqual(session.notes.lastAutoResolved, 1)
    }

    func testChapterStatusIsSaved() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("musset-status-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "Texte.".write(to: root.appendingPathComponent("01.md"), atomically: true, encoding: .utf8)
        let session = BookSession(root: root, manifest: BookManifest(title: "T", chapters: [ChapterEntry(id: "01", file: "01.md", title: "Un")]))
        session.setStatus("01", .edited)
        XCTAssertEqual(try BookStore(root: root).loadManifest().chapters.first?.status, .edited)
        session.setStatus("01", .draft)
        XCTAssertNil(try BookStore(root: root).loadManifest().chapters.first?.status)
    }

    /// A second AI pass neither stacks notes on noted passages nor brings back resolved ones; old stacks are cleaned.
    func testAIPassesDoNotStackOrReopen() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("musset-stack-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let text = "Le soir, mon père lisait Le Monde. Ma mère découpait les légumes. On était heureux."
        try text.write(to: root.appendingPathComponent("01.md"), atomically: true, encoding: .utf8)
        let session = BookSession(root: root, manifest: BookManifest(title: "T", chapters: [ChapterEntry(id: "01", file: "01.md", title: "Un")]))
        session.open("01")
        let items = [Annotator.Item(quote: "Ma mère découpait les légumes", note: "[Rythme] Trop plat.", kind: "critique"),
                     Annotator.Item(quote: "On était heureux", note: "[Explication] Nommé, pas montré.", kind: "critique")]
        XCTAssertEqual(Annotator.add(items, to: session, author: .claude, defaultKind: .critique, scope: nil, run: "a"), 2)
        let resolved = try XCTUnwrap(session.notes.notes.first { $0.anchor.quote.hasPrefix("On était") })
        session.notes.setStatus(resolved.id, .resolved)

        // Same passages, slightly different quotes and wording: nothing new is added, the resolved note stays resolved.
        let again = [Annotator.Item(quote: "mère découpait les légumes.", note: "[Rythme] Phrase plate.", kind: "critique"),
                     Annotator.Item(quote: "On était heureux.", note: "[Explication] Émotion nommée.", kind: nil),
                     Annotator.Item(quote: "mon père lisait Le Monde", note: "[Cliché] Image attendue.", kind: nil)]
        XCTAssertEqual(Annotator.add(again, to: session, author: .codex, defaultKind: .critique, scope: nil, run: "b"), 1)
        XCTAssertEqual(session.notes.notes.count, 3)
        XCTAssertEqual(session.notes.notes.first { $0.id == resolved.id }?.status, .resolved)
        XCTAssertTrue(Annotator.existingNotes(session).contains("[critique] « On était heureux"))

        // Stacks written by older versions are removed when the chapter is opened; kept or answered notes stay.
        let ns = text as NSString
        session.notes.add(range: ns.range(of: "Ma mère découpait"), text: text, author: .claude, kind: .critique, body: "Doublon", run: "c")
        let answered = try XCTUnwrap(session.notes.add(range: ns.range(of: "Ma mère découpait les"), text: text, author: .claude, kind: .critique, body: "Avec réponse", run: "d"))
        session.notes.reply(answered.id, author: .me, body: "Oui")
        let resolvedDup = try XCTUnwrap(session.notes.add(range: ns.range(of: "On était heureux"), text: text, author: .claude, kind: .critique, body: "Doublon résolu", run: "e"))
        session.notes.setStatus(resolvedDup.id, .resolved)
        let reopened = NoteStore(root: root)
        reopened.load(chapter: session.manifest.chapters[0], text: text)
        XCTAssertEqual(reopened.notes.count, 4)
        XCTAssertFalse(reopened.notes.contains { $0.body == "Doublon" || $0.body == "Doublon résolu" })
        XCTAssertEqual(reopened.notes.first { $0.id == resolved.id }?.status, .resolved)
    }

    func testNotesFollowEditsAndSurviveReload() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("musset-notes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let chapter = ChapterEntry(id: "03_nice", file: "03_nice.md", title: "Nice")
        var text = "Le soir, mon père lisait Le Monde. Ma mère découpait les légumes."
        let store = NoteStore(root: root)
        store.load(chapter: chapter, text: text)
        let range = (text as NSString).range(of: "Ma mère")
        let note = try XCTUnwrap(store.add(range: range, text: text, author: .me, kind: .question, body: "Quel âge a-t-elle ici ?"))

        // Type before the passage, the way the editor reports it.
        let insert = "Un ajout. "
        text = insert + text
        store.applyEdit(edited: NSRange(location: 0, length: (insert as NSString).length), delta: (insert as NSString).length)
        XCTAssertEqual((text as NSString).substring(with: store.live[note.id]!), "Ma mère")
        store.recapture(text: text)

        // Reopen: the note is on its passage, with its body.
        let again = NoteStore(root: root)
        again.load(chapter: chapter, text: text)
        XCTAssertEqual(again.notes.first?.body, "Quel âge a-t-elle ici ?")
        XCTAssertEqual((text as NSString).substring(with: again.live[note.id]!), "Ma mère")

        // Delete the passage: the note becomes an orphan but is kept.
        let cut = (text as NSString).range(of: "Ma mère découpait les légumes.")
        text = (text as NSString).replacingCharacters(in: cut, with: "")
        again.applyEdit(edited: NSRange(location: cut.location, length: 0), delta: -cut.length)
        XCTAssertTrue(again.notes.first!.orphaned)
        XCTAssertNil(again.live[note.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(".musset/notes/03_nice.md").path))
    }
}

@MainActor
final class NotesEditorTests: XCTestCase {
    /// The bridge holds the annotator weakly (the app owns it); the tests keep it alive here.
    private let annotator = Annotator()
    /// A temporary book with one chapter, opened in a real editor.
    private func makeBook(_ text: String) throws -> (BookSession, EditorBridge, NSWindow) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("musset-notebook-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try text.write(to: root.appendingPathComponent("01.md"), atomically: true, encoding: .utf8)
        let manifest = BookManifest(title: "Test",
                                    chapters: [ChapterEntry(id: "01", file: "01.md", title: "Un")])
        let session = BookSession(root: root, manifest: manifest)
        let bridge = EditorBridge()
        bridge.annotator = annotator
        let editor = ZenEditorView(session: session, bridge: bridge, fontName: "", fontSize: 16, columnWidth: 600,
                                   focusMode: false, typewriter: false, lineNumbers: true)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: editor)
        window.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        return (session, bridge, window)
    }

    func testNotesFollowTypingAndUndo() throws {
        let text = "Le soir, mon père lisait Le Monde.\n\nMa mère découpait les légumes, la clope au bec.\n"
        let (session, bridge, window) = try makeBook(text)
        let tv = try XCTUnwrap(bridge.textView)
        let range = (tv.string as NSString).range(of: "découpait les légumes")
        let note = try XCTUnwrap(session.notes.add(range: range, text: tv.string, author: .me, kind: .note, body: "Trop explicatif ?"))

        tv.setSelectedRange(NSRange(location: 0, length: 0))
        tv.insertText("Un ajout. ", replacementRange: tv.selectedRange())
        XCTAssertEqual((tv.string as NSString).substring(with: session.notes.live[note.id]!), "découpait les légumes")
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))   // typing is grouped for undo at the end of the event cycle
        tv.undoManager?.undo()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(tv.string, ParagraphCodec.decode(text))   // the editor holds one line per paragraph
        XCTAssertEqual((tv.string as NSString).substring(with: session.notes.live[note.id]!), "découpait les légumes")

        // Save, reopen the book: the note comes back on its passage.
        session.textDidChange(tv.string + " ")
        session.flushSave()
        let reopened = BookSession(root: session.root, manifest: session.manifest)
        XCTAssertEqual((reopened.text as NSString).substring(with: reopened.notes.live[note.id]!), "découpait les légumes")
        withExtendedLifetime(window) {}
    }

    /// Renders the editor with notes, and a note card. Opt in with MUSSET_SNAPSHOT=<dir>.
    func testNotesSnapshot() throws {
        guard let dir = ProcessInfo.processInfo.environment["MUSSET_SNAPSHOT"] else { throw XCTSkip("set MUSSET_SNAPSHOT") }
        let text = "Le soir, mon père lisait Le Monde dans le salon, en fumant son La Paz.\n\nMa mère découpait les légumes la clope au bec, mon père faisait la vinaigrette au fond du grand saladier en métal.\n\nC’était heureux, c’était bleu.\n"
        let (session, bridge, window) = try makeBook(text)
        window.appearance = NSAppearance(named: .aqua)
        let tv = try XCTUnwrap(bridge.textView)
        let ns = tv.string as NSString
        let mine = session.notes.add(range: ns.range(of: "en fumant son La Paz"), text: tv.string, author: .me, kind: .question, body: "Vérifier : La Paz ou Partagás ?")!
        session.notes.add(range: ns.range(of: "C’était heureux, c’était bleu."), text: tv.string, author: .claude, kind: .critique,
                          body: "« Heureux » nomme l’émotion que la scène vient de montrer ; le bleu peut porter seul la joie.", run: "r")
        session.notes.reply(mine.id, author: .claude, body: "Les La Paz sont des cigarillos hollandais, plausibles dans les années 80.")
        tv.scrollRangeToVisible(NSRange(location: 0, length: 0))
        tv.needsDisplay = true
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        let view = window.contentView!
        var rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: dir).appendingPathComponent("notes-editor.png"))

        let card = NSHostingView(rootView: NoteThread(noteID: mine.id, session: session, annotator: bridge.annotator!, bridge: bridge) {}
            .frame(width: 380, height: 560).environment(\.colorScheme, .light))
        card.appearance = NSAppearance(named: .aqua)
        card.frame = NSRect(origin: .zero, size: NSSize(width: 380, height: 560))
        let w2 = NSWindow(contentRect: card.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w2.contentView = card
        card.layoutSubtreeIfNeeded()
        rep = card.bitmapImageRepForCachingDisplay(in: card.bounds)!
        card.cacheDisplay(in: card.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: dir).appendingPathComponent("note-card.png"))
    }

    /// Regression for the freezes: type, delete and scroll a lot in a real editor with notes, minimap features on.
    func testHeavyTypingDoesNotHang() throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/conatus/03_nice.md")
        let (session, bridge, window) = try makeBook(try String(contentsOf: fixture, encoding: .utf8))
        let tv = try XCTUnwrap(bridge.textView)
        tv.showRepetitions = true
        session.notes.add(range: NSRange(location: 200, length: 40), text: tv.string, author: .me, kind: .note, body: "x")
        let start = Date()
        for i in 0..<300 {
            let end = (tv.string as NSString).length
            tv.setSelectedRange(NSRange(location: i % 3 == 0 ? end : end / 2, length: 0))
            tv.insertText(i % 7 == 0 ? "\n\n" : "mot ", replacementRange: tv.selectedRange())
            if i % 5 == 0 { tv.deleteBackward(nil) }
            if i % 25 == 0 { tv.scrollToCenter(offset: i * 37 % end); tv.display() }
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertLessThan(Date().timeIntervalSince(start), 30)
        withExtendedLifetime(window) {}
    }

    func testChatNotesBlockIsParsed() {
        let reply = """
        Voici mes remarques.
        ```notes
        [{"quote": "Ma mère découpait les légumes", "kind": "critique", "note": "On voit la scène, bien."}]
        ```
        """
        let items = ChatModel.noteBlocks(in: reply)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].kind, "critique")
    }

    /// Live: Claude annotates 03_nice; every note must land on its passage. Opt in with MUSSET_LIVE=1.
    func testLiveAnnotateChapter() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MUSSET_LIVE"] == "1")
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/conatus/03_nice.md")
        let text = try String(contentsOf: fixture, encoding: .utf8)
        let prompt = Annotator.prompt(task: .critique, custom: "", root: URL(fileURLWithPath: "/tmp"), book: "Le Sel", chapter: "Nice", text: text, agents: "")
        let raw = try await Agents.oneShot(.claude, prompt: prompt, model: "haiku", cwd: fixture.deletingLastPathComponent())
        let items = Annotator.parse(raw)
        let (session, _, window) = try makeBook(text)
        let placed = Annotator.add(items, to: session, author: .claude, defaultKind: .critique, scope: nil, run: "t")
        for n in session.notes.ordered { print("NOTE «\(n.anchor.quote)» — \(n.body)") }
        print("NOTES placed \(placed) of \(items.count)")
        XCTAssertGreaterThan(placed, 0)
        XCTAssertEqual(placed, items.count)
        withExtendedLifetime(window) {}
    }
}

@MainActor
final class NoteThreadLiveTests: XCTestCase {
    /// Live: replying in a Claude note's thread gets a streamed answer. MUSSET_LIVE=1.
    func testLiveThreadConversation() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MUSSET_LIVE"] == "1")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("musset-thread-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let text = "Le premier jour d’école, on m’a habillé d’un pantalon de flanelle, une chemise blanche, un gilet bleu, des mocassins Sebago et un duffle-coat Burberry.\n"
        try text.write(to: root.appendingPathComponent("01.md"), atomically: true, encoding: .utf8)
        let session = BookSession(root: root, manifest: BookManifest(title: "Le Sel", chapters: [ChapterEntry(id: "01", file: "01.md", title: "Chaumont")]))
        let range = (session.text as NSString).range(of: "une chemise blanche, un gilet bleu")
        let note = try XCTUnwrap(session.notes.add(range: range, text: session.text, author: .claude, kind: .critique,
                                                   body: "[Rythme] Après « habillé d'un pantalon », la préposition disparaît pour le reste de l'énumération. La construction se casse."))
        let annotator = Annotator()
        let start = Date()
        annotator.ask(note.id, question: "Explique ?", session: session, engine: .claude)
        var sawPartial = false
        while Date().timeIntervalSince(start) < 180 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            if annotator.answering != nil, let last = session.notes.notes.first?.replies.last, last.author == .claude, !last.body.isEmpty { sawPartial = true }
            if annotator.answering == nil { break }
        }
        let replies = try XCTUnwrap(session.notes.notes.first).replies
        print("THREAD \(Int(Date().timeIntervalSince(start)))s streamed=\(sawPartial) error=\(annotator.askError ?? "none")")
        for r in replies { print("THREAD \(r.author.label): \(r.body)") }
        XCTAssertEqual(replies.map(\.author), [.me, .claude])
        XCTAssertFalse(replies[1].body.isEmpty)
        XCTAssertTrue(sawPartial)
    }
}
