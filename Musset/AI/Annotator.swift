import Foundation
import Observation

/// AI notes: Claude or Codex reads a chapter (or a selection) and leaves notes on precise passages,
/// or answers in a note's thread. Notes are never written into the text.
@MainActor
@Observable
final class Annotator {
    enum Task: String, CaseIterable, Identifiable {
        case critique, tics, fact, continuity, custom
        var id: String { rawValue }
        var label: String {
            switch self {
            case .critique: L("Editorial critique")
            case .tics: "Tics"
            case .fact: L("Fact check", ctx: "Vérification des faits")
            case .continuity: L("Continuity")
            case .custom: L("Custom…")
            }
        }
        var kind: Note.Kind {
            switch self {
            case .critique: .critique
            case .tics: .tic
            case .fact: .fact
            case .continuity: .continuity
            case .custom: .note
            }
        }
        func instruction(root: URL, text: String) -> String {
            switch self {
            case .tics: Tics.instruction(root: root, text: text)
            case .critique:
                "Give an editorial critique as a demanding literary publisher's editor would: passages that explain instead of showing, vague or weak sentences, rhythm breaks, clichés, scenes that need strengthening. Be specific and constructive; never rewrite the passage yourself."
            case .fact:
                "Fact-check: names, dates, places, historical, technical or cultural facts and quotations that may be wrong or need verifying. For each, say what to check and why."
            case .continuity:
                "Check continuity: contradictions within the text (ages, dates, who is present, places, objects, names), timeline problems, details that clash with what the text established earlier."
            case .custom: ""
            }
        }
    }

    struct Item: Decodable {
        var quote: String = ""
        var note: String = ""
        var kind: String? = nil
        /// Short id of an open note whose problem the current text has fixed; `note` then says why.
        var resolves: String? = nil

        enum CodingKeys: String, CodingKey { case quote, note, kind, resolves }
        init(quote: String = "", note: String = "", kind: String? = nil, resolves: String? = nil) {
            self.quote = quote; self.note = note; self.kind = kind; self.resolves = resolves
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            quote = try c.decodeIfPresent(String.self, forKey: .quote) ?? ""
            note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
            kind = try c.decodeIfPresent(String.self, forKey: .kind)
            resolves = try c.decodeIfPresent(String.self, forKey: .resolves)
        }
    }

    var running = false
    var status: String?
    var lastError: String?
    /// The note being answered by "Ask Claude / Codex".
    var answering: UUID?
    var askError: String?
    @ObservationIgnored private var askProcess: (any AgentRun)?
    /// Last AI run, so it can be dismissed in one go.
    var lastRun: String?

    static func model(for engine: AgentKind) -> String { TaskModels.model(.annotate, for: engine) }

    private static func agentsMD(_ root: URL) -> String {
        (try? String(contentsOf: root.appendingPathComponent("AGENTS.md"), encoding: .utf8)).map { "\n\nThe author's AGENTS.md:\n" + $0 } ?? ""
    }

    static func prompt(task: Task, custom: String, root: URL, book: String, chapter: String, text: String, agents: String) -> String {
        let instruction = task == .custom ? custom : task.instruction(root: root, text: text)
        return """
        You are reading a chapter of the author's book « \(book) », chapter « \(chapter) ».
        \(instruction)

        Leave notes in the margin; do not rewrite the text. Write each note in the language of the text, 1 to 4 sentences.
        \(WritingPartner.noRewrites)
        Return ONLY a JSON array (no prose, no code fence), as many items as the text needs, in text order:
        {"quote": "<passage copied character for character from the text, 3 to 25 words>", "kind": \(Note.Kind.promptChoices), "note": "<your note>"}
        Use "praise" for what works and must be kept, the other kinds for problems.
        Return [] if nothing deserves a note.\(agents)

        TEXT:
        \(text)
        """
    }

    /// The notes already on the chapter, so a new pass adds only what is new, leaves resolved points alone,
    /// and resolves the open ones the author has fixed. Resolved notes come first: they must all be seen.
    @MainActor
    static func existingNotes(_ session: BookSession) -> String {
        let all = session.notes.ordered.filter(\.hasPassage)
        guard !all.isEmpty else { return "" }
        func line(_ n: Note) -> String {
            let quote = n.anchor.quote.replacingOccurrences(of: "\n", with: " ").prefix(90)
            let body = n.body.replacingOccurrences(of: "\n", with: " ").prefix(140)
            return "- #\(n.id.uuidString.prefix(8).lowercased()) [\(n.kind.rawValue)\(n.orphaned ? ", passage rewritten" : "")] « \(quote) » — \(body)"
        }
        let resolved = all.filter { $0.isClosed && !$0.kind.isPositive }.prefix(150).map(line)
        let open = all.filter { $0.status == .open }.prefix(80).map(line)
        let praise = all.filter { $0.isClosed && $0.kind.isPositive }.prefix(30).map(line)
        var out = """


        Notes already in the margin. Never note a passage or a point that is already there, open or resolved.
        """
        if !resolved.isEmpty {
            out += "\nRESOLVED by the author (settled: never raise these points again, not even on a rewritten version of the passage):\n" + resolved.joined(separator: "\n")
        }
        if !open.isEmpty {
            out += """

            OPEN:
            \(open.joined(separator: "\n"))
            If the current text has fixed the problem an open note points at, resolve it: add to your JSON array \
            {"resolves": "<its #id>", "note": "<one sentence: what changed>"} (no quote). Resolve only what is really fixed; \
            never resolve "praise" notes or the author's own notes.
            """
        }
        if !praise.isEmpty { out += "\nAlso kept:\n" + praise.joined(separator: "\n") }
        return out
    }

    static func parse(_ raw: String) -> [Item] {
        guard let start = raw.firstIndex(of: "["), let end = raw.lastIndex(of: "]"), start < end,
              let data = String(raw[start...end]).data(using: .utf8) else { return [] }
        return ((try? JSONDecoder().decode([Item].self, from: data)) ?? []).filter { $0.resolves != nil || (!$0.quote.isEmpty && !$0.note.isEmpty) }
    }

    /// Places parsed notes on their passages (preferring the given scope). Returns how many were placed.
    @discardableResult
    static func add(_ items: [Item], to session: BookSession, author: Note.Author, defaultKind: Note.Kind, scope: NSRange?, run: String) -> Int {
        let text = session.text
        var placed = 0
        for item in items {
            if let id = item.resolves {
                if let n = session.notes.note(shortID: id), n.status == .open, n.author.isAI, !n.kind.isPositive {
                    if !item.note.isEmpty { session.notes.reply(n.id, author: author, body: item.note) }
                    session.notes.setStatus(n.id, .resolved)
                    session.notes.lastAutoResolved += 1
                }
                continue
            }
            guard let re = ProofFix.tolerantRegex(item.quote, wholeWords: false) else { continue }
            let found = re.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)).map(\.range)
            let inScope = scope.flatMap { s in found.first { NSIntersectionRange($0, s).length > 0 } }
            guard let range = inScope ?? found.first else { continue }
            if session.notes.blocksNewNote(at: range, quote: item.quote) { continue }
            let kind = Note.Kind.fromTag(item.note) ?? item.kind.flatMap(Note.Kind.init(rawValue:)) ?? defaultKind
            if session.notes.add(range: range, text: text, author: author, kind: kind, body: item.note, run: run) != nil { placed += 1 }
        }
        return placed
    }

    func annotate(_ task: Task, custom: String = "", session: BookSession, selection: NSRange?, engine: AgentKind) {
        guard !running, let chapter = session.selectedChapter else { return }
        let full = session.text as NSString
        let scope = selection.flatMap { $0.length > 0 && NSMaxRange($0) <= full.length ? $0 : nil }
        let text = scope.map { full.substring(with: $0) } ?? session.text
        let prompt = Self.prompt(task: task, custom: custom, root: session.root, book: session.title, chapter: chapter.title, text: text,
                                 agents: Self.agentsMD(session.root) + Self.existingNotes(session))
        let author = Note.Author(engine)
        let chapterID = chapter.id
        running = true
        lastError = nil
        status = scope == nil ? L("\(engine.label) is reading the chapter…") : L("\(engine.label) is reading the selection…")
        Swift.Task { [weak self] in
            do {
                let raw = try await Agents.oneShot(engine, prompt: prompt, model: Self.model(for: engine), cwd: session.root)
                guard let self else { return }
                self.running = false
                guard session.selectedChapterID == chapterID else { self.status = L("Chapter changed; notes not added."); return }
                let items = Self.parse(raw)
                let run = UUID().uuidString
                session.notes.lastAutoResolved = 0
                let n = Self.add(items, to: session, author: author, defaultKind: task.kind, scope: scope, run: run)
                let fixed = session.notes.lastAutoResolved
                self.lastRun = n > 0 ? run : nil
                self.status = (n == 0 ? L("\(engine.label) left no new notes.") : L("\(n) notes left by \(engine.label)."))
                    + (fixed > 0 ? " " + L("\(fixed) fixed notes resolved.") : "")
            } catch {
                self?.running = false
                self?.status = nil
                self?.lastError = error.localizedDescription
            }
        }
    }

    /// Answers in a note's thread, streamed like the chat. `question` is added first as the author's reply when not empty.
    func ask(_ noteID: UUID, question: String, session: BookSession, engine: AgentKind) {
        guard answering == nil, let note = session.notes.notes.first(where: { $0.id == noteID }) else { return }
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty { session.notes.reply(noteID, author: .me, body: q) }
        let text = session.text as NSString
        let context = session.notes.live[noteID].map { r -> String in
            let p = text.paragraphRange(for: r)
            return text.substring(with: p)
        } ?? note.anchor.quote
        let thread = ([(note.author, note.body)] + note.replies.map { ($0.author, $0.body) } + (q.isEmpty ? [] : [(.me, q)]))
            .map { "\($0.0.label): \($0.1)" }.joined(separator: "\n")
        let prompt = """
        The author of the book « \(session.title) » is discussing a note on this passage.
        Passage: « \(note.anchor.quote) »
        Its paragraph:
        \(context)

        Thread so far:
        \(thread)

        Reply to the last message as a thoughtful literary editor and writing partner, in the language of the thread, \
        like a conversation: direct, specific, usually 1 to 6 sentences.
        \(WritingPartner.noRewrites)\(Self.agentsMD(session.root))
        """
        let replyID = session.notes.reply(noteID, author: Note.Author(engine), body: "")
        answering = noteID
        askError = nil
        do {
            askProcess = try Agents.send(engine, prompt: prompt, session: nil, cwd: session.root, model: Self.model(for: engine), systemPrompt: nil,
                onEvent: { [weak self] ev in Swift.Task { @MainActor in self?.askEvent(ev, noteID: noteID, replyID: replyID, session: session, engine: engine) } },
                onDone: { [weak self] code, stderr in Swift.Task { @MainActor in self?.askDone(code, stderr, noteID: noteID, replyID: replyID, session: session) } })
        } catch {
            askDone(1, error.localizedDescription, noteID: noteID, replyID: replyID, session: session)
        }
    }

    func stopAsking() { askProcess?.terminate() }

    private func askEvent(_ ev: AgentEvent, noteID: UUID, replyID: UUID, session: BookSession, engine: AgentKind) {
        switch ev {
        case .textDelta(let t): session.notes.appendToReply(noteID, replyID, t)
        case .fullText(let t):
            // Codex sends whole messages; Claude's final result repeats what was streamed.
            let current = session.notes.replyBody(noteID, replyID) ?? ""
            if engine == .codex { session.notes.appendToReply(noteID, replyID, (current.isEmpty ? "" : "\n\n") + t) }
            else if current.isEmpty { session.notes.appendToReply(noteID, replyID, t) }
        case .error(let e): askError = Agents.err(e).localizedDescription
        default: break
        }
    }

    private func askDone(_ code: Int32, _ stderr: String, noteID: UUID, replyID: UUID, session: BookSession) {
        session.notes.finishReply(noteID, replyID)
        if code != 0, code != 15, askError == nil { askError = Agents.err(stderr).localizedDescription }
        askProcess = nil
        answering = nil
    }
}
