import SwiftUI
import XCTest
@testable import Musset

/// A chapter's scenes as cards: the text operations behind them, on the book's real files, and the pane's mode.
@MainActor
final class SceneCardsTests: XCTestCase {
    private let chapter = "# T\n\nDébut du chapitre.\nEncore le début.\n<!-- scene: A -->\nTexte A.\nSuite de A.\n<!-- scene: B -->\nTexte B.\n"

    private func at(_ needle: String, in text: String) -> Int { (text as NSString).range(of: needle).location }

    func testSplittingAScene() throws {
        // Before a paragraph of a titled scene: a marker on the line above, nothing else touched.
        let out = try XCTUnwrap(Scenes.split(chapter, at: at("Suite de A.", in: chapter), title: "Scene 3"))
        XCTAssertEqual(out, "# T\n\nDébut du chapitre.\nEncore le début.\n<!-- scene: A -->\nTexte A.\n<!-- scene: Scene 3 -->\nSuite de A.\n<!-- scene: B -->\nTexte B.\n")
        XCTAssertEqual(Scenes.parse(out).map(\.title), [nil, "A", "Scene 3", "B"])
        // Anywhere in the paragraph: the scene starts at its first letter.
        XCTAssertEqual(Scenes.split(chapter, at: at("de A.", in: chapter), title: "Scene 3"), out)
        // In the opening: it stays the untitled opening, as it still comes first.
        let lead = try XCTUnwrap(Scenes.split(chapter, at: at("Encore", in: chapter), title: "N"))
        XCTAssertEqual(Scenes.parse(lead).map(\.title), [nil, "N", "A", "B"])
        XCTAssertTrue(lead.hasPrefix("# T\n\nDébut du chapitre.\n<!-- scene: N -->\nEncore le début.\n"))
        // Where a scene already starts, on a marker or in the heading: no scene is left empty.
        XCTAssertNil(Scenes.split(chapter, at: at("Texte A.", in: chapter), title: "N"))
        XCTAssertNil(Scenes.split(chapter, at: at("<!-- scene: B", in: chapter), title: "N"))
        XCTAssertNil(Scenes.split(chapter, at: at("Début", in: chapter), title: "N"))
        XCTAssertNil(Scenes.split(chapter, at: 0, title: "N"))
        XCTAssertNil(Scenes.split(chapter, at: (chapter as NSString).length, title: "N"))
        XCTAssertNil(Scenes.split(chapter, at: 9999, title: "N"))
        // A chapter without scenes yet becomes an opening and a scene.
        let plain = try XCTUnwrap(Scenes.split("# T\n\nUn.\nDeux.", at: 9, title: "N"))
        XCTAssertEqual(plain, "# T\n\nUn.\n<!-- scene: N -->\nDeux.")
    }

    func testMergingAScene() throws {
        let out = try XCTUnwrap(Scenes.merged(1, in: chapter))
        XCTAssertEqual(out, "# T\n\nDébut du chapitre.\nEncore le début.\n<!-- scene: A -->\nTexte A.\nSuite de A.\nTexte B.\n")
        // The opening takes the next scene in.
        XCTAssertEqual(Scenes.parse(try XCTUnwrap(Scenes.merged(0, in: chapter))).map(\.title), [nil, "B"])
        XCTAssertNil(Scenes.merged(2, in: chapter), "the last scene has no next")
        XCTAssertNil(Scenes.merged(-1, in: chapter))
        // A split merged back is the text as it was.
        let split = try XCTUnwrap(Scenes.split(chapter, at: at("Suite de A.", in: chapter), title: "N"))
        XCTAssertEqual(Scenes.merged(1, in: split), chapter)
        XCTAssertEqual(Scenes.merged(0, in: "<!-- scene: A -->\nUn.\n<!-- scene: B -->"), "<!-- scene: A -->\nUn.\n")
    }

    func testTheEditThatRenames() throws {
        let titled = try XCTUnwrap(Scenes.renaming(1, to: "Z", in: chapter))
        XCTAssertEqual((chapter as NSString).replacingCharacters(in: titled.range, with: titled.with),
                       chapter.replacingOccurrences(of: "<!-- scene: A -->", with: "<!-- scene: Z -->"))
        // The opening has no marker: it gets one, under the heading.
        let opening = try XCTUnwrap(Scenes.renaming(0, to: "Z", in: chapter))
        XCTAssertTrue((chapter as NSString).replacingCharacters(in: opening.range, with: opening.with).hasPrefix("# T\n\n<!-- scene: Z -->\nDébut du chapitre.\n"))
        XCTAssertNil(Scenes.renaming(3, to: "Z", in: chapter))
    }

    /// A book of two chapters in a temporary folder; the first has an opening and two scenes.
    private func book() throws -> BookSession {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("musset-cards-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try ParagraphCodec.encode(chapter).write(to: root.appendingPathComponent("01.md"), atomically: true, encoding: .utf8)
        try "# Deux\n\n<!-- scene: Là -->\nDéjà là.\n\n<!-- scene: Ailleurs -->\nPlus loin.\n".write(to: root.appendingPathComponent("02.md"), atomically: true, encoding: .utf8)
        let m = BookManifest(title: "T", chapters: [ChapterEntry(id: "01", file: "01.md", title: "Un"), ChapterEntry(id: "02", file: "02.md", title: "Deux")])
        try BookStore(root: root).saveManifest(m)
        try GitService(root: root).initRepo()
        return BookSession(root: root, manifest: m)
    }

    private func onDisk(_ s: BookSession, _ id: String) throws -> String {
        ParagraphCodec.decode(try String(contentsOf: s.root.appendingPathComponent("\(id).md"), encoding: .utf8))
    }

    func testSplitAndMergeInTheOpenChapter() throws {
        let saved = UserDefaults.standard.string(forKey: UILang.key)
        defer { UserDefaults.standard.set(saved, forKey: UILang.key) }
        UserDefaults.standard.set(UILang.fr.rawValue, forKey: UILang.key)
        let s = try book()
        XCTAssertEqual(s.selectedChapterID, "01")
        XCTAssertEqual(s.text, chapter)
        s.plot.update("01", "A") { $0.cells["main"] = PlotGrid.Cell(text: "celle de A") }
        s.plot.update("01", "B") { $0.cells["main"] = PlotGrid.Cell(text: "celle de B") }

        // Split: a third scene, named by its place, in the editor's text and on disk; the rows stay where they were.
        let new = try XCTUnwrap(s.splitScene(chapterID: "01", at: at("Suite de A.", in: s.text)))
        XCTAssertEqual(new, 2)
        XCTAssertEqual(s.scenes["01"]?.map(\.title), [nil, "A", "Scène 3", "B"])
        XCTAssertEqual(try onDisk(s, "01"), s.text)
        XCTAssertTrue(s.text.contains("Texte A.\n<!-- scene: Scène 3 -->\nSuite de A.\n"))
        XCTAssertEqual(s.plot.row("01", "A").cells["main"]?.text, "celle de A")
        XCTAssertNil(s.plot.rows["01"]?["Scène 3"])
        XCTAssertFalse(s.pendingCommit, "one commit")
        // Where a scene already starts: refused, nothing written.
        let before = s.text
        XCTAssertNil(s.splitScene(chapterID: "01", at: at("Texte B.", in: s.text)))
        XCTAssertEqual(s.text, before)
        // The number is bumped while the title is taken.
        let again = try XCTUnwrap(s.splitScene(chapterID: "01", at: at("Encore", in: s.text)))
        XCTAssertEqual(again, 1)
        XCTAssertEqual(s.scenes["01"]?.map(\.title), [nil, "Scène 2", "A", "Scène 3", "B"])
        XCTAssertTrue(s.mergeScene(chapterID: "01", index: 0))
        XCTAssertNil(s.splitScene(chapterID: "01", at: at("Texte B.", in: s.text) + 3))
        XCTAssertEqual(s.scenes["01"]?.map(\.title), [nil, "A", "Scène 3", "B"], "nothing to split before B's first paragraph")

        // Merge: the scene without a row takes the next one's; the text loses one marker.
        s.plot.update("01", "Scène 3") { $0.status = .done }
        XCTAssertTrue(s.mergeScene(chapterID: "01", index: 2))
        XCTAssertEqual(s.scenes["01"]?.map(\.title), [nil, "A", "Scène 3"])
        XCTAssertEqual(s.plot.rows["01"]?["Scène 3"]?.status, .done, "both had a row: this scene's stays")
        XCTAssertNil(s.plot.rows["01"]?["B"], "and the next one's is dropped")
        s.plot.update("01", "Scène 3") { $0.cells["main"] = PlotGrid.Cell(text: "celle de 3") }
        s.plot.rows["01"]?["A"] = nil
        XCTAssertTrue(s.mergeScene(chapterID: "01", index: 1))
        XCTAssertEqual(s.scenes["01"]?.map(\.title), [nil, "A"])
        XCTAssertEqual(s.plot.row("01", "A").cells["main"]?.text, "celle de 3", "this scene had no row: the next one's is kept under its title")
        XCTAssertNil(s.plot.rows["01"]?["Scène 3"])
        XCTAssertEqual(s.text, "# T\n\nDébut du chapitre.\nEncore le début.\n<!-- scene: A -->\nTexte A.\nSuite de A.\nTexte B.\n")
        XCTAssertEqual(try onDisk(s, "01"), s.text)
        XCTAssertEqual(PlotGrid.load(s.root).rows["01"]?.keys.sorted(), ["A"], "the plot is saved")
        XCTAssertFalse(s.mergeScene(chapterID: "01", index: 1), "the last scene has no next")
        XCTAssertFalse(s.pendingCommit)
    }

    func testRenameSplitAndMergeInAChapterThatIsNotOpen() throws {
        let saved = UserDefaults.standard.string(forKey: UILang.key)
        defer { UserDefaults.standard.set(saved, forKey: UILang.key) }
        UserDefaults.standard.set(UILang.en.rawValue, forKey: UILang.key)
        let s = try book()
        s.plot.update("02", "Là") { $0.cells["main"] = PlotGrid.Cell(text: "résumé") }

        XCTAssertTrue(s.renameScene("02", index: 0, to: "  Ici  "))
        XCTAssertEqual(s.scenes["02"]?.map(\.title), ["Ici", "Ailleurs"])
        XCTAssertEqual(s.plot.row("02", "Ici").cells["main"]?.text, "résumé", "the row follows the title")
        XCTAssertNil(s.plot.rows["02"]?["Là"])
        XCTAssertTrue(try onDisk(s, "02").contains("<!-- scene: Ici -->"))
        // Empty, or another scene's title: refused, and said for the second.
        XCTAssertFalse(s.renameScene("02", index: 0, to: "   "))
        XCTAssertNil(s.lastError)
        XCTAssertFalse(s.renameScene("02", index: 0, to: "Ailleurs"))
        XCTAssertNotNil(s.lastError)
        XCTAssertEqual(s.scenes["02"]?.map(\.title), ["Ici", "Ailleurs"])
        XCTAssertTrue(s.renameScene("02", index: 1, to: "Ailleurs"), "its own title is no rename")
        XCTAssertFalse(s.renameScene("02", index: 5, to: "X"))

        // The opening of the open chapter, renamed without an editor: it gets its marker, and its row.
        s.plot.update("01", "") { $0.status = .done }
        XCTAssertTrue(s.renameScene("01", index: 0, to: "Avant"))
        XCTAssertEqual(s.scenes["01"]?.map(\.title), ["Avant", "A", "B"])
        XCTAssertEqual(s.plot.rows["01"]?["Avant"]?.status, .done)
        XCTAssertTrue(s.text.hasPrefix("# T\n\n<!-- scene: Avant -->\nDébut du chapitre.\n"))
        // With the live editor's own edit, the text goes through it.
        var edits: [(NSRange, String)] = []
        XCTAssertTrue(s.renameScene("01", index: 1, to: "Alpha") { edits.append(($0, $1)) })
        XCTAssertEqual(edits.map(\.1), ["<!-- scene: Alpha -->"])
        XCTAssertEqual((s.text as NSString).substring(with: edits[0].0), "<!-- scene: A -->")

        // Split and merge on disk.
        let text = s.editorText(of: "02")
        XCTAssertNil(s.splitScene(chapterID: "02", at: at("Déjà", in: text)))
        try "# Deux\n\n<!-- scene: Ici -->\nDéjà là.\n\nEt encore.\n\n<!-- scene: Ailleurs -->\nPlus loin.\n".write(to: s.root.appendingPathComponent("02.md"), atomically: true, encoding: .utf8)
        s.scenes["02"] = Scenes.parse(s.editorText(of: "02"))
        let new = try XCTUnwrap(s.splitScene(chapterID: "02", at: at("Et encore.", in: s.editorText(of: "02"))))
        XCTAssertEqual(new, 1)
        XCTAssertEqual(s.scenes["02"]?.map(\.title), ["Ici", "Scene 2", "Ailleurs"])
        XCTAssertEqual(try String(contentsOf: s.root.appendingPathComponent("02.md"), encoding: .utf8),
                       "# Deux\n\n<!-- scene: Ici -->\nDéjà là.\n\n<!-- scene: Scene 2 -->\n\nEt encore.\n\n<!-- scene: Ailleurs -->\nPlus loin.\n",
                       "the rest of the file is as it was")
        XCTAssertTrue(s.mergeScene(chapterID: "02", index: 0))
        XCTAssertEqual(s.scenes["02"]?.map(\.title), ["Ici", "Ailleurs"])
        XCTAssertEqual(s.plot.row("02", "Ici").cells["main"]?.text, "résumé")

        // In a track the book's folder does not change: all three refuse.
        s.lastError = nil
        s.piste = Piste(id: "essai", name: "Essai", created: Date(), from: "le manuscrit")
        XCTAssertFalse(s.mergeScene(chapterID: "02", index: 0))
        XCTAssertNil(s.splitScene(chapterID: "02", at: 30))
        XCTAssertFalse(s.renameScene("02", index: 0, to: "Autre"))
        XCTAssertNotNil(s.lastError)
        s.piste = nil
    }

    func testAMoveIsUndoneAsFromThePlanUntilTheChapterIsReorganisedAgain() throws {
        let s = try book()
        let before = s.text
        s.moveScene(from: "01", index: 2, to: "01", slot: 1)
        XCTAssertEqual(s.scenes["01"]?.map(\.title), [nil, "B", "A"])
        XCTAssertEqual(s.lastSceneMove?.title, "B")
        s.undoSceneMove()
        XCTAssertEqual(s.text, before)
        XCTAssertNil(s.lastSceneMove)
        // A split after a move: undoing the move would take the split back with it, so it is no longer offered.
        s.moveScene(from: "01", index: 2, to: "01", slot: 1)
        XCTAssertNotNil(s.lastSceneMove)
        XCTAssertNotNil(s.splitScene(chapterID: "01", at: at("Suite de A.", in: s.text)))
        XCTAssertNil(s.lastSceneMove)
    }

    func testTheCardsAreAModeOfAPaneAndItsChapter() throws {
        let s = try book()
        let w = s.workspace
        let pane = try XCTUnwrap(w.focused).id
        XCTAssertEqual(w.activeTab, .chapter("01"))
        XCTAssertNil(w.focusedSceneCards)
        w.toggleSceneCards()
        XCTAssertTrue(w.showsSceneCards(pane: pane, chapter: "01"))
        XCTAssertEqual(w.focusedSceneCards, "01")
        XCTAssertEqual(w.activeTab, .chapter("01"), "the tab is the same chapter tab")
        XCTAssertFalse(String(data: try JSONEncoder().encode(w.saved), encoding: .utf8)!.contains("ards"), "not kept with the layout")
        w.selectSceneCard(2, pane: pane, chapter: "01")
        XCTAssertEqual(w.selectedSceneCard(pane: pane, chapter: "01"), 2)
        // Another chapter in the same pane has its own way of being shown.
        s.open(.chapter("02"), in: .newTab)
        XCTAssertNil(w.focusedSceneCards)
        XCTAssertTrue(w.showsSceneCards(pane: pane, chapter: "01"))
        // A chapter that is not in the pane cannot be shown as cards there.
        w.setSceneCards(true, pane: pane, chapter: "nope")
        XCTAssertFalse(w.showsSceneCards(pane: pane, chapter: "nope"))
        // Beside: the same chapter in the next pane, as cards there and as text here.
        w.openSceneCards("02", in: .nextPane)
        XCTAssertEqual(w.panes.count, 2)
        let other = try XCTUnwrap(w.focused).id
        XCTAssertNotEqual(other, pane)
        XCTAssertEqual(w.focusedSceneCards, "02")
        XCTAssertFalse(w.showsSceneCards(pane: pane, chapter: "02"))
        // The mode goes with its tab and its pane.
        w.close(0, in: other)
        XCTAssertEqual(w.panes.count, 1)
        XCTAssertEqual(w.sceneCards, [EditorCache.key(pane: pane, chapter: "01")])
        w.closeAll(.chapter("01"))
        XCTAssertTrue(w.sceneCards.isEmpty)
        XCTAssertTrue(w.sceneCardSelection.isEmpty)
    }

    func testTheCommandAndItsGate() throws {
        XCTAssertEqual(AppCommand.glyphs("view.sceneCards"), "⌃⌘L")
        let d = UserDefaults.standard
        let saved = (d.stringArray(forKey: "libraryPaths"), d.string(forKey: "lastBook"))
        defer { d.set(saved.0, forKey: "libraryPaths"); d.set(saved.1, forKey: "lastBook") }
        let s = try book()
        let app = AppState()
        app.openBook(s.root)
        let open = try XCTUnwrap(app.current)
        let c = CommandContext(app: app, bridge: EditorBridge())
        let cmd = try XCTUnwrap(AppCommand.byID["view.sceneCards"])
        open.open("01")
        XCTAssertTrue(app.hasScenes)
        XCTAssertTrue(cmd.applies(c))
        cmd.run(c)
        XCTAssertEqual(open.workspace.focusedSceneCards, "01")
        XCTAssertEqual(cmd.isOn?(c), true)
        cmd.run(c)
        XCTAssertNil(open.workspace.focusedSceneCards)
        // A chapter of one scene has no cards to show; a page that is not a chapter neither.
        XCTAssertTrue(open.mergeScene(chapterID: "01", index: 1))
        XCTAssertTrue(open.mergeScene(chapterID: "01", index: 0))
        XCTAssertFalse(app.hasScenes)
        XCTAssertFalse(cmd.applies(c))
        app.open(OverviewTab.synopsis.tab)
        XCTAssertFalse(cmd.applies(c))
    }

    func testWhereACardLands() {
        // 3 columns of 200 with gaps of 16, five cards: rows of 3 and 2.
        let g = SceneGrid(width: 3 * 200 + 2 * 16, size: 200, count: 5)
        XCTAssertEqual(g.columns, 3)
        XCTAssertEqual(g.cardWidth, 200)
        XCTAssertEqual(g.rows, 2)
        XCTAssertEqual(g.indices(row: 1), 3..<5)
        XCTAssertEqual(g.slot(g.place(at: CGPoint(x: 10, y: 10))), 0)
        XCTAssertEqual(g.slot(g.place(at: CGPoint(x: 150, y: 10))), 1, "past the middle of a card: after it")
        XCTAssertEqual(g.slot(g.place(at: CGPoint(x: 630, y: 10))), 3, "the end of the first row")
        XCTAssertEqual(g.place(at: CGPoint(x: 630, y: 10)), SceneGrid.Place(row: 0, column: 3))
        XCTAssertEqual(g.slot(g.place(at: CGPoint(x: 10, y: g.cardHeight + 40))), 3, "the same slot, shown at the head of the second row")
        XCTAssertEqual(g.slot(g.place(at: CGPoint(x: 630, y: g.cardHeight + 40))), 5, "after the last card")
        XCTAssertEqual(g.slot(g.place(at: CGPoint(x: -50, y: 9999))), 3)
        XCTAssertEqual(g.bar(SceneGrid.Place(row: 0, column: 1)).x, 200 + 8 - 1.5)
        // A pane narrower than a card still shows one column.
        XCTAssertEqual(SceneGrid(width: 100, size: 300, count: 2).columns, 1)
        XCTAssertEqual(SceneGrid(width: 100, size: 300, count: 0).rows, 0)
    }

    /// The cards drawn offscreen, light and dark, to look at them without opening Musset.
    /// MUSSET_LIVE_SHOTS=<dir> (skipped otherwise), as `LiveBibleShots`.
    func testSceneCardsShots() async throws {
        guard let dir = ProcessInfo.processInfo.environment["MUSSET_LIVE_SHOTS"] else { throw XCTSkip("set MUSSET_LIVE_SHOTS") }
        let out = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let d = UserDefaults.standard
        let saved = (d.string(forKey: UILang.key), d.stringArray(forKey: "libraryPaths"), d.string(forKey: "lastBook"), d.object(forKey: "sceneCardSize"))
        defer { d.set(saved.0, forKey: UILang.key); d.set(saved.1, forKey: "libraryPaths"); d.set(saved.2, forKey: "lastBook"); d.set(saved.3, forKey: "sceneCardSize") }
        d.set("fr", forKey: UILang.key)
        d.removeObject(forKey: "libraryPaths"); d.removeObject(forKey: "lastBook"); d.removeObject(forKey: "sceneCardSize")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cards-\(UUID())/Le sel")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let para = ["Nora descendit du bac la dernière, le manteau de son père plié sur le bras, et resta un moment sur la cale à regarder l’eau *grise* se refermer derrière le bateau.",
                    "— Tu aurais pu prévenir, dit Tom sans se retourner.",
                    "Elle ne répondit pas. Le vent portait l’odeur des bassins, cette odeur de vase et de fer qu’elle avait crue oubliée, et qui revenait d’un seul coup, **entière**, comme une phrase apprise par cœur.",
                    "Ils marchèrent jusqu’à la saline sans se parler. Les râteaux étaient restés contre le mur, là où leur mère les rangeait.",
                    "— Il est mort mardi, dit-elle enfin."]
        func scene(_ title: String, _ n: Int) -> String { "<!-- scene: \(title) -->\n\n" + (0..<n).map { para[$0 % para.count] }.joined(separator: "\n\n") + "\n\n" }
        let text = "# La traversée\n\n" + para[0] + "\n\n" + para[3] + "\n\n" + scene("Le bac", 5) + scene("La cale", 2) + scene("", 3)
            + scene("La saline, onze ans après les funérailles", 9) + scene("Mardi", 1)
        try text.write(to: root.appendingPathComponent("01.md"), atomically: true, encoding: .utf8)
        try BookStore(root: root).saveManifest(BookManifest(title: "Le sel", author: "A.", lang: "fr", chapters: [ChapterEntry(id: "01", file: "01.md", title: "La traversée", status: .draft)]))
        try GitService(root: root).initRepo()

        let app = AppState()
        app.openBook(root)
        let s = try XCTUnwrap(app.current)
        s.open("01")
        let bridge = EditorBridge(), ann = Annotator(), proof = AutoProofreader()
        bridge.annotator = ann; bridge.proof = proof
        let view = ContentView(app: app, bridge: bridge, chat: ChatModel(), pangram: PangramModel(), proof: proof, annotator: ann)
        let retina = NSScreen.screens.max { $0.backingScaleFactor < $1.backingScaleFactor }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900), styleMask: [.titled, .fullSizeContentView],
                              backing: .buffered, defer: false, screen: retina)
        window.contentView = NSHostingView(rootView: view.frame(width: 1440, height: 900))
        func shot(_ name: String, dark: Bool, _ setup: () -> Void) async throws {
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            setup()
            try await Task.sleep(for: .seconds(1.2))
            let v = window.contentView!
            let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds)!
            v.cacheDisplay(in: v.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name))
        }
        let pane = try XCTUnwrap(s.workspace.focused).id
        try await shot("12-scene-cards-dark.png", dark: true) {
            app.showInspector = false
            s.workspace.toggleSceneCards()
            s.workspace.selectSceneCard(2, pane: pane, chapter: "01")
        }
        try await shot("12-scene-cards.png", dark: false) {}
        try await shot("12b-back-to-text.png", dark: true) { s.workspace.toggleSceneCards() }
        try await shot("13-scene-cards-beside.png", dark: true) {
            s.workspace.openSceneCards("01", in: .nextPane)
            s.moveScene(from: "01", index: 4, to: "01", slot: 1)
        }
    }
}
