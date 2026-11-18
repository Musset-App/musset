import Foundation
import MussetPage

/// What the typesetter (musset-typeset, through MussetPage) needs from a book, for Read mode's pages and for the PDF
/// export alike: the template, the fonts, the special pages.
enum Typesetting {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// A style's current name: "blanche" and "classique" were the names of "book" and "fullpage".
    static func style(_ name: String) -> String {
        switch name { case "blanche": "book"; case "classique": "fullpage"; default: name }
    }

    /// The Typst the typesetter is built on (`musset-typeset/Cargo.toml`).
    static let typstVersion = "0.14.2"

    static var templateURL: URL? { Bundle.main.url(forResource: "musset", withExtension: "typ") }

    /// Musset's template, or the book's own `templates/musset.typ` when it has one (the typesetter gives a template
    /// written before the styles were renamed its new names).
    static func template(bookRoot: URL? = nil) throws -> String {
        let own = bookRoot.map { $0.appendingPathComponent("templates/musset.typ") }.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
        guard let url = own ?? templateURL, let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw Failure(message: L("Musset's Typst template is missing from the app."))
        }
        return text
    }

    /// Where fonts are looked for, first wins: the app's own (EB Garamond, Plex Mono for a monospaced manuscript),
    /// the author's, the book's. The fonts installed on the Mac come after them.
    static func fonts(bookRoot: URL) -> [URL] {
        let bundled = Bundle.main.resourceURL.map { [$0] } ?? []
        return (bundled + [URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Fonts"), bookRoot.appendingPathComponent("fonts")])
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// The book's special pages, those it has. `coverImage`: the cover's image, as a path in the book's folder.
    static func pages(_ m: BookManifest, coverImage: String?, contact: String? = nil) -> SpecialPages {
        let f = m.front ?? FrontMatter()
        var pages = SpecialPages()
        if f.has(.cover), let c = f.cover {
            pages.cover = .init(style: c.style, genre: c.genre, publisher: c.publisher, ground: c.ground, accent: c.accent, image: coverImage)
        }
        if f.has(.title) { pages.titlePage = .init(subtitle: m.subtitle, contact: contact) }
        if f.has(.dedication) { pages.dedication = f.dedication }
        if f.has(.epigraph), let e = f.epigraph { pages.epigraph = .init(text: e, source: f.epigraphSource) }
        if f.has(.contents) { pages.contents = BookTerm.contents.in(m.lang) }
        if f.has(.acknowledgements), let a = f.acknowledgements { pages.acknowledgements = .init(title: BookTerm.acknowledgements.in(m.lang), text: a) }
        if f.has(.colophon) {
            let year = Calendar.current.component(.year, from: Date())
            pages.colophon = BookTerm.colophon.in(m.lang).replacingOccurrences(of: "{year}", with: "\(year)")
        }
        return pages
    }

    /// A book as a layout sets it: the chapters that print, the page, the special pages (a manuscript has its own
    /// title page and none of the book's), the cover's image.
    static func source(manifest m: BookManifest, store: BookStore, preset p: ExportPreset) throws -> BookSource {
        let texts = CitationPages.apply(to: m.chapters.filter { !$0.excludeFromExport }.map { (id: $0.id, text: store.read($0)) }, root: store.root, lang: m.lang)
        let pseudonym = p.pseudonym.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        let author = pseudonym ?? m.author
        let contact = pseudonym == nil && p.includeContact && !m.contact.isEmpty ? m.contact : nil
        var layout = PageLayout(paper: p.paper.map { ($0.width, $0.height) }, margins: p.margins.map(\.byName).flatMap { $0.isEmpty ? nil : $0 },
                                size: p.fontSize, numbered: p.numberSections, titlePage: false, facing: p.facing ?? false)
        if let norm = p.manuscript {
            layout.manuscript = ["args": norm.typstArguments, "running": norm.running(author: author, title: m.title),
                                 "count": norm.count(of: texts.map(\.text).joined(separator: "\n\n"), lang: BookLanguage(code: m.lang))]
        }
        let image = m.front?.cover?.image.flatMap { FileManager.default.fileExists(atPath: store.root.appendingPathComponent($0).path) ? $0 : nil }
        return BookSource(chapters: m.typesetChapters(texts),
                          template: try template(bookRoot: store.root), style: p.typstStyle, title: m.title, author: author, contact: contact,
                          lang: m.lang, layout: layout, sceneBreak: m.sceneBreak?.rawValue,
                          pages: p.manuscript == nil ? pages(m, coverImage: image, contact: contact) : SpecialPages(),
                          fontDirectories: fonts(bookRoot: store.root), resourceDirectory: store.root, form: m.typesetForm, text: m.typesetText)
    }
}
