import Foundation
import Observation

/// What an entry of the book's Bible is. Stored as `type:` in its header.
enum BibleKind: String, CaseIterable, Identifiable, Codable {
    case character, place, event, note, draft, biography, web, reference, cut, document
    var id: String { rawValue }
    var label: String {
        switch self {
        case .character: L("Character")
        case .place: L("Place")
        case .event: L("Event")
        case .note: L("Note")
        case .draft: L("Draft")
        case .biography: L("Biography")
        case .web: L("Web page")
        case .reference: L("Reference")
        case .cut: L("Cut", ctx: "Chute")
        case .document: L("Document")
        }
    }
    var icon: String {
        switch self {
        case .character, .biography: "person"
        case .place: "mappin"
        case .event: "calendar"
        case .note: "note.text"
        case .draft: "doc.text"
        case .web: "globe"
        case .reference: "book.closed"
        case .cut: "scissors"
        case .document: "doc"
        }
    }
    /// The folder a new entry of this kind goes to.
    var folder: String {
        switch self {
        case .character, .biography: "personnages"
        case .place: "lieux"
        case .event: "chronologie"
        case .note: "a-trier"
        case .draft: "brouillons"
        case .web, .reference, .document: "documents"
        case .cut: "chutes"
        }
    }
    /// The few fields a new sheet suggests. A drawer, not a form: the rest is free text.
    var suggestedFields: [String] {
        switch self {
        case .character: [L("Born"), L("Occupation"), L("Wants"), L("Hides")]
        case .biography: [L("Born"), L("Died")]
        case .place: [L("Where"), L("When")]
        case .event: [L("Date")]
        default: []
        }
    }
}

/// One Markdown file in `bible/`, or one file of any other type kept there.
struct BibleEntry: Identifiable, Hashable {
    struct Field: Hashable { var name: String; var value: String }

    /// Path relative to `bible/`.
    var path: String
    var kind: BibleKind
    var title: String
    var aliases: [String] = []
    var fields: [Field] = []
    /// Header lines Musset reads itself (source, date, from…), kept apart from the author's fields.
    var meta: [String: String] = [:]
    var body = ""
    var modified = Date.distantPast
    /// A file that is not Markdown (PDF, image…), shown rather than edited.
    var isFile = false

    var id: String { path }
    var folder: String { (path as NSString).deletingLastPathComponent }
    /// Every name this entry goes by in the text.
    var names: [String] { [title] + aliases }

    static let reserved: Set<String> = ["type", "title", "aliases", "source", "date", "from", "context", "citekey", "author", "year", "publisher", "doi", "linked"]

    /// Reads a file's header and body. Text with no header is simply a note.
    static func parse(path: String, text: String, modified: Date = .distantPast) -> BibleEntry {
        let fallback = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        var entry = BibleEntry(path: path, kind: .note, title: fallback, modified: modified)
        guard text.hasPrefix("---\n"), let end = text.range(of: "\n---", range: text.index(text.startIndex, offsetBy: 3)..<text.endIndex) else {
            entry.body = text
            return entry
        }
        for line in text[text.index(text.startIndex, offsetBy: 4)..<end.lowerBound].split(separator: "\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "type": entry.kind = BibleKind(rawValue: value) ?? .note
            case "title": if !value.isEmpty { entry.title = value }
            case "aliases": entry.aliases = value.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            case _ where reserved.contains(key): entry.meta[key] = value
            default: entry.fields.append(Field(name: key, value: value))
            }
        }
        var rest = text[end.upperBound...]
        if rest.hasPrefix("\n") { rest = rest.dropFirst() }
        if rest.hasPrefix("\n") { rest = rest.dropFirst() }
        entry.body = String(rest)
        return entry
    }

    /// The file's text: readable and editable anywhere.
    var serialized: String {
        var head = ["type: \(kind.rawValue)", "title: \(title)"]
        if !aliases.isEmpty { head.append("aliases: " + aliases.joined(separator: ", ")) }
        for key in meta.keys.sorted() { head.append("\(key): \(Self.oneLine(meta[key] ?? ""))") }
        for f in fields where !f.name.isEmpty { head.append("\(f.name): \(Self.oneLine(f.value))") }
        return "---\n" + head.joined(separator: "\n") + "\n---\n\n" + body
    }

    private static func oneLine(_ s: String) -> String {
        s.replacingOccurrences(of: "\n", with: " ")
    }
}

/// Reads and writes `bible/`. Everything else in the book's folder stays out of its reach.
struct BibleStore {
    static let folderName = "bible"
    static let documents = "documents"
    let root: URL
    private var fm: FileManager { .default }

    var dir: URL { root.appendingPathComponent(Self.folderName, isDirectory: true) }
    func url(_ path: String) -> URL { dir.appendingPathComponent(path) }

    /// The folders offered from the start, in order, even empty.
    static let standardFolders = ["a-trier", "personnages", "lieux", "chronologie", "documents", "brouillons", "chutes"]

    static func folderLabel(_ path: String) -> String {
        switch path {
        case "a-trier": L("To sort")
        case "personnages": L("Characters")
        case "lieux": L("Places")
        case "chronologie": L("Timeline")
        case "documents": L("Documents")
        case "brouillons": L("Drafts")
        case "chutes": L("Cuts")
        default: (path as NSString).lastPathComponent
        }
    }

    /// Every entry and folder under `bible/`. A `.pdf.md` beside a file holds that file's kept passages, not an entry of its own.
    func scan() -> (entries: [BibleEntry], folders: [String]) {
        var entries: [BibleEntry] = []
        var folders = Set(Self.standardFolders)
        guard let walker = fm.enumerator(at: dir, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey], options: [.skipsHiddenFiles]) else {
            return ([], Self.standardFolders)
        }
        let prefix = dir.standardizedFileURL.path + "/"
        var files: [(String, URL, Date)] = []
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
            let path = url.standardizedFileURL.path.replacingOccurrences(of: prefix, with: "")
            if values?.isDirectory == true { folders.insert(path); continue }
            files.append((path, url, values?.contentModificationDate ?? .distantPast))
        }
        let all = Set(files.map(\.0))
        for (path, url, date) in files {
            if path.hasSuffix(".md") {
                if all.contains(String(path.dropLast(3))) { continue }
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                entries.append(BibleEntry.parse(path: path, text: text, modified: date))
            } else {
                entries.append(BibleEntry(path: path, kind: .document, title: (path as NSString).lastPathComponent, modified: date, isFile: true))
            }
        }
        let extra = folders.subtracting(Self.standardFolders).sorted()
        return (entries.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }, Self.standardFolders + extra)
    }

    /// A file name free in `folder`, from a title.
    func freePath(title: String, folder: String, ext: String = "md") -> String {
        let slug = Self.slug(title)
        var candidate = "\(folder)/\(slug).\(ext)"
        var n = 2
        while fm.fileExists(atPath: url(candidate).path) {
            candidate = "\(folder)/\(slug)-\(n).\(ext)"
            n += 1
        }
        return candidate
    }

    static func slug(_ s: String) -> String {
        let parts = s.lowercased().folding(options: .diacriticInsensitive, locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.prefix(8)
        return parts.isEmpty ? "sans-titre" : parts.joined(separator: "-")
    }

    func write(_ entry: BibleEntry) throws {
        let file = url(entry.path)
        try prepare(file)
        try entry.serialized.write(to: file, atomically: true, encoding: .utf8)
    }

    /// Creates what a file needs, and keeps documents out of git: no weight in history, nothing sent to a reader.
    func prepare(_ file: URL) throws {
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let ignore = dir.appendingPathComponent(".gitignore")
        let current = (try? String(contentsOf: ignore, encoding: .utf8)) ?? ""
        let missing = ["\(Self.documents)/", "*.sb-*"].filter { !current.components(separatedBy: "\n").contains($0) }
        if !missing.isEmpty { try (current + missing.joined(separator: "\n") + "\n").write(to: ignore, atomically: true, encoding: .utf8) }
    }

    func createFolder(_ name: String) throws {
        try fm.createDirectory(at: dir.appendingPathComponent(Self.slug(name), isDirectory: true), withIntermediateDirectories: true)
    }

    /// To the Trash, so a mistaken click costs nothing.
    func trash(_ path: String) throws {
        try fm.trashItem(at: url(path), resultingItemURL: nil)
        let sidecar = url(path + ".md")
        if fm.fileExists(atPath: sidecar.path) { try fm.trashItem(at: sidecar, resultingItemURL: nil) }
    }

    func move(_ path: String, toFolder folder: String) throws -> String {
        let name = (path as NSString).lastPathComponent
        var target = "\(folder)/\(name)"
        guard target != path else { return path }
        if fm.fileExists(atPath: url(target).path) {
            target = freePath(title: (name as NSString).deletingPathExtension, folder: folder, ext: (name as NSString).pathExtension)
        }
        try prepare(url(target))
        try fm.moveItem(at: url(path), to: url(target))
        return target
    }
}

/// `@[Title]` links and the text around them.
enum BibleLinks {
    private static let pattern = try! NSRegularExpression(pattern: "@\\[([^\\]\\n]+)\\]")

    static func targets(in text: String) -> [String] {
        let ns = text as NSString
        return pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) }
    }

    /// For display: `@[Le pont]` reads `Le pont`.
    static func plain(_ text: String) -> String {
        pattern.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: "$1")
    }

    /// How many times `names` appear in `text`, as whole words and with their case.
    static func count(_ names: [String], in text: String) -> Int {
        let wanted = names.map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.count > 1 }
        guard !wanted.isEmpty else { return 0 }
        let alternatives = wanted.sorted { $0.count > $1.count }.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        guard let re = try? NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}])(?:\(alternatives))(?![\\p{L}\\p{N}])") else { return 0 }
        return re.numberOfMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
    }
}

/// The open book's Bible, and what is computed from it.
@MainActor
@Observable
final class BibleModel {
    let store: BibleStore
    private(set) var entries: [BibleEntry] = []
    private(set) var folders: [String] = BibleStore.standardFolders
    /// Entry path → chapter id → mentions. Computed in the background from the chapters' text.
    private(set) var mentions: [String: [String: Int]] = [:]
    @ObservationIgnored private var mentionTask: Task<Void, Never>?

    init(root: URL) {
        store = BibleStore(root: root)
        reload()
    }

    func reload() {
        let scan = store.scan()
        entries = scan.entries
        folders = scan.folders
    }

    func entries(in folder: String) -> [BibleEntry] { entries.filter { $0.folder == folder } }
    func entry(path: String) -> BibleEntry? { entries.first { $0.path == path } }

    /// The entry a name stands for: by title or alias, ignoring case and accents.
    func entry(named name: String) -> BibleEntry? {
        let f = PlotGrid.fold(name)
        return entries.first { e in e.names.contains { PlotGrid.fold($0) == f } }
    }

    @discardableResult
    func create(title: String, kind: BibleKind, folder: String? = nil, aliases: [String] = [], body: String = "", meta: [String: String] = [:]) throws -> BibleEntry {
        var entry = BibleEntry(path: store.freePath(title: title, folder: folder ?? kind.folder), kind: kind, title: title, aliases: aliases)
        entry.fields = kind.suggestedFields.map { .init(name: $0, value: "") }
        entry.meta = meta
        entry.body = body
        try store.write(entry)
        reload()
        return entry
    }

    func save(_ entry: BibleEntry) throws {
        try store.write(entry)
        reload()
    }

    func trash(_ path: String) throws {
        try store.trash(path)
        reload()
    }

    /// The sheet for a character of the plot grid: found, or created under the same names.
    func sheet(for tag: PlotGrid.Tag) throws -> BibleEntry {
        if let found = entry(named: tag.name) { return found }
        return try create(title: tag.name, kind: tag.column == "characters" ? .character : .note,
                          folder: tag.column == "characters" ? "personnages" : "motifs", aliases: tag.aliases)
    }

    /// Characters of the grid that have no sheet yet.
    func tagsWithoutSheet(_ plot: PlotGrid) -> [PlotGrid.Tag] {
        plot.tags.filter { $0.column == "characters" && entry(named: $0.name) == nil }
    }

    /// Counts every sheet's names in every chapter, off the main thread. Grid aliases count as names of their sheet.
    func refreshMentions(chapters: [(id: String, text: String)], plot: PlotGrid) {
        mentionTask?.cancel()
        let people = entries.filter { [.character, .place, .biography].contains($0.kind) }.map { e -> (String, [String]) in
            let tag = plot.tags.first { t in e.names.contains { PlotGrid.fold($0) == PlotGrid.fold(t.name) } }
            return (e.path, Array(Set(e.names + (tag.map { [$0.name] + $0.aliases } ?? []))))
        }
        mentionTask = Task.detached(priority: .utility) { [weak self] in
            var found: [String: [String: Int]] = [:]
            for (path, names) in people {
                if Task.isCancelled { return }
                for ch in chapters {
                    let n = BibleLinks.count(names, in: ch.text)
                    if n > 0 { found[path, default: [:]][ch.id] = n }
                }
            }
            await MainActor.run { self?.mentions = found }
        }
    }

    /// Entries that link to this one with `@[…]`.
    func backlinks(to entry: BibleEntry) -> [BibleEntry] {
        let names = Set(entry.names.map(PlotGrid.fold))
        return entries.filter { $0.path != entry.path && BibleLinks.targets(in: $0.body).contains { names.contains(PlotGrid.fold($0)) } }
    }

    /// The sheets as a reader gets them, to check the text against: names and facts, no documents.
    var sheetsForReader: String {
        entries.filter { [.character, .place, .event, .biography].contains($0.kind) }.map { e in
            var lines = ["### \(e.title) (\(e.kind.rawValue))"]
            if !e.aliases.isEmpty { lines.append("Aussi : " + e.aliases.joined(separator: ", ")) }
            lines += e.fields.filter { !$0.value.isEmpty }.map { "\($0.name) : \($0.value)" }
            if !e.body.isEmpty { lines.append(BibleLinks.plain(e.body)) }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }
}
