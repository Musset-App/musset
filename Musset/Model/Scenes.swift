import Foundation

/// A scene of a chapter. Scenes are marked in the chapter's Markdown by `<!-- scene: Title -->` on its own line,
/// at the start of the scene; the marker never reaches the page. A chapter without markers is one scene.
struct ChapterScene: Equatable, Identifiable {
    /// Title from the marker; nil for the whole chapter (no markers) or the text before the first marker.
    let title: String?
    /// The marker line, if any.
    let marker: NSRange?
    /// The scene, from its marker (or the chapter start) to the next marker.
    let range: NSRange
    let words: Int

    /// Key of the scene in the plot grid: its title, "" for an untitled scene.
    var key: String { title ?? "" }
    var id: String { key + "@\(range.location)" }
}

enum Scenes {
    /// `<!-- scene: Title -->` (also « scène »), alone on its line.
    static let pattern = try! NSRegularExpression(pattern: #"^[ \t]*<!--[ \t]*sc[eè]ne[ \t]*:[ \t]*(.*?)[ \t]*-->[ \t]*$"#,
                                                  options: [.anchorsMatchLines, .caseInsensitive])

    static func markerLine(_ title: String) -> String { "<!-- scene: \(title) -->" }

    /// The scenes of a chapter's text (editor or disk form). Text before the first marker counts as an untitled scene
    /// only when it holds more than a heading.
    static func parse(_ text: String) -> [ChapterScene] {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        let markers = pattern.matches(in: text, range: full)
        guard !markers.isEmpty else { return [ChapterScene(title: nil, marker: nil, range: full, words: BookStore.wordCount(text))] }
        var out: [ChapterScene] = []
        let lead = NSRange(location: 0, length: markers[0].range.location)
        let leadText = ns.substring(with: lead)
        let leadProse = leadText.components(separatedBy: .newlines).filter { !$0.hasPrefix("#") }.joined(separator: "\n")
        if BookStore.wordCount(leadProse) > 0 {
            out.append(ChapterScene(title: nil, marker: nil, range: lead, words: BookStore.wordCount(leadProse)))
        }
        for (i, m) in markers.enumerated() {
            let start = m.range.location
            let end = i + 1 < markers.count ? markers[i + 1].range.location : ns.length
            let r = NSRange(location: start, length: end - start)
            let title = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
            out.append(ChapterScene(title: title.isEmpty ? nil : title, marker: m.range, range: r, words: BookStore.wordCount(ns.substring(with: r))))
        }
        return out
    }

    /// Where the prose of a chapter starts, after its heading lines.
    private static func proseStart(_ ns: NSString) -> Int {
        var at = 0
        while at < ns.length {
            let line = ns.lineRange(for: NSRange(location: at, length: 0))
            let t = ns.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard t.isEmpty || t.hasPrefix("#") else { break }
            at = NSMaxRange(line)
        }
        return at
    }

    /// Takes one scene out of a chapter. A scene without a marker (the opening) gets one: it can't be told apart otherwise.
    static func extract(_ index: Int, from text: String, openingTitle: String) -> (rest: String, block: String, title: String)? {
        let scenes = parse(text)
        guard scenes.indices.contains(index) else { return nil }
        let s = scenes[index], ns = text as NSString
        var r = s.range
        if s.marker == nil {
            let start = min(proseStart(ns), NSMaxRange(r))
            r = NSRange(location: start, length: NSMaxRange(r) - start)
        }
        var block = ns.substring(with: r)
        if !block.hasSuffix("\n") { block += "\n" }
        let title = s.title ?? openingTitle
        if s.marker == nil { block = markerLine(title) + "\n" + block }
        return (ns.replacingCharacters(in: r, with: ""), block, title)
    }

    /// Puts a block before the scene at `index` (at the end if there is none). An opening that would no longer
    /// come first gets a marker, or the block would swallow it. Returns that title, for its plot row.
    static func insert(_ block: String, into text: String, at index: Int, openingTitle: String) -> (text: String, markedOpening: String?) {
        let scenes = parse(text)
        let ns = text as NSString
        guard index < scenes.count else {
            let glue = text.isEmpty || text.hasSuffix("\n") ? "" : "\n"
            return (text + glue + block, nil)
        }
        let s = scenes[index]
        if s.marker == nil {
            let at = min(proseStart(ns), ns.length)
            // Only a heading so far: nothing to mark.
            if at == ns.length {
                let glue = text.isEmpty || text.hasSuffix("\n") ? "" : "\n"
                return (text + glue + block, nil)
            }
            return (ns.replacingCharacters(in: NSRange(location: at, length: 0), with: block + markerLine(openingTitle) + "\n"), openingTitle)
        }
        return (ns.replacingCharacters(in: NSRange(location: s.range.location, length: 0), with: block), nil)
    }

    /// The chapter with one scene moved before the scene now at `slot` (0…count). Nil when it wouldn't move.
    static func moved(_ from: Int, to slot: Int, in text: String, openingTitle: String) -> (text: String, opening: String?)? {
        guard slot != from, slot != from + 1, let cut = extract(from, from: text, openingTitle: openingTitle) else { return nil }
        let wasOpening = parse(text)[from].marker == nil
        let put = insert(cut.block, into: cut.rest, at: slot > from ? slot - 1 : slot, openingTitle: openingTitle)
        var out = put.text
        if !text.hasSuffix("\n"), out.hasSuffix("\n") { out.removeLast() }
        return (out, wasOpening ? cut.title : put.markedOpening)
    }

    /// The scene holding `location`.
    static func scene(at location: Int, in scenes: [ChapterScene]) -> ChapterScene? {
        scenes.last { $0.range.location <= location } ?? scenes.first
    }
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

// MARK: Plot grid

/// The book's plot grid: one row per scene, columns the author chooses. Kept in `.musset/plot.json`, tracked in git.
/// The AI fills cells; a cell the author wrote is theirs, and the AI may only propose a change to it.
struct PlotGrid: Codable, Equatable {
    struct Column: Codable, Equatable, Identifiable, Hashable {
        var id: String
        var title: String
        /// The AI may fill this column. « Intrigue cachée » is the author's unless they allow it.
        var ai: Bool = true
        /// Cells hold tags from the book's index (characters, motifs) instead of free text.
        var tagged: Bool? = nil

        var isTagged: Bool { tagged ?? ["characters", "motifs"].contains(id) }

        /// The title in the interface's language. `title` is what the AI reads and the book stores, so a standard
        /// column the author has not renamed keeps its French title there and only reads in English on screen.
        var shownTitle: String {
            switch (id, title) {
            case ("characters", "Personnages"): L("Characters")
            case ("sub", "Intrigue secondaire"): L("Subplot")
            case ("hidden", "Intrigue cachée"): L("Hidden plot")
            default: title
            }
        }
    }

    /// A name of the book's index: a character or a motif, always written the same way.
    struct Tag: Codable, Equatable, Identifiable, Hashable {
        var name: String
        /// The column it belongs to ("characters", "motifs", or any tagged column).
        var column: String
        /// Other ways the text names it; they all map to `name`.
        var aliases: [String] = []
        var note: String = ""
        /// "me" for the author's tags, which an AI pass keeps; else the AI that found it.
        var by: String = "me"
        var id: String { column + ":" + name }
    }

    /// A plot thread of the book, from the whole-book reading: context for every scene.
    struct Thread: Codable, Equatable, Hashable {
        var name: String
        var kind: String
        var note: String = ""
    }

    struct Cell: Codable, Equatable {
        var text: String = ""
        /// "me" when the author wrote it (locked for the AI), else the AI that did.
        var by: String = "me"
        /// What the AI suggests for a locked cell, waiting for the author.
        var proposal: String? = nil
        /// Index names, for a tagged column.
        var tags: [String]? = nil

        var locked: Bool { by == "me" && (!text.isEmpty || !(tags ?? []).isEmpty) }
    }

    struct Row: Codable, Equatable {
        var status: ChapterStatus? = nil
        var cells: [String: Cell] = [:]
        /// Fingerprint of the scene's text when the AI last read it, to tell which scenes changed since.
        var analyzed: String? = nil
    }

    var columns: [Column] = PlotGrid.defaultColumns
    /// chapter id → scene key → row.
    var rows: [String: [String: Row]] = [:]
    /// The book's index (from the whole-book reading, and the author's own tags).
    var index: [Tag]? = nil
    var threads: [Thread]? = nil
    var synopsis: String? = nil
    /// chapter id → what the chapter accomplishes, in the author's words.
    var chapterSynopses: [String: String]? = nil

    var tags: [Tag] { index ?? [] }
    func tags(in column: String) -> [Tag] { tags.filter { $0.column == column }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending } }

    /// Folded form for matching names: case, accents, leading article and spacing ignored.
    static func fold(_ s: String) -> String {
        var t = s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "fr"))
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        for article in ["le ", "la ", "les ", "l'", "l’", "un ", "une ", "des ", "the ", "a "] where t.hasPrefix(article) {
            t = String(t.dropFirst(article.count)); break
        }
        return t.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// The index name `name` stands for in `column` (by name or alias), if any.
    func canonical(_ name: String, column: String) -> String? {
        let f = Self.fold(name)
        guard !f.isEmpty else { return nil }
        return tags.first { $0.column == column && (Self.fold($0.name) == f || $0.aliases.contains { Self.fold($0) == f }) }?.name
    }

    /// Scenes (chapter, key) whose cell in `column` carries the tag.
    func scenes(with tag: String, in column: String) -> [(chapter: String, scene: String)] {
        rows.flatMap { ch, scenes in scenes.compactMap { key, row in (row.cells[column]?.tags ?? []).contains(tag) ? (ch, key) : nil } }
    }

    /// Renames a tag everywhere; renaming onto an existing tag merges the two.
    mutating func renameTag(_ old: String, to new: String, column: String) {
        let new = new.trimmingCharacters(in: .whitespaces)
        guard !new.isEmpty, old != new, var list = index, let i = list.firstIndex(where: { $0.column == column && $0.name == old }) else { return }
        if let j = list.firstIndex(where: { $0.column == column && $0.name == new }) {
            list[j].aliases = Array(Set(list[j].aliases + list[i].aliases + [old]))
            list.remove(at: i)
        } else {
            list[i].aliases = Array(Set(list[i].aliases + [old]))
            list[i].name = new
            list[i].by = "me"
        }
        index = list
        for (ch, scenes) in rows {
            for (key, row) in scenes {
                guard var cell = row.cells[column], var t = cell.tags, t.contains(old) else { continue }
                t = t.map { $0 == old ? new : $0 }
                cell.tags = t.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
                rows[ch]?[key]?.cells[column] = cell
            }
        }
    }

    /// Removes a tag from the index and from every cell.
    mutating func deleteTag(_ name: String, column: String) {
        index?.removeAll { $0.column == column && $0.name == name }
        for (ch, scenes) in rows {
            for (key, row) in scenes where row.cells[column]?.tags?.contains(name) == true {
                rows[ch]?[key]?.cells[column]?.tags?.removeAll { $0 == name }
            }
        }
    }

    /// Text written in a column before it held tags becomes tags (split on commas), mapped to index names.
    mutating func migrateTaggedText() {
        for c in columns where c.isTagged {
            for (ch, scenes) in rows {
                for (key, row) in scenes {
                    guard var cell = row.cells[c.id], cell.tags == nil, !cell.text.isEmpty else { continue }
                    cell.tags = cell.text.components(separatedBy: CharacterSet(charactersIn: ",;"))
                        .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                        .map { canonical($0, column: c.id) ?? $0 }
                    cell.text = ""
                    rows[ch]?[key]?.cells[c.id] = cell
                }
            }
        }
    }

    static let defaultColumns: [Column] = [
        .init(id: "main", title: "Synopsis"),
        .init(id: "characters", title: "Personnages"),
        .init(id: "motifs", title: "Motifs"),
        .init(id: "sub", title: "Intrigue secondaire"),
        .init(id: "hidden", title: "Intrigue cachée", ai: false),
        .init(id: "notes", title: "Notes", ai: false),
    ]

    /// Grids from before the Plan tab: « Intrigue principale » is now the scene's synopsis, and every scene has notes.
    /// The first time, the standard columns take their new order; the author's own follow.
    mutating func migrateColumns() {
        if let i = columns.firstIndex(where: { $0.id == "main" && $0.title == "Intrigue principale" }) { columns[i].title = "Synopsis" }
        guard !columns.contains(where: { $0.id == "notes" }) else { return }
        columns.append(.init(id: "notes", title: "Notes", ai: false))
        let order = Self.defaultColumns.map(\.id)
        columns = order.compactMap { id in columns.first { $0.id == id } } + columns.filter { !order.contains($0.id) }
    }

    func chapterSynopsis(_ chapter: String) -> String { chapterSynopses?[chapter] ?? "" }

    mutating func setChapterSynopsis(_ chapter: String, _ text: String) {
        var all = chapterSynopses ?? [:]
        all[chapter] = text.isEmpty ? nil : text
        chapterSynopses = all.isEmpty ? nil : all
    }

    /// For each column in order: does this scene have something in it?
    func filled(_ chapter: String, _ scene: String) -> [Bool] {
        let cells = row(chapter, scene).cells
        return columns.map { c in cells[c.id].map { !$0.text.isEmpty || !($0.tags ?? []).isEmpty } ?? false }
    }

    func row(_ chapter: String, _ scene: String) -> Row { rows[chapter]?[scene] ?? Row() }

    mutating func update(_ chapter: String, _ scene: String, _ change: (inout Row) -> Void) {
        var r = row(chapter, scene)
        change(&r)
        rows[chapter, default: [:]][scene] = r
    }

    /// A scene was renamed: its row follows.
    mutating func rename(_ chapter: String, from old: String, to new: String) {
        guard old != new, let r = rows[chapter]?[old] else { return }
        rows[chapter]?[old] = nil
        rows[chapter, default: [:]][new] = r
    }

    static func url(_ root: URL) -> URL { root.appendingPathComponent(".musset/plot.json") }

    static func load(_ root: URL) -> PlotGrid {
        guard let data = try? Data(contentsOf: url(root)), var g = try? JSONDecoder().decode(PlotGrid.self, from: data) else { return PlotGrid() }
        g.migrateTaggedText()
        g.migrateColumns()
        return g
    }

    func save(_ root: URL) throws {
        try FileManager.default.createDirectory(at: Self.url(root).deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try enc.encode(self).write(to: Self.url(root), options: .atomic)
    }

    /// Fingerprint of a scene's text (ignoring spacing), to know whether the AI's reading is still current.
    static func fingerprint(_ text: String) -> String {
        let squeezed = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        var h: UInt64 = 0xcbf29ce484222325
        for b in squeezed.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return String(h, radix: 16)
    }
}
