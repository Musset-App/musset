import SwiftUI

struct ContentView: View {
    @Bindable var app: AppState
    let bridge: EditorBridge
    let chat: ChatModel
    let pangram: PangramModel
    let proof: AutoProofreader
    let annotator: Annotator
    @AppStorage("fontName") private var fontName = Typefaces.manuscript
    @AppStorage("fontSize") private var fontSize = 17.0
    @AppStorage("columnWidth") private var columnWidth = 640.0
    @AppStorage("inspectorWidth") private var inspectorWidth = 384.0
    @State private var analyst = PlotAnalyst()
    /// The first chapter of the book just marked done.
    @State private var chapterDone: DoneChapter?
    @State private var planner = ScenePlanner()
    @State private var layoutName = ""
    @State private var room = WindowRoom()
    /// The interface rebuilds when its language changes.
    @AppStorage(UILang.key) private var uiLanguage = UILang.system.rawValue
    @Environment(\.openWindow) private var openWindow

    private func paneContext(_ session: BookSession) -> PaneContext {
        PaneContext(app: app, session: session, workspace: session.mainWorkspace, bridge: bridge, proof: proof, analyst: analyst,
                    planner: planner, fontName: fontName, fontSize: fontSize, columnWidth: columnWidth)
    }

    private var covered: Bool { app.activeTab?.isChapter == false }

    var body: some View {
        ZStack {
            if let session = app.current {
                VStack(spacing: 0) {
                TitleBar(app: app, session: session, bridge: bridge)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { room.width = $0 }
                // A flat column, not the system sidebar: full height, flush, one hairline.
                HStack(spacing: 0) {
                    if app.showSidebar {
                        ChapterSidebar(session: session, app: app, bridge: bridge,
                                       scenePlanner: { engine in planner.propose(session, engine: engine) })
                            .frame(width: InspectorFit.sidebar)
                            .transition(.move(edge: .leading))
                        Divider()
                    }
                    HStack(spacing: 0) {
                        // The panes and their tabs; in Focus mode, only the pane one is in, without tabs.
                        Group {
                            if app.focusMode, let pane = session.mainWorkspace.focused {
                                PaneView(ctx: paneContext(session), pane: pane)
                            } else {
                                PaneArea(ctx: paneContext(session))
                            }
                        }
                        .onChange(of: covered || app.showHome, initial: true) { _, hidden in bridge.covered = hidden }
                        // Chapters no pane shows any more are saved and let go.
                        .onChange(of: session.mainWorkspace.root) { _, _ in session.pruneDocs() }
                        // This window in front: its panes are where things open.
                        .background(WindowWatcher(onKey: { session.activeWindow = nil }))
                        .task(id: session.root) { await app.reopenWindows(of: session) }
                        .onChange(of: session.bible.entries.count) { _, _ in session.pruneTabs() }
                        .onChange(of: session.manifest.chapters.count) { _, _ in session.pruneTabs() }
                        if app.showInspector {
                            InspectorColumn(app: app, room: room, width: $inspectorWidth) {
                                InspectorPanel(app: app, session: session, bridge: bridge, chat: chat, pangram: pangram,
                                               proof: proof, annotator: annotator, analyst: analyst, planner: planner)
                            }
                            .transition(.move(edge: .trailing))
                        }
                    }
                }
                }
                .ignoresSafeArea(.container, edges: .top)
                .onAppear { chat.attach(session.root); proof.attach(session); openScreenFromLaunchArguments() }
                // The first days: what is said once, and what is offered on a later visit (FirstSteps).
                .onChange(of: session.bookCounts.words) { old, new in app.wordsChanged(from: old, to: new, in: session) }
                .task(id: session.root) { try? await Task.sleep(for: .seconds(4)); app.considerOffers() }
                .onChange(of: session.root) { _, r in chat.attach(r); proof.attach(session); pangram.clear(bridge) }
                .onChange(of: session.selectedChapterID) { _, _ in pangram.clear(bridge) }
                .onChange(of: app.showSearch) { _, on in if !on { bridge.setSearchQuery("") } }
                // Opening a note's thread (margin dot, hover preview, context menu) shows the Edits & Comments tab.
                .onChange(of: bridge.openNoteID) { _, id in
                    if id != nil { withAnimation { app.inspectorTab = .edits; app.showInspector = true } }
                }
                .sheet(item: $app.newPiste) { NewPisteSheet(session: session, start: $0) }
                .sheet(item: $app.newJalon) { JalonSheet(session: session, start: $0) }
                .sheet(item: $app.renaming) { target in
                    RenameSheet(session: session, bridge: bridge, path: target.path) { app.renaming = nil }
                }
                .sheet(item: $app.takingBack) { TakeBackView(session: session, piste: $0) }
                .sheet(item: $app.bringing) { TakeBackView(session: session, point: $0) }
                .sheet(isPresented: $app.showRubric) { BaremeSheet(session: session) }
                .sheet(isPresented: $app.showProofExceptions) { ProofExceptionsSheet(proof: proof) }
                .sheet(isPresented: $app.showExport, onDismiss: { app.exportAt = nil }) {
                    ExportSheet(session: session, preview: app.exportAt == nil ? { app.review.scope = .book; if app.activeTab?.special != nil || app.activeTab?.overview != nil { app.showChapter() }; app.reviewMode = true } : nil,
                                at: app.exportAt)
                }
                .sheet(isPresented: $app.showWordReview) { WordReviewSheet(app: app, session: session, bridge: bridge) }
                .sheet(isPresented: $planner.showing) { ScenePlanSheet(planner: planner, session: session, bridge: bridge) }
                // A shared book opened by its reader: revision mode, so every change is a correction.
                .onAppear { if Collab.shared.isReviewer(session.git) { bridge.trackChanges = true } }
                .onChange(of: session.root) { _, _ in if Collab.shared.isReviewer(session.git) { bridge.trackChanges = true } }
                // The fade belongs to the bar alone: on the whole window it animated every colour of every view
                // at each ⌘K (seconds of SwiftUI work on a MacBook Air).
                .overlay {
                    ZStack {
                        if app.showQuickOpen {
                            CommandPalette(app: app, session: session, bridge: bridge, chat: chat, annotator: annotator)
                                .transition(.opacity)
                        }
                    }
                    .animation(.easeOut(duration: 0.12), value: app.showQuickOpen)
                }
                .opacity(app.showHome ? 0 : 1)
                .allowsHitTesting(!app.showHome)
            }
            if app.showHome || app.current == nil {
                // No book yet: the welcome, unless Home was asked for (the account finds the books kept online).
                if app.libraryPaths.isEmpty && !app.showHome { WelcomeView(app: app) } else { HomeView(app: app) }
            }
        }
        .overlay(alignment: .top) { KioskHint(on: app.kiosk) }
        .overlay(alignment: .bottom) {
            ZStack { if let session = app.current { VersionSwitchToast(session: session) } }
                .animation(.easeOut(duration: 0.25), value: app.current?.lastVersionSwitch)
        }
        .overlay(alignment: .bottom) {
            if let session = app.current, !app.showHome, !app.reviewMode, app.activeTab?.isChapter != false { EmptyPageHint(session: session) }
        }
        .overlay(alignment: .bottom) { FirstNoticeView(app: app) }
        .onAppear {
            CaptureController.shared.app = app; CaptureController.shared.install(); Collab.shared.start(app)
            app.openWindow = { [openWindow] ref in openWindow(id: PaneWindow.sceneID, value: ref) }
        }
        .sheet(isPresented: $app.showNewBook) { WelcomeView(app: app, sheet: true) }
        .sheet(isPresented: $app.showSyncOffer) { SyncOfferSheet(app: app) }
        .sheet(item: $chapterDone) { done in
            if let s = app.current { ChapterDoneCard(app: app, session: s, chapterID: done.id) }
        }
        .onReceive(NotificationCenter.default.publisher(for: BookSession.firstChapterDone)) { note in
            if let s = note.object as? BookSession, s === app.current, let id = note.userInfo?["chapter"] as? String { chapterDone = DoneChapter(id: id) }
        }
        .sheet(isPresented: $app.showTryVersion) { if let session = app.current { TryVersionSheet(session: session) } }
        .sheet(isPresented: $app.showHelpers) { AIHelpersView() }
        .tint(Ink.accent)
        .id(uiLanguage)
        .sheet(item: $app.pendingSetup) { SetupSheet(app: app, setup: $0) }
        .alert(L("Save the Layout…").titled, isPresented: $app.namingLayout) {
            TextField(L("Name"), text: $layoutName)
            Button(L("Save")) { app.current?.saveLayout(named: layoutName); layoutName = "" }
            Button(L("Cancel"), role: .cancel) { layoutName = "" }
        } message: {
            Text(L("The panes and tabs of this window, to put back from the Panes menu."))
        }
        .alert("Musset", isPresented: Binding(get: { app.alert != nil }, set: { if !$0 { app.alert = nil } })) {
            Button("OK") { app.alert = nil }
        } message: { Text(app.alert ?? "") }
    }
}

extension ContentView {
    /// Development aid: `-musset-screen read|grid|special|export|settings|palette|notes|partner` opens that screen at launch,
    /// so each one can be checked in the real window.
    func openScreenFromLaunchArguments() {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-musset-screen"), i + 1 < args.count else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            switch args[i + 1] {
            case "read": app.review.scope = .book; app.reviewMode = true
            case "grid": app.open(OverviewTab.grid.tab)
            case "special": app.open(SpecialPage.cover.tab)
            case "export": app.showExport = true
            case "settings": app.showSettings()
            case "palette": app.showQuickOpen = true
            case "notes": app.inspectorTab = .edits; app.showInspector = true
            case "partner": app.inspectorTab = .chat; app.showInspector = true
            case "home": app.showHome = true
            case "account": app.showAccount()
            case "sharing": app.showReaders()
            case "blame": bridge.blameOn = true
            case "find": bridge.setSearchQuery("elle"); bridge.openFind(replace: true)
            case "overview": app.open(OverviewTab.summary.tab)
            case "bible": app.open(.folder("personnages"))
            case "capture": CaptureController.shared.toggle()
            case "helpers": app.showHelpers = true
            case "sheet": if let e = app.current?.bible.entries.first(where: { !$0.isFile }) { app.open(.sheet(e.path)) }
            default: break
            }
        }
    }
}

/// The window's width, measured on the title bar. Kept in an object of its own so that resizing the window
/// evaluates the inspector's column alone, not the whole window.
@MainActor
@Observable
final class WindowRoom {
    var width: CGFloat = .greatestFiniteMagnitude
}

/// How the inspector fits a window: the sidebar and the panes keep their room first.
enum InspectorFit {
    static let sidebar: CGFloat = 256
    static let panes: CGFloat = 280
    static let range: ClosedRange<Double> = 340...900

    /// The widest the inspector may be in a window `window` points wide; nil when even its narrowest does not fit.
    static func most(window: CGFloat, sidebar shown: Bool) -> Double? {
        let most = Double(window - (shown ? sidebar + 1 : 0) - panes)
        return most >= range.lowerBound ? min(most, range.upperBound) : nil
    }

    /// The inspector's width: the one the author set, less in a narrow window; nil when it has to fold away.
    static func width(wanted: Double, window: CGFloat, sidebar shown: Bool) -> Double? {
        most(window: window, sidebar: shown).map { min(max(wanted, range.lowerBound), $0) }
    }
}

/// The inspector at the width the window allows. Too narrow a window for the panes and the inspector together:
/// the inspector folds away rather than being cut, and comes back when there is room again.
private struct InspectorColumn<Panel: View>: View {
    let app: AppState
    let room: WindowRoom
    @Binding var width: Double
    @ViewBuilder let panel: () -> Panel

    var body: some View {
        if let most = InspectorFit.most(window: room.width, sidebar: app.showSidebar),
           let shown = InspectorFit.width(wanted: width, window: room.width, sidebar: app.showSidebar) {
            // The handle sits on the panel's edge, so the panel keeps its exact width.
            panel()
                .frame(width: shown)
                .overlay(alignment: .leading) {
                    PanelResizeHandle(width: $width, range: InspectorFit.range.lowerBound...most).offset(x: -3)
                }
        }
    }
}

struct EditorColumn: View {
    let app: AppState
    @Bindable var session: BookSession
    let bridge: EditorBridge
    let proof: AutoProofreader
    let fontName: String
    let fontSize: Double
    let columnWidth: Double
    /// The chapter shown, in a pane; nil: the one written in.
    var doc: ChapterDoc? = nil
    /// The pane the author is in: the find bar, the status bar, reading mode and the side version are its own.
    var live = true
    var onFocus: (() -> Void)? = nil
    var drops: PaneDrops? = nil
    /// The pane's kept editors, and this chapter's place among them.
    var editors: EditorCache? = nil
    var editorKey: String? = nil
    @AppStorage("repetitionWindow") private var repetitionWindow = 50
    @AppStorage("paragraphSpacing") private var paragraphSpacing = 0.73
    /// The width of the version read beside the editor; the handle between them sets it.
    @AppStorage("referenceWidth") private var referenceWidth = 520.0

    /// Below this width the preview takes the whole window instead of sitting beside the editor.
    static let sideBySideMinWidth: CGFloat = 1050

    var body: some View {
        GeometryReader { geo in
            let side = app.reviewMode && geo.size.width >= Self.sideBySideMinWidth
            let previewWidth = side ? (geo.size.width * 0.42).rounded() : geo.size.width
            // The editor keeps its place in the hierarchy in every mode, so its caret and undo history survive.
            ZStack(alignment: .trailing) {
                HStack(spacing: 0) {
                    editor(width: geo.size.width - (live && side ? previewWidth : 0))
                    if live && side { Color.clear.frame(width: previewWidth) }
                }
                .opacity(live && app.reviewMode && !side ? 0 : 1)
                .allowsHitTesting(!live || !app.reviewMode || side)
                if live && app.reviewMode {
                    HStack(spacing: 0) {
                        if side { Divider() }
                        ReviewView(app: app, session: session, model: app.review, bridge: bridge, sideBySide: side)
                    }
                    .frame(width: previewWidth)
                }
            }
        }
        .navigationTitle(session.selectedChapter.map(session.manifest.shownTitle(of:)) ?? session.title)
        .navigationSubtitle(session.title)
        .onReceive(NotificationCenter.default.publisher(for: .mussetProofread)) { _ in proof.revealNext() }
        .onReceive(NotificationCenter.default.publisher(for: .mussetProofExceptions)) { _ in app.showProofExceptions = true }
        .onReceive(NotificationCenter.default.publisher(for: .mussetCommandBar)) { _ in app.showQuickOpen = true }
    }

    /// The writing editor stays alive in reading mode (hidden), so its undo history and caret survive.
    /// Another version of the chapter may sit beside it, read-only.
    private func editor(width: CGFloat) -> some View {
        HStack(spacing: 0) {
            writing
            if live, session.reference != nil, !app.reviewMode {
                SplitHandle(width: $referenceWidth, total: width)
                ReferencePane(session: session, fontName: fontName, fontSize: fontSize,
                              columnWidth: columnWidth, paragraphSpacing: paragraphSpacing)
                    .frame(width: SplitHandle.clamp(referenceWidth, total: width))
            }
        }
    }

    private var writing: some View {
        VStack(spacing: 0) {
            if live && bridge.findOpen { FindBar(bridge: bridge, text: session.text) }
            HStack(spacing: 0) {
                ZenEditorView(session: session, bridge: bridge, doc: doc, onFocus: onFocus, drops: drops, live: live, fontName: fontName, fontSize: fontSize,
                              columnWidth: columnWidth, focusMode: app.focusMode, typewriter: app.typewriter,
                              lineNumbers: app.lineNumbers, repetitions: app.repetitions, repetitionWindow: repetitionWindow,
                              paragraphSpacing: paragraphSpacing, cache: editors, cacheKey: editorKey)
                    .frame(minWidth: 280)
                if live && app.minimap {
                    Minimap(bridge: bridge)
                        .frame(width: 72)
                        .help(L("The whole chapter: click or drag to move"))
                }
            }
            .overlay(alignment: .top) {
                if live && bridge.trackChanges { RevisionBar(bridge: bridge).padding(.top, 12) }
                else if live && app.formatBar && !app.focusMode { FormatBar(bridge: bridge).padding(.top, 12) }
            }
        }
        .overlay(alignment: .bottomLeading) {
            if live && bridge.blameOn { AttributionBar(bridge: bridge, session: session).padding([.bottom, .leading], 16) }
        }
        .overlay(alignment: .bottom) { if live, let hint = bridge.keyHint { KeyHintCard(hint: hint).padding(.bottom, 56) } }
        // A new name that just got its sheet, in the right margin (never in focus mode).
        .overlay(alignment: .topTrailing) {
            if live && !app.focusMode {
                NameJoinedNotice(spotter: session.spotter) { app.open(.sheet($0)) }.padding([.top, .trailing], 24)
            }
        }
        // In the corner, beside the column rather than over its last lines.
        .overlay(alignment: .bottomTrailing) { if live { StatusBar(app: app, session: session, proof: proof, bridge: bridge).padding([.bottom, .trailing], 16) } }
        .background(Color(nsColor: .textBackgroundColor))
    }

}

/// The window's title bar, drawn by the app at the design's 44 points: room for the window buttons, the sidebar
/// toggle, "Book / Chapter / Scene" (with the version, when the chapter has several), then the track when one
/// writes on one, Write/Revise/Read, ⌘K and the panel. The chapter's status and its corrections are in the
/// status pill under the text; every book is in the sidebar's book menu.
struct TitleBar: View {
    let app: AppState
    let session: BookSession
    let bridge: EditorBridge
    static let height: CGFloat = 44

    /// The width of the controls on the right, as laid out: wider on a track.
    @State private var controlsWidth: CGFloat = 0
    /// The window buttons, the way home and the chapters toggle; in kiosk mode there are no window buttons.
    private var leading: CGFloat { app.kiosk ? 86 : 150 }

    var body: some View {
        // The breadcrumb on the left, beside the chapters toggle. Never under the controls: it truncates first.
        GeometryReader { geo in
          let beside = geo.size.width - leading - controlsWidth - 16
            HStack(spacing: 10) {
                Color.clear.frame(width: app.kiosk ? 4 : 64)
                iconButton("house", L("All Books"), AppCommand.hint(L("All Books"), "go.home")) { app.showHome = true }
                iconButton("sidebar.left", L("Sidebar"), AppCommand.hint(L("Show or hide the sidebar"), "view.sidebar")) { withAnimation { app.showSidebar.toggle() } }
                if beside > 120 {
                    Breadcrumb(app: app, session: session, bridge: bridge).frame(maxWidth: beside, alignment: .leading)
                        .padding(.leading, 4)
                }
                Spacer(minLength: 0)
                controls(compact: geo.size.width < 1200)
                    .fixedSize()
                    .onGeometryChange(for: CGFloat.self) { $0.size.width + 14 } action: { controlsWidth = $0 }
            }
            .padding(.trailing, 14)
            .frame(height: Self.height)
        }
        .frame(height: Self.height)
        .background(WindowDragArea())
        .background(Color(nsColor: .textBackgroundColor))
        .overlay(alignment: .bottom) { Divider() }
    }

    private func controls(compact: Bool) -> some View {
        HStack(spacing: 10) {
            if let piste = session.piste { TrackChip(app: app, piste: piste) }
            Segmented(options: [(0, L("Write")), (1, L("Revise")), (2, L("Read"))],
                      selection: Binding(get: { app.reviewMode ? 2 : (bridge.trackChanges ? 1 : 0) },
                                         set: { mode in app.reviewMode = mode == 2; bridge.trackChanges = mode == 1 }))
                .frame(width: 204)
                .help(L("Write · Revise: changes become corrections (\(AppCommand.glyphs("revise.mode"))) · Read: as printed (\(AppCommand.glyphs("view.reading")))"))
            // Sharing is one click from anywhere in the book: the Readers page, on its invitation when it can send one.
            Button { app.showReaders(inviting: true) } label: {
                HStack(spacing: 6) {
                    Image(systemName: "person.badge.plus").font(.ui(12))
                    if !compact { Text(L("Share")).font(.ui(12, .medium)) }
                }
                .padding(.horizontal, compact ? 8 : 11).frame(height: 28)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: Radius.control))
                .overlay(RoundedRectangle(cornerRadius: Radius.control).strokeBorder(Ink.hairline))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("Invite Someone to This Book…").titled)
            .accessibilityLabel(L("Share"))
            Button { app.showQuickOpen = true } label: {
                HStack(spacing: 10) {
                    if !compact { Text(L("Search or command")).font(.ui(12)).foregroundStyle(.secondary) }
                    Kbd(AppCommand.glyphs("app.palette"))
                }
                .padding(.leading, compact ? 6 : 10).padding(.trailing, 6).frame(height: 28)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: Radius.control))
                .overlay(RoundedRectangle(cornerRadius: Radius.control).strokeBorder(Ink.hairline))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(AppCommand.hint(L("Command Bar…").titled, "app.palette"))
            .accessibilityLabel(L("Command Bar…").titled)
            // Without AI, no AI reader's tab: the tooltip names the tabs there are.
            let tabs = InspectorTab.allCases.filter { AIHome.shown || $0 != .chat }
            iconButton("sidebar.right", tabs.map(\.label).joined(separator: ", "),
                       tabs.map(\.label).joined(separator: ", ") + " (" + tabs.map(\.shortcut).joined(separator: " ") + ")") { withAnimation { app.showInspector.toggle() } }
        }
    }

    /// An icon alone: `label` names it for VoiceOver, `help` is its tooltip with the shortcut.
    private func iconButton(_ icon: String, _ label: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.ui(14)).foregroundStyle(.secondary).frame(width: 28, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(help).accessibilityLabel(label)
    }
}

/// The empty parts of the title bar move the window, and a double-click zooms it, as in any Mac title bar.
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 { window?.performZoom(nil) } else { window?.performDrag(with: event) }
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            WindowChrome.place(window)
            for name in [NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification, NSWindow.didExitFullScreenNotification] {
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { n in
                    if let w = n.object as? NSWindow { MainActor.assumeIsolated { WindowChrome.place(w) } }
                }
            }
        }
    }
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ view: NSView, context: Context) {}
}

/// Puts the window's close, minimise and zoom buttons in the middle of the 44-point title bar.
@MainActor
enum WindowChrome {
    static func place(_ window: NSWindow) {
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        let types: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        guard let close = window.standardWindowButton(.closeButton), let bar = close.superview, let container = bar.superview else { return }
        // Grow the system title bar to the design's height so the buttons are not clipped, then centre them in it.
        var c = container.frame
        if c.height != TitleBar.height {
            c.size.height = TitleBar.height
            c.origin.y = window.frame.height - TitleBar.height
            container.frame = c
            bar.frame = container.bounds
        }
        for (i, t) in types.enumerated() {
            guard let b = window.standardWindowButton(t) else { continue }
            b.setFrameOrigin(NSPoint(x: 14 + CGFloat(i) * 20, y: (bar.bounds.height - b.frame.height) / 2))
        }
    }
}

/// "Book / Chapter / Scene" in the title bar: where one is, not a menu (the sidebar's book menu goes from book to book).
struct Breadcrumb: View {
    let app: AppState
    let session: BookSession
    let bridge: EditorBridge

    /// The pane one is in, when it shows the chapter as its scenes' cards.
    private var cards: (pane: String, chapter: String)? {
        let w = session.workspace
        guard let chapter = w.focusedSceneCards, chapter == session.selectedChapterID else { return nil }
        return (w.focusedPane, chapter)
    }

    /// The scene the caret is in; among the cards, the one chosen. In a book with sections, the innermost of the
    /// scene and the section the caret is in: the trail stays one name long.
    private var scene: String? {
        guard let id = session.selectedChapterID else { return nil }
        let scenes = session.scenes[id] ?? []
        if let cards {
            guard scenes.count > 1, let i = session.workspace.selectedSceneCard(pane: cards.pane, chapter: cards.chapter), scenes.indices.contains(i) else { return nil }
            return scenes[i].title ?? session.words.scene(i + 1)
        }
        let at = bridge.selectedRange.location
        let scene = scenes.count > 1 ? Scenes.scene(at: at, in: scenes) : nil
        guard let section = Sections.section(at: at, in: session.sections[id] ?? []) else { return scene?.title }
        if let scene, scene.title != nil, scene.range.location > section.line.location { return scene.title }
        return section.title
    }

    /// Text or scene cards, for a chapter of several scenes shown in the pane one is in.
    @ViewBuilder private var sceneSwitch: some View {
        let w = session.workspace
        if let pane = w.focused, let id = pane.activeTab?.chapterID, id == session.selectedChapterID,
           cards != nil || (session.scenes[id]?.count ?? 0) > 1 {
            Segmented(options: [(false, L("Text")), (true, session.words.plural(.scene))],
                      selection: Binding(get: { w.showsSceneCards(pane: pane.id, chapter: id) }, set: { w.setSceneCards($0, pane: pane.id, chapter: id) }))
                .frame(width: 124)
                .fixedSize()
                .help(AppCommand.hint(session.words.sceneCards, "view.sceneCards"))
        }
    }

    /// On Overview's first page, the trail is its board's zoom: the book, then the part when one is shown; the book's name goes
    /// back to the whole book.
    @ViewBuilder private var scenesTrail: some View {
        let w = session.workspace
        if let part = session.scenesPart(in: w) {
            Button { w.zoomScenes(toPart: nil) } label: { Text(session.title).foregroundStyle(.secondary).contentShape(Rectangle()) }
                .buttonStyle(.plain)
            Text("/").foregroundStyle(.tertiary)
            Text(session.partName(part)).fontWeight(.medium)
        } else {
            Text(session.title).fontWeight(.medium)
        }
    }

    var body: some View {
        HStack(spacing: 7) {
            if app.activeTab?.overview == .summary {
                scenesTrail
            } else {
                Text(session.title).foregroundStyle(.secondary)
            }
            if app.activeTab?.overview == .summary {
                // The trail above says it all: the chapter last written in is not where one is.
            } else if let page = app.activeTab?.special {
                Text("/").foregroundStyle(.tertiary)
                Text(page.label).fontWeight(.medium)
            } else if let ch = session.selectedChapter {
                Text("/").foregroundStyle(.tertiary)
                Text(session.manifest.shownTitle(of: ch)).foregroundStyle(scene == nil ? .primary : .secondary).fontWeight(scene == nil ? .medium : .regular)
                if session.piste == nil { VersionChip(app: app, session: session).fixedSize() }
                if let scene {
                    Text("/").foregroundStyle(.tertiary)
                    Text(scene).fontWeight(.medium)
                }
                sceneSwitch.padding(.leading, 4)
            }
        }
        .font(.ui(13))
        .lineLimit(1)
        .truncationMode(.middle)
    }
}

/// Most repeated words of the chapter; picking one lights all its occurrences.
struct RepetitionsPopover: View {
    let bridge: EditorBridge
    @AppStorage("repetitionWindow") private var window = 50

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("Repeated words")).font(.ui(13, .semibold))
            Text(L("Pink: the same word again within \(window) words. Hover a word in the text to see all its occurrences."))
                .font(.ui(11)).foregroundStyle(.secondary)
            let counts = bridge.repetitionCounts
            let most = max(1, counts.map(\.count).max() ?? 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(counts) { c in
                        Button { bridge.focusRepetition(bridge.focusedStem == c.stem ? nil : c.stem) } label: {
                            HStack {
                                Text(c.display).fontWeight(bridge.focusedStem == c.stem ? .semibold : .regular)
                                Spacer()
                                if c.close > 0 { Text(L("\(c.close) close")).font(.ui(11)).foregroundStyle(.pink) }
                                Text("\(c.count)").font(.ui(11).monospacedDigit()).foregroundStyle(.secondary).frame(width: 28, alignment: .trailing)
                                Capsule().fill(.secondary.opacity(0.5)).frame(width: 50 * CGFloat(c.count) / CGFloat(most), height: 4)
                                    .frame(width: 50, alignment: .leading)
                            }
                            .padding(.vertical, 3).padding(.horizontal, 6)
                            .background(bridge.focusedStem == c.stem ? Ink.accent.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: Radius.row))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 320)
            if counts.isEmpty { Text(L("No repeated words.")).foregroundStyle(.secondary) }
            if bridge.focusedStem != nil {
                Button(L("Clear")) { bridge.focusRepetition(nil) }.controlSize(.small)
            }
        }
        .padding(14)
        .frame(width: 320)
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

extension Notification.Name {
    static let mussetProofread = Notification.Name("mussetProofread")
    static let mussetProofExceptions = Notification.Name("mussetProofExceptions")
    /// ⇧⌘M: open the comment field of Revise mode's toolbar.
    static let mussetAskComment = Notification.Name("mussetAskComment")
}

/// The counters, the chapter's status and its corrections, gathered in a small floating pill at the bottom of the
/// page. It fades while you type and comes back when you stop.
struct StatusBar: View {
    let app: AppState
    let session: BookSession
    let proof: AutoProofreader
    let bridge: EditorBridge
    @State private var showRepetitions = false
    @State private var typing = false
    @State private var fade: Task<Void, Never>?

    var body: some View {
        // Everything spelled out when the pane has the room; else the short forms (a dot for the status, counts alone),
        // shorter still in a very narrow pane.
        ViewThatFits(in: .horizontal) {
            pill(compact: false)
            pill(compact: true)
            pill(compact: true, tight: true)
        }
        .opacity(typing ? 0 : 1)
        .animation(.easeInOut(duration: 0.35), value: typing)
        .onChange(of: session.text) { _, _ in
            typing = true
            fade?.cancel()
            fade = Task { try? await Task.sleep(nanoseconds: 1_600_000_000); if !Task.isCancelled { typing = false } }
        }
    }

    /// A segment shows only when it has something to say: the words and the chapter's status always do.
    private func pill(compact: Bool, tight: Bool = false) -> some View {
        HStack(spacing: compact ? 9 : 12) {
            if let mode = bridge.keyStatus {
                Text(mode).font(.uiMono(11).weight(.medium)).foregroundStyle(.primary)
                    .padding(.horizontal, 6).frame(height: 18)
                    .background(Ink.panel, in: RoundedRectangle(cornerRadius: 4))
                separator
            }
            ChapterCount(session: session)
            if let ch = session.selectedChapter {
                separator
                PopMenu(ChapterStatus.allCases.map { st in PopItem(title: st.label, checked: (ch.status ?? .draft) == st, dot: st.dot) { session.setStatus(ch.id, st) } }) {
                    HStack(spacing: 6) {
                        StatusDot(status: ch.status ?? .draft)
                        if !compact { Text((ch.status ?? .draft).label) }
                    }
                    .frame(minWidth: 14, minHeight: 20).contentShape(Rectangle())
                }
                .help(session.words.pieceStatus + (compact ? " : " + (ch.status ?? .draft).label : ""))
                .accessibilityLabel(session.words.pieceStatus + ", " + (ch.status ?? .draft).label)
            }
            if bridge.pendingRevisions > 0 {
                separator
                PopMenu([PopItem(title: L("Next Correction")) { bridge.textView?.nextRevision() },
                         PopItem(title: L("Accept all")) { bridge.textView?.decideRevision(accept: true, all: true) },
                         PopItem(title: L("Reject all…")) { RejectAll.confirm(bridge.pendingRevisions) { bridge.textView?.decideRevision(accept: false, all: true) } }]) {
                    HStack(spacing: 6) {
                        Circle().fill(Ink.revision).frame(width: 6, height: 6)
                        Text(compact ? "\(bridge.pendingRevisions)" : L("\(bridge.pendingRevisions) corrections"))
                    }
                    .frame(minHeight: 20).contentShape(Rectangle())
                }
                .help(L("Corrections in this chapter"))
                .accessibilityLabel(L("\(bridge.pendingRevisions) corrections"))
            }
            let openNotes = session.notes.notes.filter { $0.status == .open && !$0.kind.isPositive }.count
            if openNotes > 0 {
                separator
                Button { withAnimation { app.toggleInspector(.edits) } } label: { Text(L("\(openNotes) notes")) }
                    .buttonStyle(.plain).help(AppCommand.hint("view.notes"))
            }
            if proofSpeaks {
                separator
                Button { withAnimation { app.inspectorTab = .edits; app.showInspector = true } } label: { proofSummary }
                    .buttonStyle(.plain)
                    .help([proof.lastError, proof.languageToolError].compactMap { $0 }.joined(separator: "\n").nilIfEmpty
                          ?? L("Proofreading: purple = AI suggestion, blue = grammar checker"))
            }
            if app.repetitions {
                separator
                Button { showRepetitions.toggle() } label: {
                    Text(tight ? "\(bridge.closeRepetitions)" : "\(bridge.closeRepetitions) " + L("close repetitions")).foregroundStyle(.pink)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showRepetitions, arrowEdge: .top) { RepetitionsPopover(bridge: bridge) }
            }
            if let work = bridge.tenseWork {
                separator
                HStack(spacing: 5) {
                    if bridge.tenseRunning { ProgressView().controlSize(.mini) }
                    Text(work)
                }
            }
            if let word = Collab.shared.sync.word {
                separator
                Button { app.showReaders() } label: { Text(word) }
                    .buttonStyle(.plain).foregroundStyle(Collab.shared.sync.isProblem ? Ink.warning : .secondary)
                    .help(Collab.shared.sync.help)
            } else if !Collab.shared.canSync, !Collab.shared.isLocalOnly(session), !session.repoStatus.linked, session.bookCounts.words >= 1000, !ExampleBook.isExample(session.root) {
                // (Not on a book barely begun: there is nothing yet to keep safe, and it reads as a warning.)
                // The book lives on this Mac only: said once, quietly, and an open door to Musset Sync.
                separator
                Button { app.offerSync(for: session) } label: {
                    if compact { Image(systemName: "icloud.slash") } else { Label(L("Not synced"), systemImage: "icloud.slash") }
                }
                .buttonStyle(.plain)
                .help(L("This book lives on this Mac only. Musset Sync keeps it on all your Macs, safe, with its history."))
                .accessibilityLabel(L("Not synced"))
                .contextMenu {
                    Button(L("Keep this book on this Mac only")) { Collab.shared.setLocalOnly(session, true) }
                }
            }
            if let e = session.lastError {
                separator
                HStack(spacing: 5) {
                    Text(e).foregroundStyle(Ink.error).lineLimit(1).frame(maxWidth: tight ? 70 : compact ? 150 : 260).help(e)
                    Button { session.lastError = nil } label: {
                        Image(systemName: "xmark.circle.fill").font(.ui(12)).frame(width: 18, height: 20).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help(L("Close")).accessibilityLabel(L("Close"))
                }
            }
            if !session.repoStatus.isRepo {
                separator
                Text(L("history off")).foregroundStyle(Ink.warning)
            } else if session.pendingCommit {
                separator
                Image(systemName: "circle.dotted").help(L("Saved"))
            }
        }
        .font(.ui(12).monospacedDigit())
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14).frame(height: 28)
        .fixedSize()
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Ink.hairline))
        .shadow(color: .black.opacity(0.06), radius: 12, y: 4)
    }

    /// The proofreader has something to say: it is working, it stumbled, it found something, or it is switched off.
    private var proofSpeaks: Bool {
        !proof.enabled || proof.running > 0 || proof.issueCount > 0 || proof.lastError != nil || proof.languageToolError != nil
    }

    private var separator: some View { Rectangle().fill(Ink.hairline).frame(width: 1, height: 12) }

    @ViewBuilder private var proofSummary: some View {
        HStack(spacing: 6) {
            if proof.running > 0 { ProgressView().controlSize(.mini) }
            if proof.languageToolError != nil { Image(systemName: "exclamationmark.triangle").foregroundStyle(Ink.warning) }
            if !proof.enabled {
                Text(L("proofreading off"))
            } else {
                // The grammar checker runs on this Mac, so its count stays when the AI is unavailable.
                let ai = proof.issueCount - proof.languageToolCount
                if proof.lastError != nil { Text(L("AI paused")).foregroundStyle(Ink.warning) }
                else if ai > 0 { Text("\(ai) " + L("to review")).foregroundStyle(.purple) }
                if proof.languageToolCount > 0 { Text("\(proof.languageToolCount) " + L("grammar")).foregroundStyle(.blue) }
            }
        }
    }
}

/// The open chapter's count in the status pill, recounted once typing pauses rather than on each keystroke.
/// A click on it changes the unit, here and everywhere.
private struct ChapterCount: View {
    let session: BookSession
    @State private var count: TextCounts?
    @State private var chapter: String?

    var body: some View {
        Button { CountUnit.cycle() } label: {
            Text((count ?? .zero).label).foregroundStyle(.primary).underline(true, pattern: .dot, color: .secondary.opacity(0.6))
        }
        .buttonStyle(.plain)
        .help(L("Book: \(session.bookCounts.label)") + (session.wordsToday > 0 ? " · " + L("+\(session.wordsToday) today") : "") + "\n" + CountUnit.help)
        .task(id: session.text) {
            // Another chapter (or the first count): at once. While typing: when the hand stops.
            if count != nil, chapter == session.selectedChapterID {
                try? await Task.sleep(for: .milliseconds(300))
                if Task.isCancelled { return }
            }
            count = session.textCounts
            chapter = session.selectedChapterID
        }
    }
}

/// The version being written, beside the chapter in the breadcrumb. Green: it is the book's. Its menu holds
/// everything about versions, and it is always there: a chapter with a single version shows it too, to try another.
struct VersionChip: View {
    let app: AppState
    @Bindable var session: BookSession
    @State private var renaming: String?
    @State private var newName = ""

    var body: some View {
        if session.versions.count <= 1, let ch = session.selectedChapter {
            // A single version: the same chip, named, with the way to start another.
            PopMenu(sections: [PopSection(title: L("Versions"), items: [
                PopItem(title: session.words.newVersion) { app.showTryVersion = true }])]) {
                HStack(spacing: 6) {
                    Circle().fill(Ink.added).frame(width: 7, height: 7)
                    Text(BookSession.versionLabel(ch.activeVersion)).font(.ui(12)).lineLimit(1)
                    Image(systemName: "chevron.down").font(.ui(8, .semibold)).foregroundStyle(.secondary)
                }
                .padding(.leading, 7).padding(.trailing, 8).frame(height: 22)
                .background(Ink.panel, in: Capsule())
                .overlay(Capsule().strokeBorder(Ink.hairline))
            }
            .help(L("Versions of this chapter"))
        } else if let ch = session.selectedChapter, let open = session.editingVersion {
            let inBook = open == ch.activeVersion
            let label = BookSession.versionLabel(open)
            PopMenu(sections: sections(ch, open: open, inBook: inBook, label: label)) {
                HStack(spacing: 6) {
                    if inBook { Circle().fill(Ink.added).frame(width: 7, height: 7) }
                    else { Circle().strokeBorder(.secondary, lineWidth: 1.2).frame(width: 7, height: 7) }
                    Text(label).font(.ui(12)).lineLimit(1)
                    Image(systemName: "chevron.down").font(.ui(8, .semibold)).foregroundStyle(.secondary)
                }
                .padding(.leading, 7).padding(.trailing, 8).frame(height: 22)
                .background(Ink.panel, in: Capsule())
                .overlay(Capsule().strokeBorder(Ink.hairline))
            }
            .help(inBook ? L("This version is in the book")
                         : L("You are writing another version: the book still has « \(BookSession.versionLabel(ch.activeVersion)) »"))
            .alert(L("Rename the version"), isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField(L("Name"), text: $newName)
                Button("OK") { if let v = renaming { session.renameVersion(v, to: newName) }; renaming = nil }
                Button(L("Cancel"), role: .cancel) { renaming = nil }
            }
        }
    }

    private func sections(_ ch: ChapterEntry, open: String, inBook: Bool, label: String) -> [PopSection] {
        let versions = session.versions.map { v in
            PopItem(title: BookSession.versionLabel(v), checked: v == open, dot: v == ch.activeVersion ? Ink.added : nil,
                    subtitle: v == ch.activeVersion ? L("in the book") : nil) { session.openVersion(v) }
        }
        var tools = [PopItem(title: session.words.newVersion) { app.showTryVersion = true }]
        if session.reference != nil {
            tools.append(PopItem(title: L("Close Side by Side")) { session.showBeside(nil) })
        } else {
            // Decided when clicked, from the version open then: the book's if one writes another, else the first other one.
            tools.append(PopItem(title: L("Side by Side")) {
                let now = session.editingVersion
                let book = session.selectedChapter?.activeVersion
                session.showBeside(now != book ? book : session.versions.first { $0 != now })
            })
        }
        var this: [PopItem] = []
        if !inBook { this.append(PopItem(title: L("Put « \(label) » in the Book")) { session.putInBook(session.editingVersion ?? open) }) }
        this.append(PopItem(title: L("Rename « \(label) »…")) { let v = session.editingVersion ?? open; newName = BookSession.versionLabel(v); renaming = v })
        if !inBook {
            this.append(PopItem(title: L("Move « \(label) » to the Trash"),
                                subtitle: L("The book's Trash keeps it")) { session.versionToTrash(session.editingVersion ?? open) })
        }
        return [PopSection(title: L("Versions of « \(ch.title) »"), items: versions),
                PopSection(items: tools), PopSection(items: this)]
    }
}

/// How to get out, said once when kiosk mode starts, then gone.
private struct KioskHint: View {
    let on: Bool
    @State private var shown = false

    var body: some View {
        Group {
            if shown {
                Text(L("Kiosk mode · \(AppCommand.glyphs("view.kiosk")) to leave"))
                    .font(.ui(12, .medium)).foregroundStyle(.secondary)
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(Ink.hairline))
                    .padding(.top, 14)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .allowsHitTesting(false)
            }
        }
        .task(id: on) {
            guard on else { withAnimation { shown = false }; return }
            withAnimation(.easeOut(duration: 0.3)) { shown = true }
            try? await Task.sleep(for: .seconds(3))
            withAnimation(.easeIn(duration: 0.6)) { shown = false }
        }
    }
}

/// After a prefix (⌃K, ⌃Q, ⌃X, Esc, d…), if one hesitates: what may follow.
struct KeyHintCard: View {
    let hint: KeyHint
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(hint.title + " …").font(.uiMono(12).weight(.semibold))
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], alignment: .leading, spacing: 6) {
                ForEach(hint.items, id: \.self) { item in
                    HStack(spacing: 8) {
                        Text(item.key).font(.uiMono(11)).padding(.horizontal, 6).frame(minWidth: 26, minHeight: 18)
                            .background(Ink.panel, in: RoundedRectangle(cornerRadius: 4))
                            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Ink.hairline))
                        Text(item.label).font(.ui(12)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 460)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Ink.hairline))
        .shadow(color: .black.opacity(0.16), radius: 18, y: 8)
        .allowsHitTesting(false)
    }
}


struct DoneChapter: Identifiable { let id: String }
