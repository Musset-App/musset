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

    func testFeuilletIsTwentyFiveLines() async throws {
        let doc = try await export(.feuillet, lang: "fr")
        XCTAssertEqual(lines(doc, page: 2).dropFirst().count, 25)
        XCTAssertTrue(lines(doc, page: 0).joined().contains("feuillets"))
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

    func testEachLanguageGetsItsNormAndTrims() {
        XCTAssertEqual(ManuscriptNorm.for(.deCH), .normseite)
        XCTAssertEqual(ManuscriptNorm.for(.ptBR), .portugueseBR)
        let presets = BookStore(root: root).defaultPresets(lang: "it-IT")
        XCTAssertEqual(presets.first?.manuscript, .cartella)
        XCTAssertTrue(presets.contains { $0.id == "book-140x210" })
    }

    func testBookTermsFollowTheBook() {
        XCTAssertEqual(BookTerm.acknowledgements.in("de-CH"), "Danksagung")
        XCTAssertEqual(BookTerm.acknowledgements.in("en-US"), "Acknowledgments")
        XCTAssertEqual(BookTerm.acknowledgements.in("en-GB"), "Acknowledgements")
        XCTAssertEqual(BookTerm.contents.in("fr"), "Table")
    }
}
