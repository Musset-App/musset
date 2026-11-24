import AppKit
import Observation

/// The library of book folders and the currently open book.
@MainActor
@Observable
final class AppState {
    var libraryPaths: [String] {
        didSet { UserDefaults.standard.set(libraryPaths, forKey: "libraryPaths") }
    }
    var current: BookSession?
    /// Folder waiting for first-open setup (manifest seeding, git init).
    var pendingSetup: PendingSetup?
    /// The command bar (⌘K).
    var showQuickOpen = false
    /// Asking for a name to keep the window's layout under.
    var namingLayout = false
    /// The command bar opened by ⇧⌘O: only what can be opened, and it opens in the next pane.
    var openBeside = false
    /// Asked from elsewhere (the toolbar, the command bar): the Readers page opens its invitation.
    var inviteRequested = false
    var showNewBook = false
    /// Musset Sync, offered; with the book to put online once paid.
    var showSyncOffer = false
    var syncOfferBook: URL?
    /// An invitation opened before signing in: accepted with the account.
    var pendingInvitation: String?
    /// The account lives in Home: the section its main area shows.
    var homeSection = HomeSection.books
    /// The book settings page to open on (sharing, for instance).
    var bookSettingsSection: BookSettingsView.Section?
    /// Book-wide search (⇧⌘F) shown in the sidebar.
    var showSearch = false
    /// The sheet that makes a new version of the open chapter.
    var showTryVersion = false
    var searchQuery = ""
    var searchAllBooks = false
    var searchFocusRequest = 0
    var showExport = false
    /// The sheet that brings an editor's corrected Word file back into the book.
    var showWordReview = false
    /// A past state being brought into the manuscript.
    var bringing: BringPoint?
    /// A search to run when the Historique tab shows (« passage perdu »).
    var historyQuery: String?
    /// A track to open, from where; a milestone to set, where; a track being taken back.
    var newPiste: TrackStart?
    var newJalon: TrackStart?
    var takingBack: Piste?
    /// Export the book as it was at this milestone.
    var exportAt: GitService.Tag?
    var showProofExceptions = false
    /// The book's rubric, opened from the AI reader's tab or the command bar.
    var showRubric = false
    var showSidebar = true
    /// Reading mode: the text typeset as printed (Typst), instead of the editor.
    var reviewMode = false
    /// Every book and the Musset account, over whatever is open. Leaving it goes back to the books for next time.
    var showHome = false { didSet { if !showHome { homeSection = .books } } }
    /// The optional AI helpers, with what they bring.
    var showHelpers = false
    /// One line at the foot of the window, in the first days (`FirstSteps`).
    var notice: FirstNotice?
    /// The panes and tabs of the open book's window, and the tab shown in the pane one is in.
    var workspace: Workspace? { current?.workspace }
    var activeTab: PaneTab? { workspace?.activeTab }
    /// Opens one of the book's pages in the pane one is in.
    func open(_ tab: PaneTab) { workspace?.open(tab) }

    /// The book's settings, a page of its home; on one of their sections when asked.
    func showSettings(_ section: BookSettingsView.Section? = nil) {
        bookSettingsSection = section
        open(OverviewTab.settings.tab)
    }

    /// Who reads the book, a page of its home; `inviting` goes straight to the invitation when the book can be shared.
    func showReaders(inviting: Bool = false) {
        inviteRequested = inviting
        open(OverviewTab.readers.tab)
    }

    /// A book is open and in front (not under Home): what the book's menu commands need.
    var hasBook: Bool { current != nil && !showHome }
    /// The pane one is in shows a chapter: what Format, Find and the other editor commands need.
    var hasEditor: Bool { Self.editorCommands(book: hasBook, tab: workspace?.activeTab) }
    /// The pane one is in shows a chapter of several scenes: what its scene cards need.
    var hasScenes: Bool {
        guard hasEditor, let id = workspace?.activeTab?.chapterID else { return false }
        return (current?.scenes[id]?.count ?? 0) > 1
    }
    /// Whether the editor's menu commands can act: a book in front, and a chapter in the pane one is in.
    static func editorCommands(book: Bool, tab: PaneTab?) -> Bool { book && tab?.isChapter == true }

    /// Back to the chapter being written, in its tab.
    func showChapter() {
        guard let id = current?.selectedChapterID else { return }
        workspace?.open(.chapter(id))
    }
    /// A character or a place being renamed (the preview sheet).
    var renaming: RenameTarget?
    struct RenameTarget: Identifiable { let path: String; var id: String { path } }

    // MARK: Windows

    /// Opens a window scene (set by the main window, which has SwiftUI's `openWindow`).
    @ObservationIgnored var openWindow: ((WindowRef) -> Void)?
    /// The book's windows on screen now.
    @ObservationIgnored var shownWindows: Set<String> = []
    /// Where a window torn off should open (its top left, on screen).
    @ObservationIgnored var windowOrigins: [String: CGPoint] = [:]
    /// The app is quitting: windows closing now are kept for next time.
    @ObservationIgnored var quitting = false

    /// A book open in this run, by its folder's path.
    func loadedSession(_ path: String) -> BookSession? {
        if let s = sessions[path] { return s }
        return current.flatMap { $0.root.standardizedFileURL.path == path ? $0 : nil }
    }

    /// A tab in a window of its own.
    func openInNewWindow(_ tab: PaneTab, of session: BookSession, at point: CGPoint? = nil) {
        let id = session.newWindow(with: tab)
        if let point { windowOrigins[id] = point }
        openWindow?(WindowRef(bookPath: session.root.standardizedFileURL.path, windowID: id))
    }

    /// A tab dragged out of every window: it leaves its pane for a window of its own (unless it is its window's last).
    func tearOff(pane: String, index: Int, of session: BookSession, at point: CGPoint) {
        guard let from = session.owner(ofPane: pane), from.canCloseTab,
              let tab = from.panes.first(where: { $0.id == pane })?.tabs[safe: index] else { return }
        openInNewWindow(tab, of: session, at: point)
        from.close(index, in: pane)
    }

    /// The windows left open with the book, open again (those the system did not bring back itself).
    func reopenWindows(of session: BookSession) async {
        try? await Task.sleep(for: .milliseconds(600))
        let path = session.root.standardizedFileURL.path
        for id in session.savedWindowIDs where !shownWindows.contains(id) {
            openWindow?(WindowRef(bookPath: path, windowID: id))
        }
    }

    /// A click in the sidebar: in the pane one is in, or with ⌥ in a new tab, with ⌘ in the next pane.
    func open(_ tab: PaneTab, clicked current: () -> Void) {
        let place = OpenPlace.click
        guard place != .current, let session = self.current else { return current() }
        session.open(tab, in: place)
    }

    /// The same for one of the book's pages.
    func open(clicked tab: PaneTab) { open(tab) { self.open(tab) } }

    @ObservationIgnored let review = ReviewModel()

    /// The right-hand inspector (Notes, AI reader, Stats, Plan, History): open or closed, and on which tab.
    var showInspector = UserDefaults.standard.bool(forKey: "showInspector") {
        didSet { UserDefaults.standard.set(showInspector, forKey: "showInspector") }
    }
    var inspectorTab = InspectorTab(rawValue: UserDefaults.standard.string(forKey: "inspectorTab") ?? "") ?? .edits {
        didSet { UserDefaults.standard.set(inspectorTab.rawValue, forKey: "inspectorTab") }
    }

    /// Opens the inspector on `tab`, or closes it if it is already showing that tab.
    func toggleInspector(_ tab: InspectorTab) {
        if tab == .chat && !AIHome.shown { return }
        if showInspector && inspectorTab == tab { showInspector = false } else { inspectorTab = tab; showInspector = true }
    }
    /// Kiosk mode (⌃⌘K): Musset over the whole screen, nothing else on the Mac; all of Musset stays (title bar,
    /// panels, modes), only the window's frame and buttons go. Never kept across launches, so Musset can't open locked.
    var kiosk = false {
        didSet {
            guard oldValue != kiosk else { return }
            let window = NSApp.mainWindow ?? NSApp.windows.first { $0.isVisible && $0.canBecomeMain }
            if kiosk { Kiosk.enter(window) } else { Kiosk.leave(window) }
        }
    }

    var focusMode = UserDefaults.standard.bool(forKey: "focusMode") {
        didSet { UserDefaults.standard.set(focusMode, forKey: "focusMode") }
    }
    var typewriter = UserDefaults.standard.bool(forKey: "typewriter") {
        didSet { UserDefaults.standard.set(typewriter, forKey: "typewriter") }
    }
    var lineNumbers = UserDefaults.standard.object(forKey: "lineNumbers") as? Bool ?? false {
        didSet { UserDefaults.standard.set(lineNumbers, forKey: "lineNumbers") }
    }
    var repetitions = UserDefaults.standard.bool(forKey: "repetitions") {
        didSet { UserDefaults.standard.set(repetitions, forKey: "repetitions") }
    }
    var formatBar = UserDefaults.standard.object(forKey: "formatBar") as? Bool ?? true {
        didSet { UserDefaults.standard.set(formatBar, forKey: "formatBar") }
    }
    var minimap = UserDefaults.standard.object(forKey: "minimap") as? Bool ?? false {
        didSet { UserDefaults.standard.set(minimap, forKey: "minimap") }
    }
    var alert: String?

    /// Sessions kept alive so switching books is instant.
    @ObservationIgnored private var sessions: [String: BookSession] = [:]

    struct PendingSetup: Identifiable {
        let root: URL
        var manifest: BookManifest
        var initGit: Bool
        let isRepo: Bool
        var id: URL { root }
    }

    init() {
        libraryPaths = UserDefaults.standard.stringArray(forKey: "libraryPaths") ?? []
        // A test run hosted in the app must not open the book the author may be writing in.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        countLaunch()
        if let last = UserDefaults.standard.string(forKey: "lastBook"), libraryPaths.contains(last) {
            openBook(URL(fileURLWithPath: last))
        } else if let first = libraryPaths.first {
            openBook(URL(fileURLWithPath: first))
        }
    }

    /// The library's books by name. Asked for at each redraw of the breadcrumb and the menus: an open book says its
    /// own title, a closed one's manifest is read once (`closedManifest`), not decoded from disk each time.
    var books: [(path: String, title: String)] {
        libraryPaths.map { p in
            let title = (sessions[p]?.manifest ?? closedManifest(p))?.title ?? (p as NSString).lastPathComponent.capitalized
            return (p, title)
        }
    }

    func addBookViaPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = L("Open Book")
        panel.directoryURL = BookStore.defaultFolder
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { openBook(url) }
    }

    func openBook(_ url: URL) {
        let path = url.standardizedFileURL.path
        let store = BookStore(root: url)
        if !libraryPaths.contains(path) { libraryPaths.append(path) }
        if let s = sessions[path] { switchTo(s); return }
        if store.hasManifest, let m = try? store.loadManifest() {
            // In the app the window comes first and the book's counts follow; a test reads them right after opening.
            let s = BookSession(root: url, manifest: m, countsLater: ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil)
            sessions[path] = s
            switchTo(s)
            UltraFocus.recover(s)
        } else {
            let git = GitService(root: url)
            pendingSetup = PendingSetup(root: url, manifest: store.seedManifest(), initGit: !git.isRepo, isRepo: git.isRepo)
        }
    }

    /// Writes the confirmed manifest, makes the safety commit, and opens the book.
    func completeSetup(_ setup: PendingSetup) {
        pendingSetup = nil
        let store = BookStore(root: setup.root)
        let git = GitService(root: setup.root)
        do {
            if setup.initGit && !git.isRepo { try git.initRepo() }
            // Restore point of the chapters as they were, before Musset writes anything else.
            if git.isRepo {
                try git.commit(paths: setup.manifest.chapters.map(\.file), message: "musset: snapshot before first open")
            }
            try store.saveManifest(setup.manifest)
            if git.isRepo { try git.commit(paths: [".musset"], message: "musset: add book manifest") }
        } catch {
            alert = L("Setup failed: \(error.localizedDescription)")
        }
        let s = BookSession(root: setup.root, manifest: setup.manifest)
        sessions[setup.root.standardizedFileURL.path] = s
        switchTo(s)
    }

    func cancelSetup() {
        if let p = pendingSetup?.root.standardizedFileURL.path, sessions[p] == nil {
            libraryPaths.removeAll { $0 == p }
        }
        pendingSetup = nil
    }

    private func switchTo(_ s: BookSession) {
        if current !== s { current?.close(background: true) }
        current = s
        UserDefaults.standard.set(s.root.standardizedFileURL.path, forKey: "lastBook")
        Collab.shared.opened(s)
    }

    func switchToBook(index: Int) {
        guard libraryPaths.indices.contains(index) else { return }
        openBook(URL(fileURLWithPath: libraryPaths[index]))
    }

    func removeFromLibrary(_ path: String) {
        sessions[path]?.close()
        sessions[path] = nil
        libraryPaths.removeAll { $0 == path }
        if current?.root.standardizedFileURL.path == path {
            current = nil
            if let f = libraryPaths.first { openBook(URL(fileURLWithPath: f)) }
        }
    }

    /// For quick open: every chapter of every book in the library.
    func allChapters() -> [(bookPath: String, bookTitle: String, chapter: ChapterEntry)] {
        libraryPaths.flatMap { p -> [(String, String, ChapterEntry)] in
            guard let m = sessions[p]?.manifest ?? closedManifest(p) else { return [] }
            return m.chapters.map { (p, m.title, $0) }
        }
    }

    /// The manifests of books not open, read once and again only when their book.json changes:
    /// ⌘K lists every book's chapters, and reading them all from disk each time froze it.
    @ObservationIgnored private var manifestCache: [String: (date: Date, manifest: BookManifest)] = [:]

    private func closedManifest(_ path: String) -> BookManifest? {
        let store = BookStore(root: URL(fileURLWithPath: path))
        let date = (try? FileManager.default.attributesOfItem(atPath: store.manifestURL.path)[.modificationDate] as? Date) ?? .distantPast
        if let hit = manifestCache[path], hit.date == date { return hit.manifest }
        guard let m = try? store.loadManifest() else { return nil }
        manifestCache[path] = (date, m)
        return m
    }

    func openSearch() {
        showSidebar = true
        showSearch = true
        searchFocusRequest += 1
    }

    func closeSearch() {
        showSearch = false
        searchQuery = ""
    }

    func jump(bookPath: String, chapterID: String) {
        openBook(URL(fileURLWithPath: bookPath))
        current?.open(chapterID)
    }

    func applyTypographyToBook() {
        guard let s = current else { return }
        guard Typography.supports(s.manifest.lang) else { alert = L("No typography rules for « \(s.manifest.lang) » yet."); return }
        let preview = s.typographyPreview()
        guard preview.edits > 0 else { alert = L("Typography is already right in every chapter."); return }
        let a = NSAlert()
        a.messageText = L("Apply typography to « \(s.title) »?")
        a.informativeText = L("\(preview.edits) automatic fixes") + " " + L("in \(preview.chapters) chapters") + " " + L("(spaces, quotes, apostrophes, dashes, ellipses, Latin locutions in italics). Saved in one go, so it can be undone from History.")
        a.addButton(withTitle: L("Apply"))
        a.addButton(withTitle: L("Cancel"))
        guard a.runModal() == .alertFirstButtonReturn else { return }
        s.applyTypographyToBook()
    }

    func shutdown() {
        quitting = true
        for s in sessions.values { s.close() }
        Collab.shared.sendBeforeQuitting(Array(sessions.values))
    }
}

/// Where a new track or milestone starts: a revision (« HEAD », a commit) and how to say it.
struct TrackStart: Identifiable {
    let id = UUID()
    var rev = "HEAD"
    var label = L("the manuscript")
}
