import SwiftUI
import XCTest
@testable import Musset

/// Screenshots for the website, in one language: the whole window on a demo book (its chapters, its Bible, a board,
/// its history), a window of panes as one parks it on a second screen, the typeset PDF and its country's manuscript.
/// MUSSET_SITE_SHOTS=<dir>, MUSSET_SITE_LANG=en|fr|de|es|it|pt (scripts/site-shots.sh runs them all).
/// The demo book and everything said about it are in SiteDemo/<lang>.json: original text, written for these pictures.
/// The board's layout is here, the same in every language; only its words come from the demo.
@MainActor
final class SiteShots: XCTestCase {
    struct Demo: Decodable {
        struct Chapter: Decodable { let title: String; let text: String }
        struct NoteSpec: Decodable { let anchor: String; let author: String; let kind: String; let body: String }
        struct Message: Decodable { let role: String; let text: String }
        struct Versions: Decodable { let current: String; let other: String; let edits: [[String]] }
        /// A sheet of the Bible. `fields`: born, occupation, wants, hides (characters). `facts`: chapter, fact, the
        /// book's words. `found`: other names the text gives them. `tier`: where the cast shows them.
        struct Sheet: Decodable {
            let id: String, name: String, aliases: [String], body: String
            let tier: String?, fields: [String]?, found: [String]?, facts: [[String]]?
        }
        struct Bible: Decodable { let characters: [Sheet]; let places: [Sheet] }
        /// The words of the planning wall (`SiteShots.board` lays them out).
        struct Board: Decodable {
            let title: String, labels: [String: String], columns: [String], written: [String], passage: String
            let next: [String], notes: [String: String], shape: String
        }
        struct History: Decodable { let milestone: String; let note: String }
        let uiLang: String, bookLang: String, title: String, author: String
        let chapters: [Chapter], notes: [NoteSpec], chat: [Message], versions: Versions
        let bible: Bible?, board: Board?, history: History?
    }

    private static let ids = ["01", "02", "03"]

    func testSiteShots() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["MUSSET_SITE_SHOTS"] else { throw XCTSkip("set MUSSET_SITE_SHOTS") }
        let code = env["MUSSET_SITE_LANG"] ?? "en"
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("SiteDemo/\(code).json")
        let demo = try JSONDecoder().decode(Demo.self, from: Data(contentsOf: file))
        let bibleDemo = try XCTUnwrap(demo.bible), boardDemo = try XCTUnwrap(demo.board), historyDemo = try XCTUnwrap(demo.history)
        let out = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let d = UserDefaults.standard
        let saved = (d.string(forKey: UILang.key), d.stringArray(forKey: "libraryPaths"), d.string(forKey: "lastBook"), d.object(forKey: "sideBySideDiff"))
        defer {
            d.set(saved.0, forKey: UILang.key); d.set(saved.1, forKey: "libraryPaths"); d.set(saved.2, forKey: "lastBook")
            d.set(saved.3, forKey: "sideBySideDiff")
        }
        d.set(demo.uiLang, forKey: UILang.key)
        d.set(true, forKey: "sideBySideDiff")
        d.removeObject(forKey: "libraryPaths"); d.removeObject(forKey: "lastBook")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(demo.title)
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let ids = Self.ids
        for (id, ch) in zip(ids, demo.chapters) {
            try Typography.correctedDocument(ch.text, lang: demo.bookLang).text.write(to: root.appendingPathComponent("\(id).md"), atomically: true, encoding: .utf8)
        }
        var m = BookManifest(title: demo.title, author: demo.author, lang: demo.bookLang, chapters: zip(ids, demo.chapters).enumerated().map { i, pair in
            ChapterEntry(id: pair.0, file: "\(pair.0).md", title: pair.1.title, status: i == 0 ? .edited : .draft)
        })
        m.sceneBreak = .asterism
        try BookStore(root: root).saveManifest(m)
        let git = GitService(root: root)
        try git.initRepo()
        _ = try git.commit(paths: ids.map { "\($0).md" } + [".musset"], message: "start")

        // The Bible: the author's sheets, what the book says about them, and the planning wall.
        let sheets = try Self.writeBible(bibleDemo, root: root)
        let boardPath = "\(BibleKind.board.folder)/\(boardDemo.title).canvas"
        try Self.board(boardDemo, sheets: sheets).write(BibleStore(root: root).url(boardPath))
        let tom = try XCTUnwrap(sheets["tom"])

        // The typeset book: 120 × 188 mm, facing pages, as it would go to the printer; and the manuscript as the
        // book's country expects it.
        var book = ExportPreset(id: "site-book", name: "Book", format: .pdf, style: "book")
        book.facing = true
        let norm = ManuscriptNorm.for(BookLanguage(code: demo.bookLang)).preset
        for (preset, name) in [(book, "book.pdf"), (norm, "manuscript.pdf")] {
            let pdf = try await ExportService.export(manifest: m, store: BookStore(root: root), preset: preset)
            try? FileManager.default.removeItem(at: out.appendingPathComponent(name))
            try FileManager.default.copyItem(at: pdf.file, to: out.appendingPathComponent(name))
        }

        let app = AppState()
        app.openBook(root)
        let s = try XCTUnwrap(app.current)
        s.open("01")
        // The cast as the author sees it in a whole book: where three short chapters count otherwise, the sheet is
        // kept in its column, as dropping it there does.
        func keepCast(_ s: BookSession, _ sheets: [String: String]) async throws {
            s.refreshBibleMentions()
            try await Task.sleep(for: .seconds(0.6))
            for sheet in bibleDemo.characters {
                guard let wanted = sheet.tier.flatMap(NameTier.init(rawValue:)), let path = sheets[sheet.id], var e = s.bible.entry(path: path),
                      s.bible.tier(of: e) != wanted else { continue }
                e.meta["tier"] = wanted.rawValue
                try s.bible.save(e)
            }
            s.refreshBibleMentions()
        }
        try await keepCast(s, sheets)
        // A passage as it stands in the book: the demo's words, or the same after the book's typography.
        func find(_ words: String) -> NSRange {
            let ns = s.text as NSString
            let r = ns.range(of: words)
            return r.location != NSNotFound ? r : ns.range(of: Typography.correctedDocument(words, lang: demo.bookLang).text)
        }
        for n in demo.notes {
            let r = find(n.anchor)
            XCTAssertNotEqual(r.location, NSNotFound, "\(code): no passage « \(n.anchor) »")
            guard r.location != NSNotFound else { continue }
            s.notes.add(range: r, text: s.text, author: Note.Author(rawValue: n.author) ?? .claude, kind: Note.Kind(rawValue: n.kind) ?? .note, body: n.body)
        }

        let bridge = EditorBridge(), chat = ChatModel(), ann = Annotator(), proof = AutoProofreader()
        bridge.annotator = ann; bridge.proof = proof
        bridge.openSheet = { app.open(.sheet($0)) }
        let view = ContentView(app: app, bridge: bridge, chat: chat, pangram: PangramModel(), proof: proof, annotator: ann)
        // On the Retina screen, so the pictures are drawn at 2× (a window on no screen draws at 1×). Never shown.
        // 1440 × 900 points in all, its title bar included: 1920 × 1200 once on the site.
        let retina = NSScreen.screens.max { $0.backingScaleFactor < $1.backingScaleFactor }
        let size = NSSize(width: 1440, height: 900)
        // The content goes under the title bar, which takes its height from the room left to the view.
        let probe = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: true)
        let bar = probe.frame.height - size.height
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: size.width, height: size.height - bar), styleMask: [.titled, .fullSizeContentView],
                              backing: .buffered, defer: false, screen: retina)
        window.contentView = NSHostingView(rootView: view.frame(width: size.width, height: size.height - bar))
        func capture(_ v: NSView, _ name: String) throws {
            let rep = try XCTUnwrap(v.bitmapImageRepForCachingDisplay(in: v.bounds))
            v.cacheDisplay(in: v.bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: out.appendingPathComponent(name))
        }
        func shot(_ name: String, wait: TimeInterval = 1.2, _ setup: () -> Void) async throws {
            window.appearance = NSAppearance(named: .aqua)
            setup()
            // Sleeping, not spinning the run loop: typesetting and the history finish on the main actor meanwhile.
            try await Task.sleep(for: .seconds(wait))
            try capture(window.contentView!, name)
        }
        try await shot("write-light.png") { app.showInspector = false }
        try await shot("notes-light.png") { app.inspectorTab = .edits; app.showInspector = true }
        chat.messages = demo.chat.map { msg in
            msg.role == "user" ? ChatMessage(role: .user, text: msg.text)
                : ChatMessage(role: .assistant, agent: .claude, text: msg.text, action: .style, notesAdded: 3)
        }
        try await shot("chat-light.png") { app.inspectorTab = .chat; app.showInspector = true }
        try await shot("palette-light.png") { app.showInspector = false; app.showQuickOpen = true }
        try await shot("read-light.png", wait: 14) { app.showQuickOpen = false; app.review.scope = .book; app.reviewMode = true }
        app.reviewMode = false

        // The Bible: a character's sheet in two parts (the author's, and what the book says), then the cast.
        try await shot("bible-light.png", wait: 1.5) { app.showInspector = false; app.open(.sheet(tom)) }
        try await shot("cast-light.png", wait: 1.5) { app.open(.folder(BibleKind.character.folder)) }

        // Two panes: the chapter being written, and the wall beside it, closer in on the family.
        BoardCamera.kept[boardPath] = (CGSize(width: Self.besideChapter.pan.x, height: Self.besideChapter.pan.y), Self.besideChapter.zoom)
        try await shot("panes-light.png", wait: 2) {
            s.open("01")
            s.workspace.open(.sheet(boardPath), in: .split(.right))
        }
        // Back to the chapter alone, as the pictures that follow want it.
        s.workspace.closeAll(.sheet(boardPath))

        // The chapter as scene cards, then the whole book from further away.
        try await shot("scenes-light.png", wait: 2) { s.workspace.toggleSceneCards() }
        s.workspace.toggleSceneCards()
        try await shot("overview-light.png", wait: 2.5) { app.open(OverviewTab.summary.tab) }
        s.workspace.closeAll(OverviewTab.summary.tab)
        s.open("01")

        // Ultra Focus: the whole screen, the chapter so far dimmed above, the paragraph being written under it.
        do {
            let paragraphs = UltraFocus.readable(s.text).components(separatedBy: "\n").filter { !$0.isEmpty }
            let last = paragraphs.last ?? ""
            let written = String(last.prefix(last.count * 3 / 5))
            let model = UltraFocusModel()
            model.context = paragraphs.dropLast().joined(separator: "\n")
            let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false, screen: retina)
            w.contentView = NSHostingView(rootView: UltraFocusView(model: model) {})
            w.setFrame(NSRect(origin: .zero, size: size), display: true)
            try await Task.sleep(for: .seconds(1))
            func editor(_ v: NSView) -> ForwardOnlyTextView? { v as? ForwardOnlyTextView ?? v.subviews.lazy.compactMap(editor).first }
            let tv = try XCTUnwrap(editor(w.contentView!))
            tv.insertText(String(written[..<(written.lastIndex(of: " ") ?? written.endIndex)]), replacementRange: NSRange(location: tv.floor, length: 0))
            // Twice: the first sets the room above and below, the second scrolls once that is laid out.
            tv.place()
            try await Task.sleep(for: .seconds(0.6))
            // Offscreen, the text view grows without its origin following: back to the top before scrolling.
            tv.sizeToFit()
            tv.setFrameOrigin(.zero)
            tv.place()
            try await Task.sleep(for: .seconds(0.6))
            try capture(w.contentView!, "ultra-dark.png")
        }
        s.workspace.closeAll(.folder(BibleKind.character.folder))
        s.open("01")
        try await Task.sleep(for: .seconds(0.5))
        BoardCamera.kept[boardPath] = nil

        // A window of the book's own (what a tab dragged out of the main window becomes): the wall filling it,
        // by day and by night; then the sheet and the wall side by side, for a second screen.
        func paneWindow(_ id: String) -> NSWindow {
            let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false, screen: retina)
            w.title = demo.title
            w.appearance = NSAppearance(named: .aqua)
            w.contentView = NSHostingView(rootView: PaneWindow(app: app, bridge: bridge, proof: proof,
                                                               ref: WindowRef(bookPath: root.standardizedFileURL.path, windowID: id)))
            w.setFrame(NSRect(origin: .zero, size: size), display: true)
            return w
        }
        // The window with its title bar: the frame around the content.
        func frame(of w: NSWindow) -> NSView { w.contentView?.superview ?? w.contentView! }
        let wallID = s.newWindow(with: .sheet(boardPath))
        let wall = paneWindow(wallID)
        try await Task.sleep(for: .seconds(2))
        try capture(frame(of: wall), "board-light.png")
        wall.appearance = NSAppearance(named: .darkAqua)
        try await Task.sleep(for: .seconds(1))
        try capture(frame(of: wall), "board-dark.png")
        wall.contentView = nil
        s.closeWindow(wallID)
        try await Task.sleep(for: .seconds(0.5))

        BoardCamera.kept[boardPath] = (CGSize(width: Self.secondScreen.pan.x, height: Self.secondScreen.pan.y), Self.secondScreen.zoom)
        let secondID = s.newWindow(with: .sheet(tom))
        if let ws = s.windows[secondID] {
            ws.open(.sheet(boardPath), in: .split(.right))
            ws.resize([], fractions: [0.42, 0.58])
        }
        let second = paneWindow(secondID)
        try await Task.sleep(for: .seconds(2))
        try capture(frame(of: second), "second-light.png")
        second.contentView = nil
        s.closeWindow(secondID)
        try await Task.sleep(for: .seconds(0.5))
        BoardCamera.kept[boardPath] = nil

        // Two versions of the same chapter, side by side, what differs marked.
        s.tryAnotherVersion(named: demo.versions.other, blank: false, currentName: demo.versions.current)
        try await Task.sleep(for: .seconds(0.5))
        var darker = s.text as NSString
        for edit in demo.versions.edits where edit.count == 2 {
            let r = darker.range(of: edit[0]).location != NSNotFound ? darker.range(of: edit[0])
                : darker.range(of: Typography.correctedDocument(edit[0], lang: demo.bookLang).text)
            XCTAssertNotEqual(r.location, NSNotFound, "\(code): no passage « \(edit[0]) » to rewrite")
            guard r.location != NSNotFound else { continue }
            darker = darker.replacingCharacters(in: r, with: Typography.correctedDocument(edit[1], lang: demo.bookLang).text) as NSString
        }
        s.text = darker as String
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
        bridge.trackChanges = false

        // The book's history: six weeks of sittings, a milestone, a track still open. A book of its own, since
        // sittings are dated by git and this one was written in a minute.
        let past = try Self.bookWithAPast(demo, history: historyDemo)
        defer { try? FileManager.default.removeItem(at: past.deletingLastPathComponent()) }
        let pastSheets = try Self.writeBible(bibleDemo, root: past)
        try Self.board(boardDemo, sheets: pastSheets).write(BibleStore(root: past).url(boardPath))
        app.openBook(past)
        let h = try XCTUnwrap(app.current)
        h.open("01")
        try await keepCast(h, pastSheets)
        try await shot("history-light.png", wait: 2.5) { app.showInspector = false; app.open(.story) }
    }

    // MARK: The Bible

    /// Writes the sheets and what the book says about them; returns each sheet's path by its id in the demo.
    private static func writeBible(_ bible: Demo.Bible, root: URL) throws -> [String: String] {
        let store = BibleStore(root: root)
        var paths: [String: String] = [:]
        var facts = BookFacts()
        for (kind, list) in [(BibleKind.character, bible.characters), (.place, bible.places)] {
            for sheet in list {
                var e = BibleEntry(path: store.freePath(title: sheet.name, folder: kind.folder), kind: kind, title: sheet.name, aliases: sheet.aliases)
                if let values = sheet.fields {
                    e.fields = zip(kind.suggestedFields, values).map { .init(name: $0, value: $1) }
                }
                e.body = sheet.body + "\n"
                try store.write(e)
                paths[sheet.id] = e.path
                let said = (sheet.facts ?? []).filter { $0.count == 3 }.map { BookFacts.Fact(text: $0[1], chapter: $0[0], quote: $0[2]) }
                if !said.isEmpty || sheet.found?.isEmpty == false {
                    facts.entities[e.path] = .init(facts: said, aliases: sheet.found ?? [])
                }
            }
        }
        // Read already: nothing to read again.
        for id in ids {
            facts.read[id] = PlotGrid.fingerprint((try? String(contentsOf: root.appendingPathComponent("\(id).md"), encoding: .utf8)) ?? "")
        }
        try facts.save(root)
        return paths
    }

    // MARK: The wall

    /// Where the wall is looked at from beside a chapter (the family, closer in) and on a second screen (what
    /// happens and the island).
    private static let besideChapter = (pan: CGPoint(x: 40, y: 104), zoom: CGFloat(1.1))
    private static let secondScreen = (pan: CGPoint(x: -372, y: 112), zoom: CGFloat(0.88))

    /// A novelist's planning wall for the demo book: the family on the left with what ties it, the book act by act
    /// in two columns, the island and its open questions on the right. One layout for every language.
    static func board(_ words: Demo.Board, sheets: [String: String]) -> JSONCanvas {
        typealias Node = JSONCanvas.Node
        var c = JSONCanvas()
        func add(_ n: Node) -> String { c.nodes.append(n); return n.id }
        func label(_ key: String, x: Int, y: Int, width: Int = 320) -> String {
            add(Node(type: .text, x: x, y: y, width: width, height: 36, text: words.labels[key] ?? "", musset: ["kind": "label"]))
        }
        func sheet(_ id: String, x: Int, y: Int, width: Int = 198, height: Int = 117) -> String {
            add(Node(type: .file, x: x, y: y, width: width, height: height, file: sheets[id] ?? ""))
        }
        func note(_ text: String, x: Int, y: Int, width: Int, height: Int, color: String? = nil) -> String {
            add(Node(type: .text, x: x, y: y, width: width, height: height, color: color, text: text))
        }
        func arrow(_ from: String, _ fromSide: BoardSide, _ to: String, _ toSide: BoardSide) {
            c.edges.append(.init(fromNode: from, toNode: to, fromSide: fromSide.rawValue, toSide: toSide.rawValue))
        }
        /// How wide a label's words are on the board (Inter semibold, 22 points).
        func width(of key: String) -> CGFloat {
            let font = NSFontManager.shared.font(withFamily: Typefaces.ui, traits: [], weight: 8, size: 22) ?? .systemFont(ofSize: 22, weight: .semibold)
            return ((words.labels[key] ?? "") as NSString).size(withAttributes: [.font: font]).width
        }

        // Columns first: they lie under their cards.
        let top = 54, colH = 540
        _ = add(Node(type: .group, x: 459, y: top, width: 252, height: colH, label: words.columns[0]))
        _ = add(Node(type: .group, x: 729, y: top, width: 252, height: colH, label: words.columns[1]))

        // The family.
        _ = label("family", x: 0, y: 0)
        let walter = sheet("walter", x: 0, y: top), maud = sheet("maud", x: 216, y: top)
        let nora = sheet("nora", x: 0, y: 225), tomCard = sheet("tom", x: 216, y: 225)
        let list = note(words.notes["list"] ?? "", x: 0, y: 396, width: 198, height: 135, color: "3")
        let boat = add(Node(type: .text, x: 225, y: 405, width: 180, height: 117, color: "5", text: words.shape, musset: ["kind": "shape", "shape": "ellipse"]))
        arrow(walter, .bottom, nora, .top)
        arrow(maud, .bottom, tomCard, .top)
        arrow(nora, .bottom, list, .top)
        arrow(list, .right, boat, .left)
        arrow(tomCard, .bottom, boat, .top)

        // What happens: written, then still to write (green).
        _ = label("story", x: 459, y: 0)
        let rows = [99, 219, 339, 459]
        let crossing = [words.written[0], words.written[1], nil, words.written[2]]
        var first: [String] = []
        for (y, text) in zip(rows, crossing) {
            if let text {
                first.append(note(text, x: 477, y: y, width: 216, height: 108))
            } else {
                first.append(add(Node(type: .text, x: 477, y: y, width: 216, height: 108, text: "> " + words.passage,
                                      musset: ["kind": "passage", "chapter": "01", "quote": words.passage])))
            }
        }
        var second: [String] = []
        for (i, (y, text)) in zip(rows, words.next).enumerated() {
            second.append(note(text, x: 747, y: y, width: 216, height: 108, color: i >= 2 ? "4" : nil))
        }
        arrow(boat, .right, first[3], .left)

        // The island: its places, and what is still not known.
        let islandX = 1017
        _ = label("island", x: islandX, y: 0)
        let works = sheet("saltworks", x: islandX, y: top, width: 334, height: 99)
        _ = sheet("harbour", x: islandX, y: 171, width: 334, height: 99)
        let year = label("year", x: islandX + 27, y: 315, width: 108)
        let ringed = note(words.notes["year"] ?? "", x: islandX + 158, y: 297, width: 176, height: 117, color: "3")
        _ = note(words.notes["boat"] ?? "", x: islandX, y: 450, width: 158, height: 144, color: "1")
        let tide = note(words.notes["tide"] ?? "", x: islandX + 176, y: 450, width: 158, height: 144, color: "5")
        arrow(second[0], .right, works, .left)
        arrow(second[1], .right, year, .left)
        arrow(ringed, .bottom, tide, .top)

        // The marker: a highlighter over « the family », the island underlined twice, the year ringed in red.
        let family = width(of: "family")
        let over = (0...24).map { i -> CGPoint in
            let t = CGFloat(i) / 24
            return CGPoint(x: 6 + t * (family + 6), y: 15 + 1.6 * sin(t * 5) - 2 * t)
        }
        if let n = BoardInk.make(over, width: 17, color: "3", highlighter: true) { c.nodes.append(n) }
        let island = width(of: "island")
        for (dy, shorter) in [(CGFloat(31), CGFloat(0)), (36, 0.22)] {
            let line = (0...20).map { i -> CGPoint in
                let t = CGFloat(i) / 20
                return CGPoint(x: CGFloat(islandX) - 2 + t * (island + 8) * (1 - shorter) + (shorter > 0 ? 5 : 0), y: dy + 1.2 * sin(t * 6 + dy) - 1.5 * t)
            }
            if let n = BoardInk.make(line, width: 2.5, color: "5", highlighter: false) { c.nodes.append(n) }
        }
        let date = width(of: "year")
        let centre = CGPoint(x: CGFloat(islandX + 27) + date / 2, y: 315 + 14)
        let ring = (0...44).map { i -> CGPoint in
            // One turn and a little more, as a hand closes a circle: it ends inside where it began.
            let t = CGFloat(i) / 44
            let a = -2.5 + t * 2 * .pi * 1.08
            let r = 1 - 0.1 * t + 0.03 * sin(t * 9)
            return CGPoint(x: centre.x + (date / 2 + 20) * r * cos(a) + 2 * sin(a), y: centre.y + 25 * r * sin(a) - 4 * cos(a) * 0.5)
        }
        if let n = BoardInk.make(ring, width: 3, color: "1", highlighter: false) { c.nodes.append(n) }
        return c
    }

    // MARK: A book with a past

    /// The demo book as six weeks of work would have left it: sittings on their days, a milestone, and a track that
    /// left the manuscript and is still open. Written with git itself, which alone can date a commit in the past.
    private static func bookWithAPast(_ demo: Demo, history: Demo.History) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("musset-site-\(UUID().uuidString)/\(demo.title)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let texts = demo.chapters.map { Typography.correctedDocument($0.text, lang: demo.bookLang).text }
        func write(_ chapter: Int, upTo share: Double) throws {
            let blocks = texts[chapter].components(separatedBy: "\n\n")
            let n = max(1, min(blocks.count, Int((Double(blocks.count) * share).rounded())))
            try (blocks.prefix(n).joined(separator: "\n\n") + "\n").write(to: root.appendingPathComponent("\(ids[chapter]).md"), atomically: true, encoding: .utf8)
        }
        var m = BookManifest(title: demo.title, author: demo.author, lang: demo.bookLang, chapters: zip(ids, demo.chapters).map {
            ChapterEntry(id: $0.0, file: "\($0.0).md", title: $0.1.title, status: .draft)
        })
        m.sceneBreak = .asterism
        try BookStore(root: root).saveManifest(m)
        for i in ids.indices { try write(i, upTo: 0) }

        let calendar = Calendar.current
        func day(_ ago: Int, _ hour: Int, _ minute: Int) -> Date {
            let d = calendar.date(byAdding: .day, value: -ago, to: Date()) ?? Date()
            return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: d) ?? d
        }
        @discardableResult func git(_ args: [String], at date: Date? = nil) throws -> String {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = ["-C", root.path, "-c", "commit.gpgsign=false", "-c", "tag.gpgsign=false", "-c", "core.hooksPath=/dev/null"] + args
            var e = ProcessInfo.processInfo.environment
            e["GIT_AUTHOR_NAME"] = demo.author; e["GIT_COMMITTER_NAME"] = demo.author
            e["GIT_AUTHOR_EMAIL"] = "author@example.com"; e["GIT_COMMITTER_EMAIL"] = "author@example.com"
            e["GIT_CONFIG_GLOBAL"] = "/dev/null"
            if let date {
                let stamp = "@\(Int(date.timeIntervalSince1970)) +0000"
                e["GIT_AUTHOR_DATE"] = stamp; e["GIT_COMMITTER_DATE"] = stamp
            }
            p.environment = e
            let pipe = Pipe()
            p.standardOutput = pipe; p.standardError = pipe
            try p.run()
            let said = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            p.waitUntilExit()
            XCTAssertEqual(p.terminationStatus, 0, "git \(args.joined(separator: " ")): \(said)")
            return said.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func sitting(_ chapter: Int, _ share: Double, _ date: Date) throws -> String {
            try write(chapter, upTo: share)
            try git(["add", "-A"])
            try git(["commit", "-q", "-m", "musset: edit \(ids[chapter])"], at: date)
            return try git(["rev-parse", "HEAD"])
        }
        try git(["init", "-q", "-b", "main"])
        _ = try sitting(0, 0.3, day(41, 9, 12))
        _ = try sitting(0, 0.45, day(39, 8, 47))
        _ = try sitting(0, 0.6, day(38, 21, 30))
        _ = try sitting(0, 0.75, day(34, 9, 5))
        _ = try sitting(1, 0.4, day(32, 7, 58))
        _ = try sitting(0, 0.9, day(30, 22, 10))
        let sent = try sitting(0, 1, day(27, 9, 20))
        try git(["tag", "-a", "jalon/" + Pistes.slug(history.milestone, taken: []), "-m", history.milestone + "\n\n" + history.note, sent], at: day(27, 18, 40))
        let fork = try sitting(1, 0.8, day(20, 8, 50))

        // The track: the darker version of the first chapter, tried on its own line.
        var piste = Piste(id: Pistes.slug(demo.versions.other, taken: []), name: demo.versions.other, created: day(19, 9, 0), from: L("the manuscript"))
        piste.start = fork
        try git(["checkout", "-q", "-b", piste.branch])
        var darker = texts[0]
        for (edits, date) in [(demo.versions.edits.prefix(1), day(19, 9, 30)), (demo.versions.edits.dropFirst(1).prefix(1), day(16, 21, 15)), (demo.versions.edits.dropFirst(2), day(13, 8, 20))] {
            for edit in edits where edit.count == 2 {
                for from in [edit[0], Typography.correctedDocument(edit[0], lang: demo.bookLang).text] where darker.contains(from) {
                    darker = darker.replacingOccurrences(of: from, with: Typography.correctedDocument(edit[1], lang: demo.bookLang).text)
                    break
                }
            }
            try darker.write(to: root.appendingPathComponent("\(ids[0]).md"), atomically: true, encoding: .utf8)
            try git(["add", "-A"])
            try git(["commit", "-q", "-m", "musset: edit \(ids[0])"], at: date)
        }
        try git(["checkout", "-q", "main"])
        try Pistes.save([piste], root: root)
        _ = try sitting(1, 1, day(12, 9, 15))
        _ = try sitting(2, 1, day(5, 8, 40))
        return root
    }
}
