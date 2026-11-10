import Foundation

/// A chapter's versions: one is in the book (the chapter's file), the others wait beside it
/// (`.musset/versions/<chapter>/<name>.md`). One can write in any of them; the book only reads its own.
extension BookSession {
    /// What « Put in the book » just did, so it can be undone.
    struct VersionSwitch: Equatable {
        let chapterID: String
        let name: String
        let previous: String
    }

    /// The version open in the editor when it isn't the book's; nil when one writes the book's.
    var openAlternate: String? {
        _ = versionTick   // `state` isn't observed: this is what tells the views.
        guard piste == nil, let ch = selectedChapter, let name = state.openVersions?[ch.id],
              name != ch.activeVersion, versions.contains(name) else { return nil }
        return name
    }

    /// The version in the editor, by its stored name.
    var editingVersion: String? { openAlternate ?? selectedChapter?.activeVersion }

    /// Whether the editor holds the book's text of this chapter (so it can be read instead of the file).
    func editorIsBook(_ chapterID: String) -> Bool { chapterID == selectedChapterID && openAlternate == nil }

    /// A version's name as shown: the first one, never named, is « Première version ».
    static func versionLabel(_ name: String) -> String {
        name == "main" ? L("First version") : name
    }

    func rememberOpenVersion(_ name: String?, for chapterID: String) {
        var open = state.openVersions ?? [:]
        open[chapterID] = name
        state.openVersions = open.isEmpty ? nil : open
        store.saveState(state)
        versionTick += 1
    }

    /// Writes in `name` from now on; the book keeps its own version.
    func openVersion(_ name: String) {
        guard let ch = selectedChapter, name != editingVersion else { return }
        flushSave()
        rememberOpenVersion(name == ch.activeVersion ? nil : name, for: ch.id)
        // The side shows something else than the editor.
        if state.references?[ch.id] == name { showBeside(nil) }
        load(ch)
        refreshVersionCounts()
    }

    /// The book now reads `name`. Nothing is lost: the version it had stays among the others.
    @discardableResult
    func putInBook(_ name: String) -> VersionSwitch? {
        guard inManuscript(), let ch = selectedChapter, name != ch.activeVersion, versions.contains(name) else { return nil }
        let previous = ch.activeVersion
        do { try activateVersion(name, commit: true, keepEditor: true) } catch { lastError = error.localizedDescription; return nil }
        guard selectedChapter?.activeVersion == name else { return nil }
        let done = VersionSwitch(chapterID: ch.id, name: name, previous: previous)
        lastVersionSwitch = done
        return done
    }

    /// Undoes the last « Put in the book ».
    func undoVersionSwitch() {
        guard let s = lastVersionSwitch, s.chapterID == selectedChapterID else { return }
        lastVersionSwitch = nil
        guard inManuscript() else { return }
        do { try activateVersion(s.previous, commit: true, keepEditor: true) } catch { lastError = error.localizedDescription }
    }

    /// « Try something else »: a new version of the open chapter, a copy of what is being written or a blank
    /// page, opened in the editor. The book keeps its version. `currentName` names the version left behind.
    func tryAnotherVersion(named newName: String, blank: Bool, currentName: String? = nil) {
        guard inManuscript(), let ch = selectedChapter else { return }
        flushSave()
        if let current = currentName?.trimmingCharacters(in: .whitespaces), !current.isEmpty,
           let from = editingVersion, Self.versionLabel(from) != current {
            renameVersion(from, to: current)
        }
        guard let ch2 = selectedChapter else { return }
        let name = store.uniqueVersionName(ch2, base: newName.isEmpty ? L("Version") : newName)
        let body = blank ? "# \(ch.title)\n\n" : ParagraphCodec.encode(text)
        do {
            try store.saveVersion(ch2, name: name, text: body)
        } catch { lastError = error.localizedDescription; return }
        versions = store.versions(of: ch2)
        rememberOpenVersion(name, for: ch2.id)
        load(ch2)
        refreshVersionCounts()
        commitNow("musset: nouvelle version « \(name) » de \(ch2.id)")
    }

    /// Into the book's Trash, from where it can come back. The book's own version can't go: another must be in the book first.
    func versionToTrash(_ name: String) {
        guard inManuscript(), let ch = selectedChapter, name != ch.activeVersion, versions.contains(name) else { return }
        if name == openAlternate { flushSave() }
        let trashStore = TrashStore(root: root)
        var item = TrashItem(kind: .version, title: "\(ch.title) — \(Self.versionLabel(name))")
        item.versionChapter = ch.id
        item.versionName = name
        do {
            try FileManager.default.createDirectory(at: trashStore.dir, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: store.versionURL(ch, name), to: trashStore.sheetFile(item.id))
        } catch { lastError = error.localizedDescription; return }
        trash.insert(item, at: 0)
        saveTrash()
        if state.openVersions?[ch.id] == name { rememberOpenVersion(nil, for: ch.id) }
        if state.references?[ch.id] == name { showBeside(nil) }
        load(ch)
        refreshVersionCounts()
        shelfChanges += 1
        commitNow("musset: version « \(name) » de \(ch.id) à la corbeille")
    }

    /// Back among the chapter's versions, under a free name.
    func restoreVersion(_ item: TrashItem) -> Bool {
        guard let id = item.versionChapter, let name = item.versionName, let ch = anyChapter(id) else {
            lastError = L("This chapter is no longer in the book.")
            return false
        }
        let target = store.uniqueVersionName(ch, base: name)
        do {
            try FileManager.default.createDirectory(at: store.versionsFolder(for: ch), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: TrashStore(root: root).sheetFile(item.id), to: store.versionURL(ch, target))
        } catch { lastError = error.localizedDescription; return false }
        if ch.id == selectedChapterID { versions = store.versions(of: ch) }
        refreshVersionCounts()
        return true
    }

    /// How many versions each chapter has, for the mark beside it in the list.
    func refreshVersionCounts() {
        var out: [String: Int] = [:]
        for ch in manifest.chapters + draftChapters {
            let n = store.versions(of: ch).count
            if n > 1 { out[ch.id] = n }
        }
        if out != versionCounts { versionCounts = out }
    }
}
