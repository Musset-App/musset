import SwiftUI
import XCTest
@testable import Musset

/// The live Bible's screens, drawn offscreen on the demo book, to look at them without opening Musset.
/// MUSSET_LIVE_SHOTS=<dir> (skipped otherwise).
@MainActor
final class LiveBibleShots: XCTestCase {
    func testLiveBibleShots() async throws {
        guard let dir = ProcessInfo.processInfo.environment["MUSSET_LIVE_SHOTS"] else { throw XCTSkip("set MUSSET_LIVE_SHOTS") }
        let out = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("SiteDemo/en.json")
        let demo = try JSONDecoder().decode(SiteShots.Demo.self, from: Data(contentsOf: file))

        let d = UserDefaults.standard
        let saved = (d.string(forKey: UILang.key), d.stringArray(forKey: "libraryPaths"), d.string(forKey: "lastBook"))
        defer { d.set(saved.0, forKey: UILang.key); d.set(saved.1, forKey: "libraryPaths"); d.set(saved.2, forKey: "lastBook") }
        d.set("en", forKey: UILang.key)
        d.removeObject(forKey: "libraryPaths"); d.removeObject(forKey: "lastBook")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("live-\(UUID())/\(demo.title)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let ids = ["01", "02", "03"]
        for (i, (id, ch)) in zip(ids, demo.chapters).enumerated() {
            var text = Typography.correctedDocument(ch.text, lang: "en").text
            if i == 1 { text += "\n\nThe pans had to be raked every four hours [@hartley1994, p. 88]. A woman came out of the office: Odile.\n" }
            try text.write(to: root.appendingPathComponent("\(id).md"), atomically: true, encoding: .utf8)
        }
        var m = BookManifest(title: demo.title, author: demo.author, lang: "en", chapters: zip(ids, demo.chapters).map {
            ChapterEntry(id: $0.0, file: "\($0.0).md", title: $0.1.title, status: .draft)
        })
        try BookStore(root: root).saveManifest(m)
        let git = GitService(root: root)
        try git.initRepo()
        _ = try git.commit(paths: ids.map { "\($0).md" } + [".musset"], message: "start")

        // The Bible as the live Bible keeps it.
        let store = BibleStore(root: root)
        for (name, kind, body) in [("Nora", BibleKind.character, "Comes back with her father’s coat."), ("Tom", .character, "Talks to the roof more than to people."),
                                   ("Odile", .character, ""), ("The salt works", .place, "")] {
            var e = BibleEntry(path: store.freePath(title: name, folder: kind.folder), kind: kind, title: name)
            e.body = body
            if name == "Odile" { e.meta["origin"] = "musset" }
            if kind == .place { e.meta = ["lat": "55.06420", "lon": "-7.86690", "span": "0.0300", "address": "Salt works, Holm Island"] }
            try store.write(e)
        }
        var ref = BibleEntry(path: "documents/the-salt-coast.md", kind: .reference, title: "The Salt Coast: Making Salt by Hand, 1700–1990")
        ref.meta = ["citekey": "hartley1994", "author": "M. Hartley", "year": "1994", "publisher": "Harbour Press"]
        try store.write(ref)
        var facts = BookFacts()
        facts.entities["personnages/tom.md"] = .init(facts: [
            .init(text: "Drives a van, parked by the weighing house.", chapter: "02", quote: "van was parked by the old weighing house"),
            .init(text: "Hasn’t spoken to Nora since the funeral.", chapter: "01", quote: "They had not spoken since the funeral"),
        ], aliases: ["her brother"], contradictions: [.init(a: "02|van was parked by the old weighing house", b: "01|They had not spoken since the funeral", why: "Eleven years, then twelve winters")])
        try facts.save(root)
        var board = JSONCanvas()
        board.nodes = [
            .init(type: .group, x: 90, y: 110, width: 280, height: 360, label: "Clues"),
            .init(type: .text, x: 110, y: 160, width: 240, height: 110, text: "Where is it? In the 1987 calendar, behind March."),
            .init(type: .text, x: 110, y: 300, width: 240, height: 120, color: "5", text: "**Tom** lies about the *deed* twice."),
            .init(type: .text, x: 90, y: 30, width: 400, height: 54, text: "Who signed it?", musset: ["kind": "label"]),
            .init(type: .text, x: 420, y: 520, width: 180, height: 110, color: "4", text: "The calendar", musset: ["kind": "shape", "shape": "ellipse"]),
            BoardInk.make((0..<40).map { i in CGPoint(x: 640 + Double(i) * 9, y: 560 + 30 * sin(Double(i) / 4)) }, width: 3, color: "1", highlighter: false)!,
            .init(type: .file, x: 420, y: 120, width: 240, height: 90, file: "personnages/tom.md"),
            .init(type: .text, x: 420, y: 260, width: 300, height: 200, text: "Map", musset: ["kind": "map"]),
            .init(type: .text, x: 760, y: 120, width: 260, height: 130, text: "> nothing to take but the salt", musset: ["kind": "passage", "chapter": "02", "quote": "nothing to take but the salt"]),
            .init(type: .file, x: 760, y: 300, width: 300, height: 220, file: "lieux/the-salt-works.md", musset: ["kind": "map"]),
            .init(type: .text, x: 1100, y: 120, width: 320, height: 330, text: "Map", musset: ["kind": "pin", "lat": "53.34980", "lon": "-6.26030", "span": "0.0200", "address": "Dublin, Ireland"]),
        ]
        board.edges = [.init(fromNode: board.nodes[1].id, toNode: board.nodes[6].id), .init(fromNode: board.nodes[2].id, toNode: board.nodes[4].id, fromSide: "right", toSide: "top")]
        try board.write(store.url("tableaux/The deed.canvas"))
        var plot = PlotGrid.load(root)
        plot.synopsis = "Eleven years after their mother’s funeral, Nora crosses to the island to tell her brother Tom that their father has died."
        plot.chapterSynopses = ["01": "The crossing. Every rehearsed sentence fails in the wind."]
        plot.planned = [.init(title: "The Drying Room", synopsis: "She finds the deed. He doesn’t deny it.")]
        try plot.save(root)

        let app = AppState()
        app.openBook(root)
        let s = try XCTUnwrap(app.current)
        s.open("02")
        s.refreshBibleMentions()
        try await Task.sleep(for: .seconds(0.5))

        let bridge = EditorBridge(), chat = ChatModel(), ann = Annotator(), proof = AutoProofreader()
        bridge.annotator = ann; bridge.proof = proof
        bridge.openSheet = { app.open(.sheet($0)) }
        let view = ContentView(app: app, bridge: bridge, chat: chat, pangram: PangramModel(), proof: proof, annotator: ann)
        let retina = NSScreen.screens.max { $0.backingScaleFactor < $1.backingScaleFactor }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900), styleMask: [.titled, .fullSizeContentView],
                              backing: .buffered, defer: false, screen: retina)
        window.contentView = NSHostingView(rootView: view.frame(width: 1440, height: 900))
        func shot(_ name: String, wait: TimeInterval = 1.2, dark: Bool = false, _ setup: () -> Void) async throws {
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            setup()
            try await Task.sleep(for: .seconds(wait))
            let v = window.contentView!
            let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds)!
            v.cacheDisplay(in: v.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name))
        }
        try await shot("1-writing.png") { app.showInspector = false; s.spotter.joined = .init(path: "personnages/odile.md", title: "Odile", kind: .character) }
        try await shot("2-sheet.png") { app.open(.sheet("personnages/tom.md")) }
        try await shot("3-cast.png") { app.open(.folder("personnages")) }
        try await shot("3b-place.png") { app.open(.sheet("lieux/the-salt-works.md")) }
        try await shot("4-board.png") { app.open(.sheet("tableaux/The deed.canvas")) }
        try await shot("4b-board-dark.png", dark: true) {}
        try await shot("5-synopsis.png") { app.open(OverviewTab.synopsis.tab) }
        try await shot("6-debate.png") { app.open(.debate) }
        try await shot("7-sources.png") { app.open(.sources) }

        // Panes: two chapters side by side, then a chapter beside a board, then three panes.
        try await shot("9-two-chapters.png") {
            s.open("02")
            s.workspace.open(.chapter("01"), in: .split(.right))
        }
        try await shot("10-chapter-board.png") {
            s.workspace.open(.sheet("tableaux/The deed.canvas"), in: .replace)
        }
        try await shot("11-three-panes.png") {
            s.workspace.open(.sheet("personnages/tom.md"), in: .split(.bottom))
        }

        // The rename sheet, on its own.
        let rename = NSHostingView(rootView: RenameSheet(session: s, bridge: bridge, path: "personnages/tom.md") {}.frame(width: 720, height: 600))
        let w2 = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 600), styleMask: [.titled], backing: .buffered, defer: false, screen: retina)
        w2.appearance = NSAppearance(named: .aqua)
        w2.contentView = rename
        try await Task.sleep(for: .seconds(1))
        let rep = rename.bitmapImageRepForCachingDisplay(in: rename.bounds)!
        rename.cacheDisplay(in: rename.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent("8-rename.png"))
    }
}
