import Foundation

/// One atom of the scoring library (`criteria.json`): what it measures, the question put to the reader, and what 5, 10, 15 and 19 out of 20 look like.
struct Criterion: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var version: Int
    var label: String
    var family: String
    var polarity: String
    var definition: String
    var question: String
    var scopes: [String]
    var aggregation: [String: String]? = nil
    var anchors: [String: String]? = nil
    var severityGuide: [String: String]? = nil
    var requiresQuote: Bool
    var genreHints: [String]
    var builtin: Bool
}

struct WeightedCriterion: Codable, Equatable, Hashable, Sendable {
    var criterionId: String
    var weight: Int
}

struct MalusItem: Codable, Equatable, Hashable, Sendable {
    var criterionId: String
    var maxPenalty: Int
}

/// The library shipped with the app: criteria and genre presets. A preset is never edited: a book takes a copy.
struct ScoringLibrary {
    struct Grid: Codable { var items: [WeightedCriterion]; var maluses: [MalusItem] }
    struct Preset: Codable, Identifiable {
        var id: String; var name: String; var contract: String; var work: Grid; var chapter: Grid
        /// The name in the interface's language: the file's names are French.
        var shownName: String {
            switch id {
            case "litterature-blanche": L("Literary fiction")
            case "essai": L("Philosophical essay")
            case "thriller": L("Psychological thriller")
            case "chick-lit": L("Chick lit")
            case "romance": L("Romance")
            case "young-adult": L("Young adult")
            case "sf": L("Science fiction")
            case "michon": L("Lives, after Michon")
            case "polar": L("Crime, noir")
            case "fantasy": L("Fantasy")
            case "autofiction": L("Autofiction")
            case "horreur": L("Horror")
            case "historique": L("Historical novel")
            default: name
            }
        }
    }
    private struct CriteriaFile: Codable { var criteria: [Criterion] }
    private struct PresetsFile: Codable { var presets: [Preset] }

    let criteria: [Criterion]
    let presets: [Preset]
    static let families = ["langue", "structure", "personnages", "monde", "idee", "affect", "meta"]

    static let shared = ScoringLibrary(bundle: .main)

    init(bundle: Bundle) {
        func decode<T: Decodable>(_ name: String, _ type: T.Type) -> T? {
            guard let url = bundle.url(forResource: name, withExtension: "json"), let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(type, from: data)
        }
        criteria = decode("criteria", CriteriaFile.self)?.criteria ?? []
        presets = decode("presets", PresetsFile.self)?.presets ?? []
    }

    func criterion(_ id: String) -> Criterion? { criteria.first { $0.id == id } }

    /// The criteria a chapter can be scored on, for the editor's list.
    var chapterCriteria: [Criterion] { criteria.filter { $0.polarity == "bonus" && $0.scopes.contains("chapter") } }
}

/// The book's rubric, in `.musset/bareme.json`, tracked in git. It holds a copy of the criteria it uses, so it reads the same on any machine.
struct Bareme: Codable, Equatable, Sendable {
    static let defaultPreset = "litterature-blanche"
    static let blancheCalibration = "en littérature blanche, L'Étranger de Camus vaudrait 90/100 à ce barème, soit 18/20 en moyenne. Situe ce chapitre par rapport à cette exigence : très peu de textes l'atteignent."

    var version = 1
    var name: String
    /// What the book promises its reader, in a sentence.
    var contract: String
    var threshold: Double?
    /// What the scale means, by a known book: readers otherwise crowd every text near the top.
    var calibration: String = ""
    /// The author's own requirements: eliminatory risks, scoring discipline. Given to the reader as they are.
    var rules: String = ""
    var chapter: [WeightedCriterion]
    var work: [WeightedCriterion] = []
    var maluses: [MalusItem] = []
    var criteria: [Criterion] = []

    /// The preset whose grids these are; nil once the author has made them their own. Not kept in the file (older
    /// files name it; the book's genre is the manifest's): the grids say it.
    var presetId: String? { preset()?.id }
    func preset(in library: ScoringLibrary = .shared) -> ScoringLibrary.Preset? {
        library.presets.first { $0.chapter.items == chapter && $0.work.items == work && $0.chapter.maluses == maluses }
    }

    var weights: [String: Int] { Dictionary(uniqueKeysWithValues: chapter.map { ($0.criterionId, $0.weight) }) }

    func criterion(_ id: String, library: ScoringLibrary = .shared) -> Criterion? {
        criteria.first { $0.id == id } ?? library.criterion(id)
    }

    /// The book takes this preset's grids and promise; its threshold and rules stay.
    mutating func adopt(_ preset: ScoringLibrary.Preset) {
        name = preset.name
        contract = preset.contract
        chapter = preset.chapter.items
        work = preset.work.items
        maluses = preset.chapter.maluses
        calibration = preset.id == Self.defaultPreset ? Self.blancheCalibration : ""
    }

    init(preset: ScoringLibrary.Preset) {
        name = preset.name
        contract = preset.contract
        chapter = preset.chapter.items
        work = preset.work.items
        maluses = preset.chapter.maluses
        calibration = preset.id == Self.defaultPreset ? Self.blancheCalibration : ""
    }

    /// A book that had a Markdown rubric keeps its threshold and its written requirements.
    init?(migrating markdown: String?, library: ScoringLibrary = .shared) {
        guard let preset = library.presets.first(where: { $0.id == Self.defaultPreset }) else { return nil }
        self.init(preset: preset)
        guard let markdown else { threshold = 80; return }
        if let m = markdown.range(of: #"[Ss]euil[^0-9\n]*(\d+)"#, options: .regularExpression),
           let n = markdown[m].split(whereSeparator: { !$0.isNumber }).last.flatMap({ Double($0) }) {
            threshold = n
        }
        if let start = markdown.range(of: "## Risques éliminatoires") ?? markdown.range(of: "## Eliminatory") {
            rules = String(markdown[start.lowerBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    static func url(_ root: URL) -> URL { root.appendingPathComponent(".musset/bareme.json") }

    /// The book's rubric, or the one it would start with: saved only when the author saves it or a reading uses it.
    static func forBook(_ root: URL) -> Bareme? {
        if let b = JSONFile.read(Bareme.self, at: url(root)) { return b }
        // A French book with no rubric of its own starts from the Collection Blanche one, read here and written nowhere.
        return Bareme(migrating: Rubric.load(root) ?? (bookIsFrench(root) ? Rubric.blanche : nil))
    }

    private static func bookIsFrench(_ root: URL) -> Bool {
        struct Lang: Decodable { let lang: String? }
        guard let data = try? Data(contentsOf: BookStore(root: root).manifestURL), let m = try? JSONDecoder().decode(Lang.self, from: data) else { return false }
        return (m.lang ?? "fr").lowercased().hasPrefix("fr")
    }

    func save(_ root: URL, library: ScoringLibrary = .shared) throws {
        var copy = self
        let used = Set(chapter.map(\.criterionId) + work.map(\.criterionId) + maluses.map(\.criterionId))
        copy.criteria = used.sorted().compactMap { criterion($0, library: library) }
        try JSONFile.write(copy, to: Self.url(root))
    }
}

/// The arithmetic of a reading: the AI gives scores, the code does everything else.
enum Scoring {
    /// Largest remainder: whole weights that add up exactly to `total`; empty weights go.
    static func normalize(_ weights: [String: Double], total: Int = 100) -> [String: Int] {
        let entries = weights.filter { $0.value > 0 }
        let sum = entries.values.reduce(0, +)
        guard sum > 0 else { return [:] }
        let raw = entries.mapValues { $0 * Double(total) / sum }
        var out = raw.mapValues { Int($0.rounded(.down)) }
        let rest = total - out.values.reduce(0, +)
        let byRemainder = raw.sorted {
            let a = $0.value - $0.value.rounded(.down), b = $1.value - $1.value.rounded(.down)
            return a != b ? a > b : $0.key < $1.key
        }
        for (k, _) in byRemainder.prefix(rest) { out[k, default: 0] += 1 }
        return out
    }

    /// Out of 100. A score that could not be verified is left out and its weight shared among the others, never counted as zero.
    static func total(weights: [String: Int], scores: [Reading.Score], penalty: Double = 0) -> Double? {
        let valid = scores.filter { !$0.unverified && weights[$0.criterionId] != nil }
        let w = valid.reduce(0) { $0 + (weights[$1.criterionId] ?? 0) }
        guard w > 0 else { return nil }
        let base = valid.reduce(0.0) { $0 + Double($1.score) / 20 * Double(weights[$1.criterionId] ?? 0) }
        return min(100, max(0, base * 100 / Double(w) - penalty))
    }

    /// What a family of faults costs a chapter: six points of severity reach its ceiling.
    static func penalty(severities: [Int], max ceiling: Int) -> Double {
        min(Double(ceiling), Double(severities.reduce(0, +)) * Double(ceiling) / 6)
    }

    static func points(score: Int, weight: Int) -> Double { Double(score) / 20 * Double(weight) }

    /// The scores a claimed anchor allows.
    static func band(_ anchor: String) -> ClosedRange<Int>? {
        switch anchor {
        case "5": 0...7
        case "10": 8...12
        case "15": 13...16
        case "19": 17...20
        default: nil
        }
    }
}

/// A reading of a chapter, in `.musset/readings/<chapter>.json`. Readings stay apart from the older `scores`, which came out of a conversation and another grid.
struct Reading: Codable, Identifiable, Hashable, Sendable {
    /// A passage the reader points at, and why.
    struct Pin: Codable, Hashable, Sendable { var quote: String; var note: String }
    struct Score: Codable, Hashable, Identifiable, Sendable {
        var criterionId: String
        var label: String
        var score: Int
        var anchor: String
        var quotes: [String]
        var justification: String
        var suggestion: String? = nil
        /// What costs this criterion the most, and what best achieves it: they become notes in the text.
        var reservation: Pin? = nil
        var strength: Pin? = nil
        /// No proof could be found in the text: shown, but out of the total.
        var unverified = false
        var id: String { criterionId }
    }
    /// One way forward: what to work on, why, the decision, and the gestures that carry it out. Never rewritten text.
    struct Axis: Codable, Hashable, Identifiable, Sendable {
        /// One gesture on one passage of the text: the author can start it without wondering what is asked.
        struct Step: Codable, Hashable, Sendable {
            var action: String
            var quote: String
            /// Where it goes or what it answers, for a move or a link.
            var target: String? = nil
            var detail: String
        }
        var title: String
        var criterionId: String? = nil
        var why: String
        var direction: String
        var quote: String? = nil
        /// Nil on the readings made before axes had gestures.
        var steps: [Step]? = nil
        var id: String { title }
    }
    /// What the author takes away: the reader's own word on the chapter, given with its scores.
    struct Advice: Codable, Hashable, Sendable {
        var overview: String = ""
        var axes: [Axis] = []
        var keep: String? = nil
    }
    struct Risk: Codable, Hashable, Sendable { var risk: String; var quote: String? = nil }
    /// A family of faults found in the text, each with its proof, and the points it takes off the total.
    struct Malus: Codable, Hashable, Identifiable, Sendable {
        struct Hit: Codable, Hashable, Sendable { var severity: Int; var quote: String; var why: String }
        var criterionId: String
        var label: String
        var points: Double
        var hits: [Hit]
        var id: String { criterionId }
    }

    var id = UUID()
    var date = Date()
    var agent: String
    var model: String
    var textHash: String
    var baremeVersion: Int
    var baremeName: String
    var weights: [String: Int]
    var scores: [Score]
    var risks: [Risk] = []
    var total: Double
    var advice: Advice? = nil
    /// Nil on the readings made before maluses counted.
    var maluses: [Malus]? = nil

    /// Every axis says what to do where. Older readings don't, and are worth reading again even on the same text.
    var hasConcreteAdvice: Bool { (advice?.axes ?? []).allSatisfy { !($0.steps ?? []).isEmpty } }

    /// The points a criterion costs, biggest first; the order axes are worth working in.
    var costliest: [Score] {
        scores.filter { !$0.unverified }.sorted {
            let a = Double(weights[$0.criterionId] ?? 0) * Double(20 - $0.score), b = Double(weights[$1.criterionId] ?? 0) * Double(20 - $1.score)
            return a != b ? a > b : $0.criterionId < $1.criterionId
        }
    }

    /// Points won if this criterion reached the top anchor (17/20).
    func gain(_ criterionId: String) -> Int? {
        guard let s = scores.first(where: { $0.criterionId == criterionId && !$0.unverified }), let w = weights[criterionId], s.score < 17 else { return nil }
        return max(1, Int((Double(17 - s.score) / 20 * Double(w)).rounded()))
    }

    /// The axes to show: the editor's, or else drawn from the reader's own pistes on what costs the most.
    var axes: [Axis] {
        if let a = advice?.axes, !a.isEmpty { return a }
        return costliest.filter { $0.suggestion != nil }.prefix(3).map {
            Axis(title: $0.label, criterionId: $0.criterionId, why: $0.reservation?.note ?? $0.justification, direction: $0.suggestion ?? "", quote: $0.reservation?.quote)
        }
    }

    static func url(_ root: URL, _ chapter: String) -> URL { root.appendingPathComponent(".musset/readings/\(chapter).json") }
    /// The text as last read, to tell the editor what has changed since.
    static func lastTextURL(_ root: URL, _ chapter: String) -> URL { root.appendingPathComponent(".musset/readings/\(chapter).last.md") }

    static func load(_ root: URL, _ chapter: String) -> [Reading] {
        JSONFile.read(at: url(root, chapter), iso8601: true) ?? []
    }

    static func append(_ reading: Reading, root: URL, chapter: String) throws {
        try JSONFile.write(load(root, chapter) + [reading], to: url(root, chapter), iso8601: true)
    }
}
