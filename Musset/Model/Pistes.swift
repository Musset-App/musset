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
        JSONFile.read(at: url(root), iso8601: true) ?? []
    }

    static func save(_ pistes: [Piste], root: URL) throws {
        try JSONFile.write(pistes, to: url(root), [.prettyPrinted, .sortedKeys], iso8601: true)
    }

    /// A name fit for a git ref: « Sans le père » → sans-le-pere, then -2, -3… when taken.
    static func slug(_ name: String, taken: Set<String>) -> String {
        let base = name.slug()
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
