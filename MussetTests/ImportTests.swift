import XCTest
@testable import Musset

@MainActor
final class ImportTests: XCTestCase {
    private func para(_ t: String, centered: Bool = false, bold: Bool = false, size: Int? = nil, pageBreak: Bool = false) -> String {
        let ppr = "<w:pPr>" + (centered ? "<w:jc w:val=\"center\"/>" : "") + "</w:pPr>"
        let rpr = "<w:rPr>" + (bold ? "<w:b/>" : "") + (size.map { "<w:sz w:val=\"\($0)\"/>" } ?? "") + "</w:rPr>"
        return (pageBreak ? "<w:p><w:r><w:br w:type=\"page\"/></w:r></w:p>" : "") + "<w:p>\(ppr)<w:r>\(rpr)<w:t>\(t)</w:t></w:r></w:p>"
    }

    private let long = String(repeating: "Le train est entré en gare avec vingt minutes de retard et personne ne levait les yeux. ", count: 2)

    private func xml(_ body: String) -> String {
        "<?xml version=\"1.0\"?><w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:body>\(body)</w:body></w:document>"
    }

    /// The novelist who centres titles by hand: no styles at all.
    private var unstyled: String {
        xml(para("À Marguerite", centered: true) + para("LE QUAI", centered: true, bold: true, size: 32, pageBreak: true) + para(long) + para("* * *", centered: true) + para(long)
            + para("L’ENVELOPPE", centered: true, bold: true, size: 32, pageBreak: true) + para(long)
            + para("LE PONT", centered: true, bold: true, size: 32, pageBreak: true) + para(long) + para("Il pleuvait.") )
    }

    func testDetectsRepeatedHandMadeTitles() {
        let paras = DocxAnalyzer.paragraphs(xml: unstyled)
        let found = DocxAnalyzer.detect(paras)
        let chapters = zip(paras, found.marks).filter { $0.1 == .chapter }.map(\.0.text)
        XCTAssertEqual(chapters, ["LE QUAI", "L’ENVELOPPE", "LE PONT"])
        XCTAssertEqual(zip(paras, found.marks).first { $0.0.text == "* * *" }?.1, .scene)
        XCTAssertFalse(found.rule.isEmpty)
        XCTAssertEqual(zip(paras, found.marks).first { $0.0.text == "Il pleuvait." }?.1, .body)
    }

    func testAloneAndCentredIsLeftToTheAuthor() {
        let paras = DocxAnalyzer.paragraphs(xml: xml(para("À Marguerite", centered: true, bold: true) + para("UN", centered: true, bold: true, size: 32, pageBreak: true) + para(long) + para("DEUX", centered: true, bold: true, size: 32, pageBreak: true) + para(long)))
        let marks = DocxAnalyzer.detect(paras).marks
        XCTAssertEqual(marks[paras.firstIndex { $0.text == "À Marguerite" }!], .body == marks[paras.firstIndex { $0.text == "À Marguerite" }!] ? .body : .candidate)
        XCTAssertNotEqual(marks[paras.firstIndex { $0.text == "À Marguerite" }!], .chapter)
    }

    func testNumberedTitlesWithoutAnyFormatting() {
        let paras = DocxAnalyzer.paragraphs(xml: xml(para("Chapitre 1") + para(long) + para("Chapitre 2") + para(long) + para("III") + para(long)))
        let found = DocxAnalyzer.detect(paras)
        XCTAssertEqual(zip(paras, found.marks).filter { $0.1 == .chapter }.map(\.0.text), ["Chapitre 1", "Chapitre 2", "III"])
    }

    func testHeadingStylesWin() {
        let h = { (t: String, s: String) in "<w:p><w:pPr><w:pStyle w:val=\"\(s)\"/></w:pPr><w:r><w:t>\(t)</w:t></w:r></w:p>" }
        let paras = DocxAnalyzer.paragraphs(xml: xml(h("Un", "Heading1") + h("Scène", "Heading2") + para(long) + h("Deux", "Titre1") + para("CENTRÉ", centered: true, bold: true)))
        let found = DocxAnalyzer.detect(paras)
        XCTAssertEqual(zip(paras, found.marks).filter { $0.1 == .chapter }.map(\.0.text), ["Un", "Deux"])
        XCTAssertEqual(zip(paras, found.marks).first { $0.0.text == "Scène" }?.1, .scene)
    }

    func testTitlesFormattedDifferentlyStillStandOut() {
        let paras = DocxAnalyzer.paragraphs(xml: xml(para("LE QUAI", centered: true, bold: true, size: 32) + para(long) + para("* * *", centered: true) + para(long) + para("Chapitre 2", centered: true, pageBreak: true) + para(long)))
        let found = DocxAnalyzer.detect(paras)
        XCTAssertEqual(zip(paras, found.marks).filter { $0.1 == .chapter }.map(\.0.text), ["LE QUAI", "Chapitre 2"])
    }

    func testNoMarksIsSaid() {
        let found = DocxAnalyzer.detect(DocxAnalyzer.paragraphs(xml: xml(para(long) + para(long))))
        XCTAssertFalse(found.marks.contains(.chapter))
    }

    func testPlainProseShortLinesAreNotChapters() {
        let paras = DocxAnalyzer.paragraphs(xml: xml(para(long) + para("Oui.") + para(long) + para("Non.") + para(long)))
        XCTAssertFalse(DocxAnalyzer.detect(paras).marks.contains(.chapter))
    }

    func testSplitAtMarks() {
        let md = "Avant.\n\n**⟦MUSSET-CH⟧LE QUAI**\n\nTexte *ici*.\n\n⟦MUSSET-SC⟧\\* \\* \\*\n\nSuite.\n\n# ⟦MUSSET-CH⟧Le pont\n\nFin.\n"
        let c = BookImporter.split(markdown: md)
        XCTAssertEqual(c.map(\.title), [L("Opening"), "LE QUAI", "Le pont"])
        XCTAssertTrue(c[1].text.contains("Texte *ici*."))
        XCTAssertTrue(c[1].text.contains("<!-- scene:"))
        XCTAssertFalse(c[1].text.contains("⟦"))
    }

    private func makeDocx() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("musset-docx-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("_rels"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("word"), withIntermediateDirectories: true)
        try "<?xml version=\"1.0\"?><Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Override PartName=\"/word/document.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/></Types>".write(to: dir.appendingPathComponent("[Content_Types].xml"), atomically: true, encoding: .utf8)
        try "<?xml version=\"1.0\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"r1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"word/document.xml\"/></Relationships>".write(to: dir.appendingPathComponent("_rels/.rels"), atomically: true, encoding: .utf8)
        try unstyled.write(to: dir.appendingPathComponent("word/document.xml"), atomically: true, encoding: .utf8)
        let out = dir.deletingLastPathComponent().appendingPathComponent("\(UUID()).docx")
        _ = try Shell.run("/usr/bin/zip", ["-q", "-r", out.path, "."], cwd: dir)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir); try? FileManager.default.removeItem(at: out) }
        return out
    }

    func testWordEndToEndThroughPandocLeavesTheOriginalAlone() async throws {
        let file = try makeDocx()
        let before = try Data(contentsOf: file)
        var plan = try await BookImporter.planWord(file)
        XCTAssertEqual(plan.chapterCount, 4, "the dedication before the first title opens the book")
        let chapters = try await BookImporter.chapters(of: plan, cwd: FileManager.default.temporaryDirectory)
        XCTAssertEqual(chapters.map(\.title).suffix(3), ["LE QUAI", "L’ENVELOPPE", "LE PONT"])
        XCTAssertTrue(chapters.first { $0.title == "LE QUAI" }!.text.contains("<!-- scene:"))
        XCTAssertFalse(chapters.contains { $0.text.contains("⟦") })
        XCTAssertEqual(try Data(contentsOf: file), before)
        if let i = plan.paragraphs.firstIndex(where: { $0.text == "LE PONT" }) { plan.marks[i] = .body }
        XCTAssertEqual(plan.chapterCount, 3)
    }

    func testScrivenerProject() async throws {
        let p = FileManager.default.temporaryDirectory.appendingPathComponent("Roman-\(UUID()).scriv", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: p) }
        let doc = { (id: String, text: String, synopsis: String?) in
            let dir = p.appendingPathComponent("Files/Data/\(id)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try "{\\rtf1\\ansi \(text)}".write(to: dir.appendingPathComponent("content.rtf"), atomically: true, encoding: .utf8)
            if let synopsis { try synopsis.write(to: dir.appendingPathComponent("synopsis.txt"), atomically: true, encoding: .utf8) }
        }
        try doc("A1", "Il pleuvait.", "La filature")
        try doc("B1", "Elle attendit.", nil)
        try """
        <?xml version="1.0"?><ScrivenerProject><Binder>
        <BinderItem UUID="D" Type="DraftFolder"><Title>Manuscrit</Title><Children>
          <BinderItem UUID="F1" Type="Folder"><Title>Le pont</Title><Children>
            <BinderItem UUID="A1" Type="Text"><Title>La filature</Title></BinderItem>
          </Children></BinderItem>
          <BinderItem UUID="B1" Type="Text"><Title>Le quai</Title></BinderItem>
        </Children></BinderItem>
        </Binder></ScrivenerProject>
        """.write(to: p.appendingPathComponent("Roman.scrivx"), atomically: true, encoding: .utf8)
        let plan = try await BookImporter.planScrivener(p, cwd: FileManager.default.temporaryDirectory)
        XCTAssertEqual(plan.chapters.map(\.title), ["Le pont", "Le quai"])
        XCTAssertTrue(plan.chapters[0].text.contains("<!-- scene: La filature -->"))
        XCTAssertTrue(plan.chapters[0].text.contains("Il pleuvait."))
        XCTAssertEqual(plan.chapters[0].synopsis["La filature"], "La filature")
    }

    func testUlyssesExportFolder() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("export-\(UUID())", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let group = dir.appendingPathComponent("02 Le pont", isDirectory: true)
        try FileManager.default.createDirectory(at: group, withIntermediateDirectories: true)
        try "# Le quai\n\nTexte.\n".write(to: dir.appendingPathComponent("01 quai.md"), atomically: true, encoding: .utf8)
        try "# La filature\n\nElle marche.\n".write(to: group.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
        let plan = try BookImporter.planFolder(dir)
        XCTAssertEqual(plan.chapters.map(\.title), ["Le quai", "02 Le pont"])
        XCTAssertTrue(plan.chapters[1].text.contains("<!-- scene: La filature -->"))
        XCTAssertTrue(plan.chapters[1].text.contains("Elle marche."))
    }

    func testCitationsAreNotLinks() {
        XCTAssertEqual(References.citations(in: "Voir [@pastoureau2000] et [voir @corbin1982, p. 3], mais pas @[Le pont]."), ["pastoureau2000", "corbin1982"])
    }

    func testTypstPagesResolveCitations() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("musset-typ-\(UUID())", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        var e = BibleEntry(path: "documents/bleu.md", kind: .reference, title: "Bleu")
        e.meta = ["citekey": "pastoureau2000", "author": "Michel Pastoureau", "year": "2000", "publisher": "Seuil"]
        try BibleStore(root: root).write(e)
        let out = CitationPages.apply(to: [(id: "1", text: "Voir [@pastoureau2000, p. 3] et [@absente].")], root: root, lang: "fr")
        XCTAssertEqual(out[0].text, "Voir (Pastoureau, 2000, p. 3) et [@absente].")
        XCTAssertEqual(out.last?.id, "_bibliographie")
        XCTAssertTrue(out.last?.text.contains("Michel Pastoureau, *Bleu*, Seuil, 2000.") == true)
    }

    func testIdentifiers() {
        XCTAssertEqual(References.doi(in: "https://doi.org/10.1000/xyz123"), "10.1000/xyz123")
        XCTAssertEqual(References.isbn(in: "978-2-02-041011-5"), "9782020410115")
        XCTAssertNil(References.isbn(in: "https://exemple.fr/1234567890"))
    }

    func testBibliographyImport() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("musset-ref-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try "# Un\n\nVoir [@pastoureau2000] et [@absente].\n".write(to: root.appendingPathComponent("01.md"), atomically: true, encoding: .utf8)
        let s = BookSession(root: root, manifest: BookManifest(title: "T", chapters: [ChapterEntry(id: "01", file: "01.md", title: "Un")]))
        let bib = root.appendingPathComponent("refs.bib")
        try "@book{pastoureau2000, title={Bleu}, author={Pastoureau, Michel}, year={2000}, publisher={Seuil}}\n@book{corbin1982, title={Le Miasme}, author={Corbin, Alain}, year={1982}}".write(to: bib, atomically: true, encoding: .utf8)
        let problem = await BibleImporter.importAll([bib], into: "documents", session: s)
        XCTAssertNil(problem)
        let refs = References.entries(s)
        XCTAssertEqual(Set(refs.compactMap { $0.meta["citekey"] }), ["pastoureau2000", "corbin1982"])
        XCTAssertEqual(refs.first { $0.meta["citekey"] == "pastoureau2000" }?.meta["year"], "2000")
        XCTAssertEqual(References.missing(in: s), ["absente"])
        XCTAssertEqual(References.citeCount(of: refs.first { $0.meta["citekey"] == "corbin1982" }!, in: s), 0)
    }

    func testDocumentsStayOutOfGitAndCutsComeBack() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("musset-git-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try "# Un\n\nTexte.\n".write(to: root.appendingPathComponent("01.md"), atomically: true, encoding: .utf8)
        let s = BookSession(root: root, manifest: BookManifest(title: "T", chapters: [ChapterEntry(id: "01", file: "01.md", title: "Un")]))
        try s.git.initRepo()
        try s.bible.create(title: "Marguerite", kind: .character)
        let pdf = s.bible.store.url("documents/secret.pdf")
        try s.bible.store.prepare(pdf)
        try Data("x".utf8).write(to: pdf)
        s.commitNow("test")
        XCTAssertNotNil(s.git.show("HEAD", path: "bible/personnages/marguerite.md"))
        XCTAssertNil(s.git.show("HEAD", path: "bible/documents/secret.pdf"))
    }

    func testGenreSetsTheOutline() {
        XCTAssertTrue(PlotGrid.columns(forGenre: "essai").contains { $0.title == "Thèse" })
        XCTAssertTrue(PlotGrid.columns(forGenre: "fantasy").contains { $0.title == "Monde" })
        XCTAssertEqual(PlotGrid.columns(forGenre: nil), PlotGrid.defaultColumns)
        XCTAssertEqual(PlotGrid.columns(forGenre: "fantasy").first?.id, "main")
    }

    func testCreatingABookAppliesGenreAndLanguage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("musset-new-\(UUID())", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let app = AppState()
        try await app.createBook(at: root, title: "T", author: "A", lang: "en", genre: "fantasy", chapters: [PlannedChapter(title: "One", text: "# One\n\n")])
        let m = try BookStore(root: root).loadManifest()
        XCTAssertEqual(m.genre, "fantasy")
        XCTAssertEqual(m.lang, "en")
        XCTAssertEqual(Bareme.forBook(root)?.presetId, "fantasy")
        XCTAssertTrue(PlotGrid.load(root).columns.contains { $0.title == "Monde" })
        app.removeFromLibrary(root.standardizedFileURL.path)
    }

    func testLastSentenceSkipsHeadingsAndMarkers() {
        let t = "# Titre\nUne phrase.\n<!-- scene: X -->\nLa dernière.\n"
        XCTAssertEqual(BookCard.sentence(before: nil, in: t), "La dernière.")
        XCTAssertEqual(BookCard.sentence(before: 19, in: t), "Une phrase.")
    }

    func testCaptureGoesWithItsChapterElseToSort() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("musset-cap-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try "# Le pont\n".write(to: root.appendingPathComponent("01.md"), atomically: true, encoding: .utf8)
        let s = BookSession(root: root, manifest: BookManifest(title: "T", chapters: [ChapterEntry(id: "01", file: "01.md", title: "Le pont")]))
        XCTAssertEqual(s.file(capture: "@todo Vérifier l’âge dans @[Le pont]"), "Le pont")
        XCTAssertEqual(try String(contentsOf: NoteStore.url(root, "01"), encoding: .utf8), "- [ ] Vérifier l’âge dans @[Le pont]\n")
        s.file(capture: "Une idée sans place")
        XCTAssertEqual(s.bible.entries(in: "a-trier").first?.body, "Une idée sans place\n")
        XCTAssertEqual(s.collectTodos().filter { $0.chapter == "01" }.count, 1)
        XCTAssertEqual(s.linkTargets(matching: "pon").first?.title, "Le pont")
    }
}
