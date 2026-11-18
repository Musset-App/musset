import Foundation

/// How much a character or a place is in the book. Computed from where it appears; the author can pin it (`tier:`).
enum NameTier: String, CaseIterable, Identifiable {
    case main, secondary, extra, absent
    var id: String { rawValue }
    var label: String {
        switch self {
        case .main: L("Main", ctx: "Principaux")
        case .secondary: L("Secondary", ctx: "Secondaires")
        case .extra: L("Extras", ctx: "Figurants")
        case .absent: L("Not in the text yet")
        }
    }

    /// Extra: one chapter. Secondary: several. Main: in at least a quarter of the written chapters, and named often
    /// enough to matter (a book of one chapter has main characters too).
    static func computed(chapters: Int, mentions: Int, written: Int) -> NameTier {
        if chapters == 0 { return .absent }
        if mentions >= 8, chapters * 4 >= max(written, 1), chapters >= min(2, max(written, 1)) { return .main }
        return chapters >= 2 ? .secondary : .extra
    }
}

extension NameTier {
    /// The narrator of a first-person book rarely writes their own name, and is the main character all the same.
    static let narratorWords = ["narrateur", "narratrice", "narrator", "erzahler", "erzahlerin", "narrador", "narradora", "narratore"]

    static func isNarrator(_ names: [String]) -> Bool {
        names.contains { n in let f = Fold.name(n); return narratorWords.contains { f.contains($0) } }
    }
}

/// Every name the Bible knows (sheets' titles and aliases, and the grid's aliases of the same people), found in a
/// text in one pass. Names are matched as whole words and with their case: « Rose » the woman, not « rose » the colour.
struct NameMatcher {
    /// Name as written → the sheet's path.
    let owners: [String: String]
    /// Names that two sheets share: never attributed for sure (a rename asks).
    let shared: Set<String>
    private let regex: NSRegularExpression?

    static let empty = NameMatcher(names: [])

    init(names: [(path: String, names: [String])]) {
        var owners: [String: String] = [:]
        var shared: Set<String> = []
        for (path, list) in names {
            for raw in Set(list) {
                let name = Self.normal(raw.trimmingCharacters(in: .whitespaces))
                guard name.count > 1, !Self.pronouns.contains(name.lowercased()) else { continue }
                if let other = owners[name], other != path { shared.insert(name) } else { owners[name] = path }
            }
        }
        // A name two sheets share points at neither: « elle » for three women is nobody in particular.
        for name in shared { owners[name] = nil }
        self.owners = owners
        self.shared = shared
        let alternatives = owners.keys.sorted { $0.count > $1.count }
            .map { NSRegularExpression.escapedPattern(for: $0).replacingOccurrences(of: "’", with: "['’]") }.joined(separator: "|")
        regex = alternatives.isEmpty ? nil : try? NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}])(?:\(alternatives))(?![\\p{L}\\p{N}])")
    }

    var isEmpty: Bool { regex == nil }
    /// What tells one matcher from the next, for results kept until the names change.
    var pattern: AnyObject? { regex }

    /// Each name in `range` of `text`, with the sheet it stands for.
    func matches(in text: String, range: NSRange? = nil) -> [(range: NSRange, path: String)] {
        guard let regex else { return [] }
        let ns = text as NSString
        let r = range ?? NSRange(location: 0, length: ns.length)
        return regex.matches(in: text, range: r).compactMap { m in
            owners[Self.normal(ns.substring(with: m.range))].map { (m.range, $0) }
        }
    }

    /// Pronouns are never a name, whoever's alias they were given as.
    static let pronouns: Set<String> = [
        "il", "elle", "ils", "elles", "lui", "eux", "je", "moi", "tu", "toi", "on", "nous", "vous", "leur",
        "he", "she", "him", "her", "they", "them", "me", "you", "we", "us", "it",
        "er", "sie", "ihn", "ihm", "ich", "du", "wir", "ihr", "es",
        "él", "ella", "ellos", "ellas", "yo", "tú", "usted",
        "lei", "io", "loro", "egli", "esso", "essa",
        "ele", "ela", "eles", "elas", "eu", "você",
    ]

    /// « l'urgentiste » and « l’urgentiste » are one name.
    static func normal(_ s: String) -> String { s.replacingOccurrences(of: "'", with: "’") }
}

extension BibleModel {
    static let trackedKinds: Set<BibleKind> = [.character, .place, .biography]

    /// The tier a sheet is in: the author's, if pinned, else what the book says.
    func tier(of entry: BibleEntry) -> NameTier {
        if let pinned = entry.meta["tier"].flatMap(NameTier.init(rawValue:)) { return pinned }
        if entry.kind == .character, NameTier.isNarrator(entry.names) { return .main }
        let per = counts(entry)
        return NameTier.computed(chapters: per.count, mentions: per.values.reduce(0, +), written: writtenChapters)
    }

    /// Chapter → mentions of a sheet. A sheet just given to a grid character keeps that character's counts until
    /// the next count, so it doesn't jump in the list when it is opened.
    func counts(_ entry: BibleEntry) -> [String: Int] {
        if let per = occurrences[entry.path] { return per.mapValues(\.count) }
        let f = Fold.name(entry.title)
        return tagOccurrences.first { Fold.name($0.key) == f }?.value ?? [:]
    }

    /// The tier of a character of the plot grid that has no sheet yet.
    func tier(of tag: PlotGrid.Tag) -> NameTier {
        if NameTier.isNarrator(tag.names) { return .main }
        let per = tagOccurrences[tag.name] ?? [:]
        return NameTier.computed(chapters: per.count, mentions: per.values.reduce(0, +), written: writtenChapters)
    }

    /// How many times a sheet's names are in the book.
    func presence(_ path: String) -> Int { entry(path: path).map { counts($0).values.reduce(0, +) } ?? 0 }

    /// How many times a grid character without a sheet is in the book.
    func presence(of tag: PlotGrid.Tag) -> Int { tagOccurrences[tag.name]?.values.reduce(0, +) ?? 0 }
}
