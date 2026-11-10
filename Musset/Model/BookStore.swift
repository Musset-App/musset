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
        // Every book can submit by its country's norm, even one made before the norms existed.
        let norm = ManuscriptNorm.for(BookLanguage(code: m.lang))
        if !m.exports.isEmpty, !m.exports.contains(where: { $0.manuscript == norm }) { m.exports.insert(norm.preset, at: 0) }
        return m
    }

    func saveManifest(_ m: BookManifest) throws {
        try ensureMussetDir()
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try enc.encode(m).write(to: manifestURL, options: .atomic)
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
        (try? JSONDecoder().decode(BookUIState.self, from: Data(contentsOf: stateURL))) ?? BookUIState()
    }

    func saveState(_ s: BookUIState) {
        try? ensureMussetDir()
        try? JSONEncoder().encode(s).write(to: stateURL, options: .atomic)
    }

    // MARK: Seeding

    /// Builds a first manifest by reading the book's existing build scripts,
    /// falling back to numbered or scene Markdown files.
    func seedManifest() -> BookManifest {
        let files = detectChapterFiles()
        let chapters = files.map { file -> ChapterEntry in
            let id = (file as NSString).lastPathComponent.replacingOccurrences(of: ".md", with: "")
            return ChapterEntry(id: uniqueSafeID(id), file: file, title: readTitle(file) ?? id)
        }
        let meta = detectMetadata()
        var m = BookManifest(title: meta.title ?? root.lastPathComponent.capitalized,
                             lang: meta.lang ?? "fr", chapters: chapters)
        m.contact = meta.contact ?? ""
        m.exports = defaultPresets(lang: m.lang)
        return m
    }

    func detectChapterFiles() -> [String] {
        for script in ["build_version_longue.sh", "build.sh", "build_blanche.sh"] {
            if let list = parseFilesArray(in: root.appendingPathComponent(script)), !list.isEmpty {
                return list.filter { fm.fileExists(atPath: root.appendingPathComponent($0).path) }
            }
        }
        let numbered = markdownFiles(in: root).filter { $0.first?.isNumber == true }
        if !numbered.isEmpty { return numbered.sorted { $0.localizedStandardCompare($1) == .orderedAscending } }
        for sub in ["scenes", "chapters", "chapitres"] {
            let dir = root.appendingPathComponent(sub)
            let files = markdownFiles(in: dir).filter { !$0.hasSuffix(".en.md") }
            if !files.isEmpty {
                return files.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { "\(sub)/\($0)" }
            }
        }
        return []
    }

    /// Parses `FILES=( "a.md" "b.md" … )` from a bash script.
    func parseFilesArray(in script: URL) -> [String]? {
        guard let text = try? String(contentsOf: script, encoding: .utf8),
              let start = text.range(of: "FILES=(") else { return nil }
        let rest = text[start.upperBound...]
        guard let end = rest.firstIndex(of: ")") else { return nil }
        let body = rest[..<end]
        let regex = try! NSRegularExpression(pattern: #"["']([^"']+\.md)["']"#)
        let s = String(body)
        return regex.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap {
            Range($0.range(at: 1), in: s).map { String(s[$0]) }
        }
    }

    private func markdownFiles(in dir: URL) -> [String] {
        ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".md") }
    }

    func readTitle(_ file: String) -> String? {
        (try? String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)).flatMap(Self.heading(in:))
    }

    /// The line of a chapter's `# ` heading: near the top, outside HTML comments.
    private static func headingLine(in text: String) -> Substring? {
        var inComment = false, lines = 0
        for piece in text.split(separator: "\n", maxSplits: 200, omittingEmptySubsequences: true) {
            let line = piece.prefix { $0 != "\n" }
            if inComment { inComment = !line.contains("-->"); continue }
            if line.hasPrefix("<!--") { inComment = !line.contains("-->"); continue }
            if line.hasPrefix("# ") { return line }
            lines += 1
            if lines == 10 { return nil }
        }
        return nil
    }

    private static let headingAttributes = #"\s*\{[^}]*\}\s*$"#

    /// The chapter's title as its heading gives it; nil when there is none, or while it is still empty.
    static func heading(in text: String) -> String? {
        guard var title = headingLine(in: text).map({ String($0.dropFirst(2)) }) else { return nil }
        for pattern in [headingAttributes, #"\s+#+\s*$"#] {
            if let r = title.range(of: pattern, options: .regularExpression) { title.removeSubrange(r) }
        }
        title = title.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "*_")))
        return title.isEmpty ? nil : title
    }

    /// The text with a new heading, its `{.attributes}` kept; nil when it has no heading.
    static func retitled(_ text: String, to title: String) -> String? {
        guard let line = headingLine(in: text) else { return nil }
        let attributes = line.range(of: headingAttributes, options: .regularExpression).map { String(line[$0]) } ?? ""
        return text.replacingCharacters(in: line.startIndex..<line.endIndex, with: "# \(title)\(attributes)")
    }

    private func uniqueSafeID(_ id: String) -> String {
        id.replacingOccurrences(of: "/", with: "_")
    }

    struct DetectedMeta { var title: String?; var lang: String?; var contact: String? }

    func detectMetadata() -> DetectedMeta {
        var meta = DetectedMeta()
        if let yml = try? String(contentsOf: root.appendingPathComponent("pandoc.yml"), encoding: .utf8) {
            meta.title = firstMatch(#"(?m)^\s*title:\s*"?([^"\n]+)"?"#, in: yml)
            meta.lang = firstMatch(#"(?m)^\s*lang:\s*"?([a-zA-Z-]+)"?"#, in: yml)
        }
        for script in ["build.sh", "build_blanche.sh"] {
            guard let sh = try? String(contentsOf: root.appendingPathComponent(script), encoding: .utf8) else { continue }
            meta.title = meta.title ?? firstMatch(#"title="([^"]+)""#, in: sh)
            meta.lang = meta.lang ?? firstMatch(#"lang="([a-zA-Z-]+)""#, in: sh)
            meta.contact = meta.contact ?? firstMatch(#"CONTACT="([^"]+)""#, in: sh)
        }
        return meta
    }

    private func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r]).trimmingCharacters(in: .whitespaces)
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
    static func trims(for book: BookLanguage) -> [ExportPreset] {
        func trim(_ id: String, _ name: String, _ w: String, _ h: String, _ inner: String, _ outer: String, _ top: String, _ bottom: String, crop: Bool = false) -> ExportPreset {
            ExportPreset(id: id, name: name, format: .pdf,
                         geometry: "paperwidth=\(w),paperheight=\(h),inner=\(inner),outer=\(outer),top=\(top),bottom=\(bottom)",
                         fontSize: "10pt", cropMarks: crop)
        }
        switch book {
        case .enUS:
            return [trim("trade-5.5x8.5", "Trade paperback 5.5×8.5 in", "5.5in", "8.5in", "0.8in", "0.6in", "0.75in", "0.8in"),
                    trim("trade-6x9", "Trade paperback 6×9 in", "6in", "9in", "0.875in", "0.625in", "0.75in", "0.85in")]
        case .enGB:
            return [trim("b-format", "B-format paperback 129×198 mm", "129mm", "198mm", "20mm", "15mm", "18mm", "20mm")]
        case .deDE, .deCH:
            return [trim("book-125x205", "Book 12.5×20.5 cm", "125mm", "205mm", "20mm", "15mm", "18mm", "21mm")]
        case .esES, .es419, .itIT:
            return [trim("book-130x200", "Book 13×20 cm", "130mm", "200mm", "20mm", "15mm", "18mm", "20mm"),
                    trim("book-140x210", "Book 14×21 cm", "140mm", "210mm", "21mm", "16mm", "19mm", "22mm")]
        case .ptBR:
            return [trim("book-140x210", "Book 14×21 cm", "140mm", "210mm", "21mm", "16mm", "19mm", "22mm"),
                    trim("book-160x230", "Book 16×23 cm", "160mm", "230mm", "22mm", "17mm", "20mm", "23mm")]
        case .ptPT:
            return [trim("book-150x230", "Book 15×23 cm", "150mm", "230mm", "22mm", "17mm", "20mm", "23mm")]
        case .frFR:
            return []
        }
    }

    func defaultPresets(lang: String = "fr") -> [ExportPreset] {
        let book = BookLanguage(code: lang)
        let classique = findTemplate { $0.hasPrefix("template-classique") && $0.hasSuffix(".tex") }
        let blanche = findTemplate { $0.hasPrefix("template-blanche") && $0.hasSuffix(".tex") }
        let refDoc = findTemplate { $0.hasSuffix(".docx") }
        let css = findTemplate { $0.hasPrefix("epub") && $0.hasSuffix(".css") }
        // The classique template honours $geometry$; blanche templates hard-code their own 120×188 page,
        // so blanche only gets its own preset and is never given a geometry.
        var presets = [ManuscriptNorm.for(book).preset]
        guard book == .frFR else { return presets + Self.trims(for: book) + [
            ExportPreset(id: "docx", name: "Word (.docx)", format: .docx, template: refDoc),
            ExportPreset(id: "epub", name: "EPUB", format: .epub, template: css, numberSections: false),
        ] }
        presets += [
            ExportPreset(id: "manuscript-a4", name: "Manuscript A4 (publisher submission)", format: .pdf,
                         template: classique,
                         geometry: "paperwidth=210mm,paperheight=297mm,left=38mm,right=38mm,top=50mm,bottom=50mm,headsep=8mm,footskip=14mm",
                         includeContact: true),
        ]
        if let blanche {
            presets.append(ExportPreset(id: "blanche", name: "Book 120×188 (your Blanche template)", format: .pdf, template: blanche))
        }
        presets += [
            ExportPreset(id: "book-a5", name: "Book A5", format: .pdf, template: classique,
                         geometry: "paperwidth=148mm,paperheight=210mm,inner=20mm,outer=16mm,top=20mm,bottom=22mm,headsep=6mm,footskip=10mm",
                         fontSize: "10pt"),
            ExportPreset(id: "print-trade", name: "Print-ready 5.5×8.5 in (crop marks)", format: .pdf,
                         template: classique,
                         geometry: "paperwidth=5.5in,paperheight=8.5in,inner=0.8in,outer=0.6in,top=0.75in,bottom=0.8in,headsep=6mm,footskip=10mm",
                         fontSize: "10pt", cropMarks: true),
            ExportPreset(id: "docx", name: "Word (.docx)", format: .docx, template: refDoc),
            ExportPreset(id: "epub", name: "EPUB", format: .epub, template: css, numberSections: false),
        ]
        return presets
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

    /// Finds loose revision files (e.g. `old_book/work/03_harbour_r12.md`, `drafts/01_the_ferry_draft.md`)
    /// that look like versions of a chapter. Originals are left untouched; import copies them.
    func importableRevisions(for chapter: ChapterEntry) -> [(name: String, url: URL)] {
        var found: [(String, URL)] = []
        let stem = chapter.id
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: nil,
                                    options: [.skipsHiddenFiles]) else { return [] }
        let canonical = url(for: chapter).standardizedFileURL
        for case let u as URL in e {
            if u.pathComponents.contains("output") || u.pathComponents.contains("node_modules") { e.skipDescendants(); continue }
            guard u.pathExtension == "md", u.standardizedFileURL != canonical else { continue }
            let base = u.deletingPathExtension().lastPathComponent
            guard base.hasPrefix(stem + "_") || (base == stem && u.deletingLastPathComponent() != canonical.deletingLastPathComponent()) else { continue }
            var suffix: String
            if base == stem {
                let parent = u.deletingLastPathComponent()
                suffix = parent.lastPathComponent == "chapters" ? parent.deletingLastPathComponent().lastPathComponent : parent.lastPathComponent
            } else {
                suffix = String(base.dropFirst(stem.count + 1))
            }
            if suffix.hasSuffix("_draft") { suffix = String(suffix.dropLast(6)) }
            found.append((suffix, u))
        }
        return found.sorted { $0.0.localizedStandardCompare($1.0) == .orderedAscending }
    }

    // MARK: Export source

    /// Active chapters concatenated in manifest order, like build_version_longue.sh.
    func concatenatedManuscript(_ m: BookManifest, stripComments: Bool) -> String {
        var out = ""
        let parts = m.partOpenings
        for ch in m.chapters where !ch.excludeFromExport {
            if let p = parts[ch.id] { out += "# " + p.numeral + (p.title.isEmpty ? "" : ". " + p.title) + " {.unnumbered .part}\n\n" }
            var text = Self.sceneBreaks(Revisions.resolveAll(read(ch), accept: false), m.sceneBreak ?? .none)
            if stripComments { text = Self.stripHTMLComments(text) }
            out += text
            if !out.hasSuffix("\n") { out += "\n" }
            out += "\n"
        }
        return out
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

    static func stripHTMLComments(_ text: String) -> String {
        let re = try! NSRegularExpression(pattern: #"<!--.*?-->\n?"#, options: [.dotMatchesLineSeparators])
        return re.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
    }

    static func wordCount(_ text: String) -> Int {
        var count = 0
        let body = stripHTMLComments(text)
        body.enumerateSubstrings(in: body.startIndex..<body.endIndex, options: [.byWords, .substringNotRequired]) { _, _, _, _ in count += 1 }
        return count
    }
}
