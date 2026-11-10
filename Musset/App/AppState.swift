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
    var showBookSettings = false
    var showNewBook = false
    /// The account: sign in, and the books on it.
    var showAccount = false
    /// The book settings page to open on (sharing, for instance).
    var bookSettingsSection: BookSettingsView.Section?
    /// A special page (cover, dedication…) open in place of the editor.
    var specialPage: SpecialPage?
    /// Book-wide search (⇧⌘F) shown in the sidebar.
    var showSearch = false
    /// « Try something else »: a new version of the open chapter.
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
    /// The book's history: the manuscript, its tracks and milestones.
    var showStory = false
    /// A track to open, from where; a milestone to set, where; a track being taken back.
    var newPiste: TrackStart?
    var newJalon: TrackStart?
    var takingBack: Piste?
    /// Export the book as it was at this milestone.
    var exportAt: GitService.Tag?
    var showProofExceptions = false
    var showSidebar = true
    /// Reading mode: the text typeset as printed (Typst), instead of the editor.
    var reviewMode = false
    /// The plot grid: the chapter sidebar widened over the editor.
    var showPlotGrid = false
    /// Every book, over whatever is open.
    var showHome = false
    /// The optional AI helpers, with what they bring.
    var showHelpers = false
    /// The book's own home, in place of the editor.
    var showOverview = false
    var overviewTab = OverviewTab.summary
    /// An entry or folder of the Bible, in place of the editor.
    var bibleRoute: BibleRoute?

    /// Back to the page: whatever covered the editor goes.
    func leaveBookPages() {
        bibleRoute = nil
        showOverview = false
        specialPage = nil
        showPlotGrid = false
    }

    func show(_ route: BibleRoute) {
        leaveBookPages()
        bibleRoute = route
    }

    func openOverview(_ tab: OverviewTab = .summary) {
        leaveBookPages()
        overviewTab = tab
        showOverview = true
    }
    @ObservationIgnored let review = ReviewModel()

    /// The right-hand inspector (Edits & Comments, Chat, Stats, Plan, Notes): open or closed, and on which tab.
    var showInspector = UserDefaults.standard.bool(forKey: "showInspector") {
        didSet { UserDefaults.standard.set(showInspector, forKey: "showInspector") }
    }
    var inspectorTab = InspectorTab(rawValue: UserDefaults.standard.string(forKey: "inspectorTab") ?? "") ?? .edits {
        didSet { UserDefaults.standard.set(inspectorTab.rawValue, forKey: "inspectorTab") }
    }

    /// Opens the inspector on `tab`, or closes it if it is already showing that tab.
    func toggleInspector(_ tab: InspectorTab) {
        if tab == .chat && !AIStatus.shared.isOn { return }
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
        if let last = UserDefaults.standard.string(forKey: "lastBook"), libraryPaths.contains(last) {
            openBook(URL(fileURLWithPath: last))
        } else if let first = libraryPaths.first {
            openBook(URL(fileURLWithPath: first))
        }
    }

    var books: [(path: String, title: String)] {
        libraryPaths.map { p in
            let title = (try? BookStore(root: URL(fileURLWithPath: p)).loadManifest().title) ?? (p as NSString).lastPathComponent.capitalized
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
            let s = BookSession(root: url, manifest: m)
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
            alert = L("Setup failed: ") + error.localizedDescription
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
        if current !== s { current?.close() }
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
        a.informativeText = L("\(preview.edits) fixes") + " " + L("in \(preview.chapters) chapters") + " " + L("(spaces, quotes, apostrophes, dashes, ellipses, Latin locutions in italics). Saved as one commit, so it can be undone from History.")
        a.addButton(withTitle: L("Apply"))
        a.addButton(withTitle: L("Cancel"))
        guard a.runModal() == .alertFirstButtonReturn else { return }
        s.applyTypographyToBook()
    }

    func shutdown() {
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
