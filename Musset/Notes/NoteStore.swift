import Foundation
import Observation

struct Note: Codable, Identifiable, Equatable {
    enum Author: String, Codable, CaseIterable {
        /// `model`: your own model (OpenRouter, Ollama…), named after its server.
        case me, claude, codex, model
        var label: String {
            switch self {
            case .me: L("You")
            case .claude: "Claude"
            case .codex: "Codex"
            case .model: AgentKind.endpoint.label
            }
        }
        var isAI: Bool { self != .me }

        /// Who signs what this engine writes.
        init(_ engine: AgentKind) {
            switch engine {
            case .claude: self = .claude
            case .codex: self = .codex
            case .endpoint: self = .model
            }
        }
    }

    enum Kind: String, Codable, CaseIterable {
        case note, question, todo, critique, fact, continuity
        /// What works.
        case praise
        /// Problems by family, each in its own colour.
        case tic, cut, repetition
        /// Free text among the notes: no case to tick, nothing to resolve.
        case text
        /// The kinds a note can be given.
        static let choices: [Kind] = allCases.filter { $0 != .text }
        var label: String {
            switch self {
            case .text: L("Note")
            case .note: L("Note")
            case .question: L("Question")
            case .todo: L("To do")
            case .critique: L("Critique")
            case .fact: L("Fact check", ctx: "À vérifier")
            case .continuity: L("Continuity")
            case .praise: L("Strength")
            case .tic: L("Tic")
            case .cut: L("Cut", ctx: "Coupe")
            case .repetition: L("Repetition")
            }
        }
        var isPositive: Bool { self == .praise }

        /// The kinds an AI may give a note, as written in the prompts.
        static let promptChoices = #""praise" | "tic" | "cut" | "repetition" | "critique" | "fact" | "continuity" | "question""#

        /// The kind a note's leading « [Tag] » stands for (the AIs tag their notes in the author's language).
        static func fromTag(_ body: String) -> Kind? {
            let t = body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard t.hasPrefix("["), let close = t.firstIndex(of: "]") else { return nil }
            let tag = t[t.index(after: t.startIndex)..<close]
                .folded.trimmingCharacters(in: .whitespaces)
            let table: [(Kind, [String])] = [
                (.praise, ["reussite", "force", "signature", "a garder", "strength", "keep"]),
                (.tic, ["tic", "antithese", "renversement", "chute", "maxime", "fragment", "rafale", "ligne seule", "paragraphe d'une ligne", "paragraphe d’une ligne"]),
                (.cut, ["coupe", "a couper", "remplissage", "cut"]),
                (.repetition, ["redite", "repetition", "deja dit"]),
                (.continuity, ["contradiction", "chronologie", "incoherence"]),
                (.fact, ["a verifier", "fait", "fact"]),
                (.question, ["question"]),
            ]
            return table.first { $0.1.contains { tag == $0 || tag.hasPrefix($0 + " ") } }?.0
        }
    }

    /// `done`: ticked. `resolved`: settled without being done.
    enum Status: String, Codable { case open, done, resolved }

    struct Reply: Codable, Identifiable, Equatable {
        var id = UUID()
        var author: Author
        var body: String
        var created = Date()
    }

    var id = UUID()
    var author: Author
    var kind: Kind
    var body: String
    var status: Status = .open
    var created = Date()
    var updated = Date()
    var anchor: NoteAnchor
    var replies: [Reply] = []
    /// The passage could not be found any more; `anchor.quote` keeps what it was.
    var orphaned = false
    /// AI batch the note came from, so a whole run can be dismissed.
    var run: String?
    /// Who sent it, for what came back from outside (the sender named when a Word file was brought in).
    var source: String? = nil

    var isClosed: Bool { status != .open }
    /// On the chapter (or the book) as a whole, rather than on a passage.
    var hasPassage: Bool { !anchor.quote.isEmpty }
}

/// Notes of one book, kept in `.musset/notes/<chapter>.md` (tracked by git, never exported), `_book.md` for the book itself.
/// Holds the open chapter's notes and their live ranges, which follow every edit.
@MainActor
@Observable
final class NoteStore {
    let root: URL
    private(set) var chapterID: String?
    private(set) var notes: [Note] = []
    /// Where each note of the open chapter is right now.
    private(set) var live: [UUID: NSRange] = [:]
    /// The text `live` was last resolved against, while no edit has moved it since.
    @ObservationIgnored private var resolvedText: String?
    @ObservationIgnored private var version: String?
    /// Notes the last AI pass resolved because the text fixed them.
    @ObservationIgnored var lastAutoResolved = 0

    init(root: URL) { self.root = root }

    private var dir: URL { root.appendingPathComponent(".musset/notes") }
    private func url(_ chapterID: String) -> URL { Self.url(root, chapterID) }

    /// The notes that belong to the book rather than a chapter.
    nonisolated static let bookPage = "_book"

    nonisolated static func url(_ root: URL, _ chapterID: String) -> URL {
        root.appendingPathComponent(".musset/notes/\(chapterID).md")
    }

    nonisolated static func read(_ url: URL) -> [Note] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return NoteMarkdown.decode(text)
    }

    nonisolated static func readJSON(_ data: Data) -> [Note] {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode([Note].self, from: data)) ?? []
    }

    /// Margin notes in JSON and scratch pads become one Markdown file per chapter. What was already there stays.
    /// Returns whether anything moved. The old files go; the commit that follows keeps them in the history.
    @discardableResult
    nonisolated static func migrate(root: URL, chapters: [String]) -> Bool {
        let fm = FileManager.default
        var moved = false
        for id in chapters + [bookPage] {
            let json = root.appendingPathComponent(".musset/notes/\(id).json")
            let pad = Notepad.url(root, chapter: id == bookPage ? nil : id)
            let hasJSON = fm.fileExists(atPath: json.path), hasPad = fm.fileExists(atPath: pad.path)
            guard hasJSON || hasPad else { continue }
            var notes = read(url(root, id))
            var known = Set(notes.map(\.id))
            if hasJSON, let data = try? Data(contentsOf: json) {
                let old = readJSON(data)
                // A file that doesn't read stays where it is: nothing is ever dropped.
                if old.isEmpty && !data.isEmpty && String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) != "[]" { continue }
                for var n in old.sorted(by: { $0.anchor.start < $1.anchor.start }) where !known.contains(n.id) {
                    // « Résolue » on a task was its only way of being done.
                    if n.kind == .todo, n.status == .resolved { n.status = .done }
                    notes.append(n)
                    known.insert(n.id)
                }
            }
            if hasPad, let text = try? String(contentsOf: pad, encoding: .utf8) {
                for n in NoteMarkdown.decode(TodoSyntax.normalize(text)) where !known.contains(n.id) {
                    notes.append(n)
                    known.insert(n.id)
                }
            }
            let target = url(root, id)
            try? fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard !notes.isEmpty || (!hasPad && !hasJSON) else {
                if hasJSON { try? fm.removeItem(at: json) }
                if hasPad { try? fm.removeItem(at: pad) }
                moved = true
                continue
            }
            do {
                try sortedForDisk(notes).write(to: target, atomically: true, encoding: .utf8)
                if NoteMarkdown.decode(try String(contentsOf: target, encoding: .utf8)).count == notes.count {
                    if hasJSON { try? fm.removeItem(at: json) }
                    if hasPad { try? fm.removeItem(at: pad) }
                }
                moved = true
            } catch { continue }
        }
        return moved
    }

    /// In text order; what has no passage keeps its order after.
    nonisolated static func sortedForDisk(_ notes: [Note]) -> String {
        NoteMarkdown.encode(notes.filter(\.hasPassage).sorted { $0.anchor.start < $1.anchor.start } + notes.filter { !$0.hasPassage })
    }

    /// Notes of another chapter, for the whole-book list.
    func notes(of chapterID: String) -> [Note] {
        chapterID == self.chapterID ? notes : Self.read(url(chapterID))
    }

    func load(chapter: ChapterEntry, text: String) {
        if chapterID != nil { save() }
        chapterID = chapter.id
        version = chapter.activeVersion
        notes = Self.read(url(chapter.id))
        onDisk = notes
        resolvedText = nil
        resolveAll(in: text)
        classifyByTag()
        removeStackedAINotes()
    }

    /// Older AI notes were all « critique »: give each the kind its [Tag] says.
    private func classifyByTag() {
        var changed = false
        for i in notes.indices where notes[i].author.isAI && [.critique, .note].contains(notes[i].kind) {
            if let k = Note.Kind.fromTag(notes[i].body), k != notes[i].kind { notes[i].kind = k; changed = true }
        }
        if changed { save() }
    }

    /// Finds every note's passage in `text` (chapter opened, version switched, text replaced).
    func resolveAll(in text: String) {
        // The editor resolves again when it loads the text the session just opened: nothing has moved.
        if text == resolvedText, live.count + notes.filter({ $0.orphaned || !$0.hasPassage }).count == notes.count { return }
        resolvedText = text
        live = [:]
        // Split into words only if some note needs the fuzzy search, and then once for all of them.
        lazy var words = Anchoring.tokens(text as NSString)
        for i in notes.indices where notes[i].hasPassage {
            if let r = Anchoring.resolve(notes[i].anchor, in: text, words: { words }) {
                live[notes[i].id] = r
                notes[i].orphaned = false
            } else {
                notes[i].orphaned = true
            }
        }
    }

    func save() {
        guard let chapterID else { return }
        // Going from tab to tab saves each time: only what changed is written.
        guard notes != onDisk else { return }
        write(notes, to: url(chapterID))
    }

    /// The notes as last read or written, so an unchanged chapter is not written again.
    @ObservationIgnored private var onDisk: [Note]?

    /// Writes live positions back into the anchors (fresh quote and context), then saves.
    func recapture(text: String) {
        let ns = text as NSString
        for i in notes.indices {
            guard let r = live[notes[i].id], NSMaxRange(r) <= ns.length, r.length > 0 else { continue }
            let fresh = Anchoring.capture(r, in: ns, version: notes[i].anchor.version)
            if fresh != notes[i].anchor { notes[i].anchor = fresh }
        }
        save()
    }

    /// One text edit, as reported by the text storage.
    func applyEdit(edited: NSRange, delta: Int) {
        resolvedText = nil
        guard !live.isEmpty else { return }
        var next: [UUID: NSRange] = [:]
        for (id, r) in live {
            // A passage cut down to a letter or two is gone, not moved.
            if let moved = Anchoring.adjust(r, edited: edited, delta: delta), moved.length >= min(3, r.length) { next[id] = moved }
            else if let i = notes.firstIndex(where: { $0.id == id }) { notes[i].orphaned = true }
        }
        // Typing below every note moves none: nothing that reads them is told.
        if next != live { live = next }
    }

    // MARK: Editing notes

    @discardableResult
    func add(range: NSRange, text: String, author: Note.Author, kind: Note.Kind, body: String, run: String? = nil) -> Note? {
        let ns = text as NSString
        guard chapterID != nil, range.length > 0, NSMaxRange(range) <= ns.length else { return nil }
        let note = Note(author: author, kind: kind, body: body, anchor: Anchoring.capture(range, in: ns, version: version), run: run)
        notes.append(note)
        live[note.id] = range
        save()
        return note
    }

    private func modify(_ id: UUID, _ change: (inout Note) -> Void) {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
        change(&notes[i])
        notes[i].updated = Date()
        save()
    }

    func update(_ id: UUID, body: String, kind: Note.Kind) { modify(id) { $0.body = body; $0.kind = kind } }
    @discardableResult
    func reply(_ id: UUID, author: Note.Author, body: String) -> UUID {
        let r = Note.Reply(author: author, body: body)
        modify(id) { $0.replies.append(r) }
        return r.id
    }

    /// Streaming answer: grows a reply in memory; `finishReply` saves (or drops it if nothing came).
    func appendToReply(_ id: UUID, _ replyID: UUID, _ text: String) {
        guard let i = notes.firstIndex(where: { $0.id == id }), let j = notes[i].replies.firstIndex(where: { $0.id == replyID }) else { return }
        notes[i].replies[j].body += text
    }

    func replyBody(_ id: UUID, _ replyID: UUID) -> String? {
        notes.first { $0.id == id }?.replies.first { $0.id == replyID }?.body
    }

    func finishReply(_ id: UUID, _ replyID: UUID) {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[i].replies.removeAll { $0.id == replyID && $0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        notes[i].updated = Date()
        save()
    }
    func setStatus(_ id: UUID, _ status: Note.Status) { modify(id) { $0.status = status } }
    /// Who or what the note comes from, for the Notes panel's filter (an editor, a checker).
    func setSource(_ id: UUID, _ source: String?) { modify(id) { $0.source = source } }

    /// Any note, in any chapter.
    func change(_ id: UUID, in chapter: String, _ edit: (inout Note) -> Void) {
        if chapter == chapterID { modify(id, edit); return }
        var all = Self.read(url(chapter))
        guard let i = all.firstIndex(where: { $0.id == id }) else { return }
        edit(&all[i])
        all[i].updated = Date()
        write(all, to: url(chapter))
    }

    /// A task or free text on the chapter (or the book) as a whole.
    @discardableResult
    func addPlain(_ body: String, kind: Note.Kind, in chapter: String) -> Note {
        let note = Note(author: .me, kind: kind, body: body, anchor: NoteAnchor(quote: "", prefix: "", suffix: "", start: 0, version: nil))
        if chapter == chapterID { notes.append(note); save() } else { write(Self.read(url(chapter)) + [note], to: url(chapter)) }
        return note
    }

    /// Takes a note out, wherever it is; returns its place, for putting it back.
    func remove(_ id: UUID, in chapter: String) -> Int? {
        var all = notes(of: chapter)
        guard let i = all.firstIndex(where: { $0.id == id }) else { return nil }
        all.remove(at: i)
        replaceAll(all, in: chapter)
        return i
    }

    /// A deleted note comes back where it was.
    func restore(_ note: Note, in chapter: String, at index: Int) {
        var all = notes(of: chapter)
        all.insert(note, at: min(index, all.count))
        replaceAll(all, in: chapter)
    }

    /// The whole list of a chapter, open or not.
    func replaceAll(_ list: [Note], in chapter: String) {
        if chapter == chapterID {
            notes = list
            live = live.filter { id, _ in list.contains { $0.id == id } }
            resolvedText = nil
            save()
        } else {
            write(list, to: url(chapter))
        }
    }

    private func write(_ list: [Note], to target: URL) {
        if let chapterID, target == url(chapterID) { onDisk = list }
        if list.isEmpty {
            if FileManager.default.fileExists(atPath: target.path) { try? FileManager.default.removeItem(at: target) }
            return
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? Self.sortedForDisk(list).write(to: target, atomically: true, encoding: .utf8)
    }

    /// An AI note the author wants to keep: it stops being part of its run.
    func keep(_ id: UUID) { modify(id) { $0.run = nil } }

    func delete(_ id: UUID) {
        notes.removeAll { $0.id == id }
        live[id] = nil
        save()
    }

    func deleteRun(_ run: String) {
        for n in notes where n.run == run { live[n.id] = nil }
        notes.removeAll { $0.run == run }
        save()
    }

    /// Puts an orphaned (or misplaced) note on a new passage.
    func reattach(_ id: UUID, to range: NSRange, text: String) {
        guard range.length > 0 else { return }
        live[id] = range
        modify(id) {
            $0.anchor = Anchoring.capture(range, in: text as NSString, version: $0.anchor.version)
            $0.orphaned = false
        }
    }

    /// A new AI note must not go here: an AI note already sits on (most of) this passage, open or resolved,
    /// or the author resolved a note touching it, even one whose passage was rewritten since.
    /// A note stretched over a whole chapter by an old edit says nothing of any one passage: it blocks nothing.
    func blocksNewNote(at range: NSRange, quote: String) -> Bool {
        notes.contains { n in
            if n.anchor.quote.count > 2_000 { return false }
            if let r = live[n.id] {
                if n.author.isAI, Self.sameSpot(r, range) { return true }
                return n.isClosed && NSIntersectionRange(r, range).length > 0
            }
            return n.isClosed && Self.similarQuotes(n.anchor.quote, quote)
        }
    }

    /// Two quotes of (nearly) the same passage: one holds the other, or most of their words are shared.
    static func similarQuotes(_ a: String, _ b: String) -> Bool {
        func words(_ s: String) -> [String] {
            s.folded.components(separatedBy: CharacterSet.letters.inverted).filter { $0.count > 2 }
        }
        let wa = words(a), wb = words(b)
        guard !wa.isEmpty, !wb.isEmpty else { return false }
        let ja = wa.joined(separator: " "), jb = wb.joined(separator: " ")
        if ja.contains(jb) || jb.contains(ja) { return true }
        let sa = Set(wa), sb = Set(wb)
        return Double(sa.intersection(sb).count) >= 0.6 * Double(min(sa.count, sb.count))
    }

    /// The note an AI refers to by its short id (the first characters of its UUID, as listed in the prompts).
    func note(shortID: String) -> Note? {
        let key = shortID.trimmingCharacters(in: CharacterSet(charactersIn: "#[] ")).lowercased()
        guard key.count >= 6 else { return nil }
        return notes.first { $0.id.uuidString.lowercased().hasPrefix(key) }
    }

    static func sameSpot(_ a: NSRange, _ b: NSRange) -> Bool {
        let shared = NSIntersectionRange(a, b).length
        return shared > 0 && Double(shared) >= 0.5 * Double(min(a.length, b.length))
    }

    /// Removes AI notes stacked on a passage that already has an earlier AI note. Only throwaway ones go
    /// (still part of their run, no replies); if one of them was resolved, the note that stays is resolved too.
    /// Returns how many were removed.
    @discardableResult
    func removeStackedAINotes() -> Int {
        var kept: [(id: UUID, range: NSRange)] = []
        var removed = Set<UUID>()
        var resolve = Set<UUID>()
        for n in notes.sorted(by: { $0.created < $1.created }) where n.author.isAI {
            guard let r = live[n.id] else { continue }
            if n.run != nil, n.replies.isEmpty, let k = kept.first(where: { Self.sameSpot($0.range, r) }) {
                removed.insert(n.id)
                if n.isClosed { resolve.insert(k.id) }
            } else {
                kept.append((n.id, r))
            }
        }
        guard !removed.isEmpty else { return 0 }
        for i in notes.indices where resolve.contains(notes[i].id) { notes[i].status = .resolved }
        notes.removeAll { removed.contains($0.id) }
        for id in removed { live[id] = nil }
        save()
        return removed.count
    }

    /// A reader's margin notes, from their review: the ones the author doesn't have yet, signed with the reader's name.
    func importNotes(_ theirs: [Note], chapter: String, from reader: String) {
        var mine = chapter == chapterID ? notes : Self.read(url(chapter))
        let known = Set(mine.map(\.id))
        for var n in theirs where !known.contains(n.id) {
            if n.author == .me, n.source == nil { n.body = "**\(reader)** : " + n.body }
            mine.append(n)
        }
        if chapter == chapterID {
            notes = mine
            save()
        } else {
            write(mine, to: url(chapter))
        }
    }

    /// Notes of the open chapter in text order (orphans last).
    var ordered: [Note] {
        notes.sorted { (live[$0.id]?.location ?? Int.max, $0.created) < (live[$1.id]?.location ?? Int.max, $1.created) }
    }
}

/// The scratch pads of old, in `.musset/notepad`: read once, when they become notes.
enum Notepad {
    nonisolated static func url(_ root: URL, chapter: String?) -> URL {
        root.appendingPathComponent(".musset/notepad/\(chapter ?? "_book").md")
    }
}
