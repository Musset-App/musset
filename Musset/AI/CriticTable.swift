import SwiftUI

/// A character at the table. Imagined voices: nothing they say commits the people or houses they evoke.
struct Critic: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var horizon: String
    var group: String? = nil

    private static func c(_ id: String, _ name: String, _ group: String, _ horizon: String) -> Critic {
        Critic(id: id, name: name, horizon: horizon, group: group)
    }

    static let groups = ["edition", "presse", "ecrivains", "lecteurs", "mine"]

    static func groupLabel(_ id: String) -> String {
        switch id {
        case "edition": L("Publishers")
        case "presse": L("Press and bookshops")
        case "ecrivains": L("Writers")
        case "lecteurs": L("Readers")
        default: L("My characters")
        }
    }

    static let panel: [Critic] = [
        c("gallimard", "Éditeur chez Gallimard", "edition", "un éditeur de la Blanche chez Gallimard : la langue d'abord, la tenue, la place du texte dans une longue histoire de la littérature française."),
        c("albinmichel", "Éditrice chez Albin Michel", "edition", "une éditrice chez Albin Michel : l'histoire, le lecteur, ce que le livre peut devenir en librairie, sans mépris pour le succès."),
        c("minuit", "Éditeur aux éditions de Minuit", "edition", "un éditeur de Minuit : l'économie de moyens, la forme, tout ce qui peut encore être retiré."),
        c("actessud", "Éditrice chez Actes Sud", "edition", "une éditrice chez Actes Sud : le souffle, le monde que le livre ouvre, la possibilité d'une traduction."),
        c("lemonde", "Critique littéraire au Monde", "presse", "un critique du Monde des livres : il situe le texte dans la rentrée et dans les débats du moment, et sa phrase d'éloge coûte cher."),
        c("telerama", "Critique littéraire à Télérama", "presse", "une critique de Télérama : sensible à la sincérité et à l'engagement, allergique à la pose, attentive à ce que le livre dit du monde."),
        c("figaro", "Critique au Figaro littéraire", "presse", "un critique du Figaro littéraire : le style, la tradition, une méfiance amusée envers l'autofiction."),
        c("libraire", "Libraire indépendante", "presse", "une libraire indépendante : à qui elle mettrait ce livre dans les mains, ce qu'on en dit en une phrase, où un lecteur le lâche."),
        c("houellebecq", "Michel Houellebecq", "ecrivains", "Michel Houellebecq, imaginé d'après son œuvre et ses essais : la platitude assumée, la sociologie du désir, le rejet des effets de style."),
        c("ormesson", "Jean d’Ormesson", "ecrivains", "Jean d'Ormesson, imaginé d'après son œuvre : l'érudition légère, le goût du bonheur et de la phrase claire, l'ironie aimable."),
        c("flaubert", "Gustave Flaubert", "ecrivains", "Gustave Flaubert, imaginé d'après sa correspondance : le gueuloir, la phrase éprouvée à voix haute, la chasse à la répétition et à la bêtise."),
        c("duras", "Marguerite Duras", "ecrivains", "Marguerite Duras, imaginée d'après son œuvre : le blanc, le silence, ce qui ne se dit pas, le refus de l'explication."),
        c("menagere", "Ménagère de 50 ans", "lecteurs", "une femme de 50 ans qui lit le soir, sans bagage littéraire particulier : elle dit où elle s'ennuie, où elle se reconnaît, ce qui la choque, ce qu'elle raconterait à sa sœur."),
        c("prof", "Prof de français", "lecteurs", "une professeure de français en lycée : la langue, les procédés, ce qu'elle pourrait faire étudier et ce qu'elle soulignerait en rouge."),
        c("patron", "Chef d'entreprise", "lecteurs", "un chef d'entreprise qui lit peu et vite : il veut savoir où ça mène, juge le temps qu'on lui prend, n'a aucune patience pour la complaisance."),
        c("etudiante", "Étudiante en lettres", "lecteurs", "une étudiante en lettres de 22 ans : très lectrice, féroce, attentive à ce qui a vieilli et aux angles morts de l'auteur."),
        c("metro", "Lecteur du métro", "lecteurs", "un grand lecteur qui lit dans les transports : où il se perd, où il rate sa station, sans jargon."),
    ]

    /// The author's own characters, tracked with the book.
    static func mine(_ root: URL) -> [Critic] {
        JSONFile.read(at: minesURL(root)) ?? []
    }

    static func saveMine(_ list: [Critic], root: URL) {
        try? BookStore(root: root).ensureMussetDir()
        try? JSONFile.write(list, to: minesURL(root))
    }

    private static func minesURL(_ root: URL) -> URL { root.appendingPathComponent(".musset/critics.json") }
}

/// A conversation with one reader about their reading, or a debate between several. Kept in `.musset/chat/tables/` (git-ignored, like the chat).
struct CriticTableRecord: Codable, Identifiable {
    enum Kind: String, Codable { case reader, debate }
    struct Turn: Codable, Identifiable, Equatable {
        var id = UUID()
        /// Nil: the author.
        var critic: String?
        var text: String
        /// Given alone, before hearing the others.
        var opening: Bool? = nil
    }

    var id: String
    var kind: Kind
    var title: String
    var critics: [Critic]
    var agent: AgentKind
    var model: String
    /// Everything a voice is given the first time it speaks.
    var context: String
    var turns: [Turn] = []
    var sessions: [String: String] = [:]
    /// How many turns each voice has already heard.
    var heard: [String: Int] = [:]
    /// Where the text stands, so the judgment takes it into account. Nil: finished (and older debates).
    var stage: Stage? = nil
    /// Judged against the author's synopsis and plan: two ratings, what is written and its potential.
    var againstPlan: Bool? = nil

    /// How far along the text under debate is.
    enum Stage: String, Codable, CaseIterable, Identifiable {
        case finished, draft, incomplete, beginning
        var id: String { rawValue }
        var label: String {
            switch self {
            case .finished: L("Finished", ctx: "Terminé")
            case .draft: L("First draft")
            case .incomplete: L("Incomplete")
            case .beginning: L("Just the beginning")
            }
        }
        /// What the voices are told about it.
        var instruction: String? {
            switch self {
            case .finished: nil
            case .draft: "This is a first draft. Judge what it is trying to do, how far it gets and where it is heading; do not count against it roughness, repetitions, typos or unpolished sentences, which revision will deal with."
            case .incomplete: "This text is unfinished: parts are missing and threads are left open. Judge what is there and where it is going; do not count against it what is not written yet, an ending or a resolution."
            case .beginning: "This is only the beginning of the book. Judge the opening, the voice, the promise and the wish to read on; do not ask it for what a whole book would give."
            }
        }
    }

    /// A first view ends with its rating, « ★ 4/5 »: the stars, and the text without that line. Against a plan it
    /// ends with two, « Écrit ★ 3/5 » then « Potentiel ★ 4/5 »: `stars` is what is written, `potential` the plan's.
    static func rating(in text: String) -> (stars: Int?, potential: Int?, text: String) {
        var lines = text.components(separatedBy: "\n")
        var stars: Int?, potential: Int?
        guard let re = try? NSRegularExpression(pattern: #"^\W*(?:(\p{L}+)\s*:?\s*)?\W*([1-5])(?:[.,]\d)?\s*/\s*5\W*$"#) else { return (nil, nil, text) }
        for _ in 0..<2 {
            while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
            guard let last = lines.last, let m = re.firstMatch(in: last, range: NSRange(last.startIndex..., in: last)),
                  let r = Range(m.range(at: 2), in: last), let n = Int(last[r]) else { break }
            let label = Range(m.range(at: 1), in: last).map { last[$0].lowercased() } ?? ""
            if label.hasPrefix("pot") { potential = n } else if stars == nil { stars = n } else { break }
            lines.removeLast()
        }
        guard stars != nil || potential != nil else { return (nil, nil, text) }
        return (stars, potential, lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Each voice's rating, from its first view.
    func stars(of critic: String) -> Int? {
        turns.first { $0.critic == critic && $0.opening == true }.flatMap { Self.rating(in: $0.text).stars }
    }

    /// Each voice's rating of the plan's potential, when the book was judged against one.
    func potential(of critic: String) -> Int? {
        turns.first { $0.critic == critic && $0.opening == true }.flatMap { Self.rating(in: $0.text).potential }
    }

    /// The table's mean rating, if any voice gave one.
    var meanStars: Double? {
        let all = critics.compactMap { stars(of: $0.id) }
        return all.isEmpty ? nil : Double(all.reduce(0, +)) / Double(all.count)
    }

    static func url(_ root: URL, _ id: String) -> URL { BookStore(root: root).chatDir.appendingPathComponent("tables/\(id).json") }

    static func load(_ root: URL, _ id: String) -> CriticTableRecord? {
        JSONFile.read(at: url(root, id))
    }

    func save(_ root: URL) {
        try? JSONFile.write(self, to: Self.url(root, id), [])
    }

    func name(of critic: String?) -> String {
        guard let critic else { return L("The author") }
        return critics.first { $0.id == critic }?.name ?? critic
    }

    /// What a voice is told about who it is. Sent once: a resumed session keeps it.
    func system(for critic: Critic) -> String {
        let others = critics.filter { $0.id != critic.id }.map(\.name).joined(separator: ", ")
        switch kind {
        case .reader:
            return """
            You are the reader who wrote the reading below. You read the chapter blind, apart from any other conversation, and the author now comes to talk about it. \
            Explain why you said what you said, with passages quoted exactly. When the author shows you were wrong, withdraw the point; when they only disagree, hold it. \
            Never flatter. Give no new score. The book's chapters are files in the current directory: read them with your Read tool when a question needs them. \
            Answer in the language the author writes in. \(WritingPartner.noRewrites)
            """
        case .debate:
            return """
            This is an imagined reading, a literary game for the author's private use: you play « \(critic.name) », \(critic.horizon) \
            The voice is imagined. Never attribute invented facts, quotations or a biography to a real person or house, and never break character to say so. \
            You sit at a table with \(others), discussing « \(title) ». The author listens and may speak. Speak in your own voice, as in a real conversation, with no preamble and no list. \
            Rest each claim on a passage quoted exactly, in « ». Answer the others by name. Disagree when you disagree: do not converge out of politeness, and do not repeat what was said. \
            Give your rating once, at the end of your first view, and never again; never conclude for the table. Say nothing, and quote nothing, about any sexual scene involving minors. \
            The book's chapters are files in the current directory: read them with your Read tool when you need them. \
            Answer in the book's language. \(WritingPartner.noRewrites)
            """
        }
    }

    /// What a voice hears now: the context the first time, then the turns it missed.
    /// `opening`: its own view first, without hearing anyone.
    func prompt(for critic: Critic, opening: Bool = false) -> String {
        var parts: [String] = []
        if sessions[critic.id] == nil {
            parts.append(context)
            if let note = stage?.instruction { parts.append(note) }
        }
        if opening {
            if againstPlan == true {
                parts.append("Donnez votre avis, seul, sans savoir ce que pensent les autres : ce que font les chapitres écrits, à leur place dans le plan, puis ce que vaut le plan lui-même, ses forces et ses risques. En 220 mots au plus. Terminez par deux dernières lignes qui ne contiennent que vos notes sur cinq étoiles, sous cette forme exacte : « Écrit ★ 3/5 » puis « Potentiel ★ 4/5 » (des nombres entiers de 1 à 5).")
            } else {
                parts.append("Donnez votre avis, seul, sans savoir ce que pensent les autres : ce qui tient, ce qui ne tient pas, ce que vous feriez de ce texte à votre place. En 200 mots au plus. Terminez par une dernière ligne qui ne contient que votre note sur cinq étoiles, sous cette forme exacte : « ★ 3/5 » (un nombre entier de 1 à 5).")
            }
            return parts.joined(separator: "\n\n")
        }
        let start = sessions[critic.id] == nil ? 0 : (heard[critic.id] ?? 0)
        let missed = turns.dropFirst(start).filter { $0.critic != critic.id }
        if !missed.isEmpty { parts.append(missed.map { "\(name(of: $0.critic)) : \($0.text)" }.joined(separator: "\n\n")) }
        if kind == .debate { parts.append("À vous, en 120 mots au plus.") }
        return parts.joined(separator: "\n\n")
    }
}

/// Runs a table: one voice at a time, each in a session of its own, so it only hears what it missed.
@MainActor
@Observable
final class CriticTable: Identifiable {
    private(set) var record: CriticTableRecord
    private(set) var speaking: String?
    private(set) var lastError: String?
    let root: URL
    nonisolated var id: ObjectIdentifier { ObjectIdentifier(self) }

    typealias Voice = (_ agent: AgentKind, _ prompt: String, _ session: String?, _ cwd: URL, _ model: String, _ system: String,
                       _ onEvent: @escaping @Sendable (AgentEvent) -> Void, _ onDone: @escaping @Sendable (Int32, String) -> Void) throws -> Process?

    @ObservationIgnored private let voice: Voice
    @ObservationIgnored private var queue: [(id: String, opening: Bool)] = []
    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var retried = false

    var running: Bool { speaking != nil }

    init(record: CriticTableRecord, root: URL, voice: Voice? = nil) {
        self.record = record
        self.root = root
        self.voice = voice ?? { agent, prompt, session, cwd, model, system, onEvent, onDone in
            try Agents.send(agent, prompt: prompt, session: session, cwd: cwd, model: model, systemPrompt: system, onEvent: onEvent, onDone: onDone)
        }
    }

    /// Each gives their view alone, then they argue.
    func openDebate() {
        let ids = record.critics.map(\.id)
        enqueue(ids.map { ($0, true) } + ids.map { ($0, false) })
    }

    /// One more round.
    func anotherRound() { enqueue(record.critics.map { ($0.id, false) }) }

    /// The author speaks: the reader answers, or the whole table does.
    func say(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        record.turns.append(.init(critic: nil, text: text))
        record.save(root)
        enqueue(record.critics.map { ($0.id, false) })
    }

    func stop() {
        queue.removeAll()
        process?.terminate()
        process = nil
        speaking = nil
        record.turns.removeAll { $0.critic != nil && $0.text.isEmpty }
        record.save(root)
    }

    private func enqueue(_ ids: [(id: String, opening: Bool)]) {
        queue += ids
        if !running { next() }
    }

    private func next() {
        guard !running, !queue.isEmpty else { return }
        let item = queue.removeFirst()
        guard let critic = record.critics.first(where: { $0.id == item.id }) else { return next() }
        retried = false
        speak(critic, opening: item.opening)
    }

    private func speak(_ critic: Critic, opening: Bool = false) {
        speaking = critic.id
        lastError = nil
        let prompt = record.prompt(for: critic, opening: opening)
        // The voice has now heard everything said so far, and will hear itself. Giving its view alone, it has heard nothing yet.
        record.heard[critic.id] = opening ? 0 : record.turns.count + 1
        let turn = CriticTableRecord.Turn(critic: critic.id, text: "", opening: opening ? true : nil)
        record.turns.append(turn)
        do {
            process = try voice(record.agent, prompt, record.sessions[critic.id], root, record.model, record.system(for: critic),
                                { [weak self] event in Task { @MainActor in self?.handle(event, turn: turn.id, critic: critic.id) } },
                                { [weak self] code, stderr in Task { @MainActor in self?.finished(code, stderr, turn: turn.id, critic: critic) } })
        } catch {
            finished(1, error.localizedDescription, turn: turn.id, critic: critic)
        }
    }

    private func handle(_ event: AgentEvent, turn: UUID, critic: String) {
        guard let i = record.turns.firstIndex(where: { $0.id == turn }) else { return }
        switch event {
        case .session(let id): record.sessions[critic] = id
        case .textDelta(let t): record.turns[i].text += t
        case .fullText(let t):
            // Codex sends whole messages; Claude's final result repeats the streamed text.
            if record.agent == .codex { record.turns[i].text += (record.turns[i].text.isEmpty ? "" : "\n\n") + t }
            else if record.turns[i].text.isEmpty { record.turns[i].text = t }
        case .status: break
        case .error(let e): lastError = Agents.err(e).localizedDescription
        }
    }

    private func finished(_ code: Int32, _ stderr: String, turn: UUID, critic: Critic) {
        process = nil
        guard speaking == critic.id else { return }
        let empty = record.turns.first { $0.id == turn }?.text.isEmpty ?? true
        // A session that can no longer be resumed: this voice starts again, with everything said so far.
        if code != 0, code != 15, empty, record.sessions[critic.id] != nil, !retried {
            retried = true
            let opening = record.turns.first { $0.id == turn }?.opening == true
            record.turns.removeAll { $0.id == turn }
            record.sessions[critic.id] = nil
            speak(critic, opening: opening)
            return
        }
        if empty { record.turns.removeAll { $0.id == turn } }
        speaking = nil
        if code != 0, code != 15 {
            lastError = Agents.err(stderr).localizedDescription
            queue.removeAll()
        }
        record.save(root)
        next()
    }
}

extension BookSession {
    private var chapterFiles: String {
        manifest.chapters.filter { !$0.excludeFromExport }.enumerated()
            .map { "\($0.offset + 1). \($0.element.title) — `\($0.element.file)`" }.joined(separator: "\n")
    }

    private func printed(_ id: String) -> String {
        BookStore.stripHTMLComments(Revisions.resolveAll(editorText(of: id), accept: false))
    }

    /// A thread on a reading: its reader, what they wrote, and the chapter as it stands.
    func readerTable(for reading: Reading, chapter: String, fallbackAgent: AgentKind, model: String) -> CriticTableRecord {
        let id = "reading-" + reading.id.uuidString
        if let saved = CriticTableRecord.load(root, id) { return saved }
        let title = anyChapter(chapter)?.title ?? chapter
        let text = printed(chapter)
        let changed = PlotGrid.fingerprint(text) != reading.textHash
        let context = """
        \(ChapterReader.summary(of: reading, chapter: title))

        Le texte du chapitre\(changed ? ", que l'auteur a modifié depuis cette lecture" : "") :
        <<<
        \(text)
        >>>

        Les chapitres du livre :
        \(chapterFiles)
        """
        let engine = AgentKind(rawValue: reading.agent).flatMap { AIStatus.shared.engines.contains($0) ? $0 : nil } ?? fallbackAgent
        let name = L("The AI reader")
        return CriticTableRecord(id: id, kind: .reader, title: L("AI reading of « \(title) »"),
                                 critics: [Critic(id: "lecteur", name: name, horizon: "")],
                                 agent: engine, model: engine.rawValue == reading.agent ? reading.model : model, context: context)
    }

    /// A debate on some chapters: one is given in full, the whole book or several are read by each voice first.
    func debateTable(critics: [Critic], chapters: [ChapterEntry], wholeBook: Bool, stage: CriticTableRecord.Stage,
                     agent: AgentKind, model: String) -> CriticTableRecord {
        let title: String
        let context: String
        if chapters.count == 1, let entry = chapters.first {
            title = entry.title
            context = "Le chapitre « \(entry.title) » du livre « \(self.title) » :\n<<<\n\(printed(entry.id))\n>>>\n\nTous les chapitres du livre :\n\(chapterFiles)"
        } else if wholeBook {
            title = self.title
            context = "Le livre entier, « \(self.title) ». Lisez ses chapitres dans l'ordre avec votre outil Read avant de parler :\n\(chapterFiles)"
        } else {
            title = chapters.count <= 3 ? chapters.map(\.title).joined(separator: " · ") : "\(self.title) · " + L("\(chapters.count) chapters")
            let list = chapters.map { "- \($0.title) — `\($0.file)`" }.joined(separator: "\n")
            context = "Ces chapitres du livre « \(self.title) », à lire dans l'ordre avec votre outil Read avant de parler :\n\(list)\n\nTous les chapitres du livre, pour situer :\n\(chapterFiles)"
        }
        var record = CriticTableRecord(id: "debate-" + UUID().uuidString, kind: .debate, title: title, critics: critics, agent: agent, model: model,
                                       context: context, stage: stage == .finished ? nil : stage)
        if let plan = planForDebate {
            record.context += "\n\n" + plan
            record.againstPlan = true
            // Chapters still to write: the book is unfinished, whatever its written chapters' status.
            if !(plot.planned ?? []).isEmpty, record.stage == nil { record.stage = .incomplete }
        }
        return record
    }

    /// The author's synopsis and plan, as the voices read them; nil when there is none.
    var planForDebate: String? {
        let synopsis = (plot.synopsis ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let chapters = manifest.chapters.enumerated().map { i, ch in
            let s = plot.chapterSynopsis(ch.id)
            return "\(i). « \(ch.title) » (écrit\(ch.status.map { ", " + $0.rawValue } ?? ""))" + (s.isEmpty ? "" : " — " + s)
        }
        let planned = (plot.planned ?? []).enumerated().map { i, p in
            "\(manifest.chapters.count + i). « \(p.title) » (pas encore écrit)" + (p.synopsis.isEmpty ? "" : " — " + p.synopsis)
        }
        let anySynopsis = !synopsis.isEmpty || !(plot.chapterSynopses ?? [:]).isEmpty || !planned.isEmpty
        guard anySynopsis else { return nil }
        var parts = ["Le plan de l'auteur, écrit par l'auteur seul :"]
        if !synopsis.isEmpty { parts.append("Synopsis :\n" + synopsis) }
        parts.append("Chapitre par chapitre :\n" + (chapters + planned).joined(separator: "\n"))
        parts.append("Jugez chaque chapitre écrit à sa place dans ce plan : fait-il ce que le plan lui demande, à ce moment du livre ? Puis jugez le potentiel du plan lui-même : ce qu'il promet, ses forces, ses risques, ce qui lui manque. Ce qui n'est pas encore écrit ne compte jamais contre le livre.")
        return parts.joined(separator: "\n\n")
    }
}

// MARK: Views

/// The table, sliding over the chat: who said what, and the author's turn to speak.
struct CriticTableView: View {
    let table: CriticTable
    var fontSize: Double = 15
    /// On the book's home the column stays readable.
    var columnWidth: CGFloat = .infinity
    let close: () -> Void
    @State private var input = ""
    @State private var height: CGFloat = 26

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button(action: close) { Image(systemName: "chevron.left").frame(width: 24, height: 24).contentShape(Rectangle()) }
                    .buttonStyle(.plain).accessibilityLabel(L("Back", ctx: "Retour"))
                VStack(alignment: .leading, spacing: 1) {
                    Text(table.record.title).font(.ui(13, .medium)).lineLimit(1)
                    if table.record.kind == .debate {
                        Text(([table.record.stage?.label].compactMap { $0 } + table.record.critics.map { c in
                            c.name + (table.record.stars(of: c.id).map { " \(String(repeating: "★", count: $0))" } ?? "")
                        }).joined(separator: " · "))
                        .font(.ui(11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 12).frame(height: 48)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if table.record.turns.isEmpty, !table.running {
                            EmptyNote(L("Ask about a score, a reservation, a passage: this AI reader wrote them."))
                        }
                        ForEach(Array(table.record.turns.enumerated()), id: \.element.id) { i, turn in
                            if table.record.kind == .debate, i == 0 || (table.record.turns[i - 1].opening == true && turn.opening != true) {
                                Text(turn.opening == true ? L("Their views") : L("The debate"))
                                    .font(.ui(11, .medium)).foregroundStyle(.secondary).padding(.top, i == 0 ? 0 : 10)
                            }
                            TurnView(turn: turn, name: table.record.name(of: turn.critic), fontSize: fontSize).id(turn.id)
                        }
                        if let e = table.lastError { Text(e).font(.ui(12)).foregroundStyle(Ink.error).textSelection(.enabled) }
                    }
                    .padding(.horizontal, 18).padding(.vertical, 14)
                    .frame(maxWidth: columnWidth, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
                .defaultScrollAnchor(.bottom)
                .onChange(of: table.record.turns.last?.text) { _, _ in if let id = table.record.turns.last?.id { proxy.scrollTo(id, anchor: .bottom) } }
            }
            VStack(alignment: .leading, spacing: 8) {
                if table.running || table.record.kind == .debate {
                    HStack(spacing: 8) {
                        if let who = table.speaking {
                            ProgressView().controlSize(.small)
                            Text(table.record.name(of: who)).font(.ui(11)).foregroundStyle(.secondary).lineLimit(1)
                            Spacer()
                            Button(L("Stop")) { table.stop() }.buttonStyle(.plain).font(.ui(12)).foregroundStyle(.secondary)
                        } else {
                            Spacer()
                            Button(L("Another round")) { table.anotherRound() }.buttonStyle(.plain).font(.ui(12)).foregroundStyle(Ink.accent)
                        }
                    }
                }
                Composer(text: $input, fontSize: 13, placeholder: table.record.kind == .debate ? L("Speak to the table…") : L("Answer the AI reader…"), onSend: send, height: $height)
                    .frame(height: max(height, 40))
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: Radius.card))
                    .overlay(RoundedRectangle(cornerRadius: Radius.card).strokeBorder(Ink.hairline))
            }
            .padding(14)
            .frame(maxWidth: columnWidth)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .top) { Divider() }
        }
    }

    private func send() {
        table.say(input)
        input = ""
    }
}

private struct TurnView: View {
    let turn: CriticTableRecord.Turn
    let name: String
    let fontSize: Double

    var body: some View {
        if turn.critic == nil {
            Text(turn.text).font(.ui(fontSize - 2)).lineSpacing(2)
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(Ink.accent.opacity(0.10), in: UnevenRoundedRectangle(topLeadingRadius: 12, bottomLeadingRadius: 12, bottomTrailingRadius: 4, topTrailingRadius: 12))
                .textSelection(.enabled)
                .frame(maxWidth: 320, alignment: .trailing)
                .frame(maxWidth: .infinity, alignment: .trailing)
        } else {
            let rated = turn.opening == true ? CriticTableRecord.rating(in: turn.text) : (stars: nil, potential: nil, text: turn.text)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(name).font(.ui(12, .medium)).foregroundStyle(Ink.critique)
                    if let p = rated.potential {
                        if let n = rated.stars { Text(L("Written")).font(.ui(11)).foregroundStyle(.secondary); Stars(count: n) }
                        Text(L("Potential")).font(.ui(11)).foregroundStyle(.secondary); Stars(count: p)
                    } else if let n = rated.stars { Stars(count: n) }
                }
                MarkdownText(text: rated.text.isEmpty ? "…" : rated.text, size: fontSize)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A rating out of five stars.
struct Stars: View {
    let count: Int
    var size: CGFloat = 11

    var body: some View {
        HStack(spacing: 1) {
            ForEach(1...5, id: \.self) { i in
                Image(systemName: i <= count ? "star.fill" : "star").font(.system(size: size)).foregroundStyle(i <= count ? Ink.critique : Color.secondary.opacity(0.5))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("\(count) out of 5 stars"))
    }
}

/// Debates on the book's home: who sits at the table, on what, and the debates already held.
struct DebatePage: View {
    let session: BookSession
    /// Opens the synopsis the debate judges against.
    var openSynopsis: () -> Void = {}
    @State private var chosen: Set<String> = ["gallimard", "lemonde", "menagere"]
    @State private var scope = ChapterScopeMode.book.rawValue
    @State private var statusList = "edited,final"
    @State private var picked: Set<String> = []
    /// Nil: from the chapters' statuses.
    @State private var stage: CriticTableRecord.Stage?
    @State private var mine: [Critic] = []
    @State private var newName = ""
    @State private var newHorizon = ""
    @State private var past: [CriticTableRecord] = []

    private var engine: AgentKind? { AIStatus.shared.engine(preferring: TaskModels.preferredEngine(.chat) ?? .claude) }
    private var model: String {
        guard let engine else { return "" }
        return engine == .claude ? (UserDefaults.standard.string(forKey: "model.chat.claude") ?? "opus") : (UserDefaults.standard.string(forKey: "model.chat.codex") ?? "")
    }

    var body: some View {
        Group {
            if let table = session.debate, session.debateShown {
                CriticTableView(table: table, fontSize: 15, columnWidth: 720) {
                    session.debateShown = false
                    reload()
                }
            } else {
                setup
            }
        }
        .onAppear(perform: reload)
    }

    private var chapters: [ChapterEntry] {
        ChapterScopePicker.chapters(session.manifest, scope: scope, statusList: statusList, picked: picked)
    }

    /// Unfinished while chapters are still planned; a draft as long as one of the chapters is still one.
    private var derivedStage: CriticTableRecord.Stage {
        if !(session.plot.planned ?? []).isEmpty { return .incomplete }
        return chapters.contains { ($0.status ?? .draft) == .draft } ? .draft : .finished
    }

    /// The book as the plan sees it: the written chapters, then the ones still to write, dashed.
    private var planStrip: some View {
        HStack(spacing: 3) {
            ForEach(session.manifest.chapters) { ch in
                RoundedRectangle(cornerRadius: 3).fill(Ink.accent.opacity(0.18)).frame(height: 8).help(ch.title)
            }
            ForEach(session.plot.planned ?? []) { p in
                RoundedRectangle(cornerRadius: 3).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 2])).foregroundStyle(Ink.hairline)
                    .frame(height: 8).help(p.title)
            }
        }
    }

    private func reload() {
        mine = Critic.mine(session.root)
        if picked.isEmpty, let id = session.selectedChapterID { picked = [id] }
        let dir = BookStore(root: session.root).chatDir.appendingPathComponent("tables")
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        past = files.filter { $0.lastPathComponent.hasPrefix("debate-") }
            .sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
            .compactMap { JSONFile.read(CriticTableRecord.self, at: $0) }
    }

    private var setup: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("Debate")).font(.system(size: 28, design: .serif))
                    Text(L("Each gives their view alone, then they argue. You can step in at any time.")).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel(L("On", ctx: "Sur"))
                    ChapterScopePicker(session: session, scope: $scope, statusList: $statusList, picked: $picked, pickHint: L("A scene, a sequence, the opening…"))
                        .frame(maxWidth: 520)
                }
                if session.planForDebate != nil {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionLabel(L("Against", ctx: "Face à"))
                        HStack(spacing: 6) {
                            Button(L("Your synopsis"), action: openSynopsis).buttonStyle(.link)
                            Text(L("and your plan, chapter by chapter")).foregroundStyle(.secondary)
                        }
                        .font(.ui(13))
                        planStrip.frame(maxWidth: 520)
                        Text(L("Each written chapter is judged at its place in the plan, then the plan for its potential. What isn’t written yet never counts against the book."))
                            .font(.ui(12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel(L("The text is"))
                    Segmented(options: CriticTableRecord.Stage.allCases.map { ($0, $0.label) },
                              selection: Binding(get: { stage ?? derivedStage }, set: { stage = $0 }))
                        .frame(maxWidth: 520)
                    Text(L("The voices judge it for what it is now: a draft for its promise, not its polish."))
                        .font(.ui(12)).foregroundStyle(.secondary)
                }
                ForEach(Critic.groups, id: \.self) { group in
                    let list = (Critic.panel + mine.map { var c = $0; c.group = "mine"; return c }).filter { $0.group == group }
                    if !list.isEmpty || group == "mine" {
                        VStack(alignment: .leading, spacing: 7) {
                            Text(Critic.groupLabel(group)).font(.ui(11, .medium)).foregroundStyle(.secondary)
                            ForEach(list) { c in
                                HStack {
                                    Toggle(isOn: Binding(get: { chosen.contains(c.id) }, set: { if $0 { chosen.insert(c.id) } else { chosen.remove(c.id) } })) { Text(c.name).font(.ui(13)) }
                                        .toggleStyle(.checkbox)
                                        .disabled(!chosen.contains(c.id) && chosen.count >= 6)
                                        .help(c.horizon)
                                    if group == "mine" {
                                        Button { removeMine(c) } label: { Image(systemName: "xmark").font(.ui(9)) }.buttonStyle(.plain).foregroundStyle(.tertiary)
                                            .accessibilityLabel(L("Remove"))
                                    }
                                }
                            }
                            if group == "mine" { addCharacter }
                        }
                    }
                }
                Text(L("Imagined voices: what they say commits neither the people nor the houses they evoke."))
                    .font(.ui(12)).foregroundStyle(.secondary)
                if chapters.count > 1 {
                    Text(L("Each voice reads these chapters first: this takes a while and uses a good deal of your subscription."))
                        .font(.ui(12)).foregroundStyle(.secondary)
                }
                Button(L("Start the debate"), action: start)
                    .buttonStyle(.ink)
                    .disabled(chosen.count < 2 || engine == nil || chapters.isEmpty)
                if !past.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L("Earlier debates")).font(.ui(11, .medium)).foregroundStyle(.secondary)
                        ForEach(past) { r in
                            Button { open(r) } label: {
                                VStack(alignment: .leading, spacing: 1) {
                                    HStack(spacing: 8) {
                                        Text(r.title).font(.ui(13))
                                        if let mean = r.meanStars { Stars(count: Int(mean.rounded()), size: 10) }
                                    }
                                    Text(r.critics.map(\.name).joined(separator: " · ")).font(.ui(12)).foregroundStyle(.secondary).lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 5).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.horizontal, 44).padding(.vertical, 30)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private var addCharacter: some View {
        HStack(spacing: 6) {
            TextField(L("Name"), text: $newName).textFieldStyle(.roundedBorder).frame(width: 170)
            TextField(L("Who they are, how they read"), text: $newHorizon).textFieldStyle(.roundedBorder)
            Button(L("Add"), action: addMine).buttonStyle(.inkSecondary)
                .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private func addMine() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        let id = "mine-" + UUID().uuidString
        mine.append(Critic(id: id, name: name, horizon: newHorizon.isEmpty ? name + "." : newHorizon, group: "mine"))
        Critic.saveMine(mine, root: session.root)
        session.pendingCommit = true
        if chosen.count < 6 { chosen.insert(id) }
        newName = ""; newHorizon = ""
    }

    private func removeMine(_ c: Critic) {
        mine.removeAll { $0.id == c.id }
        chosen.remove(c.id)
        Critic.saveMine(mine, root: session.root)
        session.pendingCommit = true
    }

    private func open(_ r: CriticTableRecord) {
        if session.debate?.record.id != r.id {
            session.debate?.stop()
            session.debate = CriticTable(record: r, root: session.root)
        }
        session.debateShown = true
    }

    private func start() {
        guard let engine else { return }
        let all = Critic.panel + mine
        let critics = all.filter { chosen.contains($0.id) }
        let record = session.debateTable(critics: critics, chapters: chapters, wholeBook: scope == ChapterScopeMode.book.rawValue,
                                         stage: stage ?? derivedStage, agent: engine, model: model)
        open(record)
        session.debate?.openDebate()
    }
}
