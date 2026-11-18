import CoreGraphics
import Foundation
import MussetTypeset

/// A place in the book that survives reflow: a chapter, and a character of its Markdown (UTF-16 offset).
public struct PageAnchor: Hashable, Codable, Sendable {
    public var chapter: String
    public var offset: Int
    public init(chapter: String, offset: Int) {
        self.chapter = chapter
        self.offset = offset
    }
}

/// A book as the engine composes it: its chapters' Markdown, Musset's template, and the page to set it on.
public struct BookSource: Hashable, Sendable {
    public struct Chapter: Hashable, Sendable {
        public var id: String
        /// The chapter's Markdown. Every offset the engine gives (glyphs, marks, anchors) is a UTF-16 offset in it.
        public var markdown: String
        /// A part's page before this chapter: its numeral (in a formed book, the group's line: « Acte II ») and title.
        public var part: Part?
        /// In a book with a form of its own: what the piece opens under. Nil: the chapter opens as it always did.
        public var opening: Opening?
        public init(id: String, markdown: String, part: Part? = nil, opening: Opening? = nil) {
            self.id = id
            self.markdown = markdown
            self.part = part
            self.opening = opening
        }
    }

    /// A piece's opening as the book's form has it, in the book's words: the engine writes them, it names nothing.
    public struct Opening: Hashable, Sendable, Encodable {
        /// The line over the title: « Chapitre 3 », « Prologue ». Nil: the title alone.
        public var label: String?
        /// The title a text without a heading of its own opens under.
        public var title: String?
        public init(label: String? = nil, title: String? = nil) {
            self.label = label
            self.title = title
        }
    }

    /// Where the levels of a formed book open: "rightPage", "newPage" or "inPage". Nil leaves the template's own
    /// (a group on a right-hand page, a piece on the next page).
    public struct Form: Hashable, Sendable, Encodable {
        public var groupOpens: String?
        public var pieceOpens: String?
        public init(groupOpens: String? = nil, pieceOpens: String? = nil) {
            self.groupOpens = groupOpens
            self.pieceOpens = pieceOpens
        }
    }

    /// What the book recognises in its pieces' text, whether or not it has a form of its own. As it stands here:
    /// what Musset always read (bullet lists, « 1943. » a sentence, sub-headings out of the contents).
    public struct TextOptions: Hashable, Sendable, Encodable {
        /// « - », « + », « * » open a bullet item.
        public var bullets: Bool
        /// « 1. » opens a numbered list.
        public var numbered: Bool
        /// Sub-headings are sections: the contents list them under their piece.
        public var sections: Bool
        public init(bullets: Bool = true, numbered: Bool = false, sections: Bool = false) {
            self.bullets = bullets
            self.numbered = numbered
            self.sections = sections
        }
    }

    public struct Part: Hashable, Sendable {
        public var numeral: String
        public var title: String
        public init(numeral: String, title: String) {
            self.numeral = numeral
            self.title = title
        }
    }

    public var chapters: [Chapter]
    /// The source of `musset.typ` (the app's, or the book's own `templates/musset.typ`).
    public var template: String
    /// "book", "fullpage" or "manuscript" (older names "blanche" and "classique" work too).
    public var style: String
    public var title: String
    public var author: String
    public var contact: String?
    /// The book's language code ("fr", "en-GB"…).
    public var lang: String
    public var layout: PageLayout
    /// "none", "blank" or "asterism".
    public var sceneBreak: String?
    /// The book's special pages, around the chapters. A manuscript has none.
    public var pages: SpecialPages
    /// Folders searched for fonts, first wins. Typst's own fonts are always there as a last resort.
    public var fontDirectories: [URL]
    /// The fonts installed on the system too (nil: on macOS, not on iOS).
    public var systemFonts: Bool?
    /// Where files the source names (a cover image) are read from.
    public var resourceDirectory: URL?
    /// Reading mode's paragraph markers (`#mk`); the export has none.
    public var markers: Bool
    /// A book with a form of its own. Nil: the book Musset always set.
    public var form: Form?
    /// What the book recognises in its text.
    public var text: TextOptions

    public init(chapters: [Chapter], template: String, style: String = "book", title: String = "", author: String = "",
                contact: String? = nil, lang: String = "fr", layout: PageLayout = PageLayout(), sceneBreak: String? = nil,
                pages: SpecialPages = SpecialPages(), fontDirectories: [URL] = [], systemFonts: Bool? = nil,
                resourceDirectory: URL? = nil, markers: Bool = false, form: Form? = nil, text: TextOptions = TextOptions()) {
        self.chapters = chapters
        self.template = template
        self.style = style
        self.title = title
        self.author = author
        self.contact = contact
        self.lang = lang
        self.layout = layout
        self.sceneBreak = sceneBreak
        self.pages = pages
        self.fontDirectories = fontDirectories
        self.systemFonts = systemFonts
        self.resourceDirectory = resourceDirectory
        self.markers = markers
        self.form = form
        self.text = text
    }

    public func chapterIndex(_ id: String) -> Int? { chapters.firstIndex { $0.id == id } }
}

/// The special pages a book has: before the chapters (cover, title page, dedication, epigraph, contents, in this
/// order) and after them (acknowledgements, colophon). Nil: the book has no such page. The words Musset supplies
/// (the contents page's title, the colophon) come in the book's language.
public struct SpecialPages: Hashable, Sendable, Encodable {
    public struct Cover: Hashable, Sendable, Encodable {
        /// "typographic", "image" or "plain".
        public var style: String
        public var genre: String
        public var publisher: String
        public var ground: String
        public var accent: String
        /// The image's path in the book's `resourceDirectory`, for the "image" style.
        public var image: String?
        public init(style: String, genre: String = "", publisher: String = "", ground: String, accent: String, image: String? = nil) {
            self.style = style; self.genre = genre; self.publisher = publisher; self.ground = ground; self.accent = accent; self.image = image
        }
    }
    public struct TitlePage: Hashable, Sendable, Encodable {
        public var subtitle: String?
        public var contact: String?
        public init(subtitle: String? = nil, contact: String? = nil) { self.subtitle = subtitle; self.contact = contact }
    }
    public struct Epigraph: Hashable, Sendable, Encodable {
        public var text: String
        public var source: String?
        public init(text: String, source: String? = nil) { self.text = text; self.source = source }
    }
    public struct Titled: Hashable, Sendable, Encodable {
        public var title: String
        public var text: String
        public init(title: String, text: String) { self.title = title; self.text = text }
    }

    public var cover: Cover?
    public var titlePage: TitlePage?
    public var dedication: String?
    public var epigraph: Epigraph?
    /// The contents page's title.
    public var contents: String?
    public var acknowledgements: Titled?
    /// The colophon's lines.
    public var colophon: String?

    public init(cover: Cover? = nil, titlePage: TitlePage? = nil, dedication: String? = nil, epigraph: Epigraph? = nil,
                contents: String? = nil, acknowledgements: Titled? = nil, colophon: String? = nil) {
        self.cover = cover; self.titlePage = titlePage; self.dedication = dedication; self.epigraph = epigraph
        self.contents = contents; self.acknowledgements = acknowledgements; self.colophon = colophon
    }
}

/// The page parameters, as Typst lengths ("120mm", "10.8pt"). Nil leaves the style's own.
public struct PageLayout: Hashable, Sendable {
    public var paper: [String]?
    public var margins: [String: String]?
    public var size: String?
    public var crop = false
    public var numbered = true
    public var titlePage = true
    public var facing = true
    /// A submission manuscript's norm: its Typst arguments, running head and count.
    public var manuscript: [String: String]?

    public init(paper: (String, String)? = nil, margins: [String: String]? = nil, size: String? = nil, crop: Bool = false,
                numbered: Bool = true, titlePage: Bool = true, facing: Bool = true) {
        self.paper = paper.map { [$0.0, $0.1] }
        self.margins = margins
        self.size = size
        self.crop = crop
        self.numbered = numbered
        self.titlePage = titlePage
        self.facing = facing
    }

    /// A page measured in points, with margins in points.
    public static func points(width: Double, height: Double, top: Double, bottom: Double, inside: Double, outside: Double,
                              size: Double, facing: Bool) -> PageLayout {
        func pt(_ v: Double) -> String { String(format: "%.2fpt", v) }
        return PageLayout(paper: (pt(width), pt(height)),
                          margins: ["top": pt(top), "bottom": pt(bottom), "inside": pt(inside), "outside": pt(outside)],
                          size: pt(size), numbered: false, titlePage: false, facing: facing)
    }
}

/// A glyph on a page and the characters of the chapter it shows.
public struct PageGlyph: Hashable, Sendable {
    /// Its box on the page, in points from the top left.
    public var rect: CGRect
    public var baseline: CGFloat
    /// The chapter's index in the book.
    public var chapter: Int
    /// UTF-16 range in the chapter's Markdown.
    public var range: Range<Int>
    /// For a footnote's number: the footnote's index in `TypesetBook.footnotes`.
    public var footnote: Int?
}

public struct Footnote: Hashable, Sendable, Decodable {
    public var chapter: Int
    public var start: Int
    public var end: Int
    public var text: String
}

public struct TypesetError: LocalizedError {
    public var message: String
    public var errorDescription: String? { message }
}

/// A composed book: its pages, their text maps, and bitmaps on demand. Immutable and safe to share.
public final class TypesetBook: @unchecked Sendable {
    private let handle: OpaquePointer
    public let source: BookSource
    public let pageCount: Int
    /// Page sizes in points.
    public let pageSizes: [CGSize]
    public let footnotes: [Footnote]
    private let glyphCache = NSCache<NSNumber, GlyphBox>()

    private final class GlyphBox { let glyphs: [PageGlyph]; init(_ g: [PageGlyph]) { glyphs = g } }

    /// Composes the book. Slow (a second or so for a novel): call it off the main thread.
    public init(_ source: BookSource) throws {
        self.source = source
        let json = try Self.spec(source)
        var error: UnsafeMutablePointer<CChar>?
        guard let h = json.withCString({ mt_book_compile($0, &error) }) else {
            let message = error.map { String(cString: $0) } ?? "Typst failed"
            if let error { mt_string_free(error) }
            throw TypesetError(message: message)
        }
        handle = h
        pageCount = Int(mt_book_page_count(h))
        pageSizes = (0..<pageCount).map { i in
            var w = 0.0, hh = 0.0
            _ = mt_book_page_size(h, UInt32(i), &w, &hh)
            return CGSize(width: w, height: hh)
        }
        footnotes = Self.string(mt_book_footnotes_json(h)).flatMap { try? JSONDecoder().decode([Footnote].self, from: Data($0.utf8)) } ?? []
    }

    deinit { mt_book_free(handle) }

    /// The Typst source the book was composed from.
    public var typstSource: String { Self.string(mt_book_source(handle)) ?? "" }
    public var warnings: [String] {
        Self.string(mt_book_warnings_json(handle)).flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) } ?? []
    }

    public func glyphs(page: Int) -> [PageGlyph] {
        guard page >= 0, page < pageCount else { return [] }
        if let cached = glyphCache.object(forKey: page as NSNumber) { return cached.glyphs }
        let n = mt_book_page_glyphs(handle, UInt32(clamping: page), nil, 0)
        var raw = [MTGlyph](repeating: MTGlyph(), count: n)
        _ = raw.withUnsafeMutableBufferPointer { mt_book_page_glyphs(handle, UInt32(clamping: page), $0.baseAddress, n) }
        let glyphs = raw.map { g in
            PageGlyph(rect: CGRect(x: CGFloat(g.x), y: CGFloat(g.y), width: CGFloat(g.w), height: CGFloat(g.h)),
                      baseline: CGFloat(g.baseline), chapter: Int(g.chapter), range: Int(g.start)..<max(Int(g.start), Int(g.end)),
                      footnote: g.footnote >= 0 ? Int(g.footnote) : nil)
        }
        glyphCache.setObject(GlyphBox(glyphs), forKey: page as NSNumber)
        return glyphs
    }

    /// The page showing an anchor.
    public func page(for anchor: PageAnchor) -> Int {
        guard let c = source.chapterIndex(anchor.chapter) else { return 0 }
        return Int(mt_book_locate(handle, Int32(clamping: c), Int32(clamping: max(0, anchor.offset))))
    }

    /// Where a page starts in the text: its first glyph of a chapter's text.
    public func anchor(page: Int) -> PageAnchor? {
        let g = glyphs(page: page).filter { $0.footnote == nil }.min { ($0.chapter, $0.range.lowerBound) < ($1.chapter, $1.range.lowerBound) }
        return g.map { PageAnchor(chapter: source.chapters[$0.chapter].id, offset: $0.range.lowerBound) }
    }

    /// The text a range of a chapter shows (the Markdown as written).
    public func text(chapter: Int, range: Range<Int>) -> String {
        let md = source.chapters[chapter].markdown.utf16
        let lo = md.index(md.startIndex, offsetBy: max(0, min(range.lowerBound, md.count)))
        let hi = md.index(md.startIndex, offsetBy: max(0, min(range.upperBound, md.count)))
        return String(md[lo..<hi]) ?? ""
    }

    /// A book as a PDF: the pages reading shows, written out. Slow like composing: call it off the main thread.
    public static func pdf(_ source: BookSource) throws -> Data {
        let json = try spec(source)
        var length = 0
        var error: UnsafeMutablePointer<CChar>?
        guard let bytes = json.withCString({ mt_pdf($0, &length, &error) }) else {
            let message = error.map { String(cString: $0) } ?? "Typst failed"
            if let error { mt_string_free(error) }
            throw TypesetError(message: message)
        }
        defer { mt_bitmap_free(bytes, length) }
        return Data(bytes: bytes, count: length)
    }

    /// The page as an image at `scale` pixels per point, white as `paper` and black as `ink`.
    public func render(page: Int, scale: CGFloat, paper: UInt32 = 0xFFFFFF, ink: UInt32 = 0x000000) -> CGImage? {
        guard page >= 0, page < pageCount else { return nil }
        var w: UInt32 = 0, h: UInt32 = 0
        guard let px = mt_book_render(handle, UInt32(clamping: page), Float(scale), paper, ink, &w, &h) else { return nil }
        let length = Int(w) * Int(h) * 4
        // The buffer is handed to the image and freed with it.
        guard let provider = CGDataProvider(dataInfo: nil, data: px, size: length, releaseData: { _, data, size in
            mt_bitmap_free(UnsafeMutablePointer(mutating: data.assumingMemoryBound(to: UInt8.self)), size)
        }) else {
            mt_bitmap_free(px, length)
            return nil
        }
        return CGImage(width: Int(w), height: Int(h), bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: Int(w) * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// Frees the layout Typst keeps between compositions, older than `maxAge` of them.
    public static func evictCache(maxAge: Int = 10) { mt_evict(UInt32(max(0, maxAge))) }

    // MARK: Plumbing

    private static func string(_ p: UnsafeMutablePointer<CChar>?) -> String? {
        guard let p else { return nil }
        defer { mt_string_free(p) }
        return String(cString: p)
    }

    private struct Spec: Encodable {
        struct Chapter: Encodable { let id: String; let markdown: String; let part: [String]?; let opening: BookSource.Opening? }
        struct Layout: Encodable {
            let paper: [String]?; let margins: [String: String]?; let size: String?
            let crop: Bool; let numbered: Bool; let titlePage: Bool; let facing: Bool
            let manuscript: [String: String]?
        }
        let template: String, style: String, title: String, author: String, contact: String?, lang: String
        let layout: Layout
        let chapters: [Chapter]
        let pages: SpecialPages, sceneBreak: String?, markers: Bool
        let fontDirs: [String], systemFonts: Bool?, resourceDir: String?
        let form: BookSource.Form?
        let text: BookSource.TextOptions
    }

    static func spec(_ s: BookSource) throws -> String {
        let l = s.layout
        let spec = Spec(template: s.template, style: s.style, title: s.title, author: s.author, contact: s.contact, lang: s.lang,
                        layout: .init(paper: l.paper, margins: l.margins, size: l.size, crop: l.crop, numbered: l.numbered,
                                      titlePage: l.titlePage, facing: l.facing, manuscript: l.manuscript),
                        chapters: s.chapters.map { .init(id: $0.id, markdown: $0.markdown, part: $0.part.map { [$0.numeral, $0.title] }, opening: $0.opening) },
                        pages: s.pages, sceneBreak: s.sceneBreak, markers: s.markers,
                        fontDirs: s.fontDirectories.map(\.path), systemFonts: s.systemFonts, resourceDir: s.resourceDirectory?.path, form: s.form, text: s.text)
        return String(decoding: try JSONEncoder().encode(spec), as: UTF8.self)
    }
}
