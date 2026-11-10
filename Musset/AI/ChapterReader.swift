import Foundation
import Observation

/// What a reader sends back, and whether it stands: scores within the anchor they claim, quotes found in the text.
enum ReadingCheck {
    struct Answer: Decodable {
        struct Item: Decodable {
            var criterionId: String
            var anchor: String
            var score: Int
            var quotes: [String]
            var justification: String
            var suggestion: String?

            enum CodingKeys: String, CodingKey { case criterionId, anchor, score, quotes, justification, suggestion }
            init(from d: Decoder) throws {
                let c = try d.container(keyedBy: CodingKeys.self)
                criterionId = try c.decode(String.self, forKey: .criterionId)
                anchor = (try? c.decode(String.self, forKey: .anchor)) ?? (try? c.decode(Int.self, forKey: .anchor)).map(String.init) ?? ""
                score = (try? c.decode(Int.self, forKey: .score)) ?? Int((try? c.decode(Double.self, forKey: .score)) ?? -1)
                quotes = (try? c.decode([String].self, forKey: .quotes)) ?? []
                justification = (try? c.decode(String.self, forKey: .justification)) ?? ""
                suggestion = try? c.decode(String.self, forKey: .suggestion)
            }
        }
        /// A fault as the reader reports it, not yet checked against the text.
        struct Hit: Decodable, Sendable {
            var criterionId: String
            var severity: Int
            var quote: String
            var why: String

            enum CodingKeys: String, CodingKey { case criterionId, severity, quote, why }
            init(from d: Decoder) throws {
                let c = try d.container(keyedBy: CodingKeys.self)
                criterionId = (try? c.decode(String.self, forKey: .criterionId)) ?? ""
                severity = (try? c.decode(Int.self, forKey: .severity)) ?? (try? c.decode(String.self, forKey: .severity)).flatMap(Int.init) ?? 0
                quote = (try? c.decode(String.self, forKey: .quote)) ?? ""
                why = (try? c.decode(String.self, forKey: .why)) ?? ""
            }
        }
        var scores: [Item]
        var eliminatory: [Reading.Risk]?
        var maluses: [Hit]?
    }

    static func parse(_ raw: String) -> Answer? {
        guard let data = LenientJSON.object(in: raw) else { return nil }
        return try? JSONDecoder().decode(Answer.self, from: data)
    }

    /// The quote in the text, whatever the spacing, line breaks, apostrophes or quotation marks the reader copied it with.
    static func locate(_ quote: String, in text: String) -> NSRange? {
        let words = quote.split(whereSeparator: { $0.isWhitespace })
        guard !words.isEmpty else { return nil }
        let pattern = words.map { word in
            word.map { ch -> String in
                switch ch {
                case "'", "’", "‘", "ʼ": "['’‘ʼ]"
                case "\"", "“", "”": "[\"“”]"
                default: NSRegularExpression.escapedPattern(for: String(ch))
                }
            }.joined()
        }.joined(separator: #"[\s\u00A0\u202F]+"#)
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        return re.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length))?.range
    }

    /// What is wrong with an item, if anything. A quote that is not in the text is dropped; it needs one that is.
    static func problem(_ item: Answer.Item, criterion: Criterion, text: String) -> String? {
        guard let band = Scoring.band(item.anchor) else { return "anchor must be 5, 10, 15 or 19" }
        guard band.contains(item.score) else { return "score \(item.score) is outside anchor \(item.anchor) (\(band.lowerBound)–\(band.upperBound))" }
        guard !item.justification.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "the justification is missing" }
        if criterion.requiresQuote, !item.quotes.contains(where: { locate($0, in: text) != nil }) {
            return "no quote was found word for word in the chapter"
        }
        return nil
    }

    /// The faults that stand: of a family in the rubric, of severity 1 to 3, once each, with a passage found in the text. No proof, no penalty.
    static func maluses(_ hits: [Answer.Hit], bareme: Bareme, text: String) -> [Reading.Malus] {
        bareme.maluses.compactMap { item -> Reading.Malus? in
            var seen = Set<String>()
            let kept = hits.filter {
                $0.criterionId == item.criterionId && (1...3).contains($0.severity) && locate($0.quote, in: text) != nil && seen.insert($0.quote).inserted
            }
            guard !kept.isEmpty else { return nil }
            return Reading.Malus(criterionId: item.criterionId, label: bareme.criterion(item.criterionId)?.label ?? item.criterionId,
                                 points: Scoring.penalty(severities: kept.map(\.severity), max: item.maxPenalty),
                                 hits: kept.map { .init(severity: $0.severity, quote: $0.quote, why: $0.why) })
        }.sorted { $0.points > $1.points }
    }

    /// Each fault as a note on its passage: a note the text settles closes like any other.
    static func notes(for maluses: [Reading.Malus]) -> [Annotator.Item] {
        maluses.flatMap { m in m.hits.map { Annotator.Item(quote: $0.quote, note: "[Malus] \(m.label) : \($0.why)") } }
    }

    static func score(_ item: Answer.Item, criterion: Criterion, text: String) -> Reading.Score {
        Reading.Score(criterionId: criterion.id, label: criterion.label, score: item.score, anchor: item.anchor,
                      quotes: item.quotes.filter { locate($0, in: text) != nil }, justification: item.justification,
                      suggestion: item.suggestion?.isEmpty == true ? nil : item.suggestion)
    }
}

/// The critique as a skill: the process lives in `SKILL.md`, shipped with the app; a book may carry its own in `.musset/skills/bareme-critique/SKILL.md`.
/// Book, chapter and instructions go in one prompt, sent once.
enum CritiqueSkill {
    struct Inputs {
        var bareme: Bareme
        var criteria: [Criterion]
        var title: String
        var position: Int
        var count: Int
        var book: String
        var plan: String
        var chapter: String
        var previous: Reading.Advice? = nil
        var changes: String = ""
        var margin: String = ""
    }

    static func template(root: URL?, bundle: Bundle = .main) -> String {
        let own = root?.appendingPathComponent(".musset/skills/bareme-critique/SKILL.md")
        let shipped = bundle.url(forResource: "SKILL", withExtension: "md")
        let raw = own.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? shipped.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        return withoutFrontMatter(raw)
    }

    static func withoutFrontMatter(_ s: String) -> String {
        guard s.hasPrefix("---\n"), let end = s.range(of: "\n---\n", range: s.index(s.startIndex, offsetBy: 4)..<s.endIndex) else { return s }
        return String(s[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Never the weights, never an earlier score. In one pass, so that the book's text is never read as placeholders.
    static func render(_ template: String, _ i: Inputs) -> String {
        let values: [String: String] = [
            "BOOK": i.book.isEmpty ? "Aucun autre chapitre n'existe encore." : i.book,
            "BAREME": i.bareme.name,
            "CONTRACT": i.bareme.contract,
            "TITLE": i.title,
            "POSITION": "\(i.position)",
            "COUNT": "\(i.count)",
            "PLAN": i.plan.isEmpty ? "" : "Ce que l'auteur en dit dans son plan :\n\(i.plan)",
            "CRITERIA": criteriaList(i.criteria),
            "MALUSES": malusList(i.bareme),
            "CALIBRATION": i.bareme.calibration.isEmpty ? "" : "Repère : \(i.bareme.calibration)",
            "RULES": i.bareme.rules.isEmpty ? "" : "## Les exigences de l'auteur\n\n\(i.bareme.rules)",
            "MEMORY": memory(i.previous, changes: i.changes),
            "MARGIN": i.margin.trimmingCharacters(in: .whitespacesAndNewlines),
            "CHAPTER": i.chapter,
        ]
        let re = try! NSRegularExpression(pattern: #"\{\{([A-Z_]+)\}\}"#)
        let ns = template as NSString
        var out = "", cursor = 0
        for m in re.matches(in: template, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            let key = ns.substring(with: m.range(at: 1))
            out += values[key] ?? ns.substring(with: m.range)
            cursor = NSMaxRange(m.range)
        }
        return out + ns.substring(from: cursor)
    }

    private static func criteriaList(_ criteria: [Criterion]) -> String {
        criteria.map { c -> String in
            let a = c.anchors ?? [:]
            return """
            ### \(c.id) — \(c.label)
            \(c.definition)
            Question : \(c.question)
            - 5/20 : \(a["5"] ?? "")
            - 10/20 : \(a["10"] ?? "")
            - 15/20 : \(a["15"] ?? "")
            - 19/20 : \(a["19"] ?? "")
            """
        }.joined(separator: "\n\n")
    }

    /// The faults to look for, without what they cost.
    private static func malusList(_ bareme: Bareme) -> String {
        let items = bareme.maluses.compactMap { bareme.criterion($0.criterionId) }.map { c -> String in
            let g = c.severityGuide ?? [:]
            return "### \(c.id) — \(c.label)\n\(c.definition)\n- Gravité 1 : \(g["1"] ?? "")\n- Gravité 2 : \(g["2"] ?? "")\n- Gravité 3 : \(g["3"] ?? "")"
        }
        return items.isEmpty ? "" : "## Les fautes à relever\n\n" + items.joined(separator: "\n\n")
    }

    /// What was advised, and what changed since. No score: the note is given on today's text.
    private static func memory(_ previous: Reading.Advice?, changes: String) -> String {
        guard let previous else { return "" }
        let axes = previous.axes.map { axis in
            let steps = (axis.steps ?? []).map { "  - \($0.action) « \($0.quote) » : \($0.detail)" }
            return (["- « \(axis.title) » : \(axis.why) Direction : \(axis.direction)"] + steps).joined(separator: "\n")
        }.joined(separator: "\n")
        return """
        ## Ton dernier avis

        \(previous.overview)
        \(axes)
        \(previous.keep.map { "À garder : \($0)" } ?? "")

        ## Ce que l'auteur a changé depuis

        \(changes.isEmpty ? "Rien : le texte n'a pas changé." : changes)
        """
    }

    struct Answer: Decodable {
        var overview: String?
        var axes: [Reading.Axis]?
        var keep: String?
        var notes: [Annotator.Item]?
    }

    /// The advice part of an answer. A quote that is not in the text is dropped; the axis stands without it.
    /// A gesture on a passage that is not in the text points nowhere, and goes too.
    static func advice(in raw: String, text: String) -> (advice: Reading.Advice, notes: [Annotator.Item])? {
        guard let data = LenientJSON.object(in: raw), let answer = try? JSONDecoder().decode(Answer.self, from: data) else { return nil }
        let axes = (answer.axes ?? []).prefix(3).filter { !$0.direction.isEmpty }.map { axis in
            var a = axis
            if let q = a.quote, ReadingCheck.locate(q, in: text) == nil { a.quote = nil }
            a.steps = (a.steps ?? []).compactMap { step in
                guard !step.detail.isEmpty, ReadingCheck.locate(step.quote, in: text) != nil else { return nil }
                var s = step
                if let t = s.target, ReadingCheck.locate(t, in: text) == nil { s.target = nil }
                return s
            }
            return a
        }
        let advice = Reading.Advice(overview: answer.overview ?? "", axes: axes, keep: answer.keep)
        guard !advice.overview.isEmpty || !axes.isEmpty else { return nil }
        return (advice, answer.notes ?? [])
    }
}

/// Reads a chapter: one session of its own in an empty folder, apart from the chat. It receives everything at once and answers with its scores and its advice together.
@MainActor
@Observable
final class ChapterReader {
    var running = false
    var status: String?
    var lastError: String?
    /// Goes up when a reading has been saved.
    var completed = 0
    @ObservationIgnored private var task: Task<Void, Never>?

    func stop() { task?.cancel(); running = false; status = nil }

    /// `done` receives the saved reading and what happened to its notes; nil when there is none.
    func read(_ session: BookSession, engine: AgentKind, model chosen: String? = nil, force: Bool = false, done: @escaping (Reading?, String?, PinResult) -> Void = { _, _, _ in }) {
        guard !running, let chapter = session.selectedChapter, let bareme = Bareme.forBook(session.root) else { return done(nil, nil, .none) }
        session.flushSave()
        let chapters = session.manifest.chapters
        let text = BookStore.stripHTMLComments(Revisions.resolveAll(session.editorText(of: chapter.id), accept: false))
        let criteria = bareme.chapter.compactMap { bareme.criterion($0.criterionId) }
        let model = chosen ?? (engine == .claude ? (UserDefaults.standard.string(forKey: "model.chat.claude") ?? "opus")
                                                 : (UserDefaults.standard.string(forKey: "model.chat.codex") ?? ""))
        let hash = PlotGrid.fingerprint(text)
        let earlier = Reading.load(session.root, chapter.id)
        // The same text, the same rubric, the same reader: the answer is the one already given.
        if !force, let same = earlier.last(where: { $0.agent == engine.rawValue && $0.model == model }), same.textHash == hash, same.baremeVersion == bareme.version, same.hasConcreteAdvice {
            lastError = nil
            status = L("Text unchanged: the last reading still stands.")
            return done(same, nil, .none)
        }
        let previousText = try? String(contentsOf: Reading.lastTextURL(session.root, chapter.id), encoding: .utf8)
        let prompt = CritiqueSkill.render(CritiqueSkill.template(root: session.root), .init(
            bareme: bareme, criteria: criteria, title: chapter.title,
            position: (chapters.firstIndex { $0.id == chapter.id } ?? 0) + 1, count: chapters.count,
            book: Self.bookContext(session, chapter: chapter.id) + Self.sheets(session), plan: Self.plan(session, chapter: chapter.id), chapter: text,
            previous: earlier.last { $0.advice != nil }?.advice,
            changes: Self.changes(from: previousText ?? text, to: text),
            margin: Annotator.existingNotes(session)))
        running = true
        lastError = nil
        status = L("\(engine.label) is reading the chapter…")
        task = Task { [weak self] in
            let empty = FileManager.default.temporaryDirectory.appendingPathComponent("musset-reading-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: empty) }
            let outcome = await Task.detached { () -> Result<SessionResult, Error> in
                do {
                    return .success(try await ChapterReader.runSession(criteria, text: text, prompt: prompt) { message, resume in
                        try await Agents.converse(engine, prompt: message, session: resume, model: model, cwd: empty)
                    })
                } catch { return .failure(error) }
            }.value
            guard let self, !Task.isCancelled else { return done(nil, nil, .none) }
            self.running = false
            self.status = nil
            let result: SessionResult
            switch outcome {
            case .failure(let e):
                self.lastError = e.localizedDescription
                return done(nil, nil, .none)
            case .success(let r): result = r
            }
            let maluses = result.hits.map { ReadingCheck.maluses($0, bareme: bareme, text: text) }
            guard let total = Scoring.total(weights: bareme.weights, scores: result.scores, penalty: (maluses ?? []).reduce(0) { $0 + $1.points }) else {
                self.lastError = L("No score could be verified in this reading.")
                return done(nil, nil, .none)
            }
            let ordered = bareme.chapter.compactMap { item in result.scores.first { $0.criterionId == item.criterionId } }
            let reading = Reading(agent: engine.rawValue, model: model, textHash: hash, baremeVersion: bareme.version, baremeName: bareme.name,
                                  weights: bareme.weights, scores: ordered, risks: result.risks, total: total, advice: result.advice, maluses: maluses)
            do {
                if !FileManager.default.fileExists(atPath: Bareme.url(session.root).path) { try bareme.save(session.root) }
                try Reading.append(reading, root: session.root, chapter: chapter.id)
                try? text.write(to: Reading.lastTextURL(session.root, chapter.id), atomically: true, encoding: .utf8)
                session.pendingCommit = true
                let pins = Self.pinNotes(ReadingCheck.notes(for: maluses ?? []) + result.notes, of: reading, chapter: chapter.id, in: session)
                self.completed += 1
                done(reading, reading.id.uuidString, pins)
            } catch {
                self.lastError = error.localizedDescription
                done(nil, nil, .none)
            }
        }
    }

    struct SessionResult: Sendable {
        var scores: [Reading.Score]
        var risks: [Reading.Risk]
        var advice: Reading.Advice?
        var notes: [Annotator.Item]
        /// Nil when the reader said nothing of faults; empty when it found none.
        var hits: [ReadingCheck.Answer.Hit]? = nil
    }

    /// One session from start to end: everything is sent once; what does not stand is asked again in the same session, once. What still fails is marked unverified.
    nonisolated static func runSession(_ criteria: [Criterion], text: String, prompt: String,
                                       call: @Sendable (String, String?) async throws -> (text: String, session: String?)) async throws -> SessionResult {
        var result = SessionResult(scores: [], risks: [], advice: nil, notes: [])
        var pending = criteria
        var message = prompt
        var session: String?
        for attempt in 0..<2 {
            let reply = try await call(message, session)
            session = reply.session ?? session
            let answer = ReadingCheck.parse(reply.text)
            if attempt == 0 {
                result.risks = (answer?.eliminatory ?? []).map { r in
                    Reading.Risk(risk: r.risk, quote: r.quote.flatMap { ReadingCheck.locate($0, in: text) != nil ? $0 : nil })
                }
            }
            if result.hits == nil { result.hits = answer?.maluses }
            if let found = CritiqueSkill.advice(in: reply.text, text: text) {
                if var advice = result.advice {
                    // The second answer only completes the axes that had no gesture to offer.
                    for axis in found.advice.axes where !(axis.steps ?? []).isEmpty {
                        if let i = advice.axes.firstIndex(where: { $0.title == axis.title && ($0.steps ?? []).isEmpty }) { advice.axes[i] = axis }
                    }
                    result.advice = advice
                } else {
                    result.advice = found.advice
                    result.notes = found.notes
                }
            }
            var problems: [String] = []
            if answer == nil {
                problems.append("- ta réponse n'est pas du JSON lisible : à l'intérieur d'une chaîne, écris les guillemets droits \\\" ou remplace-les par « »")
            }
            var failed: [Criterion] = []
            for c in pending {
                guard let item = answer?.scores.first(where: { $0.criterionId == c.id }) else {
                    problems.append("- \(c.id) : absent de la réponse"); failed.append(c); continue
                }
                if let p = ReadingCheck.problem(item, criterion: c, text: text) {
                    problems.append("- \(c.id) : \(p)"); failed.append(c)
                    if attempt == 1 {
                        var s = ReadingCheck.score(item, criterion: c, text: text)
                        s.unverified = true
                        result.scores.append(s)
                    }
                } else {
                    result.scores.append(ReadingCheck.score(item, criterion: c, text: text))
                }
            }
            pending = failed
            let missingAdvice = result.advice == nil
            let vague = (result.advice?.axes ?? []).filter { ($0.steps ?? []).isEmpty }.map(\.title)
            guard !problems.isEmpty || missingAdvice || !vague.isEmpty, attempt == 0 else { break }
            message = """
            Ta réponse est à compléter.
            \(problems.joined(separator: "\n"))
            \(missingAdvice ? "- overview, axes, keep et notes manquent ou sont illisibles." : "")
            \(vague.isEmpty ? "" : "- Ces axes n'ont aucun geste dont le passage se trouve dans le texte : \(vague.map { "« \($0) »" }.joined(separator: ", ")). Renvoie-les entiers dans \"axes\", même titre, avec leurs \"steps\".")
            Réponds UNIQUEMENT en JSON, avec seulement ce qui manque, dans le même format. Copie les citations mot pour mot.
            """
        }
        for c in pending where !result.scores.contains(where: { $0.criterionId == c.id }) {
            result.scores.append(Reading.Score(criterionId: c.id, label: c.label, score: 0, anchor: "", quotes: [], justification: "", unverified: true))
        }
        return result
    }

    /// The editor's notes in the text, next to what is already there. Only if the chapter is still the open one: its notes are the ones loaded.
    static func pinNotes(_ items: [Annotator.Item], of reading: Reading, chapter: String, in session: BookSession) -> PinResult {
        guard session.selectedChapterID == chapter else { return .none }
        session.notes.lastAutoResolved = 0
        let placed = Annotator.add(items, to: session, author: reading.agent == "codex" ? .codex : .claude,
                                   defaultKind: .critique, scope: nil, run: reading.id.uuidString)
        let resolved = session.notes.lastAutoResolved
        return PinResult(placed: placed, skipped: items.filter { $0.resolves == nil }.count - placed, resolved: resolved)
    }

    /// `skipped`: passages that already carry a note, or that the author settled.
    struct PinResult: Sendable, Equatable {
        var placed: Int
        var skipped: Int
        var resolved = 0
        static let none = PinResult(placed: 0, skipped: 0)
    }

    /// What the chat's next message tells the conversation: it discusses the reading, it does not score again.
    nonisolated static func summary(of reading: Reading, chapter: String) -> String {
        let lines = reading.scores.map { s in
            s.unverified ? "- \(s.label) : non vérifié" : "- \(s.label) : \(s.score)/20. \(s.justification)"
        }.joined(separator: "\n")
        return """
        (A separate reader, who has not seen this conversation, has just read « \(chapter) »: \(Int(reading.total.rounded()))/100.
        \(lines)
        \((reading.maluses ?? []).map { "- Malus \($0.label) : −\(String(format: "%.1f", $0.points))" }.joined(separator: "\n"))
        \(reading.advice?.overview ?? "")
        \(reading.axes.map { axis in
            (["Axis: \(axis.title). \(axis.direction)"] + (axis.steps ?? []).map { "- \($0.action) « \($0.quote) » : \($0.detail)" }).joined(separator: "\n")
        }.joined(separator: "\n"))
        Discuss this reading if the author asks. Do not give a score of your own.)
        """
    }

    /// What the author changed since the last reading: paragraphs gone, paragraphs new.
    nonisolated static func changes(from old: String, to new: String) -> String {
        func paragraphs(_ s: String) -> [String] { s.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
        let before = paragraphs(old), after = paragraphs(new)
        let gone = before.filter { !after.contains($0) }.map { "- Retiré ou modifié : \($0)" }
        let added = after.filter { !before.contains($0) }.map { "- Nouveau ou modifié : \($0)" }
        return String((gone + added).joined(separator: "\n").prefix(8_000))
    }

    /// The author's own words on this chapter: its synopsis, and what they wrote in the plan of its scenes, hidden plot included.
    static func plan(_ session: BookSession, chapter: String) -> String {
        var lines: [String] = []
        let own = session.plot.chapterSynopsis(chapter)
        if !own.isEmpty { lines.append("Synopsis : \(own)") }
        for scene in session.scenes[chapter] ?? [] {
            let cells = session.plot.columns.compactMap { c -> String? in
                guard let cell = session.plot.row(chapter, scene.key).cells[c.id], cell.by == "me", !cell.text.isEmpty else { return nil }
                return "\(c.title) : \(cell.text)"
            }
            if !cells.isEmpty { lines.append("Scène « \(scene.key) » : " + cells.joined(separator: " ; ")) }
        }
        return lines.joined(separator: "\n")
    }

    /// The author's sheets from the Bible, to check the text against. Never the documents.
    static func sheets(_ session: BookSession) -> String {
        let sheets = session.bible.sheetsForReader
        return sheets.isEmpty ? "" : "\n\n## Les fiches de l'auteur\nCe sont ses notes, pas le livre. Ne les note pas. Si le texte les contredit (âge, date, lieu, nom), relève-le dans une note [Réserve].\n\n" + sheets
    }

    /// The whole book, as a reader has it: every chapter's text, in order. The chapter being read stays apart. Past this size, the plan stands in for it.
    static func bookContext(_ session: BookSession, chapter: String, limit: Int = 1_200_000) -> String {
        let chapters = session.manifest.chapters.filter { !$0.excludeFromExport }
        let parts = chapters.map { ch -> String in
            ch.id == chapter ? "### \(ch.title)\n[Le chapitre à noter : il est donné plus bas.]"
                             : "### \(ch.title)\n" + BookStore.stripHTMLComments(Revisions.resolveAll(session.editorText(of: ch.id), accept: false))
        }
        let whole = parts.joined(separator: "\n\n")
        return whole.count <= limit ? whole : before(session, chapter: chapter)
    }

    /// The book so far, from the plan alone: its synopsis, a line per earlier chapter, more for the last three.
    static func before(_ session: BookSession, chapter: String) -> String {
        let chapters = session.manifest.chapters
        guard let i = chapters.firstIndex(where: { $0.id == chapter }), i > 0 else { return "" }
        let lines = chapters[..<i].enumerated().map { n, ch -> String in
            var line = "- \(ch.title)"
            let own = session.plot.chapterSynopsis(ch.id)
            let scenes = (session.scenes[ch.id] ?? []).compactMap { session.plot.row(ch.id, $0.key).cells["main"]?.text }.filter { !$0.isEmpty }
            if !own.isEmpty { line += " : \(own)" }
            else if n >= i - 3 { line += scenes.isEmpty ? "" : " : " + scenes.joined(separator: " ") }
            else if let first = scenes.first { line += " : \(first)" }
            return line
        }
        return String((([session.plot.synopsis].compactMap { $0 } + lines).joined(separator: "\n")).suffix(12_000))
    }
}
