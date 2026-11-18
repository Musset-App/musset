import SwiftUI
import XCTest
@testable import Musset

/// The scenes seen from the book and from a part: what a chapter's card says of its text, the ticks under it,
/// the page's place among the saved tabs, and the ways between the three levels.
@MainActor
final class BookScenesTests: XCTestCase {
    func testAChaptersOpeningAndClosing() {
        let text = "# Flower Island\n\n## I\n\n<!-- scene: Hors-bord -->\n\n« I’ll be your captain », a dit la jeune femme.\n\nLa nuit était tombée.\n"
            + "<!-- note à moi :\nsur deux lignes -->\n# Plus loin\n<!-- scène: Le quai -->\nLe chauffeur chargeait nos sacs.\n\nDernière ligne du chapitre.\n"
        // Budgets too small for the whole: the first lines, then the last ones, neither a marker nor the chapter's heading.
        let cut = SceneExcerpts.excerpt(of: text, opening: 60, closing: 45, scene: 30)
        XCTAssertEqual(cut.opening, "« I’ll be your captain », a dit la jeune femme.\nLa nuit…")
        XCTAssertEqual(cut.closing, "… nos sacs.\nDernière ligne du chapitre.")
        XCTAssertFalse((cut.opening + cut.closing).contains("scene"))
        XCTAssertFalse((cut.opening + cut.closing).contains("note à moi"))
        // Each scene's first lines; a heading inside the text is the author's, and stays.
        XCTAssertEqual(cut.scenes, ["« I’ll be your captain », a…", "Le chauffeur chargeait nos…"])
        XCTAssertTrue(SceneExcerpts.prose(text, skipHeadings: true).contains("# Plus loin"))

        // A closing that starts at a paragraph says so with no ellipsis.
        XCTAssertEqual(SceneExcerpts.excerpt(of: text, opening: 60, closing: 31, scene: 30).closing, "Dernière ligne du chapitre.")

        // A short chapter: its text once, nothing to close on.
        let short = SceneExcerpts.excerpt(of: "# T\n\nUn.\n\nDeux.\n")
        XCTAssertEqual(short, ChapterExcerpt(opening: "Un.\nDeux.", closing: "", scenes: ["Un.\nDeux."]))
        // Longer than the opening but shorter than both: the end is what the opening left, never the same words twice.
        let mid = SceneExcerpts.excerpt(of: "# T\n\nun deux trois quatre cinq six sept huit neuf dix", opening: 20, closing: 200)
        XCTAssertEqual(mid.opening, "un deux trois…")
        XCTAssertEqual(mid.closing, "quatre cinq six sept huit neuf dix")

        // Nothing written yet.
        XCTAssertEqual(SceneExcerpts.excerpt(of: "# T\n\n"), ChapterExcerpt(opening: "", closing: "", scenes: [""]))
        XCTAssertEqual(SceneExcerpts.excerpt(of: ""), ChapterExcerpt(opening: "", closing: "", scenes: [""]))
        // The opening scene, which has no marker, leaves the chapter's heading out too.
        XCTAssertEqual(SceneExcerpts.excerpt(of: "# T\n\nAvant.\n<!-- scene: A -->\nAprès.").scenes, ["Avant.", "Après."])
        // One long word is cut where the budget ends.
        XCTAssertEqual(SceneExcerpts.head("abcdefghij", 4).text, "abcd…")
        XCTAssertEqual(SceneExcerpts.tail("abcdefghij", 4), "…ghij")
    }

    func testTicksShareTheChapterAsItsScenesDo() {
        let scenes = Scenes.parse("<!-- scene: A -->\nun deux trois\n<!-- scene: B -->\nun\n<!-- scene: C -->\n\n<!-- scene: D -->\nun deux trois quatre cinq\n")
        XCTAssertEqual(scenes.map(\.words), [3, 1, 0, 5])
        let ticks = SceneExcerpts.ticks(scenes)
        // An empty scene still has its tick, as thin as a word.
        XCTAssertEqual(ticks, [0.3, 0.1, 0.1, 0.5])
        XCTAssertEqual(ticks.reduce(0, +), 1, accuracy: 1e-9)
        XCTAssertEqual(SceneExcerpts.ticks(Scenes.parse("")), [1])
        XCTAssertEqual(SceneExcerpts.ticks([]), [])
    }

    /// The scenes were a page of Overview for a day: they are the board of its first page now, and a layout kept
    /// on that page, or anything still holding its name, opens the first page.
    func testALayoutKeptOnTheScenesPageOpensOverview() throws {
        XCTAssertEqual(OverviewTab.allCases, [.summary, .synopsis, .grid])
        XCTAssertEqual(OverviewTab.summary.tab, .overview("summary"), "the first page keeps the name saved layouts know")
        XCTAssertEqual(PaneTab.overview("scenes").overview, .summary)
        let pane = Pane(tabs: [.chapter("01"), .overview("scenes")], active: 1)
        let saved = Workspace.Saved(root: .pane(pane), focusedPane: pane.id)
        let back = try JSONDecoder().decode(Workspace.Saved.self, from: JSONEncoder().encode(saved))
        XCTAssertEqual(back.root.panes.first?.tabs, [.chapter("01"), .overview("summary")])
        let w = Workspace(saved: back) { _ in true }
        XCTAssertEqual(w.activeTab, OverviewTab.summary.tab)
        // Overview is one tab: the page turns it, whatever page it was on.
        w.open(OverviewTab.grid.tab)
        w.open(OverviewTab.summary.tab)
        XCTAssertEqual(w.focused?.tabs, [.chapter("01"), .overview("summary")])
        // How far the board is zoomed is the window's, in memory: a layout does not carry it.
        w.zoomScenes(toPart: "p")
        XCTAssertEqual(Workspace(saved: w.saved) { _ in true }.scenesLevel, .book)
    }

    /// A book in a temporary folder: a prologue in no part, two chapters in a first part, one in a second.
    private func book() throws -> BookSession {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("musset-zoom-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let texts = ["00": "# Avant\n\nUn mot d’avant.\n",
                     "01": "# Un\n\nL’ouverture du un.\n\n<!-- scene: Reste -->\nCe qui reste ici.\n\n<!-- scene: Part -->\nCe qui part là-bas.\n",
                     "02": "# Deux\n\n<!-- scene: Là -->\nDéjà là.\n\n<!-- scene: Ailleurs -->\nPlus loin.\n",
                     "03": "# Trois\n\nUne seule scène.\n"]
        for (id, text) in texts { try text.write(to: root.appendingPathComponent("\(id).md"), atomically: true, encoding: .utf8) }
        var m = BookManifest(title: "T", chapters: [ChapterEntry(id: "00", file: "00.md", title: "Avant"),
                                                   ChapterEntry(id: "01", file: "01.md", title: "Un", part: "a"),
                                                   ChapterEntry(id: "02", file: "02.md", title: "Deux", part: "a"),
                                                   ChapterEntry(id: "03", file: "03.md", title: "Trois", part: "b")])
        m.parts = [BookPart(id: "a", title: ""), BookPart(id: "b", title: "La fuite")]
        try BookStore(root: root).saveManifest(m)
        try GitService(root: root).initRepo()
        return BookSession(root: root, manifest: m)
    }

    func testTheBookInBands() throws {
        let s = try book()
        let bands = s.manifest.scenesBands
        XCTAssertEqual(bands.map { $0.part?.id }, [nil, "a", "b"])
        XCTAssertEqual(bands.map { $0.chapters.map(\.entry.id) }, [["00"], ["01", "02"], ["03"]])
        XCTAssertEqual(bands[1].chapters.map(\.index), [1, 2], "each chapter keeps its place in the book")
        XCTAssertTrue(s.manifest.hasPartsInUse)
        XCTAssertNil(s.manifest.part(of: "00"))
        XCTAssertEqual(s.manifest.part(of: "02")?.id, "a")
        // A book without parts is one band, and has no part level.
        var plain = s.manifest
        plain.parts = nil
        XCTAssertEqual(plain.scenesBands.map { $0.chapters.count }, [4], "a part that no longer exists is no part")
        XCTAssertFalse(plain.hasPartsInUse)
        XCTAssertEqual(BookManifest(title: "T", chapters: []).scenesBands.count, 0)
    }

    func testACardsTextIsMadeOnceAndAgainWhenTheChapterChanges() throws {
        let s = try book()
        let first = s.cardText(of: "02")
        XCTAssertEqual(first.excerpt, ChapterExcerpt(opening: "Déjà là.\nPlus loin.", closing: "", scenes: ["Déjà là.", "Plus loin."]))
        // Kept: a text changed behind the session's back is not read again while its scenes stand.
        try "# Deux\n\n<!-- scene: Là -->\nAutre chose.\n".write(to: s.root.appendingPathComponent("02.md"), atomically: true, encoding: .utf8)
        XCTAssertEqual(s.cardText(of: "02").excerpt, first.excerpt)
        // Written through the session: its scenes change, and the card with them.
        try s.writeChapterText("02", "# Deux\n\n<!-- scene: Là -->\nDéjà là, *vraiment*.\n")
        XCTAssertEqual(s.cardText(of: "02").excerpt.scenes, ["Déjà là, *vraiment*."])
        XCTAssertEqual(String(s.cardText(of: "02").opening.characters), "Déjà là, vraiment.", "emphasis is shown, not its marks")
        // The open chapter is read as it stands in the editor.
        XCTAssertEqual(s.selectedChapterID, "00")
        XCTAssertEqual(s.cardText(of: "00").excerpt.opening, "Un mot d’avant.")
    }

    /// What a drop in a part's lane does: `BookScenesView.move` calls `moveScene`, with the slot the lane's grid gives.
    func testASceneDroppedInAnotherChaptersLane() throws {
        let saved = UserDefaults.standard.string(forKey: UILang.key)
        defer { UserDefaults.standard.set(saved, forKey: UILang.key) }
        UserDefaults.standard.set(UILang.fr.rawValue, forKey: UILang.key)
        let s = try book()
        s.plot.update("01", "Part") { $0.cells["main"] = PlotGrid.Cell(text: "résumé") }
        s.plot.update("02", "Là") { $0.cells["main"] = PlotGrid.Cell(text: "là") }
        let before = (s.editorText(of: "01"), s.editorText(of: "02"), s.plot)
        _ = s.cardText(of: "01"); _ = s.cardText(of: "02")

        // Between the two scenes of the other chapter: the slot a lane of two cards gives for its middle gap.
        let grid = SceneGrid(width: 600, size: 168, count: 2, height: 122)
        let slot = grid.slot(grid.place(at: CGPoint(x: grid.cardWidth + SceneGrid.gap / 2, y: 10)))
        XCTAssertEqual(slot, 1)
        s.moveScene(from: "01", index: 2, to: "02", slot: slot)
        XCTAssertEqual(s.editorText(of: "01"), ParagraphCodec.decode("# Un\n\nL’ouverture du un.\n\n<!-- scene: Reste -->\nCe qui reste ici.\n"))
        XCTAssertEqual(s.editorText(of: "02"), ParagraphCodec.decode("# Deux\n\n<!-- scene: Là -->\nDéjà là.\n\n<!-- scene: Part -->\nCe qui part là-bas.\n\n<!-- scene: Ailleurs -->\nPlus loin.\n"))
        XCTAssertEqual(s.scenes["02"]?.map(\.title), ["Là", "Part", "Ailleurs"])
        XCTAssertEqual(s.plot.row("02", "Part").cells["main"]?.text, "résumé", "the plot row follows the scene")
        XCTAssertNil(s.plot.rows["01"]?["Part"])
        XCTAssertEqual(s.plot.row("02", "Là").cells["main"]?.text, "là")
        XCTAssertEqual(try String(contentsOf: s.root.appendingPathComponent("02.md"), encoding: .utf8), ParagraphCodec.encode(s.editorText(of: "02")))
        XCTAssertFalse(s.pendingCommit, "one commit")
        // The lanes show the scenes where they are now.
        XCTAssertEqual(s.cardText(of: "01").excerpt.scenes, ["L’ouverture du un.", "Ce qui reste ici."])
        XCTAssertEqual(s.cardText(of: "02").excerpt.scenes, ["Déjà là.", "Ce qui part là-bas.", "Plus loin."])
        XCTAssertEqual(s.lastSceneMove?.title, "Part")

        // The opening, which had no marker, goes to the end of the other lane under a name of its own.
        s.moveScene(from: "01", index: 0, to: "02", slot: 3)
        XCTAssertEqual(s.scenes["01"]?.map(\.title), ["Reste"])
        XCTAssertEqual(s.scenes["02"]?.map(\.title), ["Là", "Part", "Ailleurs", "Ouverture"])
        s.undoSceneMove()
        XCTAssertEqual(s.scenes["02"]?.map(\.title), ["Là", "Part", "Ailleurs"])
        XCTAssertNil(s.lastSceneMove)

        // The first move taken back by hand: the bar's undo holds one move, so the texts are put back as they were.
        s.moveScene(from: "02", index: 1, to: "01", slot: 2)
        XCTAssertEqual(s.scenes["01"]?.map(\.title), [nil, "Reste", "Part"])
        XCTAssertEqual(s.plot.row("01", "Part").cells["main"]?.text, "résumé")
        s.undoSceneMove()
        s.moveScene(from: "01", index: 0, to: "01", slot: 2)
        XCTAssertEqual(s.scenes["01"]?.map(\.title), ["Reste", "Ouverture"], "within a lane too")
        s.undoSceneMove()
        XCTAssertEqual(s.editorText(of: "01"), ParagraphCodec.decode("# Un\n\nL’ouverture du un.\n\n<!-- scene: Reste -->\nCe qui reste ici.\n"))
        XCTAssertEqual(before.2.rows["02"]?.keys.sorted(), ["Là"])
        XCTAssertEqual(before.0.contains("Ce qui part"), true)
        XCTAssertEqual(before.1.contains("Ce qui part"), false)
    }

    func testUndoingADropRestoresBothChapters() throws {
        let s = try book()
        s.plot.update("01", "Part") { $0.cells["main"] = PlotGrid.Cell(text: "résumé") }
        let before = (s.editorText(of: "01"), s.editorText(of: "02"), s.plot)
        s.moveScene(from: "01", index: 2, to: "02", slot: 0)
        XCTAssertNotEqual(s.editorText(of: "02"), before.1)
        s.undoSceneMove()
        XCTAssertEqual(s.editorText(of: "01"), before.0)
        XCTAssertEqual(s.editorText(of: "02"), before.1)
        XCTAssertEqual(s.plot, before.2)
        XCTAssertEqual(s.cardText(of: "02").excerpt.scenes, ["Déjà là.", "Plus loin."])
        XCTAssertFalse(s.pendingCommit)
    }

    func testBetweenTheThreeLevels() throws {
        let s = try book()
        let w = s.workspace
        let pane = try XCTUnwrap(w.focused).id
        XCTAssertEqual(w.activeTab, .chapter("00"))
        XCTAssertEqual(w.scenesLevel, .book)

        // From the book: nothing chosen, the part of the chapter written in, else the first.
        XCTAssertEqual(s.scenesPartToZoom(in: w), "a")
        XCTAssertEqual(s.scenesChapter(in: w), "00")
        w.chooseScenesChapter("03")
        XCTAssertEqual(s.scenesPartToZoom(in: w), "b")
        w.zoomScenes(toPart: "b")
        XCTAssertEqual(s.scenesPart(in: w)?.id, "b")
        XCTAssertEqual(s.partName(try XCTUnwrap(s.scenesPart(in: w))), "II. La fuite")
        // Back at the book, the part is remembered; a chosen chapter in no part leaves it be.
        w.zoomScenes(toPart: nil)
        XCTAssertNil(s.scenesPart(in: w))
        w.chooseScenesChapter("00")
        XCTAssertEqual(s.scenesPartToZoom(in: w), "b")
        // In a part, « Chapter » goes to one of its chapters.
        w.zoomScenes(toPart: "a")
        XCTAssertEqual(s.scenesChapter(in: w), "01")
        // A part that is gone is no level: the page falls back to the book.
        w.zoomScenes(toPart: "gone")
        XCTAssertNil(s.scenesPart(in: w))

        // Into a chapter of several scenes: its cards, in this pane, the scene chosen.
        w.open(OverviewTab.summary.tab)
        s.enterChapter("02", scene: 1, in: w, pane: pane)
        XCTAssertEqual(w.activeTab, .chapter("02"))
        XCTAssertEqual(s.selectedChapterID, "02")
        XCTAssertTrue(w.showsSceneCards(pane: pane, chapter: "02"))
        XCTAssertEqual(w.selectedSceneCard(pane: pane, chapter: "02"), 1)
        XCTAssertEqual(w.panes.count, 1)
        // And out again, to its part, then to the book: the same Overview tab, turned.
        s.zoomOut(from: "02", toPart: true, in: w, pane: pane)
        XCTAssertEqual(w.activeTab, OverviewTab.summary.tab)
        XCTAssertEqual(s.scenesPart(in: w)?.id, "a")
        XCTAssertEqual(w.scenesChapter, "02")
        // The page is asked to scroll past the book's numbers to the chapter, on its cards; once.
        XCTAssertEqual(w.takeScenesJump(), ScenesJump(chapter: "02", cards: true))
        XCTAssertNil(w.takeScenesJump())
        w.foldScenes("a", true)
        s.zoomOut(from: "02", toPart: false, in: w, pane: pane)
        XCTAssertEqual(w.scenesLevel, .book)
        XCTAssertFalse(w.scenesFolded.contains("a"), "the chapter one comes from is in sight")
        XCTAssertEqual(w.focused?.tabs.filter { $0.overview != nil }.count, 1)
        // A chapter of one scene opens as its text.
        s.enterChapter("03", in: w, pane: pane)
        XCTAssertEqual(w.activeTab, .chapter("03"))
        XCTAssertFalse(w.showsSceneCards(pane: pane, chapter: "03"))
        // A chapter in no part has no part to zoom out to.
        s.zoomOut(from: "00", toPart: true, in: w, pane: pane)
        XCTAssertEqual(w.scenesLevel, .book)
    }

    /// The book and part levels drawn offscreen, light and dark, on a book of forty chapters in three parts.
    /// MUSSET_LIVE_SHOTS=<dir> (skipped otherwise), as `SceneCardsTests.testSceneCardsShots`.
    func testBookScenesShots() async throws {
        guard let dir = ProcessInfo.processInfo.environment["MUSSET_LIVE_SHOTS"] else { throw XCTSkip("set MUSSET_LIVE_SHOTS") }
        let out = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let d = UserDefaults.standard
        let saved = (d.string(forKey: UILang.key), d.stringArray(forKey: "libraryPaths"), d.string(forKey: "lastBook"), d.object(forKey: "sceneCardSize"))
        defer { d.set(saved.0, forKey: UILang.key); d.set(saved.1, forKey: "libraryPaths"); d.set(saved.2, forKey: "lastBook"); d.set(saved.3, forKey: "sceneCardSize") }
        d.set("fr", forKey: UILang.key)
        d.removeObject(forKey: "libraryPaths"); d.removeObject(forKey: "lastBook"); d.removeObject(forKey: "sceneCardSize")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zoom-\(UUID())/Le sel")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let para = ["Nora descendit du bac la dernière, le manteau de son père plié sur le bras, et resta un moment sur la cale à regarder l’eau *grise* se refermer derrière le bateau.",
                    "— Tu aurais pu prévenir, dit Tom sans se retourner.",
                    "Elle ne répondit pas. Le vent portait l’odeur des bassins, cette odeur de vase et de fer qu’elle avait crue oubliée, et qui revenait d’un seul coup, **entière**, comme une phrase apprise par cœur.",
                    "Ils marchèrent jusqu’à la saline sans se parler. Les râteaux étaient restés contre le mur, là où leur mère les rangeait.",
                    "— Il est mort mardi, dit-elle enfin.",
                    "Le soir, la marée remonta jusqu’aux premières tables, et personne ne songea à fermer les vannes."]
        let names = ["Le bac", "La cale", "", "La saline, onze ans après les funérailles", "Mardi", "Les vannes", "Le grenier", "", "Tom"]
        var chapters: [ChapterEntry] = []
        for n in 1...40 {
            let count = n == 7 ? 1 : n == 12 ? 0 : 2 + (n * 7) % 8
            var text = "# Chapitre \(n)\n\n"
            if n % 3 == 0 { text += para[n % para.count] + "\n\n" }
            for k in 0..<count {
                text += "<!-- scene: \(names[(n + k) % names.count]) -->\n\n" + (0...((n + k * 5) % 6)).map { para[($0 + n + k) % para.count] }.joined(separator: "\n\n") + "\n\n"
            }
            if n == 7 { text = "# Chapitre 7\n\n" + para[2] + "\n\n" + para[4] + "\n" }
            if n == 12 { text = "# Chapitre 12\n\n" }
            if n == 21 { text = "# Chapitre 21\n\n— Viens.\n\n<!-- scene: Le quai -->\n\n— Non.\n" }
            let id = String(format: "%02d", n)
            try text.write(to: root.appendingPathComponent("\(id).md"), atomically: true, encoding: .utf8)
            let title = [3: "Nice", 14: "La maison du quai des Belges, un dimanche", 28: "Peninsula", 33: "Flower Island"][n] ?? "Chapitre \(n)"
            chapters.append(ChapterEntry(id: id, file: "\(id).md", title: title, status: n < 20 ? .final : n < 30 ? .done : .draft,
                                         part: n == 1 ? nil : n <= 12 ? "a" : n <= 26 ? "b" : "c"))
        }
        var m = BookManifest(title: "Le sel", author: "A.", lang: "fr", chapters: chapters)
        m.parts = [BookPart(id: "a", title: ""), BookPart(id: "b", title: "La fuite"), BookPart(id: "c", title: "")]
        try BookStore(root: root).saveManifest(m)
        try GitService(root: root).initRepo()

        let app = AppState()
        app.openBook(root)
        let s = try XCTUnwrap(app.current)
        s.open("33")
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
        let w = s.workspace
        let pane = try XCTUnwrap(w.focused).id
        // Every chapter's card text, as the page asks for them when it opens: sixty would take no longer to feel.
        let clock = ContinuousClock()
        let took = clock.measure { for ch in s.manifest.chapters { _ = s.cardText(of: ch.id) } }
        print("BookScenes: 40 chapters' card texts in \(took)")
        XCTAssertLessThan(took, .milliseconds(250))

        try await shot("14-book-scenes-dark.png", dark: true) {
            app.showInspector = false
            w.foldScenes("a", true)
            w.chooseScenesChapter("33")
            // The board is under the book's numbers: the page is brought to it, as from a chapter's cards.
            w.jumpToScenes(ScenesJump(chapter: "33", cards: true))
            w.open(OverviewTab.summary.tab)
        }
        try await shot("14-book-scenes.png", dark: false) { w.foldScenes("a", false); w.chooseScenesChapter("03") }
        try await shot("14b-book-scenes-small.png", dark: true) { d.set(220.0, forKey: "sceneCardSize") }
        d.removeObject(forKey: "sceneCardSize")
        try await shot("15-part-scenes-dark.png", dark: true) { s.showPartOnBoard("c", in: w); w.chooseScenesChapter("28") }
        try await shot("15-part-scenes.png", dark: false) {
            w.zoomScenes(toPart: "b")
            s.moveScene(from: "14", index: 1, to: "15", slot: 2)
        }
        try await shot("16-chapter-from-part-dark.png", dark: true) { s.enterChapter("33", scene: 2, in: w, pane: pane) }
        try await shot("17-book-scenes-narrow-pane.png", dark: true) {
            s.zoomOut(from: "33", toPart: false, in: w, pane: pane)
            w.open(.chapter("33"), in: .split(.right))
            w.focus(pane)
        }
    }

    /// A reviewer's marks are not shown raw on a chapter's card: the author's words are.
    func testAnExcerptLeavesOutAReviewersMarks() {
        let e = SceneExcerpts.excerpt(of: "# One\n\nNobody had {~~ever locked~>locked~~}{@Claire} anything{>>why?<<}{@Claire} here.")
        XCTAssertEqual(e.opening, "Nobody had ever locked anything here.")
    }
}
