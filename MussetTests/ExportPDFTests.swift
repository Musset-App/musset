import MussetPage
import PDFKit
import XCTest
@testable import Musset

/// Sample books for the PDF export: a French novel with parts and every special page, an English manuscript,
/// a German one, a book with its own template from before the styles were renamed.
enum ExportSamples {
    static let para = "Il marchait le long du quai, sans hâte, regardant les péniches et les pêcheurs qui ne prenaient rien ; la ville, derrière lui, s’éveillait à peine, et il se demanda « pourquoi maintenant ? » sans trouver de réponse. "

    static func write(_ root: URL, _ m: BookManifest, _ texts: [String: String]) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for ch in m.chapters { try (texts[ch.id] ?? "").write(to: root.appendingPathComponent(ch.file), atomically: true, encoding: .utf8) }
        try BookStore(root: root).saveManifest(m)
    }

    /// Everything Musset's Markdown can hold: scenes, quotes, footnotes, notes to self, pending corrections, lists,
    /// links, the LaTeX blocks of old books, a sentence that starts with a year.
    static func frenchNovel(_ root: URL, cover: FrontMatter.Cover = .init(genre: "roman", publisher: "Éditions du Quai")) throws -> BookManifest {
        var m = BookManifest(title: "Le Sel & l’Écume", author: "Jeanne Martin", lang: "fr-FR", chapters: [
            ChapterEntry(id: "01", file: "01.md", title: "Le port", part: "P1"),
            ChapterEntry(id: "02", file: "02.md", title: "La malle", part: "P1"),
            ChapterEntry(id: "03", file: "03.md", title: "Écarté", excludeFromExport: true, part: "P1"),
            ChapterEntry(id: "04", file: "04.md", title: "Nice", part: "P2"),
            ChapterEntry(id: "05", file: "05.md", title: "Retour")])
        m.subtitle = "roman d’un été"
        m.contact = "jeanne@example.org"
        m.parts = [BookPart(id: "P1", title: ""), BookPart(id: "P2", title: "La fuite")]
        m.sceneBreak = .asterism
        m.front = FrontMatter(cover: cover, titlePage: true, dedication: "À ceux qui restent,\net à ceux qui partent.",
                              epigraph: "Chaque chose, autant qu’il est en elle,\ns’efforce de persévérer dans son être.", epigraphSource: "Spinoza, *Éthique*, III",
                              contents: true, acknowledgements: "Merci à Louise.\nEt à Paul.\n\nMerci aussi au *Café du Port*.", colophon: true)
        let long = String(repeating: para, count: 9)
        try write(root, m, [
            "01": "# Le port\n\n<!-- scene: Le quai -->\n\(long)\n\n— Tu viens ? demanda-t-elle.\n\n\(long)\n\n<!-- scene: La nuit -->\n1943. Barcelone. \(long)\n\nLe Kawai^[Un quart de queue, *noir*, acheté à crédit.] trônait dans le salon.\n\n> *Vacuité de la mode – 2004*  \n> *Métal sur métal*\\\n> une suite\n\n\(long)\n",
            "02": "# La malle\n\nIl {++faisait ++}chaud. {--Très chaud.--}{>>À revoir<<} Un {~~vieux~>neuf~~} parapluie.\n\n<!-- une note\nsur deux lignes -->\n\(long)\n\n* * *\n\n- du pain\n- du **sel**\n\nVoir [le site](https://example.org/a_b) et `code_brut`, a -- b / c, #1 $5 @x <a> [b] ~ 1_000.\n\n\\begin{center}\n\\emph{Centré}, \\textsc{petites capitales}\n\\end{center}\n\n\\vspace{2em}\n\n\(long)\n",
            "03": "# Écarté\n\nCe chapitre ne s’imprime pas.\n",
            "04": "# Nice\n\n<!-- scene: La plage -->\n\(long)\n\n<!-- scene: L’hôtel -->\n\(long)\n\nUne ligne\u{2028}et sa suite dans le même paragraphe.\n\n\(long)\n",
            "05": "# Retour\n\n\(long)\n\n\\newpage\n\n\(long)\n"])
        return m
    }

    static func englishManuscript(_ root: URL) throws -> BookManifest {
        var m = BookManifest(title: "The Salt Road", author: "Mara A. Fenwick", lang: "en-US", chapters: [
            ChapterEntry(id: "01", file: "01.md", title: "The Ferry"), ChapterEntry(id: "02", file: "02.md", title: "The Salt Works")])
        m.contact = "Mara A. Fenwick\n12 Harbour Row\nmara@example.org"
        m.sceneBreak = .blank
        let p = "Tom came down to the ferry before light, his boots loud on the planks, and nobody \"asked\" him why -- not even Old Pellow. "
        try write(root, m, ["01": "# The Ferry\n\n<!-- scene: Dawn -->\n" + String(repeating: p, count: 14) + "\n\n<!-- scene: Noon -->\n" + String(repeating: p, count: 14) + "\n",
                            "02": "# The Salt Works\n\n" + String(repeating: p, count: 20) + "\n\n*He said nothing.*\n"])
        return m
    }

    static func germanManuscript(_ root: URL) throws -> BookManifest {
        var m = BookManifest(title: "Die Salzstraße", author: "Greta Vogel", lang: "de-DE", chapters: [
            ChapterEntry(id: "01", file: "01.md", title: "Die Fähre"), ChapterEntry(id: "02", file: "02.md", title: "Das Salzwerk")])
        m.contact = "greta@example.org"
        m.parts = [BookPart(id: "P1", title: "Aufbruch")]
        m.chapters[0].part = "P1"
        let p = "Er ging langsam am Kai entlang, ohne Eile, und sah den Kähnen zu, während hinter ihm die Stadt „erwachte“ – größer, lauter, fremder als früher. "
        try write(root, m, ["01": "# Die Fähre\n\n" + String(repeating: p, count: 16) + "\n", "02": "# Das Salzwerk\n\n" + String(repeating: p, count: 12) + "\n"])
        return m
    }

    /// A book that keeps its own `templates/musset.typ`, written when the styles were « blanche » and « classique »,
    /// and its own layout from the LaTeX days.
    static func ownTemplate(_ root: URL) throws -> BookManifest {
        let shipped = try Typesetting.template()
        var own = shipped.replacingOccurrences(of: "#let book(", with: "#let blanche(").replacingOccurrences(of: "#let fullpage(", with: "#let classique(")
        own = own.replacingOccurrences(of: "#let blanche = book\n", with: "").replacingOccurrences(of: "#let classique = fullpage\n", with: "")
        own = own.replacingOccurrences(of: "#let asterism() = align(center, block(above: 1.2em, below: 1.2em)[⁂])", with: "#let asterism() = align(center, block(above: 1.2em, below: 1.2em)[MAISON])")
        XCTAssertFalse(own.contains("#let book(")); XCTAssertTrue(own.contains("MAISON"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("templates"), withIntermediateDirectories: true)
        try own.write(to: root.appendingPathComponent("templates/musset.typ"), atomically: true, encoding: .utf8)
        let long = String(repeating: para, count: 6)
        let json = #"{"title":"Maison","author":"Paul Durand","lang":"fr","contact":"","formatVersion":1,"sceneBreak":"asterism","chapters":[{"id":"01","file":"01.md","title":"Un","activeVersion":"main","excludeFromExport":false}],"exports":[{"id":"mine","name":"Poche","format":"pdf","template":"templates/template-blanche.tex","geometry":"paperwidth=110mm,paperheight=178mm,inner=18mm,outer=12mm,top=14mm,bottom=18mm","fontSize":"10pt","numberSections":true,"cropMarks":false,"includeContact":false,"extraArgs":[],"facing":true},{"id":"mine-a4","name":"Épreuves","format":"pdf","template":"templates/template-classique.tex","numberSections":true,"cropMarks":false,"includeContact":false,"extraArgs":[]}]}"#
        let m = try JSONDecoder().decode(BookManifest.self, from: Data(json.utf8))
        try write(root, m, ["01": "# Un\n\n<!-- scene: A -->\n\(long)\n\n<!-- scene: B -->\n\(long)\n"])
        return m
    }

    /// A small image for a cover of the « image » style.
    static func coverImage(at url: URL) throws {
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 60, pixelsHigh: 90, bitsPerSample: 8, samplesPerPixel: 4,
                                                 hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.systemTeal.setFill()
        NSRect(x: 0, y: 0, width: 60, height: 90).fill()
        NSGraphicsContext.restoreGraphicsState()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
    }

    static func pages(_ url: URL) throws -> [(text: String, size: CGSize)] {
        let doc = try XCTUnwrap(PDFDocument(url: url))
        return (0..<doc.pageCount).map { i in (doc.page(at: i)?.string ?? "", doc.page(at: i)?.bounds(for: .mediaBox).size ?? .zero) }
    }
}

/// The PDF export, by the typesetter Read mode sets its pages with: what each kind of book comes out as.
final class ExportPDFTests: XCTestCase {
    private func tmp(_ name: String) -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("musset-pdf-\(UUID().uuidString.prefix(6))-\(name)")
        addTeardownBlock { try? FileManager.default.removeItem(at: u) }
        return u
    }

    private func export(_ m: BookManifest, _ root: URL, _ preset: ExportPreset) async throws -> PDFDocument {
        let out = try await ExportService.export(manifest: m, store: BookStore(root: root), preset: preset)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".musset/typst").path), "nothing is written beside the PDF")
        return try XCTUnwrap(PDFDocument(url: out.file))
    }

    private func texts(_ doc: PDFDocument) -> [String] { (0..<doc.pageCount).map { doc.page(at: $0)?.string ?? "" } }

    /// Where the folio stands across the page (0 the left edge, 1 the right), for a page whose last line is its number.
    private func folio(_ doc: PDFDocument, page index: Int) -> CGFloat? {
        guard let page = doc.page(at: index), let text = page.string else { return nil }
        let ns = text as NSString
        let last = ns.range(of: "\(index + 1)", options: .backwards)
        guard last.location != NSNotFound, ns.substring(from: NSMaxRange(last)).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let box = page.selection(for: last)?.bounds(for: page) else { return nil }
        return box.midX / page.bounds(for: .mediaBox).width
    }

    /// The readers' PDF of a French novel: cover, title page, dedication, epigraph, contents, parts, the chapters
    /// that print, acknowledgements, colophon; scenes parted by an asterism; nothing of the author's workshop.
    func testANovelForReaders() async throws {
        let root = tmp("fr")
        let m = try ExportSamples.frenchNovel(root)
        var reader = try XCTUnwrap(BookStore(root: root).presets(m).first { $0.id == "reader" })
        reader.facing = false
        let doc = try await export(m, root, reader)
        let pages = texts(doc)
        XCTAssertEqual(pages.count, 24, "the pages the typst CLI gave too, before the export came here")
        XCTAssertEqual(doc.page(at: 0)?.bounds(for: .mediaBox).width ?? 0, 120 * 72 / 25.4, accuracy: 0.5, "120 mm wide")

        // The special pages, in order, each alone on its page.
        // (Letterspaced capitals read back with spaces between them.)
        let cover = pages[0].filter { !$0.isWhitespace }
        XCTAssertTrue(cover.contains("JEANNEMARTIN") && cover.contains("LeSel&l’Écume") && cover.contains("roman") && cover.contains("ÉDITIONSDUQUAI"), pages[0])
        XCTAssertTrue(pages[1].contains("roman d’un été") && pages[1].contains("Jeanne Martin"), "the title page: \(pages[1])")
        XCTAssertFalse(pages[1].contains("jeanne@example.org"), "no contact in the readers' edition")
        XCTAssertTrue(pages[2].contains("À ceux qui restent,") && pages[2].contains("et à ceux qui partent."), pages[2])
        XCTAssertTrue(pages[3].contains("s’efforce de persévérer dans son être.") && pages[3].contains("Spinoza, Éthique, III"), pages[3])
        XCTAssertTrue(pages[4].contains("Table") && pages[4].contains("Le port") && pages[4].contains("Retour"), pages[4])
        XCTAssertFalse(pages[4].contains("Écarté"), "a chapter set out of the export is not in the contents")
        let whole = pages.joined(separator: "\n")
        let first = try XCTUnwrap(pages.firstIndex { $0.hasPrefix("Le port") })
        XCTAssertEqual(pages[first - 1].trimmingCharacters(in: .whitespacesAndNewlines), "I", "the first part's page, before its first chapter")
        XCTAssertTrue(pages.contains { $0.contains("II") && $0.contains("La fuite") && !$0.contains("Il marchait") }, "the second part's page")
        XCTAssertLessThan(try XCTUnwrap(pages.firstIndex { $0.contains("Merci à Louise. Et à Paul.") }), pages.count - 1)
        XCTAssertTrue(pages[pages.count - 1].contains("Achevé d’imprimer en") && pages[pages.count - 1].contains("Composé avec Musset."), pages[pages.count - 1])

        // The text: what prints and what does not.
        XCTAssertFalse(whole.contains("Ce chapitre ne s’imprime pas"))
        XCTAssertFalse(whole.contains("une note") || whole.contains("À revoir") || whole.contains("scene:"), "notes to self stay out")
        XCTAssertTrue(whole.contains("Il chaud. Très chaud. Un vieux parapluie."), "pending corrections are not printed")
        XCTAssertEqual(whole.components(separatedBy: "⁂").count - 1, 2, "an asterism between scenes, none before the first")
        XCTAssertTrue(whole.contains("1943. Barcelone."), "a year that opens a sentence is not a list")
        let kawai = try XCTUnwrap(pages.first { $0.contains("Le Kawai") })
        XCTAssertTrue(kawai.contains("Un quart de queue, noir, acheté à crédit."), "the footnote at the foot of its page")
        XCTAssertTrue(whole.contains("Centré, petites capitales") || whole.contains("Centré, PETITES CAPITALES") || whole.lowercased().contains("centré, petites capitales"), "the LaTeX blocks of old books")
        XCTAssertFalse(whole.contains("\\begin") || whole.contains("vspace") || whole.contains("newpage"))
        let signs = try XCTUnwrap(pages.first { $0.contains("le site") })
        for sign in ["#1", "$5", "@x", "<a>", "[b]", "~", "1_000", "a -- b / c", "code_brut"] { XCTAssertTrue(signs.contains(sign), "signs Typst gives a meaning to print as written: \(sign) in \(signs.suffix(400))") }

        // Single pages: no folio before the text starts, then one at the centre of the foot.
        XCTAssertNil(folio(doc, page: 0)); XCTAssertNil(folio(doc, page: 2))
        XCTAssertEqual(try XCTUnwrap(folio(doc, page: first + 1)), 0.5, accuracy: 0.03)
    }

    /// Facing pages: the first chapter opens on a recto, folios stand at the outer foot, inside margins are wider.
    func testFacingPagesForThePrinter() async throws {
        let root = tmp("fr")
        var m = try ExportSamples.frenchNovel(root)
        var reader = try XCTUnwrap(BookStore(root: root).presets(m).first { $0.id == "reader" })
        reader.facing = true
        let doc = try await export(m, root, reader)
        let pages = texts(doc)
        XCTAssertEqual(pages.count, 26)
        let first = try XCTUnwrap(pages.firstIndex { $0.hasPrefix("Le port") })
        XCTAssertEqual(first % 2, 0, "the first chapter opens on a right-hand page (an odd page)")
        let verso = try XCTUnwrap((first + 1..<pages.count).first { $0 % 2 == 1 && folio(doc, page: $0) != nil })
        let recto = try XCTUnwrap((first + 1..<pages.count).first { $0 % 2 == 0 && folio(doc, page: $0) != nil })
        XCTAssertLessThan(try XCTUnwrap(folio(doc, page: verso)), 0.3, "an even page: the folio at the left")
        XCTAssertGreaterThan(try XCTUnwrap(folio(doc, page: recto)), 0.7, "an odd page: the folio at the right")

        // The printer's interior: the same book without its cover, at the trade size of the book's market.
        let print = try XCTUnwrap(BookStore(root: root).presets(m).first { $0.id == "print" })
        XCTAssertEqual(print.interior, true)
        m.front?.cover?.inPDF = false
        let interior = try await export(m, root, print)
        XCTAssertFalse(texts(interior)[0].filter { !$0.isWhitespace }.contains("JEANNEMARTIN"), "no cover")
        XCTAssertTrue(texts(interior)[0].contains("roman d’un été"), "the title page first")
        XCTAssertEqual(interior.pageCount, 23)
    }

    /// The cover as an image from the book's folder, and a plain one; a full page with numbered chapters.
    func testCoversAndTheFullPage() async throws {
        let root = tmp("fr")
        var m = try ExportSamples.frenchNovel(root)
        try ExportSamples.coverImage(at: root.appendingPathComponent("images/couverture 1.png"))
        m.front?.cover = .init(style: "image", genre: "roman", publisher: "", image: "images/couverture 1.png")
        let reader = try XCTUnwrap(BookStore(root: root).presets(m).first { $0.id == "reader" })
        let source = try Typesetting.source(manifest: m, store: BookStore(root: root), preset: reader)
        XCTAssertEqual(source.pages.cover?.image, "images/couverture 1.png")
        let withImage = try await export(m, root, reader)
        let ink = try XCTUnwrap(withImage.page(at: 0)).thumbnail(of: CGSize(width: 60, height: 90), for: .mediaBox)
        let rep = try XCTUnwrap(ink.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        let corner = try XCTUnwrap(rep.colorAt(x: 3, y: 3)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(corner.blueComponent, corner.redComponent + 0.1, "the image covers the page to its corner")

        // An image that is no longer there: the cover without it, not a failed export.
        m.front?.cover?.image = "images/gone.png"
        XCTAssertNil(try Typesetting.source(manifest: m, store: BookStore(root: root), preset: reader).pages.cover?.image)

        m.front?.cover = .init(style: "plain")
        let a4 = ExportPreset(id: "a4", name: "A4", format: .pdf, style: "classique", includeContact: true)
        let doc = try await export(m, root, a4)
        XCTAssertEqual(doc.page(at: 0)?.bounds(for: .mediaBox).width ?? 0, 595, accuracy: 1, "A4, under the style's old name")
        XCTAssertEqual(doc.pageCount, 18)
        let pages = texts(doc)
        XCTAssertTrue(pages[1].contains("jeanne@example.org"), "the contact on the title page when the layout asks for it")
        XCTAssertTrue(pages.contains { $0.contains("1\nLe port") || $0.contains("1 Le port") || $0.hasPrefix("1\n") && $0.contains("Le port") }, "numbered chapters")
    }

    /// A manuscript for submission has its own title page and none of the book's special pages.
    func testManuscriptsByCountry() async throws {
        let en = tmp("en")
        let road = try ExportSamples.englishManuscript(en)
        var shunn = ManuscriptNorm.shunnUS.preset
        var doc = try await export(road, en, shunn)
        var pages = texts(doc)
        XCTAssertEqual(doc.page(at: 0)?.bounds(for: .mediaBox).size.width ?? 0, 612, accuracy: 1, "US Letter")
        XCTAssertTrue(pages[0].contains("THE SALT ROAD") || pages[0].contains("The Salt Road"), pages[0])
        XCTAssertTrue(pages[0].contains("mara@example.org") && pages[0].contains("about") && pages[0].contains("words"), pages[0])
        XCTAssertTrue(pages[1].contains("Fenwick / THE SALT ROAD"), "the running head: \(pages[1])")
        XCTAssertTrue(pages.joined().contains("\"asked\"") || pages.joined().contains("“asked”"))
        shunn.pseudonym = "A. N. Other"
        pages = texts(try await export(road, en, shunn))
        XCTAssertFalse(pages.joined().contains("Fenwick") || pages.joined().contains("mara@example.org"), "under a pseudonym: no name, no contact")
        XCTAssertTrue(pages[1].contains("Other / THE SALT ROAD"))

        let de = tmp("de")
        let strasse = try ExportSamples.germanManuscript(de)
        doc = try await export(strasse, de, ManuscriptNorm.normseite.preset)
        pages = texts(doc)
        XCTAssertTrue(pages[0].contains("Normseiten"), pages[0])
        XCTAssertTrue(pages.contains { $0.contains("Aufbruch") && !$0.contains("Er ging langsam") }, "the part's page")
        let body = try XCTUnwrap(pages.first { $0.contains("Er ging langsam") && !$0.contains("Die Fähre\n") }).components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        XCTAssertLessThanOrEqual(body.dropFirst().map(\.count).max() ?? 0, 60, "at most 60 characters a line")
        XCTAssertTrue(pages.joined().contains("„erwachte“"))
    }

    /// A book with its own `templates/musset.typ` from before the styles were renamed, and a layout from the LaTeX days.
    func testABooksOwnTemplateUnderItsOldNames() async throws {
        let root = tmp("own")
        let m = try ExportSamples.ownTemplate(root)
        XCTAssertEqual(m.exports.map(\.typstStyle), ["book", "fullpage"])
        let poche = try await export(m, root, m.exports[0])
        XCTAssertEqual(poche.page(at: 0)?.bounds(for: .mediaBox).width ?? 0, 110 * 72 / 25.4, accuracy: 0.5, "the page its old geometry described")
        XCTAssertTrue(texts(poche).contains { $0.contains("MAISON") }, "the book's own template is the one used")
        XCTAssertEqual(poche.pageCount, 4)
        let a4 = try await export(m, root, m.exports[1])
        XCTAssertEqual(a4.page(at: 0)?.bounds(for: .mediaBox).width ?? 0, 595, accuracy: 1)
        XCTAssertTrue(texts(a4).contains { $0.contains("MAISON") })
    }

    /// What Typst refuses comes back as the export's error, in words.
    func testABrokenTemplateSaysSo() async throws {
        let root = tmp("broken")
        let m = try ExportSamples.ownTemplate(root)
        try "#let book(body) = { unknown-function() }\n".write(to: root.appendingPathComponent("templates/musset.typ"), atomically: true, encoding: .utf8)
        do {
            _ = try await ExportService.export(manifest: m, store: BookStore(root: root), preset: m.exports[0])
            XCTFail("a template that does not compile")
        } catch {
            XCTAssertTrue(error.localizedDescription.hasPrefix("Typst: "), error.localizedDescription)
        }
    }
}
