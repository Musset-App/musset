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
            case .ultra: "Ultra Focus"
            case .proof: L("Proofreading", ctx: "Correction")
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

    init(pane: Pane = Self.initialPane) { _pane = State(initialValue: pane) }

    /// `-musset-settings ai` opens a pane directly (screenshots).
    static var initialPane: Pane {
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
                        .background(pane == p ? Ink.selected : .clear, in: RoundedRectangle(cornerRadius: 7))
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
                    case .editor: EditorPane()
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

/// Rows in a rounded hairline box, a hairline between each.
private struct Card<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        Group {
            if #available(macOS 15, *) {
                VStack(spacing: 0) {
                    Group(subviews: content) { rows in
                        ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                            if i > 0 { CardHairline() }
                            row
                        }
                    }
                }
            } else {
                // macOS 14 has no Group(subviews:): the older way to walk a view's rows.
                _VariadicView.Tree(CardRows()) { content }
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Ink.hairline))
    }
}

private struct CardHairline: View {
    var body: some View { Rectangle().fill(Ink.hairline.opacity(0.6)).frame(height: 1) }
}

private struct CardRows: _VariadicView_MultiViewRoot {
    func body(children: _VariadicView.Children) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(children.enumerated()), id: \.offset) { i, row in
                if i > 0 { CardHairline() }
                row
            }
        }
    }
}

private struct Row<Trailing: View>: View {
    let title: String
    var hint: String? = nil
    @ViewBuilder let trailing: Trailing
    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.ui(13, .medium))
                if let hint { Text(hint).font(.ui(12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }
}

private struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let shown: String
    var body: some View {
        Row(title: title) {
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
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Ink.hairline))
    }
}

extension Field where Leading == EmptyView {
    init(text: String, detail: String? = nil, width: CGFloat = 200) {
        self.init(text: text, detail: detail, width: width) { EmptyView() }
    }
}

private struct Switch: View {
    @Binding var on: Bool
    var body: some View { Toggle("", isOn: $on).toggleStyle(.switch).labelsHidden().controlSize(.small) }
}

private struct GroupTitle: View {
    let text: String
    var body: some View { Text(text.uppercased()).font(.ui(11, .semibold)).tracking(0.6).foregroundStyle(.secondary) }
}

// MARK: General

private struct GeneralPane: View {
    @AppStorage(UILang.key) private var uiLanguage = UILang.system.rawValue
    var body: some View {
        PaneHeader(title: L("General"), subtitle: L("For every book."))
        Card {
            Row(title: L("Interface language"),
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
        Card {
            Row(title: L("Manuscript font")) {
                PopMenu(fonts.filter { NSFont(name: $0, size: 12) != nil }.map { f in
                    PopItem(title: display(f), checked: f == fontName) { fontName = f }
                }) { Field(text: display(fontName), width: 220) }
            }
            SliderRow(title: L("Size"), value: $fontSize, range: 13...28, step: 1, shown: "\(Int(fontSize)) pt")
            SliderRow(title: L("Column width"), value: $columnWidth, range: 480...900, step: 20, shown: "\(Int(columnWidth)) px")
            SliderRow(title: L("Space between paragraphs"), value: $paragraphSpacing, range: 0...1.5, step: 0.1,
                      shown: String(format: "%.1f", paragraphSpacing) + L(" line"))
            SliderRow(title: L("Partner text size"), value: $chatFontSize, range: 11...24, step: 1, shown: "\(Int(chatFontSize)) pt")
        }
        Text(L("The ferry left at six, before the gulls were awake. She stood at the rail with her father’s coat over her arm."))
            .font(.custom(fontName, size: fontSize))
            .lineSpacing(fontSize * 0.78)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 28).padding(.vertical, 24)
            .background(Ink.side, in: RoundedRectangle(cornerRadius: 10))
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
        PaneHeader(title: L("Proofreading", ctx: "Correction"),
                   subtitle: L("As you write, in the book’s language. LanguageTool runs inside Musset: nothing leaves this Mac."))
        Card {
            Row(title: L("Proofread while I write", ctx: "Corriger pendant que j’écris"),
                hint: L("Underlines mistakes, paragraph by paragraph.")) { Switch(on: $autoProofread) }
            Row(title: L("Also proofread with AI"),
                hint: L("Sends the current paragraph to the AI. Off by default.")) { Switch(on: $proofWithAI) }
            Row(title: L("Fix obvious mistakes"),
                hint: L("Missing accents and ligatures, and with the AI certain typos, outside the paragraph being written.")) { Switch(on: $autoCorrect) }
            Row(title: L("The book’s typography"),
                hint: L("Non-breaking spaces, apostrophes, quotes.")) { Switch(on: $autoTypography) }
            Row(title: L("Grammar checker"),
                hint: L("Underlined in blue, never applied automatically.")) {
                PopMenu(LocalProofreader.Checker.allCases.map { c in
                    PopItem(title: c.label, checked: c.rawValue == ruleChecker, subtitle: note(c)) { ruleChecker = c.rawValue }
                }) { Field(text: short(LocalProofreader.Checker(rawValue: ruleChecker) ?? .local), width: 240) }
            }
            if ruleChecker == LocalProofreader.Checker.local.rawValue {
                Row(title: L("Have the AI check grammar alerts"),
                    hint: L("Agreement, confusion and other grammar alerts are underlined only if the AI confirms them, as a rule-based checker can’t tell what a sentence means. Sends those passages to the AI. Off by default.")) { Switch(on: $proofArbiter) }
            }
            if ruleChecker == LocalProofreader.Checker.languageTool.rawValue {
                Row(title: "LanguageTool") {
                    PopMenu([LanguageTool.Mode.local, .publicAPI].map { m in PopItem(title: m.label, checked: m.rawValue == languageTool) { languageTool = m.rawValue } }) {
                        Field(text: (LanguageTool.Mode(rawValue: languageTool) ?? .local).label, width: 240)
                    }
                }
                Row(title: L("Local server")) {
                    TextField("", text: $languageToolLocalURL).textFieldStyle(.roundedBorder).font(.uiMono(12)).frame(width: 240)
                }
            }
            Row(title: L("Repetitions"),
                hint: L("Flags a word repeated within this many words (⌃⌘R).")) {
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
    @State private var custom: AITask?
    @State private var customID = ""
    @State private var pangramKey = ""
    /// Bumped on every choice so the fields read UserDefaults again.
    @State private var revision = 0
    private var ai: AIStatus { .shared }

    private var note: String {
        if !ai.enabled {
            return L("Off. No partner, no annotations, no AI proofreading or plot grid. Everything else works the same.")
        }
        if ai.installed.isEmpty {
            return L("Neither claude nor codex is installed on this Mac: the AI features are hidden.")
        }
        return L("Uses ") + ai.installed.map(\.rawValue).joined(separator: L(" and "))
            + L(", through your own login. Each task has its model.")
    }

    /// The engine a task runs on, and its model as the catalog names it.
    private func current(_ task: AITask) -> (engine: AgentKind, id: String, model: AIModel?) {
        _ = revision
        let engine = ai.engine(preferring: TaskModels.preferredEngine(task)) ?? .claude
        let id = TaskModels.model(task, for: engine)
        let list = catalog.models(engine)
        let model = id.isEmpty ? list.first(where: \.isDefault) : list.first { $0.id == id }
        return (engine, id, model)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            PaneHeader(title: L("AI"), subtitle: note)
            Spacer()
            Switch(on: Binding(get: { ai.enabled }, set: { ai.enabled = $0 }))
        }
        if ai.isOn {
            HStack(spacing: 6) {
                GroupTitle(text: L("Models"))
                Spacer()
                ForEach(AgentKind.allCases) { e in
                    let on = ai.installed.contains(e)
                    HStack(spacing: 6) {
                        Circle().fill(on ? Color(red: 0.18, green: 0.54, blue: 0.34) : Color(nsColor: .tertiaryLabelColor)).frame(width: 6, height: 6)
                        Text(e.rawValue + " " + (on ? L("connected") : L("missing")))
                    }
                    .font(.ui(11, .medium))
                    .foregroundStyle(on ? Color(red: 0.13, green: 0.40, blue: 0.24) : .secondary)
                    .padding(.horizontal, 9).frame(height: 22)
                    .background(on ? Color(red: 0.93, green: 0.96, blue: 0.94) : Ink.selected, in: Capsule())
                }
            }
            .padding(.bottom, 8)
            Card {
                ForEach(AITask.allCases) { task in
                    Row(title: task.label, hint: task.hint) { modelMenu(task) }
                }
            }
            if let task = custom {
                HStack(spacing: 10) {
                    Text(L("Model id for ") + task.label).font(.ui(13, .medium))
                    TextField("claude-opus-5-5", text: $customID).textFieldStyle(.roundedBorder).font(.uiMono(12))
                    Button(L("Use")) {
                        let id = customID.trimmingCharacters(in: .whitespaces)
                        if !id.isEmpty { TaskModels.set(task, engine: current(task).engine, model: id); revision += 1 }
                        custom = nil
                    }
                    .buttonStyle(.ink)
                    Button(L("Cancel")) { custom = nil }.buttonStyle(.inkSecondary)
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                .background(Ink.side, in: RoundedRectangle(cornerRadius: 10))
                .padding(.top, 12)
            }
            HStack(spacing: 10) {
                Text(L("Read from claude and codex, through your own login: no API key in Musset.")
                     + (catalog.updatedAt.map { L(" Updated ") + $0.formatted(.relative(presentation: .named)) + "." } ?? ""))
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

            GroupTitle(text: "Pangram").padding(.top, 28).padding(.bottom, 8)
            Card {
                Row(title: L("API key"),
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
    }

    private func modelMenu(_ task: AITask) -> some View {
        let cur = current(task)
        let sections = ai.engines.map { engine in
            PopSection(title: engine.rawValue.uppercased(), items: catalog.models(engine).map { m in
                let chosen = engine == cur.engine && (m.id == cur.id || (cur.id.isEmpty && m.isDefault))
                return PopItem(title: m.name, checked: chosen, detail: m.isDefault ? m.id + " · " + L("default") : m.id, subtitle: m.note) {
                    TaskModels.set(task, engine: engine, model: m.id); revision += 1
                }
            })
        } + [PopSection(items: [PopItem(title: L("Other model…")) { customID = cur.id; custom = task }])]
        return PopMenu(sections: sections) {
            Field(text: cur.model?.name ?? (cur.id.isEmpty ? L("Default") : cur.id),
                  detail: cur.engine == .claude ? cur.id : nil, width: 240) {
                Text(cur.engine == .claude ? "C" : "X").font(.ui(10, .semibold)).foregroundStyle(.white)
                    .frame(width: 18, height: 18)
                    .background(cur.engine == .claude ? Color(red: 0.77, green: 0.42, blue: 0.29) : Color(white: 0.23), in: RoundedRectangle(cornerRadius: 5))
            }
        }
        .help(L("Model for: ") + task.label)
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
        Card {
            ForEach(tools) { t in
                HStack(spacing: 12) {
                    Circle().fill(t.place != nil ? Color(red: 0.18, green: 0.54, blue: 0.34) : Color(nsColor: .tertiaryLabelColor)).frame(width: 7, height: 7)
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
            return [Tool(name: "typst", place: inApp("typst")), Tool(name: "pandoc", place: inApp("pandoc")),
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
            Text(L("CHEAT SHEET · ") + current.label.uppercased())
                .font(.ui(11, .semibold)).foregroundStyle(.secondary)
            Card {
                ForEach(Array(current.cheatSheet.enumerated()), id: \.offset) { _, row in
                    HStack {
                        Text(row.what)
                        Spacer()
                        Text(row.keys).font(.uiMono(12)).padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Ink.panel, in: RoundedRectangle(cornerRadius: 5))
                            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Ink.hairline))
                    }
                    .padding(.horizontal, 16).padding(.vertical, 7)
                }
            }
        }
        .padding(.bottom, 18)
        Card {
            Row(title: L("Help after a prefix"), hint: current.prefixHelp) {
                Toggle("", isOn: $prefixHelp).toggleStyle(.switch).labelsHidden()
            }
            Row(title: L("Keyboard layout"),
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
                            .background(Ink.panel, in: RoundedRectangle(cornerRadius: 5))
                            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Ink.hairline))
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
            .background(on ? Ink.accent.opacity(0.10) : Ink.side, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(on ? Ink.accent.opacity(0.7) : Ink.hairline))
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
        Card {
            Row(title: L("Level"), hint: currentLevel.hint) {
                Segmented(options: UltraFocusLevel.allCases.map { ($0.rawValue, $0.label) }, selection: $level).frame(width: 250)
            }
            Row(title: L("Enter, leave"), hint: L("Also from ⌘K and the Write menu.")) {
                Text("⌃⌘U").font(.uiMono(12)).padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Ink.panel, in: RoundedRectangle(cornerRadius: 5))
            }
            Row(title: L("What you write goes"), hint: L("Into the open chapter, or apart if you’d rather read it first.")) {
                Picker("", selection: $destination) {
                    ForEach(UltraFocusDestination.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .labelsHidden().fixedSize()
            }
            Row(title: L("Lock"), hint: L("No way out before. ⌥⌘Esc is always there.")) {
                Segmented(options: UltraFocusLock.allCases.map { ($0.rawValue, $0.label) }, selection: $lock).frame(width: 230)
            }
            Row(title: L("Written lines fade upward"), hint: L("Only the line being written stays clear.")) {
                Toggle("", isOn: $fade).toggleStyle(.switch).labelsHidden()
            }
            Row(title: L("Refused"), hint: L("Write forward, correct afterwards.")) {
                Text(currentLevel.refused).font(.uiMono(11)).foregroundStyle(Color(red: 1, green: 0.416, blue: 0.239))
            }
        }
    }
}
