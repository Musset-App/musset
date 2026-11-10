import Foundation
import Observation

/// Keeps the plot grid up to date. A whole-book reading first builds the book's index (characters, recurring motifs,
/// plot threads, a synopsis); each scene is then filled against that index, so the same thing always carries the same
/// tag. Cells the author wrote are never overwritten, only given a proposal.
@MainActor
@Observable
final class PlotAnalyst {
    var running = false
    var status: String?
    var lastError: String?
    @ObservationIgnored private var task: Task<Void, Never>?

    /// A cell as the AI returns it: text, or a list of index names.
    enum Value: Decodable {
        case text(String), tags([String])
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let a = try? c.decode([String].self) { self = .tags(a) } else { self = .text((try? c.decode(String.self)) ?? "") }
        }
        var asText: String {
            switch self { case .text(let s): s; case .tags(let a): a.joined(separator: ", ") }
        }
        var asTags: [String] {
            switch self {
            case .tags(let a): a
            case .text(let s): s.components(separatedBy: CharacterSet(charactersIn: ",;")).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            }
        }
    }

    struct Item: Decodable {
        let scene: String
        var cells: [String: Value]? = nil
        var proposals: [String: Value]? = nil
    }

    /// The whole-book reading.
    struct BookIndex: Decodable {
        struct Entry: Decodable { var name: String; var aliases: [String]? = nil; var note: String? = nil }
        struct ThreadEntry: Decodable { var name: String; var kind: String? = nil; var note: String? = nil }
        var synopsis: String? = nil
        var characters: [Entry]? = nil
        var motifs: [Entry]? = nil
        var threads: [ThreadEntry]? = nil
    }

    /// Scenes whose text changed since the AI last read them (or never read).
    static func stale(_ session: BookSession, chapter: String) -> [ChapterScene] {
        let text = session.editorText(of: chapter) as NSString
        return (session.scenes[chapter] ?? []).filter { s in
            NSMaxRange(s.range) <= text.length
                && session.plot.row(chapter, s.key).analyzed != PlotGrid.fingerprint(text.substring(with: s.range))
        }
    }

    /// Reading the whole book needs the strongest reader: Opus for Claude.
    static func indexModel(for engine: AgentKind) -> String { TaskModels.model(.plot, for: engine) }

    /// Fills the scenes that changed. With `rebuild`, first reads the whole book to refresh the index, then fills every scene.
    func update(_ session: BookSession, engine: AgentKind, chapters only: [String]? = nil, rebuild: Bool = false) {
        guard !running else { return }
        session.flushSave()
        let chapters = session.manifest.chapters.filter { !$0.excludeFromExport || only != nil }.map(\.id)
            .filter { id in only.map { $0.contains(id) } ?? true }
        let work = chapters.compactMap { id -> (String, [ChapterScene])? in
            let s = rebuild ? (session.scenes[id] ?? []) : Self.stale(session, chapter: id)
            return s.isEmpty ? nil : (id, s)
        }
        let needIndex = rebuild || session.plot.tags.isEmpty
        guard needIndex || !work.isEmpty else { status = L("The grid is up to date."); return }
        running = true
        lastError = nil
        task = Task { [weak self] in
            if needIndex {
                self?.status = L("\(engine.label) is reading the whole book to build its index…")
                do {
                    let raw = try await Agents.oneShot(engine, prompt: Self.indexPrompt(session), model: Self.indexModel(for: engine), cwd: session.root)
                    guard let index = Self.parseIndex(raw) else { throw Agents.err(L("The book's index could not be read from the answer.")) }
                    Self.merge(index, into: session, engine: engine)
                } catch {
                    self?.lastError = error.localizedDescription
                    self?.running = false
                    return
                }
            }
            for (n, (chapter, scenes)) in work.enumerated() {
                guard let self, !Task.isCancelled else { return }
                let title = session.manifest.chapters.first { $0.id == chapter }?.title ?? chapter
                self.status = L("\(engine.label) is reading « \(title) » (\(n + 1)/\(work.count))…")
                let prompt = Self.prompt(session, chapter: chapter, scenes: scenes)
                do {
                    let raw = try await Agents.oneShot(engine, prompt: prompt, model: TaskModels.model(.plot, for: engine), cwd: session.root)
                    Self.apply(Self.parse(raw), to: session, chapter: chapter, scenes: scenes, engine: engine)
                } catch {
                    self.lastError = error.localizedDescription
                    break
                }
            }
            self?.running = false
            if self?.lastError == nil {
                let tags = session.plot.tags.count, scenes = work.reduce(0) { $0 + $1.1.count }
                self?.status = L("Grid updated: \(tags) tags in the index,") + " " + L("\(scenes) scenes read.")
            }
        }
    }

    func stop() { task?.cancel(); running = false; status = nil }

    // MARK: Whole-book index

    static func indexPrompt(_ session: BookSession) -> String {
        let book = session.manifest.chapters.filter { !$0.excludeFromExport }.enumerated().map { i, ch in
            "## CHAPTER \(i): \(ch.title)\n\n" + BookStore.stripHTMLComments(session.editorText(of: ch.id))
        }.joined(separator: "\n\n")
        let mine = session.plot.tags.filter { $0.by == "me" }
            .map { "- \($0.column): \($0.name)\($0.aliases.isEmpty ? "" : " (also: \($0.aliases.joined(separator: ", ")))")" }.joined(separator: "\n")
        return """
        You are building the index of the book « \(session.title) », whose full text follows, chapter by chapter. \
        It will tag every scene of the book, so names must be consistent and easy to spot. Write in the language of the book.
        Return ONLY a JSON object (no prose, no code fence):
        {"synopsis": "<what the book is about, its arc, 5 to 10 lines>",
         "characters": [{"name": "<canonical name, as the book most often calls them>", "aliases": ["<every other way the text names them>"], "note": "<who they are, one line>"}],
         "motifs": [{"name": "<canonical name: one to three words, lowercase, a noun (e.g. « ficelle », « pommiers »)>", "aliases": ["<other words the text uses for it>"], "note": "<what it carries in the book, one line>"}],
         "threads": [{"name": "<short name>", "kind": "main" | "sub" | "hidden", "note": "<one line>"}]}
        Characters: everyone who acts, speaks or matters, including the narrator (name them as the book does, or « le narrateur »). \
        One entry per person: « ma mère », « maman » and her first name are one character.
        Motifs: only images, objects, places, gestures, colours or words that come back across the book (at least two chapters) \
        and carry meaning; usually 10 to 40. Not themes in the abstract, not one-off details.
        Threads: the main plot, the subplots, and what runs under the surface.
        \(mine.isEmpty ? "" : "The author already defined these tags: keep them with exactly these names (you may add aliases):\n\(mine)\n")
        BOOK:
        \(book)
        """
    }

    static func parseIndex(_ raw: String) -> BookIndex? {
        guard let data = LenientJSON.object(in: raw) else { return nil }
        return try? JSONDecoder().decode(BookIndex.self, from: data)
    }

    /// The author's tags stay (with any new aliases); the AI's previous tags are replaced by the new reading.
    static func merge(_ index: BookIndex, into session: BookSession, engine: AgentKind) {
        var tags = session.plot.tags.filter { $0.by == "me" }
        func add(_ entries: [BookIndex.Entry]?, column: String) {
            for e in entries ?? [] {
                let name = e.name.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { continue }
                let aliases = (e.aliases ?? []).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && $0 != name }
                if let i = tags.firstIndex(where: { $0.column == column && PlotGrid.fold($0.name) == PlotGrid.fold(name) }) {
                    tags[i].aliases = Array(Set(tags[i].aliases + aliases)).sorted()
                    if tags[i].note.isEmpty { tags[i].note = e.note ?? "" }
                } else {
                    tags.append(.init(name: name, column: column, aliases: aliases, note: e.note ?? "", by: engine.rawValue))
                }
            }
        }
        add(index.characters, column: "characters")
        add(index.motifs, column: "motifs")
        session.plot.index = tags
        if let t = index.threads { session.plot.threads = t.map { .init(name: $0.name, kind: $0.kind ?? "sub", note: $0.note ?? "") } }
        if let s = index.synopsis { session.plot.synopsis = s }
        session.savePlot()
    }

    // MARK: Filling scenes

    static func prompt(_ session: BookSession, chapter: String, scenes: [ChapterScene]) -> String {
        let grid = session.plot
        let columns = grid.columns.filter(\.ai)
        let text = session.editorText(of: chapter) as NSString
        let chapterTitle = session.manifest.chapters.first { $0.id == chapter }?.title ?? chapter
        let cols = columns.map { c -> String in
            guard c.isTagged else { return "- \(c.id) « \(c.title) »: a few words to two short sentences." }
            let names = grid.tags(in: c.id).map { $0.aliases.isEmpty ? $0.name : "\($0.name) (= \($0.aliases.joined(separator: ", ")))" }
            let open = c.id == "characters" ? " A character who is not in the list but acts in the scene may be added under the name the text gives them." : ""
            return "- \(c.id) « \(c.title) »: a JSON array of names, each written EXACTLY as in this list, never an alias.\(open)\n  " + names.joined(separator: "; ")
        }.joined(separator: "\n")
        let threads = (grid.threads ?? []).map { "- \($0.name) (\($0.kind)): \($0.note)" }.joined(separator: "\n")
        let blocks = scenes.map { s -> String in
            let row = grid.row(chapter, s.key)
            let current = columns.compactMap { c -> String? in
                guard let cell = row.cells[c.id], cell.locked else { return nil }
                return "  \(c.id) (AUTHOR): \(c.isTagged ? (cell.tags ?? []).joined(separator: ", ") : cell.text)"
            }.joined(separator: "\n")
            return """
            ### SCENE "\(s.key)"
            \(current.isEmpty ? "" : "\(current)\n")TEXT:
            \(text.substring(with: s.range))
            """
        }.joined(separator: "\n\n")
        return """
        You keep the plot grid of the book « \(session.title) »: one row per scene. In the language of the book, \
        describe what each scene holds for each column; do not judge or advise, do not invent what the text does not show, \
        leave a column out when the scene has nothing for it.
        \(grid.synopsis.map { "THE BOOK:\n\($0)\n" } ?? "")\(threads.isEmpty ? "" : "ITS THREADS (call them by these names in the plot columns):\n\(threads)\n")
        COLUMNS:
        \(cols)
        A tag goes in a scene only when the scene shows it (a character present or at stake, a motif that appears in the text).
        Cells marked AUTHOR are the author's: never rewrite them; only if the scene clearly contradicts one, put your version under "proposals".
        Return ONLY a JSON array (no prose, no code fence), one item per scene:
        {"scene": "<the scene's name exactly as given>", "cells": {"<column id>": "<text>" or ["<tag>", …]}, "proposals": {"<column id>": …}}

        CHAPTER « \(chapterTitle) »:
        \(blocks)
        """
    }

    static func parse(_ raw: String) -> [Item] {
        guard let start = raw.firstIndex(of: "["), let end = raw.lastIndex(of: "]"), start < end,
              let data = String(raw[start...end]).data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([Item].self, from: data)) ?? []
    }

    /// Index names for what the AI wrote: aliases become the name, unknown motifs are dropped, unknown characters join the index.
    static func normalize(_ names: [String], column: String, in session: BookSession, engine: AgentKind) -> [String] {
        var out: [String] = []
        for n in names {
            let name = n.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            var tag = session.plot.canonical(name, column: column)
            if tag == nil, column == "characters" {
                session.plot.index = session.plot.tags + [.init(name: name, column: column, by: engine.rawValue)]
                tag = name
            }
            if let tag, !out.contains(tag) { out.append(tag) }
        }
        return out
    }

    /// Writes the AI's cells: free and AI cells are replaced, author cells only get a proposal. Every scene sent
    /// is marked as read, so it is not sent again until its text changes.
    static func apply(_ items: [Item], to session: BookSession, chapter: String, scenes: [ChapterScene], engine: AgentKind) {
        let text = session.editorText(of: chapter) as NSString
        let columns = Dictionary(uniqueKeysWithValues: session.plot.columns.filter(\.ai).map { ($0.id, $0) })
        for s in scenes {
            let item = items.first { $0.scene == s.key } ?? (scenes.count == 1 ? items.first : nil)
            var cells: [String: PlotGrid.Cell] = [:]
            var proposals: [String: String] = [:]
            for (col, value) in item?.cells ?? [:] {
                guard let c = columns[col] else { continue }
                var cell = PlotGrid.Cell(by: engine.rawValue)
                if c.isTagged { cell.tags = normalize(value.asTags, column: col, in: session, engine: engine) }
                else { cell.text = value.asText.trimmingCharacters(in: .whitespacesAndNewlines) }
                cells[col] = cell
            }
            for (col, value) in item?.proposals ?? [:] where columns[col] != nil {
                proposals[col] = columns[col]!.isTagged
                    ? normalize(value.asTags, column: col, in: session, engine: engine).joined(separator: ", ")
                    : value.asText.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            session.plot.update(chapter, s.key) { row in
                for (col, cell) in cells where !(row.cells[col]?.locked ?? false) { row.cells[col] = cell }
                for (col, p) in proposals {
                    guard var cell = row.cells[col], cell.locked else { continue }
                    let mine = columns[col]!.isTagged ? (cell.tags ?? []).joined(separator: ", ") : cell.text
                    if p != mine, !p.isEmpty { cell.proposal = p; row.cells[col] = cell }
                }
                if NSMaxRange(s.range) <= text.length { row.analyzed = PlotGrid.fingerprint(text.substring(with: s.range)) }
            }
        }
        session.savePlot()
    }
}

/// Proposes where the open chapter's scenes begin; the author picks which markers to insert.
@MainActor
@Observable
final class ScenePlanner {
    struct Proposal: Identifiable, Decodable {
        var id = UUID()
        var start: String
        var title: String
        var include = true
        enum CodingKeys: String, CodingKey { case start, title }
    }

    var running = false
    var engine: AgentKind = .claude
    var chapterID: String?
    var proposals: [Proposal] = []
    var error: String?
    var showing = false

    func propose(_ session: BookSession, engine: AgentKind) {
        guard !running, let ch = session.selectedChapter else { return }
        session.flushSave()
        self.engine = engine
        chapterID = ch.id
        proposals = []
        error = nil
        running = true
        showing = true
        let prompt = Self.prompt(session)
        Task { [weak self] in
            do {
                let raw = try await Agents.oneShot(engine, prompt: prompt, model: Self.model(for: engine), cwd: session.root)
                guard let self else { return }
                self.proposals = Self.parse(raw)
                if self.proposals.isEmpty { self.error = L("\(engine.label) proposed no scenes.") }
            } catch {
                self?.error = error.localizedDescription
            }
            self?.running = false
        }
    }

    /// Cutting a chapter into scenes needs the strongest reader: Opus for Claude, whatever the chat uses.
    static func model(for engine: AgentKind) -> String { TaskModels.model(.plot, for: engine) }

    static func prompt(_ session: BookSession) -> String {
        let fr = session.manifest.lang.hasPrefix("fr")
        return """
        Divide this chapter of the book « \(session.title) » into scenes, as a writer using Scrivener would: a new scene \
        begins with a change of place, of time, of point of view, or a clear break in the action. Do not cut too finely; \
        a scene is usually several paragraphs. Do not change the text.
        Return ONLY a JSON array (no prose, no code fence), in text order, one item per scene, the first one included:
        {"start": "<the first 6 to 12 words of the scene's first paragraph, copied character for character>", \
        "title": "<a short title, 2 to 5 words, in \(fr ? "French" : "the book's language")>"}

        CHAPTER:
        \(session.text)
        """
    }

    static func parse(_ raw: String) -> [Proposal] {
        guard let start = raw.firstIndex(of: "["), let end = raw.lastIndex(of: "]"), start < end,
              let data = String(raw[start...end]).data(using: .utf8) else { return [] }
        return ((try? JSONDecoder().decode([Proposal].self, from: data)) ?? []).filter { !$0.start.isEmpty }
    }

    /// Where each chosen scene starts: the beginning of the paragraph its first words are found in.
    static func locate(_ proposals: [Proposal], in text: String) -> [(offset: Int, title: String)] {
        let ns = text as NSString
        var out: [(Int, String)] = []
        for p in proposals where p.include {
            guard let re = ProofFix.tolerantRegex(p.start, wholeWords: false),
                  let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { continue }
            let para = ns.paragraphRange(for: NSRange(location: m.range.location, length: 0)).location
            if !out.contains(where: { $0.0 == para }) { out.append((para, p.title)) }
        }
        return out.sorted { $0.0 < $1.0 }
    }

    /// The line before `offset` is already a scene marker.
    static func markerJustBefore(_ offset: Int, in text: String) -> Bool {
        let ns = text as NSString
        guard offset > 0 else { return false }
        let prev = ns.lineRange(for: NSRange(location: offset - 1, length: 0))
        let line = ns.substring(with: prev).trimmingCharacters(in: .newlines)
        return Scenes.pattern.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) != nil
    }

    /// Inserts the chosen markers through the editor (undoable; notes follow), last first so offsets hold.
    func apply(_ session: BookSession, bridge: EditorBridge) -> Int {
        guard session.selectedChapterID == chapterID else { error = L("The chapter changed; open it again."); return 0 }
        let spots = Self.locate(proposals, in: session.text)
        var inserted = 0
        for spot in spots.reversed() {
            if Self.markerJustBefore(spot.offset, in: session.text) { continue }
            bridge.replace(NSRange(location: spot.offset, length: 0), with: Scenes.markerLine(spot.title) + "\n")
            inserted += 1
        }
        session.flushSave()
        showing = false
        return inserted
    }
}
