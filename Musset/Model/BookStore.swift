import Foundation

/// Reads and writes a book folder. Never deletes or moves the author's files:
/// it only writes canonical chapter files and the hidden `.musset/` folder.
struct BookStore {
    let root: URL
    private let fm = FileManager.default

    var mussetDir: URL { root.appendingPathComponent(".musset", isDirectory: true) }
    var manifestURL: URL { mussetDir.appendingPathComponent("book.json") }
    var stateURL: URL { mussetDir.appendingPathComponent("state.json") }
    var versionsDir: URL { mussetDir.appendingPathComponent("versions", isDirectory: true) }
    var exportsDir: URL { mussetDir.appendingPathComponent("exports", isDirectory: true) }
    var chatDir: URL { mussetDir.appendingPathComponent("chat", isDirectory: true) }
    var pangramDir: URL { mussetDir.appendingPathComponent("pangram", isDirectory: true) }

    var hasManifest: Bool { fm.fileExists(atPath: manifestURL.path) }

    // MARK: Manifest

    func loadManifest() throws -> BookManifest {
        let data = try Data(contentsOf: manifestURL)
        var m = try JSONDecoder().decode(BookManifest.self, from: data)
        dropStoredBuiltIns(&m)
        return m
    }

    func saveManifest(_ m: BookManifest) throws {
        try ensureMussetDir()
        try JSONFile.write(m, to: manifestURL)
    }

    func ensureMussetDir() throws {
        try fm.createDirectory(at: mussetDir, withIntermediateDirectories: true)
        let ignore = mussetDir.appendingPathComponent(".gitignore")
        // `*.sb-*`: the temporary file of an atomic save, never part of the book.
        let wanted = ["chat/", "pangram/", "exports/", "proof/", "typst/", "state.json", "*.sb-*"]
        let current = (try? String(contentsOf: ignore, encoding: .utf8)) ?? ""
        let lines = Set(current.split(separator: "\n").map(String.init))
        let missing = wanted.filter { !lines.contains($0) }
        if !missing.isEmpty {
            let prefix = current.isEmpty || current.hasSuffix("\n") ? current : current + "\n"
            try (prefix + missing.joined(separator: "\n") + "\n").write(to: ignore, atomically: true, encoding: .utf8)
        }
    }

    func loadState() -> BookUIState {
        JSONFile.read(at: stateURL) ?? BookUIState()
    }

    func saveState(_ s: BookUIState) {
        try? ensureMussetDir()
        try? JSONFile.write(s, to: stateURL, [])
    }

    /// The chapter's title as its heading gives it; nil when there is none, or while it is still empty.
    static func heading(in text: String) -> String? { PieceText.heading(in: text) }

    /// The text with a new heading, its `{.attributes}` kept; nil when it has no heading.
    static func retitled(_ text: String, to title: String) -> String? {
        guard let line = PieceText.headingLine(in: text) else { return nil }
        let attributes = line.range(of: PieceText.headingAttributes, options: .regularExpression).map { String(line[$0]) } ?? ""
        return text.replacingCharacters(in: line.startIndex..<line.endIndex, with: "# \(title)\(attributes)")
    }

    /// Existing templates in `templates/`, by kind.
    func findTemplate(_ predicate: (String) -> Bool) -> String? {
        let names = ((try? fm.contentsOfDirectory(atPath: root.appendingPathComponent("templates").path)) ?? []).sorted()
        return names.first(where: predicate).map { "templates/\($0)" }
    }

    /// Where new books go: ~/writings when the author already keeps books there, else ~/Documents/Musset.
    static var defaultFolder: URL {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let writings = home.appendingPathComponent("writings")
        if FileManager.default.fileExists(atPath: writings.path) { return writings }
        return home.appendingPathComponent("Documents/Musset")
    }

    /// Trade sizes where the book's language is published: the usual trims of its market.
    /// A book page set the way the 120 × 188 mm literary format is: a text block about 25 ems wide, margins wider
    /// inside than outside, the foot a little taller than the head.
    static func book(_ id: String, _ name: String, _ w: String, _ h: String, inner: String, outer: String, top: String, bottom: String,
                     size: String, facing: Bool, interior: Bool = false) -> ExportPreset {
        var p = ExportPreset(id: id, name: name, format: .pdf, style: "book", paper: PagePaper(width: w, height: h),
                             margins: PageMargins(inside: inner, outside: outer, top: top, bottom: bottom), fontSize: size, numberSections: false)
        p.facing = facing
        p.interior = interior
        return p
    }

    /// The book's two editions beside its submission manuscript:
    /// - for readers: a PDF read on a screen or a tablet, the Blanche page on single pages, the cover included;
    /// - for the printer: the interior of the self-published book at its market's usual trim (one Amazon KDP, IngramSpark
    ///   and the European print-on-demand houses all take), facing pages, no cover (the printer takes it apart), no crop marks.
    static func editions(for book: BookLanguage) -> [ExportPreset] {
        // The French literary page (Gallimard's Blanche): 120 × 188 mm at 10.8/13, its two side margins made one.
        let reader = Self.book("reader", "PDF for readers", "120mm", "188mm", inner: "17mm", outer: "17mm", top: "16mm", bottom: "20mm", size: "10.8pt", facing: false)
        func print(_ w: String, _ h: String, _ inner: String, _ outer: String, _ top: String, _ bottom: String, _ size: String) -> ExportPreset {
            Self.book("print", "PDF for the printer", w, h, inner: inner, outer: outer, top: top, bottom: bottom, size: size, facing: true, interior: true)
        }
        let printer: ExportPreset = switch book {
        case .enUS: print("5.5in", "8.5in", "0.85in", "0.65in", "0.72in", "0.9in", "11pt")
        case .enGB: print("129mm", "198mm", "20mm", "15mm", "17mm", "21mm", "10.8pt")
        case .frFR: print("130mm", "200mm", "20mm", "15mm", "17mm", "21mm", "10.8pt")
        case .deDE, .deCH: print("120mm", "190mm", "20mm", "14mm", "16mm", "20mm", "10.8pt")
        case .esES, .es419, .ptPT: print("150mm", "230mm", "24mm", "19mm", "19.5mm", "24mm", "11.5pt")
        case .itIT, .ptBR: print("140mm", "210mm", "22mm", "17mm", "18mm", "22mm", "11pt")
        }
        return [reader, printer]
    }

    /// Musset's own layouts for a book in this language: its country's submission manuscript, the two PDF editions,
    /// Word and EPUB (with the book's own reference document or stylesheet, if `templates/` has one).
    func builtInPresets(lang: String) -> [ExportPreset] {
        let book = BookLanguage(code: lang)
        let refDoc = findTemplate { $0.hasSuffix(".docx") }
        let css = findTemplate { $0.hasPrefix("epub") && $0.hasSuffix(".css") }
        return [ManuscriptNorm.for(book).preset] + Self.editions(for: book) + [
            ExportPreset(id: "docx", name: "Word (.docx)", format: .docx, template: refDoc),
            ExportPreset(id: "epub", name: "EPUB", format: .epub, template: css, numberSections: false),
        ]
    }

    /// Every layout the book can be exported in: Musset's own, made now for the book's language and carrying what
    /// the author set on them, then the author's (one that bears the id of a built-in stands in its place).
    func presets(_ m: BookManifest) -> [ExportPreset] {
        let own = Set(m.exports.map(\.id))
        let builtIn = builtInPresets(lang: m.lang).filter { !own.contains($0.id) }.map { p -> ExportPreset in
            var p = p
            p.pseudonym = m.layoutSettings?[p.id]?.pseudonym
            return p
        }
        return builtIn.filter { $0.format == .pdf } + m.exports + builtIn.filter { $0.format != .pdf }
    }

    /// The PDF layouts earlier versions of Musset made: each book now has the two editions instead.
    static let retiredLayouts: Set<String> = ["manuscript-a4", "blanche", "book-120x188", "book-a5", "print-trade", "trade-5.5x8.5", "trade-6x9",
                                              "b-format", "book-125x205", "book-130x200", "book-140x210", "book-150x230", "book-160x230"]

    /// A `book.json` written when Musset kept its own layouts in it: they go (they are made at use now), a
    /// manuscript's pseudonym stays as a setting, and what the author made or changed stays as it is.
    /// A manifest in today's form holds none of them, and comes out as it went in.
    func dropStoredBuiltIns(_ m: inout BookManifest) {
        guard !m.exports.isEmpty else { return }
        let builtIn = Dictionary(uniqueKeysWithValues: builtInPresets(lang: m.lang).map { ($0.id, $0) })
        var kept: [ExportPreset] = []
        for p in m.exports {
            if p.format == .pdf, let norm = p.manuscript, p.id == norm.preset.id {
                // Any country's manuscript Musset made, not only the one of the book's language today.
                if let name = p.pseudonym, m.layoutSettings?[p.id] == nil { m.setPseudonymSetting(name, for: p.id) }
            } else if p.format == .pdf, p.manuscript == nil, Self.retiredLayouts.contains(p.id) || p.id == "reader" || p.id == "print" {
                continue
            } else if var made = builtIn[p.id], made.format != .pdf {
                // Word and EPUB as Musset made them (whatever template was found then) go; changed by hand, they are the author's.
                made.template = p.template
                if made != p { kept.append(p) }
            } else {
                kept.append(p)
            }
        }
        m.exports = kept
    }

        // MARK: Chapters & versions

    func url(for chapter: ChapterEntry) -> URL { root.appendingPathComponent(chapter.file) }

    /// A store that reads the book as it was at a revision (a milestone, a track): for exports. Nil: the folder.
    var revision: String?
    /// How that revision is named in exported file names.
    var revisionName: String?

    func read(_ chapter: ChapterEntry) -> String {
        if let revision { return GitService(root: root).show(revision, path: chapter.file) ?? "" }
        return (try? String(contentsOf: url(for: chapter), encoding: .utf8)) ?? ""
    }

    func write(_ text: String, to chapter: ChapterEntry) throws {
        let u = url(for: chapter)
        try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: u, atomically: true, encoding: .utf8)
    }

    func versionsFolder(for chapter: ChapterEntry) -> URL {
        versionsDir.appendingPathComponent(chapter.id, isDirectory: true)
    }

    func versionURL(_ chapter: ChapterEntry, _ name: String) -> URL {
        versionsFolder(for: chapter).appendingPathComponent(name + ".md")
    }

    /// All versions of a chapter, active one first.
    func versions(of chapter: ChapterEntry) -> [String] {
        let alternates = ((try? fm.contentsOfDirectory(atPath: versionsFolder(for: chapter).path)) ?? [])
            .filter { $0.hasSuffix(".md") }
            .map { String($0.dropLast(3)) }
            .filter { $0 != chapter.activeVersion }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return [chapter.activeVersion] + alternates
    }

    func readVersion(_ chapter: ChapterEntry, _ name: String) -> String {
        if name == chapter.activeVersion { return read(chapter) }
        return (try? String(contentsOf: versionURL(chapter, name), encoding: .utf8)) ?? ""
    }

    func saveVersion(_ chapter: ChapterEntry, name: String, text: String) throws {
        try fm.createDirectory(at: versionsFolder(for: chapter), withIntermediateDirectories: true)
        try text.write(to: versionURL(chapter, name), atomically: true, encoding: .utf8)
    }

    func uniqueVersionName(_ chapter: ChapterEntry, base: String) -> String {
        let existing = Set(versions(of: chapter))
        let clean = sanitize(base)
        if !existing.contains(clean) { return clean }
        var i = 2
        while existing.contains("\(clean)-\(i)") { i += 1 }
        return "\(clean)-\(i)"
    }

    /// Today's date and the next free number: « 2026-11-01-1 », « 2026-11-01-2 »…
    func datedVersionName(_ chapter: ChapterEntry, on date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        let day = f.string(from: date)
        let existing = Set(versions(of: chapter))
        var i = 1
        while existing.contains("\(day)-\(i)") { i += 1 }
        return "\(day)-\(i)"
    }

    /// A version's name as typed, safe as a file name: no folder separator, no control character, no leading dot.
    func sanitize(_ name: String) -> String {
        var s = String(name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespaces)
        while s.hasPrefix(".") { s.removeFirst() }
        s = s.trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? "version" : String(s.prefix(80))
    }

    /// Swaps `name` into the canonical file; the previous active text is kept as an alternate.
    /// Returns the updated entry.
    func activate(_ chapter: ChapterEntry, version name: String) throws -> ChapterEntry {
        guard name != chapter.activeVersion else { return chapter }
        let incoming = readVersion(chapter, name)
        let outgoing = read(chapter)
        try saveVersion(chapter, name: chapter.activeVersion, text: outgoing)
        try write(incoming, to: chapter)
        try? fm.removeItem(at: versionURL(chapter, name))
        var updated = chapter
        updated.activeVersion = name
        return updated
    }

    func renameVersion(_ chapter: ChapterEntry, from old: String, to new: String) throws -> ChapterEntry {
        let new = uniqueVersionName(chapter, base: new)
        var updated = chapter
        if old == chapter.activeVersion {
            updated.activeVersion = new
        } else {
            try fm.moveItem(at: versionURL(chapter, old), to: versionURL(chapter, new))
        }
        return updated
    }

    func deleteVersion(_ chapter: ChapterEntry, _ name: String) throws {
        guard name != chapter.activeVersion else { return }
        // Recoverable through git history: version files are committed.
        try fm.removeItem(at: versionURL(chapter, name))
    }

    // MARK: Export source

    /// Active chapters concatenated in manifest order, like build_version_longue.sh.
    func concatenatedManuscript(_ m: BookManifest, stripComments: Bool) -> String {
        var out = ""
        let parts = m.groupOpenings
        for ch in m.chapters where !ch.excludeFromExport {
            // « II. La fuite », « Acte II. La fuite »; a group level without numbers has only its title to print.
            if let p = parts[ch.id] { out += "# " + [p.line, p.title].filter { !$0.isEmpty }.joined(separator: ". ") + " {.unnumbered .part}\n\n" }
            // The lists the book has, and no other: « 1943. Barcelone. » is not pandoc's to number.
            let source = ListLines.forPandoc(Revisions.resolveAll(read(ch), accept: false), m.printedListOptions)
            var text = Self.sceneBreaks(Self.opened(source, m.opening(of: ch, text: source)), m.sceneBreak ?? .none)
            if stripComments { text = Self.stripHTMLComments(text) }
            out += text
            if !out.hasSuffix("\n") { out += "\n" }
            out += "\n"
        }
        return out
    }

    /// A formed book's piece as pandoc reads it: its line written into its heading (« # Chapitre 3. Le port »,
    /// « # Prologue »), which the contents then list; a text without a heading is given one. Nil: the text as it is.
    static func opened(_ text: String, _ opening: PieceOpening?) -> String {
        guard let opening else { return text }
        if let title = opening.title {
            return "# " + [opening.label, title].compactMap { $0 }.joined(separator: ". ") + "\n\n" + text
        }
        guard let label = opening.label, let line = PieceText.headingLine(in: text) else { return text }
        return text.replacingCharacters(in: line.startIndex..<line.endIndex, with: "# " + label + ". " + line.dropFirst(2))
    }

    /// Scene markers as the export shows them (pandoc formats): nothing, a blank paragraph or an asterism.
    /// The first scene of a chapter gets no break.
    static func sceneBreaks(_ text: String, _ mode: SceneBreak) -> String {
        guard mode != .none else { return text }
        let ns = text as NSString
        var out = text as NSString
        for m in Scenes.pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let before = ns.substring(to: m.range.location).components(separatedBy: .newlines)
                .filter { !$0.hasPrefix("#") && !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.hasPrefix("<!--") }
            guard !before.isEmpty else { continue }
            out = out.replacingCharacters(in: m.range, with: mode == .asterism ? "⁂" : "&nbsp;") as NSString
        }
        return out as String
    }

    private static let htmlComment = try! NSRegularExpression(pattern: #"<!--.*?-->\n?"#, options: [.dotMatchesLineSeparators])

    static func stripHTMLComments(_ text: String) -> String {
        // Most paragraphs have none: no copy, no regex pass.
        guard text.contains("<!--") else { return text }
        return htmlComment.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
    }

    static func wordCount(_ text: String) -> Int {
        var count = 0
        let body = stripHTMLComments(text)
        body.enumerateSubstrings(in: body.startIndex..<body.endIndex, options: [.byWords, .substringNotRequired]) { _, _, _, _ in count += 1 }
        return count
    }
}
