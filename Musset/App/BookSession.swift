import Foundation
import Observation

/// One open book: manifest, the chapter being edited, autosave and autocommit.
@MainActor
@Observable
final class BookSession: Identifiable {
    let root: URL
    let store: BookStore
    let git: GitService
    /// Passage notes (yours and the AI's), kept beside the text in .musset/notes.
    let notes: NoteStore
    let bible: BibleModel
    var manifest: BookManifest
    var selectedChapterID: String?
    /// Text of the selected chapter as shown in the editor.
    var text: String = ""
    var versions: [String] = []
    /// Chapters with more than one version, and how many.
    var versionCounts: [String: Int] = [:]
    /// The last « Put in the book », while it can be undone.
    var lastVersionSwitch: VersionSwitch?
    /// Bumped whenever the version open in the editor changes: what shows it (the breadcrumb's chip) redraws.
    var versionTick = 0
    var lastError: String?
    /// Range to select once the editor shows the chapter (search results).
    var pendingSelection: NSRange?
    var lastCommitAt: Date?
    var pendingCommit = false
    /// Scenes of every chapter (editor form), for the sidebar tree and the plot grid.
    var scenes: [String: [ChapterScene]] = [:]
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

    /// Reads the book's past for the Historique tab, and keeps what it read.
    @ObservationIgnored lazy var historyReader = HistoryReader(git: git)

    @ObservationIgnored var state: BookUIState
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var stateTask: Task<Void, Never>?
    @ObservationIgnored private var commitTask: Task<Void, Never>?
    @ObservationIgnored private var dirty = false
    @ObservationIgnored var selection: Int = 0
    /// The version shown read-only beside the editor for the open chapter, and its text.
    private(set) var reference: String?
    private(set) var referenceText = ""
    /// The track being written in; nil for the manuscript (the files in the book's folder).
    var piste: Piste?
    var pistes: [Piste] = []
    var jalons: [GitService.Tag] = []
    /// In a track, the manuscript shows beside the editor until closed.
    @ObservationIgnored var manuscriptBeside = true

    nonisolated var id: URL { root }

    static let commitIdleSeconds: UInt64 = 120

    init(root: URL, manifest: BookManifest) {
        self.root = root
        self.store = BookStore(root: root)
        self.git = GitService(root: root)
        self.notes = NoteStore(root: root)
        self.bible = BibleModel(root: root)
        self.manifest = manifest
        self.plot = PlotGrid.load(root)
        self.trash = TrashStore(root: root).load()
        self.state = store.loadState()
        defer { countAllWords() }
        // French books start with the Collection Blanche rubric (editable from the chat's « Rubric… »).
        if manifest.lang.lowercased().hasPrefix("fr"), Rubric.load(root) == nil, store.hasManifest {
            try? Rubric.save(Rubric.blanche, root: root)
        }
        // Once: margin notes and scratch pads become Markdown notes, in a commit of their own, so it can be undone.
        if NoteStore.migrate(root: root, chapters: manifest.chapters.map(\.id)), git.isRepo {
            _ = try? git.commit(paths: [".musset"], message: "musset: notes en Markdown")
        }
        pistes = Pistes.load(root)
        piste = state.piste.flatMap { id in pistes.first { $0.id == id && git.resolve($0.branch) != nil } }
        jalons = git.tags(matching: "jalon/*")
        let first = state.lastChapter.flatMap { id in (manifest.chapters + (manifest.drafts ?? [])).first { $0.id == id } } ?? manifest.chapters.first
        if let first { open(first.id) }
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
    /// Words per chapter (active version), for the sidebar's length bars. The open chapter is updated on save.
    var chapterWords: [String: Int] = [:]
    var bookWordCount: Int { manifest.chapters.filter { !$0.excludeFromExport }.reduce(0) { $0 + (chapterWords[$1.id] ?? 0) } }

    private var todayKey: String {
        "wordsBaseline:\(root.standardizedFileURL.path):\(Date().formatted(.iso8601.year().month().day()))"
    }

    /// Net words written in this book today (book total minus the total when the book was first opened today).
    var wordsToday: Int {
        let base = UserDefaults.standard.object(forKey: todayKey) as? Int ?? bookWordCount
        return max(0, bookWordCount - base)
    }

    func countAllWords() {
        var out: [String: Int] = [:]
        var sc: [String: [ChapterScene]] = [:]
        var texts: [String: String] = [:]
        for ch in manifest.chapters + draftChapters {
            let t = editorIsBook(ch.id) ? text : ParagraphCodec.decode(chapterText(ch))
            out[ch.id] = BookStore.wordCount(t)
            sc[ch.id] = Scenes.parse(t)
            texts[ch.id] = t
        }
        followHeadings(texts)
        chapterWords = out
        scenes = sc
        refreshVersionCounts()
        if UserDefaults.standard.object(forKey: todayKey) == nil { UserDefaults.standard.set(bookWordCount, forKey: todayKey) }
    }

    var savedSelection: Int { selectedChapterID.flatMap { state.selections[$0] } ?? 0 }

    /// Paths Musset commits: chapter files and its own folder.
    var trackedPaths: [String] { (manifest.chapters + draftChapters + trash.compactMap(\.chapter)).map(\.file) + [".musset"] + (FileManager.default.fileExists(atPath: bible.store.dir.path) ? [BibleStore.folderName] : []) }

    // MARK: Chapters

    func open(_ chapterID: String) {
        flushSave()
        commitIfPending(message: "musset: edit \(selectedChapterID ?? "")", background: true)
        guard let ch = anyChapter(chapterID) else { return }
        selectedChapterID = ch.id
        load(ch)
        state.lastChapter = ch.id
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
        loadReference()
    }

    /// A chapter's Markdown where one is writing: the book's folder, or the track.
    func chapterText(_ ch: ChapterEntry) -> String {
        guard let piste else { return store.read(ch) }
        let cached = Pistes.cacheDir(root, piste).appendingPathComponent(ch.file)
        if let s = try? String(contentsOf: cached, encoding: .utf8) { return s }
        return git.show(piste.branch, path: ch.file) ?? store.read(ch)
    }

    func textDidChange(_ newText: String) {
        guard newText != text else { return }
        text = newText
        dirty = true
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            self?.flushSave()
        }
    }

    func rememberPiste(_ id: String?) {
        state.piste = id
        store.saveState(state)
    }

    func rememberSelection(_ location: Int) {
        guard let id = selectedChapterID, state.selections[id] != location else { return }
        state.selections[id] = location
        // Written soon after the caret stops: a quit that skips close() still finds its place.
        stateTask?.cancel()
        stateTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled, let self else { return }
            self.store.saveState(self.state)
        }
    }

    func flushSave() {
        saveTask?.cancel()
        guard dirty, let ch = selectedChapter else { return }
        do {
            if let piste {
                let u = Pistes.cacheDir(root, piste).appendingPathComponent(ch.file)
                try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
                try ParagraphCodec.encode(text).write(to: u, atomically: true, encoding: .utf8)
            } else if let other = openAlternate {
                // Another version being tried: its own file; the book's chapter and its notes stay as they are.
                try store.saveVersion(ch, name: other, text: ParagraphCodec.encode(text))
            } else {
                try store.write(ParagraphCodec.encode(text), to: ch)
                // Notes belong to the manuscript's text.
                notes.recapture(text: text)
            }
            dirty = false
            refreshScenes()
            if openAlternate == nil {
                chapterWords[ch.id] = wordCount
                followHeadings([ch.id: text])
            }
            scheduleCommit()
        } catch {
            lastError = L("Could not save \(ch.file): ") + error.localizedDescription
        }
    }

    private func scheduleCommit() {
        pendingCommit = true
        commitTask?.cancel()
        let id = selectedChapterID ?? ""
        commitTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.commitIdleSeconds * 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.commitIfPending(message: "musset: edit \(id)", background: true)
        }
    }

    func commitIfPending(message: String, background: Bool = false) {
        guard pendingCommit else { return }
        commitTask?.cancel()
        if background { commitInBackground(message) } else { commitNow(message) }
    }

    /// libgit2 calls on this book, one at a time: a background commit never overlaps one made in place.
    @ObservationIgnored private let gitQueue = DispatchQueue(label: "app.musset.git")

    func commitNow(_ message: String) {
        guard git.isRepo else { pendingCommit = false; return }
        if piste != nil { commitPiste(message); return }
        let git = git, paths = trackedPaths
        do {
            committed(try gitQueue.sync { try git.commit(paths: paths, message: message) })
        } catch {
            lastError = "git: \(error.localizedDescription)"
        }
    }

    /// The same, off the main thread: a commit takes ~100 ms on a real book, and leaving a chapter one
    /// has just written in must not wait for it.
    func commitInBackground(_ message: String) {
        guard git.isRepo else { pendingCommit = false; return }
        // A track's commit touches no files and takes a few milliseconds.
        if piste != nil { commitPiste(message); return }
        pendingCommit = false
        let git = git, paths = trackedPaths
        gitQueue.async { [weak self] in
            let result = Result { try git.commit(paths: paths, message: message) }
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success(let made): self.committed(made)
                case .failure(let error): self.lastError = "git: \(error.localizedDescription)"; self.pendingCommit = true
                }
            }
        }
    }

    private func committed(_ made: Bool) {
        // A later commit went through: the earlier failure no longer holds.
        if lastError?.hasPrefix("git:") == true { lastError = nil }
        if made {
            lastCommitAt = Date()
            // A shared book follows the author's saves on the server.
            Collab.shared.sync(self)
        }
        pendingCommit = false
    }

    /// What the sync brought was written to disk: everything shown follows. The chapter being written only moves if its text changed.
    func reloadAfterSync() {
        if let m = try? store.loadManifest() { manifest = m }
        plot = PlotGrid.load(root)
        pistes = Pistes.load(root)
        jalons = git.tags(matching: "jalon/*")
        bible.reload()
        trash = TrashStore(root: root).load()
        if selectedChapter == nil, let first = manifest.chapters.first { selectedChapterID = first.id; state.lastChapter = first.id }
        if piste == nil, let ch = selectedChapter {
            versions = store.versions(of: ch)
            let fresh = ParagraphCodec.decode(openAlternate.map { store.readVersion(ch, $0) } ?? store.read(ch))
            if fresh != text { text = fresh; dirty = false }
            notes.load(chapter: ch, text: text)
        }
        countAllWords()
    }

    /// Called when the app quits or the book is switched away.
    func close() {
        flushSave()
        notes.save()
        commitIfPending(message: "musset: edit \(selectedChapterID ?? "")")
        store.saveState(state)
    }

    func saveManifest() {
        do { try store.saveManifest(manifest) } catch { lastError = error.localizedDescription }
    }

    /// Anything else dropped on the list (text dragged from the page) moves nothing.
    func moveChapters(ids: [String], to destination: Int) {
        let source = IndexSet(ids.compactMap { id in manifest.chapters.firstIndex { $0.id == id } })
        guard !source.isEmpty else { return }
        let before = manifest.chapters.map(\.id)
        manifest.chapters.move(fromOffsets: source, toOffset: destination)
        guard manifest.chapters.map(\.id) != before else { return }
        saveManifest()
        commitNow("musset: reorder chapters")
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
        pendingCommit = true
    }

    /// Renaming rewrites the heading. A chapter without one keeps its text and takes the name.
    func renameChapter(_ id: String, to title: String) {
        let title = title.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty, inManuscript(), let i = manifest.chapters.firstIndex(where: { $0.id == id }) else { return }
        if let renamed = BookStore.retitled(editorText(of: id), to: title) {
            if id == selectedChapterID {
                replaceText(renamed)
            } else {
                do { try store.write(ParagraphCodec.encode(renamed), to: manifest.chapters[i]) } catch { lastError = error.localizedDescription; return }
                chapterWords[id] = BookStore.wordCount(renamed)
            }
        }
        if manifest.chapters[i].title != title {
            manifest.chapters[i].title = title
            saveManifest()
        }
        commitNow("musset: rename chapter \(id)")
    }

    func setStatus(_ id: String, _ status: ChapterStatus) {
        let value = status == .draft ? nil : status
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
        chapterWords[entry.id] = BookStore.wordCount(store.read(entry))
        saveManifest()
        commitNow("musset: add chapter \(entry.id)")
        open(entry.id)
    }

    /// A free id and file for a new chapter, beside the book's last one.
    func newChapterEntry(title: String) -> ChapterEntry {
        let n = manifest.chapters.count
        let slug = title.lowercased().folding(options: .diacriticInsensitive, locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: "_")
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

    /// Re-reads the open chapter's scenes; a renamed marker carries its plot row along when it is the only change.
    func refreshScenes() {
        guard let id = selectedChapterID else { return }
        let new = Scenes.parse(text)
        let old = scenes[id] ?? []
        if old.count == new.count {
            for (a, b) in zip(old, new) where a.key != b.key && plot.rows[id]?[b.key] == nil { plot.rename(id, from: a.key, to: b.key); savePlot() }
        }
        scenes[id] = new
    }

    /// The text of a chapter in editor form (the open one as edited).
    func editorText(of chapterID: String) -> String {
        if editorIsBook(chapterID) { return text }
        guard let ch = anyChapter(chapterID) else { return "" }
        return ParagraphCodec.decode(chapterText(ch))
    }

    func sceneStatus(_ chapterID: String, _ key: String) -> ChapterStatus { plot.row(chapterID, key).status ?? .draft }

    func setSceneStatus(_ chapterID: String, _ key: String, _ status: ChapterStatus) {
        plot.update(chapterID, key) { $0.status = status == .draft ? nil : status }
        savePlot()
    }

    func savePlot() {
        do { try plot.save(root); pendingCommit = true } catch { lastError = error.localizedDescription }
    }

    /// Renames a scene of a chapter that is not open: rewrites its marker on disk. (The open chapter goes through the editor.)
    func renameSceneOnDisk(_ chapterID: String, _ scene: ChapterScene, to title: String) {
        guard inManuscript() else { return }
        guard chapterID != selectedChapterID, let marker = scene.marker,
              let ch = manifest.chapters.first(where: { $0.id == chapterID }) else { return }
        let t = editorText(of: chapterID) as NSString
        let updated = t.replacingCharacters(in: marker, with: Scenes.markerLine(title))
        do {
            try store.write(ParagraphCodec.encode(updated), to: ch)
            plot.rename(chapterID, from: scene.key, to: title)
            savePlot()
            scenes[chapterID] = Scenes.parse(updated)
            commitNow("musset: rename scene in \(chapterID)")
        } catch { lastError = error.localizedDescription }
    }

    /// What it takes to put a scene back: the editor's undo stops at the chapter.
    struct SceneMoveUndo {
        var title: String
        var chapters: [(id: String, text: String, notes: [Note])]
        var plot: PlotGrid
    }
    var lastSceneMove: SceneMoveUndo?

    private func writeChapterText(_ id: String, _ new: String) throws {
        guard let ch = manifest.chapters.first(where: { $0.id == id }) else { return }
        if id == selectedChapterID {
            replaceText(new)
        } else {
            try store.write(ParagraphCodec.encode(new), to: ch)
        }
        chapterWords[id] = BookStore.wordCount(new)
        scenes[id] = Scenes.parse(new)
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
                                 chapters: [(source, sourceText, notes.notes(of: source))] + (source == target ? [] : [(target, targetText, notes.notes(of: target))]),
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
                let leaving = notes.notes(of: source).filter { n in
                    (Anchoring.resolve(n.anchor, in: sourceText)).map { NSIntersectionRange($0, scene.range).length == $0.length } ?? false
                }
                notes.transfer(Set(leaving.map(\.id)), from: source, to: target)
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
                notes.replaceAll(c.notes, in: c.id)
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
        loadReference()
    }

    /// Shows `version` read-only beside the editor for the open chapter (nil closes it). Remembered per chapter.
    func showBeside(_ version: String?) {
        if piste != nil { manuscriptBeside = version != nil; loadReference(); return }
        guard let id = selectedChapterID else { return }
        var refs = state.references ?? [:]
        refs[id] = version
        state.references = refs.isEmpty ? nil : refs
        store.saveState(state)
        loadReference()
    }

    /// A reference that became the active version, or was deleted, closes.
    func loadReference() {
        if piste != nil {
            guard let ch = selectedChapter, manuscriptBeside else { reference = nil; referenceText = ""; return }
            reference = L("The manuscript")
            referenceText = ParagraphCodec.decode(store.read(ch))
            return
        }
        guard let ch = selectedChapter, let name = state.references?[ch.id],
              name != editingVersion, store.versions(of: ch).contains(name) else {
            reference = nil; referenceText = ""
            return
        }
        reference = name
        referenceText = ParagraphCodec.decode(store.readVersion(ch, name))
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

    /// Saves the current text as a new alternate version (the active one is unchanged).
    func newVersion(named name: String, text body: String? = nil, activate: Bool = false) {
        guard inManuscript() else { return }
        flushSave()
        guard let ch = selectedChapter else { return }
        let vname = store.uniqueVersionName(ch, base: name)
        do {
            // `body` comes from outside (an AI revision, git history): already standard Markdown.
            try store.saveVersion(ch, name: vname, text: body ?? ParagraphCodec.encode(text))
            if activate { try activateVersion(vname, commit: false) }
            refreshVersions()
            commitNow("musset: new version \(vname) of \(ch.id)")
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
        chapterWords[ch.id] = BookStore.wordCount(ParagraphCodec.decode(store.read(updated)))
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
            if state.references?[ch.id] == old { var r = state.references ?? [:]; r[ch.id] = fresh; state.references = r; store.saveState(state) }
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

    func importRevisions(_ items: [(name: String, url: URL)]) {
        guard inManuscript() else { return }
        guard let ch = selectedChapter else { return }
        for item in items {
            guard let body = try? String(contentsOf: item.url, encoding: .utf8) else { continue }
            let name = store.uniqueVersionName(ch, base: item.name)
            try? store.saveVersion(ch, name: name, text: body)
        }
        refreshVersions()
        commitNow("musset: import \(items.count) revision(s) for \(ch.id)")
    }

    /// How many typographic fixes each chapter needs (active versions).
    func typographyPreview() -> (edits: Int, chapters: Int) {
        var edits = 0, chapters = 0
        for ch in manifest.chapters {
            let n = Typography.correctedDocument(editorIsBook(ch.id) ? text : store.read(ch), lang: manifest.lang).count
            if n > 0 { edits += n; chapters += 1 }
        }
        return (edits, chapters)
    }

    /// Applies the book's typographic conventions to every chapter, in a single commit.
    func applyTypographyToBook() {
        guard inManuscript() else { return }
        flushSave()
        commitIfPending(message: "musset: edit \(selectedChapterID ?? "")")
        for ch in manifest.chapters {
            let current = editorIsBook(ch.id) ? text : store.read(ch)
            let fixed = Typography.correctedDocument(current, lang: manifest.lang)
            guard fixed.count > 0 else { continue }
            if editorIsBook(ch.id) {
                replaceText(fixed.text)   // editor form in, editor form out
            } else {
                do { try store.write(fixed.text, to: ch) } catch { lastError = L("Could not save \(ch.file): ") + error.localizedDescription }
            }
        }
        pendingCommit = true
        commitNow("musset: typography (\(manifest.lang))")
    }

    /// Replaces the editor text (used by history restore); goes through the normal save/commit path.
    func replaceText(_ newText: String) {
        textDidChange(newText)
        // The live ranges belong to the old text: saving now must not write them back as anchors.
        notes.resolveAll(in: newText)
        flushSave()
    }
}
