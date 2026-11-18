import Foundation
import MussetPage
import PDFKit
import XCTest
@testable import Musset

/// What the typesetter makes of a chapter or a small book, for tests: the Typst it composes, the pages, the PDF.
enum Typeset {
    static func book(_ chapters: [(id: String, text: String)], style: String = "book", title: String = "T", author: String = "A", lang: String = "fr",
                     layout: PageLayout = PageLayout(numbered: false, titlePage: false), sceneBreak: SceneBreak = .none, markers: Bool = false,
                     pages: SpecialPages = SpecialPages(), parts: [String: (numeral: String, title: String)] = [:]) throws -> TypesetBook {
        let root = FileManager.default.temporaryDirectory
        return try TypesetBook(BookSource(chapters: chapters.map { ch in .init(id: ch.id, markdown: ch.text, part: parts[ch.id].map { .init(numeral: $0.numeral, title: $0.title) }) },
                                          template: Typesetting.template(), style: style, title: title, author: author, lang: lang, layout: layout,
                                          sceneBreak: sceneBreak.rawValue, pages: pages, fontDirectories: Typesetting.fonts(bookRoot: root), markers: markers))
    }

    /// A chapter's Markdown as the Typst the typesetter composes, without the document's opening lines.
    static func chapter(_ md: String, id: String = "c", markers: Bool = false, sceneBreak: SceneBreak = .none) throws -> String {
        let source = try book([(id, md)], sceneBreak: sceneBreak, markers: markers).typstSource
        let start = try XCTUnwrap(source.range(of: ")\n\n")).upperBound
        return String(source[start...].dropLast())
    }

    /// The book's PDF, read back.
    static func pdf(_ book: TypesetBook) throws -> PDFDocument { try XCTUnwrap(PDFDocument(data: try TypesetBook.pdf(book.source))) }
}
