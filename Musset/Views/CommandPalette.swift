import SwiftUI

/// ⌘K: one bar for everything — go to a chapter or a scene, run a critique, switch a mode, export.
/// It replaces the toolbar's buttons; every command also keeps its menu entry and shortcut.
struct CommandPalette: View {
    let app: AppState
    let session: BookSession
    let bridge: EditorBridge
    let chat: ChatModel
    let annotator: Annotator
    @AppStorage("model.chat.claude") private var claudeModel = "opus"
    @AppStorage("model.chat.codex") private var codexModel = ""
    @State private var query = ""
    @State private var index = 0
    /// Built once when the bar opens: building them reads every book's chapters.
    @State private var all: [Command] = []
    @FocusState private var focused: Bool
    @Environment(\.openSettings) private var openSettings

    struct Command: Identifiable {
        let id: String
        let group: String
        let title: String
        var subtitle = ""
        var key = ""
        var icon = "circle"
        /// Run inside an animation (panels sliding in). Off for what repaints the whole window, like the appearance:
        /// animating every colour at once took seconds.
        var animated = true
        /// What it opens in a pane, for « Open beside ».
        var tab: PaneTab? = nil
        let run: () -> Void
    }

    var body: some View {
        ZStack(alignment: .top) {
            // The page stays visible behind, veiled, as in the design.
            Color(nsColor: .textBackgroundColor).opacity(0.72)
                .ignoresSafeArea()
                .onTapGesture { close() }
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(app.openBeside ? L("Open beside: a chapter, a sheet, a board…") : L("Type a command or search…"), text: $query)
                        .textFieldStyle(.plain)
                        .font(.ui(16))
                        .focused($focused)
                        .onSubmit(runSelected)
                        .onKeyPress(.downArrow) { index = min(index + 1, max(0, results.count - 1)); return .handled }
                        .onKeyPress(.upArrow) { index = max(index - 1, 0); return .handled }
                        .onKeyPress(.escape) { close(); return .handled }
                        .onChange(of: query) { _, _ in index = 0 }
                    Kbd("esc")
                }
                .padding(.horizontal, 18).frame(height: 54)
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        // Eager: the results are a few dozen at most, and a LazyVStack that is scrolled to by id is
                        // what spun forever in SwiftUI's prefetch in the chat.
                        VStack(alignment: .leading, spacing: 1) {
                            let list = results
                            ForEach(Array(list.enumerated()), id: \.element.id) { i, c in
                                if i == 0 || list[i - 1].group != c.group {
                                    Text(c.group).font(.ui(11, .medium)).foregroundStyle(.secondary)
                                        .padding(.horizontal, 10).padding(.top, i == 0 ? 6 : 12).padding(.bottom, 4)
                                }
                                row(c, selected: i == index).id(c.id)
                                    .onTapGesture { index = i; runSelected() }
                            }
                            if list.isEmpty {
                                Text(L("Nothing found.")).foregroundStyle(.secondary).padding(16)
                            }
                        }
                        .padding(8)
                    }
                    .frame(maxHeight: 420)
                    .onChange(of: index) { _, i in if results.indices.contains(i) { proxy.scrollTo(results[i].id) } }
                }
                Divider()
                HStack(spacing: 16) {
                    Text(L("↑↓ to move")); Text(app.openBeside ? L("↵ to open beside") : L("↵ to open"))
                    Spacer()
                    Text(L("All of Musset is here."))
                }
                .font(.ui(12)).foregroundStyle(.secondary)
                .padding(.horizontal, 18).padding(.vertical, 9)
                .background(Ink.side)
            }
            .frame(width: 640)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Ink.hairline))
            .shadow(color: .black.opacity(0.16), radius: 32, y: 16)
            .padding(.top, 90)
        }
        .onAppear { all = commands; focused = true }
    }

    private func row(_ c: Command, selected: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: c.icon).font(.ui(13)).frame(width: 18)
                .foregroundStyle(selected ? Ink.accent : .secondary)
            Text(c.title).lineLimit(1)
            Spacer(minLength: 8)
            Text(c.subtitle).font(.ui(12)).foregroundStyle(.secondary).lineLimit(1)
            if !c.key.isEmpty { Text(c.key).font(.ui(11)).foregroundStyle(.secondary).frame(minWidth: 40, alignment: .trailing) }
        }
        .padding(.horizontal, 10).frame(height: 36)
        .background(selected ? Ink.selected : .clear, in: RoundedRectangle(cornerRadius: Radius.control))
        .contentShape(Rectangle())
    }

    // MARK: Commands

    private var results: [Command] {
        let q = query.folded
        if app.openBeside {
            let openable = all.filter { $0.tab != nil }
            guard !q.isEmpty else { return Array(openable.prefix(40)) }
            let words = q.split(separator: " ")
            return Array(openable.filter { c in words.allSatisfy { (c.title + " " + c.subtitle + " " + c.group).folded.contains($0) } }.prefix(60))
        }
        guard !q.isEmpty else {
            // At rest: where you are and the chapters first, then a few views and book commands, the critiques last.
            let here = "sc:" + (session.selectedChapterID ?? "") + ":"
            var out = Array(all.filter { $0.id.hasPrefix(here) || $0.id.hasPrefix("ch:") }.prefix(8))
            out += Array(all.filter { $0.group == AppCommand.Group.view.label }.prefix(5))
            out += Array(all.filter { $0.group == AppCommand.Group.book.label }.prefix(6))
            out += all.filter { $0.id.hasPrefix("chat:") }
            return out
        }
        let words = q.split(separator: " ")
        let found = all.filter { c in
            let hay = (c.title + " " + c.subtitle + " " + c.group).folded
            return words.allSatisfy { hay.contains($0) }
        }
        .prefix(60).map { $0 }
        // The text itself: the book's search (⇧⌘F), already typed in. First when no command matches, so ↵ runs it.
        let typed = query.trimmingCharacters(in: .whitespaces)
        guard typed.count >= 2 else { return found }
        let text = Command(id: "find:text", group: L("Text"), title: L("Search « \(typed) » in the text"),
                           subtitle: session.manifest.title, key: AppCommand.glyphs("book.search"), icon: "text.magnifyingglass") {
            app.searchQuery = typed
            app.openSearch()
        }
        return found.isEmpty ? [text] : found + [text]
    }


    private var context: CommandContext { CommandContext(app: app, bridge: bridge, openSettings: { openSettings() }) }

    /// The commands of the one table (`AppCommand.all`) that apply now, as the bar lists them.
    static func tableCommands(_ c: CommandContext) -> [Command] {
        AppCommand.all.filter { $0.inPalette && $0.applies(c) }.map { cmd in
            var subtitle = ""
            switch cmd.id {
            case "view.ultraFocus": subtitle = L("Only the text, only forward")
            case "view.kiosk": subtitle = L("Only Musset on the screen")
            case "view.light": subtitle = Appearance.current == .light ? L("Now") : ""
            case "view.dark": subtitle = Appearance.current == .dark ? L("Now") : ""
            case "view.system": subtitle = Appearance.current == .system ? L("Now") : ""
            default: break
            }
            return Command(id: cmd.id, group: cmd.group.label, title: cmd.title(c), subtitle: subtitle, key: cmd.shortcut?.glyphs ?? "",
                           icon: cmd.icon, animated: cmd.animated, tab: cmd.tab) { cmd.run(c) }
        }
    }

    private var commands: [Command] {
        var out: [Command] = []
        let critique = L("Critique"), go = AppCommand.Group.go.label
        let chapter = session.selectedChapter?.title ?? ""
        let ai = AIStatus.shared
        let agent = ai.conversingEngine(preferring: chat.agent)
        let model = { (agent == .claude ? claudeModel : codexModel) }

        // The open chapter's scenes, then the book's chapters with theirs.
        for ch in session.manifest.chapters {
            let scenes = session.scenes[ch.id] ?? []
            out.append(.init(id: "ch:\(ch.id)", group: go, title: session.manifest.shownTitle(of: ch), subtitle: (ch.status ?? .draft).label, icon: "doc.text",
                             tab: .chapter(ch.id)) {
                session.open(ch.id)
            })
            for s in scenes where s.title != nil {
                out.append(.init(id: "sc:\(ch.id):\(s.id)", group: go, title: s.title!, subtitle: ch.title + " · " + session.words.name(.scene), icon: "text.line.first.and.arrowtriangle.forward") {
                    bridge.show(s, chapter: ch.id, session: session)
                })
            }
            // Its sections, in a book that reads sub-headings as sections.
            for s in session.sections[ch.id] ?? [] {
                out.append(.init(id: "sec:\(ch.id):\(s.id)", group: go, title: s.title, subtitle: ch.title + " · " + BookStructure.word(.section, lang: session.manifest.lang).one,
                                 icon: "number") {
                    bridge.show(s, chapter: ch.id, session: session)
                })
            }
        }
        // The Bible's sheets and boards.
        let bibleGroup = L("Bible")
        for e in session.bible.entries where !e.isFile {
            out.append(.init(id: "bible:\(e.path)", group: bibleGroup, title: e.title, subtitle: BibleStore.folderLabel(e.folder),
                             icon: e.kind.icon, tab: .sheet(e.path)) { app.open(.sheet(e.path)) })
        }
        for other in app.allChapters() where other.bookPath != session.root.standardizedFileURL.path {
            out.append(.init(id: "other:\(other.bookPath):\(other.chapter.id)", group: go, title: other.chapter.title, subtitle: other.bookTitle, icon: "books.vertical") {
                app.jump(bookPath: other.bookPath, chapterID: other.chapter.id)
            })
        }

        // Every command of the menus, from the same table.
        out += Self.tableCommands(context)
        for name in session.layoutNames {
            out.append(.init(id: "layout:\(name)", group: AppCommand.Group.panes.label, title: name, subtitle: L("Layouts"), icon: "rectangle.3.group") {
                session.applyLayout(named: name)
            })
        }

        // What the AI reader can do with the chapter.
        for a in ChatAction.allCases {
            guard let agent else { break }
            out.append(.init(id: "chat:\(a.rawValue)", group: critique, title: a.localizedLabel + (chapter.isEmpty ? "" : " — " + inQuotes(chapter)),
                             subtitle: "\(agent.label)", icon: a.icon) {
                app.inspectorTab = .chat; app.showInspector = true
                chat.agent = agent
                chat.runAction(a, session: session, selection: bridge.selectedText, model: model())
            })
        }
        for engine in ai.engines {
            for task in Annotator.Task.allCases where task != .custom {
                out.append(.init(id: "annotate:\(engine.rawValue):\(task.rawValue)", group: critique,
                                 title: L("Annotate") + " · " + task.label, subtitle: engine.label, icon: "sparkles") {
                    app.inspectorTab = .edits; app.showInspector = true
                    let sel = bridge.selectedRange
                    annotator.annotate(task, session: session, selection: sel.length > 0 ? sel : nil, engine: engine)
                })
            }
        }
        return out
    }

    private func runSelected() {
        let r = results
        guard r.indices.contains(index) else { return }
        let c = r[index]
        let beside = app.openBeside
        close()
        if beside, let tab = c.tab {
            DispatchQueue.main.async { session.open(tab, in: .nextPane) }
            return
        }
        DispatchQueue.main.async { if c.animated { withAnimation { c.run() } } else { c.run() } }
    }

    private func close() { app.showQuickOpen = false; app.openBeside = false }
}

extension ChatAction {
    var localizedLabel: String {
        switch self {
        case .style: L("Style & problems")
        case .tics: L("Tics")
        case .critique: L("Critique (rubric)")
        case .continuity: L("Continuity")
        case .cuts: L("What to cut")
        case .openingEnding: L("Opening & ending")
        case .facts: L("Facts to check")
        }
    }
}
