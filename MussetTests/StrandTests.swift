import SwiftUI
import XCTest
@testable import Musset

/// Strands: the threads a book's chapters follow (a period, a narrator, a place). Giving a chapter one, the
/// Overview's legend and its totals, the board read along one strand, and what removing one leaves behind.
@MainActor
final class StrandTests: XCTestCase {
    /// A prologue in no part, two chapters in a first part, two in a second; no structure.
    private func manifest() -> BookManifest {
        var m = BookManifest(title: "T", author: "A", lang: "fr", chapters: [
            ChapterEntry(id: "00", file: "00.md", title: "Avant", kind: "prologue"),
            ChapterEntry(id: "01", file: "01.md", title: "Un", status: .final, part: "a"),
            ChapterEntry(id: "02", file: "02.md", title: "Deux", status: .done, part: "a"),
            ChapterEntry(id: "03", file: "03.md", title: "Trois", excludeFromExport: true, status: .done, part: "b"),
            ChapterEntry(id: "04", file: "04.md", title: "Quatre", part: "b")])
        m.parts = [BookPart(id: "a", title: ""), BookPart(id: "b", title: "La fuite")]
        return m
    }

    private func book(_ m: BookManifest? = nil) throws -> BookSession {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("musset-strands-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let m = m ?? manifest()
        for (i, ch) in m.chapters.enumerated() {
            try ("# \(ch.title)\n\n" + String(repeating: "mot ", count: (i + 1) * 10) + "\n").write(to: root.appendingPathComponent(ch.file), atomically: true, encoding: .utf8)
        }
        try BookStore(root: root).saveManifest(m)
        let git = GitService(root: root)
        try git.initRepo()
        _ = try git.commit(paths: m.chapters.map(\.file) + [".musset"], message: "start")
        return BookSession(root: root, manifest: m)
    }

    private func saved(_ s: BookSession) throws -> BookManifest { try BookStore(root: s.root).loadManifest() }

    // MARK: Assigning

    func testAStrandMadeFromAChaptersMenu() throws {
        let s = try book()
        let before = s.manifest
        XCTAssertNil(before.structure)
        let id = try XCTUnwrap(s.newStrand(named: "  1943 ", for: ["01"]))
        // The book takes the form it read as, as on its Structure page, and nothing else of it moves.
        XCTAssertEqual(s.manifest.structure?.form, .novelInParts)
        XCTAssertEqual(s.manifest.structure, { var b = BookStructure(form: .novelInParts); b.strands = s.manifest.strands; return b }())
        XCTAssertEqual(s.manifest.strands, [BookStructure.Strand(id: id, name: "1943", colour: BookStructure.strandColours[0])])
        XCTAssertEqual(s.manifest.chapters.map(\.strand), [nil, id, nil, nil, nil])
        var bare = s.manifest
        bare.structure = nil
        for i in bare.chapters.indices { bare.chapters[i].strand = nil }
        XCTAssertEqual(bare, before, "titles, parts, kinds, statuses, exclusions: untouched")
        XCTAssertEqual(try saved(s), s.manifest, "written to book.json")
        XCTAssertEqual(try saved(s).chapters[1].strand, id)

        // The next one takes the next colour; a colour the author moved a strand off is free again.
        let today = try XCTUnwrap(s.newStrand(named: "Aujourd’hui", for: ["02", "04"]))
        XCTAssertEqual(s.manifest.strand(today)?.colour, BookStructure.strandColours[1])
        XCTAssertEqual(s.manifest.chapters.map(\.strand), [nil, id, today, nil, today])
        s.setStructure { $0.structure?.strands?[0].colour = BookStructure.strandColours[4] }
        let third = try XCTUnwrap(s.newStrand(named: "Nice"))
        XCTAssertEqual(s.manifest.strand(third)?.colour, BookStructure.strandColours[0], "the first colour no strand has")
        XCTAssertEqual(s.manifest.pieces(in: third), 0, "made for no chapter: it only exists")
        // A name the book has is that strand; no name is no strand.
        XCTAssertEqual(s.newStrand(named: "aujourd’hui", for: ["03"]), today)
        XCTAssertEqual(s.manifest.strands.count, 3)
        XCTAssertEqual(s.manifest.chapters[3].strand, today)
        XCTAssertNil(s.newStrand(named: "   ", for: ["00"]))
        XCTAssertNil(s.manifest.chapters[0].strand)
        // The palette's neighbours differ in lightness, not only in hue.
        func light(_ hex: String) -> Double {
            let v = UInt64(hex.dropFirst(), radix: 16) ?? 0
            return (0.2126 * Double((v >> 16) & 0xFF) + 0.7152 * Double((v >> 8) & 0xFF) + 0.0722 * Double(v & 0xFF)) / 255
        }
        let palette = BookStructure.strandColours
        XCTAssertEqual(Set(palette).count, palette.count)
        for (a, b) in zip(palette, palette.dropFirst()) { XCTAssertGreaterThan(abs(light(a) - light(b)), 0.12, "\(a) \(b)") }
    }

    func testAssigningAndClearingAStrand() throws {
        var m = manifest()
        m.structure = BookStructure(form: .play)
        m.structure?.strands = [.init(id: "s1", name: "1943", colour: "#8FA3FF"), .init(id: "s2", name: "", colour: "#8E4A7A")]
        let s = try book(m)
        s.setStrand("s1", for: ["01", "03", "gone"])
        XCTAssertEqual(s.manifest.chapters.map(\.strand), [nil, "s1", nil, "s1", nil], "several at once")
        XCTAssertEqual(try saved(s).chapters.map(\.strand), [nil, "s1", nil, "s1", nil])
        XCTAssertEqual(s.manifest.structure, m.structure, "the structure is not touched")
        var bare = s.manifest
        for i in bare.chapters.indices { bare.chapters[i].strand = nil }
        XCTAssertEqual(bare, m)
        XCTAssertFalse(s.pendingCommit, "committed like a part or a kind")
        XCTAssertEqual(s.git.show("HEAD", path: ".musset/book.json")?.components(separatedBy: "\"strand\"").count, 3, "in the book's history")

        s.setStrand("s2", for: ["01"])
        XCTAssertEqual(s.manifest.strand(of: s.manifest.chapters[1])?.id, "s2", "one strand at a time")
        s.setStrand(nil, for: ["01", "02"])
        XCTAssertEqual(s.manifest.chapters.map(\.strand), [nil, nil, nil, "s1", nil])
        XCTAssertEqual(try saved(s).chapters.map(\.strand), [nil, nil, nil, "s1", nil])
        // A strand the book does not have is no strand to follow.
        s.setStrand("nope", for: ["02"])
        XCTAssertNil(s.manifest.chapters[2].strand)
        XCTAssertEqual(s.manifest.strand("s2")?.shownName, L("Untitled"), "a strand not named yet can still be called")
        // A strand id left on a chapter by a book.json edited by hand reads as none.
        var odd = m
        odd.chapters[0].strand = "gone"
        XCTAssertNil(odd.strand(of: odd.chapters[0]))
    }

    // MARK: Groupings

    func testTheStrandsWithWhatFollowsThem() throws {
        var m = manifest()
        XCTAssertTrue(BookNumbers.threads(m, counts: [:]).isEmpty, "a book without strands has no such legend")
        m.structure = BookStructure(form: .novelInParts)
        m.structure?.strands = [.init(id: "s1", name: "1943", colour: "#8FA3FF"), .init(id: "s2", name: "Aujourd’hui", colour: "#8E4A7A"),
                                .init(id: "s3", name: "Nice", colour: "#E0C866")]
        var counts = [String: TextCounts]()
        for (id, n) in [("00", 10), ("01", 200), ("02", 300), ("03", 40), ("04", 5)] { var c = TextCounts(); c.words = n; c.characters = n * 5; counts[id] = c }
        // Strands and nothing following them: every chapter is without one.
        var threads = BookNumbers.threads(m, counts: counts)
        XCTAssertEqual(threads.map { $0.strand?.id }, [nil])
        XCTAssertEqual(threads[0].chapters.count, 5)

        for (i, strand) in [(1, "s2"), (2, "s1"), (4, "s2"), (3, "gone")] { m.chapters[i].strand = strand }
        threads = BookNumbers.threads(m, counts: counts)
        XCTAssertEqual(threads.map { $0.strand?.id }, ["s1", "s2", nil], "in the author's order, those no chapter follows left out, then the rest")
        XCTAssertEqual(threads.map(\.chapters), [["02"], ["01", "04"], ["00", "03"]], "in the book's order")
        XCTAssertEqual(threads.map(\.counts.words), [300, 205, 50])
        XCTAssertEqual(threads[1].counts[.characters], 1025, "in whichever unit is shown")
        XCTAssertEqual(threads.reduce(0) { $0 + $1.counts.words }, 555, "every chapter is counted once")

        let bars = BookNumbers.groups(m, counts: counts, scenes: [:]).flatMap(\.bars)
        XCTAssertEqual(bars.map(\.strand), [nil, "s2", "s1", nil, "s2"], "a strand the book no longer has is none")
        // The bar says its strand when it is drawn in it.
        XCTAssertTrue(BookBars.words(bars[1], m.words, strand: "Aujourd’hui").hasSuffix(" · Aujourd’hui"))
        XCTAssertFalse(BookBars.words(bars[1], m.words).contains("Aujourd"))
    }

    // MARK: One strand read alone

    private func stranded() throws -> BookSession {
        var m = manifest()
        m.structure = BookStructure(form: .novelInParts)
        m.structure?.strands = [.init(id: "s1", name: "1943", colour: "#8FA3FF"), .init(id: "s2", name: "Aujourd’hui", colour: "#8E4A7A")]
        for (i, strand) in [(0, "s1"), (1, "s1"), (2, "s2"), (4, "s2")] { m.chapters[i].strand = strand }
        return try book(m)
    }

    func testTheBoardReadAlongOneStrand() throws {
        let s = try stranded()
        let w = s.workspace
        let m = s.manifest
        XCTAssertNil(s.scenesStrand(in: w))
        XCTAssertEqual(m.scenesBands(strand: nil).map { $0.chapters.map(\.entry.id) }, [["00"], ["01", "02"], ["03", "04"]])

        s.readStrand("s1", in: w)
        XCTAssertEqual(s.scenesStrand(in: w)?.name, "1943")
        let bands = m.scenesBands(strand: "s1")
        XCTAssertEqual(bands.map { $0.part?.id }, [nil, "a"], "a part with no chapter on the strand has no band")
        XCTAssertEqual(bands.map { $0.chapters.map(\.entry.id) }, [["00"], ["01"]])
        XCTAssertEqual(bands[1].chapters[0].index, 1, "each keeps its place in the book: its number is the book's")
        // What the heading counts: « Fil : 1943 · 2 chapitres · 32 mots ».
        let shown = m.boardChapters(strand: "s1")
        XCTAssertEqual(shown.map(\.entry.id), ["00", "01"])
        XCTAssertEqual(m.words.count(shown.count, .piece), "2 chapitres")
        XCTAssertEqual(shown.reduce(0) { $0 + (s.chapterCounts[$1.entry.id]?.words ?? 0) }, 32)
        XCTAssertEqual(BookNumbers.threads(m, counts: s.chapterCounts).first?.counts.words, 32, "the legend's total is the heading's")
        XCTAssertEqual(m.boardChapters(part: "b", strand: "s2").map(\.entry.id), ["04"], "a part's lanes keep the strand's chapters")
        XCTAssertEqual(m.boardChapters().count, 5)
        XCTAssertEqual(s.scenesChapter(in: w), "00", "the board stands on a chapter it shows")

        // A part that holds none of the strand's chapters cannot be the board's; one that does can.
        w.zoomScenes(toPart: "b")
        XCTAssertNil(s.scenesPart(in: w))
        XCTAssertEqual(s.scenesPartToZoom(in: w), "a")
        w.zoomScenes(toPart: "a")
        XCTAssertEqual(s.scenesPart(in: w)?.id, "a")
        w.zoomScenes(toPart: nil)

        // Picked again in the legend, or « Tout le livre »: the whole book.
        s.readStrand("s1", in: w)
        XCTAssertNil(w.scenesStrand)
        s.readStrand("s2", in: w)
        s.readStrand(nil, in: w)
        XCTAssertNil(w.scenesStrand)
        s.readStrand("nope", in: w)
        XCTAssertNil(w.scenesStrand, "not a strand of the book")

        // A chapter chosen on the board stays chosen only while it is in sight.
        w.chooseScenesChapter("04")
        s.readStrand("s2", in: w)
        XCTAssertEqual(w.scenesChapter, "04")
        s.readStrand("s1", in: w)
        XCTAssertNil(w.scenesChapter)
        // A bar of another strand, a part without the strand, a chapter one zooms out of: asked for by name, they
        // bring the whole book back rather than a board that cannot show them.
        s.showOnBoard("01", in: w)
        XCTAssertEqual(w.scenesStrand, "s1", "one of the strand's leaves it be")
        s.showOnBoard("04", in: w)
        XCTAssertNil(w.scenesStrand)
        s.readStrand("s1", in: w)
        s.showPartOnBoard("b", in: w)
        XCTAssertNil(w.scenesStrand)
        XCTAssertEqual(s.scenesPart(in: w)?.id, "b")
        s.readStrand("s2", in: w)
        s.showPartOnBoard("b", in: w)
        XCTAssertEqual(w.scenesStrand, "s2")
        // In memory, per workspace: another window of the book reads what it likes.
        XCTAssertNil(Workspace().scenesStrand)
    }

    func testRemovingAStrandClearsWhatFollowedItAndTheFilter() throws {
        let s = try stranded()
        let w = s.workspace
        s.readStrand("s1", in: w)
        s.removeStrand("s1")
        XCTAssertEqual(s.manifest.strands.map(\.id), ["s2"])
        XCTAssertEqual(s.manifest.chapters.map(\.strand), [nil, nil, "s2", nil, "s2"], "the chapters stay, without a strand")
        XCTAssertEqual(try saved(s), s.manifest)
        XCTAssertNil(w.scenesStrand, "no board is left reading a strand that is gone")
        XCTAssertNil(s.scenesStrand(in: w))
        XCTAssertEqual(s.manifest.chapters.count, 5)

        // The last chapter taken off a strand read alone: nothing left to read, the book comes back.
        s.readStrand("s2", in: w)
        s.setStrand(nil, for: ["02"])
        XCTAssertEqual(w.scenesStrand, "s2")
        s.setStrand(nil, for: ["04"])
        XCTAssertNil(w.scenesStrand)
        // The last strand gone, the book has none: no legend, no switch, no column.
        s.removeStrand("s2")
        XCTAssertNil(s.manifest.structure?.strands)
        XCTAssertNotNil(s.manifest.structure, "the form stays")
        XCTAssertTrue(BookNumbers.threads(s.manifest, counts: s.chapterCounts).isEmpty)
        s.removeStrand("s2")
    }

    // MARK: Shots

    /// Twenty-four chapters in three parts, moving between two periods as an autofiction does; a few follow no strand.
    private func shotBook(_ name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("strands-\(UUID())/\(name)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let para = ["Nora descendit du bac la dernière, le manteau de son père plié sur le bras, et resta un moment sur la cale à regarder l’eau grise se refermer derrière le bateau.",
                    "— Tu aurais pu prévenir, dit Tom sans se retourner.",
                    "Elle ne répondit pas. Le vent portait l’odeur des bassins, cette odeur de vase et de fer qu’elle avait crue oubliée, et qui revenait d’un seul coup, entière.",
                    "Ils marchèrent jusqu’à la saline sans se parler. Les râteaux étaient restés contre le mur, là où leur mère les rangeait.",
                    "— Il est mort mardi, dit-elle enfin.",
                    "Le soir, la marée remonta jusqu’aux premières tables, et personne ne songea à fermer les vannes."]
        let titles = ["Avant la marée", "Le bac", "La cale", "Nice", "La saline, onze ans après les funérailles", "Entre deux eaux", "Mardi", "Les vannes",
                      "Le grenier", "Tom", "La maison du quai des Belges", "Peninsula", "Flower Island", "Le registre", "La lettre", "Les râteaux",
                      "Marseille", "Le train de nuit", "La photographie", "Le sel", "Octobre", "La digue", "Le retour", "Après"]
        var chapters: [ChapterEntry] = []
        for (n, title) in titles.enumerated() {
            let scenes = 1 + (n * 3) % 4
            var text = "# \(title)\n\n"
            for k in 0..<scenes {
                if scenes > 1 { text += "<!-- scene: \(["Le quai", "La nuit", "Le retour", "L’aube"][k]) -->\n\n" }
                text += (0...(n * 5 + k * 3) % 7).map { para[($0 + n + k) % para.count] }.joined(separator: "\n\n") + "\n\n"
            }
            let id = String(format: "%02d", n)
            try text.write(to: root.appendingPathComponent("\(id).md"), atomically: true, encoding: .utf8)
            // The past comes back every third chapter, then more often; the prologue and two others follow nothing.
            let strand: String? = [0, 9, 17].contains(n) ? nil : n % 3 == 1 || (n > 12 && n % 2 == 0) ? "s1" : "s2"
            chapters.append(ChapterEntry(id: id, file: "\(id).md", title: title, status: n < 9 ? .final : n < 14 ? .edited : n < 20 ? .done : .draft,
                                         part: n == 0 ? nil : n <= 8 ? "a" : n <= 16 ? "b" : "c", kind: n == 0 ? "prologue" : nil, strand: strand))
        }
        var m = BookManifest(title: name, author: "A.", lang: "fr", chapters: chapters)
        m.goal = 12_000
        m.parts = [BookPart(id: "a", title: ""), BookPart(id: "b", title: "La fuite"), BookPart(id: "c", title: "")]
        m.structure = BookStructure(form: .novelInParts)
        m.structure?.strands = [.init(id: "s1", name: "1943", colour: BookStructure.strandColours[0]),
                                .init(id: "s2", name: "Aujourd’hui", colour: BookStructure.strandColours[1])]
        try BookStore(root: root).saveManifest(m)
        let git = GitService(root: root)
        try git.initRepo()
        _ = try git.commit(paths: chapters.map(\.file) + [".musset"], message: "start")
        return root
    }

    /// The main window on a book with two strands, drawn offscreen: the sidebar's marks, the Overview by status and
    /// by strand, one strand read alone as cards, as a list and at a part, dark and light, and a narrow pane.
    /// MUSSET_LIVE_SHOTS=<dir> (skipped otherwise), as `BookOverviewTests.testOverviewShots`.
    func testStrandShots() async throws {
        guard let dir = ProcessInfo.processInfo.environment["MUSSET_LIVE_SHOTS"] else { throw XCTSkip("set MUSSET_LIVE_SHOTS") }
        let out = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let d = UserDefaults.standard
        let keys = [UILang.key, "libraryPaths", "lastBook", "sceneCardSize", BookOverviewPage.listKey, BookBars.byStrandKey, "sidebarFoldedParts", "sidebarBookFolded"]
        let saved = keys.map { d.object(forKey: $0) }
        let unit = CountSetting.shared.unit
        defer {
            for (k, v) in zip(keys, saved) { d.set(v, forKey: k) }
            CountSetting.shared.unit = unit
        }
        d.set("fr", forKey: UILang.key)
        for k in keys.dropFirst() { d.removeObject(forKey: k) }
        CountSetting.shared.unit = .words

        let retina = NSScreen.screens.max { $0.backingScaleFactor < $1.backingScaleFactor }
        func open(_ root: URL, width: CGFloat, height: CGFloat = 900) throws -> (AppState, BookSession, NSWindow) {
            let app = AppState()
            app.openBook(root)
            let s = try XCTUnwrap(app.current)
            s.open("04")
            let bridge = EditorBridge(), ann = Annotator(), proof = AutoProofreader()
            bridge.annotator = ann; bridge.proof = proof
            let view = ContentView(app: app, bridge: bridge, chat: ChatModel(), pangram: PangramModel(), proof: proof, annotator: ann)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.titled, .fullSizeContentView],
                                  backing: .buffered, defer: false, screen: retina)
            window.contentView = NSHostingView(rootView: view.frame(width: width, height: height))
            app.showInspector = false
            return (app, s, window)
        }
        func shot(_ window: NSWindow, _ name: String, dark: Bool, _ setup: () -> Void = {}) async throws {
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            setup()
            try await Task.sleep(for: .seconds(1.2))
            let v = window.contentView!
            let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds)!
            v.cacheDisplay(in: v.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name))
        }

        let (app, s, wide) = try open(try shotBook("Le sel"), width: 1440)
        let w = s.workspace
        // The chapter's text: the sidebar's marks, and a title bar that says nothing of strands.
        try await shot(wide, "strand-1-sidebar-dark.png", dark: true)
        try await shot(wide, "strand-1-sidebar-light.png", dark: false)
        // The Overview as it opens in a book with strands: by status, the switch beside the legend.
        try await shot(wide, "strand-2-by-status-light.png", dark: false) { app.open(OverviewTab.summary.tab) }
        try await shot(wide, "strand-3-by-strand-dark.png", dark: true) { d.set(true, forKey: BookBars.byStrandKey) }
        try await shot(wide, "strand-3-by-strand-light.png", dark: false)
        // One strand read alone: the other bars dimmed, the board's heading, the part that holds none of it gone.
        try await shot(wide, "strand-4-read-alone-cards-dark.png", dark: true) { s.readStrand("s1", in: w) }
        try await shot(wide, "strand-4-read-alone-cards-light.png", dark: false)
        try await shot(wide, "strand-4b-read-alone-board-light.png", dark: false) { w.jumpToScenes(ScenesJump(chapter: nil)) }
        try await shot(wide, "strand-5-read-alone-list-dark.png", dark: true) { d.set(true, forKey: BookOverviewPage.listKey) }
        try await shot(wide, "strand-5-read-alone-list-light.png", dark: false)
        // The whole book as a list: the strands' column.
        try await shot(wide, "strand-6-list-light.png", dark: false) { s.readStrand(nil, in: w) }
        // A part's lanes, read along the other strand.
        try await shot(wide, "strand-7-part-lanes-light.png", dark: false) {
            d.set(false, forKey: BookOverviewPage.listKey)
            s.readStrand("s2", in: w)
            s.showPartOnBoard("b", in: w)
        }
        // A pane of 700 points: the legend wraps, the list keeps the marks.
        let (appN, sN, narrow) = try open(try shotBook("Le sel"), width: 956)
        try await shot(narrow, "strand-8-pane-700-dark.png", dark: true) { appN.open(OverviewTab.summary.tab) }
        try await shot(narrow, "strand-8-pane-700-list-light.png", dark: false) { d.set(true, forKey: BookOverviewPage.listKey); sN.readStrand("s2", in: sN.workspace) }
        // A third strand made from a chapter's menu, and a book in characters: the legend's totals follow the unit.
        try await shot(narrow, "strand-9-three-strands-characters-light.png", dark: false) {
            d.set(false, forKey: BookOverviewPage.listKey)
            sN.readStrand(nil, in: sN.workspace)
            sN.newStrand(named: "Marseille, l’été", for: ["16", "17", "18"])
            CountSetting.shared.unit = .charactersWithSpaces
        }
    }
}
