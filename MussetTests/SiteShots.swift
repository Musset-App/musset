import SwiftUI
import XCTest
@testable import Musset

/// Screenshots for the website: the whole window on a demo book, and its typeset PDF. MUSSET_SITE_SHOTS=<dir>.
/// The demo text is original, written for these pictures.
@MainActor
final class SiteShots: XCTestCase {
    static let ferry = """
    # The Ferry

    <!-- scene: Morning crossing -->

    The ferry left at six, before the gulls were awake. Nora stood at the rail with her father's coat over her arm, as if he might still ask for it. The deck was wet and nobody else had come up; the other passengers were below, in the warm room that smelled of coffee and diesel, sleeping against their own reflections in the windows.

    Below, the water kept its own counsel. She had rehearsed what she would say to her brother for three hundred miles, and now every sentence sounded like someone else's. She tried them again under her breath, one after the other, and none of them survived the wind.

    "You came," he would say. Or he would say nothing, which was worse, and which was more like him.

    They had not spoken since the funeral of their mother, eleven years ago, when Tom had stood at the back of the church in a borrowed suit and left before the last hymn. She had found him afterwards in the car park, smoking with the undertaker, and he had looked at her as if she were a stranger who had asked him for directions.

    A man in an orange jacket came along the deck with a coil of rope and nodded at her without stopping. She nodded back. It was the first time anyone had looked at her since the motorway.

    <!-- scene: The island -->

    The island rose out of the haze in pieces: a church, a line of white houses, the long grey roof of the salt works where their mother had counted sacks for twenty years. Then the harbour wall, the crane, the two cars waiting on the slipway with their headlights still on, though it was day now and nobody needed them.

    She folded the coat once more. It smelled of tobacco and of rain, and of the winter he had spent pretending not to be ill. In the inside pocket there was a ferry ticket from March, a pencil, and a list in his handwriting that she had not been able to read in the hospital and could not read now: *salt, glass, the blue boat, Tom.*

    The engines changed their note. Somewhere below, a door banged, and the passengers began to come up the stairs with their bags, blinking, putting on their coats. A child asked whether this was the island. Its mother said it was. The child looked at the island for a long time and said that it was smaller than in the book.

    Nora put the list back where she had found it.

    <!-- scene: The harbour -->

    He was not on the quay. She had known he would not be, and still she looked for him twice: once among the men by the crane, once in the doorway of the café, where an old woman was turning the sign from *Closed* to *Open* with great care, as if the word might break.

    She walked up the hill with the coat over her arm and her bag on her shoulder. The road was the road she remembered, only narrower. The houses had new doors. At the top, where the road turned towards the salt works, someone had painted a blue boat on the side of the bus shelter, badly, a long time ago, and it was still there.

    She stopped in front of it and laughed, because it was his, and because nobody had painted over it in eleven years, and because she did not know what else to do.
    """

    static let saltWorks = """
    # The Salt Works

    The gate was open. Nobody had {~~ever locked~>locked~~}{@Claire} anything on the island since the war, and the salt works least of all: there was nothing {--left--}{@Claire} to take but the salt, and the salt took care of itself.

    Tom's van was parked by the old weighing house, {++its back doors open,++}{@Claire} with a dog asleep in the shade of it. The dog lifted its head when she came through the gate and put it down again, as if she had been expected.

    {==She found him on the roof.==}{>>Too sudden? We haven't heard him yet. Maybe his voice first, then the roof.<<}{@Claire} He was kneeling between two rows of slates with a hammer in his hand, and he did not look round.

    "It leaks over the drying room," he said. "It always leaked over the drying room."
    """

    static let inventory = "# Inventory\n\nHer brother had kept everything: receipts, tide tables, a calendar from 1987 with the high tides ringed in red.\n"

    func testSiteShots() async throws {
        guard let dir = ProcessInfo.processInfo.environment["MUSSET_SITE_SHOTS"] else { throw XCTSkip("set MUSSET_SITE_SHOTS") }
        let out = URL(fileURLWithPath: dir)
        let d = UserDefaults.standard
        let saved = (d.string(forKey: UILang.key), d.stringArray(forKey: "libraryPaths"), d.string(forKey: "lastBook"), d.object(forKey: "sideBySideDiff"))
        defer {
            d.set(saved.0, forKey: UILang.key); d.set(saved.1, forKey: "libraryPaths"); d.set(saved.2, forKey: "lastBook")
            d.set(saved.3, forKey: "sideBySideDiff")
        }
        d.set("en", forKey: UILang.key)
        d.set(true, forKey: "sideBySideDiff")
        d.removeObject(forKey: "libraryPaths"); d.removeObject(forKey: "lastBook")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("The Salt Road")
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for (name, text) in [("01.md", Self.ferry), ("02.md", Self.saltWorks), ("03.md", Self.inventory)] {
            try Typography.correctedDocument(text, lang: "en-GB").text.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        var m = BookManifest(title: "The Salt Road", author: "Nora Vale", lang: "en-GB", chapters: [
            ChapterEntry(id: "01", file: "01.md", title: "The Ferry", status: .edited),
            ChapterEntry(id: "02", file: "02.md", title: "The Salt Works", status: .draft),
            ChapterEntry(id: "03", file: "03.md", title: "Inventory", status: .draft)])
        m.exports = BookStore(root: root).defaultPresets(lang: m.lang)
        m.sceneBreak = .asterism
        try BookStore(root: root).saveManifest(m)
        let git = GitService(root: root)
        try git.initRepo()
        _ = try git.commit(paths: ["01.md", "02.md", "03.md", ".musset"], message: "start")

        // The typeset book: Blanche, facing pages, as it would go to the printer.
        var blanche = ExportPreset(id: "site-blanche", name: "Book", format: .pdf, template: "blanche")
        blanche.facing = true
        let pdf = try await ExportService.export(manifest: m, store: BookStore(root: root), preset: blanche)
        try? FileManager.default.removeItem(at: out.appendingPathComponent("book.pdf"))
        try FileManager.default.copyItem(at: pdf.file, to: out.appendingPathComponent("book.pdf"))

        let app = AppState()
        app.openBook(root)
        let s = try XCTUnwrap(app.current)
        s.open("01")
        let text = s.text as NSString
        s.notes.add(range: text.range(of: "kept its own counsel"), text: s.text, author: .claude, kind: .critique,
                    body: "A borrowed phrase in a chapter that is otherwise all hers. What does Nora see in the water?")
        s.notes.add(range: text.range(of: "which was worse, and which was more like him"), text: s.text, author: .claude, kind: .praise,
                    body: "The brother arrives before he appears. Keep it.")
        s.notes.add(range: text.range(of: "She folded the coat once more."), text: s.text, author: .claude, kind: .question,
                    body: "The coat is folded for the second time. Deliberate echo, or one too many?")
        s.notes.add(range: text.range(of: "eleven years ago"), text: s.text, author: .me, kind: .continuity,
                    body: "Check against chapter 4: the funeral is in winter there.")

        let bridge = EditorBridge(), chat = ChatModel(), ann = Annotator(), proof = AutoProofreader()
        bridge.annotator = ann; bridge.proof = proof
        let view = ContentView(app: app, bridge: bridge, chat: chat, pangram: PangramModel(), proof: proof, annotator: ann)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900), styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: view.frame(width: 1440, height: 900))
        func shot(_ name: String, dark: Bool = false, wait: TimeInterval = 1.2, _ setup: () -> Void) async throws {
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            setup()
            // Sleeping, not spinning the run loop: typesetting and the history finish on the main actor meanwhile.
            try await Task.sleep(for: .seconds(wait))
            let v = window.contentView!
            let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds)!
            v.cacheDisplay(in: v.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name))
        }
        try await shot("write-light.png") { app.showInspector = false }
        try await shot("write-dark.png", dark: true) { app.showInspector = false }
        try await shot("notes-light.png") { app.inspectorTab = .edits; app.showInspector = true }
        chat.messages = [
            ChatMessage(role: .user, text: "Does the crossing hold without Tom in it? I’m afraid the first scene is all waiting."),
            ChatMessage(role: .assistant, agent: .claude, text: "It holds, and the waiting is the point: Tom is present in every paragraph through what Nora rehearses, the coat, the list in his handwriting. The reader meets him before he appears.\n\nTwo things weaken it. « Kept its own counsel » is the only borrowed phrase in a chapter that is otherwise all hers. And the coat is folded twice; the second fold is the stronger one, so the first could go.\n\nI’ve left three notes in the margin. Would you like me to look at how the harbour scene ends?", action: .style, notesAdded: 3),
            ChatMessage(role: .user, text: "Yes — does the laugh at the bus shelter come too soon?"),
        ]
        try await shot("chat-light.png") { app.inspectorTab = .chat; app.showInspector = true }
        try await shot("palette-light.png") { app.showInspector = false; app.showQuickOpen = true }
        try await shot("read-light.png", wait: 14) { app.showQuickOpen = false; app.review.scope = .book; app.reviewMode = true }
        try await shot("history-light.png", wait: 5) { app.reviewMode = false; app.inspectorTab = .history; app.showInspector = true }

        // Two versions of the same chapter, side by side, what differs marked.
        s.tryAnotherVersion(named: "Darker", blank: false, currentName: "First draft")
        try await Task.sleep(for: .seconds(0.5))
        var darker = s.text
        for (from, to) in [("The ferry left at six, before the gulls were awake.", "The ferry left in the dark."),
                           ("as if he might still ask for it.", "as if he might still come up the stairs and ask for it."),
                           ("Below, the water kept its own counsel.", "Below, the water was black and did not move."),
                           ("which was worse, and which was more like him.", "which was what he had always done.")] {
            darker = darker.replacingOccurrences(of: from, with: to)
        }
        s.text = darker
        s.flushSave()
        try await shot("versions-light.png", wait: 1.5) {
            app.showInspector = false
            s.showBeside(s.versions.first { $0 != s.editingVersion })
        }
        s.showBeside(nil)

        // An editor's corrections and comments, in Revise mode.
        s.open("02")
        try await shot("revise-light.png", wait: 1.5) {
            bridge.trackChanges = true
            app.inspectorTab = .edits; app.showInspector = true
        }
    }
}
