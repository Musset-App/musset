import AppKit
import Foundation

/// What can be dragged onto Drafts or Trash, as the plain text a drag carries.
enum ShelfDrag: Equatable {
    case chapter(String)
    case note(chapter: String, id: UUID)
    case sheet(String)
    case trashed(UUID)
    /// A folder of the Bible, moved within the Bible only.
    case folder(String)

    private static let prefix = "musset-drag|"

    var wire: String {
        switch self {
        case .chapter(let id): Self.prefix + "chapter|" + id
        case .note(let chapter, let id): Self.prefix + "note|" + id.uuidString + "|" + chapter
        case .sheet(let path): Self.prefix + "sheet|" + path
        case .trashed(let id): Self.prefix + "trashed|" + id.uuidString
        case .folder(let path): Self.prefix + "folder|" + path
        }
    }

    /// Anything else dropped here (text dragged from the page, from another app) is not ours.
    init?(wire: String) {
        guard wire.hasPrefix(Self.prefix) else { return nil }
        let parts = wire.dropFirst(Self.prefix.count).split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        switch parts[0] {
        case "chapter": self = .chapter(parts[1])
        case "sheet": self = .sheet(parts[1])
        case "folder": self = .folder(parts[1])
        case "trashed":
            guard let id = UUID(uuidString: parts[1]) else { return nil }
            self = .trashed(id)
        case "note":
            let rest = parts[1].split(separator: "|", maxSplits: 1).map(String.init)
            guard rest.count == 2, let id = UUID(uuidString: rest[0]) else { return nil }
            self = .note(chapter: rest[1], id: id)
        default: return nil
        }
    }
}

/// Something put in the book's Trash, with what it takes to put it back.
struct TrashItem: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case chapter, note, sheet, version }

    var id = UUID()
    var kind: Kind
    var title: String
    var date = Date()
    /// A chapter: its entry and place. Its file stays where it is.
    var chapter: ChapterEntry? = nil
    var index: Int? = nil
    var wasDraft: Bool? = nil
    /// A note: the note, and the chapter it was on.
    var note: Note? = nil
    var noteChapter: String? = nil
    /// A Bible entry: where it was under `bible/`. Its file waits in `.musset/trash/`.
    var sheetPath: String? = nil
    /// A version of a chapter: which chapter, under which name. Its file waits in `.musset/trash/`.
    var versionChapter: String? = nil
    var versionName: String? = nil
}

/// `.musset/trash.json`, tracked by git like the rest of the book.
struct TrashStore {
    let root: URL
    private var url: URL { root.appendingPathComponent(".musset/trash.json") }
    var dir: URL { root.appendingPathComponent(".musset/trash", isDirectory: true) }

    func load() -> [TrashItem] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode([TrashItem].self, from: data)) ?? []
    }

    func save(_ items: [TrashItem]) throws {
        if items.isEmpty {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            return
        }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try enc.encode(items).write(to: url, options: .atomic)
    }

    func sheetFile(_ id: UUID) -> URL { dir.appendingPathComponent(id.uuidString + ".md") }
}

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
            case (.trashed, .trash), (.folder, _): break
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
                let item = trash.first { $0.id == id }
                if item?.kind == .chapter, restoreFromTrash(id, at: offset) { landed = item?.chapter?.id }
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
        chapterWords[entry.id] = BookStore.wordCount(store.read(entry))
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
            item = TrashItem(kind: .chapter, title: entry.title, chapter: entry, index: i, wasDraft: false)
            neighbour = manifest.chapters[safe: i]?.id ?? manifest.chapters.last?.id
        } else if let i = draftChapters.firstIndex(where: { $0.id == id }) {
            let entry = draftChapters[i]
            manifest.drafts?.remove(at: i)
            item = TrashItem(kind: .chapter, title: entry.title, chapter: entry, index: i, wasDraft: true)
            neighbour = manifest.chapters.first?.id
        } else { return false }
        trash.append(item)
        saveTrash()
        saveManifest()
        commitNow("musset: \(id) à la corbeille")
        if selectedChapterID == id {
            selectedChapterID = nil
            if let neighbour { open(neighbour) } else { text = "" }
        }
        return true
    }

    // MARK: Notes

    /// A note becomes a draft of its own: its words, the passage it was on, and its discussion.
    @discardableResult
    func noteToDrafts(_ id: UUID, in chapter: String) -> Bool {
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
        guard let note = notes.notes(of: chapter).first(where: { $0.id == id }),
              let index = notes.remove(id, in: chapter) else { return false }
        trash.append(TrashItem(kind: .note, title: Self.shortTitle(note), index: index, note: note, noteChapter: chapter))
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
        let item = TrashItem(kind: .sheet, title: entry.title, sheetPath: path)
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
        switch item.kind {
        case .chapter:
            guard let entry = item.chapter else { return false }
            if toDrafts || (offset == nil && item.wasDraft == true) {
                manifest.drafts = draftChapters + [entry]
            } else {
                manifest.chapters.insert(entry, at: min(offset ?? item.index ?? manifest.chapters.count, manifest.chapters.count))
            }
            saveManifest()
            chapterWords[entry.id] = BookStore.wordCount(ParagraphCodec.decode(store.read(entry)))
        case .note:
            guard let note = item.note else { return false }
            let known = manifest.chapters.map(\.id) + draftChapters.map(\.id)
            let chapter = item.noteChapter.flatMap { known.contains($0) ? $0 : nil } ?? NoteStore.bookPage
            if toDrafts {
                notes.restore(note, in: chapter, at: item.index ?? 0)
                trash.remove(at: i)
                saveTrash()
                return noteToDrafts(note.id, in: chapter)
            }
            notes.restore(note, in: chapter, at: item.index ?? 0)
            notes.resolveAll(in: text)
        case .sheet:
            guard let path = item.sheetPath else { return false }
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
            switch item.kind {
            case .chapter:
                guard let entry = item.chapter else { continue }
                gone.append(entry.file)
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

    /// What a Trash line holds, to read it before deciding.
    func trashPreview(_ item: TrashItem) -> String {
        switch item.kind {
        case .chapter: item.chapter.map { ParagraphCodec.decode(store.read($0)) } ?? ""
        case .note: [item.note?.anchor.quote ?? "", item.note?.body ?? ""].filter { !$0.isEmpty }.joined(separator: "\n\n")
        case .sheet: (try? String(contentsOf: TrashStore(root: root).sheetFile(item.id), encoding: .utf8)) ?? ""
        case .version: ParagraphCodec.decode((try? String(contentsOf: TrashStore(root: root).sheetFile(item.id), encoding: .utf8)) ?? "")
        }
    }

    func saveTrash() {
        do { try TrashStore(root: root).save(trash) } catch { lastError = error.localizedDescription }
    }
}
