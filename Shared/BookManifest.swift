import Foundation

// The book's manifest, as the Mac app writes it and both apps read it: one set of types for Musset and Musset Reader.

/// `.musset/book.json` — the single source of truth for what the app shows.
struct BookManifest: Encodable, Equatable {
    var title: String
    var author: String = NSFullUserName()
    var lang: String = "fr"
    var contact: String = ""
    var chapters: [ChapterEntry]
    /// The layouts the author made. Musset's own are not kept here: `BookStore.presets` makes them for the book's language.
    var exports: [ExportPreset] = []
    /// What the author set on Musset's own layouts, by the layout's id.
    var layoutSettings: [String: LayoutSettings]? = nil
    var formatVersion: Int = 1
    /// What a change of scene looks like on the page; nil reads as nothing.
    var sceneBreak: SceneBreak? = nil
    var subtitle: String? = nil
    /// Word goal for the book, shown against the count.
    var goal: Int? = nil
    /// Cover, title page, dedication… (see FrontMatter).
    var front: FrontMatter? = nil
    /// On the home screen; nil reads as in progress.
    var shelf: Shelf? = nil
    /// The genre chosen at creation: a rubric preset's id. The one place a preset's id is kept: the rubric itself
    /// (`Bareme`) says which preset it is by its grids.
    var genre: String? = nil
    /// Chapters set aside: out of the book's count and export, files where they were.
    var drafts: [ChapterEntry]? = nil
    /// The book's parts (I, II, III…), numbered by where their first chapter stands. Chapters name theirs.
    var parts: [BookPart]? = nil
    /// The book's form: what its levels are called and how they number (see BookStructure). Nil is the book
    /// Musset always made, and is not written.
    var structure: BookStructure? = nil

    struct LayoutSettings: Codable, Equatable {
        /// A manuscript sent under a pseudonym (literary prizes).
        var pseudonym: String? = nil
    }

    /// The pseudonym a layout is exported under: kept on the layout if it is the author's own, else among the settings.
    mutating func setPseudonym(_ name: String?, for layout: String) {
        if let i = exports.firstIndex(where: { $0.id == layout }) { exports[i].pseudonym = name; return }
        setPseudonymSetting(name, for: layout)
    }

    mutating func setPseudonymSetting(_ name: String?, for layout: String) {
        var all = layoutSettings ?? [:]
        all[layout] = name.map { LayoutSettings(pseudonym: $0) }
        layoutSettings = all.isEmpty ? nil : all
    }

    /// A chapter's place in the book, counted from 1. The number a list shows is `pieceMarks`: it follows the book's form.
    static func chapterNumber(at index: Int) -> Int { index + 1 }
    /// The number the chapter carries, nil for one that carries none (see `pieceNumbers`).
    func chapterNumber(of id: String) -> Int? { pieceNumber(of: id) }
}

struct ChapterEntry: Encodable, Equatable, Identifiable, Hashable {
    /// Stable id = canonical file name without extension, e.g. "01_the_ferry".
    var id: String
    /// Path of the canonical file, relative to the book folder. Always holds the active version.
    var file: String
    var title: String
    /// Name of the version currently in `file`. Alternates live in `.musset/versions/<id>/<name>.md`.
    var activeVersion: String = "main"
    var excludeFromExport: Bool = false
    /// Where the chapter stands; nil reads as draft.
    var status: ChapterStatus? = nil
    /// The part it belongs to (a `BookPart` id); nil outside any part.
    var part: String? = nil
    /// An unnumbered piece's kind (a prologue, an interlude…): one of the book's `unnumberedKinds`. Nil takes its number.
    var kind: String? = nil
    /// The strand it follows (a `BookStructure.Strand` id).
    var strand: String? = nil
}

/// A chapter's progress, in order.
enum ChapterStatus: String, Codable, CaseIterable, Identifiable {
    case draft, done, edited, final
    var id: String { rawValue }
    var label: String {
        switch self {
        case .draft: L("Draft")
        case .done: L("Done", ctx: "Écrit")
        case .edited: L("Edited")
        case .final: L("Final")
        }
    }
    var help: String {
        switch self {
        case .draft: L("Being written")
        case .done: L("First version finished")
        case .edited: L("Revised after critique")
        case .final: L("Ready, nothing more to change")
        }
    }
}

enum ExportFormat: String, Codable, CaseIterable {
    case pdf, docx, epub
}

/// A page's trim size, as lengths Typst reads ("120mm", "5.5in").
struct PagePaper: Codable, Hashable {
    var width: String
    var height: String
    /// As shown beside a layout's name.
    var label: String { "\(width) × \(height)" }
}

/// A page's margins, as lengths Typst reads. Facing pages have an inside and an outside; single pages a left and a right.
struct PageMargins: Codable, Hashable {
    var inside: String? = nil
    var outside: String? = nil
    var left: String? = nil
    var right: String? = nil
    var top: String? = nil
    var bottom: String? = nil

    /// By the names Typst gives them.
    var byName: [String: String] {
        var out: [String: String] = [:]
        for (name, value) in [("inside", inside), ("outside", outside), ("left", left), ("right", right), ("top", top), ("bottom", bottom)] {
            if let value { out[name] = value }
        }
        return out
    }
}

/// A layout a book can be exported in. Musset's own (the submission manuscript, the two PDF editions, Word, EPUB) are
/// made from the book's language each time they are asked for (`BookStore.presets`); `book.json` only keeps the
/// author's own.
struct ExportPreset: Equatable, Identifiable, Hashable {
    var id: String
    var name: String
    var format: ExportFormat
    /// Template path relative to the book folder: reference doc for DOCX, CSS for EPUB.
    var template: String? = nil
    /// PDF only: the Typst style, "book" (a printed book, any trim) or "fullpage" (an A4 page); nil reads as "fullpage".
    var style: String? = nil
    /// PDF only: the page, when it is not the style's own.
    var paper: PagePaper? = nil
    var margins: PageMargins? = nil
    var fontSize: String? = nil
    var numberSections: Bool = true
    var includeContact: Bool = false
    var extraArgs: [String] = []
    /// PDF only: facing pages, as a printed book; single pages (nil) have the same margin left and right.
    var facing: Bool? = nil
    /// PDF only: a manuscript for submission, by a country's norm (Typst's `manuscript` style).
    var manuscript: ManuscriptNorm? = nil
    /// A manuscript sent under a pseudonym (literary prizes): no name, no contact, the pseudonym instead.
    var pseudonym: String? = nil
    /// PDF only: a book's interior for the printer, without the cover (sent to the printer as its own file).
    var interior: Bool? = nil

    /// The name in the interface's language: a built-in preset's English name is a key of the tables; a name the author typed has none and shows as is.
    var shownName: String { L(dynamic: name) }
}

extension ExportPreset: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, name, format, template, style, paper, margins, fontSize, numberSections, includeContact, extraArgs, facing, manuscript, pseudonym, interior
        /// Written by Musset when PDFs went through LaTeX: `geometry` is read once into `paper` and `margins`;
        /// `cropMarks` is still written (false) because those versions cannot read a preset without it.
        case geometry, cropMarks
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        format = try c.decode(ExportFormat.self, forKey: .format)
        template = try c.decodeIfPresent(String.self, forKey: .template)
        style = try c.decodeIfPresent(String.self, forKey: .style)
        paper = try c.decodeIfPresent(PagePaper.self, forKey: .paper)
        margins = try c.decodeIfPresent(PageMargins.self, forKey: .margins)
        fontSize = try c.decodeIfPresent(String.self, forKey: .fontSize)
        numberSections = try c.decodeIfPresent(Bool.self, forKey: .numberSections) ?? true
        includeContact = try c.decodeIfPresent(Bool.self, forKey: .includeContact) ?? false
        extraArgs = try c.decodeIfPresent([String].self, forKey: .extraArgs) ?? []
        facing = try c.decodeIfPresent(Bool.self, forKey: .facing)
        manuscript = try c.decodeIfPresent(ManuscriptNorm.self, forKey: .manuscript)
        pseudonym = try c.decodeIfPresent(String.self, forKey: .pseudonym)
        interior = try c.decodeIfPresent(Bool.self, forKey: .interior)
        if let old = try c.decodeIfPresent(String.self, forKey: .geometry) {
            let page = Self.page(geometry: old)
            paper = paper ?? page.paper
            margins = margins ?? page.margins
        }
        if format == .pdf, manuscript == nil {
            // A PDF preset older than the styles named a LaTeX template: it only said which style to use.
            if style == nil { style = (template ?? id).lowercased().contains("blanche") ? "book" : "fullpage" }
            template = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(format, forKey: .format)
        try c.encodeIfPresent(template, forKey: .template)
        try c.encodeIfPresent(style, forKey: .style)
        try c.encodeIfPresent(paper, forKey: .paper)
        try c.encodeIfPresent(margins, forKey: .margins)
        try c.encodeIfPresent(fontSize, forKey: .fontSize)
        try c.encode(numberSections, forKey: .numberSections)
        try c.encode(false, forKey: .cropMarks)
        try c.encode(includeContact, forKey: .includeContact)
        try c.encode(extraArgs, forKey: .extraArgs)
        try c.encodeIfPresent(facing, forKey: .facing)
        try c.encodeIfPresent(manuscript, forKey: .manuscript)
        try c.encodeIfPresent(pseudonym, forKey: .pseudonym)
        try c.encodeIfPresent(interior, forKey: .interior)
    }

    /// The page an old LaTeX geometry string describes ("paperwidth=148mm,paperheight=210mm,inner=20mm,…").
    static func page(geometry: String) -> (paper: PagePaper?, margins: PageMargins?) {
        var kv: [String: String] = [:]
        for part in geometry.split(separator: ",") {
            let pair = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if pair.count == 2 { kv[pair[0]] = pair[1] }
        }
        let paper = kv["paperwidth"].flatMap { w in kv["paperheight"].map { PagePaper(width: w, height: $0) } }
        let margins = PageMargins(inside: kv["inner"], outside: kv["outer"], left: kv["left"], right: kv["right"], top: kv["top"], bottom: kv["bottom"])
        return (paper, margins == PageMargins() ? nil : margins)
    }
}

extension CodingUserInfoKey {
    /// Set by a reader that never writes the manifest back: what it cannot read (a layout, a setting from a newer
    /// Musset) is left out instead of refusing the book. The Mac app, which saves what it loaded, refuses.
    static let readingOnly = CodingUserInfoKey(rawValue: "musset.readingOnly")!
}

extension KeyedDecodingContainer {
    /// A value that may be missing; one that cannot be read is an error, or nothing for a reader (`readingOnly`).
    fileprivate func optional<T: Decodable>(_ key: Key, lenient: Bool) throws -> T? {
        lenient ? (try? decodeIfPresent(T.self, forKey: key)) ?? nil : try decodeIfPresent(T.self, forKey: key)
    }
}

extension BookManifest: Decodable {
    /// The manifest a reader takes from a book it only reads.
    static func forReading(_ data: Data) throws -> BookManifest {
        let decoder = JSONDecoder()
        decoder.userInfo[.readingOnly] = true
        return try decoder.decode(BookManifest.self, from: data)
    }

    /// Only the title and the chapters are required: everything else has its default when the file does not say.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let lenient = decoder.userInfo[.readingOnly] != nil
        title = try c.decode(String.self, forKey: .title)
        chapters = try c.decode([ChapterEntry].self, forKey: .chapters)
        author = try c.optional(.author, lenient: lenient) ?? ""
        lang = try c.optional(.lang, lenient: lenient) ?? "fr"
        contact = try c.optional(.contact, lenient: lenient) ?? ""
        exports = try c.optional(.exports, lenient: lenient) ?? []
        layoutSettings = try c.optional(.layoutSettings, lenient: lenient)
        formatVersion = try c.optional(.formatVersion, lenient: lenient) ?? 1
        sceneBreak = try c.optional(.sceneBreak, lenient: lenient)
        subtitle = try c.optional(.subtitle, lenient: lenient)
        goal = try c.optional(.goal, lenient: lenient)
        front = try c.optional(.front, lenient: lenient)
        shelf = try c.optional(.shelf, lenient: lenient)
        genre = try c.optional(.genre, lenient: lenient)
        drafts = try c.optional(.drafts, lenient: lenient)
        parts = try c.optional(.parts, lenient: lenient)
        structure = try c.optional(.structure, lenient: lenient)
    }
}

extension ChapterEntry: Decodable {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let lenient = decoder.userInfo[.readingOnly] != nil
        id = try c.decode(String.self, forKey: .id)
        file = try c.decode(String.self, forKey: .file)
        title = try c.decode(String.self, forKey: .title)
        activeVersion = try c.optional(.activeVersion, lenient: lenient) ?? "main"
        excludeFromExport = try c.optional(.excludeFromExport, lenient: lenient) ?? false
        status = try c.optional(.status, lenient: lenient)
        part = try c.optional(.part, lenient: lenient)
        kind = try c.optional(.kind, lenient: lenient)
        strand = try c.optional(.strand, lenient: lenient)
    }
}

/// A part of the book: I, II, III… with an optional title. Its chapters are the ones that name it, one run in the book's order.
struct BookPart: Codable, Equatable, Identifiable, Hashable {
    var id: String = UUID().uuidString
    var title: String = ""
}

extension BookManifest {
    /// Parts in the book's order: by where their first chapter stands, empty ones last.
    var orderedParts: [BookPart] {
        let all = parts ?? []
        var seen: [String] = []
        for ch in chapters { if let p = ch.part, !seen.contains(p), all.contains(where: { $0.id == p }) { seen.append(p) } }
        return seen.compactMap { id in all.first { $0.id == id } } + all.filter { !seen.contains($0.id) }
    }

    static func roman(_ n: Int) -> String {
        guard n > 0 else { return "" }
        let table: [(Int, String)] = [(1000, "M"), (900, "CM"), (500, "D"), (400, "CD"), (100, "C"), (90, "XC"),
                                      (50, "L"), (40, "XL"), (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I")]
        var n = n, out = ""
        for (value, letters) in table { while n >= value { out += letters; n -= value } }
        return out
    }
}

/// The book's special pages, around the chapters: cover, title page, dedication, epigraph, contents,
/// and at the end acknowledgements and colophon. Kept in the manifest; typeset with the book, never in a chapter file.
struct FrontMatter: Codable, Equatable {
    struct Cover: Codable, Equatable {
        /// "typographic", "image" or "plain".
        var style: String = "typographic"
        var genre: String = ""
        var publisher: String = ""
        var ground: String = "#F3EEE2"
        var accent: String = "#9B2F26"
        /// Image path relative to the book folder, for the "image" style.
        var image: String? = nil
        var inPDF: Bool = true
    }

    var cover: Cover? = nil
    var titlePage: Bool? = nil
    var dedication: String? = nil
    var epigraph: String? = nil
    var epigraphSource: String? = nil
    var contents: Bool? = nil
    var acknowledgements: String? = nil
    var colophon: Bool? = nil

    func has(_ page: SpecialPage) -> Bool {
        switch page {
        case .cover: cover?.inPDF ?? false
        case .title: titlePage ?? true
        case .dedication: !(dedication ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .epigraph: !(epigraph ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .contents: contents ?? false
        case .acknowledgements: !(acknowledgements ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .colophon: colophon ?? false
        }
    }
}

enum SpecialPage: String, CaseIterable, Identifiable, Hashable {
    case cover, title, dedication, epigraph, contents, acknowledgements, colophon
    var id: String { rawValue }
    var isBack: Bool { self == .acknowledgements || self == .colophon }
    var label: String {
        switch self {
        case .cover: L("Cover")
        case .title: L("Title page")
        case .dedication: L("Dedication")
        case .epigraph: L("Epigraph")
        case .contents: L("Contents", ctx: "Table des matières")
        case .acknowledgements: L("Acknowledgements")
        case .colophon: L("Colophon")
        }
    }
    var icon: String {
        switch self {
        case .cover: "rectangle.portrait"
        case .title: "textformat.size"
        case .dedication: "heart.text.square"
        case .epigraph: "quote.opening"
        case .contents: "list.bullet.indent"
        case .acknowledgements: "hands.sparkles"
        case .colophon: "seal"
        }
    }
    static var front: [SpecialPage] { allCases.filter { !$0.isBack } }
    static var back: [SpecialPage] { allCases.filter(\.isBack) }
}

/// How a change of scene shows on the printed page.
enum SceneBreak: String, Codable, CaseIterable, Identifiable {
    case none, blank, asterism
    var id: String { rawValue }
    var label: String {
        switch self {
        case .none: "Nothing"
        case .blank: "Blank line"
        case .asterism: "⁂"
        }
    }
}

/// Where a book stands on the shelf.
enum Shelf: String, Codable, CaseIterable, Identifiable {
    case ongoing, finished, aside
    var id: String { rawValue }
    var label: String {
        switch self {
        case .ongoing: L("In progress")
        case .finished: L("Finished", ctx: "Terminés")
        case .aside: L("Set aside", ctx: "Mis de côté")
        }
    }
    var verb: String {
        switch self {
        case .ongoing: L("Back in progress")
        case .finished: L("Mark as finished")
        case .aside: L("Set aside", ctx: "Mettre de côté")
        }
    }
}

/// How a manuscript is presented to publishers in each country: page, face, spacing, and the count they expect.
enum ManuscriptNorm: String, Codable, CaseIterable, Identifiable {
    /// English standard manuscript (William Shunn): US Letter or A4, double spaced, word count rounded to 100.
    case shunnUS = "shunn-us", shunnUK = "shunn-uk"
    /// French manuscript: A4, Garamond 12 pt, double spaced; counted in feuillets of 1,500 signs.
    case feuillet
    /// German Normseite: 30 lines of 60 characters, 1,800 a page.
    case normseite
    /// Italian cartella editoriale: 30 lines of 60 battute, 1,800 a page.
    case cartella
    /// Spanish: A4, Times 12, 1.5 spacing; counted in characters with spaces.
    case spanish = "es"
    /// Portuguese: A4, Times 12, 1.5 spacing, 3/2 cm margins; counted in characters with spaces.
    case portugueseBR = "pt-br", portuguesePT = "pt-pt"

    var id: String { rawValue }
}
