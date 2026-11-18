import AppKit
import PDFKit
import XCTest
@testable import Musset

/// Each country's submission manuscript, exported through Typst and measured.
final class ManuscriptNormTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("musset-norm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func export(_ norm: ManuscriptNorm, lang: String, pseudonym: String? = nil) async throws -> PDFDocument {
        let sentence = "Elle arrivait avec le train de sept heures, une valise à la main et rien dans la tête. "
        let paragraphs = (0..<60).map { _ in String(repeating: sentence, count: 4) }.joined(separator: "\n\n")
        try "# Le quai\n\n\(paragraphs)\n".write(to: root.appendingPathComponent("quai.md"), atomically: true, encoding: .utf8)
        var m = BookManifest(title: "Le Sel", author: "Julie Martin", lang: lang, chapters: [ChapterEntry(id: "quai", file: "quai.md", title: "Le quai")])
        m.contact = "julie@example.com"
        var p = norm.preset
        p.pseudonym = pseudonym
        m.exports = [p]
        let store = BookStore(root: root)
        try store.saveManifest(m)
        let out = try await ExportService.export(manifest: m, store: store, preset: p)
        if let keep = ProcessInfo.processInfo.environment["MUSSET_KEEP_PDF"] {
            let dest = URL(fileURLWithPath: keep).appendingPathComponent("\(norm.rawValue).pdf")
            try? FileManager.default.removeItem(at: dest)
            try? FileManager.default.copyItem(at: out.file, to: dest)
        }
        return try XCTUnwrap(PDFDocument(url: out.file))
    }

    private func lines(_ doc: PDFDocument, page: Int) -> [String] {
        (doc.page(at: page)?.string ?? "").components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    func testNormseiteIsThirtyLinesOfSixty() async throws {
        let doc = try await export(.normseite, lang: "de-DE")
        let page = try XCTUnwrap(doc.page(at: 2))
        XCTAssertEqual(page.bounds(for: .mediaBox).width, 595, accuracy: 1, "A4")
        let body = lines(doc, page: 2).dropFirst()   // the running head
        XCTAssertEqual(body.count, 30, "a full Normseite: 30 lines")
        XCTAssertLessThanOrEqual(body.map(\.count).max() ?? 0, 60, "at most 60 characters a line")
        XCTAssertTrue(lines(doc, page: 0).joined().contains("Normseiten"), "the count on the title page")
    }

    /// The French manuscript: A4 in Garamond 12 pt, double spaced, still counted in feuillets.
    func testFrenchManuscriptIsGaramondOnA4() async throws {
        let doc = try await export(.feuillet, lang: "fr")
        let page = try XCTUnwrap(doc.page(at: 2))
        XCTAssertEqual(page.bounds(for: .mediaBox).width, 595, accuracy: 1, "A4")
        XCTAssertTrue(lines(doc, page: 0).joined().contains("feuillets"))
        let font = (page.attributedString?.attribute(.font, at: 40, effectiveRange: nil) as? NSFont)?.fontName ?? ""
        XCTAssertTrue(font.contains("Garamond"), font)
        let body = lines(doc, page: 2).dropFirst()
        XCTAssertGreaterThanOrEqual(body.count, 24)
        XCTAssertLessThanOrEqual(body.count, 28, "double spaced: about 26 lines on A4")
    }

    /// A book.json of an older Musset, which kept its own layouts in it (the manuscript under its former name).
    func testAnOldFrenchPresetTakesItsNewNameAndKeepsItsPseudonym() throws {
        let store = BookStore(root: root)
        try FileManager.default.createDirectory(at: store.mussetDir, withIntermediateDirectories: true)
        let old = #"""
        {"title":"Le Sel","author":"A","lang":"fr","contact":"","chapters":[],"formatVersion":1,"exports":[
          {"id":"manuscript-feuillet","name":"Manuscript in French pages (25 × 60)","format":"pdf","numberSections":true,"cropMarks":false,
           "includeContact":true,"extraArgs":[],"manuscript":"feuillet","pseudonym":"Lucrecia"}]}
        """#
        try Data(old.utf8).write(to: store.manifestURL)
        let m = try store.loadManifest()
        XCTAssertEqual(m.exports, [], "Musset's own layouts are no longer kept in the book")
        XCTAssertEqual(m.layoutSettings, ["manuscript-feuillet": .init(pseudonym: "Lucrecia")])
        let first = try XCTUnwrap(store.presets(m).first)
        XCTAssertEqual(first.name, "Manuscript for French publishers")
        XCTAssertEqual(first.pseudonym, "Lucrecia", "the author's settings stay")
        XCTAssertTrue(first.includeContact)
        // Set again from the export sheet, it is written with the book and read back.
        var changed = m
        changed.setPseudonym("Ariel", for: first.id)
        try store.saveManifest(changed)
        XCTAssertEqual(store.presets(try store.loadManifest()).first?.pseudonym, "Ariel")
        XCTAssertFalse(try String(contentsOf: store.manifestURL, encoding: .utf8).contains("\"name\""), "no layout is stored")
    }

    func testShunnOnLetterWithWordCountAndHeader() async throws {
        let doc = try await export(.shunnUS, lang: "en-US")
        let page = try XCTUnwrap(doc.page(at: 1))
        XCTAssertEqual(page.bounds(for: .mediaBox).width, 612, accuracy: 1, "US Letter")
        XCTAssertTrue(lines(doc, page: 0).joined(separator: " ").contains("about"), "word count on page one")
        XCTAssertTrue(lines(doc, page: 1).first?.contains("Martin / LE SEL / 2") == true, lines(doc, page: 1).first ?? "")
    }

    func testPseudonymHidesTheAuthor() async throws {
        let doc = try await export(.spanish, lang: "es-ES", pseudonym: "Lucrecia")
        let text = (0..<doc.pageCount).compactMap { doc.page(at: $0)?.string }.joined()
        XCTAssertTrue(text.contains("Lucrecia"))
        XCTAssertFalse(text.contains("Julie Martin"))
        XCTAssertFalse(text.contains("julie@example.com"))
    }

    /// Every language: its submission manuscript, a PDF for readers, a PDF for the printer at its market's trim.
    func testEachLanguageGetsThreePDFs() {
        XCTAssertEqual(ManuscriptNorm.for(.deCH), .normseite)
        XCTAssertEqual(ManuscriptNorm.for(.ptBR), .portugueseBR)
        for lang in BookLanguage.allCases {
            let pdfs = BookStore(root: root).builtInPresets(lang: lang.rawValue).filter { $0.format == .pdf }
            XCTAssertEqual(pdfs.map(\.id), [ManuscriptNorm.for(lang).preset.id, "reader", "print"], lang.rawValue)
            XCTAssertEqual(pdfs[1].facing, false)
            XCTAssertEqual(pdfs[2].facing, true)
            XCTAssertEqual(pdfs[2].interior, true)
            XCTAssertTrue(pdfs.dropFirst().allSatisfy { $0.typstStyle == "book" })
            // For readers: the Blanche page and type, on single pages.
            XCTAssertEqual(pdfs[1].paper, PagePaper(width: "120mm", height: "188mm"), lang.rawValue)
            XCTAssertEqual(pdfs[1].margins, PageMargins(inside: "17mm", outside: "17mm", top: "16mm", bottom: "20mm"), lang.rawValue)
            XCTAssertEqual(pdfs[1].fontSize, "10.8pt")
            XCTAssertEqual(pdfs[1].facing, false)
        }
        XCTAssertEqual(BookStore(root: root).builtInPresets(lang: "it-IT")[2].paper?.width, "140mm")
        XCTAssertEqual(BookStore(root: root).builtInPresets(lang: "en-US")[2].paper?.width, "5.5in")
        // Made for the book's language each time: a book that changes language changes page, with nothing to rewrite.
        var m = BookManifest(title: "T", lang: "it-IT", chapters: [])
        XCTAssertEqual(BookStore(root: root).presets(m).map(\.id), ["manuscript-cartella", "reader", "print", "docx", "epub"])
        m.lang = "en-US"
        XCTAssertEqual(BookStore(root: root).presets(m).first?.id, "manuscript-shunn-us")
        XCTAssertEqual(m.exports, [])
    }

    /// A book saved by an older Musset (the JSON as it wrote it: LaTeX geometry, engine, crop marks, built-in layouts
    /// kept in the file): its old layouts give way to the editions, and the author's own stay, with their page.
    func testOldPresetsAreRead() throws {
        let store = BookStore(root: root)
        try FileManager.default.createDirectory(at: store.mussetDir, withIntermediateDirectories: true)
        func preset(_ id: String, _ name: String, _ format: String, _ more: String = "") -> String {
            #"{"id":"\#(id)","name":"\#(name)","format":"\#(format)","numberSections":true,"cropMarks":false,"includeContact":false,"extraArgs":[]\#(more)}"#
        }
        let old = #"{"title":"T","author":"A","lang":"fr","contact":"","chapters":[],"formatVersion":1,"exports":["# + [
            preset("manuscript-feuillet", "Manuscript for French publishers", "pdf", #","manuscript":"feuillet""#),
            preset("blanche", "Book 120×188 (your Blanche template)", "pdf", #","template":"templates/template-blanche.tex","engine":"latex""#),
            preset("book-a5", "Book A5", "pdf", #","template":"templates/template-classique.tex""#),
            preset("reader", "PDF for readers", "pdf", #","style":"book","geometry":"paperwidth=120mm,paperheight=188mm,inner=17mm,outer=17mm,top=16mm,bottom=20mm","fontSize":"10.8pt","facing":false"#),
            preset("mine", "Mine", "pdf", #","template":"templates/template-classique.tex","geometry":"paperwidth=100mm,paperheight=150mm,inner=12mm,outer=9mm,top=10mm","fontSize":"9pt","engine":"typst""#),
            preset("mine-blanche", "My Blanche", "pdf", #","template":"templates/template-blanche.tex""#),
            preset("docx", "Word (.docx)", "docx"),
            preset("agent", "Word for my agent", "docx", #","template":"templates/agent.docx""#),
        ].joined(separator: ",") + "]}"
        try Data(old.utf8).write(to: store.manifestURL)
        let loaded = try store.loadManifest()
        XCTAssertEqual(loaded.exports.map(\.id), ["mine", "mine-blanche", "agent"], "only the author's own are kept")
        XCTAssertEqual(store.presets(loaded).map(\.id), ["manuscript-feuillet", "reader", "print", "mine", "mine-blanche", "agent", "docx", "epub"])
        let mine = try XCTUnwrap(loaded.exports.first)
        XCTAssertEqual(mine.typstStyle, "fullpage")
        XCTAssertNil(mine.template, "the LaTeX template only said the style")
        XCTAssertEqual(mine.paper, PagePaper(width: "100mm", height: "150mm"))
        XCTAssertEqual(mine.margins, PageMargins(inside: "12mm", outside: "9mm", top: "10mm"))
        XCTAssertEqual(loaded.exports[1].typstStyle, "book")
        XCTAssertEqual(loaded.exports[2].template, "templates/agent.docx")
        // The page Typst is given is the one the geometry string described.
        let layout = try Typesetting.source(manifest: loaded, store: store, preset: mine).layout
        XCTAssertEqual(layout.paper, ["100mm", "150mm"])
        XCTAssertEqual(layout.margins, ["inside": "12mm", "outside": "9mm", "top": "10mm"])
        XCTAssertEqual(layout.size, "9pt")
        // Loading changes nothing on disk; saved, the book holds the new form, which reads back the same, and which
        // a Musset from before can still decode (it needs `cropMarks`).
        XCTAssertEqual(try String(contentsOf: store.manifestURL, encoding: .utf8), old)
        try store.saveManifest(loaded)
        let written = try String(contentsOf: store.manifestURL, encoding: .utf8)
        XCTAssertFalse(written.contains("geometry")); XCTAssertFalse(written.contains("engine")); XCTAssertFalse(written.contains(".tex"))
        XCTAssertTrue(written.contains("\"cropMarks\" : false"))
        XCTAssertEqual(try store.loadManifest(), loaded, "loading again changes nothing")
        XCTAssertEqual(ExportPreset(id: "x", name: "X", format: .pdf, style: "blanche").typstStyle, "book")
        XCTAssertEqual(ExportPreset(id: "x", name: "X", format: .pdf, style: "classique").typstStyle, "fullpage")
    }

    /// Word or EPUB changed by hand in book.json is the author's, and stands in place of Musset's.
    func testABuiltInChangedByHandIsTheAuthors() throws {
        let store = BookStore(root: root)
        var m = BookManifest(title: "T", lang: "fr", chapters: [])
        m.exports = [ExportPreset(id: "docx", name: "Word (.docx)", format: .docx, extraArgs: ["--toc"]),
                     ExportPreset(id: "epub", name: "EPUB", format: .epub, template: "templates/gone.css", numberSections: false)]
        try store.saveManifest(m)
        let loaded = try store.loadManifest()
        XCTAssertEqual(loaded.exports.map(\.id), ["docx"])
        XCTAssertEqual(store.presets(loaded).filter { $0.format != .pdf }.map(\.extraArgs), [["--toc"], []])
    }

    func testBookTermsFollowTheBook() {
        XCTAssertEqual(BookTerm.acknowledgements.in("de-CH"), "Danksagung")
        XCTAssertEqual(BookTerm.acknowledgements.in("en-US"), "Acknowledgments")
        XCTAssertEqual(BookTerm.acknowledgements.in("en-GB"), "Acknowledgements")
        XCTAssertEqual(BookTerm.contents.in("fr"), "Table")
    }
}
