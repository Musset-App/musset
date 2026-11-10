import Foundation

/// A track (« piste »): a parallel draft of the book, kept as the git branch `piste/<id>`.
/// The manuscript never moves while one writes in a track; taking it back is chosen paragraph by paragraph.
struct Piste: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var created: Date
    /// What it started from, as shown: « le manuscrit », a milestone's title, a session's date.
    var from: String
    /// The commit it started at.
    var start: String?
    /// Put away: out of the list, its branch kept.
    var shelved: Bool?

    var branch: String { "piste/\(id)" }
}

enum Pistes {
    static func url(_ root: URL) -> URL { root.appendingPathComponent(".musset/pistes.json") }

    static func load(_ root: URL) -> [Piste] {
        guard let data = try? Data(contentsOf: url(root)) else { return [] }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return (try? d.decode([Piste].self, from: data)) ?? []
    }

    static func save(_ pistes: [Piste], root: URL) throws {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url(root).deletingLastPathComponent(), withIntermediateDirectories: true)
        try e.encode(pistes).write(to: url(root), options: .atomic)
    }

    /// A name fit for a git ref: « Sans le père » → sans-le-pere, then -2, -3… when taken.
    static func slug(_ name: String, taken: Set<String>) -> String {
        let base = name.lowercased().folding(options: .diacriticInsensitive, locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: "-")
        let clean = base.isEmpty ? "piste" : String(base.prefix(48))
        var s = clean, i = 2
        while taken.contains(s) { s = "\(clean)-\(i)"; i += 1 }
        return s
    }

    /// Where a track's unsaved-to-git chapter lives between two commits: inside .git, never seen by other tools.
    static func cacheDir(_ root: URL, _ piste: Piste) -> URL {
        root.appendingPathComponent(".git/musset/pistes/\(piste.id)", isDirectory: true)
    }
}

/// Three-way merge by paragraph: the manuscript and a track, against the text they both started from.
/// Paragraphs are the editor's lines (see ParagraphCodec).
enum ParagraphMerge {
    enum Pick: Equatable { case mine, theirs, both }

    struct Block: Identifiable, Equatable {
        var id = 0
        /// Paragraphs both sides share.
        var same: [String] = []
        /// A difference: the manuscript's paragraphs and the track's.
        var mine: [String] = []
        var theirs: [String] = []
        var isChange = false
        /// Both sides wrote something new here since they parted.
        var conflict = false
        /// The side that changed, when only one did.
        var suggested: Pick?
    }

    static func blocks(base: String, mine: String, theirs: String) -> [Block] {
        let m = lines(mine), t = lines(theirs)
        let baseSet = Set(lines(base))
        let diff = t.difference(from: m)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in diff {
            switch change {
            case .remove(let o, _, _): removed.insert(o)
            case .insert(let o, _, _): inserted.insert(o)
            }
        }
        var out: [Block] = []
        func add(_ b: Block) { var b = b; b.id = out.count; out.append(b) }
        func change(_ a: [String], _ b: [String]) {
            // As many paragraphs on each side: one choice per paragraph.
            let pairs = a.count == b.count && a.count > 1 ? zip(a, b).map { ([$0], [$1]) } : [(a, b)]
            for (x, y) in pairs {
                let mineNew = x.contains { !baseSet.contains($0) }, theirsNew = y.contains { !baseSet.contains($0) }
                var suggested: Pick?
                if theirsNew && !mineNew { suggested = .theirs }
                else if mineNew && !theirsNew { suggested = .mine }
                else if !mineNew && !theirsNew {
                    // Only paragraphs of the common text: one side deleted, the other kept.
                    if x.isEmpty { suggested = .mine } else if y.isEmpty { suggested = .theirs }
                }
                add(Block(mine: x, theirs: y, isChange: true, conflict: mineNew && theirsNew, suggested: suggested))
            }
        }
        var i = 0, j = 0
        var same: [String] = []
        while i < m.count || j < t.count {
            if i < m.count, j < t.count, !removed.contains(i), !inserted.contains(j) {
                same.append(m[i]); i += 1; j += 1
                continue
            }
            if !same.isEmpty { add(Block(same: same)); same = [] }
            var a: [String] = [], b: [String] = []
            while i < m.count, removed.contains(i) { a.append(m[i]); i += 1 }
            while j < t.count, inserted.contains(j) { b.append(t[j]); j += 1 }
            if a.isEmpty && b.isEmpty { break }
            change(a, b)
        }
        if !same.isEmpty { add(Block(same: same)) }
        return out
    }

    /// The chapter as chosen: shared paragraphs, then each difference's pick (the manuscript's when none).
    static func result(_ blocks: [Block], picks: [Int: Pick]) -> String {
        var out: [String] = []
        for b in blocks {
            if !b.isChange { out += b.same; continue }
            switch picks[b.id] ?? .mine {
            case .mine: out += b.mine
            case .theirs: out += b.theirs
            case .both: out += b.mine + b.theirs
            }
        }
        return out.joined(separator: "\n")
    }

    static func lines(_ s: String) -> [String] {
        s.isEmpty ? [] : s.components(separatedBy: "\n")
    }
}
