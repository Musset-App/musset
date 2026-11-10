import XCTest
import SwiftUI
@testable import Musset

@MainActor
final class SceneTests: XCTestCase {
    let chapter = """
    # La cuisine

    <!-- scene: Le marché -->
    Ma mère achetait des tomates au marché du cours Saleya.
    <!-- scène : Le retour -->
    Nous remontions la rue avec les paniers.
    Il faisait chaud.
    """

    func testParseScenes() {
        let scenes = Scenes.parse(chapter)
        XCTAssertEqual(scenes.map(\.title), ["Le marché", "Le retour"], "the heading alone is not a scene")
        XCTAssertEqual(scenes[0].words, 10)
        XCTAssertEqual(scenes[1].words, 10)
        let plain = Scenes.parse("# Titre\n\nUn seul bloc de texte.")
        XCTAssertEqual(plain.count, 1)
        XCTAssertNil(plain[0].title)
        let lead = Scenes.parse("Avant tout.\n<!-- scene: Après -->\nLa suite.")
        XCTAssertEqual(lead.map(\.title), [nil, "Après"])
    }

    func testMovingAScene() throws {
        let three = "# T\n\nDébut du chapitre.\n<!-- scene: A -->\nTexte A.\n<!-- scene: B -->\nTexte B.\n"
        // Down: the opening gets a marker and the heading stays on top.
        let down = try XCTUnwrap(Scenes.moved(0, to: 2, in: three, openingTitle: "Ouverture"))
        XCTAssertEqual(down.text, "# T\n\n<!-- scene: A -->\nTexte A.\n<!-- scene: Ouverture -->\nDébut du chapitre.\n<!-- scene: B -->\nTexte B.\n")
        XCTAssertEqual(down.opening, "Ouverture")
        // Up over the opening: it must not be swallowed.
        let up = try XCTUnwrap(Scenes.moved(2, to: 0, in: three, openingTitle: "Ouverture"))
        XCTAssertEqual(Scenes.parse(up.text).map(\.title), ["B", "Ouverture", "A"])
        XCTAssertTrue(up.text.hasPrefix("# T\n\n<!-- scene: B -->"))
        // In place: nothing happens.
        XCTAssertNil(Scenes.moved(1, to: 1, in: three, openingTitle: "Ouverture"))
        XCTAssertNil(Scenes.moved(1, to: 2, in: three, openingTitle: "Ouverture"))
        // To the end, without a final line ending: none is added, none is lost.
        let bare = "<!-- scene: A -->\nUn.\n<!-- scene: B -->\nDeux."
        XCTAssertEqual(try XCTUnwrap(Scenes.moved(0, to: 2, in: bare, openingTitle: "O")).text, "<!-- scene: B -->\nDeux.\n<!-- scene: A -->\nUn.")
        // Every word survives any move.
        for from in 0..<3 { for to in 0...3 {
            guard let out = Scenes.moved(from, to: to, in: three, openingTitle: "O") else { continue }
            for w in ["Début", "Texte A.", "Texte B."] { XCTAssertEqual(out.text.components(separatedBy: w).count, 2, "\(from)→\(to)") }
        } }
    }

    func testASceneMovesToAnotherChapterWithItsNotesAndRow() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = "# Un\n\n<!-- scene: Reste -->\nCe qui reste ici, longtemps.\n\n<!-- scene: Part -->\nCe qui part là-bas, avec sa note.\n"
        let b = "# Deux\n\n<!-- scene: Là -->\nDéjà là depuis toujours.\n"
        try a.write(to: root.appendingPathComponent("01.md"), atomically: true, encoding: .utf8)
        try b.write(to: root.appendingPathComponent("02.md"), atomically: true, encoding: .utf8)
        let m = BookManifest(title: "T", chapters: [ChapterEntry(id: "01", file: "01.md", title: "Un"), ChapterEntry(id: "02", file: "02.md", title: "Deux")])
        let store = BookStore(root: root)
        try store.saveManifest(m)
        try GitService(root: root).initRepo()
        let s = BookSession(root: root, manifest: m)
        let ns = s.text as NSString
        s.notes.add(range: ns.range(of: "avec sa note"), text: s.text, author: .me, kind: .todo, body: "suit")
        s.notes.add(range: ns.range(of: "longtemps"), text: s.text, author: .me, kind: .todo, body: "reste")
        s.plot.update("01", "Part") { $0.cells["main"] = PlotGrid.Cell(text: "résumé") }
        let before = (s.text, s.editorText(of: "02"))

        s.moveScene(from: "01", index: 1, to: "02", slot: 0)
        XCTAssertEqual(s.scenes["01"]?.map(\.title), ["Reste"])
        XCTAssertEqual(s.scenes["02"]?.map(\.title), ["Part", "Là"])
        XCTAssertFalse(s.text.contains("Ce qui part"), "the open chapter follows")
        XCTAssertEqual(s.notes.notes(of: "02").map(\.body), ["suit"])
        XCTAssertEqual(s.notes.notes(of: "01").map(\.body), ["reste"])
        XCTAssertEqual(s.plot.row("02", "Part").cells["main"]?.text, "résumé")
        XCTAssertNil(s.plot.rows["01"]?["Part"])
        XCTAssertFalse(s.pendingCommit, "one commit")

        s.undoSceneMove()
        XCTAssertEqual(s.text, before.0)
        XCTAssertEqual(s.editorText(of: "02"), before.1)
        XCTAssertEqual(Set(s.notes.notes(of: "01").map(\.body)), ["suit", "reste"])
        XCTAssertEqual(s.plot.row("01", "Part").cells["main"]?.text, "résumé")
    }

    func testTypstSceneBreaks() {
        let none = TypstMarkup.chapter(chapter, id: "c", markers: false)
        XCTAssertFalse(none.contains("scene"))
        XCTAssertFalse(none.contains("asterism"))
        let star = TypstMarkup.chapter(chapter, id: "c", markers: false, sceneBreak: .asterism)
        XCTAssertEqual(star.components(separatedBy: "#asterism()").count - 1, 1, "no break before the first scene")
        XCTAssertTrue(TypstMarkup.chapter(chapter, id: "c", markers: false, sceneBreak: .blank).contains("#scenegap()"))
        let pandoc = BookStore.sceneBreaks(ParagraphCodec.encode(chapter), .asterism)
        XCTAssertEqual(pandoc.components(separatedBy: "⁂").count - 1, 1)
        XCTAssertTrue(pandoc.contains("<!-- scene: Le marché -->"))
    }

    func testFindGoesRoundTheChapter() {
        let m = [NSRange(location: 2, length: 3), NSRange(location: 10, length: 3), NSRange(location: 20, length: 3)]
        XCTAssertEqual(EditorBridge.match(in: m, from: NSRange(location: 0, length: 0), forward: true), m[0])
        XCTAssertEqual(EditorBridge.match(in: m, from: m[0], forward: true), m[1])
        XCTAssertEqual(EditorBridge.match(in: m, from: m[2], forward: true), m[0], "Past the last, back to the first")
        XCTAssertEqual(EditorBridge.match(in: m, from: m[1], forward: false), m[0])
        XCTAssertEqual(EditorBridge.match(in: m, from: m[0], forward: false), m[2], "Before the first, on to the last")
        XCTAssertNil(EditorBridge.match(in: [], from: m[0], forward: true))
    }

    func testHeadingGivesTheChapterItsTitle() {
        XCTAssertEqual(BookStore.heading(in: "# Rachid\n\nTexte"), "Rachid")
        XCTAssertEqual(BookStore.heading(in: "<!-- note\n# pas un titre\n-->\n\n# Rachid {.unnumbered}\n"), "Rachid")
        XCTAssertNil(BookStore.heading(in: "# \n\nTexte"), "An empty heading keeps the last title while typing")
        XCTAssertNil(BookStore.heading(in: "Texte\n\n## Partie"))
        XCTAssertEqual(BookStore.retitled("# Un {.unnumbered}\n\nTexte", to: "Deux"), "# Deux {.unnumbered}\n\nTexte")
        XCTAssertNil(BookStore.retitled("Texte", to: "Deux"))
    }

    func testChapterFollowsItsHeadingAndRenameRewritesIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("musset-title-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try "# Rachid\n\nTexte\n".write(to: root.appendingPathComponent("01.md"), atomically: true, encoding: .utf8)
        try "# Lyon\n\nAilleurs\n".write(to: root.appendingPathComponent("02.md"), atomically: true, encoding: .utf8)
        let session = BookSession(root: root, manifest: BookManifest(title: "T", chapters: [
            ChapterEntry(id: "01", file: "01.md", title: "Chapitre 1"), ChapterEntry(id: "02", file: "02.md", title: "Chapitre 2")]))
        XCTAssertEqual(session.manifest.chapters.map(\.title), ["Rachid", "Lyon"], "An existing book is put right on opening")

        session.open("01")
        session.textDidChange("# Salma\n\nTexte")
        session.flushSave()
        XCTAssertEqual(session.manifest.chapters[0].title, "Salma")
        XCTAssertEqual(session.manifest.chapters[0].id, "01")
        XCTAssertEqual(session.manifest.chapters[0].file, "01.md", "The file keeps its name")

        session.renameChapter("01", to: "Nour")
        XCTAssertTrue(session.text.hasPrefix("# Nour\n"))
        session.renameChapter("02", to: "Grenoble")
        XCTAssertEqual(session.manifest.chapters[1].title, "Grenoble")
        XCTAssertTrue(try String(contentsOf: root.appendingPathComponent("02.md"), encoding: .utf8).hasPrefix("# Grenoble\n"))
    }

    func testAnalystUsesTheIndexAndKeepsAuthorCells() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("musset-plot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try ParagraphCodec.encode(chapter).write(to: root.appendingPathComponent("01.md"), atomically: true, encoding: .utf8)
        let session = BookSession(root: root, manifest: BookManifest(title: "T", chapters: [ChapterEntry(id: "01", file: "01.md", title: "Un")]))
        session.open("01")
        let scenes = try XCTUnwrap(session.scenes["01"])
        XCTAssertEqual(PlotAnalyst.stale(session, chapter: "01").count, 2)

        // The whole-book reading: one name per character and motif, aliases mapped.
        let index = try XCTUnwrap(PlotAnalyst.parseIndex(#"""
        {"synopsis": "Un été au bord de la mer.", "characters": [{"name": "la mère", "aliases": ["maman", "ma mère"], "note": "pharmacienne"},
         {"name": "le narrateur", "aliases": ["je"]}], "motifs": [{"name": "ficelle", "aliases": ["la corde"]}, {"name": "pommiers"}],
         "threads": [{"name": "Le départ du village", "kind": "main", "note": "le frère part"}]}
        """#))
        PlotAnalyst.merge(index, into: session, engine: .claude)
        XCTAssertEqual(session.plot.canonical("Maman", column: "characters"), "la mère")
        XCTAssertEqual(session.plot.canonical("La ficelle", column: "motifs"), "ficelle")
        XCTAssertEqual(session.plot.canonical("la corde", column: "motifs"), "ficelle")
        XCTAssertTrue(PlotAnalyst.prompt(session, chapter: "01", scenes: scenes).contains("ficelle (= la corde)"))

        session.plot.update("01", "Le marché") { $0.cells["characters"] = PlotGrid.Cell(by: "me", tags: ["la mère"]) }
        let items = PlotAnalyst.parse(#"""
        [{"scene": "Le marché", "cells": {"characters": ["maman", "le narrateur"], "main": "Les courses", "hidden": "secret", "motifs": ["la corde", "soleil"]},
          "proposals": {"characters": ["maman", "la marchande"]}},
         {"scene": "Le retour", "cells": {"characters": ["Ma mère", "Pierre"], "motifs": "pommiers, Pommiers"}}]
        """#)
        PlotAnalyst.apply(items, to: session, chapter: "01", scenes: scenes, engine: .claude)
        let market = session.plot.row("01", "Le marché")
        XCTAssertEqual(market.cells["characters"]?.tags, ["la mère"], "the author's cell stays")
        XCTAssertEqual(market.cells["characters"]?.proposal, "la mère, la marchande")
        XCTAssertEqual(market.cells["motifs"]?.tags, ["ficelle"], "aliases become the name, unknown motifs are dropped")
        XCTAssertEqual(market.cells["main"]?.text, "Les courses")
        XCTAssertNil(market.cells["hidden"], "the hidden plot is the author's")
        let back = session.plot.row("01", "Le retour")
        XCTAssertEqual(back.cells["characters"]?.tags, ["la mère", "Pierre"], "a new character joins the index")
        XCTAssertEqual(back.cells["motifs"]?.tags, ["pommiers"])
        XCTAssertNotNil(session.plot.canonical("pierre", column: "characters"))
        XCTAssertEqual(session.plot.scenes(with: "la mère", in: "characters").count, 2)
        XCTAssertTrue(PlotAnalyst.stale(session, chapter: "01").isEmpty)

        // Renaming onto an existing tag merges them, everywhere.
        session.plot.renameTag("Pierre", to: "le narrateur", column: "characters")
        XCTAssertEqual(session.plot.row("01", "Le retour").cells["characters"]?.tags, ["la mère", "le narrateur"])
        XCTAssertEqual(session.plot.canonical("Pierre", column: "characters"), "le narrateur")
        session.savePlot()
        XCTAssertEqual(PlotGrid.load(root).row("01", "Le marché").cells["motifs"]?.tags, ["ficelle"], "saved")

        // Renaming a marker in the text carries the row along.
        session.textDidChange(session.text.replacingOccurrences(of: "Le retour", with: "La remontée"))
        session.flushSave()
        XCTAssertEqual(session.plot.row("01", "La remontée").cells["motifs"]?.tags, ["pommiers"])
        XCTAssertNil(session.plot.rows["01"]?["Le retour"])
    }

    func testOldTextCellsBecomeTags() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("musset-plotmig-\(UUID().uuidString)")
        var g = PlotGrid()
        g.update("01", "") { $0.cells["characters"] = .init(text: "La mère, le narrateur", by: "claude"); $0.cells["main"] = .init(text: "Texte", by: "me") }
        try g.save(root)
        let loaded = PlotGrid.load(root)
        XCTAssertEqual(loaded.row("01", "").cells["characters"]?.tags, ["La mère", "le narrateur"])
        XCTAssertEqual(loaded.row("01", "").cells["main"]?.text, "Texte")
    }

    func testPlannerLocatesParagraphs() {
        let text = "# T\n\nIl pleuvait sur Nice ce matin-là.\nLe soir, à Paris, tout avait changé de couleur.\n"
        let props = ScenePlanner.parse(#"[{"start": "Il pleuvait sur Nice", "title": "La pluie"}, {"start": "Le soir, à Paris, tout avait", "title": "Paris"}]"#)
        let spots = ScenePlanner.locate(props, in: text)
        XCTAssertEqual(spots.map(\.title), ["La pluie", "Paris"])
        XCTAssertEqual(spots[0].offset, 5)
        XCTAssertFalse(ScenePlanner.markerJustBefore(5, in: text))
        let marked = "# T\n\n<!-- scene: La pluie -->\nIl pleuvait."
        XCTAssertTrue(ScenePlanner.markerJustBefore((marked as NSString).range(of: "Il pleuvait").location, in: marked))
    }

    /// Live: Claude splits 03_nice into scenes, the markers go in, then it fills the grid. MUSSET_LIVE=1.
    func testLiveScenesAndGrid() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MUSSET_LIVE"] == "1")
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/conatus/03_nice.md")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("musset-live-plot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixture, to: root.appendingPathComponent("01.md"))
        let session = BookSession(root: root, manifest: BookManifest(title: "Le Sel", chapters: [ChapterEntry(id: "01", file: "01.md", title: "Le port")]))
        session.open("01")

        let raw = try await Agents.oneShot(.claude, prompt: ScenePlanner.prompt(session), model: ScenePlanner.model(for: .claude), cwd: root)
        let props = ScenePlanner.parse(raw)
        let spots = ScenePlanner.locate(props, in: session.text)
        print("SCENES proposed \(props.count), located \(spots.count): \(props.map(\.title))")
        XCTAssertGreaterThan(props.count, 1)
        XCTAssertEqual(spots.count, props.count, "every proposed start is found")
        var t = session.text as NSString
        for s in spots.reversed() { t = t.replacingCharacters(in: NSRange(location: s.offset, length: 0), with: Scenes.markerLine(s.title) + "\n") as NSString }
        session.textDidChange(t as String)
        session.flushSave()
        let scenes = try XCTUnwrap(session.scenes["01"])
        XCTAssertEqual(scenes.filter { $0.title != nil }.count, spots.count)

        let grid = try await Agents.oneShot(.claude, prompt: PlotAnalyst.prompt(session, chapter: "01", scenes: scenes), model: "haiku", cwd: root)
        PlotAnalyst.apply(PlotAnalyst.parse(grid), to: session, chapter: "01", scenes: scenes, engine: .claude)
        for s in scenes {
            let row = session.plot.row("01", s.key)
            print("ROW \(s.key) (\(s.words) w): " + session.plot.columns.map { "\($0.title)=\(row.cells[$0.id]?.text ?? "")" }.joined(separator: " | "))
        }
        XCTAssertTrue(scenes.allSatisfy { !(session.plot.row("01", $0.key).cells["characters"]?.text ?? "").isEmpty })
        XCTAssertTrue(scenes.allSatisfy { session.plot.row("01", $0.key).cells["hidden"] == nil })
    }

    /// Renders the grid, the sidebar tree and the editor's scene markers. MUSSET_SNAPSHOT=<dir>.
    func testScenesSnapshot() throws {
        guard let dir = ProcessInfo.processInfo.environment["MUSSET_SNAPSHOT"] else { throw XCTSkip("set MUSSET_SNAPSHOT") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("musset-snap-plot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try ParagraphCodec.encode(chapter).write(to: root.appendingPathComponent("01.md"), atomically: true, encoding: .utf8)
        try "# Le port\n\nUn chapitre sans scènes.\n".write(to: root.appendingPathComponent("02.md"), atomically: true, encoding: .utf8)
        let session = BookSession(root: root, manifest: BookManifest(title: "Le Sel", chapters: [
            ChapterEntry(id: "01", file: "01.md", title: "Le grenier", status: .edited), ChapterEntry(id: "02", file: "02.md", title: "Le port")]))
        session.open("01")
        session.plot.update("01", "Le marché") {
            $0.cells["characters"] = .init(by: "me", proposal: "la mère, le narrateur, la marchande", tags: ["la mère", "le narrateur"])
            $0.cells["motifs"] = .init(by: "claude", tags: ["ficelle", "pommiers", "tomates"])
            $0.cells["main"] = .init(text: "Les courses du samedi au cours Saleya.", by: "claude")
            $0.status = .done
        }
        session.plot.update("01", "Le retour") { $0.cells["motifs"] = .init(by: "codex", tags: ["ficelle", "paniers"]); $0.cells["characters"] = .init(by: "codex", tags: ["la mère"]) }
        session.plot.index = [.init(name: "la mère", column: "characters", note: "pharmacienne"), .init(name: "le narrateur", column: "characters"),
                              .init(name: "ficelle", column: "motifs"), .init(name: "pommiers", column: "motifs"), .init(name: "paniers", column: "motifs")]
        let app = AppState()
        let bridge = EditorBridge()
        func png(_ view: some View, _ size: NSSize, _ name: String) throws {
            let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height).environment(\.colorScheme, .light))
            host.appearance = NSAppearance(named: .aqua)
            host.frame = NSRect(origin: .zero, size: size)
            let w = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            w.contentView = host
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
        }
        try png(PlotGridView(app: app, session: session, bridge: bridge, analyst: PlotAnalyst(), planner: ScenePlanner()), NSSize(width: 1500, height: 420), "plot-grid.png")
        try png(ChapterSidebar(session: session, app: app, bridge: bridge), NSSize(width: 280, height: 360), "scene-tree.png")
        try png(ZenEditorView(session: session, bridge: bridge, fontName: "", fontSize: 16, columnWidth: 600,
                              focusMode: false, typewriter: false, lineNumbers: false), NSSize(width: 800, height: 420), "scene-editor.png")
    }

    /// Live: Opus reads a whole real book (a copy) to build the index, then fills two chapters with it. MUSSET_LIVE=1.
    func testLiveBookIndex() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MUSSET_LIVE"] == "1")
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("fixtures/conatus")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("musset-live-index-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: fixture, to: root)
        try? FileManager.default.removeItem(at: PlotGrid.url(root))
        let session = BookSession(root: root, manifest: try BookStore(root: root).loadManifest())

        let raw = try await Agents.oneShot(.claude, prompt: PlotAnalyst.indexPrompt(session), model: PlotAnalyst.indexModel(for: .claude), cwd: root)
        let index = try XCTUnwrap(PlotAnalyst.parseIndex(raw), raw)
        PlotAnalyst.merge(index, into: session, engine: .claude)
        print("SYNOPSIS \(session.plot.synopsis ?? "")")
        for t in session.plot.tags(in: "characters") { print("CHAR \(t.name) = \(t.aliases.joined(separator: ", ")) — \(t.note)") }
        for t in session.plot.tags(in: "motifs") { print("MOTIF \(t.name) = \(t.aliases.joined(separator: ", ")) — \(t.note)") }
        for t in session.plot.threads ?? [] { print("THREAD \(t.name) (\(t.kind)) — \(t.note)") }
        XCTAssertGreaterThan(session.plot.tags(in: "motifs").count, 5)

        for id in session.manifest.chapters.prefix(2).map(\.id) {
            session.open(id)
            let scenes = try XCTUnwrap(session.scenes[id])
            let out = try await Agents.oneShot(.claude, prompt: PlotAnalyst.prompt(session, chapter: id, scenes: scenes), model: "opus", cwd: root)
            PlotAnalyst.apply(PlotAnalyst.parse(out), to: session, chapter: id, scenes: scenes, engine: .claude)
            for sc in scenes {
                let row = session.plot.row(id, sc.key)
                print("ROW \(id)/\(sc.key): " + session.plot.columns.map { c in "\(c.title)=" + (c.isTagged ? (row.cells[c.id]?.tags ?? []).joined(separator: ", ") : row.cells[c.id]?.text ?? "") }.joined(separator: " | "))
            }
        }
    }
}
