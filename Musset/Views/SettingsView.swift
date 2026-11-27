import SwiftUI
import Carbon

/// Settings: a sidebar of five panes (General, Editor, Proofreading, AI, Advanced), each a card of rows.
struct SettingsView: View {
    enum Pane: String, CaseIterable, Identifiable {
        case general, editor, keys, ultra, proof, ai, advanced
        var id: String { rawValue }
        var label: String {
            switch self {
            case .general: L("General")
            case .editor: L("Editor")
            case .keys: L("Keyboard")
            case .ultra: L("Ultra Focus")
            case .proof: L("Proofreading")
            case .ai: L("AI")
            case .advanced: L("Advanced")
            }
        }
        var icon: String {
            switch self {
            case .general: "gearshape"
            case .editor: "textformat"
            case .keys: "keyboard"
            case .ultra: "forward.end"
            case .proof: "checkmark"
            case .ai: "sparkle"
            case .advanced: "slider.horizontal.3"
            }
        }
    }

    @State private var pane: Pane
    /// The app the editor's switches act on.
    let app: AppState?

    init(app: AppState? = nil, pane: Pane = Self.initialPane) { self.app = app; _pane = State(initialValue: pane) }

    /// Opens Settings on this pane, from elsewhere in the app (call before `openSettings()`).
    static func show(_ pane: Pane) {
        requested = pane
        NotificationCenter.default.post(name: Self.paneRequest, object: pane.rawValue)
    }
    nonisolated(unsafe) private static var requested: Pane?
    private static let paneRequest = Notification.Name("musset.settings.pane")

    /// `-musset-settings ai` opens a pane directly (screenshots).
    static var initialPane: Pane {
        if let p = requested { requested = nil; return p }
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-musset-settings"), i + 1 < args.count else { return .general }
        return Pane(rawValue: args[i + 1]) ?? .general
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Pane.allCases) { p in
                    Button { pane = p } label: {
                        HStack(spacing: 10) {
                            Group {
                                if p == .ultra { UltraFocusGlyph(size: 15) } else { Image(systemName: p.icon).font(.ui(12)) }
                            }
                            .frame(width: 16)
                            Text(p.label).font(.ui(13, pane == p ? .medium : .regular))
                            Spacer()
                        }
                        .padding(.horizontal, 10).frame(height: 30)
                        .background(pane == p ? Ink.selected : .clear, in: RoundedRectangle(cornerRadius: Radius.control))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(.horizontal, 8).padding(.vertical, 12)
            .frame(width: 196)
            .frame(maxHeight: .infinity)
            .background(Ink.side)
            .overlay(alignment: .trailing) { Rectangle().fill(Ink.hairline).frame(width: 1) }

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    switch pane {
                    case .general: GeneralPane()
                    case .editor: EditorPane(app: app)
                    case .keys: KeyboardPane()
                    case .ultra: UltraFocusPane()
                    case .proof: ProofPane()
                    case .ai: AIPane()
                    case .advanced: AdvancedPane()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 36).padding(.top, 24).padding(.bottom, 36)
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
        .frame(width: 860, height: 600)
        // Settings already open: go to the pane asked for.
        .onReceive(NotificationCenter.default.publisher(for: Self.paneRequest)) { n in
            if let p = (n.object as? String).flatMap(Pane.init(rawValue:)) { pane = p; Self.requested = nil }
        }
    }
}

// MARK: Building blocks

private struct PaneHeader: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.ui(20, .semibold))
            Text(subtitle).font(.ui(13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 20)
    }
}

private struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let shown: String
    var body: some View {
        SettingsRow(title: title) {
            Slider(value: $value, in: range, step: step).frame(width: 180).controlSize(.small)
            Text(shown).font(.uiMono(12)).foregroundStyle(.secondary).frame(width: 72, alignment: .trailing)
        }
    }
}

/// The closed state of a drop-down: what is chosen, and a chevron.
private struct Field<Leading: View>: View {
    let text: String
    var detail: String? = nil
    var width: CGFloat = 200
    @ViewBuilder var leading: Leading
    var body: some View {
        HStack(spacing: 8) {
            leading
            Text(text).lineLimit(1)
            Spacer(minLength: 4)
            if let detail { Text(detail).font(.uiMono(11)).foregroundStyle(.secondary).lineLimit(1) }
            Image(systemName: "chevron.down").font(.ui(10, .medium)).foregroundStyle(.secondary)
        }
        .font(.ui(13))
        .padding(.horizontal, 10).frame(width: width, height: 30)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: Radius.control))
        .overlay(RoundedRectangle(cornerRadius: Radius.control).strokeBorder(Ink.hairline))
    }
}

extension Field where Leading == EmptyView {
    init(text: String, detail: String? = nil, width: CGFloat = 200) {
        self.init(text: text, detail: detail, width: width) { EmptyView() }
    }
}

// MARK: General

private struct GeneralPane: View {
    @AppStorage(UILang.key) private var uiLanguage = UILang.system.rawValue
    /// Read from the defaults, so the row follows a choice made from the command bar.
    @AppStorage(Appearance.key) private var appearance = Appearance.system.rawValue
    var body: some View {
        PaneHeader(title: L("General"), subtitle: L("For every book."))
        SettingsCard {
            SettingsRow(title: L("Appearance")) {
                Segmented(options: [(Appearance.system, L("System")), (.light, L("Light", ctx: "Clair")), (.dark, L("Dark"))],
                          selection: Binding(get: { Appearance(rawValue: appearance) ?? .system }, set: { $0.choose() }))
                    .frame(width: 240)
            }
            SettingsRow(title: L("Interface language"),
                hint: L("Each book’s own language is set in the book.")) {
                PopMenu(UILang.allCases.map { l in PopItem(title: l.label, checked: l.rawValue == uiLanguage) { uiLanguage = l.rawValue } }) {
                    Field(text: (UILang(rawValue: uiLanguage) ?? .system).label)
                }
            }
        }
    }
}

// MARK: Editor

private struct EditorPane: View {
    /// The app whose editor these switches act on at once; without it (a preview), they are kept for the next launch.
    let app: AppState?
    @AppStorage("lineNumbers") private var lineNumbers = false
    @AppStorage("minimap") private var minimap = false
    @AppStorage("fontName") private var fontName = Typefaces.manuscript
    @AppStorage("fontSize") private var fontSize = 17.0
    @AppStorage("columnWidth") private var columnWidth = 640.0
    @AppStorage("paragraphSpacing") private var paragraphSpacing = 0.73
    @AppStorage("chatFontSize") private var chatFontSize = 15.0

    private let fonts = ["IBMPlexMono-Regular", "Iosevka-Aile", "Iosevka-Etoile", "Inconsolata-Regular", "Inconsolata", "JetBrainsMonoNL-Regular", "JetBrainsMono-Regular",
                         "iA Writer Quattro S", "EB Garamond", "Iowan Old Style", "Georgia"]
    private func display(_ name: String) -> String { NSFont(name: name, size: 12)?.displayName ?? name }

    var body: some View {
        PaneHeader(title: L("Editor"), subtitle: L("The page you write on."))
        SettingsCard {
            SettingsRow(title: L("Manuscript font")) {
                PopMenu(fonts.filter { NSFont(name: $0, size: 12) != nil }.map { f in
                    PopItem(title: display(f), checked: f == fontName) { fontName = f }
                }) { Field(text: display(fontName), width: 220) }
            }
            SliderRow(title: L("Size"), value: $fontSize, range: 13...28, step: 1, shown: "\(Int(fontSize)) pt")
            SliderRow(title: L("Column width"), value: $columnWidth, range: 480...900, step: 20, shown: "\(Int(columnWidth)) px")
            SliderRow(title: L("Space between paragraphs"), value: $paragraphSpacing, range: 0...1.5, step: 0.1,
                      shown: L("\(paragraphSpacing.formatted(.number.precision(.fractionLength(1)).locale(UILang.locale))) line"))
            SliderRow(title: L("Chat text size"), value: $chatFontSize, range: 11...24, step: 1, shown: "\(Int(chatFontSize)) pt")
        }
        // A programmer's editor has these in its menus; a novelist sets them once, if ever. Both stay in the command bar.
        SettingsCard {
            SettingsRow(title: L("Line Numbers")) {
                SettingsSwitch(on: Binding(get: { app?.lineNumbers ?? lineNumbers }, set: { if let app { app.lineNumbers = $0 } else { lineNumbers = $0 } }))
            }
            SettingsRow(title: L("Minimap"), hint: L("The whole chapter: click or drag to move")) {
                SettingsSwitch(on: Binding(get: { app?.minimap ?? minimap }, set: { if let app { app.minimap = $0 } else { minimap = $0 } }))
            }
        }
        .padding(.top, 16)
        Text(L("The ferry left at six, before the gulls were awake. She stood at the rail with her father’s coat over her arm."))
            .font(.custom(fontName, size: fontSize))
            .lineSpacing(fontSize * 0.78)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 28).padding(.vertical, 24)
            .background(Ink.side, in: RoundedRectangle(cornerRadius: Radius.card))
            .padding(.top, 20)
    }
}

// MARK: Proofreading

private struct ProofPane: View {
    @AppStorage("autoProofread") private var autoProofread = true
    @AppStorage("proofWithAI") private var proofWithAI = false
    @AppStorage("autoCorrect") private var autoCorrect = true
    @AppStorage("autoTypography") private var autoTypography = true
    @AppStorage("ruleChecker") private var ruleChecker = LocalProofreader.Checker.local.rawValue
    @AppStorage("proofArbiter") private var proofArbiter = false
    @AppStorage("languageTool") private var languageTool = LanguageTool.Mode.auto.rawValue
    @AppStorage("languageToolLocalURL") private var languageToolLocalURL = "http://localhost:8081"
    @AppStorage("repetitionWindow") private var repetitionWindow = 50

    private func short(_ c: LocalProofreader.Checker) -> String {
        c == .local ? L("LanguageTool, on this Mac") : c.label
    }

    private func note(_ c: LocalProofreader.Checker) -> String {
        switch c {
        case .local: L("Inside Musset: nothing leaves this Mac.")
        case .languageTool: L("Your own LanguageTool server, or languagetool.org, which receives the text.")
        case .off: L("No grammar underlines.")
        }
    }

    var body: some View {
        PaneHeader(title: L("Proofreading"),
                   subtitle: L("As you write, in the book’s language. LanguageTool runs inside Musset: nothing leaves this Mac."))
        SettingsCard {
            SettingsRow(title: L("Proofread while I write", ctx: "Corriger pendant que j’écris"),
                hint: L("Underlines mistakes, paragraph by paragraph.")) { SettingsSwitch(on: $autoProofread) }
            SettingsRow(title: L("Also proofread with AI"),
                hint: L("Sends the current paragraph to the AI. Off by default.")) { SettingsSwitch(on: $proofWithAI) }
            SettingsRow(title: L("Fix obvious mistakes"),
                hint: L("Missing accents and ligatures, and with the AI certain typos, outside the paragraph being written.")) { SettingsSwitch(on: $autoCorrect) }
            SettingsRow(title: L("The book’s typography"),
                hint: L("Non-breaking spaces, apostrophes, quotes.")) { SettingsSwitch(on: $autoTypography) }
            SettingsRow(title: L("Grammar checker"),
                hint: L("Underlined in blue, never applied automatically.")) {
                PopMenu(LocalProofreader.Checker.allCases.map { c in
                    PopItem(title: c.label, checked: c.rawValue == ruleChecker, subtitle: note(c)) { ruleChecker = c.rawValue }
                }) { Field(text: short(LocalProofreader.Checker(rawValue: ruleChecker) ?? .local), width: 240) }
            }
            if ruleChecker == LocalProofreader.Checker.local.rawValue {
                SettingsRow(title: L("Have the AI check grammar alerts"),
                    hint: L("Agreement, confusion and other grammar alerts are underlined only if the AI confirms them, as a rule-based checker can’t tell what a sentence means. Sends those passages to the AI. Off by default.")) { SettingsSwitch(on: $proofArbiter) }
            }
            if ruleChecker == LocalProofreader.Checker.languageTool.rawValue {
                SettingsRow(title: "LanguageTool") {
                    PopMenu([LanguageTool.Mode.local, .publicAPI].map { m in PopItem(title: m.label, checked: m.rawValue == languageTool) { languageTool = m.rawValue } }) {
                        Field(text: (LanguageTool.Mode(rawValue: languageTool) ?? .local).label, width: 240)
                    }
                }
                SettingsRow(title: L("Local server")) {
                    TextField("", text: $languageToolLocalURL).textFieldStyle(.roundedBorder).font(.uiMono(12)).frame(width: 240)
                }
            }
            SettingsRow(title: L("Repetitions"),
                hint: L("Flags a word repeated within this many words (\(AppCommand.glyphs("view.repetitions"))).")) {
                Slider(value: Binding(get: { Double(repetitionWindow) }, set: { repetitionWindow = Int($0) }), in: 10...300, step: 10)
                    .frame(width: 160).controlSize(.small)
                Text("\(repetitionWindow) " + L("words")).font(.uiMono(12)).foregroundStyle(.secondary).frame(width: 72, alignment: .trailing)
            }
        }
    }
}

// MARK: AI

private struct AIPane: View {
    @State private var catalog = ModelCatalog.shared
    @AppStorage("keepBible") private var keepBible = true
    /// A model id typed by hand, for this task and provider.
    @State private var custom: (task: AITask, provider: Provider)?
    @State private var customID = ""
    /// The task whose model is being chosen among all of a server's.
    @State private var browsing: Browse?
    /// The server being added or edited.
    @State private var editing: EndpointConfig?
    @State private var pangramKey = ""
    /// Bumped on every choice so the fields read UserDefaults again.
    @State private var revision = 0
    private var ai: AIStatus { .shared }

    struct Browse: Identifiable { let task: AITask; let server: EndpointConfig; var id: String { task.rawValue } }

    /// Where a task runs: a CLI, or one of your own servers.
    enum Provider: Hashable {
        case cli(AgentKind)
        case server(String)
        var engine: AgentKind { if case .cli(let k) = self { k } else { .endpoint } }
    }

    private var servers: [EndpointConfig] { _ = revision; return EndpointClient.providers() }

    private var providers: [Provider] {
        AgentKind.clis.filter { ai.installed.contains($0) }.map { .cli($0) } + servers.map { .server($0.id) }
    }

    private func label(_ p: Provider) -> String {
        switch p {
        case .cli(let k): k.label
        case .server(let id): servers.first { $0.id == id }?.label ?? id
        }
    }

    private var note: String {
        if !ai.enabled {
            return L("Off. No AI reader, no annotations, no AI proofreading or plot grid. Everything else works the same.")
        }
        return L("Connect the providers you use, then choose a provider and a model for each task.")
    }

    /// The provider a task runs on, and its model's id there (empty: the provider's default).
    private func current(_ task: AITask) -> (provider: Provider, id: String) {
        _ = revision
        let engine = ai.engine(preferring: TaskModels.preferredEngine(task)) ?? .claude
        let stored = TaskModels.model(task, for: engine)
        guard engine == .endpoint else { return (.cli(engine), stored) }
        let (config, _) = EndpointClient.resolve(stored)
        let own = EndpointClient.split(stored)
        return (.server(config.id), own.provider == config.id || own.provider == nil ? own.model : "")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            PaneHeader(title: L("AI"), subtitle: note)
            Spacer()
            SettingsSwitch(on: Binding(get: { ai.enabled }, set: { ai.enabled = $0 }))
        }
        if ai.enabled {
            SectionLabel(L("Providers"), tracking: 0.6).padding(.bottom, 8)
            SettingsCard {
                ForEach(AgentKind.clis) { k in cliRow(k) }
                ForEach(servers, id: \.id) { s in serverRow(s) }
            }
            HStack(spacing: 10) {
                Menu {
                    ForEach(EndpointPreset.allCases.filter { p in !servers.contains { $0.preset == p } }) { p in
                        Button(p.label) { editing = EndpointConfig(preset: p, baseURL: p.defaultURL) }
                    }
                } label: { Label(L("Add a provider"), systemImage: "plus") }
                .menuStyle(.button).fixedSize()
                .disabled(servers.count == EndpointPreset.allCases.count)
                Text(L("OpenRouter, Ollama, LM Studio or any server that speaks OpenAI's chat completions. Your key, your bill: Musset takes nothing."))
                    .font(.ui(12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 12)
        }
        if ai.isOn {
            SectionLabel(L("Models"), tracking: 0.6).padding(.top, 28).padding(.bottom, 8)
            SettingsCard {
                ForEach(AITask.allCases) { task in
                    SettingsRow(title: task.label, hint: task.hint) {
                        HStack(spacing: 8) {
                            // The Bible's reading runs on its own, after pauses: it can be turned off.
                            if task == .bible { Toggle("", isOn: $keepBible).toggleStyle(.switch).controlSize(.mini).labelsHidden().accessibilityLabel(L("Keep the Bible up to date")) }
                            providerMenu(task)
                            modelMenu(task)
                        }
                    }
                }
            }
            if let (task, provider) = custom {
                HStack(spacing: 10) {
                    Text(L("Model id for \(task.label)")).font(.ui(13, .medium))
                    TextField(provider.engine == .endpoint ? "mistralai/mistral-large" : "claude-opus-5-5", text: $customID).textFieldStyle(.roundedBorder).font(.uiMono(12))
                    Button(L("Use")) {
                        let id = customID.trimmingCharacters(in: .whitespaces)
                        if !id.isEmpty { choose(task, provider, model: id) }
                        custom = nil
                    }
                    .buttonStyle(.ink)
                    Button(L("Cancel")) { custom = nil }.buttonStyle(.inkSecondary)
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                .background(Ink.side, in: RoundedRectangle(cornerRadius: Radius.card))
                .padding(.top, 12)
            }
            HStack(spacing: 10) {
                Text(L("The lists come from claude and codex, through your own login, and from your servers.")
                     + (catalog.updatedAt.map { " " + L("Updated \($0.formatted(.relative(presentation: .named))).") } ?? ""))
                    .font(.ui(12)).foregroundStyle(.secondary)
                Spacer()
                Button {
                    Task { await catalog.refresh() }
                } label: {
                    HStack(spacing: 6) {
                        if catalog.refreshing { ProgressView().controlSize(.mini) } else { Image(systemName: "arrow.clockwise") }
                        Text(L("Refresh"))
                    }
                }
                .buttonStyle(.inkSecondary)
                .disabled(catalog.refreshing)
            }
            .padding(.top, 12)
        }
        if ai.isOn {
            SectionLabel("Pangram", tracking: 0.6).padding(.top, 28).padding(.bottom, 8)
            SettingsCard {
                SettingsRow(title: L("API key"),
                    hint: L("If empty, Musset reads PANGRAM_API_KEY from the book’s .env once.")) {
                    SecureField("", text: $pangramKey).textFieldStyle(.roundedBorder).font(.uiMono(12)).frame(width: 160)
                    Button(L("Save")) { Secrets.set("pangram", pangramKey) }.buttonStyle(.inkSecondary)
                }
            }
        }
        Color.clear.frame(height: 0)
            // Read when the pane opens, not at launch: a Keychain prompt must never hold up the app.
            .onAppear { if pangramKey.isEmpty { pangramKey = Secrets.get("pangram") ?? "" } }
            .task {
                if ai.installed.isEmpty { await ai.detect() }
                await catalog.refresh()
            }
            .sheet(item: $browsing) { b in
                ModelBrowser(config: b.server, key: EndpointClient.key(b.server),
                             current: current(b.task).provider == .server(b.server.id) ? EndpointClient.resolve(EndpointClient.route(b.server.id, current(b.task).id)).model : "") { m, _ in
                    choose(b.task, .server(b.server.id), model: m.id)
                }
            }
            .sheet(item: Binding(get: { editing.map { Editing(config: $0) } }, set: { editing = $0?.config })) { e in
                ProviderSheet(config: e.config, isNew: !servers.contains { $0.id == e.config.id }) {
                    revision += 1
                    Task { await catalog.refresh(); revision += 1 }
                }
            }
    }

    struct Editing: Identifiable { let config: EndpointConfig; var id: String { config.id } }

    // MARK: Providers

    private func cliRow(_ k: AgentKind) -> some View {
        let on = ai.installed.contains(k)
        return HStack(spacing: 12) {
            badge(.cli(k))
            VStack(alignment: .leading, spacing: 2) {
                Text(k.label).font(.ui(13, .medium))
                Text(k == .claude ? L("Through the claude command, with your Claude subscription.") : L("Through the codex command, with your ChatGPT subscription."))
                    .font(.ui(12)).foregroundStyle(.secondary)
            }
            Spacer()
            state(on ? L("connected") : L("missing"), on: on)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private func serverRow(_ s: EndpointConfig) -> some View {
        HStack(spacing: 12) {
            badge(.server(s.id))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(s.label).font(.ui(13, .medium))
                    if !s.defaultModel.isEmpty {
                        Text(s.defaultModel).font(.uiMono(11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                    }
                }
                Text(s.destination).font(.ui(12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            // Connected once it has listed its models; a local server that isn't running doesn't.
            let answers = catalog.models(.endpoint).contains { EndpointClient.split($0.id).provider == s.id }
            state(answers ? L("connected") : L("no answer"), on: answers)
            Button(L("Edit…")) { editing = s }.buttonStyle(.inkSecondary)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private func state(_ text: String, on: Bool) -> some View {
        HStack(spacing: 6) {
            Circle().fill(on ? Ink.positive : Color(nsColor: .tertiaryLabelColor)).frame(width: 6, height: 6)
            Text(text)
        }
        .font(.ui(11, .medium))
        .foregroundStyle(on ? Ink.positive : .secondary)
        .padding(.horizontal, 9).frame(height: 22)
        .background(on ? Ink.positive.opacity(0.12) : Ink.selected, in: Capsule())
    }

    private func badge(_ p: Provider) -> some View {
        Text(Self.letter(label(p))).font(.ui(10, .semibold)).foregroundStyle(.white)
            .frame(width: 18, height: 18)
            .background(Self.color(p), in: RoundedRectangle(cornerRadius: Radius.row))
    }

    private static func letter(_ name: String) -> String {
        name == "Codex" ? "X" : String(name.prefix(1)).uppercased()
    }

    private static func color(_ p: Provider) -> Color {
        switch p {
        case .cli(.claude): Color(red: 0.77, green: 0.42, blue: 0.29)
        case .cli: Color(white: 0.23)
        case .server("openrouter"): Color(nsColor: .systemIndigo)
        case .server("ollama"): Color(white: 0.4)
        case .server("lmstudio"): Color(nsColor: .systemPurple)
        case .server: Color(nsColor: .systemTeal)
        }
    }

    // MARK: Models

    private func choose(_ task: AITask, _ p: Provider, model: String) {
        switch p {
        case .cli(let k): TaskModels.set(task, engine: k, model: model)
        case .server(let id): TaskModels.set(task, engine: .endpoint, model: EndpointClient.route(id, model))
        }
        revision += 1
    }

    private func providerMenu(_ task: AITask) -> some View {
        let cur = current(task)
        return PopMenu(providers.map { p in
            PopItem(title: label(p), checked: p == cur.provider) {
                guard p != cur.provider else { return }
                // Back on a provider: the model it had for this task, else its default.
                switch p {
                case .cli(let k): choose(task, p, model: TaskModels.model(task, for: k))
                case .server: choose(task, p, model: "")
                }
            }
        }) {
            Field(text: label(cur.provider), width: 168) { badge(cur.provider) }
        }
        .help(L("Provider for: \(task.label)"))
    }

    private func modelMenu(_ task: AITask) -> some View {
        let cur = current(task)
        var sections = [PopSection(items: items(task, cur))]
        var more = [PopItem(title: L("Other model…")) { customID = cur.id; custom = (task, cur.provider) }]
        if case .server(let id) = cur.provider, let server = servers.first(where: { $0.id == id }) {
            more.insert(PopItem(title: L("All \(server.label) models…")) { browsing = Browse(task: task, server: server) }, at: 0)
        }
        sections.append(PopSection(items: more))
        return PopMenu(sections: sections) {
            Field(text: name(cur), detail: cur.provider == .cli(.claude) ? cur.id : nil, width: 210)
        }
        .help(L("Model for: \(task.label)"))
    }

    /// What the model field shows: the catalog's name, the server's default, or the id.
    private func name(_ cur: (provider: Provider, id: String)) -> String {
        switch cur.provider {
        case .cli(let k):
            let list = catalog.models(k)
            let m = cur.id.isEmpty ? list.first(where: \.isDefault) : list.first { $0.id == cur.id }
            return m?.name ?? (cur.id.isEmpty ? L("Default") : cur.id)
        case .server(let id):
            let model = cur.id.isEmpty ? (servers.first { $0.id == id }?.defaultModel ?? "") : cur.id
            return catalog.models(.endpoint).first { $0.id == EndpointClient.route(id, model) }?.name ?? (model.isEmpty ? L("Default") : model)
        }
    }

    /// A server can list hundreds of models (OpenRouter): the menu shows its default, the one chosen, and the browser.
    private func items(_ task: AITask, _ cur: (provider: Provider, id: String)) -> [PopItem] {
        switch cur.provider {
        case .cli(let k):
            return catalog.models(k).map { m in
                PopItem(title: m.name, checked: m.id == cur.id || (cur.id.isEmpty && m.isDefault),
                        detail: m.isDefault ? m.id + " · " + L("default") : m.id, subtitle: m.note) { choose(task, cur.provider, model: m.id) }
            }
        case .server(let id):
            let server = servers.first { $0.id == id }
            var list = catalog.models(.endpoint).filter { EndpointClient.split($0.id).provider == id }
            if list.count > 25 { list = list.filter { $0.isDefault || EndpointClient.split($0.id).model == cur.id } }
            let def = PopItem(title: L("The server's model"), checked: cur.id.isEmpty, detail: server?.defaultModel) {
                choose(task, cur.provider, model: "")
            }
            return [def] + list.filter { !$0.isDefault }.map { m in
                let model = EndpointClient.split(m.id).model
                return PopItem(title: m.name, checked: model == cur.id, detail: model, subtitle: m.note) { choose(task, cur.provider, model: model) }
            }
        }
    }
}

/// One of your own servers: its address, its key in the Keychain, its default model, and whether background work may use it.
/// Nothing is kept until Save; Test tries what is in the form.
private struct ProviderSheet: View {
    let isNew: Bool
    let changed: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var config: EndpointConfig
    @State private var key = ""
    @State private var models: [EndpointModel] = []
    @State private var testing = false
    @State private var result: (ok: Bool, text: String)?
    @State private var browsing = false

    init(config: EndpointConfig, isNew: Bool, changed: @escaping () -> Void) {
        _config = State(initialValue: config)
        self.isNew = isNew
        self.changed = changed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(config.preset == .custom ? L("Other server") : config.preset.label).font(.ui(15, .semibold))
            SettingsCard {
                SettingsRow(title: L("Address"), hint: config.destination.isEmpty ? L("It usually ends in /v1.") : config.destination) {
                    TextField("https://…/v1", text: $config.baseURL).textFieldStyle(.roundedBorder).font(.uiMono(12)).frame(width: 260)
                }
                if config.preset.needsKey {
                    SettingsRow(title: L("API key"), hint: L("Kept in the Keychain of this Mac.")) {
                        SecureField("", text: $key).textFieldStyle(.roundedBorder).font(.uiMono(12)).frame(width: 260)
                    }
                }
                SettingsRow(title: L("Model"), hint: modelHint) {
                    HStack(spacing: 6) {
                        TextField(config.preset == .ollama ? "llama3.1" : "mistralai/mistral-large", text: $config.defaultModel)
                            .textFieldStyle(.roundedBorder).font(.uiMono(12)).frame(width: 180)
                        Button(L("Browse…")) { browsing = true }
                            .buttonStyle(.inkSecondary).disabled(!config.isConfigured)
                            .help(L("Every model the server lists, with its price and context"))
                    }
                }
                if !config.isLocal {
                    SettingsRow(title: L("Also for background work"),
                                hint: L("Proofreading as you write and keeping the Bible up to date. On a paid server, every pause costs tokens.")) {
                        Toggle("", isOn: $config.background).toggleStyle(.switch).controlSize(.mini).labelsHidden()
                    }
                }
            }
            if testing || result != nil {
                HStack(spacing: 8) {
                    if testing { ProgressView().controlSize(.small) }
                    if let result {
                        Text(result.text).font(.ui(12)).foregroundStyle(result.ok ? Ink.positive : Ink.error)
                            .lineLimit(3).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            HStack(spacing: 10) {
                if !isNew {
                    Button(L("Remove")) { remove() }.buttonStyle(.inkSecondary)
                }
                Spacer()
                Button(L("Cancel")) { dismiss() }.buttonStyle(.inkSecondary)
                Button(L("Test")) { test() }.buttonStyle(.inkSecondary).disabled(testing || !config.isConfigured)
                Button(L("Save")) { save() }.buttonStyle(.ink).keyboardShortcut(.defaultAction).disabled(!config.isConfigured)
            }
        }
        .padding(20)
        .frame(width: 640)
        // Read when the sheet opens, not at launch: a Keychain prompt must never hold up the app.
        .onAppear { if !isNew { key = config.storedKey() ?? "" } }
        .sheet(isPresented: $browsing) {
            ModelBrowser(config: config, key: key, current: config.defaultModel) { m, list in
                config.defaultModel = m.id; models = list
            }
        }
    }

    private var modelHint: String {
        guard let m = models.first(where: { $0.id == config.defaultModel }) else {
            return L("Used by every task that has no model of its own on this server.")
        }
        var parts: [String] = []
        if let c = m.context { parts.append(L("Reads \(c.formatted(.number.notation(.compactName))) tokens at once.")) }
        if !m.usable { parts.append(L("Can't use tools, which the reader will need. Choose another model.")) }
        return parts.joined(separator: " ")
    }

    private func test() {
        testing = true
        result = nil
        let config = config, key = key
        Task {
            do {
                let list = try await EndpointClient.models(config, key: key)
                models = list
                guard !config.defaultModel.isEmpty else {
                    result = (true, L("Connected: \(list.count) models. Choose one."))
                    testing = false
                    return
                }
                let start = Date()
                _ = try await EndpointClient.complete([EndpointMessage(role: "user", content: "Reply with the single word: OK")],
                                                      model: config.defaultModel, config: config, key: key)
                let seconds = Date().timeIntervalSince(start).formatted(.number.precision(.fractionLength(1)))
                result = (true, L("Connected. \(config.defaultModel) answered in \(seconds) s."))
            } catch {
                result = (false, error.localizedDescription)
            }
            testing = false
        }
    }

    private func save() {
        config.save()
        Secrets.set(config.keychainAccount, config.preset.needsKey ? key.trimmingCharacters(in: .whitespacesAndNewlines) : "")
        AIStatus.shared.refreshEndpoint()
        changed()
        dismiss()
    }

    private func remove() {
        EndpointConfig.forget(config.id)
        AIStatus.shared.refreshEndpoint()
        changed()
        dismiss()
    }
}

// MARK: Advanced

private struct AdvancedPane: View {
    struct Tool: Identifiable { let name: String; let place: String?; var id: String { name } }
    @State private var tools: [Tool] = []
    @State private var checking = false

    var body: some View {
        PaneHeader(title: L("Advanced"),
                   subtitle: L("The tools inside Musset, and those it finds on this Mac."))
        SettingsCard {
            ForEach(tools) { t in
                HStack(spacing: 12) {
                    Circle().fill(t.place != nil ? Ink.positive : Color(nsColor: .tertiaryLabelColor)).frame(width: 7, height: 7)
                    Text(t.name).font(.uiMono(12, .medium)).frame(width: 90, alignment: .leading)
                    Text(t.place ?? L("not found")).font(.uiMono(12)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Spacer()
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
            }
            HStack {
                Button(L("Check again")) { Task { await check() } }.buttonStyle(.inkSecondary).disabled(checking)
                if checking { ProgressView().controlSize(.small) }
                Spacer()
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
        }
        .task { await check() }
    }

    private func check() async {
        checking = true
        defer { checking = false }
        let found = await Task.detached { () -> [Tool] in
            let inApp = { (tool: String) -> String? in
                guard let p = Shell.bundledOrPath(tool) else { return nil }
                return p.hasPrefix(Bundle.main.bundlePath) ? L("inside Musset") : p
            }
            return [Tool(name: "typst", place: "Typst \(Typesetting.typstVersion) · " + L("inside Musset")), Tool(name: "pandoc", place: inApp("pandoc")),
                    Tool(name: "git", place: "libgit2 \(GitService.libraryVersion) · " + L("inside Musset")),
                    Tool(name: "claude", place: Shell.which("claude")), Tool(name: "codex", place: Shell.which("codex")),
                    Tool(name: "xelatex", place: Shell.which("xelatex"))]
        }.value
        tools = found
        await AIStatus.shared.detect()
    }
}

/// Keyboard: one mode at a time; ⌘ stays Musset's in all of them.
private struct KeyboardPane: View {
    @AppStorage(KeyboardMode.defaultsKey) private var mode = KeyboardMode.mac.rawValue
    @AppStorage("keyPrefixHelp") private var prefixHelp = true

    private var current: KeyboardMode { KeyboardMode(rawValue: mode) ?? .mac }

    var body: some View {
        PaneHeader(title: L("Keyboard"),
                   subtitle: L("How your hands talk to Musset. One mode at a time; ⌘ stays Musset’s in all of them."))
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible())], spacing: 10) {
            ForEach(KeyboardMode.allCases) { m in tile(m) }
        }
        .padding(.bottom, 18)
        VStack(alignment: .leading, spacing: 8) {
            Text(L("CHEAT SHEET · \(current.label.uppercased())"))
                .font(.ui(11, .semibold)).foregroundStyle(.secondary)
            SettingsCard {
                ForEach(Array(current.cheatSheet.enumerated()), id: \.offset) { _, row in
                    HStack {
                        Text(row.what)
                        Spacer()
                        Text(row.keys).font(.uiMono(12)).padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Ink.panel, in: RoundedRectangle(cornerRadius: Radius.row))
                            .overlay(RoundedRectangle(cornerRadius: Radius.row).strokeBorder(Ink.hairline))
                    }
                    .padding(.horizontal, 16).padding(.vertical, 7)
                }
            }
        }
        .padding(.bottom, 18)
        SettingsCard {
            SettingsRow(title: L("Help after a prefix"), hint: current.prefixHelp) {
                Toggle("", isOn: $prefixHelp).toggleStyle(.switch).labelsHidden()
            }
            SettingsRow(title: L("Keyboard layout"),
                hint: current == .vi ? L("On AZERTY, the keys follow the letters; { } $ need ⌥ there.")
                                     : L("Keys follow the letters, wherever they are on your keyboard.")) {
                Text(Self.layoutName).font(.ui(12)).foregroundStyle(.secondary)
            }
        }
    }

    private func tile(_ m: KeyboardMode) -> some View {
        let on = m == current
        return Button { mode = m.rawValue } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(m.label).font(.ui(14, .semibold))
                    Spacer()
                    Image(systemName: on ? "largecircle.fill.circle" : "circle").foregroundStyle(on ? Ink.accent : .secondary)
                }
                Text(m.hint).font(.ui(12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 5) {
                    ForEach(m.signature, id: \.self) { k in
                        Text(k).font(.uiMono(11)).padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Ink.panel, in: RoundedRectangle(cornerRadius: Radius.row))
                            .overlay(RoundedRectangle(cornerRadius: Radius.row).strokeBorder(Ink.hairline))
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
            .background(on ? Ink.accent.opacity(0.10) : Ink.side, in: RoundedRectangle(cornerRadius: Radius.card))
            .overlay(RoundedRectangle(cornerRadius: Radius.card).strokeBorder(on ? Ink.accent.opacity(0.7) : Ink.hairline))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The input source in use, as macOS names it (« U.S. », « French »).
    static var layoutName: String {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(source, kTISPropertyLocalizedName) else { return "" }
        return Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
    }
}

/// Ultra Focus: where the text goes, the lock, the fade.
private struct UltraFocusPane: View {
    @AppStorage(UltraFocusDestination.defaultsKey) private var destination = UltraFocusDestination.end.rawValue
    @AppStorage(UltraFocusLock.defaultsKey) private var lock = UltraFocusLock.none.rawValue
    @AppStorage("ultraFade") private var fade = true
    @AppStorage(UltraFocusLevel.defaultsKey) private var level = UltraFocusLevel.normal.rawValue
    private var currentLevel: UltraFocusLevel { UltraFocusLevel(rawValue: level) ?? .normal }

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 11).fill(Color(red: 0.067, green: 0.067, blue: 0.063))
                UltraFocusGlyph(size: 30)
            }
            .frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 3) {
                Text("Ultra Focus").font(.ui(20, .semibold))
                Text(L("Only the text. No going back. One way out."))
                    .font(.ui(13)).foregroundStyle(.secondary)
            }
        }
        .padding(.bottom, 20)
        SettingsCard {
            SettingsRow(title: L("Level"), hint: currentLevel.hint) {
                Segmented(options: UltraFocusLevel.allCases.map { ($0.rawValue, $0.label) }, selection: $level).frame(width: 250)
            }
            SettingsRow(title: L("Enter, leave"), hint: L("Also from ⌘K and the Write menu.")) {
                Text("⌃⌘U").font(.uiMono(12)).padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Ink.panel, in: RoundedRectangle(cornerRadius: Radius.row))
            }
            SettingsRow(title: L("What you write goes"), hint: L("Into the open chapter, or apart if you’d rather read it first.")) {
                Picker("", selection: $destination) {
                    ForEach(UltraFocusDestination.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .labelsHidden().fixedSize()
            }
            SettingsRow(title: L("Lock"), hint: L("No way out before. ⌥⌘Esc is always there.")) {
                Segmented(options: UltraFocusLock.allCases.map { ($0.rawValue, $0.label) }, selection: $lock).frame(width: 230)
            }
            SettingsRow(title: L("Written lines fade upward"), hint: L("Only the line being written stays clear.")) {
                Toggle("", isOn: $fade).toggleStyle(.switch).labelsHidden()
            }
            SettingsRow(title: L("Refused"), hint: L("Write forward, correct afterwards.")) {
                Text(currentLevel.refused).font(.uiMono(11)).foregroundStyle(Color(red: 1, green: 0.416, blue: 0.239))
            }
        }
    }
}
