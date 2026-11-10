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
        (try? Data(contentsOf: minesURL(root))).flatMap { try? JSONDecoder().decode([Critic].self, from: $0) } ?? []
    }

    static func saveMine(_ list: [Critic], root: URL) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try? BookStore(root: root).ensureMussetDir()
        try? enc.encode(list).write(to: minesURL(root), options: .atomic)
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

    static func url(_ root: URL, _ id: String) -> URL { BookStore(root: root).chatDir.appendingPathComponent("tables/\(id).json") }

    static func load(_ root: URL, _ id: String) -> CriticTableRecord? {
        (try? Data(contentsOf: url(root, id))).flatMap { try? JSONDecoder().decode(CriticTableRecord.self, from: $0) }
    }

    func save(_ root: URL) {
        let file = Self.url(root, id)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(self).write(to: file, options: .atomic)
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
            Never give a score and never conclude for the table. Say nothing, and quote nothing, about any sexual scene involving minors. \
            The book's chapters are files in the current directory: read them with your Read tool when you need them. \
            Answer in the book's language. \(WritingPartner.noRewrites)
            """
        }
    }

    /// What a voice hears now: the context the first time, then the turns it missed.
    /// `opening`: its own view first, without hearing anyone.
    func prompt(for critic: Critic, opening: Bool = false) -> String {
        var parts: [String] = []
        if sessions[critic.id] == nil { parts.append(context) }
        if opening {
            parts.append("Donnez votre avis, seul, sans savoir ce que pensent les autres : ce qui tient, ce qui ne tient pas, ce que vous feriez de ce texte à votre place. En 200 mots au plus.")
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
        let name = L("The reader")
        return CriticTableRecord(id: id, kind: .reader, title: L("Reading of « \(title) »"),
                                 critics: [Critic(id: "lecteur", name: name, horizon: "")],
                                 agent: engine, model: engine.rawValue == reading.agent ? reading.model : model, context: context)
    }

    /// A debate on the open chapter, or on the whole book (nil).
    func debateTable(critics: [Critic], chapter: String?, agent: AgentKind, model: String) -> CriticTableRecord {
        let title: String
        let context: String
        if let chapter, let entry = anyChapter(chapter) {
            title = entry.title
            context = "Le chapitre « \(entry.title) » du livre « \(self.title) » :\n<<<\n\(printed(chapter))\n>>>\n\nTous les chapitres du livre :\n\(chapterFiles)"
        } else {
            title = self.title
            context = "Le livre entier, « \(self.title) ». Lisez ses chapitres dans l'ordre avec votre outil Read avant de parler :\n\(chapterFiles)"
        }
        return CriticTableRecord(id: "debate-" + UUID().uuidString, kind: .debate, title: title, critics: critics, agent: agent, model: model, context: context)
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
                        Text(table.record.critics.map(\.name).joined(separator: " · ")).font(.ui(11)).foregroundStyle(.secondary).lineLimit(1)
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
                            Text(L("Ask about a score, a reservation, a passage: this reader wrote them."))
                                .font(.ui(12)).foregroundStyle(.secondary)
                        }
                        ForEach(Array(table.record.turns.enumerated()), id: \.element.id) { i, turn in
                            if table.record.kind == .debate, i == 0 || (table.record.turns[i - 1].opening == true && turn.opening != true) {
                                Text(turn.opening == true ? L("Their views") : L("The debate"))
                                    .font(.ui(11, .medium)).foregroundStyle(.secondary).padding(.top, i == 0 ? 0 : 10)
                            }
                            TurnView(turn: turn, name: table.record.name(of: turn.critic), fontSize: fontSize).id(turn.id)
                        }
                        if let e = table.lastError { Text(e).font(.ui(12)).foregroundStyle(.red).textSelection(.enabled) }
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
                Composer(text: $input, fontSize: 13, placeholder: table.record.kind == .debate ? L("Speak to the table…") : L("Answer the reader…"), onSend: send, height: $height)
                    .frame(height: max(height, 40))
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Ink.hairline))
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
                .background(Color.accentColor.opacity(0.10), in: UnevenRoundedRectangle(topLeadingRadius: 12, bottomLeadingRadius: 12, bottomTrailingRadius: 4, topTrailingRadius: 12))
                .textSelection(.enabled)
                .frame(maxWidth: 320, alignment: .trailing)
                .frame(maxWidth: .infinity, alignment: .trailing)
        } else {
            VStack(alignment: .leading, spacing: 5) {
                Text(name).font(.ui(12, .medium)).foregroundStyle(Ink.critique)
                MarkdownText(text: turn.text.isEmpty ? "…" : turn.text, size: fontSize)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Debates on the book's home: who sits at the table, on what, and the debates already held.
struct DebatePage: View {
    let session: BookSession
    @State private var chosen: Set<String> = ["gallimard", "lemonde", "menagere"]
    @State private var scope = ""
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

    private func reload() {
        mine = Critic.mine(session.root)
        let dir = BookStore(root: session.root).chatDir.appendingPathComponent("tables")
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        past = files.filter { $0.lastPathComponent.hasPrefix("debate-") }
            .sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
            .compactMap { (try? Data(contentsOf: $0)).flatMap { try? JSONDecoder().decode(CriticTableRecord.self, from: $0) } }
    }

    private var setup: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("Debate")).font(.system(size: 28, design: .serif))
                    Text(L("Each gives their view alone, then they argue. You can step in at any time.")).foregroundStyle(.secondary)
                }
                Picker(L("On"), selection: $scope) {
                    Text(L("The whole book", ctx: "Tout le livre")).tag("")
                    ForEach(session.manifest.chapters) { Text($0.title).tag($0.id) }
                }
                .frame(maxWidth: 360)
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
                if scope.isEmpty {
                    Text(L("On the whole book, each voice reads every chapter first: this takes a while and uses a good deal of your subscription."))
                        .font(.ui(12)).foregroundStyle(.secondary)
                }
                Button(L("Start the debate"), action: start)
                    .buttonStyle(.ink)
                    .disabled(chosen.count < 2 || engine == nil)
                if !past.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L("Earlier debates")).font(.ui(11, .medium)).foregroundStyle(.secondary)
                        ForEach(past) { r in
                            Button { open(r) } label: {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(r.title).font(.ui(13))
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
        let record = session.debateTable(critics: critics, chapter: scope.isEmpty ? nil : scope, agent: engine, model: model)
        open(record)
        session.debate?.openDebate()
    }
}
