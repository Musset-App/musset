import XCTest
@testable import Musset

@MainActor
final class WordReviewTests: XCTestCase {
    private var root: URL!
    let chapterA = "# Le grenier\n\nJe me souviens de la *vieille* malle sous la fenêtre.\n\nLe bruit de la pluie sur le toit, l’odeur du bois[^1].\n\n<!-- scene: Dehors -->\n\nLe facteur est passé vers midi, sous un grand parapluie noir.\n\n[^1]: Les poutres de chêne.\n"
    let chapterB = "# Le port\n\nLe ciel était bas ce jour-là, et personne ne parlait.\n\nUn deuxième paragraphe qu’on supprimera tout entier.\n\nUn troisième paragraphe qui reste.\n"

    override func setUpWithError() throws {
        try XCTSkipIf(ExportService.pandoc == nil, "pandoc is needed")
        root = FileManager.default.temporaryDirectory.appendingPathComponent("musset-word-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try chapterA.write(to: root.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
        try chapterB.write(to: root.appendingPathComponent("b.md"), atomically: true, encoding: .utf8)
    }
    override func tearDownWithError() throws { if let root { try? FileManager.default.removeItem(at: root) } }

    private func session() throws -> BookSession {
        let git = GitService(root: root)
        try git.initRepo()
        var m = BookManifest(title: "Le Sel", author: "Jeanne Martin", chapters: [ChapterEntry(id: "a", file: "a.md", title: "Le grenier"), ChapterEntry(id: "b", file: "b.md", title: "Le port")])
        m.sceneBreak = .asterism
        m.exports = [ExportPreset(id: "docx", name: "Word", format: .docx)]
        try BookStore(root: root).saveManifest(m)
        _ = try git.commit(paths: ["a.md", "b.md", ".musset"], message: "start")
        return BookSession(root: root, manifest: m)
    }

    private func unzip(_ file: URL) async throws -> URL {
        let dir = root.appendingPathComponent("x-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let r = try await Shell.runAsync("/usr/bin/unzip", ["-q", file.path, "-d", dir.path])
        XCTAssertTrue(r.ok, r.stderr)
        return dir
    }

    private func zip(_ dir: URL, to out: URL) async throws {
        let r = try await Shell.runAsync("/usr/bin/zip", ["-q", "-X", "-r", out.path, "[Content_Types].xml", "."], cwd: dir)
        XCTAssertTrue(r.ok, r.stderr)
    }

    private func exportDocx(_ s: BookSession) async throws -> URL {
        try await ExportService.export(manifest: s.manifest, store: s.store, preset: s.manifest.exports[0]).file
    }

    private let ins = #"w:id="900" w:author="Marie Dupont" w:date="2026-11-05T10:00:00Z""#
    private let del = #"w:id="901" w:author="Marie Dupont" w:date="2026-11-05T10:00:00Z""#

    func testExportFollowsPublishingConventions() async throws {
        let s = try session()
        let dir = try await unzip(try exportDocx(s))
        let doc = try String(contentsOf: dir.appendingPathComponent("word/document.xml"), encoding: .utf8)
        let styles = try String(contentsOf: dir.appendingPathComponent("word/styles.xml"), encoding: .utf8)
        let settings = try String(contentsOf: dir.appendingPathComponent("word/settings.xml"), encoding: .utf8)
        // Everything an editor does is tracked from the first keystroke.
        XCTAssertTrue(settings.contains("<w:trackRevisions"))
        XCTAssertLessThan(settings.range(of: "<w:trackRevisions")!.lowerBound, settings.range(of: "<w:defaultTabStop")!.lowerBound, "schema order")
        // A4, one page setting, running header and page number.
        XCTAssertEqual(doc.components(separatedBy: "<w:sectPr").count, 2)
        XCTAssertTrue(doc.contains(#"w:w="11906" w:h="16838""#))
        XCTAssertTrue(try String(contentsOf: dir.appendingPathComponent("word/header1.xml"), encoding: .utf8).contains("Jeanne Martin — Le Sel"))
        XCTAssertTrue(try String(contentsOf: dir.appendingPathComponent("word/footer1.xml"), encoding: .utf8).contains("PAGE"))
        // Times 12, the book's language, one and a half lines, no colour.
        XCTAssertTrue(styles.contains(#"w:ascii="Times New Roman""#))
        XCTAssertTrue(styles.contains(#"<w:lang w:val="fr-FR""#))
        XCTAssertTrue(styles.contains(#"w:line="360""#))
        XCTAssertFalse(styles.contains("<w:color "))
        for name in ["Saut de scène", "Texte sans retrait", "Dédicace", "Exergue", "Citation"] { XCTAssertTrue(styles.contains(#"w:val="\#(name)""#), name) }
        // Semantic marks, not manual layout.
        XCTAssertTrue(doc.contains(#"<w:rStyle w:val="Emphasis" />"#))
        XCTAssertFalse(doc.contains("<w:i />"))
        XCTAssertTrue(doc.contains(#"<w:pStyle w:val="SceneBreak" />"#))
        // After a scene break, the paragraph sits flush.
        let after = doc.components(separatedBy: #"<w:pStyle w:val="SceneBreak" />"#)[1]
        XCTAssertLessThan(after.range(of: #"w:val="FirstParagraph""#)!.lowerBound, after.range(of: "</w:body>")!.lowerBound)
        XCTAssertFalse(after.prefix(400).contains(#"w:val="BodyText""#))
        // Chapter marks in the file, and what was sent kept in the book.
        let sent = WordManuscript.allSent(root: root)
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent[0].chapters, ["a", "b"])
        XCTAssertEqual(Set(sent[0].main.compactMap(\.chapter)), ["a", "b"])
        XCTAssertEqual(sent[0].notes.first?.chapter, "a")
        // The lone space between a word in italics and the next is text like any other.
        XCTAssertTrue(sent[0].main.contains { $0.text.hasPrefix("Je me souviens de la vieille malle") }, "\(sent[0].main.map(\.text))")
        XCTAssertTrue(try String(contentsOf: dir.appendingPathComponent("docProps/custom.xml"), encoding: .utf8).contains(sent[0].id))
    }

    /// Word writes what the editor did; Musset gives it back as corrections and notes, even on a text that moved on.
    func testRoundTripWithTrackedChangesAndComments() async throws {
        let s = try session()
        let out = try await exportDocx(s)
        let dir = try await unzip(out)
        let url = dir.appendingPathComponent("word/document.xml")
        var xml = try String(contentsOf: url, encoding: .utf8)
        func edit(_ a: String, _ b: String, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertTrue(xml.contains(a), a, file: file, line: line)
            xml = xml.replacingOccurrences(of: a, with: b)
        }
        // A tracked replacement, in the middle of a run.
        edit(#"<w:r><w:t xml:space="preserve">Le facteur est passé vers midi, sous un grand parapluie noir.</w:t></w:r>"#,
             #"<w:r><w:t xml:space="preserve">Le facteur est passé vers midi, sous un grand </w:t></w:r><w:del \#(del)><w:r><w:delText xml:space="preserve">parapluie</w:delText></w:r></w:del><w:ins \#(ins)><w:r><w:t>chapeau</w:t></w:r></w:ins><w:r><w:t xml:space="preserve"> noir.</w:t></w:r>"#)
        // A comment on a passage.
        edit(#"<w:r><w:t xml:space="preserve">Le ciel était bas ce jour-là, et personne ne parlait.</w:t></w:r>"#,
             #"<w:r><w:t xml:space="preserve">Le ciel était </w:t></w:r><w:commentRangeStart w:id="7"/><w:r><w:t>bas ce jour-là</w:t></w:r><w:commentRangeEnd w:id="7"/><w:r><w:commentReference w:id="7"/></w:r><w:r><w:t xml:space="preserve">, et personne ne parlait.</w:t></w:r>"#)
        // A whole paragraph taken out, its mark too.
        edit(#"<w:p><w:pPr><w:pStyle w:val="BodyText" /></w:pPr><w:r><w:t xml:space="preserve">Un deuxième paragraphe qu’on supprimera tout entier.</w:t></w:r></w:p>"#,
             #"<w:p><w:pPr><w:pStyle w:val="BodyText" /><w:rPr><w:del \#(del)/></w:rPr></w:pPr><w:del \#(del)><w:r><w:delText>Un deuxième paragraphe qu’on supprimera tout entier.</w:delText></w:r></w:del></w:p>"#)
        // Word's own tracked move out of the end.
        try xml.write(to: url, atomically: true, encoding: .utf8)
        let comments = #"<?xml version="1.0"?><w:comments xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:w14="http://schemas.microsoft.com/office/word/2010/wordml"><w:comment w:id="7" w:author="Marie Dupont" w:date="2026-11-05T10:00:00Z"><w:p w14:paraId="00000001"><w:r><w:t>Trop attendu ?</w:t></w:r></w:p></w:comment></w:comments>"#
        try comments.write(to: dir.appendingPathComponent("word/comments.xml"), atomically: true, encoding: .utf8)
        let back = root.appendingPathComponent("relu.docx")
        try await zip(dir, to: back)

        // Meanwhile the author wrote on: a new first sentence, chapter B untouched.
        s.open("a")
        s.replaceText("# Le grenier\nUne phrase toute neuve.\nJe me souviens de la *vieille* malle sous la fenêtre.\nLe bruit de la pluie sur le toit, l’odeur du bois[^1].\n<!-- scene: Dehors -->\nLe facteur est passé vers midi, sous un grand parapluie noir.\n[^1]: Les poutres de chêne.\n")
        let plan = try await s.wordReviewPlan(back)
        XCTAssertEqual(plan.sent?.chapters, ["a", "b"])
        XCTAssertEqual(plan.readers.keys.sorted(), ["Marie Dupont"])
        XCTAssertEqual(plan.unplaced, 0, "\(plan.chapters.map(\.unplaced))")
        XCTAssertEqual(plan.placed, 2)
        XCTAssertEqual(plan.noteCount, 1)
        let before = (a: s.editorText(of: "a"), b: s.editorText(of: "b"))
        XCTAssertEqual(s.editorText(of: "a"), before.a, "planning changes nothing")

        s.applyWordReview(plan, sender: "Jean")
        let a = s.editorText(of: "a"), b = s.editorText(of: "b")
        XCTAssertTrue(a.contains("Une phrase toute neuve."), "the author's new text stays")
        XCTAssertTrue(a.contains("sous un grand {~~parapluie~>chapeau~~}{@Jean} noir."), a)
        XCTAssertEqual(Revisions.resolveAll(a, accept: false), before.a, "refusing everything gives the author's text back")
        XCTAssertEqual(Revisions.resolveAll(b, accept: false), before.b)
        XCTAssertFalse(Revisions.resolveAll(b, accept: true).contains("supprimera"), b)
        XCTAssertFalse(Revisions.resolveAll(b, accept: true).contains("\n\n"), "no empty paragraph left: \(b)")
        // The comment is a note on its passage, signed.
        let notes = s.notes.notes(of: "b")
        XCTAssertEqual(notes.count, 1)
        XCTAssertEqual(notes[0].kind, .question)
        XCTAssertEqual(notes[0].source, "Jean")
        XCTAssertTrue(notes[0].body.contains("**Marie Dupont**"), "a second name inside the file stays: \(notes[0].body)")
        // The source survives the note's file.
        XCTAssertEqual(NoteStore.read(NoteStore.url(root, "b")).first?.source, "Jean")
        // Accepting one of Jean's from the list, in a chapter not open: only that one goes.
        let pending = Revisions.pending(in: b, chapter: "b")
        XCTAssertEqual(pending.map(\.source), ["Jean"])
        XCTAssertEqual(notes[0].anchor.quote, "bas ce jour-là")
        XCTAssertFalse(notes[0].orphaned)
        // A milestone to come back to, and the disk as it should be.
        XCTAssertTrue(s.jalons.contains { $0.id.hasPrefix("jalon/avant-les-corrections") })
        XCTAssertTrue(try String(contentsOf: root.appendingPathComponent("b.md"), encoding: .utf8).contains("{--"))

        // Twice: nothing added, and the sheet knows.
        let again = try await s.wordReviewPlan(back)
        XCTAssertNotNil(again.previousImport)
        XCTAssertEqual(again.placed, 0, "\(again.chapters.map(\.text))")
        s.applyWordReview(again, sender: "Jean")
        XCTAssertEqual(s.notes.notes(of: "b").count, 1, "stable ids")
    }

    func testUntrackedEditsItalicsAndNewParagraphAreCaught() async throws {
        let s = try session()
        let dir = try await unzip(try exportDocx(s))
        let url = dir.appendingPathComponent("word/document.xml")
        var xml = try String(contentsOf: url, encoding: .utf8)
        // Change tracking switched off: the words simply differ.
        xml = xml.replacingOccurrences(of: "Un troisième paragraphe qui reste.", with: "Un troisième paragraphe qui demeure.")
        // A word put in italics.
        let a = #"<w:r><w:t xml:space="preserve">Le ciel était bas ce jour-là, et personne ne parlait.</w:t></w:r>"#
        XCTAssertTrue(xml.contains(a))
        xml = xml.replacingOccurrences(of: a, with: #"<w:r><w:t xml:space="preserve">Le </w:t></w:r><w:r><w:rPr><w:i/></w:rPr><w:t>ciel</w:t></w:r><w:r><w:t xml:space="preserve"> était bas ce jour-là, et personne ne parlait.</w:t></w:r>"#)
        try xml.write(to: url, atomically: true, encoding: .utf8)
        let back = root.appendingPathComponent("sans-suivi.docx")
        try await zip(dir, to: back)
        let plan = try await s.wordReviewPlan(back)
        s.applyWordReview(plan, sender: "Jean")
        let b = s.editorText(of: "b")
        XCTAssertTrue(b.contains("qui {~~reste~>demeure~~}{@Jean}."), b)
        XCTAssertTrue(b.contains("{~~ciel~>*ciel*~~}{@Jean}"), b)
    }

    func testFoldFindsWordTextInMarkdown() {
        let f = FoldedText("# Titre {.unnumbered}\nUn *mot* en [lien](http://x) ; l'ami -- fin...\\* et [^1] note.\n<!-- scene: A -->\nSuite\u{00A0}: là.")
        let page = f.text as String
        XCTAssertTrue(page.hasPrefix("Titre Un mot en lien ; l'ami – fin…* et \u{FFFC} note. Suite : là."), page)
        let at = f.find(FoldedText.plain("mot en lien"), from: 0)!
        let r = f.sourceRange(foldedLocation: at, length: "mot en lien".utf16.count)
        XCTAssertEqual((("# Titre {.unnumbered}\nUn *mot* en [lien](http://x) ; l'ami" as NSString).substring(with: r)), "mot* en [lien")
    }

    func testMultilineMarksResolve() {
        let t = "Un.\n{--Deux.\n--}Trois.\n{++Quatre.\n++}Cinq."
        XCTAssertEqual(Revisions.resolveAll(t, accept: true), "Un.\nTrois.\nQuatre.\nCinq.")
        XCTAssertEqual(Revisions.resolveAll(t, accept: false), "Un.\nDeux.\nTrois.\nCinq.")
        XCTAssertEqual(Revisions.refusingMultiline(t), "Un.\nDeux.\nTrois.\nCinq.")
    }

    func testReaderHandlesWordsOwnShapes() throws {
        let dir = root.appendingPathComponent("hand")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("word"), withIntermediateDirectories: true)
        let w = #"xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:w14="http://schemas.microsoft.com/office/word/2010/wordml" xmlns:w15="http://schemas.microsoft.com/office/word/2012/wordml""#
        try #"<w:document \#(w)><w:body><w:p><w:r><w:t>Déplacé </w:t></w:r><w:moveFrom w:id="1" w:author="A"><w:r><w:t>loin</w:t></w:r></w:moveFrom></w:p><w:p><w:pPr><w:rPr><w:ins w:id="2" w:author="A"/></w:rPr></w:pPr><w:r><w:t>Coupé</w:t></w:r></w:p><w:p><w:r><w:t>en deux</w:t></w:r><w:moveTo w:id="3" w:author="A"><w:r><w:t> loin</w:t></w:r></w:moveTo></w:p><w:p><w:commentRangeStart w:id="1"/><w:r><w:rPr><w:rStyle w:val="Accentuation"/></w:rPr><w:t>Ital</w:t></w:r><w:r><w:rPr><w:i w:val="0"/></w:rPr><w:t> rom</w:t></w:r><w:commentRangeEnd w:id="1"/></w:p></w:body></w:document>"#.write(to: dir.appendingPathComponent("word/document.xml"), atomically: true, encoding: .utf8)
        try #"<w:styles \#(w)><w:style w:type="character" w:styleId="Accentuation"><w:rPr><w:i/></w:rPr></w:style></w:styles>"#.write(to: dir.appendingPathComponent("word/styles.xml"), atomically: true, encoding: .utf8)
        try #"<w:comments \#(w)><w:comment w:id="1" w:author="A"><w:p w14:paraId="AA"><w:r><w:t>Question ?</w:t></w:r></w:p></w:comment><w:comment w:id="2" w:author="B"><w:p w14:paraId="BB"><w:r><w:t>Réponse.</w:t></w:r></w:p></w:comment></w:comments>"#.write(to: dir.appendingPathComponent("word/comments.xml"), atomically: true, encoding: .utf8)
        try #"<w15:commentsEx \#(w)><w15:commentEx w15:paraId="AA" w15:done="1"/><w15:commentEx w15:paraId="BB" w15:paraIdParent="AA"/></w15:commentsEx>"#.write(to: dir.appendingPathComponent("word/commentsExtended.xml"), atomically: true, encoding: .utf8)
        let doc = try DocxContent.read(dir: dir)
        XCTAssertEqual(doc.accepted.map(\.text), ["Déplacé ", "Coupé", "en deux loin", "Ital rom"])
        XCTAssertEqual(doc.rejected.map(\.text), ["Déplacé loin", "Coupéen deux", "Ital rom"])
        XCTAssertEqual(doc.accepted[3].runs.first?.format, .italic)
        XCTAssertEqual(doc.accepted[3].runs.last?.format, [])
        XCTAssertEqual(doc.comments.count, 2)
        XCTAssertEqual(doc.comments[0].quote, "Ital rom")
        XCTAssertTrue(doc.comments[0].done)
        XCTAssertEqual(doc.comments[1].parent, "1")
        XCTAssertTrue(doc.hasRevisions)
    }

    /// The real book, copied: an untouched file brings nothing, and changes all through it land where they should.
    func testOnTheRealBook() async throws {
        // Read only: the chapters are copied. Not MUSSET_CONATUS_COPY, which another test migrates in place.
        let source = ProcessInfo.processInfo.environment["MUSSET_WORD_BOOK"] ?? ""
        try XCTSkipIf(source.isEmpty, "set TEST_RUNNER_MUSSET_WORD_BOOK")
        let book = root.appendingPathComponent("conatus")
        try FileManager.default.createDirectory(at: book, withIntermediateDirectories: true)
        let fm = FileManager.default
        let from = URL(fileURLWithPath: source)
        var manifest = try BookStore(root: from).loadManifest()
        for ch in manifest.chapters { try fm.copyItem(at: from.appendingPathComponent(ch.file), to: book.appendingPathComponent(ch.file)) }
        manifest.exports = [ExportPreset(id: "docx", name: "Word", format: .docx)]
        try BookStore(root: book).saveManifest(manifest)
        let git = GitService(root: book)
        try git.initRepo()
        _ = try git.commit(paths: manifest.chapters.map(\.file) + [".musset"], message: "start")
        let s = BookSession(root: book, manifest: manifest)
        let start = Date()
        let out = try await ExportService.export(manifest: s.manifest, store: s.store, preset: s.manifest.exports[0]).file
        print("WORDTEST export", Date().timeIntervalSince(start), "s", (try? fm.attributesOfItem(atPath: out.path)[.size]) ?? 0, "bytes")
        let sent = WordManuscript.allSent(root: book)[0]
        print("WORDTEST paragraphs", sent.main.count, "notes", sent.notes.count, "unassigned", sent.main.filter { $0.chapter == nil }.count, "json", (try? fm.attributesOfItem(atPath: WordManuscript.directory(book).appendingPathComponent(sent.id + ".json").path)[.size]) ?? 0)

        let t0 = Date()
        let untouched = try await s.wordReviewPlan(out)
        print("WORDTEST plan", Date().timeIntervalSince(t0), "s")
        XCTAssertEqual(untouched.placed, 0)
        XCTAssertEqual(untouched.unplaced, 0)
        XCTAssertEqual(untouched.noteCount, 0)

        // Every thirtieth paragraph of prose: one word changed, a word removed further on, in tracked form.
        let dir = root.appendingPathComponent("edited")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        _ = try await Shell.runAsync("/usr/bin/unzip", ["-q", out.path, "-d", dir.path])
        let url = dir.appendingPathComponent("word/document.xml")
        var xml = try String(contentsOf: url, encoding: .utf8)
        let re = try NSRegularExpression(pattern: #"<w:r><w:t xml:space="preserve">([^<]{120,})</w:t></w:r>"#)
        let ns = xml as NSString
        var changed = 0, n = 0
        var expected: [String] = []
        let tag = #"w:id="9" w:author="Relecteur" w:date="2026-11-05T10:00:00Z""#
        for m in re.matches(in: xml, range: NSRange(location: 0, length: ns.length)).reversed() {
            n += 1
            guard n % 30 == 0 else { continue }
            let text = ns.substring(with: m.range(at: 1))
            let words = text.components(separatedBy: " ")
            guard words.count > 20, let i = (5..<words.count - 5).first(where: { words[$0].count >= 4 && words[$0].allSatisfy(\.isLetter) }) else { continue }
            let head = words[..<i].joined(separator: " ") + " ", tail = " " + words[(i + 1)...].joined(separator: " ")
            let run = "<w:r><w:t xml:space=\"preserve\">\(head)</w:t></w:r><w:del \(tag)><w:r><w:delText>\(words[i])</w:delText></w:r></w:del><w:ins \(tag)><w:r><w:t>zzmot</w:t></w:r></w:ins><w:r><w:t xml:space=\"preserve\">\(tail)</w:t></w:r>"
            xml = (xml as NSString).replacingCharacters(in: m.range, with: run)
            expected.append(words[i])
            changed += 1
        }
        try xml.write(to: url, atomically: true, encoding: .utf8)
        let back = root.appendingPathComponent("relu.docx")
        _ = try await Shell.runAsync("/usr/bin/zip", ["-q", "-X", "-r", back.path, "[Content_Types].xml", "."], cwd: dir)
        let before = s.manifest.chapters.map { s.editorText(of: $0.id) }
        let plan = try await s.wordReviewPlan(back)
        print("WORDTEST changed", changed, "placed", plan.placed, "unplaced", plan.unplaced, plan.chapters.flatMap(\.unplaced).prefix(10))
        XCTAssertEqual(plan.placed + plan.unplaced, changed)
        XCTAssertGreaterThanOrEqual(plan.placed * 100, changed * 98)
        s.applyWordReview(plan, sender: "Jean")
        for (i, ch) in s.manifest.chapters.enumerated() {
            XCTAssertEqual(Revisions.resolveAll(s.editorText(of: ch.id), accept: false), before[i], ch.id)
        }
        let all = s.manifest.chapters.map { s.editorText(of: $0.id) }.joined()
        XCTAssertEqual(all.components(separatedBy: "~>zzmot~~}{@Jean}").count - 1, plan.placed)
    }

    func testSourceTravelsWithTheMarkAndDecidesOneAtATime() {
        let t = "Un {~~a~>b~~}{@Jean} deux {++c++}{@Paul} trois {--d--} fin."
        XCTAssertEqual(Revisions.pending(in: t, chapter: "x").map(\.source), ["Jean", "Paul", nil])
        XCTAssertEqual(Revisions.resolveAll(t, accept: true), "Un b deux c trois  fin.")
        XCTAssertEqual(Revisions.resolveAll(t, accept: false), "Un a deux  trois d fin.")
        // Only Jean's.
        let jean = Revisions.resolve(t, accept: true) { Revisions.sourceName($0, in: t) == "Jean" }
        XCTAssertEqual(jean, "Un b deux {++c++}{@Paul} trois {--d--} fin.")
        // The name never shows.
        let hidden = Revisions.hidden(in: t).map { (t as NSString).substring(with: $0) }.joined()
        XCTAssertTrue(hidden.contains("{@Jean}"))
        XCTAssertEqual(Revisions.sourceTag(" Jean {x}\n"), "{@Jean  x}")
        XCTAssertEqual(Revisions.sourceTag("  "), "")
    }

    /// With real Word in the loop: the first run exports to MUSSET_WORD_REAL, the second reads back `relu.docx` from there.
    func testWithRealWord() async throws {
        let path = ProcessInfo.processInfo.environment["MUSSET_WORD_REAL"] ?? ""
        try XCTSkipIf(path.isEmpty, "set TEST_RUNNER_MUSSET_WORD_REAL")
        let keep = URL(fileURLWithPath: path)
        let book = keep.appendingPathComponent("book")
        let back = keep.appendingPathComponent("relu.docx")
        if !FileManager.default.fileExists(atPath: book.path) {
            try FileManager.default.createDirectory(at: book, withIntermediateDirectories: true)
            try chapterA.write(to: book.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
            try chapterB.write(to: book.appendingPathComponent("b.md"), atomically: true, encoding: .utf8)
            root = book
            let s = try session()
            let out = try await exportDocx(s)
            try FileManager.default.copyItem(at: out, to: keep.appendingPathComponent("export.docx"))
            root = keep.appendingPathComponent("unused")
            return
        }
        root = keep.appendingPathComponent("unused")
        let m = try BookStore(root: book).loadManifest()
        let s = BookSession(root: book, manifest: m)
        let plan = try await s.wordReviewPlan(back)
        print("WORDREAL sent", plan.sent?.id ?? "nil", "readers", plan.readers, "placed", plan.placed, "unplaced", plan.chapters.flatMap(\.unplaced), "notes", plan.noteCount)
        s.applyWordReview(plan, sender: "Jean")
        for ch in m.chapters { print("WORDREAL \(ch.id):", s.editorText(of: ch.id).replacingOccurrences(of: "\n", with: " ⏎ ")) }
        for n in s.notes.notes(of: "a") + s.notes.notes(of: "b") + s.notes.notes(of: NoteStore.bookPage) { print("WORDREAL note:", n.source ?? "", "|", n.body, "|", n.anchor.quote, "| orphan", n.orphaned) }
        for ch in m.chapters {
            XCTAssertEqual(Revisions.resolveAll(s.editorText(of: ch.id), accept: false), ParagraphCodec.decode(ch.id == "a" ? chapterA : chapterB))
        }
    }
}
