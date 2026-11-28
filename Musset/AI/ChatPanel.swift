import SwiftUI

struct ChatMessage: Identifiable, Codable, Hashable {
    enum Role: String, Codable { case user, assistant, status, error }
    var id = UUID()
    var role: Role
    var agent: AgentKind?
    var text: String
    /// Sent while another answer was still coming; waits its turn.
    var queued: Bool? = nil
    /// Quick action this message asked for (its answer is pinned to the text as notes).
    var action: ChatAction? = nil
    /// Notes the answer placed in the chapter, so they can be removed together.
    var notesRun: String? = nil
    var notesAdded: Int? = nil
    /// Open notes the answer resolved because the text had fixed them.
    var notesResolved: Int? = nil
    var score: RubricScore? = nil
    var previousTotal: Double? = nil
    /// A reading this message shows, and the threshold it is measured against.
    var reading: Reading? = nil
    var threshold: Double? = nil
    /// Passages of that reading that already carried a note.
    var notesSkipped: Int? = nil
    /// The chapter a reading is of, to discuss it later.
    var chapter: String? = nil
    /// The model that answered: a CLI's model (« opus »), or your own server's, routed (« openrouter|mistralai/… »).
    var model: String? = nil
}

/// One conversation per book and agent, persisted in `.musset/chat/` (git-ignored).
@MainActor
@Observable
final class ChatModel {
    var agent: AgentKind = TaskModels.preferredEngine(.chat) ?? .claude
    var messages: [ChatMessage] = []
    var running = false
    var status = ""
    /// Scores come from here, never from the conversation.
    let reader = ChapterReader()
    /// The reading the conversation has not heard of yet.
    @ObservationIgnored private var unsharedReading: String?
    var input = ""
    var includeChapter = true
    /// The thread or debate open over the chat.
    var table: CriticTable?
    /// Shown or not, it keeps running; closing only slides it away.
    var tableShown = false
    @ObservationIgnored private var sessions: [AgentKind: String] = [:]
    @ObservationIgnored private var process: (any AgentRun)?
    @ObservationIgnored private var bookRoot: URL?
    /// Messages waiting for the current answer to finish.
    @ObservationIgnored private var pending: [Pending] = []
    /// What each agent's session last saw of the chapter (id + text hash), so the text is only re-sent when it changed.
    @ObservationIgnored private var sentChapter: [AgentKind: String] = [:]
    @ObservationIgnored private var sentReference: [AgentKind: String] = [:]

    private struct Pending {
        let messageID: UUID
        let question: String
        let selection: String
        let model: String
        let agent: AgentKind
        weak var book: BookSession?
        var action: ChatAction? = nil
    }

    /// The answer being written: where its notes go when it is finished.
    @ObservationIgnored private var current: (replyID: UUID, action: ChatAction?, agent: AgentKind, book: BookSession?)?

    private var transcriptURL: URL? { bookRoot.map { BookStore(root: $0).chatDir.appendingPathComponent("chat.json") } }

    struct Saved: Codable { var messages: [ChatMessage]; var sessions: [String: String] }

    func attach(_ root: URL) {
        guard root != bookRoot else { return }
        persist()
        bookRoot = root
        table?.stop()
        table = nil
        tableShown = false
        messages = []
        sessions = [:]
        sentChapter = [:]
        sentReference = [:]
        pending = []
        if let url = transcriptURL, let s = JSONFile.read(Saved.self, at: url) {
            messages = s.messages
            for (k, v) in s.sessions { if let a = AgentKind(rawValue: k) { sessions[a] = v } }
        }
    }

    func persist() {
        guard let url = transcriptURL else { return }
        let s = Saved(messages: messages.suffix(300), sessions: Dictionary(uniqueKeysWithValues: sessions.map { ($0.key.rawValue, $0.value) }))
        try? JSONFile.write(s, to: url, [])
    }

    func newConversation() {
        stop()
        messages.removeAll()
        sessions.removeAll()
        sentChapter.removeAll()
        sentReference.removeAll()
        persist()
    }

    /// Stops the answer being written and drops the queued messages.
    func stop() {
        let queued = Set(pending.map(\.messageID))
        pending.removeAll()
        messages.removeAll { queued.contains($0.id) }
        process?.terminate()
        process = nil
        running = false
    }

    func cancelQueued(_ id: UUID) {
        pending.removeAll { $0.messageID == id }
        messages.removeAll { $0.id == id }
    }

    /// Sends now, or queues behind the answer being written.
    func send(session book: BookSession, selection: String, model: String) {
        let question = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        input = ""
        let message = ChatMessage(role: .user, agent: agent, text: question, queued: running ? true : nil)
        messages.append(message)
        pending.append(Pending(messageID: message.id, question: question, selection: selection, model: model, agent: agent, book: book))
        if !running { startNext() }
    }

    /// A quick action: the agent annotates the chapter (or the selection) and keeps its chat answer short.
    func runAction(_ action: ChatAction, session book: BookSession, selection: String, model: String) {
        if action == .critique { return readChapter(book, model: model) }
        let label = "⚡ " + (selection.isEmpty ? action.localizedLabel : L("\(action.localizedLabel) — selection"))
        let message = ChatMessage(role: .user, agent: agent, text: label, queued: running ? true : nil, action: action)
        messages.append(message)
        pending.append(Pending(messageID: message.id, question: "", selection: selection, model: model, agent: agent, book: book, action: action))
        if !running { startNext() }
    }

    /// Opens a table over the chat. One runs at a time.
    func open(_ record: CriticTableRecord, root: URL) {
        if table?.record.id != record.id {
            table?.stop()
            table = CriticTable(record: record, root: root)
        }
        tableShown = true
    }

    /// The critique has a reader of its own, outside this conversation. The result lands here so it can be discussed.
    private func readChapter(_ book: BookSession, model: String) {
        let engine = agent
        guard !reader.running else {
            messages.append(ChatMessage(role: .error, text: L("An AI reading is already under way.")))
            return
        }
        messages.append(ChatMessage(role: .user, agent: engine, text: "⚡ " + ChatAction.critique.localizedLabel, action: .critique))
        let title = book.selectedChapter?.title ?? ""
        let chapter = book.selectedChapter?.id ?? ""
        reader.read(book, engine: engine, model: model) { [weak self] reading, run, pins in
            guard let self else { return }
            if let reading {
                var m = ChatMessage(role: .assistant, agent: engine,
                                    text: reading.advice?.overview.nilIfEmpty ?? L("A separate AI reader, outside this conversation, read « \(title) »."),
                                    action: .critique, notesRun: run, notesAdded: pins.placed)
                m.model = TaskModels.answering(engine, model)
                m.notesSkipped = pins.skipped
                m.notesResolved = pins.resolved
                m.reading = reading
                m.threshold = Bareme.forBook(book.root)?.threshold
                m.previousTotal = Reading.load(book.root, chapter).dropLast().last { $0.agent == reading.agent }?.total
                m.chapter = chapter
                self.messages.append(m)
                self.unsharedReading = ChapterReader.summary(of: reading, chapter: title)
            } else if let e = self.reader.lastError {
                self.messages.append(ChatMessage(role: .error, text: e))
            }
            self.persist()
        }
    }

    private func startNext() {
        guard !running, !pending.isEmpty else { return }
        let next = pending.removeFirst()
        if let i = messages.firstIndex(where: { $0.id == next.messageID }) { messages[i].queued = nil }
        guard let book = next.book else { startNext(); return }
        let question = next.action?.prompt(book: book, selection: next.selection) ?? next.question
        run(question, book: book, selection: next.selection, model: next.model, agent: next.agent, action: next.action)
    }

    private func run(_ question: String, book: BookSession, selection: String, model: String, agent: AgentKind, action: ChatAction? = nil) {
        var prompt = ""
        if let shared = unsharedReading {
            prompt += shared + "\n"
            unsharedReading = nil
        }
        if let ch = book.selectedChapter, includeChapter {
            // The chapter goes in the message, so the agent answers without first spending a turn reading the file.
            let seen = ch.id + ":" + PangramClient.sha(book.text)
            if sessions[agent] == nil || sentChapter[agent] != seen {
                prompt += "Book: \(book.title). Current chapter: \"\(ch.title)\" (file `\(ch.file)`, version \"\(ch.activeVersion)\"). Its current text:\n<<<\n\(ParagraphCodec.encode(book.text))\n>>>\n"
                sentChapter[agent] = seen
            } else {
                prompt += "(The chapter \"\(ch.title)\" has not changed since your last answer.)\n"
            }
        }
        if let previous = book.reference, includeChapter {
            // Side by side: a rewrite in progress, the earlier version open beside it.
            let seen = previous + ":" + PangramClient.sha(book.referenceText)
            if sessions[agent] == nil || sentReference[agent] != seen {
                prompt += "\n" + WritingPartner.rewriting(previous: previous, text: book.referenceText) + "\n"
                sentReference[agent] = seen
            } else {
                prompt += "(Still a rewrite: the earlier version \"\(previous)\" is unchanged beside it.)\n"
            }
        }
        if !selection.isEmpty {
            prompt += "\nThe author has selected this passage:\n<<<\n\(selection)\n>>>\n"
        }
        prompt += "\n\(question)"
        // Repeated in every message: a resumed conversation keeps the system prompt it started with.
        prompt += "\n\n(\(WritingPartner.noRewrites))"

        let system = """
        You are talking with the author of this book inside their writing app: a demanding literary critic and writing partner. \
        Discuss, critique, question; you cannot edit files. \(WritingPartner.noRewrites) \
        When your answer is about specific passages, you may also add margin notes in a fenced block starting with ```notes \
        holding a JSON array of {"quote": "<passage copied exactly from the chapter, 3 to 25 words>", "kind": \(Note.Kind.promptChoices), "note": "<the note>"}; \
        the author can then pin them to the text. \
        Follow the project's AGENTS.md if present. Answer in the language the author writes to you in.
        """
        let agentsMD = (try? String(contentsOf: book.root.appendingPathComponent("AGENTS.md"), encoding: .utf8)).map { "\n\nAGENTS.md:\n" + $0 } ?? ""

        running = true
        status = L("\(agent.label) is reading…")
        let replyID = UUID()
        messages.append(ChatMessage(id: replyID, role: .assistant, agent: agent, text: "", action: action,
                                    model: TaskModels.answering(agent, model)))
        current = (replyID, action, agent, book)
        do {
            process = try Agents.send(agent, prompt: prompt, session: sessions[agent], cwd: book.root, model: model,
                                      systemPrompt: system + agentsMD,
                                      onEvent: { [weak self] ev in Task { @MainActor in self?.handle(ev, replyID: replyID, agent: agent) } },
                                      onDone: { [weak self] code, stderr in Task { @MainActor in self?.finish(code, stderr, replyID: replyID) } })
        } catch {
            finish(1, error.localizedDescription, replyID: replyID)
        }
    }

    private func handle(_ ev: AgentEvent, replyID: UUID, agent: AgentKind) {
        guard let i = messages.firstIndex(where: { $0.id == replyID }) else { return }
        switch ev {
        case .session(let id): sessions[agent] = id
        case .textDelta(let t): messages[i].text += t
        case .fullText(let t):
            // Codex sends whole messages; Claude's final result repeats the streamed text.
            if agent == .codex { messages[i].text += (messages[i].text.isEmpty ? "" : "\n\n") + t }
            else if messages[i].text.isEmpty { messages[i].text = t }
        case .status(let s): status = s
        case .error(let e): messages.append(ChatMessage(role: .error, agent: agent, text: Agents.err(e).localizedDescription))
        }
    }

    private func finish(_ code: Int32, _ stderr: String, replyID: UUID) {
        running = false
        status = ""
        process = nil
        if code == 0 { pinActionResults(replyID: replyID) }
        current = nil
        if let i = messages.firstIndex(where: { $0.id == replyID }), messages[i].text.isEmpty {
            messages.remove(at: i)
        }
        if code != 0, code != 15, messages.last?.role != .error {
            messages.append(ChatMessage(role: .error, text: Agents.err(stderr).localizedDescription))
        }
        startNext()
        persist()
    }

    /// A quick action's answer: its notes go into the chapter.
    private func pinActionResults(replyID: UUID) {
        guard let c = current, c.replyID == replyID, let action = c.action, let book = c.book,
              let i = messages.firstIndex(where: { $0.id == replyID }) else { return }
        let reply = messages[i].text
        let items = Self.noteBlocks(in: reply)
        if !items.isEmpty {
            let run = UUID().uuidString
            let author = Note.Author(c.agent)
            book.notes.lastAutoResolved = 0
            messages[i].notesAdded = Annotator.add(items, to: book, author: author, defaultKind: action.defaultKind, scope: nil, run: run)
            messages[i].notesResolved = book.notes.lastAutoResolved
            messages[i].notesRun = run
        }
    }

    func removeNotes(of messageID: UUID, book: BookSession) {
        guard let i = messages.firstIndex(where: { $0.id == messageID }), let run = messages[i].notesRun else { return }
        book.notes.deleteRun(run)
        messages[i].notesAdded = 0
        persist()
    }

    /// ```notes blocks: margin notes the agent proposes, as JSON.
    static func noteBlocks(in text: String) -> [Annotator.Item] {
        let re = try! NSRegularExpression(pattern: "```(?:notes|json)[^\\n]*\\n(.*?)```", options: [.dotMatchesLineSeparators])
        return re.matches(in: text, range: NSRange(text.startIndex..., in: text)).flatMap { m -> [Annotator.Item] in
            Range(m.range(at: 1), in: text).map { Annotator.parse(String(text[$0])) } ?? []
        }
    }
}

struct ChatPanel: View {
    @Bindable var chat: ChatModel
    let session: BookSession
    let bridge: EditorBridge
    @AppStorage("model.chat.claude") private var claudeModel = "opus"
    @AppStorage("model.chat.codex") private var codexModel = ""
    @AppStorage("model.chat.endpoint") private var endpointModel = ""
    /// Your own servers' models picked in the chat lately, so switching back and forth takes one click.
    @AppStorage("chat.recentModels") private var recentModels = ""
    @State private var browsing: EndpointConfig?
    @State private var composerHeight: CGFloat = 26
    @State private var showTics = false
    @State private var showCheckers = false
    @State private var bookCheckers = BookCheckers()
    @AppStorage("chatFontSize") private var chatFontSize = 15.0
    private static let messagePage = 40
    @State private var shownMessages = Self.messagePage
    /// False once the author has scrolled up: a small arrow then leads back to the end.
    @State private var atBottom = true

    private var currentModel: String {
        switch chat.agent {
        case .claude: claudeModel
        case .codex: codexModel
        case .endpoint: endpointModel
        }
    }

    var body: some View {
        ZStack {
            conversation.opacity(chat.tableShown ? 0 : 1).allowsHitTesting(!chat.tableShown)
            if chat.tableShown, let table = chat.table {
                CriticTableView(table: table, fontSize: chatFontSize) { withAnimation(.easeOut(duration: 0.2)) { chat.tableShown = false } }
                    .background(Color(nsColor: .textBackgroundColor))
                    .transition(.move(edge: .trailing))
            }
        }
        .clipped()
        .animation(.easeOut(duration: 0.2), value: chat.tableShown)
    }

    private var conversation: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    // Not lazy: a LazyVStack's prefetch here re-triggered itself forever and froze the app. Only the latest messages are built.
                    VStack(alignment: .leading, spacing: 14) {
                        if chat.messages.isEmpty {
                            EmptyNote(L("Ask \(chat.agent.label) about this chapter. Select a passage first to discuss just that.")).padding(.top, 20)
                        }
                        if chat.messages.count > shownMessages {
                            Button(L("Earlier messages")) { shownMessages += Self.messagePage }
                                .buttonStyle(.link).font(.ui(11)).frame(maxWidth: .infinity)
                        }
                        ForEach(chat.messages.suffix(shownMessages)) { m in
                            MessageView(message: m, fontSize: chatFontSize, onAddNotes: { items in
                                let author = Note.Author(m.agent ?? .claude)
                                return Annotator.add(items, to: session, author: author, defaultKind: .note, scope: nil, run: UUID().uuidString)
                            }, onRemoveNotes: { chat.removeNotes(of: m.id, book: session) }, onShowQuote: { quote in
                                if let range = ReadingCheck.locate(quote, in: bridge.textView?.string ?? session.text) { bridge.scroll(to: range) }
                            }, onDiscuss: { reading in
                                let chapter = m.chapter ?? session.selectedChapterID ?? ""
                                chat.open(session.readerTable(for: reading, chapter: chapter, fallbackAgent: chat.agent, model: currentModel), root: session.root)
                            }, turnsOnReading: { reading in
                                CriticTableRecord.load(session.root, "reading-" + reading.id.uuidString)?.turns.count ?? 0
                            })
                            .id(m.id)
                            if m.queued == true {
                                HStack(spacing: 6) {
                                    Image(systemName: "clock").font(.ui(10))
                                    Text(L("Queued")).font(.ui(11))
                                    Button(L("Cancel")) { chat.cancelQueued(m.id) }.buttonStyle(.link).font(.ui(11))
                                }
                                .foregroundStyle(.secondary)
                            }
                        }
                        if chat.running || chat.reader.running {
                            HStack(spacing: 6) { ProgressView().controlSize(.small); Text(chat.running ? chat.status : chat.reader.status ?? "").font(.ui(11)).foregroundStyle(.secondary).lineLimit(1) }
                                .id("running")
                        }
                    }
                    .padding(.horizontal, 18).padding(.vertical, 12)
                }
                // Open at the latest message, and follow the answer as it streams in.
                .defaultScrollAnchor(.bottom)
                .modifier(TracksBottom(atBottom: $atBottom))
                .overlay(alignment: .bottomTrailing) {
                    if !atBottom && !chat.messages.isEmpty {
                        Button {
                            withAnimation(.easeOut(duration: 0.25)) {
                                if chat.running || chat.reader.running { proxy.scrollTo("running", anchor: .bottom) }
                                else if let id = chat.messages.last?.id { proxy.scrollTo(id, anchor: .bottom) }
                            }
                        } label: {
                            Image(systemName: "arrow.down").font(.ui(12, .semibold))
                                .frame(width: 30, height: 30)
                                .background(Ink.panel, in: Circle())
                                .overlay(Circle().strokeBorder(Ink.hairline))
                                .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .padding(.trailing, 14).padding(.bottom, 10)
                        .help(L("Go to the end of the conversation"))
                        .accessibilityLabel(L("Go to the end of the conversation"))
                        .transition(.opacity.combined(with: .scale(scale: 0.8)))
                    }
                }
                .animation(.easeOut(duration: 0.15), value: atBottom)
                .onAppear {
                    DispatchQueue.main.async { if let id = chat.messages.last?.id { proxy.scrollTo(id, anchor: .bottom) } }
                }
                .onChange(of: chat.messages.count) { _, _ in
                    if let id = chat.messages.last?.id { proxy.scrollTo(id, anchor: .bottom) }
                }
                .onChange(of: chat.messages.last?.text) { _, _ in
                    if let id = chat.messages.last?.id { proxy.scrollTo(id, anchor: .bottom) }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                actions
                VStack(alignment: .leading, spacing: 8) {
                    Composer(text: $chat.input, fontSize: 13,
                             placeholder: chat.running ? L("Queue another message…") : L("Ask \(chat.agent.label)… (⇧↩ new line)"),
                             onSend: send, height: $composerHeight)
                        .frame(height: max(composerHeight, 40))
                    HStack(spacing: 8) {
                        modelPicker
                        if !bridge.selectedText.isEmpty {
                            Text(L("Selection: \(TextCounts(bridge.selectedText).label)"))
                                .foregroundStyle(.tertiary).lineLimit(1)
                        }
                        Spacer()
                        Menu {
                            Button(L("New conversation")) { chat.newConversation() }
                            Toggle(L("Tell the agent which chapter is open"), isOn: $chat.includeChapter)
                            Divider()
                            Button(L("Larger Text")) { chatFontSize = min(24, chatFontSize + 1) }.keyboardShortcut("+", modifiers: [.command, .option])
                            Button(L("Smaller Text")) { chatFontSize = max(11, chatFontSize - 1) }.keyboardShortcut("-", modifiers: [.command, .option])
                        } label: { Image(systemName: "ellipsis") }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().tint(.secondary)
                        if chat.running {
                            Button { chat.stop() } label: { Image(systemName: "stop.fill").font(.ui(10)).frame(width: 28, height: 28).background(Ink.panel, in: RoundedRectangle(cornerRadius: Radius.control)) }
                                .buttonStyle(.plain).help(L("Stop (also drops queued messages)"))
                        }
                        Button(action: send) {
                            Image(systemName: "arrow.up").font(.ui(12, .semibold))
                                .foregroundStyle(Color(nsColor: .textBackgroundColor))
                                .frame(width: 28, height: 28)
                                .background(Color.primary, in: RoundedRectangle(cornerRadius: Radius.control))
                        }
                        .buttonStyle(.plain)
                        .disabled(chat.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .help(chat.running ? L("Queue this message") : L("Send (↩)"))
                    }
                    .font(.ui(12)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: Radius.card))
                .overlay(RoundedRectangle(cornerRadius: Radius.card).strokeBorder(Ink.hairline))
            }
            .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 14)
            .overlay(alignment: .top) { Divider() }
        }
        // Only one of the two CLIs on this Mac: talk to that one.
        .onAppear { if let e = AIStatus.shared.conversingEngine(preferring: chat.agent) { chat.agent = e } }
    }

    /// The engine and model for the next message, picked here as in Settings › AI: comparing two models on the same passage
    /// is a click, and each answer says which model gave it.
    private var modelPicker: some View {
        let catalog = ModelCatalog.shared
        return Menu {
            ForEach(AIStatus.shared.conversing) { a in
                if a == .endpoint {
                    ForEach(EndpointClient.providers(), id: \.id) { server in
                        Section(server.label) {
                            ForEach(serverChoices(server), id: \.self) { model in
                                pickButton(.endpoint, EndpointClient.route(server.id, model),
                                           title: catalog.models(.endpoint).first { $0.id == EndpointClient.route(server.id, model) }?.name ?? model)
                            }
                            Button(L("All \(server.label) models…")) { browsing = server }
                        }
                    }
                } else {
                    Section(a.label) {
                        let list = catalog.models(a)
                        if list.isEmpty { pickButton(a, "", title: L("Default")) }
                        ForEach(list) { m in pickButton(a, m.id, title: m.name) }
                    }
                }
            }
        } label: {
            Text(TaskModels.answerLabel(chat.agent, TaskModels.answering(chat.agent, currentModel))).foregroundColor(.secondary)
                + Text(" ") + Text(Image(systemName: "chevron.down")).font(.ui(9)).foregroundColor(.secondary)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().tint(.secondary)
        .help(L("Engine and model for the next message"))
        .sheet(item: Binding(get: { browsing.map { Browsing(config: $0) } }, set: { browsing = $0?.config })) { b in
            ModelBrowser(config: b.config, key: EndpointClient.key(b.config),
                         current: EndpointClient.split(TaskModels.answering(.endpoint, endpointModel) ?? "").model) { m, _ in
                pick(.endpoint, EndpointClient.route(b.config.id, m.id))
            }
        }
    }

    struct Browsing: Identifiable { let config: EndpointConfig; var id: String { config.id } }

    private func pickButton(_ engine: AgentKind, _ model: String, title: String) -> some View {
        let chosen = chat.agent == engine && TaskModels.answering(engine, currentModel) == TaskModels.answering(engine, model)
        return Button { pick(engine, model) } label: { Label(title, systemImage: chosen ? "checkmark" : "") }
    }

    /// A server can list hundreds of models: its default, the one chosen, and the ones picked here lately.
    private func serverChoices(_ server: EndpointConfig) -> [String] {
        let listed = ModelCatalog.shared.models(.endpoint).map { EndpointClient.split($0.id) }.filter { $0.provider == server.id }.map(\.model)
        let chosen = EndpointClient.split(TaskModels.answering(.endpoint, endpointModel) ?? "")
        let recent = recentModels.split(separator: "\n").map { EndpointClient.split(String($0)) }.filter { $0.provider == server.id }.map(\.model)
        var out: [String] = []
        for m in [server.defaultModel] + (chosen.provider == server.id ? [chosen.model] : []) + recent + (listed.count <= 12 ? listed : [])
        where !m.isEmpty && !out.contains(m) { out.append(m) }
        return out
    }

    private func pick(_ engine: AgentKind, _ model: String) {
        chat.agent = engine
        TaskModels.set(.chat, engine: engine, model: model)
        if engine == .endpoint {
            let kept = recentModels.split(separator: "\n").map(String.init).filter { $0 != model }
            recentModels = ([model] + kept).prefix(8).joined(separator: "\n")
        }
    }

    /// One-click requests: the answer annotates the chapter (or the selection) instead of filling the chat.
    private var actions: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let line = session.checks.lastError ?? session.checks.status {
                HStack(spacing: 6) {
                    if session.checks.running != nil { ProgressView().controlSize(.small) }
                    Text(line).font(.ui(11)).foregroundStyle(session.checks.lastError != nil ? Ink.error : .secondary).lineLimit(2)
                    Spacer(minLength: 4)
                    if session.checks.running != nil { Button(L("Stop")) { session.checks.stop() }.buttonStyle(.link).font(.ui(11)) }
                }
                .padding(.bottom, 6)
            }
            FlowLayout(spacing: 6) {
                ForEach(ChatAction.allCases) { action in
                    Button { runAction(action) } label: {
                        Text(action.localizedLabel).font(.ui(12, action == .critique ? .semibold : .regular))
                            .foregroundStyle(action == .critique ? Color(nsColor: .textBackgroundColor) : .primary)
                            .padding(.horizontal, 10).frame(height: 24)
                            .background(action == .critique ? Ink.critique : .clear, in: Capsule())
                            .overlay(Capsule().strokeBorder(action == .critique ? .clear : Ink.hairline))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help((bridge.selectedText.isEmpty ? action.help : L("\(action.help) — on the selection")))
                }
                ForEach(bookCheckers.checkers) { checker in
                    Button { session.checks.run(checker, session: session, engine: chat.agent, model: currentModel) } label: {
                        Label(checker.name, systemImage: "checkmark.seal").font(.ui(12)).labelStyle(.titleAndIcon)
                            .padding(.horizontal, 10).frame(height: 24)
                            .overlay(Capsule().strokeBorder(Ink.critique.opacity(0.6)))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(session.checks.running != nil || session.selectedChapter == nil)
                    .help(L("Checks the open chapter against these rules: notes in the margin, the text untouched"))
                }
                Menu {
                    Button(L("Tics grid…")) { showTics = true }
                    Button(L("Checkers…")) { showCheckers = true }
                } label: { Image(systemName: "slider.horizontal.3") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().tint(.secondary)
                .help(L("The book's tics grid and checkers"))
            }
        }
        .sheet(isPresented: $showCheckers, onDismiss: { bookCheckers = BookCheckers.load(session.root) }) { CheckersSheet(session: session) }
        .onAppear { bookCheckers = BookCheckers.load(session.root) }
        .onChange(of: session.checkersChanged) { _, _ in bookCheckers = BookCheckers.load(session.root) }
        .sheet(isPresented: $showTics) { TicsSheet(session: session) }
    }

    private func runAction(_ action: ChatAction) {
        chat.runAction(action, session: session, selection: bridge.selectedText, model: currentModel)
    }

    private func send() {
        chat.send(session: session, selection: bridge.selectedText, model: currentModel)
    }
}

private struct MessageView: View {
    let message: ChatMessage
    var fontSize: Double = 15
    /// Pins the message's ```notes to the chapter; returns how many found their passage.
    let onAddNotes: ([Annotator.Item]) -> Int
    let onRemoveNotes: () -> Void
    let onShowQuote: (String) -> Void
    var onDiscuss: (Reading) -> Void = { _ in }
    var turnsOnReading: (Reading) -> Int = { _ in 0 }
    @State private var notesAdded: Int?

    private func notesLine(placed n: Int, hadNotes: Bool) -> String {
        var parts: [String]
        if n == 0 {
            parts = [hadNotes ? L("Notes removed") : L("No new notes")]
        } else {
            parts = [L("\(n) notes in the margin")]
        }
        if let fixed = message.notesResolved, fixed > 0 { parts.append(L("\(fixed) resolved")) }
        if let skipped = message.notesSkipped, skipped > 0 { parts.append("\(skipped) " + L("passages already annotated")) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch message.role {
            case .user:
                Text(message.text)
                    .font(.ui(fontSize - 2))
                    .lineSpacing(2)
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .background(Ink.accent.opacity(0.10), in: UnevenRoundedRectangle(topLeadingRadius: 12, bottomLeadingRadius: 12, bottomTrailingRadius: 4, topTrailingRadius: 12))
                    .textSelection(.enabled)
                    .frame(maxWidth: 320, alignment: .trailing)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            case .assistant:
                HStack(spacing: 8) {
                    let a = message.agent ?? .claude
                    let color = Note.Author(a).color
                    let label = TaskModels.answerLabel(a, message.model)
                    Text(String(label.prefix(1)))
                        .font(.ui(10, .semibold))
                        .foregroundStyle(color)
                        .frame(width: 16, height: 16)
                        .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
                    Text(label).font(.ui(12)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                        .help(message.model.map { EndpointClient.split($0).model } ?? "")
                }
                // The JSON blocks are for the app: notes go to the margin, scores to the card.
                MarkdownText(text: message.text.isEmpty ? "…" : stripMachineBlocks(message.text), size: fontSize)
                if let score = message.score { ScoreCard(score: score, previous: message.previousTotal) }
                if let reading = message.reading {
                    ReadingCard(reading: reading, threshold: message.threshold, previous: message.previousTotal, show: onShowQuote)
                    let turns = turnsOnReading(reading)
                    Button { onDiscuss(reading) } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "bubble.left.and.bubble.right").font(.ui(11))
                            Text(turns == 0 ? L("Discuss with this AI reader") : L("Resume the discussion (\(turns))")).font(.ui(12, .medium))
                        }
                        .foregroundStyle(Ink.critique)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                let notes = ChatModel.noteBlocks(in: message.text).filter { $0.resolves == nil }
                if message.action != nil, let n = message.notesAdded {
                    HStack(spacing: 10) {
                        HStack(spacing: 3) {
                            ForEach(Array(Set(notes.compactMap { Note.Kind.fromTag($0.note) ?? $0.kind.flatMap(Note.Kind.init(rawValue:)) })).prefix(4), id: \.self) {
                                Circle().fill($0.color).frame(width: 6, height: 6)
                            }
                        }
                        Text(notesLine(placed: n, hadNotes: !notes.isEmpty))
                        Spacer()
                        if n > 0 { Button(L("Remove")) { onRemoveNotes() }.buttonStyle(.link).foregroundStyle(.secondary) }
                    }
                    .font(.ui(12)).foregroundStyle(.secondary)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(Ink.panel.opacity(0.6), in: RoundedRectangle(cornerRadius: Radius.control))
                } else if message.action == nil, !notes.isEmpty {
                    HStack {
                        if let n = notesAdded {
                            Text(n == notes.count ? L("\(n) notes added") : L("\(n) of \(notes.count) notes added (others already noted or not found)"))
                                .font(.ui(11)).foregroundStyle(.secondary)
                        } else {
                            Button(L("Add \(notes.count) notes to the chapter")) { notesAdded = onAddNotes(notes) }
                        }
                    }
                    .controlSize(.small)
                }
            case .status:
                Text(message.text).font(.ui(11)).foregroundStyle(.secondary)
            case .error:
                Text(message.text).font(.ui(12)).foregroundStyle(Ink.error).textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

@MainActor
@Observable
final class PangramModel {
    var running = false
    var result: PangramResult?
    var error: String?

    func run(session: BookSession, bridge: EditorBridge) async {
        guard let key = Secrets.pangramKey(bookRoot: session.root) else {
            error = L("No Pangram key. Add it in Settings (\(AppCommand.glyphs("app.settings"))).")
            return
        }
        let text = bridge.selectedText.isEmpty ? session.text : bridge.selectedText
        running = true; error = nil; result = nil
        bridge.flagged = []
        defer { running = false }
        do {
            let r = try await PangramClient.check(text, key: key, cacheDir: session.store.pangramDir, label: session.selectedChapterID ?? "text")
            result = r
            bridge.flagged = PangramClient.ranges(of: r.flaggedWindows, in: session.text)
            bridge.refreshHighlights()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func clear(_ bridge: EditorBridge) {
        result = nil; error = nil
        // Nothing flagged: nothing to repaint (this runs at every change of chapter).
        guard !bridge.flagged.isEmpty else { return }
        bridge.flagged = []
        bridge.refreshHighlights()
    }
}


/// Whether the conversation is scrolled to its end. macOS 14 can't tell: the jump arrow then never shows.
private struct TracksBottom: ViewModifier {
    @Binding var atBottom: Bool

    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content.onScrollGeometryChange(for: Bool.self) { g in
                g.contentOffset.y + g.containerSize.height >= g.contentSize.height - 40
            } action: { _, bottom in
                atBottom = bottom
            }
        } else {
            content
        }
    }
}
