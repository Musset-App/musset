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
                    TextField(L("Type a command or search…"), text: $query)
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
                        LazyVStack(alignment: .leading, spacing: 1) {
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
                    Text("↑↓ " + L("move")); Text("↵ " + L("open"))
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
                .foregroundStyle(selected ? Color.accentColor : .secondary)
            Text(c.title).lineLimit(1)
            Spacer(minLength: 8)
            Text(c.subtitle).font(.ui(12)).foregroundStyle(.secondary).lineLimit(1)
            if !c.key.isEmpty { Text(c.key).font(.ui(11)).foregroundStyle(.secondary).frame(minWidth: 40, alignment: .trailing) }
        }
        .padding(.horizontal, 10).frame(height: 36)
        .background(selected ? Ink.selected : .clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
    }

    // MARK: Commands

    private var results: [Command] {
        let q = fold(query)
        guard !q.isEmpty else {
            // At rest: the critiques, where you are, the views, the book — a few of each.
            let here = "sc:" + (session.selectedChapterID ?? "") + ":"
            var out: [Command] = all.filter { $0.id.hasPrefix("chat:") }
            out += Array(all.filter { $0.id.hasPrefix(here) || $0.id.hasPrefix("ch:") }.prefix(8))
            out += Array(all.filter { $0.id.hasPrefix("v:") }.prefix(5))
            out += Array(all.filter { $0.id.hasPrefix("b:") }.prefix(6))
            return out
        }
        let words = q.split(separator: " ")
        let found = all.filter { c in
            let hay = fold(c.title + " " + c.subtitle + " " + c.group)
            return words.allSatisfy { hay.contains($0) }
        }
        .prefix(60).map { $0 }
        // The text itself: the book's search (⇧⌘F), already typed in. First when no command matches, so ↵ runs it.
        let typed = query.trimmingCharacters(in: .whitespaces)
        guard typed.count >= 2 else { return found }
        let text = Command(id: "find:text", group: L("Text"), title: L("Search « \(typed) » in the text"),
                           subtitle: session.manifest.title, key: "⇧⌘F", icon: "text.magnifyingglass") {
            app.searchQuery = typed
            app.openSearch()
        }
        return found.isEmpty ? [text] : found + [text]
    }

    private func fold(_ s: String) -> String { s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }

    private var commands: [Command] {
        var out: [Command] = []
        let critique = L("Critique"), go = L("Go to"), view = L("View"), book = L("Book")
        let chapter = session.selectedChapter?.title ?? ""
        let ai = AIStatus.shared
        let agent = ai.engine(preferring: chat.agent)
        let model = { (agent == .claude ? claudeModel : codexModel) }

        for a in ChatAction.allCases {
            guard let agent else { break }
            out.append(.init(id: "chat:\(a.rawValue)", group: critique, title: a.localizedLabel + (chapter.isEmpty ? "" : " — « \(chapter) »"),
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

        // The open chapter's scenes, then the book's chapters with theirs.
        for ch in session.manifest.chapters {
            let scenes = session.scenes[ch.id] ?? []
            out.append(.init(id: "ch:\(ch.id)", group: go, title: ch.title, subtitle: (ch.status ?? .draft).label, icon: "doc.text") {
                session.open(ch.id)
            })
            for s in scenes where s.title != nil {
                out.append(.init(id: "sc:\(ch.id):\(s.id)", group: go, title: s.title!, subtitle: ch.title + " · " + L("scene"), icon: "text.line.first.and.arrowtriangle.forward") {
                    bridge.show(s, chapter: ch.id, session: session)
                })
            }
        }
        for other in app.allChapters() where other.bookPath != session.root.standardizedFileURL.path {
            out.append(.init(id: "other:\(other.bookPath):\(other.chapter.id)", group: go, title: other.chapter.title, subtitle: other.bookTitle, icon: "books.vertical") {
                app.jump(bookPath: other.bookPath, chapterID: other.chapter.id)
            })
        }

        out += [
            .init(id: "v:grid", group: view, title: L("Plot grid", ctx: "Grille d’intrigue"), key: "⌘5", icon: "tablecells") { app.showPlotGrid.toggle() },
            .init(id: "v:read", group: view, title: L("Reading mode"), key: "⇧⌘R", icon: "book") { app.reviewMode.toggle() },
            .init(id: "v:focus", group: view, title: L("Focus mode"), key: "⇧⌘D", icon: "eye") { app.focusMode.toggle() },
            .init(id: "v:ultra", group: view, title: "Ultra Focus", subtitle: L("Only the text, only forward"), key: "⌃⌘U", icon: "forward.end") { UltraFocus.shared.toggle(app) },
            .init(id: "v:try", group: view, title: L("Try something else"), subtitle: L("Another version of this chapter"), icon: "square.on.square") { app.showTryVersion = true },
            .init(id: "v:kiosk", group: view, title: L("Kiosk mode"), subtitle: L("Only Musset on the screen"), key: "⌃⌘K", icon: "lock.display") { app.kiosk.toggle() },
            .init(id: "v:light", group: view, title: Appearance.light.label, subtitle: Appearance.current == .light ? L("Now") : "", icon: Appearance.light.icon, animated: false) { Appearance.light.choose() },
            .init(id: "v:dark", group: view, title: Appearance.dark.label, subtitle: Appearance.current == .dark ? L("Now") : "", icon: Appearance.dark.icon, animated: false) { Appearance.dark.choose() },
            .init(id: "v:system", group: view, title: Appearance.system.label, subtitle: Appearance.current == .system ? L("Now") : "", icon: Appearance.system.icon, animated: false) { Appearance.system.choose() },
            .init(id: "v:type", group: view, title: L("Typewriter scrolling"), key: "⇧⌘T", icon: "keyboard") { app.typewriter.toggle() },
            .init(id: "v:rep", group: view, title: L("Repetitions"), key: "⌃⌘R", icon: "repeat") { app.repetitions.toggle() },
            .init(id: "v:mini", group: view, title: L("Minimap"), key: "⌃⌘M", icon: "sidebar.squares.right") { app.minimap.toggle() },
            .init(id: "v:lines", group: view, title: L("Line numbers"), key: "⌃⌘L", icon: "list.number") { app.lineNumbers.toggle() },
            .init(id: "v:side", group: view, title: L("Chapters"), key: "⌘1", icon: "sidebar.left") { app.showSidebar.toggle() },
            .init(id: "v:notes", group: view, title: InspectorTab.edits.label, key: "⌘2", icon: InspectorTab.edits.icon) { app.toggleInspector(.edits) },
            .init(id: "v:lang", group: view, title: L("Stats"), key: "⌘4", icon: InspectorTab.stats.icon) { app.toggleInspector(.stats) },
            .init(id: "v:plan", group: view, title: L("Plan"), key: "⌘6", icon: InspectorTab.plan.icon) { app.toggleInspector(.plan) },
            .init(id: "v:pad", group: view, title: InspectorTab.history.label, key: "⌘7", icon: InspectorTab.history.icon) { app.toggleInspector(.history) },
            .init(id: "f:bold", group: book, title: L("Bold"), key: "⌘B", icon: "bold") { bridge.textView?.toggleInline("**") },
            .init(id: "f:italic", group: book, title: L("Italic"), key: "⌘I", icon: "italic") { bridge.textView?.toggleInline("*") },
            .init(id: "f:h1", group: book, title: L("Heading 1"), key: "⌥⌘1", icon: "textformat.size.larger") { bridge.textView?.setHeading(1) },
            .init(id: "f:h2", group: book, title: L("Heading 2"), key: "⌥⌘2", icon: "textformat.size") { bridge.textView?.setHeading(2) },
            .init(id: "f:h3", group: book, title: L("Heading 3"), key: "⌥⌘3", icon: "textformat.size.smaller") { bridge.textView?.setHeading(3) },
            .init(id: "f:quote", group: book, title: L("Quotation"), key: "⌥⌘'", icon: "text.quote") { bridge.textView?.toggleQuote() },
            .init(id: "f:note", group: book, title: L("Footnote"), key: "⌥⌘6", icon: "textformat.superscript") { bridge.textView?.insertFootnote() },
            .init(id: "r:mode", group: book, title: L("Revision mode"), key: "⇧⌘E", icon: "pencil.line") { bridge.trackChanges.toggle() },
            .init(id: "r:comment", group: book, title: L("Comment the selection"), key: "⇧⌘M", icon: "text.bubble") { bridge.textView?.commentSelection() },
            .init(id: "r:next", group: book, title: L("Next correction"), key: "⌥⌘]", icon: "arrow.down.to.line") { bridge.textView?.nextRevision() },
            .init(id: "r:acceptall", group: book, title: L("Accept all corrections"), icon: "checkmark.circle") { bridge.textView?.decideRevision(accept: true, all: true) },
            .init(id: "r:rejectall", group: book, title: L("Reject all corrections"), icon: "xmark.circle") { bridge.textView?.decideRevision(accept: false, all: true) },
            .init(id: "f:bar", group: view, title: L("Format bar"), icon: "textformat") { app.formatBar.toggle() },
            .init(id: "b:scene", group: book, title: L("New scene here"), key: "⇧⌘N", icon: "plus.square.dashed") { bridge.textView?.beginScene() },
            .init(id: "b:note", group: book, title: L("Add a note on the selection"), key: "⌥⌘N", icon: "plus.bubble") { bridge.textView?.beginNote() },
            .init(id: "b:search", group: book, title: L("Search the book"), key: "⇧⌘F", icon: "magnifyingglass") { app.openSearch() },
            .init(id: "b:export", group: book, title: L("Export…"), key: "⌘E", icon: "square.and.arrow.up") { app.showExport = true },
            .init(id: "b:wordReview", group: book, title: L("Bring in a corrected Word file…"), icon: "doc.badge.arrow.up") { app.showWordReview = true },
            .init(id: "b:special", group: book, title: L("Cover & special pages"), icon: "rectangle.portrait") { app.specialPage = .cover },
            .init(id: "b:settings", group: book, title: L("Book settings"), key: "⌥⌘,", icon: "gearshape") { app.showBookSettings = true },
            .init(id: "c:share", group: book, title: L("Share this book, reviews…"), icon: "person.2") {
                app.bookSettingsSection = .sharing; app.showBookSettings = true
            },
            .init(id: "c:blame", group: book, title: L("Who wrote what"), key: "⌥⌘B", icon: "person.2.wave.2") { bridge.blameOn.toggle() },
            .init(id: "c:shared", group: book, title: L("Musset account, my books online…"), icon: "person.crop.circle") { app.showAccount = true },
            .init(id: "b:new", group: book, title: L("New book…"), key: "⌘N", icon: "plus.rectangle.on.folder") { app.showNewBook = true },
            .init(id: "b:open", group: book, title: L("Open a book folder…"), key: "⌘O", icon: "folder") { app.addBookViaPanel() },
                        .init(id: "b:story", group: book, title: L("The book’s history: tracks, milestones"), key: "", icon: "point.topleft.down.to.point.bottomright.curvepath") { app.showStory = true },
            .init(id: "b:piste", group: book, title: L("Try something else (new track)…"), key: "", icon: "arrow.triangle.branch") { app.newPiste = TrackStart() },
            .init(id: "b:jalon", group: book, title: L("Set a milestone…"), key: "", icon: "flag") { app.newJalon = TrackStart() },
            .init(id: "b:snapshot", group: book, title: L("Save a snapshot (commit now)"), key: "⌘S", icon: "checkmark.seal") {
                session.flushSave(); session.commitNow("musset: snapshot")
            },
            .init(id: "b:typo", group: book, title: L("Apply typography to the whole book"), icon: "textformat") { app.applyTypographyToBook() },
        ]
        if ai.isOn {
            out.append(.init(id: "v:chat", group: view, title: L("Chat"), key: "⌘3", icon: "bubble.left.and.text.bubble.right") { app.toggleInspector(.chat) })
        }
        return out
    }

    private func runSelected() {
        let r = results
        guard r.indices.contains(index) else { return }
        let c = r[index]
        close()
        DispatchQueue.main.async { if c.animated { withAnimation { c.run() } } else { c.run() } }
    }

    private func close() { app.showQuickOpen = false }
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
