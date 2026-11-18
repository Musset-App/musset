import Foundation

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
    /// Once it has a sheet in the Bible, the sheet is the character: the tag points at it (`sheet`), takes its title
    /// as its name and reads its aliases from it. A name without a sheet is all here, as it always was.
    struct Tag: Codable, Equatable, Identifiable, Hashable {
        /// What the cells of the grid say. With a sheet: the sheet's title, followed each time the Bible changes.
        var name: String
        /// The column it belongs to ("characters", "motifs", or any tagged column).
        var column: String
        /// Other ways the text names it, as a reading of the book found them; they all map to `name`.
        /// With a sheet: only those the sheet does not list itself (the sheet is where aliases are written).
        var aliases: [String] = []
        /// Who or what it is, in a line, from the reading of the book.
        var note: String = ""
        /// "me" for the author's tags, which an AI pass keeps; else the AI that found it.
        var by: String = "me"
        /// The Bible sheet this name is: its path in `bible/`, which follows the sheet when it moves.
        var sheet: String? = nil
        /// The sheet's own aliases, read from the Bible (`bind`), never kept in the plot.
        var sheetAliases: [String] = []
        var id: String { column + ":" + name }

        /// Every other way the text names it: the sheet's aliases, then what the readings found.
        var allAliases: [String] { sheetAliases + aliases }
        var names: [String] { [name] + allAliases }

        private enum CodingKeys: String, CodingKey { case name, column, aliases, note, by, sheet }
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
    /// Chapters the author means to write, after the written ones: a title and what they'll do. Not in the
    /// manifest (nothing exported, nothing synced as a chapter) until « Start writing ».
    var planned: [Planned]? = nil

    struct Planned: Codable, Equatable, Identifiable {
        var id = UUID().uuidString
        var title: String
        var synopsis: String = ""
    }

    var tags: [Tag] { index ?? [] }
    func tags(in column: String) -> [Tag] { tags.filter { $0.column == column }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending } }

    /// The index name `name` stands for in `column` (by name or alias), if any.
    func canonical(_ name: String, column: String) -> String? {
        let f = Fold.name(name)
        guard !f.isEmpty else { return nil }
        return tags.first { $0.column == column && $0.names.contains { Fold.name($0) == f } }?.name
    }

    /// Ties the index to the Bible's sheets, the one place where a tag and a sheet are matched by name. A tag whose
    /// sheet is gone looks for one again; a tag without a sheet takes the one that bears its name (its title first,
    /// then an alias); a tag with a sheet takes the sheet's title (unless another tag already has it: two tags are
    /// never merged here) and leaves the sheet its aliases. Nothing is written: the plot is saved when the author
    /// next changes it. Returns whether anything changed.
    @discardableResult
    mutating func bind(to sheets: [BibleEntry]) -> Bool {
        guard var list = index, !list.isEmpty else { return false }
        let before = list
        // People first: a character of the grid is the character's sheet rather than a place of the same name.
        let ordered = sheets.filter { !$0.isFile && $0.kind == .character } + sheets.filter { !$0.isFile && $0.kind != .character }
        var byPath: [String: BibleEntry] = [:], titled: [String: String] = [:], named: [String: String] = [:]
        for e in ordered {
            byPath[e.path] = e
            if titled[Fold.name(e.title)] == nil { titled[Fold.name(e.title)] = e.path }
            for n in e.aliases where named[Fold.name(n)] == nil { named[Fold.name(n)] = e.path }
        }
        for i in list.indices {
            if let path = list[i].sheet, byPath[path] == nil { list[i].sheet = nil }
            if list[i].sheet == nil { list[i].sheet = titled[Fold.name(list[i].name)] ?? named[Fold.name(list[i].name)] }
        }
        index = list
        for tag in list {
            guard let e = tag.sheet.flatMap({ byPath[$0] }), e.title != tag.name,
                  !tags.contains(where: { $0.column == tag.column && $0.name == e.title }) else { continue }
            renameTag(tag.name, to: e.title, column: tag.column)
            // The sheet was renamed, not the tag: it stays whose it was.
            if let i = index?.firstIndex(where: { $0.column == tag.column && $0.name == e.title }) { index?[i].by = tag.by }
        }
        list = index ?? []
        for i in list.indices {
            guard let e = list[i].sheet.flatMap({ byPath[$0] }) else { list[i].sheetAliases = []; continue }
            let own = Set(e.names.map(Fold.name))
            list[i].sheetAliases = e.aliases
            list[i].aliases = list[i].aliases.filter { !own.contains(Fold.name($0)) }
        }
        index = list
        return list != before
    }

    /// Sheets went from one path to another in the Bible (a move, a folder renamed): the tags that are those sheets follow.
    @discardableResult
    mutating func retarget(_ move: (String) -> String) -> Bool {
        guard var list = index else { return false }
        var moved = false
        for i in list.indices {
            guard let old = list[i].sheet else { continue }
            let new = move(old)
            if new != old { list[i].sheet = new; moved = true }
        }
        if moved { index = list }
        return moved
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

    /// A chapter's scenes went from `old` to `new` (its text as parsed before and after an edit): the rows of the
    /// scenes renamed follow them, whatever else was added or removed in the chapter. A scene is the same one when
    /// it kept its title, or when it stands at the same place between scenes that kept theirs (or, where scenes
    /// were also added or removed there, when its text is the same). A row never goes to a
    /// title another scene bears: it waits under its old key (`heldRow`) until the title typed is the scene's own.
    /// Returns the new scenes, with the rows they hold, and whether a row moved.
    mutating func follow(_ chapter: String, from old: [ChapterScene], to new: [ChapterScene]) -> (scenes: [ChapterScene], moved: Bool) {
        let before = old.map(\.key), after = new.map(\.key)
        guard before != after, rows[chapter]?.isEmpty == false else { return (new, false) }
        var out = new, moved = false
        for (i, j) in Self.renamed(old, new) {
            let from = before[i], to = after[j]
            // Nothing to carry, or the row is that of a scene still called so.
            guard from != to, rows[chapter]?[from] != nil, !after.contains(from) else { continue }
            if rows[chapter]?[to] == nil, after.filter({ $0 == to }).count == 1 {
                rename(chapter, from: from, to: to)
                moved = true
            } else {
                out[j].heldRow = from
            }
        }
        return (out, moved)
    }

    /// Which scenes of `old` became which of `new`, for those whose title changed. Scenes whose title is on both
    /// sides, in order, are the fixed points (the longest such run); between two of them, as many old as new are the
    /// same ones in order, and otherwise those whose text did not change.
    static func renamed(_ old: [ChapterScene], _ new: [ChapterScene]) -> [(Int, Int)] {
        let a = old.map(\.key), b = new.map(\.key)
        let n = a.count, m = b.count
        // Longest common subsequence, read from the start so equal titles pair with the earliest.
        var lcs = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                lcs[i][j] = a[i] == b[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }
        var out: [(Int, Int)] = []
        var i = 0, j = 0, gapOld = 0, gapNew = 0
        func close(_ i: Int, _ j: Int) {
            if i - gapOld == j - gapNew { out += zip(gapOld..<i, gapNew..<j); return }
            var next = gapNew
            for o in gapOld..<i {
                guard let same = (next..<j).first(where: { new[$0].body == old[o].body }) else { continue }
                out.append((o, same))
                next = same + 1
            }
        }
        while i < n, j < m {
            if a[i] == b[j] {
                close(i, j)
                i += 1; j += 1
                gapOld = i; gapNew = j
            } else if lcs[i + 1][j] >= lcs[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        close(n, m)
        return out
    }

    static func url(_ root: URL) -> URL { root.appendingPathComponent(".musset/plot.json") }

    static func load(_ root: URL) -> PlotGrid {
        guard var g = JSONFile.read(PlotGrid.self, at: url(root)) else { return PlotGrid() }
        g.migrateTaggedText()
        g.migrateColumns()
        return g
    }

    func save(_ root: URL) throws {
        try JSONFile.write(self, to: Self.url(root))
    }

    /// Fingerprint of a scene's text (ignoring spacing), to know whether the AI's reading is still current.
    static func fingerprint(_ text: String) -> String {
        let squeezed = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        var h: UInt64 = 0xcbf29ce484222325
        for b in squeezed.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return String(h, radix: 16)
    }
}
