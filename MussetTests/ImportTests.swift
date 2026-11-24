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

    /// A project on disk, written as Scrivener 3 for the Mac writes it.
    private func scriv(_ binder: String, docs: [String: [String: String]], layout: (String, String) -> String = { "Files/Data/\($0)/\($1)" }) throws -> URL {
        let p = FileManager.default.temporaryDirectory.appendingPathComponent("Roman-\(UUID()).scriv", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: p) }
        try FileManager.default.createDirectory(at: p, withIntermediateDirectories: true)
        for (id, files) in docs {
            for (name, content) in files {
                let f = p.appendingPathComponent(layout(id, name))
                try FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
                try content.write(to: f, atomically: true, encoding: .utf8)
            }
        }
        try "<?xml version=\"1.0\" encoding=\"UTF-8\"?><ScrivenerProject Version=\"2.0\"><Binder>\(binder)</Binder></ScrivenerProject>"
            .write(to: p.appendingPathComponent("\(p.deletingPathExtension().lastPathComponent).scrivx"), atomically: true, encoding: .utf8)
        return p
    }

    /// The Mac's RTF: a paragraph ends with a backslash at the end of the line.
    private func cocoa(_ body: String) -> String {
        "{\\rtf1\\ansi\\ansicpg1252\\cocoartf2819\n{\\fonttbl\\f0\\fnil\\fcharset0 Palatino-Roman;}\n{\\colortbl;\\red255\\green255\\blue255;}\n\\pard\\fi720\\sl480\\slmult1\\pardirnatural\\partightenfactor0\n\n\\f0\\fs26 \\cf0 \(body)}"
    }

    func testScrivenerParagraphsStayParagraphs() async throws {
        let p = try scriv("""
        <BinderItem UUID="D" Type="DraftFolder"><Title>Draft</Title><Children>
          <BinderItem UUID="A" Type="Text"><Title>Le quai</Title></BinderItem>
        </Children></BinderItem>
        """, docs: ["A": ["content.rtf": cocoa("\\tab Il pleuvait sur le quai.\\\n\\tab \\'c9lise attendit, \\i longtemps\\i0 .\\\n\\\nLe train \\uc0\\u8212  enfin.")]])
        let text = try await BookImporter.planScrivener(p, cwd: FileManager.default.temporaryDirectory).chapters[0].text
        XCTAssertEqual(text, "# Le quai\n\nIl pleuvait sur le quai.\n\nÉlise attendit, *longtemps*.\n\nLe train — enfin.\n")
    }

    func testScrivenerMarksDoNotReachTheText() async throws {
        let rtf = cocoa("""
        <$Scr_Ps::0>Une lettre, cit\\'e9e.\\
        Sa suite.<!$Scr_Ps::0>\\
        Du <$Scr_Cs::1>\\b gras\\b0 <!$Scr_Cs::1> ici.\\
        Une note.\\{\\\\Scrv_fn= La note de bas de page.\\\\end_Scrv_fn\\}\\
        \\{\\\\Scrv_annot \\\\color=\\{\\\\R=0.6\\\\G=0.04\\\\B=0.01\\} \\\\text=V\\'e9rifier la date.\\\\end_Scrv_annot\\}\\
        Elle {\\field{\\*\\fldinst{HYPERLINK "scrivcmt://AAAA-1"}}{\\fldrslt h\\'e9sita}} puis {\\field{\\*\\fldinst{HYPERLINK "scrivcmt://AAAA-2"}}{\\fldrslt partit.}}\\
        Voir {\\field{\\*\\fldinst{HYPERLINK "scrivlnk://BBBB"}}{\\fldrslt le chapitre deux}}.\\
        {\\pict\\pngblip\\picw10\\pich10 89504e470d0a1a0a}\\
        \\itap1\\trowd \\taflags1 \\trgaph108\\trleft-108 \\clvertalc \\cellx8640
        \\pard\\intbl\\itap1 Dans un tableau.\\cell \\lastrow\\row
        \\pard Fin.
        """)
        let comments = """
        <?xml version="1.0" encoding="UTF-8"?><Comments>
        <Comment ID="AAAA-1"><![CDATA[{\\rtf1\\ansi\\ansicpg1252 Trop long ?}]]></Comment>
        <Comment ID="AAAA-2" Footnote="Yes"><![CDATA[{\\rtf1\\ansi\\ansicpg1252 Not\\'e9 en marge.}]]></Comment>
        </Comments>
        """
        let p = try scriv("""
        <BinderItem UUID="D" Type="DraftFolder"><Title>Draft</Title><Children>
          <BinderItem UUID="A" Type="Text"><Title>Un</Title></BinderItem>
        </Children></BinderItem>
        """, docs: ["A": ["content.rtf": rtf, "content.comments": comments, "content.styles": "S-QUOTE\nS-BOLD\n"]])
        try "<Styles><Style Name=\"Block Quote\" ID=\"S-QUOTE\"/><Style Name=\"Strong\" ID=\"S-BOLD\"/></Styles>"
            .write(to: p.appendingPathComponent("Files/styles.xml"), atomically: true, encoding: .utf8)
        let plan = try await BookImporter.planScrivener(p, cwd: FileManager.default.temporaryDirectory)
        let text = plan.chapters[0].text
        for leak in ["Scr_", "Scrv_", "scrivcmt", "scrivlnk", "<img", "![", "<table", "||", "\\<", "&lt;"] {
            XCTAssertFalse(text.contains(leak), "\(leak) in:\n\(text)")
        }
        XCTAssertTrue(text.contains("> Une lettre, citée.\n\n> Sa suite."), text)
        XCTAssertTrue(text.contains("Du **gras** ici."), text)
        XCTAssertTrue(text.contains("Une note.[^1]"), text)
        XCTAssertTrue(text.contains("[^1]: La note de bas de page."), text)
        XCTAssertTrue(text.contains("{>>Vérifier la date.<<}"), text)
        XCTAssertTrue(text.contains("Elle {==hésita==}{>>Trop long ?<<} puis partit.[^2]"), text)
        XCTAssertTrue(text.contains("[^2]: Noté en marge."), text)
        XCTAssertTrue(text.contains("Voir le chapitre deux."), text)
        XCTAssertTrue(text.contains("Dans un tableau.\n\nFin."), text)
    }

    func testScrivenerPartsChaptersAndScenes() async throws {
        let doc = { (s: String) in ["content.rtf": self.cocoa(s)] }
        let p = try scriv("""
        <BinderItem UUID="D" Type="DraftFolder"><Title>Manuscript</Title><Children>
          <BinderItem UUID="PR" Type="Text"><Title>Prologue</Title></BinderItem>
          <BinderItem UUID="P1" Type="Folder"><Title>Part One</Title><Children>
            <BinderItem UUID="C1" Type="Folder"><Title>Chapter 1</Title><Children>
              <BinderItem UUID="S1" Type="Text"><Title>Arrival</Title><Children>
                <BinderItem UUID="S1B" Type="Text"><Title></Title></BinderItem>
              </Children></BinderItem>
              <BinderItem UUID="S2" Type="Text"><Title>Arrival</Title></BinderItem>
              <BinderItem UUID="N1" Type="Text"><Title>Notes to self</Title><MetaData><IncludeInCompile>No</IncludeInCompile></MetaData></BinderItem>
              <BinderItem UUID="IMG" Type="Image"><Title>Map</Title></BinderItem>
            </Children></BinderItem>
            <BinderItem UUID="C2" Type="Folder"><Title>Chapter 2</Title><Children>
              <BinderItem UUID="S3" Type="Text"><Title>The road -- north</Title></BinderItem>
            </Children></BinderItem>
          </Children></BinderItem>
          <BinderItem UUID="P2" Type="Folder"><Title>Part Two</Title><Children>
            <BinderItem UUID="C3" Type="Folder"><Title>Chapter 3</Title></BinderItem>
          </Children></BinderItem>
        </Children></BinderItem>
        <BinderItem UUID="R" Type="ResearchFolder"><Title>Research</Title><Children>
          <BinderItem UUID="RX" Type="Text"><Title>Salt trade</Title></BinderItem>
        </Children></BinderItem>
        """, docs: ["PR": doc("Before."), "S1": doc("She arrived."), "S1B": doc("Later that same night, she slept badly."),
                    "S2": doc("Again."), "N1": doc("SECRET NOTE"), "S3": doc("North."), "P2": doc("An epigraph for the part."),
                    "RX": doc("RESEARCH"), "S2x": [:]].merging(["S2": ["content.rtf": cocoa("Again."), "synopsis.txt": "She comes back."]]) { $1 })
        let plan = try await BookImporter.planScrivener(p, cwd: FileManager.default.temporaryDirectory)
        XCTAssertEqual(plan.chapters.map(\.title), ["Prologue", "Chapter 1", "Chapter 2", "Part Two", "Chapter 3"])
        let one = plan.chapters[1]
        XCTAssertEqual(Scenes.parse(one.text).map(\.title), ["Arrival", "Later that same night, she slept", "Arrival 2"])
        XCTAssertEqual(one.synopsis["Arrival 2"], "She comes back.")
        XCTAssertTrue(plan.chapters[2].text.contains("<!-- scene: The road – north -->"))
        XCTAssertEqual(plan.chapters[3].text, "# Part Two\n\nAn epigraph for the part.\n")
        XCTAssertEqual(plan.chapters.map(\.part), [nil, "Part One", "Part One", "Part Two", "Part Two"])

        // The book made from it has the two parts, each with its chapters.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("livre-\(UUID())", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try await AppState().createBook(at: root, title: "Roman", author: "A", lang: "en", genre: nil, chapters: plan.chapters)
        let m = try BookStore(root: root).loadManifest()
        XCTAssertEqual(m.orderedParts.map(\.title), ["Part One", "Part Two"])
        // Musset-App/musset#2: a new book has its lists, bullets and numbers, in the editor and on the page, whatever its form.
        XCTAssertEqual(m.listOptions, ListOptions(bullets: true, numbered: true, dialogue: true))
        XCTAssertEqual(m.printedListOptions, ListOptions(bullets: true, numbered: true))
        XCTAssertTrue(m.typesetText.bullets && m.typesetText.numbered)
        XCTAssertFalse(m.hasForm, "an imported book still reads as the book Musset always made")
        XCTAssertEqual(m.chapters.map { ch in m.parts?.first { $0.id == ch.part }?.title }, [nil, "Part One", "Part One", "Part Two", "Part Two"])
        let all = plan.chapters.map(\.text).joined()
        XCTAssertFalse(all.contains("SECRET NOTE"))
        XCTAssertFalse(all.contains("RESEARCH"))
        XCTAssertTrue(plan.keeps.contains { $0.to == L("Left out") })
    }

    /// Scrivener 2 numbers its documents and keeps them side by side in Files/Docs.
    func testScrivener2Project() async throws {
        let p = try scriv("""
        <BinderItem ID="1" Type="DraftFolder"><Title>Draft</Title><Children>
          <BinderItem ID="3" Type="Folder"><Title>One</Title><Children>
            <BinderItem ID="4" Type="Text"><Title>Dawn</Title></BinderItem>
            <BinderItem ID="5" Type="Text"><Title>Plain</Title></BinderItem>
          </Children></BinderItem>
        </Children></BinderItem>
        """, docs: ["4": [".rtf": "{\\rtf1\\ansi\\ansicpg1252 First light.\\par Second paragraph.}", "_synopsis.txt": "The sun rises."],
                    "5": [".txt": "A line.\nAnother."]], layout: { "Files/Docs/\($0)\($1)" })
        let plan = try await BookImporter.planScrivener(p, cwd: FileManager.default.temporaryDirectory)
        XCTAssertEqual(plan.chapters.map(\.title), ["One"])
        XCTAssertEqual(plan.chapters[0].text, "# One\n\n<!-- scene: Dawn -->\n\nFirst light.\n\nSecond paragraph.\n\n<!-- scene: Plain -->\n\nA line.\n\nAnother.\n")
        XCTAssertEqual(plan.chapters[0].synopsis["Dawn"], "The sun rises.")
    }

    /// A real project, when one is at hand: nothing of Scrivener's own may reach the text. Writes the chapters to
    /// MUSSET_SCRIV_OUT for reading.
    func testARealScrivenerProject() async throws {
        guard let path = ProcessInfo.processInfo.environment["MUSSET_SCRIV"] else { throw XCTSkip("MUSSET_SCRIV is not set") }
        let project = URL(fileURLWithPath: path)
        let before = try Data(contentsOf: Scrivener.binder(of: project))
        let started = Date()
        let plan = try await BookImporter.planScrivener(project, cwd: FileManager.default.temporaryDirectory)
        print("SCRIV \(plan.chapters.count) chapters, \(plan.wordCount) words, \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
        XCTAssertFalse(plan.chapters.isEmpty)
        XCTAssertEqual(try Data(contentsOf: Scrivener.binder(of: project)), before)
        if let out = ProcessInfo.processInfo.environment["MUSSET_SCRIV_OUT"] {
            let dir = URL(fileURLWithPath: out)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for (i, c) in plan.chapters.enumerated() {
                try c.text.write(to: dir.appendingPathComponent(String(format: "%02d %@.md", i + 1, c.title.replacingOccurrences(of: "/", with: "-"))), atomically: true, encoding: .utf8)
            }
        }
        for c in plan.chapters {
            for leak in ["Scr_", "Scrv_", "scrivcmt", "scrivlnk", "<img", "<table", "<td", "data:image"] {
                XCTAssertFalse(c.text.contains(leak), "\(leak) in « \(c.title) »")
            }
            XCTAssertFalse(c.text.contains("  \n"), "a line break where a paragraph ends in « \(c.title) »")
        }
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
        XCTAssertEqual(out[0].text, "Voir (Pastoureau 2000, p. 3) et [@absente].", "author-date, as pandoc's export writes it")
        XCTAssertEqual(out.last?.id, "_bibliographie")
        XCTAssertTrue(out.last?.text.contains("Pastoureau, Michel. 2000. *Bleu*. Seuil.") == true, out.last?.text ?? "")
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

@MainActor
final class FirstRunTests: XCTestCase {
    /// The example is a whole book: its chapters, its people, its history with what was cut, and it opens twice
    /// on the same folder.
    func testTheExampleBookIsMadeAsABookIs() async throws {
        let shelf = FileManager.default.temporaryDirectory.appendingPathComponent("example-\(UUID())", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: shelf) }
        let app = AppState()
        try await ExampleBook.open(in: app, at: shelf, lang: "en-GB")
        let s = try XCTUnwrap(app.current)
        XCTAssertTrue(ExampleBook.isExample(s.root))
        XCTAssertEqual(s.manifest.title, "The Time Machine")
        XCTAssertEqual(s.manifest.chapters.count, 17)
        XCTAssertEqual(s.manifest.chapters.first?.title, "Introduction")
        XCTAssertEqual(s.manifest.chapters.last?.status, .draft)
        XCTAssertEqual(Set(s.manifest.chapters.compactMap(\.status)), [.draft, .done, .edited, .final])
        XCTAssertTrue(s.bible.entries.contains { $0.title == "Weena" && $0.kind == .character })
        XCTAssertTrue(s.bible.entries.contains { $0.kind == .cut && $0.title == "The Grey Man" })
        XCTAssertEqual(s.milestones.map(\.title).sorted(), ["First edition", "Serial, New Review"])
        XCTAssertFalse((s.plot.synopsis ?? "").isEmpty)
        // The passage is in the serial and no longer in the book.
        let chapter = s.manifest.chapters[13]
        let today = try String(contentsOf: s.root.appendingPathComponent(chapter.file), encoding: .utf8)
        XCTAssertFalse(today.contains("some small breed of kangaroo"))
        let serial = try XCTUnwrap(s.milestones.first { $0.title == "Serial, New Review" })
        XCTAssertTrue((s.git.show(serial.id, path: chapter.file) ?? "").contains("some small breed of kangaroo"))
        XCTAssertEqual(NoteStore.read(NoteStore.url(s.root, s.manifest.chapters[0].id)).count, 3)
        XCTAssertFalse(today.contains("Gutenberg"))
        // Opened again: the same book, not a second one.
        let again = AppState()
        try await ExampleBook.open(in: again, at: shelf, lang: "en-GB")
        XCTAssertEqual(again.current?.root.standardizedFileURL, s.root.standardizedFileURL)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: shelf.path).filter { !$0.hasPrefix(".") }.count, 1)
    }

    func testTheExampleReadsInFrenchAndFallsBackToEnglish() {
        XCTAssertEqual(ExampleBook.title("fr-FR"), "La Machine à explorer le temps")
        XCTAssertEqual(ExampleBook.title("pt-BR"), "The Time Machine")
        XCTAssertEqual(ExampleBook.title("it-IT"), "La macchina del tempo")
        XCTAssertEqual(ExampleBook.title("de-CH"), "Die Zeitmaschine")
        XCTAssertEqual(ExampleBook.title("es-MX"), "La máquina exploradora del tiempo")
        XCTAssertEqual(ExampleBook.content("it-IT")?.chapters.count, 17)
        let fr = try? XCTUnwrap(ExampleBook.content("fr-FR"))
        XCTAssertEqual(fr?.chapters.count, 17)
        XCTAssertNil(fr?.cut)
    }

    /// Every language's example builds, with its notes anchored in its own first chapter.
    /// Musset-App/musset#2: the genres under « Other… » read in French in an English interface.
    func testGenreNamesFollowTheInterface() {
        for p in ScoringLibrary.shared.presets { XCTAssertNotEqual(p.shownName, "", p.id) }
        let saved = UserDefaults.standard.string(forKey: UILang.key)
        defer { UserDefaults.standard.set(saved, forKey: UILang.key) }
        UserDefaults.standard.set(UILang.en.rawValue, forKey: UILang.key)
        XCTAssertEqual(ScoringLibrary.shared.presets.first { $0.id == "historique" }?.shownName, "Historical novel")
        XCTAssertEqual(BookGenres.label("horreur"), "Horror")
        UserDefaults.standard.set(UILang.de.rawValue, forKey: UILang.key)
        XCTAssertEqual(BookGenres.label("horreur"), "Horror")
        XCTAssertEqual(BookGenres.label("historique"), "Historischer Roman")
    }

    func testEveryExampleBuilds() async throws {
        for lang in ["fr-FR", "it-IT", "de-DE", "es-ES"] {
            let shelf = FileManager.default.temporaryDirectory.appendingPathComponent("example-\(UUID())", isDirectory: true)
            addTeardownBlock { try? FileManager.default.removeItem(at: shelf) }
            let app = AppState()
            try await ExampleBook.open(in: app, at: shelf, lang: lang)
            let s = try XCTUnwrap(app.current)
            XCTAssertEqual(s.manifest.chapters.count, 17, lang)
            XCTAssertEqual(NoteStore.read(NoteStore.url(s.root, s.manifest.chapters[0].id)).count, 3, lang)
            XCTAssertTrue(s.bible.entries.contains { $0.title == "Weena" }, lang)
            XCTAssertEqual(s.milestones.count, 2, lang)
        }
    }

    /// What is said once is said for typing, not for a book that arrives with its words.
    func testNoticesComeFromTypingOnly() async throws {
        let d = UserDefaults.standard
        let keys = ["said.kept", "said.read"]
        let old = keys.map { d.object(forKey: $0) }
        defer { for (k, v) in zip(keys, old) { d.set(v, forKey: k) } }
        keys.forEach(d.removeObject)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("notice-\(UUID())/b", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let app = AppState()
        try await app.createBook(at: root, title: "B", author: "A", lang: "en", genre: nil, chapters: [PlannedChapter(title: "One", text: "# One\n\n")])
        let s = try XCTUnwrap(app.current)
        app.wordsChanged(from: 0, to: 25_000, in: s)
        XCTAssertNil(app.notice)
        app.wordsChanged(from: 20, to: 26, in: s)
        XCTAssertNotNil(app.notice)
        app.notice = nil
        app.wordsChanged(from: 26, to: 40, in: s)
        XCTAssertNil(app.notice, "said once")
        app.wordsChanged(from: 290, to: 301, in: s)
        XCTAssertEqual(app.notice?.action, .read)
    }
}
