import SwiftUI
import XCTest
@testable import Musset

/// The screens that were merged (one planning place, one history place, one home for the AI reader, a lighter
/// title bar, slimmer settings), drawn offscreen on the demo book in light and dark, wide and narrow.
/// MUSSET_MERGE_SHOTS=<dir> (skipped otherwise).
@MainActor
final class MergeShots: XCTestCase {
    func testMergeShots() async throws {
        guard let dir = ProcessInfo.processInfo.environment["MUSSET_MERGE_SHOTS"] else { throw XCTSkip("set MUSSET_MERGE_SHOTS") }
        let only = ProcessInfo.processInfo.environment["MUSSET_MERGE_ONLY"].map { Set($0.components(separatedBy: ",")) }
        func wanted(_ item: String) -> Bool { only?.contains(item) ?? true }
        let out = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("SiteDemo/en.json")
        let demo = try JSONDecoder().decode(SiteShots.Demo.self, from: Data(contentsOf: file))

        let d = UserDefaults.standard
        let keys = [UILang.key, "libraryPaths", "lastBook", "showInspector", "inspectorTab", "lineNumbers", "minimap", "aiHomePage", "helpersSeen"]
        let saved = keys.map { d.object(forKey: $0) }
        defer { for (k, v) in zip(keys, saved) { d.set(v, forKey: k) } }
        d.set("en", forKey: UILang.key)
        d.removeObject(forKey: "libraryPaths"); d.removeObject(forKey: "lastBook")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("merge-\(UUID())/\(demo.title)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let ids = ["01", "02", "03"]
        for (id, ch) in zip(ids, demo.chapters) {
            var text = Typography.correctedDocument(ch.text, lang: "en").text
            if id == "02" {
                let paras = text.components(separatedBy: "\n\n")
                let half = max(1, paras.count / 2)
                text = (["<!-- scene: The gate -->"] + paras.prefix(half) + ["<!-- scene: The weighing house -->"] + paras.dropFirst(half)).joined(separator: "\n\n")
            }
            try text.write(to: root.appendingPathComponent("\(id).md"), atomically: true, encoding: .utf8)
        }
        let m = BookManifest(title: demo.title, author: demo.author, lang: "en", chapters: zip(ids, demo.chapters).enumerated().map { i, c in
            ChapterEntry(id: c.0, file: "\(c.0).md", title: c.1.title, status: i == 0 ? .edited : .draft)
        })
        try BookStore(root: root).saveManifest(m)
        let git = GitService(root: root)
        try git.initRepo()
        _ = try git.commit(paths: ids.map { "\($0).md" } + [".musset"], message: "start")
        var plot = PlotGrid.load(root)
        plot.synopsis = "Eleven years after their mother’s funeral, Nora crosses to the island to tell her brother Tom that their father has died."
        plot.chapterSynopses = ["01": "The crossing. Every rehearsed sentence fails in the wind.", "02": "Nora finds Tom on the roof of the salt works."]
        plot.planned = [.init(title: "The Drying Room", synopsis: "She finds the deed. He doesn’t deny it.")]
        try plot.save(root)

        let app = AppState()
        app.openBook(root)
        let s = try XCTUnwrap(app.current)
        s.open("02")
        try await Task.sleep(for: .seconds(0.5))

        let bridge = EditorBridge(), chat = ChatModel(), ann = Annotator(), proof = AutoProofreader()
        bridge.annotator = ann; bridge.proof = proof
        let retina = NSScreen.screens.max { $0.backingScaleFactor < $1.backingScaleFactor }
        var windows: [CGFloat: NSWindow] = [:]
        func window(_ width: CGFloat) -> NSWindow {
            if let w = windows[width] { return w }
            let view = ContentView(app: app, bridge: bridge, chat: chat, pangram: PangramModel(), proof: proof, annotator: ann)
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 900), styleMask: [.titled, .fullSizeContentView],
                             backing: .buffered, defer: false, screen: retina)
            w.contentView = NSHostingView(rootView: view.frame(width: width, height: 900))
            windows[width] = w
            return w
        }
        /// The whole window: `name`-light.png and `name`-dark.png, at 1440 points wide, or narrower.
        func shot(_ name: String, width: CGFloat = 1440, wait: TimeInterval = 1.0, _ setup: () -> Void) async throws {
            let w = window(width)
            for dark in [false, true] {
                w.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                setup()
                try await Task.sleep(for: .seconds(wait))
                let v = w.contentView!
                let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds)!
                v.cacheDisplay(in: v.bounds, to: rep)
                try rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent("merge-\(name)-\(dark ? "dark" : "light").png"))
            }
        }
        /// One view on its own, light and dark.
        func piece<V: View>(_ name: String, _ size: NSSize, _ view: V) async throws {
            for dark in [false, true] {
                let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height, alignment: .top)
                    .background(Color(nsColor: .textBackgroundColor)).environment(\.colorScheme, dark ? .dark : .light))
                host.frame = NSRect(origin: .zero, size: size)
                let w = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false, screen: retina)
                w.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                w.contentView = host
                try await Task.sleep(for: .seconds(0.8))
                let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
                host.cacheDisplay(in: host.bounds, to: rep)
                try rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent("merge-\(name)-\(dark ? "dark" : "light").png"))
            }
        }

        if wanted("A") {
            try await shot("A1-overview-summary") { app.showInspector = false; app.open(OverviewTab.summary.tab) }
            try await shot("A2-overview-synopsis") { app.open(OverviewTab.synopsis.tab) }
            try await shot("A3-overview-grid") { if app.activeTab != OverviewTab.grid.tab { AppCommand.byID["view.grid"]?.run(CommandContext(app: app, bridge: bridge)) } }
            XCTAssertEqual(s.workspace.focused?.tabs.filter { $0.overview != nil }.count, 1, "Overview is one tab")
            try await shot("A4-plan-panel") { s.open("02"); app.inspectorTab = .plan; app.showInspector = true }
            try await shot("A5-overview-grid-narrow", width: 1000) { app.showInspector = false; app.open(OverviewTab.grid.tab) }
            try await shot("A6-plan-panel-narrow", width: 1000) { s.open("02"); app.inspectorTab = .plan; app.showInspector = true }
        }

        if wanted("B") {
            s.addJalon(title: "Sent to Claire", note: "First three chapters.", at: "HEAD")
            try await shot("B1-history-tab") { app.showInspector = false; s.open("02"); app.open(.story) }
            try await shot("B2-history-beside-chapter") {
                if s.workspace.panes.count == 1 { s.workspace.closeAll(.story); s.workspace.open(.story, in: .split(.right)) }
                app.inspectorTab = .history; app.showInspector = true
            }
            try await shot("B3-history-narrow", width: 1000) { app.showInspector = false }
            s.workspace.closeAll(.story)
        }
        if wanted("C") {
            let on = AIStatus.shared.installed
            defer { AIStatus.shared.installed = on }
            AIStatus.shared.installed = [.claude]
            try await shot("C1-ai-home-chat") { s.open("02"); d.set("chat", forKey: "aiHomePage"); app.inspectorTab = .chat; app.showInspector = true }
            try await shot("C2-ai-home-no-readings") { d.set("readings", forKey: "aiHomePage") }
            var r = Reading(agent: "claude", model: "opus", textHash: "h", baremeVersion: 1, baremeName: "Literary novel", weights: ["forme": 10, "voix": 20],
                            scores: [], total: 64)
            r.advice = .init(overview: "", axes: [.init(title: "A summary before the first scene", criterionId: "forme", why: "The reader crosses two paragraphs before the first event.",
                                                        direction: "Cut the summary down to what the book uses again.", steps: [])], keep: "Leave the dog alone.")
            var r2 = r; r2.total = 71
            try Reading.append(r, root: s.root, chapter: "02"); try Reading.append(r2, root: s.root, chapter: "02")
            chat.reader.completed += 1
            try await shot("C3-ai-home-readings") { d.set("readings", forKey: "aiHomePage") }
            try await shot("C4-stats") { app.inspectorTab = .stats }
            try await shot("C5-debate-tab") { app.showInspector = true; app.inspectorTab = .chat; app.open(.debate) }
            try await shot("C6-ai-home-narrow", width: 1000) { s.workspace.closeAll(.debate); app.inspectorTab = .chat }
            try await shot("C7-stats-narrow", width: 1000) { app.inspectorTab = .stats }
            AIStatus.shared.installed = []
            d.removeObject(forKey: "helpersSeen")
            try await shot("C8-ai-home-no-engine") { app.inspectorTab = .chat }
            d.set(true, forKey: "helpersSeen")
            try await shot("C9-ai-off-stats") { app.inspectorTab = .stats }
            XCTAssertFalse(AIHome.shown)
        }
        if wanted("D") {
            try await shot("D1-title-bar") { app.showInspector = false; s.open("02"); app.open(.chapter("02")) }
            s.lastError = "The disk is full: the chapter could not be saved."
            app.repetitions = true
            try await shot("D2-status-pill-many") {}
            try await shot("D3-status-pill-narrow", width: 1000) { app.inspectorTab = .plan; app.showInspector = true }
            s.lastError = nil; app.repetitions = false
            s.tryAnotherVersion(named: "Colder", blank: false)
            try await shot("D4-title-bar-version") { app.showInspector = false }
        }
        if wanted("E") {
            try await piece("E1-book-settings-general", NSSize(width: 860, height: 600), BookSettingsView(app: app, session: s))
            try await piece("E2-book-settings-ai-reader", NSSize(width: 860, height: 600), BookSettingsView(app: app, session: s, startSection: .critic))
            try await piece("E3-book-settings-folder", NSSize(width: 860, height: 600), BookSettingsView(app: app, session: s, startSection: .folder))
            try await piece("E4-export-sheet", NSSize(width: 780, height: 560), ExportSheet(session: s))
        }
        if wanted("F") {
            try await piece("F1-settings-general", NSSize(width: 860, height: 600), SettingsView(app: app, pane: .general).font(.ui(13)))
            try await piece("F2-settings-ai", NSSize(width: 860, height: 600), SettingsView(app: app, pane: .ai).font(.ui(13)))
            try await piece("F3-debate-setup", NSSize(width: 900, height: 760), DebatePage(session: s))
            try await shot("F4-notes-empty") { s.open("03"); app.inspectorTab = .edits; app.showInspector = true }
            try await shot("F5-history-panel") { app.inspectorTab = .history }
        }
        if wanted("G") {
            try await piece("G1-settings-editor", NSSize(width: 860, height: 600), SettingsView(app: app, pane: .editor).font(.ui(13)))
            app.lineNumbers = true; app.minimap = true
            try await shot("G2-line-numbers-minimap") { app.showInspector = false; s.open("02"); app.open(.chapter("02")) }
            app.lineNumbers = false; app.minimap = false
            XCTAssertNil(AppCommand.byID["view.lineNumbers"]?.shortcut)
            XCTAssertNotNil(AppCommand.byID["view.minimap"])
        }
        // Last: writing on a track changes what every screen shows.
        if wanted("T") {
            s.open("02")
            s.newPiste(named: "Without the father", from: "HEAD", fromLabel: "the manuscript")
            try await Task.sleep(for: .seconds(0.5))
            try await shot("T1-on-a-track") { app.showInspector = false; app.open(.chapter("02")) }
            try await shot("T2-on-a-track-history") { app.open(.story) }
            try await shot("T3-on-a-track-narrow", width: 1000) { app.open(.chapter("02")) }
        }
    }
}
