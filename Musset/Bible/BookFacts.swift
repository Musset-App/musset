import Foundation

/// What the book says about each character and place: facts read in the chapters, each with the exact words it
/// comes from, the other names the text gives them, and where the book disagrees with itself. Kept by Musset in
/// `.musset/facts.json`; the author's own sheet is never touched.
struct BookFacts: Codable, Equatable {
    struct Fact: Codable, Hashable, Identifiable {
        var text: String
        var chapter: String
        /// The book's own words, found again in the chapter before being kept.
        var quote: String
        var id: String { chapter + "|" + quote }
    }

    struct Contradiction: Codable, Hashable, Identifiable {
        var a: String
        var b: String
        var why: String
        /// « On purpose »: the author keeps it, and it is not raised again.
        var dismissed = false
        var id: String { a + "⇄" + b }
    }

    struct Entity: Codable, Equatable {
        var facts: [Fact] = []
        /// Other names the text gives them (« her brother », « Tommy »), apart from the author's aliases.
        var aliases: [String] = []
        var contradictions: [Contradiction] = []
    }

    /// Sheet path → what the book says.
    var entities: [String: Entity] = [:]
    /// Chapter id → fingerprint of the text last read.
    var read: [String: String] = [:]

    static func url(_ root: URL) -> URL { root.appendingPathComponent(".musset/facts.json") }

    static func load(_ root: URL) -> BookFacts {
        JSONFile.read(at: url(root)) ?? BookFacts()
    }

    func save(_ root: URL) throws {
        try JSONFile.write(self, to: Self.url(root), [.prettyPrinted, .sortedKeys])
    }

    func fact(_ id: String, of path: String) -> Fact? { entities[path]?.facts.first { $0.id == id } }

    /// Replaces what one chapter says about each sheet; facts from other chapters stay.
    mutating func replace(chapter: String, with found: [String: (facts: [Fact], aliases: [String])], fingerprint: String) {
        for path in Set(entities.keys).union(found.keys) {
            var e = entities[path] ?? Entity()
            e.facts.removeAll { $0.chapter == chapter }
            if let new = found[path] {
                e.facts += new.facts
                e.aliases = Array(Set(e.aliases + new.aliases)).sorted()
            }
            let ids = Set(e.facts.map(\.id))
            e.contradictions.removeAll { !ids.contains($0.a) || !ids.contains($0.b) }
            entities[path] = e.facts.isEmpty && e.aliases.isEmpty ? nil : e
        }
        read[chapter] = fingerprint
    }
}

/// The prompts and the reading of the answers.
enum FactsPrompt {
    struct Answer: Decodable {
        struct Item: Decodable {
            var name: String
            var aliases: [String]?
            var facts: [Pair]?
        }
        struct Pair: Decodable { var fact: String; var quote: String }
        var entities: [Item]
    }

    struct Pairs: Decodable { var pairs: [[AnyCodableIndex]] }
    /// A pair is [i, j, "why"]: two numbers and a reason, in one array.
    enum AnyCodableIndex: Decodable {
        case n(Int), s(String)
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let i = try? c.decode(Int.self) { self = .n(i) } else { self = .s((try? c.decode(String.self)) ?? "") }
        }
    }

    static func facts(chapter: String, text: String, people: [(name: String, aliases: [String])], french: Bool) -> String {
        let list = people.map { "- " + $0.name + ($0.aliases.isEmpty ? "" : " (" + $0.aliases.joined(separator: ", ") + ")") }.joined(separator: "\n")
        return """
        You read one chapter of a novel for its author, to keep their notes on characters and places up to date.
        Write only about the names listed below. For each one present in the chapter, give:
        - the facts the chapter states or shows about them (what they do, have, are, where, when), each in one short sentence \(french ? "in French" : "in the book's language");
        - for each fact, the exact words of the chapter it comes from, copied letter for letter (a few words to one sentence);
        - other names the chapter uses for them (a nickname, « her brother »), if any.
        Never guess, never interpret, never add what the chapter doesn't say. No fact without its quote.
        Return ONLY a JSON object, no prose, no code fence:
        {"entities": [{"name": "...", "aliases": ["..."], "facts": [{"fact": "...", "quote": "..."}]}]}

        Names:
        \(list)

        Chapter « \(chapter) »:
        \(text)
        """
    }

    static func retry(_ missing: [String]) -> String {
        "These quotes are not in the chapter word for word:\n" + missing.map { "- « \($0) »" }.joined(separator: "\n")
            + "\nGive the whole answer again, with every quote copied exactly from the chapter, or leave that fact out. Same JSON."
    }

    static func contradictions(name: String, facts: [BookFacts.Fact], titles: [String: String]) -> String {
        let list = facts.enumerated().map { "\($0.offset). [\(titles[$0.element.chapter] ?? $0.element.chapter)] \($0.element.text) — « \($0.element.quote) »" }
            .joined(separator: "\n")
        return """
        These are facts a novel states about \(name), chapter by chapter. Find the pairs that cannot both be true
        (a date, an age, a colour, a place, who did what). A change the story explains is not a contradiction.
        Return ONLY a JSON object, no prose: {"pairs": [[i, j, "why, in a few words"]]}, using the numbers below;
        {"pairs": []} if there is none.

        \(list)
        """
    }

    static func parseFacts(_ raw: String) -> Answer? {
        guard let data = LenientJSON.object(in: raw) else { return nil }
        return try? JSONDecoder().decode(Answer.self, from: data)
    }

    static func parsePairs(_ raw: String, count: Int) -> [(Int, Int, String)] {
        guard let data = LenientJSON.object(in: raw), let p = try? JSONDecoder().decode(Pairs.self, from: data) else { return [] }
        return p.pairs.compactMap { row in
            guard row.count >= 2, case .n(let i) = row[0], case .n(let j) = row[1], i != j, (0..<count).contains(i), (0..<count).contains(j) else { return nil }
            var why = ""
            if row.count > 2, case .s(let s) = row[2] { why = s }
            return (min(i, j), max(i, j), why)
        }
    }
}

/// Keeps « What the book says » up to date, chapter by chapter, when the author pauses, never while they type.
/// Only chapters whose text changed are read; every fact must quote the chapter exactly or it is dropped.
@MainActor
@Observable
final class BibleKeeper {
    private(set) var facts: BookFacts
    var running: String?
    var lastError: String?
    @ObservationIgnored weak var session: BookSession?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var idle: Task<Void, Never>?
    /// Stands in for the AI in tests.
    @ObservationIgnored var voice: ((String) async throws -> String)?
    static let idleDelay: Duration = .seconds(180)
    static var enabled: Bool { UserDefaults.standard.object(forKey: "keepBible") as? Bool ?? true }

    init(session: BookSession) {
        self.session = session
        facts = BookFacts.load(session.root)
    }

    func entity(_ path: String) -> BookFacts.Entity? { facts.entities[path] }

    /// What the book says follows a sheet that moved in the Bible (`move`: where a path went). A reading under way
    /// still speaks of the old place: it is dropped, and its chapter is read again later.
    func retarget(_ move: (String) -> String) {
        task?.cancel()
        var next = facts
        next.entities = Dictionary(facts.entities.map { (move($0.key), $0.value) }, uniquingKeysWith: { a, _ in a })
        if next != facts { store(next) }
    }

    /// Typing: once the author has stopped for a while, the open chapter is read.
    func textChanged() {
        idle?.cancel()
        idle = Task { [weak self] in
            try? await Task.sleep(for: Self.idleDelay)
            guard !Task.isCancelled, let self, let id = self.session?.selectedChapterID else { return }
            self.read(id)
        }
    }

    /// A chapter just left: read it now if it changed.
    func chapterLeft(_ id: String) {
        idle?.cancel()
        read(id)
    }

    func stale(_ id: String) -> Bool {
        guard let session else { return false }
        return facts.read[id] != PlotGrid.fingerprint(session.editorText(of: id))
    }

    /// Reads one chapter (if it changed) and updates what it says, then looks for contradictions.
    func read(_ id: String) {
        guard Self.enabled, running == nil, let session, session.piste == nil, stale(id),
              let chapter = session.manifest.chapters.first(where: { $0.id == id }) else { return }
        // Never a real AI call from the tests: they give a voice.
        let testing = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        let engine = testing ? nil : TaskModels.backgroundEngine(.bible)
        guard voice != nil || engine != nil else { return }
        let text = BookStore.stripHTMLComments(session.editorText(of: id))
        guard text.contains(where: \.isLetter) else { return }
        let sheets = session.bible.entries.filter { BibleModel.trackedKinds.contains($0.kind) }
        guard !sheets.isEmpty else { return }
        let people = sheets.map { (name: $0.title, aliases: $0.aliases) }
        let byName = Dictionary(sheets.flatMap { e in e.names.map { (Fold.name($0), e.path) } }, uniquingKeysWith: { a, _ in a })
        let titles = Dictionary(session.manifest.chapters.map { ($0.id, $0.title) }, uniquingKeysWith: { a, _ in a })
        let french = session.manifest.lang.hasPrefix("fr")
        let prompt = FactsPrompt.facts(chapter: chapter.title, text: text, people: people, french: french)
        let fingerprint = PlotGrid.fingerprint(session.editorText(of: id))
        let call = caller(engine)
        running = id
        lastError = nil
        task = Task { [weak self] in
            do {
                var raw = try await call(prompt)
                var answer = FactsPrompt.parseFacts(raw)
                // Quotes not found word for word are asked again once, then left out.
                let missing = answer.map { a in a.entities.flatMap { ($0.facts ?? []).map(\.quote) }.filter { ReadingCheck.locate($0, in: text) == nil } } ?? []
                if !missing.isEmpty {
                    raw = try await call(prompt + "\n\n" + FactsPrompt.retry(missing))
                    answer = FactsPrompt.parseFacts(raw) ?? answer
                }
                guard let self else { return }
                guard let answer else { throw Agents.err(L("The answer could not be read.")) }
                var found: [String: (facts: [BookFacts.Fact], aliases: [String])] = [:]
                for item in answer.entities {
                    guard let path = byName[Fold.name(item.name)] else { continue }
                    let kept = (item.facts ?? []).filter { ReadingCheck.locate($0.quote, in: text) != nil }
                        .map { BookFacts.Fact(text: $0.fact, chapter: id, quote: $0.quote) }
                    let aliases = (item.aliases ?? []).filter { a in a.count > 1 && ReadingCheck.locate(a, in: text) != nil && byName[Fold.name(a)] == nil }
                    found[path, default: ([], [])].facts += kept
                    found[path, default: ([], [])].aliases += aliases
                }
                var next = self.facts
                next.replace(chapter: id, with: found, fingerprint: fingerprint)
                // Contradictions, for the sheets whose facts this chapter changed.
                for path in found.keys {
                    guard var e = next.entities[path], e.facts.count >= 2, !Task.isCancelled else { continue }
                    let name = sheets.first { $0.path == path }?.title ?? path
                    let pairs = FactsPrompt.parsePairs(try await call(FactsPrompt.contradictions(name: name, facts: e.facts, titles: titles)), count: e.facts.count)
                    let dismissed = Set(e.contradictions.filter(\.dismissed).map(\.id))
                    e.contradictions = pairs.map { i, j, why in
                        var c = BookFacts.Contradiction(a: e.facts[i].id, b: e.facts[j].id, why: why)
                        c.dismissed = dismissed.contains(c.id)
                        return c
                    }
                    next.entities[path] = e
                }
                if !Task.isCancelled { self.store(next) }
            } catch {
                if !Task.isCancelled { self?.lastError = error.localizedDescription }
            }
            self?.running = nil
        }
    }

    /// « On purpose »: the author keeps this one.
    func dismiss(_ c: BookFacts.Contradiction, of path: String) {
        guard var e = facts.entities[path], let i = e.contradictions.firstIndex(of: c) else { return }
        e.contradictions[i].dismissed = true
        var next = facts
        next.entities[path] = e
        store(next)
    }

    private func store(_ next: BookFacts) {
        guard let session else { return }
        facts = next
        try? next.save(session.root)
        session.pendingCommit = true
        session.bible.setFoundAliases(next.entities.mapValues(\.aliases))
        session.refreshBibleMentions()
    }

    private func caller(_ engine: AgentKind?) -> (String) async throws -> String {
        if let voice { return voice }
        guard let engine, let root = session?.root else { return { _ in "" } }
        let model = TaskModels.model(.bible, for: engine)
        return { prompt in try await Agents.oneShot(engine, prompt: prompt, model: model, cwd: root) }
    }
}
