import XCTest
import SwiftUI
@testable import Musset

/// A book chooses its form: what its levels are called and how they number. One place computes it
/// (`Shared/BookStructure.swift`); a book without a structure is the book Musset always made.
@MainActor
final class StructureTests: XCTestCase {
    private func encoded(_ m: BookManifest) throws -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = .book
        return String(decoding: try enc.encode(m), as: UTF8.self)
    }

    private func book(_ form: BookStructure.Form?, lang: String = "fr", pieces: [(id: String, part: String?, kind: String?)] = [("a", "p", nil), ("b", "p", nil), ("c", "q", nil)]) -> BookManifest {
        var m = BookManifest(title: "T", author: "A", lang: lang, chapters: pieces.map {
            ChapterEntry(id: $0.id, file: $0.id + ".md", title: $0.id.uppercased(), part: $0.part, kind: $0.kind)
        })
        m.parts = [BookPart(id: "p", title: ""), BookPart(id: "q", title: "La fuite")]
        if let form { m.structure = BookStructure(form: form) }
        return m
    }

    // MARK: Old books

    /// A manifest as Musset wrote it before a book could choose its form: read and written back, not a byte moves.
    func testAnOldManifestRoundTripsByteForByte() throws {
        let old = """
        {
          "author" : "Jeanne Martin",
          "chapters" : [
            {
              "activeVersion" : "main",
              "excludeFromExport" : false,
              "file" : "01_le_port.md",
              "id" : "01_le_port",
              "part" : "P1",
              "status" : "edited",
              "title" : "Le port"
            },
            {
              "activeVersion" : "Vague",
              "excludeFromExport" : true,
              "file" : "02_nice.md",
              "id" : "02_nice",
              "title" : "Nice"
            }
          ],
          "contact" : "",
          "exports" : [

          ],
          "formatVersion" : 1,
          "front" : {
            "dedication" : "À Louise"
          },
          "lang" : "fr",
          "parts" : [
            {
              "id" : "P1",
              "title" : ""
            }
          ],
          "sceneBreak" : "blank",
          "title" : "Le Sel"
        }
        """
        let m = try JSONDecoder().decode(BookManifest.self, from: Data(old.utf8))
        XCTAssertNil(m.structure)
        XCTAssertNil(m.chapters[0].kind)
        XCTAssertNil(m.chapters[0].strand)
        XCTAssertEqual(try encoded(m), old)
        XCTAssertEqual(try BookManifest.forReading(Data(old.utf8)), m, "the reader takes the same book")
    }

    /// The author's own book, when the checkout has it: only read, and written back in memory.
    func testTheAuthorsBookIsWrittenBackUnchanged() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("fixtures/conatus/.musset/book.json")
        guard let data = try? Data(contentsOf: url) else { throw XCTSkip("no fixtures/conatus") }
        let m = try JSONDecoder().decode(BookManifest.self, from: data)
        XCTAssertNil(m.structure)
        XCTAssertEqual(try encoded(m), String(decoding: data, as: UTF8.self))
    }

    func testABookWithoutStructureIsTheBookMussetAlwaysMade() {
        let m = book(nil)
        XCTAssertEqual(m.form, .novelInParts)
        XCTAssertEqual(m.pieceMarks, ["1", "2", "3"])
        XCTAssertEqual(m.chapterNumber(of: "b"), 2)
        XCTAssertEqual([m.numeral(of: "p"), m.numeral(of: "q")], ["I", "II"])
        XCTAssertEqual(m.label(of: m.parts![1]), "II. La fuite")
        XCTAssertEqual(m.partOpenings["a"]?.numeral, "I")
        XCTAssertEqual(m.partOpenings["c"]?.title, "La fuite")
        XCTAssertTrue(m.groupsOn)
        XCTAssertTrue(m.words.usual(.piece) && m.words.usual(.group) && m.words.usual(.scene), "said in the interface's own sentences")
        let t = m.textFeatures
        XCTAssertEqual([t.subheadings, t.bulletLists, t.numberedLists], [false, true, false], "today's text: bullets, no lists by number, no sub-headings")
        // A novel without parts reads as a novel, and shows its parts the day it has some.
        var plain = m
        plain.parts = nil
        XCTAssertEqual(plain.form, .novel)
        XCTAssertTrue(plain.groupsOn)
    }

    // MARK: The presets' words

    func testEachPresetNamesItsLevelsInFrenchAndEnglish() {
        let french: [BookStructure.Form: [String]] = [
            .novel: ["Chapitre", "Scène"], .novelInParts: ["Partie", "Chapitre", "Scène"], .collection: ["Section", "Texte"],
            .journal: ["Année", "Entrée"], .essay: ["Partie", "Chapitre", "Section"], .play: ["Acte", "Scène"], .fragments: ["Fragment"],
        ]
        let english: [BookStructure.Form: [String]] = [
            .novel: ["Chapter", "Scene"], .novelInParts: ["Part", "Chapter", "Scene"], .collection: ["Section", "Piece"],
            .journal: ["Year", "Entry"], .essay: ["Part", "Chapter", "Section"], .play: ["Act", "Scene"], .fragments: ["Fragment"],
        ]
        for (form, names) in french { XCTAssertEqual(form.diagram(lang: "fr-FR"), names, "\(form)") }
        for (form, names) in english { XCTAssertEqual(form.diagram(lang: "en-GB"), names, "\(form)") }
        XCTAssertEqual(book(.journal).level(.piece).plural, "Entrées")
        XCTAssertEqual(book(.journal, lang: "en-US").level(.piece).plural, "Entries")
        XCTAssertEqual(book(.play, lang: "de-CH").level(.group).name, "Akt")
        XCTAssertEqual(book(.collection, lang: "it").level(.piece).plural, "Testi")
        XCTAssertEqual(book(.essay, lang: "pt-BR").level(.scene).name, "Seção")
        XCTAssertEqual(book(.essay, lang: "pt-PT").level(.scene).name, "Secção")
        XCTAssertEqual(book(.journal, lang: "es-419").level(.group).plural, "Años")
        // The three unnumbered kinds, in the book's language.
        XCTAssertEqual(book(.novel).unnumberedKinds.map(book(.novel).kindName), ["Prologue", "Interlude", "Épilogue"])
        XCTAssertEqual(book(.novel, lang: "de").unnumberedKinds.map(book(.novel, lang: "de").kindName), ["Prolog", "Zwischenspiel", "Epilog"])
        // The essay recognises sub-headings and numbered lists; the others keep today's text.
        XCTAssertTrue(book(.essay).textFeatures.subheadings && book(.essay).textFeatures.numberedLists && book(.essay).textFeatures.bulletLists)
        XCTAssertFalse(book(.play).textFeatures.subheadings || book(.play).textFeatures.numberedLists)
    }

    func testTheAuthorsOwnWordsWinOverThePresets() {
        var m = book(.collection)
        m.structure?[.piece].name = "Nouvelle"
        XCTAssertEqual(m.level(.piece).name, "Nouvelle")
        XCTAssertEqual(m.level(.piece).plural, "Nouvelle", "no plural typed yet: the name stands in")
        m.structure?[.piece].plural = "Nouvelles"
        XCTAssertEqual(m.count(3, .piece), "3 nouvelles")
        XCTAssertNil(m.level(.piece).term, "a word Musset has never seen: nothing agrees with it")
        m.structure?[.piece].name = "  "
        m.structure?[.piece].plural = nil
        XCTAssertEqual(m.level(.piece).name, "Texte", "blank is the preset's word again")
    }

    // MARK: Numbers

    func testRomanArabicAndNone() {
        var m = book(.novelInParts)
        XCTAssertEqual(m.pieceMarks, ["1", "2", "3"])
        m.structure?[.piece].numbering = .roman
        XCTAssertEqual(m.pieceMarks, ["I", "II", "III"])
        XCTAssertEqual(m.heading(of: m.chapters[2]), "Chapitre III")
        m.structure?[.piece].numbering = BookStructure.Numbering.none
        XCTAssertEqual(m.pieceMarks, ["", "", ""])
        XCTAssertNil(m.pieceNumber(of: "b"))
        XCTAssertNil(m.heading(of: m.chapters[0]), "a piece without a number has only its title")
        m.structure?[.group].numbering = .arabic
        XCTAssertEqual(m.label(of: m.parts![1]), "2. La fuite")
        XCTAssertEqual(m.heading(of: m.parts![0]), "Partie 1")
        m.structure?[.group].numbering = BookStructure.Numbering.none
        XCTAssertEqual(m.label(of: m.parts![1]), "La fuite")
        XCTAssertEqual(m.label(of: m.parts![0]), "Partie", "no number, no title: the level's name")
        XCTAssertEqual(m.partOpenings["c"]?.numeral, "")
    }

    func testNumberingRestartsInEachGroup() {
        let play = book(.play, pieces: [("a", "p", nil), ("b", "p", nil), ("c", "q", nil), ("d", "q", nil)])
        XCTAssertEqual(play.pieceMarks, ["1", "2", "1", "2"])
        XCTAssertEqual(play.heading(of: play.parts![1]), "Acte II")
        XCTAssertEqual(play.heading(of: play.chapters[2]), "Scène 1")
        XCTAssertEqual(play.nextPieceMark(), "3", "the next scene of the last act")
        var through = play
        through.structure?[.piece].restarts = false
        XCTAssertEqual(through.pieceMarks, ["1", "2", "3", "4"])
        XCTAssertEqual(through.nextPieceMark(ahead: 1), "6")
        // Without groups there is nothing to start again in.
        var flat = play
        flat.structure?[.group].off = true
        XCTAssertEqual(flat.pieceMarks, ["1", "2", "3", "4"])
    }

    func testAnUnnumberedPieceTakesNoNumber() {
        let m = book(.novelInParts, pieces: [("pro", nil, "prologue"), ("a", "p", nil), ("b", "p", nil), ("int", "p", "Entracte"), ("c", "q", nil), ("epi", nil, "epilogue")])
        XCTAssertEqual(m.pieceMarks, ["", "1", "2", "", "3", ""], "those after it number as if it were not there")
        XCTAssertEqual(m.pieceNumbers, [nil, 1, 2, nil, 3, nil])
        XCTAssertEqual(m.heading(of: m.chapters[0]), "Prologue")
        XCTAssertEqual(m.heading(of: m.chapters[3]), "Entracte", "the author's own kind, as typed")
        XCTAssertEqual(m.heading(of: m.chapters[4]), "Chapitre 3")
        XCTAssertEqual(m.numberedTitle(of: m.chapters[4]), "3 C")
        XCTAssertEqual(m.numberedTitle(of: m.chapters[0]), "PRO")
        XCTAssertEqual(m.pieceReference(at: 0), "PRO", "referred to by its title, for want of a number")
        var untitled = m
        untitled.chapters[5].title = ""
        XCTAssertEqual(untitled.shownTitle(of: untitled.chapters[5]), "Épilogue")
        // In English the same book says Prologue, Epilogue.
        var en = m
        en.lang = "en-GB"
        XCTAssertEqual(en.heading(of: en.chapters[5]), "Epilogue")
        // A book that never chose a form numbers the same way.
        var old = m
        old.structure = nil
        XCTAssertEqual(old.pieceMarks, ["", "1", "2", "", "3", ""])
    }

    func testTheGroupLevelOffHidesThePartsAndKeepsThem() {
        var m = book(.novelInParts)
        m.structure?[.group].off = true
        XCTAssertFalse(m.groupsOn)
        XCTAssertEqual(m.shownParts, [])
        XCTAssertNil(m.group(of: m.chapters[0]))
        XCTAssertTrue(m.partOpenings.isEmpty)
        XCTAssertFalse(m.hasPartsInUse)
        XCTAssertEqual(m.scenesBands.count, 1, "one run, no part over it")
        XCTAssertEqual(m.parts?.count, 2, "the parts are still in the book")
        XCTAssertEqual(m.chapters.map(\.part), ["p", "p", "q"])
        m.structure?[.group].off = false
        XCTAssertEqual(m.shownParts.map(\.id), ["p", "q"], "back as they were")
        // The plain novel has no group level; a novel in parts does.
        XCTAssertFalse(book(.novel).groupsOn)
        XCTAssertFalse(book(.fragments).groupsOn)
        XCTAssertTrue(book(.journal).groupsOn)
    }

    // MARK: Counts and headings

    func testCountsTakeTheBooksPlural() {
        let journal = book(.journal)
        XCTAssertEqual(journal.count(1, .piece), "1 entrée")
        XCTAssertEqual(journal.count(0, .piece), "0 entrée", "French: none is singular")
        XCTAssertEqual(journal.count(12, .piece), "12 entrées")
        XCTAssertEqual(journal.count(2, .group), "2 années")
        XCTAssertEqual(book(.journal, lang: "en").count(0, .piece), "0 entries")
        XCTAssertEqual(book(.play, lang: "de").count(3, .group), "3 Akte", "German nouns keep their capital")
        XCTAssertEqual(book(.play, lang: "de").count(1, .group), "1 Akt")
    }

    func testTheInterfaceSaysTheBooksWords() {
        let saved = UserDefaults.standard.string(forKey: UILang.key)
        defer { UserDefaults.standard.set(saved, forKey: UILang.key) }
        UserDefaults.standard.set(UILang.fr.rawValue, forKey: UILang.key)
        // The usual words: the interface's own sentences, as before.
        let novel = book(.novelInParts).words
        XCTAssertEqual(novel.newPiece, "Nouveau chapitre")
        XCTAssertEqual(novel.count(3, .piece), "3 chapitres")
        XCTAssertEqual(novel.groupName(BookPart(id: "p")), "Partie I")
        XCTAssertEqual(novel.scene(3), "Scène 3")
        // The book's own.
        let journal = book(.journal).words
        XCTAssertEqual(journal.newPiece, "Nouvelle entrée", "the interface speaks the book's language: it agrees")
        XCTAssertEqual(journal.count(2, .piece), "2 entrées")
        XCTAssertEqual(journal.name(.group), "Année")
        XCTAssertEqual(journal.bookPieceByPiece, "Le livre, entrée par entrée")
        let play = book(.play).words
        XCTAssertEqual(play.groupName(BookPart(id: "q")), "Acte II")
        XCTAssertEqual(play.groupName(BookPart(id: "q", title: "La fuite")), "II. La fuite")
        XCTAssertEqual(play.newPiece, "Nouvelle scène")
        XCTAssertEqual(play.scene(2), "Moment 2")
        XCTAssertEqual(play.hideScenes, "Masquer les moments")
        // A word the author typed: nothing agrees with it.
        var own = book(.collection)
        own.structure?[.piece].name = "Lettre"
        XCTAssertEqual(own.words.newPiece.replacingOccurrences(of: "\u{00A0}", with: " "), "Nouveau : lettre")
        // An English interface over a French book: the book's word, no agreement.
        UserDefaults.standard.set(UILang.en.rawValue, forKey: UILang.key)
        XCTAssertEqual(book(.journal).words.newPiece, "New Entrée")
        XCTAssertEqual(book(.novel).words.newPiece, "New Chapter")
    }

    func testNewPiecesAndScenesAreTitledInTheBooksWords() {
        XCTAssertEqual(book(nil).newPieceTitle(8), "Chapitre 8")
        XCTAssertEqual(book(.journal).newPieceTitle(2), "Entrée 2")
        XCTAssertEqual(book(.essay).sceneTitle(3), "Section 3")
        XCTAssertEqual(book(.novel, lang: "en").sceneTitle(3), "Scene 3")
        let text = "# Un\n\nIl pleuvait.\n"
        guard case let .scene(_, marker)? = Breaks.onReturn(text, caret: (text as NSString).length, lang: "fr", scene: book(.essay).level(.scene).name) else { return XCTFail() }
        XCTAssertEqual(marker, Scenes.markerLine("Section 2"))
    }

    // MARK: Changing the form

    func testChangingTheFormKeepsThePiecesThePartsAndTheFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("musset-structure-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for id in ["a", "b", "c"] { try "# \(id.uppercased())\n\nLe texte de \(id).\n".write(to: root.appendingPathComponent("\(id).md"), atomically: true, encoding: .utf8) }
        var m = book(nil)
        m.chapters[0].kind = "prologue"
        try BookStore(root: root).saveManifest(m)
        let git = GitService(root: root)
        try git.initRepo()
        _ = try git.commit(paths: ["a.md", "b.md", "c.md", ".musset"], message: "start")
        let s = BookSession(root: root, manifest: m)
        let files = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasSuffix(".md") }.sorted()
        let texts = try files.map { try String(contentsOf: root.appendingPathComponent($0), encoding: .utf8) }

        for form in BookStructure.Form.allCases {
            s.setStructure { $0.setForm(form) }
            XCTAssertEqual(s.manifest.structure?.form, form)
            XCTAssertEqual(s.manifest.chapters.map(\.id), ["a", "b", "c"], "\(form)")
            XCTAssertEqual(s.manifest.chapters.map(\.part), ["p", "p", "q"], "\(form)")
            XCTAssertEqual(s.manifest.chapters[0].kind, "prologue", "\(form)")
            XCTAssertEqual(s.manifest.parts?.map(\.id), ["p", "q"], "\(form): the parts stay, shown or not")
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasSuffix(".md") }.sorted(), files)
            XCTAssertEqual(try files.map { try String(contentsOf: root.appendingPathComponent($0), encoding: .utf8) }, texts)
            XCTAssertEqual(try BookStore(root: root).loadManifest().structure?.form, form, "saved with the book")
        }
        // A form is its preset: what was set on the last one goes; the kinds and the strands stay.
        s.setStructure { $0.setForm(.play); $0.structure?[.piece].name = "Tableau"; $0.structure?.strands = [.init(id: "s", name: "1943", colour: "#8FA3FF")]; $0.structure?.unnumbered = ["prologue", "Entracte"] }
        XCTAssertEqual(s.manifest.level(.piece).name, "Tableau")
        s.setStructure { $0.setForm(.collection) }
        XCTAssertEqual(s.manifest.level(.piece).name, "Texte")
        XCTAssertEqual(s.manifest.structure?.strands?.map(\.name), ["1943"])
        XCTAssertEqual(s.manifest.unnumberedKinds, ["prologue", "Entracte"])
        // Custom starts from the book as it stands: its words are now the author's.
        s.setStructure { $0.setForm(.custom) }
        XCTAssertEqual(s.manifest.structure?.piece?.name, "Texte")
        XCTAssertEqual(s.manifest.level(.group).name, "Section")
        XCTAssertEqual(s.manifest.level(.piece).numbering, BookStructure.Numbering.none)

        // A piece's kind: its number goes, nothing else.
        s.setStructure { $0.setForm(.novelInParts) }
        s.setKind("b", "interlude")
        XCTAssertEqual(s.manifest.pieceMarks, ["", "", "1"])
        s.setKind("a", nil)
        XCTAssertEqual(s.manifest.pieceMarks, ["1", "", "2"])
        XCTAssertEqual(try BookStore(root: root).loadManifest().chapters.map(\.kind), [nil, "interlude", nil])
    }

    /// The structure as a book carries it: only what the author changed from the form.
    func testTheStructureInTheManifest() throws {
        var m = BookManifest(title: "T", author: "A", lang: "fr", chapters: [ChapterEntry(id: "a", file: "a.md", title: "A", kind: "prologue", strand: "s1")])
        m.structure = BookStructure(form: .collection)
        XCTAssertTrue(try encoded(m).contains("\"structure\" : {\n    \"form\" : \"collection\"\n  }"))
        m.structure?[.piece] = .init(name: "Nouvelle", plural: "Nouvelles", numbering: .arabic)
        m.structure?[.group].off = true
        m.structure?.unnumbered = ["prologue", "Entracte"]
        m.structure?.strands = [.init(id: "s1", name: "1943", colour: "#8FA3FF")]
        m.structure?.text = .init(numberedLists: true)
        let again = try JSONDecoder().decode(BookManifest.self, from: Data(try encoded(m).utf8))
        XCTAssertEqual(again, m)
        XCTAssertEqual(again.chapters[0].strand, "s1")
        XCTAssertEqual(again.pieces(in: "s1"), 1)
        XCTAssertTrue(again.textFeatures.numberedLists && again.textFeatures.bulletLists && !again.textFeatures.subheadings)
        // A form from a newer Musset: the reader reads the book as a plain one; the Mac app, which would save over it, refuses.
        let newer = #"{"title":"T","chapters":[],"structure":{"form":"atlas"}}"#
        XCTAssertNil(try BookManifest.forReading(Data(newer.utf8)).structure)
        XCTAssertThrowsError(try JSONDecoder().decode(BookManifest.self, from: Data(newer.utf8)))
    }

    // MARK: Snapshots

    /// The Structure page, the new book's form step, and the main window on a collection and on a play, drawn
    /// offscreen. MUSSET_LIVE_SHOTS=<dir> (skipped otherwise), as `BookOverviewTests.testOverviewShots`.
    func testStructureShots() async throws {
        guard let dir = ProcessInfo.processInfo.environment["MUSSET_LIVE_SHOTS"] else { throw XCTSkip("set MUSSET_LIVE_SHOTS") }
        let out = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let d = UserDefaults.standard
        let keys = [UILang.key, "libraryPaths", "lastBook", "sceneCardSize", BookOverviewPage.listKey]
        let saved = keys.map { d.object(forKey: $0) }
        defer { for (k, v) in zip(keys, saved) { d.set(v, forKey: k) } }
        d.set("fr", forKey: UILang.key)
        for k in keys.dropFirst() { d.removeObject(forKey: k) }

        let retina = NSScreen.screens.max { $0.backingScaleFactor < $1.backingScaleFactor }
        func window<V: View>(_ view: V, width: CGFloat, height: CGFloat) -> NSWindow {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.titled, .fullSizeContentView],
                             backing: .buffered, defer: false, screen: retina)
            w.contentView = NSHostingView(rootView: view.frame(width: width, height: height).background(Color(nsColor: .windowBackgroundColor)))
            return w
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
        func open(_ root: URL) throws -> (AppState, BookSession, NSWindow) {
            let app = AppState()
            app.openBook(root)
            let s = try XCTUnwrap(app.current)
            let bridge = EditorBridge(), ann = Annotator(), proof = AutoProofreader()
            bridge.annotator = ann; bridge.proof = proof
            let view = ContentView(app: app, bridge: bridge, chat: ChatModel(), pangram: PangramModel(), proof: proof, annotator: ann)
            app.showInspector = false
            return (app, s, window(view, width: 1440, height: 900))
        }

        // Book Settings › Structure: a novel in parts with two strands, then a play, then a book that never chose.
        let novel = try shotBook("Le sel", form: .novelInParts)
        let (appN, sN, _) = try open(novel)
        sN.setStructure { m in
            m.structure?.strands = [.init(id: "s1", name: "1943", colour: "#8FA3FF"), .init(id: "s2", name: "Aujourd’hui", colour: "#E8B27A")]
            for i in m.chapters.indices where m.chapters[i].kind == nil { m.chapters[i].strand = i % 3 == 0 ? "s2" : "s1" }
        }
        let settings = window(BookSettingsView(app: appN, session: sN, startSection: .structure), width: 1260, height: 760)
        try await shot(settings, "structure-1-settings-dark.png", dark: true)
        try await shot(settings, "structure-1-settings-light.png", dark: false)
        let (appP, sP, playWindow) = try open(try shotBook("La Cerisaie, encore", form: .play))
        let playSettings = window(BookSettingsView(app: appP, session: sP, startSection: .structure), width: 1260, height: 760)
        try await shot(playSettings, "structure-2-settings-play-dark.png", dark: true)
        try await shot(playSettings, "structure-3-settings-group-off-light.png", dark: false) { sP.setStructure { $0.structure?[.group].off = true } }
        sP.setStructure { $0.structure?[.group].off = nil }

        // A new book's form step: as it opens (Roman), and on the mock's choice.
        let chooser = window(FormChooser(form: .constant(.novel), lang: "fr-FR", title: "Le sel", back: {}, create: {}), width: 1200, height: 820)
        try await shot(chooser, "structure-4-new-book-dark.png", dark: true)
        let chooser2 = window(FormChooser(form: .constant(.novelInParts), lang: "fr-FR", title: "Le sel", back: {}, create: {}), width: 1200, height: 820)
        try await shot(chooser2, "structure-4-new-book-parts-dark.png", dark: true)
        let chooser3 = window(FormChooser(form: .constant(.play), lang: "fr-FR", title: "Le sel", back: {}, create: {}), width: 1200, height: 820)
        try await shot(chooser3, "structure-4-new-book-play-light.png", dark: false)

        // The main window: a collection, then a play; sidebar and Overview.
        let (appC, sC, collection) = try open(try shotBook("Les eaux basses", form: .collection))
        try await shot(collection, "structure-5-recueil-dark.png", dark: true) { appC.open(OverviewTab.summary.tab) }
        try await shot(collection, "structure-5-recueil-light.png", dark: false)
        try await shot(collection, "structure-5-recueil-text-light.png", dark: false) { appC.showChapter(); sC.open("03") }
        try await shot(playWindow, "structure-6-theatre-dark.png", dark: true) { appP.open(OverviewTab.summary.tab) }
        try await shot(playWindow, "structure-6-theatre-light.png", dark: false)
        try await shot(playWindow, "structure-6-theatre-part-light.png", dark: false) { sP.showPartOnBoard("b", in: sP.workspace) }
    }

    /// Nine pieces in two groups, a prologue before them and an interlude between, in the given form.
    private func shotBook(_ name: String, form: BookStructure.Form) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("structure-\(UUID())/\(name)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let para = ["Nora descendit du bac la dernière, le manteau de son père plié sur le bras, et resta un moment sur la cale à regarder l’eau grise se refermer derrière le bateau.",
                    "— Tu aurais pu prévenir, dit Tom sans se retourner.",
                    "Elle ne répondit pas. Le vent portait l’odeur des bassins, cette odeur de vase et de fer qu’elle avait crue oubliée.",
                    "Ils marchèrent jusqu’à la saline sans se parler. Les râteaux étaient restés contre le mur."]
        let titles = ["Avant la marée", "Le bac", "La cale", "Nice", "La saline", "Entre deux eaux", "Mardi", "Les vannes", "Le grenier", "Tom", "Après"]
        let kinds: [Int: String] = [0: "prologue", 5: "interlude", 10: "epilogue"]
        var chapters: [ChapterEntry] = []
        for (n, title) in titles.enumerated() {
            let scenes = 1 + (n * 3) % 4
            var text = "# \(title)\n\n"
            for k in 0..<scenes {
                if scenes > 1 { text += "<!-- scene: \(["Le quai", "La nuit", "Le retour", "L’aube"][k]) -->\n\n" }
                text += (0...(n + k) % 4).map { para[($0 + n + k) % para.count] }.joined(separator: "\n\n") + "\n\n"
            }
            let id = String(format: "%02d", n)
            try text.write(to: root.appendingPathComponent("\(id).md"), atomically: true, encoding: .utf8)
            chapters.append(ChapterEntry(id: id, file: "\(id).md", title: title, status: n < 4 ? .final : n < 7 ? .edited : .draft,
                                         part: n == 0 || n == 10 ? nil : n <= 5 ? "a" : "b", kind: kinds[n]))
        }
        var m = BookManifest(title: name, author: "A.", lang: "fr", chapters: chapters)
        m.parts = [BookPart(id: "a", title: form == .collection ? "Le port" : ""), BookPart(id: "b", title: form == .collection ? "La ville" : "La fuite")]
        m.structure = BookStructure(form: form)
        try BookStore(root: root).saveManifest(m)
        let git = GitService(root: root)
        try git.initRepo()
        _ = try git.commit(paths: chapters.map(\.file) + [".musset"], message: "start")
        return root
    }
}
