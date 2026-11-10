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
    @State private var planner = ScenePlanner()
    /// The interface rebuilds when its language changes.
    @AppStorage(UILang.key) private var uiLanguage = UILang.system.rawValue

    private var covered: Bool { app.showPlotGrid || app.specialPage != nil || app.showOverview || app.bibleRoute != nil }

    var body: some View {
        ZStack {
            if let session = app.current {
                VStack(spacing: 0) {
                TitleBar(app: app, session: session, bridge: bridge)
                // A flat column, not the system sidebar: full height, flush, one hairline.
                HStack(spacing: 0) {
                    if app.showSidebar && !app.showPlotGrid {
                        ChapterSidebar(session: session, app: app, bridge: bridge,
                                       scenePlanner: { engine in planner.propose(session, engine: engine) })
                            .frame(width: 256)
                            .transition(.move(edge: .leading))
                        Divider()
                    }
                    HStack(spacing: 0) {
                        // The grid covers the editor, which stays alive underneath (caret, undo).
                        ZStack {
                            EditorColumn(app: app, session: session, bridge: bridge, proof: proof,
                                         fontName: fontName, fontSize: fontSize, columnWidth: columnWidth)
                                .opacity(covered ? 0 : 1)
                                .allowsHitTesting(!covered)
                                .onChange(of: covered || app.showHome, initial: true) { _, hidden in bridge.covered = hidden }
                            if app.showOverview {
                                OverviewView(app: app, session: session, bridge: bridge, analyst: analyst, planner: planner, proof: proof)
                            } else if case .folder(let folder)? = app.bibleRoute {
                                BibleFolderView(app: app, session: session, bridge: bridge, folder: folder).id(folder)
                            } else if case .entry(let path)? = app.bibleRoute, let entry = session.bible.entry(path: path) {
                                BibleEntryView(app: app, session: session, bridge: bridge, entry: entry).id(path)
                            } else if app.showPlotGrid {
                                PlotGridView(app: app, session: session, bridge: bridge, analyst: analyst, planner: planner)
                                    .transition(.opacity)
                            } else if let page = app.specialPage {
                                SpecialPageView(app: app, session: session, page: page)
                                    .transition(.opacity)
                            }
                        }
                        if app.showInspector {
                            // The handle sits on the panel's edge, so the panel keeps its exact width.
                            InspectorPanel(app: app, session: session, bridge: bridge, chat: chat, pangram: pangram,
                                           proof: proof, annotator: annotator, analyst: analyst, planner: planner)
                                .frame(width: inspectorWidth)
                                .overlay(alignment: .leading) { PanelResizeHandle(width: $inspectorWidth, range: 340...900).offset(x: -3) }
                                .transition(.move(edge: .trailing))
                        }
                    }
                }
                }
                .ignoresSafeArea(.container, edges: .top)
                .onAppear { chat.attach(session.root); proof.attach(session); openScreenFromLaunchArguments() }
                .onChange(of: session.root) { _, r in chat.attach(r); proof.attach(session); pangram.clear(bridge) }
                .onChange(of: session.selectedChapterID) { _, _ in pangram.clear(bridge) }
                .onChange(of: app.showSearch) { _, on in if !on { bridge.setSearchQuery("") } }
                // Opening a note's thread (margin dot, hover preview, context menu) shows the Edits & Comments tab.
                .onChange(of: bridge.openNoteID) { _, id in
                    if id != nil { withAnimation { app.inspectorTab = .edits; app.showInspector = true } }
                }
                .sheet(isPresented: $app.showStory) { StoryView(app: app, session: session) }
                .sheet(item: $app.newPiste) { NewPisteSheet(session: session, start: $0) }
                .sheet(item: $app.newJalon) { JalonSheet(session: session, start: $0) }
                .sheet(item: $app.takingBack) { TakeBackView(session: session, piste: $0) }
                .sheet(item: $app.bringing) { TakeBackView(session: session, point: $0) }
                .sheet(isPresented: $app.showProofExceptions) { ProofExceptionsSheet(proof: proof) }
                .sheet(isPresented: $app.showExport, onDismiss: { app.exportAt = nil }) {
                    ExportSheet(session: session, preview: app.exportAt == nil ? { app.review.scope = .book; app.specialPage = nil; app.showPlotGrid = false; app.reviewMode = true } : nil,
                                at: app.exportAt)
                }
                .sheet(isPresented: $app.showWordReview) { WordReviewSheet(app: app, session: session, bridge: bridge) }
                .sheet(isPresented: $planner.showing) { ScenePlanSheet(planner: planner, session: session, bridge: bridge) }
                .sheet(isPresented: $app.showBookSettings, onDismiss: { app.bookSettingsSection = nil }) {
                    BookSettingsView(app: app, session: session, proof: proof, startSection: app.bookSettingsSection)
                }
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
                // Opening a chapter leaves a special page.
                .onChange(of: session.selectedChapterID) { _, _ in app.specialPage = nil }
                .opacity(app.showHome ? 0 : 1)
                .allowsHitTesting(!app.showHome)
            }
            if app.showHome || app.current == nil {
                if app.libraryPaths.isEmpty { WelcomeView(app: app) } else { HomeView(app: app) }
            }
        }
        .overlay(alignment: .top) { KioskHint(on: app.kiosk) }
        .overlay(alignment: .bottom) {
            ZStack { if let session = app.current { VersionSwitchToast(session: session) } }
                .animation(.easeOut(duration: 0.25), value: app.current?.lastVersionSwitch)
        }
        .onAppear { CaptureController.shared.app = app; CaptureController.shared.install(); Collab.shared.start(app) }
        .sheet(isPresented: $app.showNewBook) { WelcomeView(app: app, sheet: true) }
        .sheet(isPresented: $app.showTryVersion) { if let session = app.current { TryVersionSheet(session: session) } }
        .sheet(isPresented: $app.showHelpers) { AIHelpersView() }
        .sheet(isPresented: $app.showAccount) { AccountSheet(app: app) }
        .tint(Ink.accent)
        .id(uiLanguage)
        .sheet(item: $app.pendingSetup) { SetupSheet(app: app, setup: $0) }
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
            case "grid": app.showPlotGrid = true
            case "special": app.specialPage = .cover
            case "export": app.showExport = true
            case "settings": app.showBookSettings = true
            case "palette": app.showQuickOpen = true
            case "notes": app.inspectorTab = .edits; app.showInspector = true
            case "partner": app.inspectorTab = .chat; app.showInspector = true
            case "home": app.showHome = true
            case "account": app.showAccount = true
            case "sharing": app.bookSettingsSection = .sharing; app.showBookSettings = true
            case "blame": bridge.blameOn = true
            case "find": bridge.setSearchQuery("elle"); bridge.openFind(replace: true)
            case "overview": app.openOverview()
            case "bible": app.show(.folder("personnages"))
            case "capture": CaptureController.shared.toggle()
            case "helpers": app.showHelpers = true
            case "sheet": if let e = app.current?.bible.entries.first(where: { !$0.isFile }) { app.show(.entry(e.path)) }
            default: break
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
                    editor(width: geo.size.width - (side ? previewWidth : 0))
                    if side { Color.clear.frame(width: previewWidth) }
                }
                .opacity(app.reviewMode && !side ? 0 : 1)
                .allowsHitTesting(!app.reviewMode || side)
                if app.reviewMode {
                    HStack(spacing: 0) {
                        if side { Divider() }
                        ReviewView(app: app, session: session, model: app.review, bridge: bridge, sideBySide: side)
                    }
                    .frame(width: previewWidth)
                }
            }
        }
        .navigationTitle(session.selectedChapter?.title ?? session.title)
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
            if session.reference != nil, !app.reviewMode {
                SplitHandle(width: $referenceWidth, total: width)
                ReferencePane(session: session, fontName: fontName, fontSize: fontSize,
                              columnWidth: columnWidth, paragraphSpacing: paragraphSpacing)
                    .frame(width: SplitHandle.clamp(referenceWidth, total: width))
            }
        }
    }

    private var writing: some View {
        VStack(spacing: 0) {
            if bridge.findOpen { FindBar(bridge: bridge, text: session.text) }
            HStack(spacing: 0) {
                ZenEditorView(session: session, bridge: bridge, fontName: fontName, fontSize: fontSize,
                              columnWidth: columnWidth, focusMode: app.focusMode, typewriter: app.typewriter,
                              lineNumbers: app.lineNumbers, repetitions: app.repetitions, repetitionWindow: repetitionWindow,
                              paragraphSpacing: paragraphSpacing)
                    .frame(minWidth: 280)
                if app.minimap {
                    Minimap(bridge: bridge)
                        .frame(width: 72)
                        .help(L("The whole chapter: click or drag to move"))
                }
            }
            .overlay(alignment: .top) {
                if bridge.trackChanges { RevisionBar(bridge: bridge).padding(.top, 12) }
                else if app.formatBar && !app.focusMode { FormatBar(bridge: bridge).padding(.top, 12) }
            }
        }
        .overlay(alignment: .bottomLeading) {
            if bridge.blameOn { AttributionBar(bridge: bridge, session: session).padding([.bottom, .leading], 16) }
        }
        .overlay(alignment: .bottom) { if let hint = bridge.keyHint { KeyHintCard(hint: hint).padding(.bottom, 56) } }
        // In the corner, beside the column rather than over its last lines.
        .overlay(alignment: .bottomTrailing) { StatusBar(app: app, session: session, proof: proof, bridge: bridge).padding([.bottom, .trailing], 16) }
        .background(Color(nsColor: .textBackgroundColor))
    }

}

/// The window's title bar, drawn by the app at the design's 44 points: room for the window buttons,
/// the chapters toggle, "Book / Chapter / Scene", then Write/Read, the status, ⌘K and the panel.
struct TitleBar: View {
    let app: AppState
    let session: BookSession
    let bridge: EditorBridge
    static let height: CGFloat = 44

    /// The width of the controls on the right, as laid out: they vary with the track, the versions, the corrections.
    @State private var controlsWidth: CGFloat = 0
    /// The window buttons and the chapters toggle; in kiosk mode there are no window buttons.
    private var leading: CGFloat { app.kiosk ? 48 : 112 }
    @AppStorage("helpersSeen") private var helpersSeen = false

    var body: some View {
        // The breadcrumb on the left, beside the chapters toggle. Never under the controls: it truncates first.
        GeometryReader { geo in
          let beside = geo.size.width - leading - controlsWidth - 16
            HStack(spacing: 10) {
                Color.clear.frame(width: app.kiosk ? 4 : 64)
                iconButton("house", L("All books (⇧⌘H)")) { app.showHome = true }
                iconButton("sidebar.left", L("Show or hide the chapters (⌘1)")) { withAnimation { app.showSidebar.toggle() } }
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
            if !AIStatus.shared.isOn && !helpersSeen {
                Button(L("A second reader?")) { app.showHelpers = true }.buttonStyle(.link).font(.ui(12))
            }
            if session.git.isRepo { PisteMenu(app: app, session: session) }
            if bridge.pendingRevisions > 0 {
                PopMenu([PopItem(title: L("Next correction")) { bridge.textView?.nextRevision() },
                         PopItem(title: L("Accept all")) { bridge.textView?.decideRevision(accept: true, all: true) },
                         PopItem(title: L("Reject all")) { bridge.textView?.decideRevision(accept: false, all: true) }]) {
                    HStack(spacing: 6) {
                        Circle().fill(Color(red: 0.76, green: 0.22, blue: 0.18)).frame(width: 6, height: 6)
                        Text("\(bridge.pendingRevisions) " + (bridge.pendingRevisions == 1 ? L("correction") : L("corrections")))
                            .font(.ui(12))
                    }
                    .padding(.leading, 7).padding(.trailing, 9).frame(height: 22)
                    .background(Ink.panel, in: Capsule())
                }
                .help(L("Corrections in this chapter"))
            }
            Segmented(options: [(0, L("Write")), (1, L("Revise")), (2, L("Read"))],
                      selection: Binding(get: { app.reviewMode ? 2 : (bridge.trackChanges ? 1 : 0) },
                                         set: { mode in app.reviewMode = mode == 2; bridge.trackChanges = mode == 1 }))
                .frame(width: 204)
                .help(L("Write · Revise: changes become corrections (⇧⌘E) · Read: as printed (⇧⌘R)"))
            if let ch = session.selectedChapter {
                PopMenu(ChapterStatus.allCases.map { st in PopItem(title: st.label, checked: (ch.status ?? .draft) == st, dot: st.dot) { session.setStatus(ch.id, st) } }) {
                    HStack(spacing: 6) { StatusDot(status: ch.status ?? .draft); Text((ch.status ?? .draft).label).font(.ui(12)) }
                        .padding(.leading, 7).padding(.trailing, 9).frame(height: 22)
                        .background(Ink.panel, in: Capsule())
                }
                .help(L("Chapter status"))
            }
            Button { app.showQuickOpen = true } label: {
                HStack(spacing: 10) {
                    if !compact { Text(L("Search or command")).font(.ui(12)).foregroundStyle(.secondary) }
                    Kbd("⌘K")
                }
                .padding(.leading, compact ? 6 : 10).padding(.trailing, 6).frame(height: 28)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Ink.hairline))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("Command bar (⌘K)"))
            iconButton("sidebar.right", InspectorTab.edits.label + ", Chat, Stats, Plan, " + InspectorTab.history.label + " (⌘2 ⌘3 ⌘4 ⌘6 ⌘7)") { withAnimation { app.showInspector.toggle() } }
        }
    }

    private func iconButton(_ icon: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.ui(14)).foregroundStyle(.secondary).frame(width: 28, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(help)
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

/// "Book / Chapter / Scene" in the title bar. The book opens its settings and special pages.
struct Breadcrumb: View {
    let app: AppState
    let session: BookSession
    let bridge: EditorBridge

    private var scene: String? {
        guard let id = session.selectedChapterID, let scenes = session.scenes[id], scenes.count > 1 else { return nil }
        return Scenes.scene(at: bridge.selectedRange.location, in: scenes)?.title
    }

    var body: some View {
        HStack(spacing: 7) {
            Menu {
                Button(L("Book settings…")) { app.showBookSettings = true }
                Button(L("Cover & special pages")) { app.specialPage = .cover }
                Button(L("Plot grid", ctx: "Grille d’intrigue")) { app.showPlotGrid = true }
                Divider()
                ForEach(Array(app.books.enumerated()), id: \.element.path) { i, b in
                    Button(b.title) { app.switchToBook(index: i) }
                }
                Divider()
                Button(L("New book…")) { app.showNewBook = true }
                Button(L("Open a book folder…")) { app.addBookViaPanel() }
                Button(L("Musset account…")) { app.showAccount = true }
                Button(L("Share this book…")) { app.bookSettingsSection = .sharing; app.showBookSettings = true }
            } label: { Text(session.title).foregroundColor(.secondary) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().tint(.secondary)
            if let page = app.specialPage {
                Text("/").foregroundStyle(.tertiary)
                Text(page.label).fontWeight(.medium)
            } else if let ch = session.selectedChapter {
                Text("/").foregroundStyle(.tertiary)
                Text(ch.title).foregroundStyle(scene == nil ? .primary : .secondary).fontWeight(scene == nil ? .medium : .regular)
                if session.piste == nil { VersionChip(app: app, session: session).fixedSize() }
                if let scene {
                    Text("/").foregroundStyle(.tertiary)
                    Text(scene).fontWeight(.medium)
                }
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
                            .background(bridge.focusedStem == c.stem ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 5))
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

/// Auto-corrections made this session, each one revertible.
struct CorrectionsPopover: View {
    let proof: AutoProofreader

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("Auto-corrected")).font(.ui(13, .semibold))
            if proof.corrections.isEmpty {
                Text(L("Nothing yet.")).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(proof.corrections) { c in
                        HStack(alignment: .firstTextBaseline) {
                            Text(c.original).strikethrough().foregroundStyle(.secondary)
                            Image(systemName: "arrow.right").font(.ui(11)).foregroundStyle(.tertiary)
                            Text(c.replacement)
                            Spacer()
                            Button(L("Undo")) { proof.revert(c) }.controlSize(.small)
                        }
                        .help(LocalProofreader.shown(c.reason))
                    }
                }
            }
            .frame(maxHeight: 260)
            ForEach([proof.lastError, proof.languageToolError].compactMap { $0 }, id: \.self) { e in
                Text(e).font(.ui(11)).foregroundStyle(.orange).textSelection(.enabled)
            }
            Divider()
            Toggle(L("Correct obvious mistakes automatically", ctx: "Corriger d’office les fautes évidentes"), isOn: Binding(get: { proof.autoCorrect }, set: { proof.autoCorrect = $0 }))
            Toggle(L("Apply the book's typography (spaces, « », ’, —, …)"), isOn: Binding(get: { proof.typography }, set: { proof.typography = $0 }))
            if proof.typographyFixed > 0 {
                Text(L("\(proof.typographyFixed) typographic fixes this session") + " " + L("(⌘Z undoes the last batch).")).font(.ui(11)).foregroundStyle(.secondary)
            }
            Toggle(L("Proofread while I write", ctx: "Relire pendant que j’écris"), isOn: Binding(get: { proof.enabled }, set: { proof.enabled = $0 }))
            HStack {
                Button(L("Check this chapter again")) { proof.recheckAll() }
                Button(L("Dictionary & exceptions…")) { NotificationCenter.default.post(name: .mussetProofExceptions, object: nil) }
            }
        }
        .padding(14)
        .frame(width: 380)
    }
}

/// The counters, gathered in a small floating pill at the bottom of the page. It fades while you type
/// and comes back when you stop.
struct StatusBar: View {
    let app: AppState
    let session: BookSession
    let proof: AutoProofreader
    let bridge: EditorBridge
    @State private var showCorrections = false
    @State private var showRepetitions = false
    @State private var typing = false
    @State private var fade: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 12) {
            if let mode = bridge.keyStatus {
                Text(mode).font(.uiMono(11).weight(.medium)).foregroundStyle(.primary)
                    .padding(.horizontal, 6).frame(height: 18)
                    .background(Ink.panel, in: RoundedRectangle(cornerRadius: 4))
                separator
            }
            Text("\(session.wordCount.ui) " + L("words"))
                .help(L("Book: ") + "\(session.bookWordCount.ui)" + (session.wordsToday > 0 ? " · +\(session.wordsToday) " + L("today") : ""))
            if let work = bridge.tenseWork {
                separator
                HStack(spacing: 5) {
                    if bridge.tenseRunning { ProgressView().controlSize(.mini) }
                    Text(work)
                }
            }
            if let word = Collab.shared.sync.word {
                separator
                Button { app.bookSettingsSection = .sharing; app.showBookSettings = true } label: { Text(word) }
                    .buttonStyle(.plain).foregroundStyle(Collab.shared.sync.isProblem ? Color.orange : .secondary)
                    .help(Collab.shared.sync.help)
            }
            if let e = session.lastError {
                separator
                Text(e).foregroundStyle(.red).lineLimit(1).frame(maxWidth: 260)
                    .onTapGesture { session.lastError = nil }
            }
            let openNotes = session.notes.notes.filter { $0.status == .open && !$0.kind.isPositive }.count
            if openNotes > 0 {
                separator
                Button { withAnimation { app.toggleInspector(.edits) } } label: { Text("\(openNotes) " + (openNotes == 1 ? L("note") : L("notes"))) }
                    .buttonStyle(.plain).help(InspectorTab.edits.label + " (⌘2)")
            }
            if app.repetitions {
                separator
                Button { showRepetitions.toggle() } label: {
                    Text("\(bridge.closeRepetitions) " + L("close repetitions")).foregroundStyle(.pink)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showRepetitions, arrowEdge: .top) { RepetitionsPopover(bridge: bridge) }
            }
            separator
            Button { withAnimation { app.inspectorTab = .edits; app.showInspector = true } } label: { proofSummary }
                .buttonStyle(.plain)
                .help([proof.lastError, proof.languageToolError].compactMap { $0 }.joined(separator: "\n").nilIfEmpty
                      ?? L("Proofreading: purple = AI suggestion, blue = grammar checker"))
            if !session.git.isRepo {
                separator
                Text(L("no git")).foregroundStyle(.orange)
            } else if session.pendingCommit {
                separator
                Image(systemName: "circle.dotted").help(L("Saved, commit pending"))
            }
        }
        .font(.ui(12).monospacedDigit())
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14).frame(height: 28)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Ink.hairline))
        .shadow(color: .black.opacity(0.06), radius: 12, y: 4)
        .opacity(typing ? 0 : 1)
        .animation(.easeInOut(duration: 0.35), value: typing)
        .onChange(of: session.text) { _, _ in
            typing = true
            fade?.cancel()
            fade = Task { try? await Task.sleep(nanoseconds: 1_600_000_000); if !Task.isCancelled { typing = false } }
        }
    }

    private var separator: some View { Rectangle().fill(Ink.hairline).frame(width: 1, height: 12) }

    @ViewBuilder private var proofSummary: some View {
        HStack(spacing: 6) {
            if proof.running > 0 { ProgressView().controlSize(.mini) }
            if proof.languageToolError != nil { Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange) }
            if !proof.enabled {
                Text(L("proofreading off"))
            } else {
                // The grammar checker runs on this Mac, so its count stays when the AI is unavailable.
                let ai = proof.issueCount - proof.languageToolCount
                if proof.lastError != nil { Text(L("AI paused")).foregroundStyle(.orange) }
                else if ai > 0 { Text("\(ai) " + L("to review")).foregroundStyle(.purple) }
                if proof.languageToolCount > 0 { Text("\(proof.languageToolCount) " + L("grammar")).foregroundStyle(.blue) }
                if proof.issueCount == 0 && proof.running == 0 && proof.lastError == nil { Text(L("no issues")) }
            }
        }
    }
}

/// The version being written, beside the chapter in the breadcrumb. Green: it is the book's. Its menu holds
/// everything about versions. A chapter with a single version shows only a faint icon, to try another.
struct VersionChip: View {
    let app: AppState
    @Bindable var session: BookSession
    @State private var renaming: String?
    @State private var newName = ""

    var body: some View {
        if session.versions.count <= 1, session.selectedChapter != nil {
            PopMenu(sections: [PopSection(title: L("Versions"), items: [
                PopItem(title: L("Try Something Else…"),
                        subtitle: L("Another version of this chapter")) { app.showTryVersion = true }])]) {
                HStack(spacing: 4) {
                    Image(systemName: "square.on.square").font(.ui(11))
                    Image(systemName: "chevron.down").font(.ui(8, .semibold))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7).frame(height: 22)
                .background(Ink.panel, in: Capsule())
                .contentShape(Capsule())
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
        var tools = [PopItem(title: L("Try Something Else…")) { app.showTryVersion = true }]
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

struct ImportRevisionsSheet: View {
    let session: BookSession
    let candidates: [(name: String, url: URL)]
    @State private var chosen: Set<String> = []
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Import revisions")).font(.ui(13, .semibold))
            Text(L("Copies these files in as versions of this chapter. The originals are not moved or changed."))
                .font(.ui(12)).foregroundStyle(.secondary)
            if candidates.isEmpty {
                Text(L("No loose revision files found for this chapter.")).foregroundStyle(.secondary).padding(.vertical)
            } else {
                List(candidates, id: \.url) { c in
                    Toggle(isOn: Binding(get: { chosen.contains(c.url.path) }, set: { if $0 { chosen.insert(c.url.path) } else { chosen.remove(c.url.path) } })) {
                        VStack(alignment: .leading) {
                            Text(c.name)
                            Text(c.url.path.replacingOccurrences(of: session.root.path + "/", with: "")).font(.ui(11)).foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(minHeight: 260)
            }
            HStack {
                Button(L("Select all")) { chosen = Set(candidates.map(\.url.path)) }.disabled(candidates.isEmpty)
                Spacer()
                Button(L("Cancel")) { dismiss() }
                Button(L("Import \(chosen.count)")) {
                    session.importRevisions(candidates.filter { chosen.contains($0.url.path) })
                    dismiss()
                }
                .keyboardShortcut(.defaultAction).disabled(chosen.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}

/// How to get out, said once when kiosk mode starts, then gone.
private struct KioskHint: View {
    let on: Bool
    @State private var shown = false

    var body: some View {
        Group {
            if shown {
                Text(L("Kiosk mode · ⌃⌘K to leave"))
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
