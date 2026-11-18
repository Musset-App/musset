import MussetPage
import PDFKit
import XCTest
@testable import Musset

/// Books that chose a form, for the outputs: a play, a collection, a novel with a prologue, fragments.
enum FormSamples {
    static let para = ExportSamples.para

    private static func front() -> FrontMatter { FrontMatter(titlePage: true, contents: true) }

    /// Two acts, the scenes numbered again in each; the second act has a title.
    static func play(_ root: URL) throws -> BookManifest {
        var m = BookManifest(title: "Le Bal", author: "Jeanne Martin", lang: "fr-FR", chapters: [
            ChapterEntry(id: "s1", file: "s1.md", title: "Le salon", part: "A1"),
            ChapterEntry(id: "s2", file: "s2.md", title: "L’aveu", part: "A1"),
            ChapterEntry(id: "s3", file: "s3.md", title: "La rue", part: "A2"),
            ChapterEntry(id: "s4", file: "s4.md", title: "Scène 9", part: "A2")])
        m.parts = [BookPart(id: "A1", title: ""), BookPart(id: "A2", title: "La fuite")]
        m.structure = BookStructure(form: .play)
        m.front = front()
        let long = String(repeating: para, count: 5)
        try ExportSamples.write(root, m, [
            "s1": "# Le salon\n\nElle entre. \(long)\n", "s2": "# L’aveu\n\nIl avoue. \(long)\n",
            "s3": "# La rue\n\nNuit noire. \(long)\n",
            // No heading, and a title that only says a place it no longer has: the scene opens under its line alone.
            "s4": "Le rideau tombe. \(long)\n"])
        return m
    }

    /// Titled texts without numbers; the parts stay in the manifest, the level is off.
    static func collection(_ root: URL) throws -> BookManifest {
        var m = BookManifest(title: "Petites proses", author: "Jeanne Martin", lang: "fr-FR", chapters: [
            ChapterEntry(id: "t1", file: "t1.md", title: "La mer", part: "S1"),
            ChapterEntry(id: "t2", file: "t2.md", title: "Le vent", part: "S1"),
            ChapterEntry(id: "t3", file: "t3.md", title: "La pluie", part: "S2")])
        m.parts = [BookPart(id: "S1", title: "Dehors"), BookPart(id: "S2", title: "Dedans")]
        m.structure = BookStructure(form: .collection)
        m.structure?[.group] = BookStructure.Level(off: true)
        m.front = front()
        let long = String(repeating: para, count: 3)
        try ExportSamples.write(root, m, ["t1": "# La mer\n\nElle monte. \(long)\n", "t2": "# Le vent\n\nIl tourne. \(long)\n", "t3": "# La pluie\n\nElle tombe. \(long)\n"])
        return m
    }

    /// A prologue that is its own title, an interlude with a title, an epilogue without a heading; the chapters
    /// number as if they were not there.
    static func novel(_ root: URL) throws -> BookManifest {
        var m = BookManifest(title: "Le Sel", author: "Jeanne Martin", lang: "fr-FR", chapters: [
            ChapterEntry(id: "pro", file: "pro.md", title: "Prologue", kind: "prologue"),
            ChapterEntry(id: "c1", file: "c1.md", title: "Le port", part: "P1"),
            ChapterEntry(id: "c2", file: "c2.md", title: "La malle", part: "P1"),
            ChapterEntry(id: "int", file: "int.md", title: "Le rêve", part: "P1", kind: "interlude"),
            ChapterEntry(id: "c3", file: "c3.md", title: "Nice", part: "P2"),
            ChapterEntry(id: "epi", file: "epi.md", title: "", kind: "epilogue")])
        m.parts = [BookPart(id: "P1", title: ""), BookPart(id: "P2", title: "La fuite")]
        m.structure = BookStructure(form: .novelInParts)
        m.front = front()
        let long = String(repeating: para, count: 5)
        try ExportSamples.write(root, m, [
            "pro": "# Prologue\n\nAvant tout. \(long)\n", "c1": "# Le port\n\nPremier. \(long)\n", "c2": "# La malle\n\nDeuxième. \(long)\n",
            "int": "# Le rêve\n\nElle rêve. \(long)\n", "c3": "# Nice\n\nTroisième. \(long)\n", "epi": "Après tout. \(long)\n"])
        return m
    }

    /// Numbered fragments that follow each other in the page; one has a title.
    static func fragments(_ root: URL) throws -> BookManifest {
        var m = BookManifest(title: "Éclats", author: "Jeanne Martin", lang: "fr-FR", chapters: (1...8).map {
            ChapterEntry(id: "f\($0)", file: "f\($0).md", title: $0 == 3 ? "La mer" : "Fragment \($0)")
        })
        m.structure = BookStructure(form: .fragments)
        m.front = front()
        var texts: [String: String] = [:]
        for i in 1...8 { texts["f\(i)"] = (i == 3 ? "# La mer\n\n" : "") + "Éclat numéro \(i). " + String(repeating: para, count: i % 3 + 1) + "\n" }
        try ExportSamples.write(root, m, texts)
        return m
    }

    /// The book Musset always made: no structure, no kinds.
    static func plain(_ root: URL) throws -> BookManifest {
        var m = BookManifest(title: "Le Sel", author: "Jeanne Martin", lang: "fr", chapters: [
            ChapterEntry(id: "a", file: "a.md", title: "A", part: "P1"), ChapterEntry(id: "b", file: "b.md", title: "B")])
        m.parts = [BookPart(id: "P1", title: "")]
        m.front = FrontMatter(contents: true)
        try ExportSamples.write(root, m, ["a": "# A\n\nTexte.\n", "b": "# B\n\nSuite.\n"])
        return m
    }
}

/// Every output follows the book's form (`Shared/BookStructure.swift`), and a book without one comes out as it always did.
final class StructureOutputTests: XCTestCase {
    private func tmp(_ name: String) -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("musset-form-\(UUID().uuidString.prefix(6))-\(name)")
        addTeardownBlock { try? FileManager.default.removeItem(at: u) }
        return u
    }

    private func preset(_ id: String, _ m: BookManifest, _ root: URL) throws -> ExportPreset {
        try XCTUnwrap(BookStore(root: root).presets(m).first { $0.id == id || (id == "manuscript" && $0.manuscript != nil) })
    }

    private func typst(_ m: BookManifest, _ root: URL, _ id: String = "reader") throws -> String {
        try TypesetBook(Typesetting.source(manifest: m, store: BookStore(root: root), preset: preset(id, m, root))).typstSource
    }

    /// The PDF's pages as text; kept in `MUSSET_STRUCTURE_PDF` when the run names a folder (TEST_RUNNER_MUSSET_STRUCTURE_PDF).
    private func pdf(_ m: BookManifest, _ root: URL, _ id: String, keep: String) async throws -> [String] {
        let out = try await ExportService.export(manifest: m, store: BookStore(root: root), preset: preset(id, m, root))
        if let dir = ProcessInfo.processInfo.environment["MUSSET_STRUCTURE_PDF"], !dir.isEmpty {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let to = URL(fileURLWithPath: dir).appendingPathComponent(keep + ".pdf")
            try? FileManager.default.removeItem(at: to)
            try FileManager.default.copyItem(at: out.file, to: to)
        }
        let doc = try XCTUnwrap(PDFDocument(url: out.file))
        return (0..<doc.pageCount).map { doc.page(at: $0)?.string ?? "" }
    }

    private func unzip(_ file: URL) async throws -> URL {
        let dir = tmp("x")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let r = try await Shell.runAsync("/usr/bin/unzip", ["-q", file.path, "-d", dir.path])
        XCTAssertTrue(r.ok, r.stderr)
        return dir
    }

    /// The paragraphs of a Word file, each with its style: « Heading1|Le salon ».
    private func paragraphs(_ xml: String) -> [String] {
        xml.components(separatedBy: "<w:p>").dropFirst().map { p in
            let style = p.range(of: #"<w:pStyle w:val="([^"]+)""#, options: .regularExpression).map { String(p[$0]).components(separatedBy: "\"")[1] } ?? ""
            let text = p.components(separatedBy: "<w:t").dropFirst().map { t in String(t[(t.range(of: ">")?.upperBound ?? t.startIndex)...].prefix { $0 != "<" }) }.joined()
            return style + "|" + text
        }
    }

    // MARK: A book without a form

    /// Not a byte moves: the Typst source, the Word and pandoc sources, the Word styles.
    func testABookWithoutAFormComesOutAsItAlwaysDid() throws {
        let root = tmp("plain")
        let m = try FormSamples.plain(root)
        let store = BookStore(root: root)
        XCTAssertFalse(m.hasForm)
        let source = try Typesetting.source(manifest: m, store: store, preset: preset("reader", m, root))
        XCTAssertNil(source.form)
        XCTAssertEqual(source.chapters.map(\.opening), [nil, nil])
        XCTAssertEqual(source.chapters.map(\.part), [BookSource.Part(numeral: "I", title: ""), nil])
        XCTAssertEqual(try TypesetBook(source).typstSource, """
        #import "musset.typ": *
        #show: book.with(title: "Le Sel", author: "Jeanne Martin", contact: none, lang: "fr", region: "FR", crop: false, paper: (120mm, 188mm), margins: (bottom: 20mm, inside: 17mm, outside: 17mm, top: 16mm), size: 10.8pt, title-page-on: false, facing: false)

        #page(header: none, footer: none)[#nofolio()#v(30%)#align(center)[#text(size: 1.25em, smallcaps[Le Sel])
        #v(18mm)Jeanne Martin]]

        #page(header: none, footer: none)[#nofolio()#align(center)[#text(size: 1.3em)[Table]]#v(2em)#outline(title: none, depth: 1)]

        #part-page("I", "")

        = A

        Texte.


        = B

        Suite.



        """)
        XCTAssertEqual(WordManuscript.source(m, store: store).text,
                       "::: {custom-style=\"PartNumber\"}\nI\n:::\n\n::: {#mch_0}\n\n# A\n\nTexte.\n\n\n:::\n\n::: {#mch_1}\n\n# B\n\nSuite.\n\n\n:::\n\n")
        XCTAssertEqual(store.concatenatedManuscript(m, stripComments: true), "# I {.unnumbered .part}\n\n# A\n\nTexte.\n\n# B\n\nSuite.\n\n")
        let styles = WordManuscript.styles("<w:styles></w:styles>", lang: "fr")
        XCTAssertFalse(styles.contains(WordManuscript.pieceLineStyle) || styles.contains(WordManuscript.pieceTitleStyle), "no style of a formed book's")
        XCTAssertTrue(styles.contains(#"w:styleId="Heading1"><w:name w:val="heading 1"/><w:basedOn w:val="Normal"/><w:next w:val="FirstParagraph"/><w:qFormat/><w:pPr><w:keepNext/><w:keepLines/><w:pageBreakBefore/>"#))
        // The fixtures of the PDF export, the books Musset always made: nothing of a formed book's in their source.
        for (name, make) in [("fr", { try ExportSamples.frenchNovel($0) }), ("en", ExportSamples.englishManuscript), ("de", ExportSamples.germanManuscript)] as [(String, (URL) throws -> BookManifest)] {
            let root = tmp(name)
            let m = try make(root)
            for p in BookStore(root: root).presets(m) where p.format == .pdf {
                let typst = try TypesetBook(Typesetting.source(manifest: m, store: BookStore(root: root), preset: p)).typstSource
                for call in ["piece-label", "piece-opens", "group-opens", "group-mark", "part-heading", "book-contents"] {
                    XCTAssertFalse(typst.contains(call), "\(name) \(p.id): \(call)")
                }
            }
        }
    }

    // MARK: The typesetter

    func testAPlayIsSetByItsActsAndScenes() async throws {
        let root = tmp("play")
        let m = try FormSamples.play(root)
        let source = try typst(m, root)
        XCTAssertTrue(source.contains("#group-mark(\"Acte I\", \"\")\n#part-page(\"Acte I\", \"\")\n\n#piece-label.update(\"Scène 1\")\n= Le salon"), source)
        XCTAssertTrue(source.contains("#piece-label.update(\"Scène 2\")\n= L’aveu"), source)
        XCTAssertTrue(source.contains("#part-page(\"Acte II\", \"La fuite\")\n\n#piece-label.update(\"Scène 1\")\n= La rue"), "the scenes number again in each act: \(source)")
        XCTAssertTrue(source.contains("#piece-label.update(none)\n= Scène 2\n\nLe rideau tombe."), "no title: the scene's line is its heading: \(source)")
        XCTAssertTrue(source.contains("#book-contents()") && !source.contains("#outline("))
        XCTAssertFalse(source.contains("-opens.update"), "an act on a right-hand page, a scene on the next: the template's own")

        let pages = try await pdf(m, root, "print", keep: "play-print")
        let contents = try XCTUnwrap(pages.first { $0.contains("Table") })
        for line in ["Acte I", "Scène 1 · Le salon", "Scène 2 · L’aveu", "Acte II · La fuite", "Scène 1 · La rue", "Scène 2"] { XCTAssertTrue(contents.contains(line), "\(line) in \(contents)") }
        let act2 = try XCTUnwrap(pages.firstIndex { $0.contains("Acte II") && $0.contains("La fuite") && !$0.contains("Table") })
        XCTAssertEqual(act2 % 2, 0, "an act opens on a right-hand page (page \(act2 + 1))")
        XCTAssertFalse(pages[act2].contains("Nuit noire"), "on a page of its own")
        let scene = try XCTUnwrap(pages.firstIndex { $0.contains("Nuit noire") })
        XCTAssertTrue(pages[scene].hasPrefix("Scène 1\nLa rue") || pages[scene].replacingOccurrences(of: "\n", with: " ").hasPrefix("Scène 1 La rue"), pages[scene])
    }

    func testACollectionHasNoPartsAndNoNumbers() async throws {
        let root = tmp("collection")
        let m = try FormSamples.collection(root)
        let source = try typst(m, root)
        XCTAssertFalse(source.contains("#part-page") || source.contains("#group-mark"), "the group level is off: \(source)")
        XCTAssertEqual(source.components(separatedBy: "#piece-label.update(none)\n= ").count - 1, 3, "a title and nothing over it: \(source)")
        let pages = try await pdf(m, root, "reader", keep: "collection-reader")
        XCTAssertFalse(pages.joined().contains("Dehors") || pages.joined().contains("Section"), "the parts stay in the manifest, unseen")
        XCTAssertTrue(try XCTUnwrap(pages.first { $0.contains("Elle monte") }).hasPrefix("La mer"))
    }

    func testAPrologueAndAnInterludeTakeNoNumber() async throws {
        let root = tmp("novel")
        let m = try FormSamples.novel(root)
        let source = try typst(m, root)
        XCTAssertTrue(source.contains("#piece-label.update(none)\n= Prologue\n"), "« Prologue » is not said twice: \(source)")
        XCTAssertTrue(source.contains("#part-page(\"Partie I\", \"\")\n\n#piece-label.update(\"Chapitre 1\")\n= Le port"), source)
        XCTAssertTrue(source.contains("#piece-label.update(\"Interlude\")\n= Le rêve"), source)
        XCTAssertTrue(source.contains("#part-page(\"Partie II\", \"La fuite\")\n\n#piece-label.update(\"Chapitre 3\")\n= Nice"), "the interlude took no number: \(source)")
        XCTAssertTrue(source.contains("#piece-label.update(none)\n= Épilogue\n\nAprès tout."), "a text without a heading opens under its kind: \(source)")

        let pages = try await pdf(m, root, "print", keep: "novel-print")
        let contents = try XCTUnwrap(pages.first { $0.contains("Table") })
        for line in ["Prologue", "Partie I", "Chapitre 1 · Le port", "Chapitre 2 · La malle", "Interlude · Le rêve", "Partie II · La fuite", "Chapitre 3 · Nice", "Épilogue"] {
            XCTAssertTrue(contents.contains(line), "\(line) in \(contents)")
        }
        XCTAssertFalse(contents.contains("Prologue · Prologue"))
        XCTAssertTrue(try XCTUnwrap(pages.first { $0.contains("Troisième.") }).replacingOccurrences(of: "\n", with: " ").hasPrefix("Chapitre 3 Nice"))
        XCTAssertEqual(try XCTUnwrap(pages.firstIndex { $0.contains("Avant tout.") }) % 2, 0, "the text opens on a right-hand page")

        // The country's manuscript keeps its rule (the heading at its place, a line then the title) in the book's words.
        let manuscript = try typst(m, root, "manuscript")
        XCTAssertTrue(manuscript.hasPrefix("#import \"musset.typ\": *\n#show: manuscript.with("))
        XCTAssertTrue(manuscript.contains("#piece-label.update(\"Chapitre 3\")\n= Nice"))
        let sheets = try await pdf(m, root, "manuscript", keep: "novel-manuscript")
        XCTAssertTrue(try XCTUnwrap(sheets.first { $0.contains("Troisième.") }).contains("Chapitre 3\nNice"), "the level's word and number, then the title")
        XCTAssertTrue(try XCTUnwrap(sheets.first { $0.contains("Elle rêve.") }).contains("Interlude\nLe rêve"))
    }

    func testFragmentsFollowEachOtherInThePage() async throws {
        let root = tmp("fragments")
        let m = try FormSamples.fragments(root)
        let source = try typst(m, root)
        XCTAssertTrue(source.contains("#piece-opens.update(\"inPage\")\n#piece-label.update(none)\n= Fragment 1\n\nÉclat numéro 1."), source)
        XCTAssertFalse(source.contains("group-opens"), "no group, nothing to say of it")
        XCTAssertTrue(source.contains("#piece-label.update(\"Fragment 3\")\n= La mer"), source)
        let pages = try await pdf(m, root, "reader", keep: "fragments-reader")
        let first = try XCTUnwrap(pages.firstIndex { $0.contains("Éclat numéro 1.") })
        XCTAssertTrue(pages[first].contains("Fragment 2") && pages[first].contains("Éclat numéro 2."), "the second starts in the first's page: \(pages[first])")
        XCTAssertLessThan(pages.count - first, 8, "eight fragments on fewer pages")
        let full = try await pdf(m, root, "manuscript", keep: "fragments-manuscript")
        XCTAssertLessThan(full.count, 8, "a manuscript too: one page a fragment would be a page a paragraph")
    }

    /// Read mode sets one piece alone under its own line, without its group's page.
    func testAPieceAloneKeepsItsLine() throws {
        let root = tmp("alone")
        let m = try FormSamples.play(root)
        let one = m.typesetChapters([(id: "s3", text: "# La rue\n\nNuit.\n")], groups: false)
        XCTAssertEqual(one.map(\.opening), [BookSource.Opening(label: "Scène 1")])
        XCTAssertNil(one[0].part)
        XCTAssertEqual(m.typesetForm, BookSource.Form(groupOpens: "rightPage", pieceOpens: "newPage"))
        // A page Musset adds after the pieces opens under its own title.
        XCTAssertEqual(m.typesetChapters([(id: "_bibliographie", text: "# Bibliographie\n")]).map(\.opening), [BookSource.Opening()])
    }

    // MARK: Word, EPUB, Markdown

    func testTheSourcesPandocReads() throws {
        let play = tmp("play"), novel = tmp("novel"), collection = tmp("collection")
        let p = try FormSamples.play(play)
        let text = BookStore(root: play).concatenatedManuscript(p, stripComments: true)
        XCTAssertTrue(text.hasPrefix("# Acte I {.unnumbered .part}\n\n# Scène 1. Le salon\n\nElle entre."), String(text.prefix(200)))
        XCTAssertTrue(text.contains("# Acte II. La fuite {.unnumbered .part}\n\n# Scène 1. La rue\n\n"))
        XCTAssertTrue(text.contains("\n# Scène 2\n\nLe rideau tombe."), "a heading for the text that has none")
        let word = WordManuscript.source(p, store: BookStore(root: play)).text
        XCTAssertTrue(word.hasPrefix("::: {custom-style=\"PartNumber\"}\nActe I\n:::\n\n::: {custom-style=\"ChapterNumber\"}\nScène 1\n:::\n\n::: {#mch_0}\n\n# Le salon\n"), String(word.prefix(200)))
        XCTAssertTrue(word.contains("::: {custom-style=\"PartNumber\"}\nActe II\n:::\n\n::: {custom-style=\"PartTitle\"}\nLa fuite\n:::\n\n::: {custom-style=\"ChapterNumber\"}\nScène 1\n:::\n\n::: {#mch_2}"))
        XCTAssertTrue(word.contains("# Scène 2\n\n::: {#mch_3}\n\nLe rideau tombe."), "the heading Musset gives stays outside the text sent for correction")

        let n = try FormSamples.novel(novel)
        let book = BookStore(root: novel).concatenatedManuscript(n, stripComments: true)
        XCTAssertTrue(book.hasPrefix("# Prologue\n\nAvant tout."), String(book.prefix(80)))
        for heading in ["# Partie I {.unnumbered .part}\n\n# Chapitre 1. Le port\n", "# Interlude. Le rêve\n", "# Partie II. La fuite {.unnumbered .part}\n\n# Chapitre 3. Nice\n", "# Épilogue\n\nAprès tout."] {
            XCTAssertTrue(book.contains(heading), heading)
        }

        // A group level without numbers: its title is its line, and no empty paragraph stands for a number.
        var c = try FormSamples.collection(collection)
        XCTAssertFalse(WordManuscript.source(c, store: BookStore(root: collection)).text.contains("PartNumber"), "the level is off")
        c.structure?[.group] = BookStructure.Level()
        let sections = WordManuscript.source(c, store: BookStore(root: collection)).text
        XCTAssertTrue(sections.hasPrefix("::: {custom-style=\"PartNumber\"}\nDehors\n:::\n\n::: {#mch_0}\n\n# La mer"), String(sections.prefix(120)))
        XCTAssertFalse(sections.contains("PartTitle") || sections.contains("\"PartNumber\"}\n\n:::"))
        XCTAssertFalse(sections.contains("ChapterNumber"), "texts without numbers have their titles only")
        XCTAssertTrue(BookStore(root: collection).concatenatedManuscript(c, stripComments: true).contains("# Dedans {.unnumbered .part}\n\n# La pluie\n"))
    }

    /// Strands are the author's tool: a book whose pieces follow strands comes out as the same book without them,
    /// in the typesetter's source, in Word's, and in the Markdown the EPUB and the other outputs are made from.
    func testStrandsReachNoOutput() throws {
        for (name, make) in [("novel", FormSamples.novel), ("play", FormSamples.play)] as [(String, (URL) throws -> BookManifest)] {
            let root = tmp("strands-" + name)
            let plain = try make(root)
            var m = plain
            m.structure?.strands = [.init(id: "s1", name: "1943", colour: "#8FA3FF"), .init(id: "s2", name: "Aujourd’hui", colour: "#8E4A7A")]
            for i in m.chapters.indices { m.chapters[i].strand = i % 2 == 0 ? "s1" : "s2" }
            XCTAssertNotEqual(m, plain)
            let store = BookStore(root: root)
            for p in store.presets(plain) {
                XCTAssertEqual(try TypesetBook(Typesetting.source(manifest: m, store: store, preset: p)).typstSource,
                               try TypesetBook(Typesetting.source(manifest: plain, store: store, preset: p)).typstSource, "\(name) \(p.id)")
            }
            XCTAssertEqual(WordManuscript.source(m, store: store).text, WordManuscript.source(plain, store: store).text, name)
            for strip in [true, false] {
                XCTAssertEqual(store.concatenatedManuscript(m, stripComments: strip), store.concatenatedManuscript(plain, stripComments: strip), name)
            }
            let typst = try TypesetBook(Typesetting.source(manifest: m, store: store, preset: preset("reader", m, root))).typstSource
            XCTAssertFalse(typst.contains("1943") || typst.contains("Aujourd’hui") || typst.contains("8FA3FF"))
        }
    }

    /// The Word file of a novel with a prologue, and back: the lines are the form's, in styles of their own, and
    /// the pieces are still found by their marks.
    @MainActor func testWordAndBack() async throws {
        try XCTSkipIf(ExportService.pandoc == nil, "pandoc is needed")
        let root = tmp("word")
        var m = try FormSamples.novel(root)
        m.exports = [ExportPreset(id: "docx", name: "Word", format: .docx)]
        let git = GitService(root: root)
        try git.initRepo()
        try BookStore(root: root).saveManifest(m)
        _ = try git.commit(paths: m.chapters.map(\.file) + [".musset"], message: "start")
        let session = BookSession(root: root, manifest: m)
        let out = try await ExportService.export(manifest: m, store: BookStore(root: root), preset: m.exports[0]).file
        let dir = try await unzip(out)
        let url = dir.appendingPathComponent("word/document.xml")
        var xml = try String(contentsOf: url, encoding: .utf8)
        let all = paragraphs(xml)
        func at(_ p: String) throws -> Int { try XCTUnwrap(all.firstIndex(of: p), "\(p) in \(all.filter { !$0.hasPrefix("BodyText") && !$0.hasPrefix("FirstParagraph") })") }
        XCTAssertEqual(try at("Heading1|Prologue"), all.firstIndex { $0.hasPrefix("Heading") }, "the prologue under its own title, a page to itself")
        XCTAssertEqual(try at("PartNumber|Partie I") + 1, try at("ChapterNumber|Chapitre 1"))
        XCTAssertEqual(try at("ChapterNumber|Chapitre 1") + 1, try at("ChapterTitle|Le port"), "the title on the line's page")
        XCTAssertEqual(try at("ChapterNumber|Interlude") + 1, try at("ChapterTitle|Le rêve"))
        XCTAssertEqual(try at("PartNumber|Partie II") + 1, try at("PartTitle|La fuite"))
        XCTAssertEqual(try at("PartTitle|La fuite") + 1, try at("ChapterNumber|Chapitre 3"))
        XCTAssertEqual(try at("Heading1|Épilogue") + 1, try at("FirstParagraph|Après tout. " + String(repeating: FormSamples.para, count: 5).trimmingCharacters(in: .whitespaces)))
        XCTAssertFalse(all.contains { $0.hasPrefix("PartNumber|") && $0.hasSuffix("|") }, "no empty paragraph for a number")
        let styles = try String(contentsOf: dir.appendingPathComponent("word/styles.xml"), encoding: .utf8)
        XCTAssertTrue(styles.contains(#"w:styleId="ChapterNumber"><w:name w:val="Numéro de chapitre"/>"#) && styles.contains(#"w:styleId="ChapterTitle"><w:name w:val="Titre de chapitre"/><w:basedOn w:val="Heading1"/>"#))

        // What was sent: every piece's text under its mark, the form's lines under none.
        let sent = try XCTUnwrap(WordManuscript.allSent(root: root).first)
        XCTAssertEqual(sent.chapters, ["pro", "c1", "c2", "int", "c3", "epi"])
        for (text, piece) in [("Prologue", "pro"), ("Le port", "c1"), ("Le rêve", "int"), ("Nice", "c3")] {
            XCTAssertEqual(sent.main.first { $0.text == text }?.chapter, piece, text)
        }
        XCTAssertEqual(sent.main.first { $0.text.hasPrefix("Après tout.") }?.chapter, "epi")
        for line in ["Partie I", "Chapitre 1", "Interlude", "Chapitre 3", "Épilogue"] {
            XCTAssertNil(sent.main.first { $0.text == line }?.chapter, "\(line) is not the text's")
        }

        // An editor corrects a word of the third chapter and of the epilogue: each comes back to its piece.
        func edit(_ a: String, _ b: String) { XCTAssertTrue(xml.contains(a), a); xml = xml.replacingOccurrences(of: a, with: b) }
        let mark = #"w:author="Marie Dupont" w:date="2026-11-05T10:00:00Z""#
        edit(#"<w:t xml:space="preserve">Troisième. "#, #"<w:t xml:space="preserve"></w:t></w:r><w:del w:id="901" \#(mark)><w:r><w:delText xml:space="preserve">Troisième</w:delText></w:r></w:del><w:ins w:id="900" \#(mark)><w:r><w:t>Dernier</w:t></w:r></w:ins><w:r><w:t xml:space="preserve">. "#)
        edit(#"<w:t xml:space="preserve">Après tout. "#, #"<w:t xml:space="preserve">Après </w:t></w:r><w:del w:id="903" \#(mark)><w:r><w:delText xml:space="preserve">tout</w:delText></w:r></w:del><w:ins w:id="902" \#(mark)><w:r><w:t>coup</w:t></w:r></w:ins><w:r><w:t xml:space="preserve">. "#)
        try xml.write(to: url, atomically: true, encoding: .utf8)
        let back = root.appendingPathComponent("relu.docx")
        let zipped = try await Shell.runAsync("/usr/bin/zip", ["-q", "-X", "-r", back.path, "[Content_Types].xml", "."], cwd: dir)
        XCTAssertTrue(zipped.ok, zipped.stderr)
        let plan = try await session.wordReviewPlan(back)
        XCTAssertEqual(plan.sent?.chapters, sent.chapters)
        XCTAssertEqual(plan.unplaced, 0, "\(plan.chapters.map(\.unplaced))")
        XCTAssertEqual(plan.placed, 2)
        session.applyWordReview(plan, sender: "Marie")
        let third = session.editorText(of: "c3"), last = session.editorText(of: "epi")
        XCTAssertTrue(third.hasPrefix("# Nice\n{~~Troisième~>Dernier~~}{@Marie}. "), String(third.prefix(80)))
        XCTAssertTrue(last.hasPrefix("Après {~~tout~>coup~~}{@Marie}. "), String(last.prefix(80)))
        XCTAssertFalse(last.contains("Épilogue") || third.contains("Chapitre 3"), "the form's lines do not come back into the text")
    }

    /// The EPUB: the contents list the pieces under their lines, and pandoc numbers nothing itself.
    func testTheEPUBListsThePiecesUnderTheirLines() async throws {
        try XCTSkipIf(ExportService.pandoc == nil, "pandoc is needed")
        let root = tmp("epub")
        let m = try FormSamples.play(root)
        var p = try preset("epub", m, root)
        p.numberSections = true
        let dir = try await unzip(try await ExportService.export(manifest: m, store: BookStore(root: root), preset: p).file)
        let nav = try String(contentsOf: dir.appendingPathComponent("EPUB/nav.xhtml"), encoding: .utf8)
        let entries = nav.components(separatedBy: "</a>").compactMap { $0.components(separatedBy: ">").last }.filter { !$0.isEmpty && !$0.contains("<") }
        XCTAssertEqual(Array(entries.filter { $0.contains("Acte") || $0.contains("Scène") }.prefix(6)),
                       ["Acte I", "Scène 1. Le salon", "Scène 2. L’aveu", "Acte II. La fuite", "Scène 1. La rue", "Scène 2"], nav)
        XCTAssertFalse(nav.contains("header-section-number"), "the form numbers, not pandoc")
    }
}
