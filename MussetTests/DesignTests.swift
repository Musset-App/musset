import XCTest
import SwiftUI
@testable import Musset

@MainActor
final class DesignTests: XCTestCase {
    private func makeBook() throws -> BookSession {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("musset-design-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let one = "# Le Grenier\n\n<!-- scene: La malle -->\nIl pleuvait depuis le matin. Je suis monté au grenier et j’ai ouvert la vieille malle.\n\nLa clé a tourné du premier coup.\n\n<!-- scene: Les lettres -->\nSous les couvertures, il y avait une boîte de lettres nouées d’un ruban.\n"
        try one.write(to: root.appendingPathComponent("01.md"), atomically: true, encoding: .utf8)
        try "# Le port\n\nUn chapitre sans scènes, au soleil.\n".write(to: root.appendingPathComponent("02.md"), atomically: true, encoding: .utf8)
        var m = BookManifest(title: "Le Sel", author: "Jeanne Martin", lang: "fr", chapters: [
            ChapterEntry(id: "01", file: "01.md", title: "Le Grenier", status: .edited),
            ChapterEntry(id: "02", file: "02.md", title: "Le port", status: .final)])
        m.front = FrontMatter(cover: .init(genre: "roman", publisher: "[ÉDITEUR]"), dedication: "À ceux qui restent.", contents: true, colophon: true)
        let s = BookSession(root: root, manifest: m)
        s.open("01")
        return s
    }

    func testDroppedChapterMoves() throws {
        let s = try makeBook()
        s.moveChapters(ids: ["01"], to: 2)
        XCTAssertEqual(s.manifest.chapters.map(\.id), ["02", "01"])
        XCTAssertEqual(try BookStore(root: s.root).loadManifest().chapters.map(\.id), ["02", "01"])
        s.moveChapters(ids: ["texte tiré de la page"], to: 0)
        XCTAssertEqual(s.manifest.chapters.map(\.id), ["02", "01"], "only a chapter moves")
    }

    func testSpecialPagesTypst() throws {
        let s = try makeBook()
        let pages = Typesetting.pages(s.manifest, coverImage: nil)
        XCTAssertEqual(pages.dedication, "À ceux qui restent.")
        XCTAssertNotNil(pages.cover); XCTAssertNotNil(pages.titlePage); XCTAssertNotNil(pages.contents)
        XCTAssertNil(pages.epigraph); XCTAssertNil(pages.acknowledgements)
        let doc = try Typeset.book([("01", "# Un\n\nTexte.")], title: "Le Sel", author: "Jeanne Martin", pages: pages).typstSource
        XCTAssertTrue(doc.contains("smallcaps[Le Sel]"))
        XCTAssertTrue(doc.contains("JEANNE MARTIN"), "the author on the cover")
        XCTAssertTrue(doc.contains("qui restent"))
        XCTAssertTrue(doc.contains("#outline(title: none"))
        XCTAssertLessThan(doc.range(of: "fill: rgb")!.lowerBound, doc.range(of: "smallcaps")!.lowerBound, "cover first, then the title page")
        XCTAssertTrue(doc.contains("Achevé d’imprimer"))
        XCTAssertFalse(doc.contains("image("), "no image without the image style")
        XCTAssertLessThan(doc.range(of: "#outline")!.lowerBound, doc.range(of: "= Un")!.lowerBound)
        XCTAssertGreaterThan(doc.range(of: "Achevé")!.lowerBound, doc.range(of: "= Un")!.lowerBound)
        XCTAssertTrue(ExportService.pandocFront(s.manifest).contains("qui restent"))
    }

    /// The special pages compile in Typst: a real PDF with the cover, dedication, contents and colophon.
    func testTypstExportWithSpecialPages() async throws {
        let s = try makeBook()
        var m = s.manifest
        m.front?.epigraph = "Chaque chose, autant qu’il est en elle,\ns’efforce de persévérer dans son être."
        m.front?.epigraphSource = "Spinoza"
        m.front?.acknowledgements = "Merci."
        m.sceneBreak = .asterism
        let preset = try XCTUnwrap(s.store.presets(m).first { $0.format == .pdf })
        let out = try await ExportService.export(manifest: m, store: s.store, preset: preset)
        let data = try Data(contentsOf: out.file)
        XCTAssertGreaterThan(data.count, 5000)
        XCTAssertEqual(String(data: data.prefix(4), encoding: .ascii), "%PDF")
        if let dir = ProcessInfo.processInfo.environment["MUSSET_SNAPSHOT"] {
            try? FileManager.default.removeItem(atPath: dir + "/d-export.pdf")
            try FileManager.default.copyItem(atPath: out.file.path, toPath: dir + "/d-export.pdf")
        }
    }

    func testInterfaceLanguage() {
        let d = UserDefaults.standard
        let old = d.string(forKey: UILang.key)
        defer { d.set(old, forKey: UILang.key) }
        d.set("fr", forKey: UILang.key)
        XCTAssertEqual(ChapterStatus.edited.label, "Révisé")
        XCTAssertEqual(Note.Kind.praise.label, "Réussite")
        d.set("en", forKey: UILang.key)
        XCTAssertEqual(ChapterStatus.edited.label, "Edited")
        XCTAssertEqual(ChapterSidebar.compact(1248), "1.2k")
    }

    /// Renders the new screens, in French. MUSSET_SNAPSHOT=<dir>.
    func testDesignSnapshots() throws {
        guard let dir = ProcessInfo.processInfo.environment["MUSSET_SNAPSHOT"] else { throw XCTSkip("set MUSSET_SNAPSHOT") }
        let d = UserDefaults.standard
        let old = d.string(forKey: UILang.key)
        defer { d.set(old, forKey: UILang.key) }
        d.set("fr", forKey: UILang.key)
        let s = try makeBook()
        let app = AppState()
        let bridge = EditorBridge()
        let ann = Annotator()
        let text = s.text as NSString
        s.notes.add(range: text.range(of: "ouvert la vieille malle"), text: s.text, author: .claude, kind: .critique, body: "« Ouvert » : le geste passe vite. Que voit-il d’abord ?")
        s.notes.add(range: text.range(of: "La clé a tourné du premier coup."), text: s.text, author: .claude, kind: .praise, body: "Sèche et juste.")
        func png(_ view: some View, _ size: NSSize, _ name: String) throws {
            let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height).environment(\.colorScheme, .light))
            host.appearance = NSAppearance(named: .aqua)
            host.frame = NSRect(origin: .zero, size: size)
            let w = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            w.contentView = host
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
        }
        try png(ChapterSidebar(session: s, app: app, bridge: bridge), NSSize(width: 260, height: 520), "d-sidebar.png")
        try png(NotesPanel(app: app, session: s, bridge: bridge, annotator: ann, proof: AutoProofreader()), NSSize(width: 380, height: 520), "d-notes.png")
        try png(CommandPalette(app: app, session: s, bridge: bridge, chat: ChatModel(), annotator: ann), NSSize(width: 900, height: 700), "d-palette.png")
        try png(ExportSheet(session: s), NSSize(width: 780, height: 620), "d-export.png")
        try png(BookSettingsView(app: app, session: s), NSSize(width: 860, height: 600), "d-settings.png")
        try png(SpecialPageView(app: app, session: s, page: .cover), NSSize(width: 1100, height: 700), "d-cover.png")
        try png(SpecialPageView(app: app, session: s, page: .cover), NSSize(width: 1184, height: 900), "d-cover-big.png")
        try png(WelcomeView(app: app), NSSize(width: 580, height: 560), "d-newbook.png")
        let chat = ChatModel()
        chat.messages = [ChatMessage(role: .user, text: "La scène de l’arrivée tient-elle sans aucun dialogue ?"),
                         ChatMessage(role: .assistant, agent: .claude, text: "Oui, et c’est sa force : l’enfant enregistre des objets parce qu’il ne peut pas encore enregistrer le reste.\n\nCe qui l’affaiblit, c’est la dernière phrase.", action: .style, notesAdded: 3, model: "opus"),
                         ChatMessage(role: .assistant, agent: .endpoint, text: "La dernière phrase explique ce que la scène montrait déjà.", model: "openrouter|deepseek/deepseek-chat")]
        try png(ChatPanel(chat: chat, session: s, bridge: bridge), NSSize(width: 400, height: 640), "d-partner.png")
        try png(FeedbackSheet(kind: .problem), NSSize(width: 520, height: 470), "d-feedback.png")
        // The same sheet in dark mode, on the window's own background as a sheet has it.
        let dark = NSHostingView(rootView: FeedbackSheet(kind: .problem).frame(width: 520, height: 470)
            .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .dark))
        dark.appearance = NSAppearance(named: .darkAqua)
        dark.frame = NSRect(x: 0, y: 0, width: 520, height: 470)
        let darkWindow = NSWindow(contentRect: dark.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        darkWindow.appearance = NSAppearance(named: .darkAqua)
        darkWindow.contentView = dark
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let darkRep = dark.bitmapImageRepForCachingDisplay(in: dark.bounds)!
        dark.cacheDisplay(in: dark.bounds, to: darkRep)
        try darkRep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: dir).appendingPathComponent("d-feedback-dark.png"))
        try png(PlotGridView(app: app, session: s, bridge: bridge, analyst: PlotAnalyst(), planner: ScenePlanner()), NSSize(width: 1300, height: 420), "d-grid.png")
        try png(StatusBar(app: app, session: s, proof: AutoProofreader(), bridge: bridge).padding(20), NSSize(width: 520, height: 70), "d-status.png")
    }

    /// The whole window, screen by screen, as assembled in the app (sidebar, page, panel). MUSSET_SNAPSHOT=<dir>.
    func testWindowSnapshots() throws {
        guard let dir = ProcessInfo.processInfo.environment["MUSSET_SNAPSHOT"] else { throw XCTSkip("set MUSSET_SNAPSHOT") }
        let d = UserDefaults.standard
        let old = d.string(forKey: UILang.key)
        defer { d.set(old, forKey: UILang.key) }
        d.set("fr", forKey: UILang.key)
        let book = try makeBook()
        let app = AppState()
        app.openBook(book.root)
        let s = try XCTUnwrap(app.current)
        let text = s.text as NSString
        s.notes.add(range: text.range(of: "ouvert la vieille malle"), text: s.text, author: .claude, kind: .critique, body: "« Ouvert » : le geste passe vite. Que voit-il d’abord ?")
        let bridge = EditorBridge(), chat = ChatModel(), ann = Annotator(), proof = AutoProofreader()
        bridge.annotator = ann; bridge.proof = proof
        let view = ContentView(app: app, bridge: bridge, chat: chat, pangram: PangramModel(), proof: proof, annotator: ann)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900), styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = NSHostingView(rootView: view.frame(width: 1440, height: 900))
        func shot(_ name: String, _ setup: () -> Void) throws {
            setup()
            RunLoop.main.run(until: Date().addingTimeInterval(1.2))
            let v = window.contentView!
            let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds)!
            v.cacheDisplay(in: v.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
        }
        try shot("w-write.png") { app.showInspector = false }
        try shot("w-notes.png") { app.inspectorTab = .edits; app.showInspector = true }
        try shot("w-partner.png") { app.inspectorTab = .chat }
        try shot("w-grid.png") { app.showInspector = false; app.open(OverviewTab.grid.tab) }
        try shot("w-special.png") { app.open(SpecialPage.cover.tab) }
        RunLoop.main.run(until: Date().addingTimeInterval(3))
        try shot("w-special2.png") {}
        try shot("w-palette.png") { app.showChapter(); app.showQuickOpen = true }
        try shot("w-read.png") { app.showQuickOpen = false; app.review.scope = .book; app.reviewMode = true }
        RunLoop.main.run(until: Date().addingTimeInterval(4))
        try shot("w-read.png") {}
    }
}

@MainActor
final class TitleBarSnapshotTests: XCTestCase {
    /// A long scene title with a track and versions, at the widths a window takes. MUSSET_SNAPSHOT=<dir>.
    func testTitleBarWidths() throws {
        guard let dir = ProcessInfo.processInfo.environment["MUSSET_SNAPSHOT"] else { throw XCTSkip("set MUSSET_SNAPSHOT") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("musset-bar-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "# Quai de la Tournelle\n\n<!-- scene: Un -->\nUn.\n\n<!-- scene: L’ALPINE ET LE CHAMPS DES POSSIBLES -->\nDeux.\n".write(to: root.appendingPathComponent("01.md"), atomically: true, encoding: .utf8)
        let git = GitService(root: root)
        try git.initRepo()
        try git.commit(paths: ["01.md"], message: "first")
        let s = BookSession(root: root, manifest: BookManifest(title: "Le Sel", lang: "fr", chapters: [ChapterEntry(id: "01", file: "01.md", title: "Quai de la Tournelle")]))
        s.open("01")
        try s.store.saveVersion(XCTUnwrap(s.selectedChapter), name: "2026-11-02-1", text: ParagraphCodec.encode(s.text))
        s.refreshVersions()
        let bridge = EditorBridge()
        bridge.selectedRange = NSRange(location: (s.text as NSString).length - 1, length: 0)
        for w: CGFloat in [720, 1000, 1510, 1900] {
            let host = NSHostingView(rootView: TitleBar(app: AppState(), session: s, bridge: bridge).frame(width: w).environment(\.colorScheme, .dark))
            host.appearance = NSAppearance(named: .darkAqua)
            host.frame = NSRect(x: 0, y: 0, width: w, height: TitleBar.height)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: dir).appendingPathComponent("bar-\(Int(w)).png"))
        }
    }
}

@MainActor
final class InspectorSnapshotTests: XCTestCase {
    /// Each tab of the right-hand column on a copy of the fixture book, dark, in French. MUSSET_SNAPSHOT=<dir>.
    func testTabs() throws {
        guard let dir = ProcessInfo.processInfo.environment["MUSSET_SNAPSHOT"] else { throw XCTSkip("set MUSSET_SNAPSHOT") }
        let d = UserDefaults.standard
        let old = d.string(forKey: UILang.key), oldTab = d.string(forKey: "inspectorTab")
        defer { d.set(old, forKey: UILang.key); d.set(oldTab, forKey: "inspectorTab") }
        d.set("fr", forKey: UILang.key)
        let fm = FileManager.default
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("fixtures/conatus")
        let root = fm.temporaryDirectory.appendingPathComponent("musset-inspector-\(UUID().uuidString)")
        try fm.createDirectory(at: root.appendingPathComponent(".musset"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        for item in ["book.json", "plot.json", "scores", "notes", "proof"] {
            try fm.copyItem(at: fixture.appendingPathComponent(".musset/\(item)"), to: root.appendingPathComponent(".musset/\(item)"))
        }
        let manifest = try BookStore(root: root).loadManifest()
        for ch in manifest.chapters { try? fm.copyItem(at: fixture.appendingPathComponent(ch.file), to: root.appendingPathComponent(ch.file)) }
        let s = BookSession(root: root, manifest: manifest)
        s.open("05_chaumont")
        s.plot.setChapterSynopsis("05_chaumont", "Le chapitre tel que l’auteur le résume.")
        s.plot.setChapterSynopsis("00_exergue", "L’exergue, en une ligne.")
        let app = AppState()
        let bridge = EditorBridge(), chat = ChatModel(), ann = Annotator(), proof = AutoProofreader()
        bridge.annotator = ann; bridge.proof = proof
        // One fault in the proofreader's cache, so the panel shows its row whatever the fixture's holds for this text.
        let probe = AutoProofreader()
        probe.attach(s)
        let paragraph = try XCTUnwrap(probe.paragraphs(of: s.text).first { $0.text.count > 80 })
        let word = try XCTUnwrap(paragraph.text.split(separator: " ").map(String.init).first { $0.count > 4 && $0.allSatisfy(\.isLetter) })
        let fix: [String: Any] = ["original": word, "replacement": word + "s", "reason": "Accord", "kind": "obvious"]
        try JSONSerialization.data(withJSONObject: ["cache": [paragraph.hash: [fix]], "ignored": [String]()])
            .write(to: root.appendingPathComponent(".musset/proof/cache.json"))
        proof.attach(s)
        let first = try XCTUnwrap(s.scenes["05_chaumont"]?.first)

        func png(_ view: some View, _ name: String, size: NSSize = NSSize(width: 400, height: 860)) throws {
            let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height).background(Color(nsColor: .textBackgroundColor)).environment(\.colorScheme, .dark))
            host.appearance = NSAppearance(named: .darkAqua)
            host.frame = NSRect(origin: .zero, size: size)
            let w = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            w.appearance = NSAppearance(named: .darkAqua)
            w.contentView = host
            RunLoop.main.run(until: Date().addingTimeInterval(1))
            let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
        }
        func panel(_ tab: InspectorTab) -> some View {
            app.inspectorTab = tab
            return InspectorPanel(app: app, session: s, bridge: bridge, chat: chat, pangram: PangramModel(), proof: proof, annotator: ann, analyst: PlotAnalyst(), planner: ScenePlanner())
        }
        try png(panel(.edits), "i-edits.png")
        try png(NoteFilters(rows: [.init(key: "kind:todo", label: Note.Kind.todo.label, color: Note.Kind.todo.color, count: 3), .init(key: "kind:critique", label: Note.Kind.critique.label, color: Note.Kind.critique.color, count: 12), .init(key: "kind:continuity", label: Note.Kind.continuity.label, color: Note.Kind.continuity.color, count: 2), .init(key: "kind:praise", label: Note.Kind.praise.label, color: Note.Kind.praise.color, count: 81), .init(key: "faults", label: "Fautes", color: .red, count: 4)], hidden: ["kind:praise"], showFinished: .constant(false), finished: 40, showResolvedInText: .constant(false)) { _ in }, "i-filters.png", size: NSSize(width: 250, height: 340))
        try png(panel(.stats), "i-stats.png")
        // Two blind readings by different AIs, as they would be saved, and the rubric's window.
        let b = try XCTUnwrap(Bareme(migrating: Rubric.load(fixture)))
        func reading(_ agent: String, _ values: [Int]) -> Reading {
            let scores = zip(b.chapter, values).map { item, v in
                Reading.Score(criterionId: item.criterionId, label: b.criterion(item.criterionId)?.label ?? "", score: v, anchor: v >= 17 ? "19" : v >= 13 ? "15" : "10",
                              quotes: ["un passage cité"], justification: "Ce que fait le passage cité, en une phrase.")
            }
            return Reading(agent: agent, model: "", textHash: "h", baremeVersion: 1, baremeName: b.name, weights: b.weights, scores: scores, total: Scoring.total(weights: b.weights, scores: scores) ?? 0)
        }
        try b.save(root)
        try Reading.append(reading("claude", [11, 12, 10, 12, 13, 12, 13, 10, 12, 13]), root: root, chapter: "05_chaumont")
        try Reading.append(reading("codex", [12, 13, 11, 12, 12, 11, 14, 11, 13, 12]), root: root, chapter: "05_chaumont")
        try Reading.append(reading("claude", [13, 13, 12, 12, 14, 12, 15, 11, 13, 14]), root: root, chapter: "05_chaumont")
        try png(panel(.stats), "i-stats-blind.png")
        try png(BaremeSheet(session: s), "i-bareme.png", size: NSSize(width: 720, height: 680))
        try png(panel(.history), "i-notes.png")
        try png(PlanPanel(app: app, session: s, bridge: bridge, analyst: PlotAnalyst(), planner: ScenePlanner(), openScene: first.key), "i-plan.png")
        try png(PlotGridView(app: app, session: s, bridge: bridge, analyst: PlotAnalyst(), planner: ScenePlanner()), "i-grid.png", size: NSSize(width: 1440, height: 640))
    }

    /// Atomic saves make and drop a temporary file in `.musset`; a commit running at that moment must not fail.
    func testCommitSurvivesFilesVanishingWhileItRuns() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("musset-race-\(UUID().uuidString)")
        let dir = root.appendingPathComponent(".musset")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let chapter = root.appendingPathComponent("01.md")
        try "# Un\n".write(to: chapter, atomically: true, encoding: .utf8)
        for i in 0..<200 { try "x".write(to: dir.appendingPathComponent("f\(i).json"), atomically: true, encoding: .utf8) }
        let git = GitService(root: root)
        try git.initRepo()
        _ = try git.commit(paths: ["01.md", ".musset"], message: "first")

        let stop = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)
        let plot = dir.appendingPathComponent("plot.json")
        DispatchQueue.global().async {
            var n = 0
            while stop.wait(timeout: .now()) == .timedOut {
                n += 1
                try? Data("\(n)".utf8).write(to: plot, options: .atomic)
            }
            done.signal()
        }
        var failures: [String] = []
        for i in 0..<150 {
            try "# Un\n\n\(i)\n".write(to: chapter, atomically: true, encoding: .utf8)
            do { _ = try git.commit(paths: ["01.md", ".musset"], message: "c\(i)") } catch { failures.append(error.localizedDescription) }
        }
        stop.signal()
        done.wait()
        XCTAssertEqual(failures.count, 0, failures.first ?? "")
    }

    /// The reader's gestures in the panel, each with its passage.
    func testAdviceShowsItsGestures() throws {
        guard let dir = ProcessInfo.processInfo.environment["MUSSET_SNAPSHOT"] else { throw XCTSkip("set MUSSET_SNAPSHOT") }
        var r = Reading(agent: "claude", model: "opus", textHash: "h", baremeVersion: 1, baremeName: "b", weights: ["forme": 10], scores: [], total: 70)
        r.advice = .init(overview: "", axes: [.init(title: "Un bilan avant la première scène", criterionId: "forme", why: "Le lecteur traverse plusieurs paragraphes d’imparfait avant le premier événement.", direction: "Réduisez le bilan à ce que le livre réutilise.", steps: [
            .init(action: "Couper", quote: "Les patients étaient nombreux, les chambres se remplissaient.", detail: "La phrase tombe entièrement : le lecteur passe du convoi aux billets."),
            .init(action: "Déplacer", quote: "Je mettais surtout les pièces dans les machines", target: "Mehdi a fait du mot mon nouveau surnom.", detail: "Placez ce passage juste avant le surnom."),
        ])], keep: "Ne touchez pas à l’éponge.")
        let size = NSSize(width: 380, height: 360)
        let host = NSHostingView(rootView: AdviceView(reading: r, show: { _ in }).padding(10).frame(width: size.width, height: size.height, alignment: .top).background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .dark))
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame = NSRect(origin: .zero, size: size)
        let w = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.contentView = host
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: dir).appendingPathComponent("advice.png"))
    }

    /// Every replacement can be read whole: the choices wrap, however many and however long.
    func testIssueCardShowsEveryChoiceWhole() throws {
        let dir = ProcessInfo.processInfo.environment["MUSSET_SNAPSHOT"]
        func card(_ original: String, _ choices: [String], _ name: String) throws -> CGFloat {
            let fix = ProofFix(original: original, replacement: choices[0], reason: "Orthographe", alternatives: Array(choices.dropFirst()), source: "grammalecte", message: "Mot inconnu du dictionnaire : « \(original) ».")
            let paragraph = AutoProofreader.Paragraph(range: NSRange(location: 0, length: original.utf16.count), text: original, hash: "h")
            let issue = AutoProofreader.Issue(range: paragraph.range, fix: fix, paragraph: paragraph)
            let host = NSHostingView(rootView: IssueCard(issue: issue, proof: AutoProofreader()) {}.background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .dark))
            host.appearance = NSAppearance(named: .darkAqua)
            let size = host.fittingSize
            host.frame = NSRect(origin: .zero, size: size)
            let w = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            w.appearance = NSAppearance(named: .darkAqua)
            w.contentView = host
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            if let dir {
                let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
                host.cacheDisplay(in: host.bounds, to: rep)
                try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
            }
            XCTAssertEqual(size.width, 340, "the card keeps its width: \(name)")
            return size.height
        }
        let one = try card("démisionné", ["démissionné"], "card-one.png")
        let five = try card("démisionné", ["démissionne", "démissionné", "démissionnée", "démissionnés", "démissionner"], "card-five.png")
        XCTAssertGreaterThan(five, one, "five long choices need a second line")
        // The same second choice, short then too long for one line: only wrapping its own text can make the card taller.
        let medium = try card("il y avait", ["il y eut", "il y avait là quelque chose"], "card-medium.png")
        let long = try card("il y avait", ["il y eut", "il y avait là quelque chose que personne n’aurait su nommer, pas même elle, et qui restait entre eux"], "card-long.png")
        XCTAssertGreaterThan(long, medium, "a choice wider than the card wraps its text")
    }
}
