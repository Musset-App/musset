import Foundation
import Observation

/// An editing checker: the author's own rules, applied to a chapter by the AI. It flags passages in the margin,
/// with the rule's number and a few leads; it never rewrites the text. Checkers live in a library shared by all
/// books, and each book picks the ones it uses.
struct Checker: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    /// The rules as the author wrote them, numbered or not.
    var rules: String
}

/// The library, one Markdown file per checker in Application Support, so every book on this Mac can use it.
/// A book keeps a copy of the checkers it uses in `.musset/checkers.json`, so it still has them on another Mac.
enum CheckerLibrary {
    /// Tests point this elsewhere.
    nonisolated(unsafe) static var folder: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Musset/Checkers", isDirectory: true)

    static func url(_ id: String) -> URL { folder.appendingPathComponent(id + ".md") }

    static func all() -> [Checker] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "md" }.compactMap { url in
            (try? String(contentsOf: url, encoding: .utf8)).map { decode($0, id: url.deletingPathExtension().lastPathComponent) }
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func load(_ id: String) -> Checker? {
        (try? String(contentsOf: url(id), encoding: .utf8)).map { decode($0, id: id) }
    }

    static func save(_ checker: Checker) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try encode(checker).write(to: url(checker.id), atomically: true, encoding: .utf8)
    }

    /// To the Trash: a set of rules can take hours to write.
    static func delete(_ id: String) throws {
        guard FileManager.default.fileExists(atPath: url(id).path) else { return }
        try FileManager.default.trashItem(at: url(id), resultingItemURL: nil)
    }

    /// A new id from the name, free in the library.
    static func newID(for name: String) -> String {
        let base = BibleStore.slug(name)
        var id = base, n = 2
        while FileManager.default.fileExists(atPath: url(id).path) { id = "\(base)-\(n)"; n += 1 }
        return id
    }

    static func encode(_ c: Checker) -> String {
        "---\nname: \(c.name.replacingOccurrences(of: "\n", with: " "))\n---\n\n" + c.rules.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    static func decode(_ text: String, id: String) -> Checker {
        var name = id, body = text
        if text.hasPrefix("---\n"), let end = text.range(of: "\n---\n", range: text.index(text.startIndex, offsetBy: 4)..<text.endIndex) {
            for line in text[text.index(text.startIndex, offsetBy: 4)..<end.lowerBound].split(separator: "\n") where line.hasPrefix("name:") {
                name = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            }
            body = String(text[end.upperBound...])
        }
        return Checker(id: id, name: name, rules: body.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// The checkers a book uses, with a copy of each.
struct BookCheckers: Codable, Equatable {
    var enabled: [String] = []
    var copies: [String: Checker] = [:]

    static func url(_ root: URL) -> URL { root.appendingPathComponent(".musset/checkers.json") }

    static func load(_ root: URL) -> BookCheckers {
        (try? Data(contentsOf: url(root))).flatMap { try? JSONDecoder().decode(BookCheckers.self, from: $0) } ?? BookCheckers()
    }

    func save(_ root: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try FileManager.default.createDirectory(at: Self.url(root).deletingLastPathComponent(), withIntermediateDirectories: true)
        try enc.encode(self).write(to: Self.url(root), options: .atomic)
    }

    /// The library's version when this Mac has it, else the book's copy.
    var checkers: [Checker] { enabled.compactMap { CheckerLibrary.load($0) ?? copies[$0] } }

    mutating func set(_ checker: Checker, on: Bool) {
        enabled.removeAll { $0 == checker.id }
        if on { enabled.append(checker.id); copies[checker.id] = checker } else { copies[checker.id] = nil }
    }

    /// Keeps the copies in step with the library.
    mutating func refresh() {
        for id in enabled { if let c = CheckerLibrary.load(id) { copies[id] = c } }
    }
}

/// What the AI found, before it is placed.
struct CheckerFinding: Decodable, Equatable {
    var quote: String = ""
    var comment: String = ""
    var intended: Bool = false
    var leads: [String] = []

    enum CodingKeys: String, CodingKey { case quote, comment, intended, leads, pistes }

    init(quote: String, comment: String, intended: Bool = false, leads: [String] = []) {
        self.quote = quote; self.comment = comment; self.intended = intended; self.leads = leads
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        quote = (try? c.decode(String.self, forKey: .quote)) ?? ""
        comment = (try? c.decode(String.self, forKey: .comment)) ?? ""
        intended = (try? c.decode(Bool.self, forKey: .intended)) ?? false
        leads = (try? c.decode([String].self, forKey: .leads)) ?? (try? c.decode([String].self, forKey: .pistes)) ?? []
    }

    /// The note as it reads in the margin.
    func body(french: Bool) -> String {
        guard !leads.isEmpty, !intended else { return comment }
        return comment + "\n" + (french ? "Pistes :" : "Leads:") + "\n" + leads.map { "– " + $0 }.joined(separator: "\n")
    }
}

enum CheckerPrompt {
    static func prompt(_ checker: Checker, book: String, chapter: String, file: String, text: String, people: String, others: String, french: Bool) -> String {
        """
        You are the editor of « \(book) ». You check one chapter against the author's own writing rules. \
        You flag; you never rewrite the text, and Musset never applies what you write: your leads are inspirations \
        the author may take or leave.

        THE AUTHOR'S RULES, verbatim:
        <<<
        \(checker.rules)
        >>>

        Work through the chapter in order, and flag every passage that breaks a rule. One item per passage; \
        when it breaks several rules, name them all in the same item. If the rules say how to present a finding \
        (what to say, how many leads, when to ask instead of proposing), follow them exactly. Judge each passage \
        by the rule's own wording and exceptions: dialogue, a quoted voice, a crisis, a deliberate echo may be allowed. \
        When a breach looks deliberate, say why in one sentence and ask whether to keep it, with no leads.
        Things worth flagging that no rule covers (a typo, a fact, a capital) go in "outside", briefly.
        The other chapters are in this folder; open them with your Read tool only when a rule needs the rest of the book:
        \(others)
        \(people.isEmpty ? "" : "\nThe book's people:\n\(people)\n")
        Write everything in \(french ? "French" : "the chapter's language"). Address the author the same way throughout: \
        as the rules do, else \(french ? "as « tu »" : "directly").
        In "outside", state a fact about the rest of the book only after checking it with Read; otherwise ask.

        Return ONLY a JSON object, no prose, no code fence:
        {"items": [{"quote": "<copied character for character from the chapter, just long enough to be unique>", \
        "comment": "<the rule number(s) with a short label in brackets, then the reason, e.g. Règles 20 (métaphore) et 26 (« on »).>", \
        "intended": false, "leads": ["<short lead>", "<another>"]}], \
        "outside": [{"quote": "<exact passage>", "comment": "<one sentence>"}]}
        Leads are short; when cutting works, one of them is a plain cut (« Couper. » and why in a few words). \
        For a deliberate breach: "intended": true and "leads": [].

        THE CHAPTER « \(chapter) » (\(file)):
        <<<
        \(text)
        >>>
        """
    }

    static func parse(_ raw: String) -> (items: [CheckerFinding], outside: [CheckerFinding])? {
        struct Answer: Decodable { var items: [CheckerFinding]?; var outside: [CheckerFinding]? }
        guard let data = LenientJSON.object(in: raw), let a = try? JSONDecoder().decode(Answer.self, from: data) else { return nil }
        let keep: (CheckerFinding) -> Bool = { !$0.quote.isEmpty && !$0.comment.isEmpty }
        return ((a.items ?? []).filter(keep), (a.outside ?? []).filter(keep))
    }
}

/// Runs a checker on the open chapter, outside the chat, and puts what it finds in the margin.
@MainActor
@Observable
final class CheckerRunner {
    var running: String?
    var status: String?
    var lastError: String?
    @ObservationIgnored private var task: Task<Void, Never>?
    /// Stands in for the AI in tests.
    @ObservationIgnored var voice: ((String) async throws -> String)?

    func stop() { task?.cancel(); running = nil; status = nil }

    func run(_ checker: Checker, session: BookSession, engine: AgentKind, model: String) {
        guard running == nil, let chapter = session.selectedChapter else { return }
        session.flushSave()
        let text = session.text
        let french = session.manifest.lang.hasPrefix("fr")
        let others = session.manifest.chapters.filter { $0.id != chapter.id }.map { "- \($0.title) — `\($0.file)`" }.joined(separator: "\n")
        let prompt = CheckerPrompt.prompt(checker, book: session.title, chapter: chapter.title, file: chapter.file,
                                          text: BookStore.stripHTMLComments(text), people: GrammarArbiter.facts(plot: session.plot),
                                          others: others, french: french)
        let chapterID = chapter.id, root = session.root, voice = self.voice
        running = checker.id
        lastError = nil
        status = L("\(checker.name): \(engine.label) is checking the chapter…")
        task = Task { [weak self] in
            let result: Result<String, Error>
            do {
                if let voice { result = .success(try await voice(prompt)) }
                else { result = .success(try await Agents.oneShot(engine, prompt: prompt, model: model, cwd: root, tools: "Read,Grep,Glob")) }
            } catch { result = .failure(error) }
            guard let self, !Task.isCancelled else { return }
            self.running = nil
            switch result {
            case .failure(let e):
                self.status = nil
                self.lastError = e.localizedDescription
            case .success(let raw):
                guard session.selectedChapterID == chapterID else {
                    self.status = L("The chapter changed: nothing was added.")
                    return
                }
                guard let found = CheckerPrompt.parse(raw) else {
                    self.status = nil
                    self.lastError = L("\(checker.name): the answer could not be read.")
                    return
                }
                let findings = Self.merged(found.items, outside: found.outside, in: BookStore.stripHTMLComments(session.text), french: french)
                let placed = Self.place(findings, checker: checker, session: session, author: engine == .claude ? .claude : .codex)
                let missed = findings.count - placed
                self.status = L("\(placed) notes in the margin from \(checker.name)")
                    + (missed > 0 ? L(", \(missed) passages not found in the text.") : ".")
            }
        }
    }

    /// A remark outside the rules on a passage already flagged joins that note rather than making a second one.
    static func merged(_ items: [CheckerFinding], outside: [CheckerFinding], in text: String, french: Bool) -> [CheckerFinding] {
        var out = items
        let ranges = items.map { ReadingCheck.locate($0.quote, in: text) }
        for o in outside {
            let r = ReadingCheck.locate(o.quote, in: text)
            if let r, let i = ranges.firstIndex(where: { $0.map { NSIntersectionRange($0, r).length > 0 } ?? false }) {
                out[i].comment += "\n" + (french ? "Hors règles : " : "Outside the rules: ") + o.comment
            } else {
                out.append(CheckerFinding(quote: o.quote, comment: (french ? "Hors règles : " : "Outside the rules: ") + o.comment))
            }
        }
        return out
    }

    /// The checker's earlier open notes on this chapter give way to the new ones, unless the author answered them.
    @discardableResult
    static func place(_ findings: [CheckerFinding], checker: Checker, session: BookSession, author: Note.Author) -> Int {
        for n in session.notes.notes where n.source == checker.name && n.status == .open && n.replies.isEmpty {
            session.notes.delete(n.id)
        }
        let text = session.text
        let french = session.manifest.lang.hasPrefix("fr")
        let run = UUID().uuidString
        var placed = 0
        for f in findings {
            guard let range = ReadingCheck.locate(f.quote, in: text) else { continue }
            if let note = session.notes.add(range: range, text: text, author: author, kind: f.intended ? .question : .critique, body: f.body(french: french), run: run) {
                session.notes.setSource(note.id, checker.name)
                placed += 1
            }
        }
        if placed > 0 { session.pendingCommit = true }
        return placed
    }
}
