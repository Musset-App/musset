import AppKit
import Foundation

extension BookSession {
    enum ShelfTarget { case drafts, trash }

    var draftChapters: [ChapterEntry] { manifest.drafts ?? [] }
    var draftSheets: [BibleEntry] { bible.entries(in: BibleKind.draft.folder) }

    /// Handles a drop on Drafts or Trash. Returns whether anything moved, and where Bible entries went (nil: into the Trash).
    @discardableResult
    func drop(_ wires: [String], on target: ShelfTarget) -> (accepted: Bool, sheets: [String: String?]) {
        let drags = wires.compactMap(ShelfDrag.init(wire:))
        guard !drags.isEmpty, inManuscript() else { return (false, [:]) }
        var accepted = false
        var sheets: [String: String?] = [:]
        for drag in drags {
            switch (drag, target) {
            case (.chapter(let id), .drafts): accepted = chapterToDrafts(id) || accepted
            case (.chapter(let id), .trash): accepted = chapterToTrash(id) || accepted
            case (.note(let chapter, let id), .drafts): accepted = noteToDrafts(id, in: chapter) || accepted
            case (.note(let chapter, let id), .trash): accepted = noteToTrash(id, in: chapter) || accepted
            case (.sheet(let path), .drafts):
                if let moved = sheetToDrafts(path) { sheets[path] = .some(moved); accepted = true }
            case (.sheet(let path), .trash):
                if sheetToTrash(path) { sheets[path] = .some(nil); accepted = true }
            case (.trashed(let id), .drafts): accepted = restoreFromTrash(id, toDrafts: true) || accepted
            case (.trashed, .trash), (.folder, _), (.tab, _): break
            }
        }
        if accepted { shelfChanges += 1 }
        return (accepted, sheets)
    }

    /// A drop on the book's chapter list: reorders it, or brings a chapter back from Drafts or Trash at that place.
    /// `part`, when given, is the part of the place it lands in (`.some(nil)`: outside any part).
    func dropOnBook(_ wires: [String], at offset: Int, part: String?? = .none) {
        for wire in wires {
            var landed: String?
            switch ShelfDrag(wire: wire) {
            case .chapter(let id) where manifest.chapters.contains(where: { $0.id == id }):
                moveChapters(ids: [id], to: offset)
                landed = id
            case .chapter(let id):
                if draftToBook(id, at: offset) { landed = id }
            case .trashed(let id):
                let entry = trash.first { $0.id == id }?.chapter
                if entry != nil, restoreFromTrash(id, at: offset) { landed = entry?.id }
            case .sheet(let path) where bible.entry(path: path).map({ BibleStore.isInside($0.folder, BibleKind.draft.folder) }) == true:
                landed = sheetToBook(path, at: offset)
            default: break
            }
            if let landed, case .some(let part) = part { putInPart(landed, part) }
        }
    }

    // MARK: Chapters

    @discardableResult
    func chapterToDrafts(_ id: String) -> Bool {
        guard inManuscript(), let i = manifest.chapters.firstIndex(where: { $0.id == id }) else { return false }
        flushSave()
        let entry = manifest.chapters.remove(at: i)
        manifest.drafts = draftChapters + [entry]
        saveManifest()
        commitNow("musset: \(id) aux brouillons")
        return true
    }

    @discardableResult
    func draftToBook(_ id: String, at offset: Int? = nil) -> Bool {
        guard inManuscript(), let i = draftChapters.firstIndex(where: { $0.id == id }) else { return false }
        flushSave()
        let entry = draftChapters[i]
        manifest.drafts?.remove(at: i)
        manifest.chapters.insert(entry, at: min(offset ?? manifest.chapters.count, manifest.chapters.count))
        saveManifest()
        commitNow("musset: \(id) revient dans le livre")
        return true
    }

    /// A draft written in the Bible becomes a chapter at that place: its own file, the sheet's text, the sheet's title.
    /// The sheet goes to the book's Trash, so nothing is lost if this was a mistake.
    @discardableResult
    func sheetToBook(_ path: String, at offset: Int? = nil) -> String? {
        guard inManuscript(), let sheet = bible.entry(path: path), !sheet.isFile else { return nil }
        flushSave()
        let entry = newChapterEntry(title: sheet.title)
        var text = sheet.body.trimmingCharacters(in: .newlines)
        if !text.hasPrefix("# ") { text = "# \(sheet.title)\n\n" + text }
        do {
            try store.write(text + "\n", to: entry)
        } catch {
            lastError = error.localizedDescription
            return nil
        }
        manifest.chapters.insert(entry, at: min(offset ?? manifest.chapters.count, manifest.chapters.count))
        chapterCounts[entry.id] = TextCounts(store.read(entry))
        saveManifest()
        _ = sheetToTrash(path, commit: false)
        shelfChanges += 1
        commitNow("musset: « \(sheet.title) » entre dans le livre")
        return entry.id
    }

    /// The file stays where it is, with its notes and versions. Only the book stops counting it.
    @discardableResult
    func chapterToTrash(_ id: String) -> Bool {
        guard inManuscript() else { return false }
        flushSave()
        let item: TrashItem
        var neighbour: String?
        if let i = manifest.chapters.firstIndex(where: { $0.id == id }) {
            let entry = manifest.chapters.remove(at: i)
            item = TrashItem(.chapter(entry, index: i, wasDraft: false), title: entry.title)
            neighbour = manifest.chapters[safe: i]?.id ?? manifest.chapters.last?.id
        } else if let i = draftChapters.firstIndex(where: { $0.id == id }) {
            let entry = draftChapters[i]
            manifest.drafts?.remove(at: i)
            item = TrashItem(.chapter(entry, index: i, wasDraft: true), title: entry.title)
            neighbour = manifest.chapters.first?.id
        } else { return false }
        trash.append(item)
        saveTrash()
        saveManifest()
        commitNow("musset: \(id) à la corbeille")
        if selectedChapterID == id {
            // The chapter is gone: nothing to save into it any more.
            focused?.dirty = false
            closeChapter()
            if let neighbour { open(neighbour) }
        }
        return true
    }

    // MARK: Notes

    /// A note becomes a draft of its own: its words, the passage it was on, and its discussion.
    @discardableResult
    func noteToDrafts(_ id: UUID, in chapter: String) -> Bool {
        let notes = noteStore(for: chapter)
        guard let note = notes.notes(of: chapter).first(where: { $0.id == id }) else { return false }
        var parts: [String] = []
        if note.hasPassage { parts.append("> " + note.anchor.quote.replacingOccurrences(of: "\n", with: "\n> ")) }
        parts.append(note.body)
        parts += note.replies.map { "\($0.author.label) : \($0.body)" }
        var meta = ["date": ISO8601DateFormatter().string(from: Date())]
        if chapter != NoteStore.bookPage { meta["from"] = chapter }
        do {
            try bible.create(title: Self.shortTitle(note), kind: .draft, body: parts.joined(separator: "\n\n"), meta: meta)
        } catch {
            lastError = error.localizedDescription
            return false
        }
        _ = notes.remove(id, in: chapter)
        commitNow("musset: note aux brouillons")
        return true
    }

    @discardableResult
    func noteToTrash(_ id: UUID, in chapter: String) -> Bool {
        let notes = noteStore(for: chapter)
        guard let note = notes.notes(of: chapter).first(where: { $0.id == id }),
              let index = notes.remove(id, in: chapter) else { return false }
        trash.append(TrashItem(.note(note, chapter: chapter, index: index), title: Self.shortTitle(note)))
        saveTrash()
        commitNow("musset: note à la corbeille")
        return true
    }

    private static func shortTitle(_ note: Note) -> String {
        let source = note.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? note.anchor.quote : note.body
        let words = BibleLinks.plain(source).split(whereSeparator: { $0.isWhitespace }).prefix(7).joined(separator: " ")
        return words.isEmpty ? L("Note") : words
    }

    // MARK: Bible entries

    func sheetToDrafts(_ path: String) -> String? {
        guard var entry = bible.entry(path: path), !entry.isFile, entry.folder != BibleKind.draft.folder else { return nil }
        do {
            let moved = try bible.store.move(path, toFolder: BibleKind.draft.folder)
            entry.path = moved
            if entry.kind == .note { entry.kind = .draft; try bible.store.write(entry) }
            bible.reload()
            sheetMoved(from: path, to: moved)
            commitNow("musset: fiche aux brouillons")
            return moved
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    /// Only Markdown: documents can weigh a lot and stay out of git, so they keep going to the Finder's Trash.
    func sheetToTrash(_ path: String, commit: Bool = true) -> Bool {
        guard let entry = bible.entry(path: path), !entry.isFile else { return false }
        let item = TrashItem(.sheet(path: path), title: entry.title)
        let store = TrashStore(root: root)
        do {
            try FileManager.default.createDirectory(at: store.dir, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: bible.store.url(path), to: store.sheetFile(item.id))
        } catch {
            lastError = error.localizedDescription
            return false
        }
        trash.append(item)
        saveTrash()
        bible.reload()
        if commit { commitNow("musset: fiche à la corbeille") }
        return true
    }

    // MARK: Out of the Trash

    /// Back where it was. A chapter can be sent to a place in the book, or to Drafts.
    @discardableResult
    func restoreFromTrash(_ id: UUID, at offset: Int? = nil, toDrafts: Bool = false) -> Bool {
        guard inManuscript(), let i = trash.firstIndex(where: { $0.id == id }) else { return false }
        let item = trash[i]
        switch item.payload {
        case .chapter(let entry, let index, let wasDraft):
            if toDrafts || (offset == nil && wasDraft == true) {
                manifest.drafts = draftChapters + [entry]
            } else {
                manifest.chapters.insert(entry, at: min(offset ?? index ?? manifest.chapters.count, manifest.chapters.count))
            }
            saveManifest()
            chapterCounts[entry.id] = TextCounts(ParagraphCodec.decode(store.read(entry)))
        case .note(let note, let was, let index):
            let known = manifest.chapters.map(\.id) + draftChapters.map(\.id)
            let chapter = was.flatMap { known.contains($0) ? $0 : nil } ?? NoteStore.bookPage
            noteStore(for: chapter).restore(note, in: chapter, at: index ?? 0)
            if toDrafts {
                trash.remove(at: i)
                saveTrash()
                return noteToDrafts(note.id, in: chapter)
            }
            resolveNotes(in: chapter)
        case .sheet(let path):
            let source = TrashStore(root: root).sheetFile(item.id)
            let folder = toDrafts ? BibleKind.draft.folder : (path as NSString).deletingLastPathComponent
            let stem = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
            let target = bible.store.freePath(title: stem, folder: folder)
            do {
                try bible.store.prepare(bible.store.url(target))
                try FileManager.default.moveItem(at: source, to: bible.store.url(target))
            } catch {
                lastError = error.localizedDescription
                return false
            }
            bible.reload()
            // Back under another name or in Drafts: what was kept for it finds it again.
            sheetMoved(from: path, to: target)
        case .version:
            guard restoreVersion(item) else { return false }
        }
        trash.remove(at: i)
        saveTrash()
        shelfChanges += 1
        commitNow("musset: « \(item.title) » sort de la corbeille")
        return true
    }

    /// Out of the book for good. Files go to the Finder's Trash, and the book's history still has them.
    func deleteFromTrash(_ ids: Set<UUID>) {
        guard inManuscript() else { return }
        let fm = FileManager.default
        var gone: [String] = []
        for item in trash where ids.contains(item.id) {
            switch item.payload {
            case .chapter(let entry, _, _):
                gone.append(entry.file)
                forgetChapter(entry.id)
                for url in [store.url(for: entry), NoteStore.url(root, entry.id), store.versionsDir.appendingPathComponent(entry.id)] where fm.fileExists(atPath: url.path) {
                    try? fm.trashItem(at: url, resultingItemURL: nil)
                }
            case .sheet, .version:
                let file = TrashStore(root: root).sheetFile(item.id)
                if fm.fileExists(atPath: file.path) { try? fm.trashItem(at: file, resultingItemURL: nil) }
            case .note: break
            }
        }
        trash.removeAll { ids.contains($0.id) }
        saveTrash()
        if git.isRepo { _ = try? git.commit(paths: gone + [".musset"], message: "musset: corbeille vidée") }
        shelfChanges += 1
    }

    /// A chapter is out of the book for good: what was kept under its id goes with it (its plot rows and synopsis, its
    /// place in the page, the versions shown), so that a new chapter given the same id starts with nothing.
    private func forgetChapter(_ id: String) {
        if plot.rows[id] != nil || plot.chapterSynopses?[id] != nil {
            plot.rows[id] = nil
            plot.setChapterSynopsis(id, "")
            savePlot()
        }
        scenes[id] = nil
        sections[id] = nil
        chapterCounts[id] = nil
        state.selections[id] = nil
        state.references?[id] = nil
        state.openVersions?[id] = nil
        stateChanged()
    }

    /// What a Trash line holds, to read it before deciding.
    func trashPreview(_ item: TrashItem) -> String {
        switch item.payload {
        case .chapter(let entry, _, _): ParagraphCodec.decode(store.read(entry))
        case .note(let note, _, _): [note.anchor.quote, note.body].filter { !$0.isEmpty }.joined(separator: "\n\n")
        case .sheet: (try? String(contentsOf: TrashStore(root: root).sheetFile(item.id), encoding: .utf8)) ?? ""
        case .version: ParagraphCodec.decode((try? String(contentsOf: TrashStore(root: root).sheetFile(item.id), encoding: .utf8)) ?? "")
        }
    }

    func saveTrash() {
        do { try TrashStore(root: root).save(trash) } catch { lastError = error.localizedDescription }
    }

    /// A draft chapter holding `body`, out of the book until it is dragged in.
    func newDraft(title: String, body: String) -> Bool {
        guard inManuscript() else { return false }
        let entry = newChapterEntry(title: title)
        do { try store.write("# \(title)\n\n" + ParagraphCodec.encode(body) + "\n", to: entry) } catch { lastError = error.localizedDescription; return false }
        manifest.drafts = draftChapters + [entry]
        saveManifest()
        chapterCounts[entry.id] = TextCounts(body)
        shelfChanges += 1
        commitNow("musset: Ultra Focus dans les brouillons")
        return true
    }

    /// Takes `range` out of a chapter one is not in, if the book's text still holds `expected` there
    /// (WordStar's ⌃K V with a block marked in another chapter). In a track, nothing moves: the book's folder doesn't change.
    func removeFromChapter(_ id: String, range: NSRange, expected: String) -> Bool {
        guard piste == nil, id != selectedChapterID, anyChapter(id) != nil else { return false }
        let text = editorText(of: id) as NSString
        guard NSMaxRange(range) <= text.length, text.substring(with: range) == expected else { return false }
        let out = text.replacingCharacters(in: range, with: "")
        do { try writeChapterText(id, out) } catch { lastError = error.localizedDescription; return false }
        commitNow("musset: bloc déplacé de \(id)")
        return true
    }
}
