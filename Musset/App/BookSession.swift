import Foundation
import Observation

/// One open book: manifest, the chapter being edited, autosave and autocommit.
@MainActor
@Observable
final class BookSession: Identifiable {
    let root: URL
    let store: BookStore
    let git: GitService
    /// Passage notes (yours and the AI's) of the chapter one is in, kept beside the text in .musset/notes.
    var notes: NoteStore { focused?.notes ?? noChapterNotes }
    /// Notes when no chapter is open: empty, never saved anywhere.
    @ObservationIgnored private let noChapterNotes: NoteStore
    /// The chapters open for writing, and the one the author is in. Everything that speaks of « the chapter »
    /// (`text`, `notes`, `selectedChapterID`) speaks of that one.
    private(set) var focused: ChapterDoc?
    @ObservationIgnored private(set) var docs: [String: ChapterDoc] = [:]
    /// The main window's panes and tabs, kept with the book (`.musset/state.json`).
    let mainWorkspace: Workspace
    /// The book's other windows (a tab torn off, « Open in New Window »), by id.
    var windows: [String: Workspace] = [:]
    /// The window one is in: nil for the main one.
    var activeWindow: String? {
        didSet { if activeWindow != oldValue { followFocusedPane() } }
    }
    /// The panes and tabs of the window one is in: everything that opens something goes there.
    var workspace: Workspace { activeWindow.flatMap { windows[$0] } ?? mainWorkspace }
    var allWorkspaces: [Workspace] { [mainWorkspace] + windows.keys.sorted().compactMap { windows[$0] } }
    /// Conversations with the people reading the book.
    let talk: TalkStore
    let bible: BibleModel
    /// Spots the names the author writes for the first time and gives them a sheet.
    @ObservationIgnored private(set) lazy var spotter = NameSpotter(session: self)
    /// Keeps « What the book says » up to date from the chapters.
    @ObservationIgnored private(set) lazy var keeper = BibleKeeper(session: self)
    var manifest: BookManifest
    var selectedChapterID: String? { focused?.chapterID }
    /// Text of the selected chapter as shown in the editor.
    var text: String {
        get { focused?.text ?? "" }
        set { focused?.text = newValue }
    }
    /// The versions of the chapter one is in.
    var versions: [String] {
        get { focused?.versions ?? [] }
        set { focused?.versions = newValue }
    }
    /// Chapters with more than one version, and how many.
    var versionCounts: [String: Int] = [:]
    /// The last « Put in the book », while it can be undone.
    var lastVersionSwitch: VersionSwitch?
    /// Bumped whenever the version open in the editor changes: what shows it (the breadcrumb's chip) redraws.
    var versionTick = 0
    var lastError: String?
    /// Range to select once the editor shows the chapter one has just gone to (search results): asked of the window's
    /// live editor, once.
    var pendingSelection: NSRange?
    /// A chapter just split by Return: the editor puts its undo on ⌘Z once the new chapter is loaded.
    @ObservationIgnored var pendingSplitUndo: ChapterSplit?
    var lastCommitAt: Date?
    var pendingCommit = false
    /// Scenes of every chapter (editor form), for the sidebar tree and the plot grid.
    var scenes: [String: [ChapterScene]] = [:]
    /// Sections of every chapter (its `## ` and `### ` sub-headings), read when its scenes are, in a book that
    /// reads sub-headings as sections; empty in any other, which pays nothing for them.
    var sections: [String: [ChapterSection]] = [:]
    /// What the Scenes page shows of each chapter's text, made once and kept while the text stands (`cardText`).
    @ObservationIgnored var cardTexts: [String: (mark: Int, text: ChapterCardText)] = [:]
    /// The book's plot grid (.musset/plot.json).
    var plot: PlotGrid
    /// The book's Trash (.musset/trash.json).
    var trash: [TrashItem] = []
    /// Moves with each change of Drafts or Trash, for lists that read notes from disk.
    var shelfChanges = 0
    /// The debate open on the book's home; it goes on when the page is left.
    var debate: CriticTable?
    var debateShown = false
    /// The author's checkers, run on the open chapter.
    let checks = CheckerRunner()
    /// Goes up when the book's checkers change, so every place that lists them reloads.
    var checkersChanged = 0
    /// Goes up when boards were rewritten outside their page (a sheet on them moved): an open board reads its file again.
    var boardsRewritten = 0

    /// Reads the book's past for the Historique tab, and keeps what it read.
    @ObservationIgnored lazy var historyReader = HistoryReader(git: git)

    /// The layouts the author named, by name.
    var layoutNames: [String] = []
    @ObservationIgnored var state: BookUIState
    @ObservationIgnored private var stateTask: Task<Void, Never>?
    @ObservationIgnored var commitTask: Task<Void, Never>?
    /// The chapter last saved and not committed yet.
    @ObservationIgnored var lastSaved: String?
    /// libgit2 calls on this book, one at a time: a background commit never overlaps one made in place.
    @ObservationIgnored let gitQueue = DispatchQueue(label: "app.musset.git")
    /// The version shown read-only beside the editor of the chapter one is in, and its text.
    var reference: String? { focused?.reference }
    var referenceText: String { focused?.referenceText ?? "" }
    /// The track being written in; nil for the manuscript (the files in the book's folder).
    var piste: Piste?
    var pistes: [Piste] = []
    var jalons: [GitService.Tag] = []
    /// In a track, the manuscript shows beside the editor until closed.
    @ObservationIgnored var manuscriptBeside = true

    nonisolated var id: URL { root }

    static let commitIdleSeconds: UInt64 = 120

    /// `countsLater`: the app's way. The window shows the chapter left last time at once; the words, the scenes and
    /// the cast's mentions of the whole book follow, counted off the main thread (`counting`). Otherwise everything
    /// is counted before `init` returns.
    init(root: URL, manifest: BookManifest, countsLater: Bool = false) {
        self.root = root
        self.store = BookStore(root: root)
        self.git = GitService(root: root)
        self.noChapterNotes = NoteStore(root: root)
        self.talk = TalkStore(root: root)
        self.bible = BibleModel(root: root)
        self.manifest = manifest
        var plot = PlotGrid.load(root)
        plot.bind(to: bible.entries)
        self.plot = plot
        self.trash = TrashStore(root: root).load()
        var state = store.loadState()
        let adopted = state.adoptOldPreferences(of: root)
        self.state = state
        // The panes and tabs as they were left, without what no longer exists.
        self.mainWorkspace = state.layout.map { Workspace(saved: $0, keep: Self.keeper(root: root, manifest: manifest)) } ?? Workspace()
        // In a track the chapters come from its branch: counted in place.
        let later = countsLater && state.piste == nil
        defer { if later { countAllWordsLater() } else { countAllWords() } }
        // Once: margin notes and scratch pads become Markdown notes, in a commit of their own, so it can be undone.
        if NoteStore.migrate(root: root, chapters: manifest.chapters.map(\.id)), git.isRepo {
            _ = try? git.commit(paths: [".musset"], message: "musset: notes en Markdown")
        }
        pistes = Pistes.load(root)
        bible.onSheetsChanged = { [weak self] in self?.bindPlot() }
        piste = state.piste.flatMap { id in pistes.first { $0.id == id && git.resolve($0.branch) != nil } }
        jalons = git.tags(matching: "jalon/*")
        // The chapter one was in: the layout says it (an older state file names it).
        let first = (mainWorkspace.saved.lastChapter ?? state.lastChapter).flatMap { id in (manifest.chapters + (manifest.drafts ?? [])).first { $0.id == id } } ?? manifest.chapters.first
        if let first { open(first.id, show: workspace.activeTab == nil || workspace.activeTab?.isChapter == true) }
        watch(mainWorkspace)
        if adopted { stateChanged() }
        layoutNames = (state.layouts ?? [:]).keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        // The cast's tiers from the start, not only once the Bible is opened.
        if !later { refreshBibleMentions() }
    }

    var title: String { manifest.title }

    var selectedChapter: ChapterEntry? {
        guard let id = selectedChapterID else { return nil }
        return anyChapter(id)
    }

    /// A chapter of the book, or one set aside in Drafts.
    func anyChapter(_ id: String) -> ChapterEntry? {
        manifest.chapters.first { $0.id == id } ?? manifest.drafts?.first { $0.id == id }
    }

    var wordCount: Int { BookStore.wordCount(text) }
    /// The open chapter in the three units, as it stands in the editor.
    var textCounts: TextCounts { TextCounts(text) }

    /// What the status bar asks about the book's repository each time it redraws (a file check, the repository
    /// opened to list its remotes): kept a few seconds, and forgotten when the book is shared or synced.
    var repoStatus: (isRepo: Bool, linked: Bool) {
        if let known = repoFacts, Date().timeIntervalSince(known.at) < 5 { return (known.isRepo, known.linked) }
        let isRepo = git.isRepo
        let linked = isRepo && Collab.shared.link(git) != nil
        repoFacts = (Date(), isRepo, linked)
        return (isRepo, linked)
    }
    func forgetRepoStatus() { repoFacts = nil }
    @ObservationIgnored private var repoFacts: (at: Date, isRepo: Bool, linked: Bool)?
    /// Each chapter's length (active version) in the three units, counted once: the sidebar, the overview and the
    /// rest read it in the unit chosen. The open chapter is updated on save.
    var chapterCounts: [String: TextCounts] = [:]
    var bookCounts: TextCounts { manifest.chapters.filter { !$0.excludeFromExport }.reduce(.zero) { $0 + (chapterCounts[$1.id] ?? .zero) } }
    var bookWordCount: Int { bookCounts.words }

    /// Net words written in this book today (book total minus the total when the book was first opened today).
    var wordsToday: Int {
        guard let base = state.wordsBaseline, base.day == BookUIState.WordsBaseline.today else { return 0 }
        return max(0, bookWordCount - base.words)
    }

    /// The first count of the day is what « today » starts from; yesterday's is forgotten.
    private func keepWordsBaseline() {
        let today = BookUIState.WordsBaseline.today
        guard state.wordsBaseline?.day != today else { return }
        state.wordsBaseline = .init(day: today, words: bookWordCount)
        stateChanged()
    }

    /// A chapter's length and scenes. A chapter without scene markers is one scene, whose count is the chapter's:
    /// it is not counted twice.
    nonisolated static func count(_ text: String) -> (counts: TextCounts, scenes: [ChapterScene]) {
        let scenes = Scenes.parse(text)
        if scenes.count == 1, scenes[0].marker == nil, scenes[0].range.length == (text as NSString).length { return (scenes[0].counts, scenes) }
        return (TextCounts(text), scenes)
    }

    /// The count under way after the book opened (`countsLater`); nil once done, or when it was made in place.
    @ObservationIgnored private(set) var counting: Task<Void, Never>?

    /// Every chapter read once, off the main thread, for both the counts and the cast's mentions.
    private func countAllWordsLater() {
        let files = (manifest.chapters + draftChapters).map { (id: $0.id, url: store.url(for: $0)) }
        counting = Task { [weak self] in
            let found = await Task.detached(priority: .userInitiated) {
                files.map { f -> (id: String, text: String, counts: TextCounts, scenes: [ChapterScene]) in
                    let t = BookSearch.texts.text(at: f.url)
                    let c = BookSession.count(t)
                    return (f.id, t, c.counts, c.scenes)
                }
            }.value
            guard let self else { return }
            var texts: [String: String] = [:]
            for f in found where self.anyChapter(f.id) != nil {
                // A chapter open in a pane is counted as it stands there (it may have been written in meanwhile).
                if let d = self.bookDoc(f.id) {
                    let c = Self.count(d.text)
                    self.chapterCounts[f.id] = c.counts
                    self.scenes[f.id] = c.scenes
                    texts[f.id] = d.text
                } else {
                    self.chapterCounts[f.id] = f.counts
                    self.scenes[f.id] = f.scenes
                    texts[f.id] = f.text
                }
            }
            self.readSections(texts)
            self.followHeadings(texts)
            self.refreshVersionCounts()
            self.keepWordsBaseline()
            self.refreshBibleMentions()
            self.counting = nil
        }
    }

    func countAllWords() {
        var out: [String: TextCounts] = [:]
        var sc: [String: [ChapterScene]] = [:]
        var texts: [String: String] = [:]
        for ch in manifest.chapters + draftChapters {
            let t = editorText(of: ch.id)
            let c = Self.count(t)
            out[ch.id] = c.counts
            sc[ch.id] = c.scenes
            texts[ch.id] = t
        }
        followHeadings(texts)
        readSections(texts)
        chapterCounts = out
        scenes = sc
        refreshVersionCounts()
        keepWordsBaseline()
    }

    var savedSelection: Int { selectedChapterID.flatMap { state.selections[$0] } ?? 0 }

    /// Paths Musset commits: chapter files and its own folder.
    var trackedPaths: [String] { (manifest.chapters + draftChapters + trash.compactMap(\.chapter)).map(\.file) + [".musset"] + (FileManager.default.fileExists(atPath: bible.store.dir.path) ? [BibleStore.folderName] : []) }

    // MARK: Chapters

    /// Opens a chapter to write in, and shows its tab (`show: false` only when restoring the window as it was left).
    func open(_ chapterID: String, show: Bool = true) {
        flushSave()
        commitIfPending(message: editMessage, background: true)
        // The chapter just left is read for the Bible, if it changed.
        if let left = selectedChapterID, left != chapterID { keeper.chapterLeft(left) }
        guard let ch = anyChapter(chapterID) else { return }
        focused?.notes.save()
        if let doc = docs[ch.id] {
            // Already open in a pane: it becomes the one written in, as it stands.
            focused = doc
            refreshFocus(ch)
        } else {
            let doc = ChapterDoc(chapterID: ch.id, root: root)
            docs[ch.id] = doc
            focused = doc
            load(ch)
        }
        if show, workspace.activeTab != .chapter(ch.id) { workspace.open(.chapter(ch.id)) }
    }

    /// Something of the book's state on this Mac changed (`state`, or the panes): the one way `state.json` is
    /// written, once things have settled. Closing the book or quitting writes it at once (`saveStateNow`).
    func stateChanged() {
        stateTask?.cancel()
        stateTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            self?.saveStateNow()
        }
    }

    func saveStateNow() {
        stateTask?.cancel()
        keepLayout()
        store.saveState(state)
    }

    func load(_ ch: ChapterEntry) {
        // One line per paragraph in the editor; the file keeps standard Markdown (see ParagraphCodec).
        // Versions are the manuscript's; a track is a version of the whole book.
        versions = piste == nil ? store.versions(of: ch) : []
        // The version open in the editor: the book's, or another one being tried.
        text = ParagraphCodec.decode(openAlternate.map { store.readVersion(ch, $0) } ?? chapterText(ch))
        notes.load(chapter: ch, text: text)
        scenes[ch.id] = Scenes.parse(text)
        readSections(ch.id, text)
        loadReference(known: versions)
    }

    /// What follows the chapter one is in, when one goes back to a chapter already open: its versions, scenes, side text.
    private func refreshFocus(_ ch: ChapterEntry) {
        versions = piste == nil ? store.versions(of: ch) : []
        scenes[ch.id] = Scenes.parse(text)
        readSections(ch.id, text)
        loadReference(known: versions)
        versionTick += 1
    }

    /// The chapter's document, open or opened (without making it the one written in).
    func doc(for chapterID: String) -> ChapterDoc? {
        if let d = docs[chapterID] { return d }
        guard let ch = anyChapter(chapterID) else { return nil }
        let d = ChapterDoc(chapterID: ch.id, root: root)
        d.text = ParagraphCodec.decode(alternate(of: ch).map { store.readVersion(ch, $0) } ?? chapterText(ch))
        d.notes.load(chapter: ch, text: d.text)
        docs[ch.id] = d
        return d
    }

    /// The notes of any chapter (or of the book, `NoteStore.bookPage`) are read and written through this: the chapter's
    /// open document if it has one, so what a pane holds is never written over from disk; else the files.
    func noteStore(for chapterID: String) -> NoteStore { docs[chapterID]?.notes ?? notes }

    /// Notes just put into a chapter from outside (a reader's, one back from the Trash) find their passage, if it is open.
    func resolveNotes(in chapterID: String) {
        if let d = docs[chapterID] { d.notes.resolveAll(in: d.text) }
    }

    /// A reader's notes join a chapter's own.
    func importNotes(_ theirs: [Note], chapter: String, from reader: String) {
        noteStore(for: chapter).importNotes(theirs, chapter: chapter, from: reader)
        resolveNotes(in: chapter)
    }

    /// Notes that follow their scene to another chapter, each side through its own open document.
    func transferNotes(_ ids: Set<UUID>, from source: String, to target: String) {
        guard !ids.isEmpty, source != target else { return }
        let from = noteStore(for: source).notes(of: source)
        noteStore(for: source).replaceAll(from.filter { !ids.contains($0.id) }, in: source)
        let to = noteStore(for: target)
        to.replaceAll(to.notes(of: target) + from.filter { ids.contains($0.id) }, in: target)
    }

    /// Documents no pane shows any more are saved and let go.
    func pruneDocs() { pruneDocs(keeping: shownChapters) }

    func pruneDocs(keeping shown: Set<String>) {
        for (id, d) in docs where id != selectedChapterID && !shown.contains(id) {
            flushSave(d)
            d.notes.save()
            docs[id] = nil
        }
    }

    /// A chapter's Markdown where one is writing: the book's folder, or the track.
    func chapterText(_ ch: ChapterEntry) -> String {
        guard let piste else { return store.read(ch) }
        let cached = Pistes.cacheDir(root, piste).appendingPathComponent(ch.file)
        if let s = try? String(contentsOf: cached, encoding: .utf8) { return s }
        return git.show(piste.branch, path: ch.file) ?? store.read(ch)
    }

    func textDidChange(_ newText: String) {
        guard let doc = focused, newText != doc.text else { return }
        doc.text = newText
        // Writing in a chapter keeps its tab: it is no longer the preview.
        if workspace.activeTab == .chapter(doc.chapterID) { workspace.pin() }
        doc.dirty = true
        doc.saveTask?.cancel()
        doc.saveTask = Task { [weak self, weak doc] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled, let doc else { return }
            // Saved into its own chapter, even if the author has gone to another pane meanwhile.
            self?.flushSave(doc)
        }
    }

    func rememberPiste(_ id: String?) {
        state.piste = id
        stateChanged()
    }

    func rememberSelection(_ location: Int) {
        guard let id = selectedChapterID, state.selections[id] != location else { return }
        state.selections[id] = location
        // Written soon after the caret stops: a quit that skips close() still finds its place.
        stateChanged()
    }

    /// Saves every chapter open for writing, the one one is in first.
    func flushSave() {
        if let f = focused { flushSave(f) }
        for d in docs.values where d !== focused { flushSave(d) }
    }

    func flushSave(_ doc: ChapterDoc) {
        doc.saveTask?.cancel()
        guard doc.dirty, let ch = anyChapter(doc.chapterID) else { return }
        let other = alternate(of: ch)
        do {
            if let piste {
                let u = Pistes.cacheDir(root, piste).appendingPathComponent(ch.file)
                try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
                try ParagraphCodec.encode(doc.text).write(to: u, atomically: true, encoding: .utf8)
            } else if let other {
                // Another version being tried: its own file; the book's chapter and its notes stay as they are.
                try store.saveVersion(ch, name: other, text: ParagraphCodec.encode(doc.text))
            } else {
                try store.write(ParagraphCodec.encode(doc.text), to: ch)
                // Notes belong to the manuscript's text.
                doc.notes.recapture(text: doc.text)
            }
            doc.dirty = false
            lastSaved = ch.id
            refreshScenes(of: ch.id, text: doc.text)
            if other == nil {
                chapterCounts[ch.id] = TextCounts(doc.text)
                followHeadings([ch.id: doc.text])
            }
            scheduleCommit()
        } catch {
            lastError = L("Could not save \(ch.file): \(error.localizedDescription)")
        }
    }

    /// What the sync brought was written to disk: everything shown follows. A chapter open in a pane only moves if its text changed.
    func reloadAfterSync() {
        forgetRepoStatus()
        if let m = try? store.loadManifest() { manifest = m }
        plot = PlotGrid.load(root)
        pistes = Pistes.load(root)
        jalons = git.tags(matching: "jalon/*")
        bible.reload()
        trash = TrashStore(root: root).load()
        if selectedChapter == nil, let first = manifest.chapters.first { open(first.id) }
        if piste == nil {
            if let ch = selectedChapter { versions = store.versions(of: ch) }
            for d in docs.values { reloadFromDisk(d) }
        }
        countAllWords()
    }

    /// An open chapter follows its file, written by something else than its editor: its text if it changed, and its notes.
    /// The file wins over what was typed since the last save, as the sync saves everything before it writes.
    private func reloadFromDisk(_ doc: ChapterDoc) {
        guard let ch = anyChapter(doc.chapterID) else { return }
        let fresh = ParagraphCodec.decode(alternate(of: ch).map { store.readVersion(ch, $0) } ?? store.read(ch))
        if fresh != doc.text {
            doc.saveTask?.cancel()
            doc.text = fresh
            doc.dirty = false
        }
        doc.notes.load(chapter: ch, text: doc.text)
    }

    /// No chapter open any more (the last one went to the Drafts or the Trash).
    func closeChapter() {
        if let f = focused {
            flushSave(f)
            f.notes.save()
            docs[f.chapterID] = nil
        }
        focused = nil
    }

    /// Called when the app quits or the book is switched away. `background`: going to another book, the commit
    /// (~100 ms on a real book) is made off the main thread; quitting waits for it.
    func close(background: Bool = false) {
        flushSave()
        for d in docs.values { d.notes.save() }
        commitIfPending(message: editMessage, background: background)
        commitBesideTrack()
        saveStateNow()
    }

    /// The one way the book's settings and chapter list are written (`book.json`): saved at once, and committed like
    /// the text, so a status, a pseudonym or a dedication reaches the history and the account without waiting for an edit.
    func saveManifest() {
        do { try store.saveManifest(manifest) } catch { lastError = error.localizedDescription; return }
        scheduleCommit()
    }

    /// Anything else dropped on the list (text dragged from the page) moves nothing.
    func moveChapters(ids: [String], to destination: Int) {
        let source = IndexSet(ids.compactMap { id in manifest.chapters.firstIndex { $0.id == id } })
        guard !source.isEmpty else { return }
        let before = manifest.chapters.map(\.id)
        manifest.chapters.move(fromOffsets: source, toOffset: destination)
        guard manifest.chapters.map(\.id) != before else { return }
        saveManifest()
        commitInBackground("musset: reorder chapters")
    }

    /// A chapter is called what its heading says. In a track the book's folder doesn't change: the title only shows.
    private func followHeadings(_ texts: [String: String]) {
        var changed = false
        for i in manifest.chapters.indices {
            guard let heading = texts[manifest.chapters[i].id].flatMap(BookStore.heading(in:)), heading != manifest.chapters[i].title else { continue }
            manifest.chapters[i].title = heading
            changed = true
        }
        for i in draftChapters.indices {
            guard let heading = texts[draftChapters[i].id].flatMap(BookStore.heading(in:)), heading != draftChapters[i].title else { continue }
            manifest.drafts?[i].title = heading
            changed = true
        }
        guard changed, piste == nil else { return }
        saveManifest()
    }

    /// Renaming rewrites the heading. A chapter without one keeps its text and takes the name.
    func renameChapter(_ id: String, to title: String) {
        let title = title.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty, inManuscript(), let i = manifest.chapters.firstIndex(where: { $0.id == id }) else { return }
        if let renamed = BookStore.retitled(editorText(of: id), to: title) {
            do { try writeChapterText(id, renamed) } catch { lastError = error.localizedDescription; return }
        }
        if manifest.chapters[i].title != title {
            manifest.chapters[i].title = title
            saveManifest()
        }
        commitInBackground("musset: rename chapter \(id)")
    }

    /// The first chapter of a book marked done: Musset speaks once, then never again for this book.
    static let firstChapterDone = Notification.Name("MussetFirstChapterDone")

    func setStatus(_ id: String, _ status: ChapterStatus) {
        let value = status == .draft ? nil : status
        if status == .done, ((manifest.chapters.first { $0.id == id })?.status ?? .draft) == .draft, state.firstChapterDone != true,
           !manifest.chapters.contains(where: { ($0.status ?? .draft) != .draft }) {
            state.firstChapterDone = true
            stateChanged()
            NotificationCenter.default.post(name: Self.firstChapterDone, object: self, userInfo: ["chapter": id])
        }
        if let i = manifest.chapters.firstIndex(where: { $0.id == id }) { manifest.chapters[i].status = value }
        else if let i = draftChapters.firstIndex(where: { $0.id == id }) { manifest.drafts?[i].status = value }
        else { return }
        saveManifest()
    }

    func toggleExport(_ id: String) {
        guard let i = manifest.chapters.firstIndex(where: { $0.id == id }) else { return }
        manifest.chapters[i].excludeFromExport.toggle()
        saveManifest()
    }

    func addChapter(title: String) {
        let entry = newChapterEntry(title: title)
        if !FileManager.default.fileExists(atPath: store.url(for: entry).path) {
            try? store.write("# \(title)\n\n", to: entry)
        }
        manifest.chapters.append(entry)
        chapterCounts[entry.id] = TextCounts(store.read(entry))
        saveManifest()
        commitInBackground("musset: add chapter \(entry.id)")
        open(entry.id)
    }

    /// A free id and file for a new chapter, beside the book's last one.
    func newChapterEntry(title: String) -> ChapterEntry {
        let n = manifest.chapters.count
        let slug = title.slug("_")
        let dir = manifest.chapters.last.map { ($0.file as NSString).deletingLastPathComponent } ?? ""
        var id = String(format: "%02d_%@", n, slug.isEmpty ? "chapitre" : slug)
        let taken = (manifest.chapters + draftChapters + trash.compactMap(\.chapter)).map(\.id)
        while taken.contains(id) { id += "_" }
        var file = dir.isEmpty ? "\(id).md" : "\(dir)/\(id).md"
        // A file left on disk by something else is never overwritten.
        while FileManager.default.fileExists(atPath: root.appendingPathComponent(file).path) {
            id += "_"
            file = dir.isEmpty ? "\(id).md" : "\(dir)/\(id).md"
        }
        return ChapterEntry(id: id, file: file, title: title)
    }

    // MARK: Scenes

    /// Re-reads the open chapter's scenes.
    func refreshScenes() {
        if let id = selectedChapterID { refreshScenes(of: id, text: text) }
    }

    /// A chapter's scenes after its text was edited: a marker renamed carries its plot row along (`PlotGrid.follow`).
    private func refreshScenes(of id: String, text: String) {
        let followed = plot.follow(id, from: scenes[id] ?? [], to: Scenes.parse(text))
        scenes[id] = followed.scenes
        if followed.moved { savePlot() }
        readSections(id, text)
    }

    // MARK: Sections

    /// A chapter's sections as its text now has them. Nothing is read in a book whose sub-headings are not sections.
    func readSections(_ id: String, _ text: String) {
        guard manifest.textFeatures.subheadings else {
            if !sections.isEmpty { sections = [:] }
            return
        }
        let found = Sections.parse(text)
        if (sections[id] ?? []) != found { sections[id] = found.isEmpty ? nil : found }
    }

    private func readSections(_ texts: [String: String]) {
        guard manifest.textFeatures.subheadings else {
            if !sections.isEmpty { sections = [:] }
            return
        }
        sections = texts.mapValues(Sections.parse).filter { !$0.value.isEmpty }
    }

    /// Every chapter's sections again: the book started, or stopped, reading its sub-headings as sections.
    func refreshSections() {
        readSections(Dictionary((manifest.chapters + draftChapters).map { ($0.id, editorText(of: $0.id)) }, uniquingKeysWith: { a, _ in a }))
    }

    /// The open document that holds the book's text of a chapter, if a pane has one (not one open on another version).
    private func bookDoc(_ chapterID: String) -> ChapterDoc? { editorIsBook(chapterID) ? docs[chapterID] : nil }

    /// The one way to read a chapter's text, in editor form: as it stands in a pane if it is open, else its file.
    func editorText(of chapterID: String) -> String {
        if let d = bookDoc(chapterID) { return d.text }
        guard let ch = anyChapter(chapterID) else { return "" }
        // A closed chapter of the manuscript: as last read, while its file has not changed. The Bible's counts, the
        // notes of the whole book and the reading view each ask for every chapter.
        if piste == nil, store.revision == nil { return BookSearch.texts.text(at: store.url(for: ch)) }
        return ParagraphCodec.decode(chapterText(ch))
    }

    func sceneStatus(_ chapterID: String, _ key: String) -> ChapterStatus { plot.row(chapterID, key).status ?? .draft }

    func setSceneStatus(_ chapterID: String, _ key: String, _ status: ChapterStatus) {
        plot.update(chapterID, key) { $0.status = status == .draft ? nil : status }
        savePlot()
    }

    /// The grid's index tied to the Bible's sheets again: after the sheets changed, or names joined the index.
    func bindPlot() {
        var bound = plot
        if bound.bind(to: bible.entries) { plot = bound }
    }

    /// A name of the index renamed from the grid. A tag that is a sheet is renamed there, where its name is kept,
    /// and the grid follows; the name of another tag merges the two.
    func renameTag(_ tag: PlotGrid.Tag, to name: String) {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != tag.name else { return }
        if var sheet = tag.sheet.flatMap(bible.entry(path:)), !plot.tags.contains(where: { $0.column == tag.column && $0.name == name }) {
            sheet.title = name
            do { try bible.save(sheet) } catch { lastError = error.localizedDescription; return }
        } else {
            plot.renameTag(tag.name, to: name, column: tag.column)
        }
        savePlot()
    }

    func savePlot() {
        do { try plot.save(root); pendingCommit = true } catch { lastError = error.localizedDescription }
    }

    /// What it takes to put a scene back: the editor's undo stops at the chapter.
    struct SceneMoveUndo {
        var title: String
        var chapters: [(id: String, text: String, notes: [Note])]
        var plot: PlotGrid
    }
    var lastSceneMove: SceneMoveUndo?

    /// The one way to write a chapter's text in the book from outside its editor (a rename, a track taken back,
    /// corrections, going back): through its open document if a pane has one, whichever pane, so no pane keeps an
    /// old text to save over the new one; else to its file. `file`: the Markdown to write as it is, when it comes
    /// from the history, for a chapter that is not open.
    func writeChapterText(_ id: String, _ new: String, file: String? = nil) throws {
        guard let ch = anyChapter(id) else { return }
        if let d = bookDoc(id) {
            replaceText(new, in: d)
        } else {
            try store.write(file ?? ParagraphCodec.encode(new), to: ch)
        }
        chapterCounts[id] = TextCounts(new)
        scenes[id] = Scenes.parse(new)
        readSections(id, new)
    }

    /// Moves a scene with its text, its notes and its plot row, to any place in the book, in one commit.
    /// `slot`: the scene's place in the target, as the target's scenes stand now.
    func moveScene(from source: String, index: Int, to target: String, slot: Int) {
        guard inManuscript() else { return }
        flushSave()
        let opening = L("Opening")
        let sourceText = editorText(of: source), targetText = editorText(of: target)
        let sourceScenes = Scenes.parse(sourceText)
        guard sourceScenes.indices.contains(index) else { return }
        let scene = sourceScenes[index]
        let undo = SceneMoveUndo(title: scene.title ?? opening,
                                 chapters: [(source, sourceText, noteStore(for: source).notes(of: source))] + (source == target ? [] : [(target, targetText, noteStore(for: target).notes(of: target))]),
                                 plot: plot)
        do {
            if source == target {
                guard let out = Scenes.moved(index, to: slot, in: sourceText, openingTitle: opening) else { return }
                if let title = out.opening { plot.rename(source, from: "", to: title) }
                try writeChapterText(source, out.text)
            } else {
                guard let cut = Scenes.extract(index, from: sourceText, openingTitle: opening) else { return }
                // The name must stay unique in its new chapter: the plot row hangs on it.
                let taken = Set((scenes[target] ?? Scenes.parse(targetText)).compactMap(\.title))
                var title = cut.title, n = 2
                while taken.contains(title) { title = "\(cut.title) (\(n))"; n += 1 }
                var block = cut.block
                if title != cut.title, let eol = block.firstIndex(of: "\n") {
                    block = Scenes.markerLine(title) + block[eol...]
                }
                let put = Scenes.insert(block, into: targetText, at: slot, openingTitle: opening)
                // The notes whose passage is in the scene leave with it.
                let leaving = noteStore(for: source).notes(of: source).filter { n in
                    (Anchoring.resolve(n.anchor, in: sourceText)).map { NSIntersectionRange($0, scene.range).length == $0.length } ?? false
                }
                transferNotes(Set(leaving.map(\.id)), from: source, to: target)
                if let row = plot.rows[source]?[scene.key] {
                    plot.rows[source]?[scene.key] = nil
                    plot.rows[target, default: [:]][title] = row
                }
                if let marked = put.markedOpening { plot.rename(target, from: "", to: marked) }
                try writeChapterText(source, cut.rest)
                try writeChapterText(target, put.text)
            }
            lastSceneMove = undo
            savePlot()
            if let ch = selectedChapter { notes.resolveAll(in: editorText(of: ch.id)) }
            commitNow("musset: move scene \(undo.title) from \(source) to \(target)")
        } catch { lastError = error.localizedDescription }
    }

    /// Puts the texts, the notes and the plot back as they were before the last move, in a commit of its own.
    func undoSceneMove() {
        guard let undo = lastSceneMove, inManuscript() else { return }
        flushSave()
        do {
            for c in undo.chapters {
                noteStore(for: c.id).replaceAll(c.notes, in: c.id)
                try writeChapterText(c.id, c.text)
            }
            plot = undo.plot
            savePlot()
            if let ch = selectedChapter { notes.resolveAll(in: editorText(of: ch.id)) }
            lastSceneMove = nil
            commitNow("musset: undo move of scene \(undo.title)")
        } catch { lastError = error.localizedDescription }
    }

    // MARK: Versions

    private func updateEntry(_ entry: ChapterEntry) {
        if let i = manifest.chapters.firstIndex(where: { $0.id == entry.id }) { manifest.chapters[i] = entry }
        else if let i = draftChapters.firstIndex(where: { $0.id == entry.id }) { manifest.drafts?[i] = entry }
        saveManifest()
    }

    func refreshVersions() {
        if let ch = selectedChapter { versions = store.versions(of: ch) }
        loadReference(known: selectedChapter == nil ? nil : versions)
    }

    /// Shows `version` read-only beside the editor for the open chapter (nil closes it). Remembered per chapter.
    func showBeside(_ version: String?) {
        if piste != nil { manuscriptBeside = version != nil; loadReference(); return }
        guard let id = selectedChapterID else { return }
        var refs = state.references ?? [:]
        refs[id] = version
        state.references = refs.isEmpty ? nil : refs
        stateChanged()
        loadReference()
    }

    /// A reference that became the active version, or was deleted, closes.
    /// `known`: the chapter's versions, when the caller has just listed them.
    func loadReference(known: [String]? = nil) {
        guard let doc = focused, let ch = selectedChapter else { return }
        if piste != nil {
            doc.reference = manuscriptBeside ? L("The manuscript") : nil
            doc.referenceText = manuscriptBeside ? ParagraphCodec.decode(store.read(ch)) : ""
            return
        }
        guard let name = state.references?[ch.id],
              name != editingVersion, (known ?? store.versions(of: ch)).contains(name) else {
            doc.reference = nil; doc.referenceText = ""
            return
        }
        doc.reference = name
        doc.referenceText = ParagraphCodec.decode(store.readVersion(ch, name))
    }

    /// Starts the chapter again on a blank page, as a new active version named by the date;
    /// the text it had stays beside it, read-only.
    func newVersionFromScratch(_ chapterID: String) {
        guard inManuscript() else { return }
        if selectedChapterID != chapterID { open(chapterID) }
        flushSave()
        guard let ch = selectedChapter else { return }
        let previous = ch.activeVersion
        let name = store.datedVersionName(ch)
        do {
            try store.saveVersion(ch, name: name, text: "")
            try activateVersion(name, commit: false)
            showBeside(previous)
            commitNow("musset: new version \(name) of \(ch.id), from scratch")
        } catch { lastError = error.localizedDescription }
    }

    func activateVersion(_ name: String) {
        guard inManuscript() else { return }
        do { try activateVersion(name, commit: true) } catch { lastError = error.localizedDescription }
    }

    /// `keepEditor`: the editor stays on the version it had open (« Put in the book »); otherwise it follows the book.
    func activateVersion(_ name: String, commit: Bool, keepEditor: Bool = false) throws {
        flushSave()
        guard let ch = selectedChapter else { return }
        let open = editingVersion
        let updated = try store.activate(ch, version: name)
        updateEntry(updated)
        rememberOpenVersion(keepEditor && open != name ? open : nil, for: ch.id)
        versions = store.versions(of: updated)
        text = ParagraphCodec.decode(openAlternate.map { store.readVersion(updated, $0) } ?? store.read(updated))
        notes.resolveAll(in: text)
        chapterCounts[ch.id] = TextCounts(ParagraphCodec.decode(store.read(updated)))
        refreshScenes()
        if openAlternate == nil { followHeadings([ch.id: text]) }
        refreshVersions()
        refreshVersionCounts()
        if commit { commitNow("musset: activate \(name) for \(ch.id)") }
    }

    func renameVersion(_ old: String, to new: String) {
        flushSave()
        guard let ch = selectedChapter else { return }
        let fresh = store.uniqueVersionName(ch, base: new)
        do {
            let updated = try store.renameVersion(ch, from: old, to: fresh)
            updateEntry(updated)
            // The editor and the side keep showing it under its new name.
            if state.openVersions?[ch.id] == old { rememberOpenVersion(fresh, for: ch.id) }
            if state.references?[ch.id] == old { var r = state.references ?? [:]; r[ch.id] = fresh; state.references = r; stateChanged() }
            refreshVersions()
            commitNow("musset: rename version \(old) → \(new) for \(ch.id)")
        } catch { lastError = error.localizedDescription }
    }

    func deleteVersion(_ name: String) {
        guard let ch = selectedChapter else { return }
        do {
            try store.deleteVersion(ch, name)
            refreshVersions()
            commitNow("musset: delete version \(name) of \(ch.id)")
        } catch { lastError = error.localizedDescription }
    }

    /// How many typographic fixes each chapter needs (active versions).
    func typographyPreview() -> (edits: Int, chapters: Int) {
        var edits = 0, chapters = 0
        for ch in manifest.chapters {
            let n = Typography.correctedDocument(bookDoc(ch.id)?.text ?? store.read(ch), lang: manifest.lang, lists: manifest.listOptions).count
            if n > 0 { edits += n; chapters += 1 }
        }
        return (edits, chapters)
    }

    /// Applies the book's typographic conventions to every chapter, in a single commit.
    func applyTypographyToBook() {
        guard inManuscript() else { return }
        flushSave()
        commitIfPending(message: editMessage)
        for ch in manifest.chapters {
            let open = bookDoc(ch.id)
            let fixed = Typography.correctedDocument(open?.text ?? store.read(ch), lang: manifest.lang, lists: manifest.listOptions)
            guard fixed.count > 0 else { continue }
            if let open {
                replaceText(fixed.text, in: open)   // editor form in, editor form out
            } else {
                do { try store.write(fixed.text, to: ch) } catch { lastError = L("Could not save \(ch.file): \(error.localizedDescription)") }
            }
        }
        pendingCommit = true
        commitNow("musset: typography (\(manifest.lang))")
    }

    /// Replaces the editor text (used by history restore); goes through the normal save/commit path.
    func replaceText(_ newText: String) {
        guard let f = focused else { return }
        replaceText(newText, in: f)
    }

    /// The text of an open chapter, replaced (history restore, typography, a rename) and saved at once.
    func replaceText(_ newText: String, in doc: ChapterDoc) {
        if doc === focused { textDidChange(newText) } else if newText != doc.text { doc.text = newText; doc.dirty = true }
        // The live ranges belong to the old text: saving now must not write them back as anchors.
        doc.notes.resolveAll(in: newText)
        flushSave(doc)
    }
}
