import Foundation

/// Something put in the book's Trash, with what it takes to put it back.
struct TrashItem: Identifiable, Equatable {
    enum Kind: String, Codable { case chapter, note, sheet, version }

    /// What it is, and where it was.
    enum Payload: Equatable {
        /// A chapter: its entry and its place, in the book or among the drafts. Its file stays where it is.
        case chapter(ChapterEntry, index: Int?, wasDraft: Bool?)
        /// A note, the chapter it was on and its place among that chapter's notes.
        case note(Note, chapter: String?, index: Int?)
        /// A Bible entry: where it was under `bible/`. Its file waits in `.musset/trash/`.
        case sheet(path: String)
        /// A version of a chapter: which chapter, under which name. Its file waits in `.musset/trash/`.
        case version(chapter: String, name: String)
    }

    var id = UUID()
    var title: String
    var date = Date()
    var payload: Payload

    init(_ payload: Payload, title: String) {
        self.payload = payload
        self.title = title
    }

    var kind: Kind {
        switch payload {
        case .chapter: .chapter
        case .note: .note
        case .sheet: .sheet
        case .version: .version
        }
    }

    /// The chapter it holds, if it is one.
    var chapter: ChapterEntry? { if case .chapter(let entry, _, _) = payload { entry } else { nil } }
}

/// In `trash.json` an item is flat: its kind, and beside it the fields of that kind.
extension TrashItem: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, kind, title, date, chapter, index, wasDraft, note, noteChapter, sheetPath, versionChapter, versionName
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        date = try c.decode(Date.self, forKey: .date)
        let index = try c.decodeIfPresent(Int.self, forKey: .index)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .chapter: payload = .chapter(try c.decode(ChapterEntry.self, forKey: .chapter), index: index, wasDraft: try c.decodeIfPresent(Bool.self, forKey: .wasDraft))
        case .note: payload = .note(try c.decode(Note.self, forKey: .note), chapter: try c.decodeIfPresent(String.self, forKey: .noteChapter), index: index)
        case .sheet: payload = .sheet(path: try c.decode(String.self, forKey: .sheetPath))
        case .version: payload = .version(chapter: try c.decode(String.self, forKey: .versionChapter), name: try c.decode(String.self, forKey: .versionName))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(kind, forKey: .kind)
        try c.encode(title, forKey: .title)
        try c.encode(date, forKey: .date)
        switch payload {
        case .chapter(let entry, let index, let wasDraft):
            try c.encode(entry, forKey: .chapter)
            try c.encodeIfPresent(index, forKey: .index)
            try c.encodeIfPresent(wasDraft, forKey: .wasDraft)
        case .note(let note, let chapter, let index):
            try c.encode(note, forKey: .note)
            try c.encodeIfPresent(chapter, forKey: .noteChapter)
            try c.encodeIfPresent(index, forKey: .index)
        case .sheet(let path):
            try c.encode(path, forKey: .sheetPath)
        case .version(let chapter, let name):
            try c.encode(chapter, forKey: .versionChapter)
            try c.encode(name, forKey: .versionName)
        }
    }
}

/// `.musset/trash.json`, tracked by git like the rest of the book.
struct TrashStore {
    let root: URL
    private var url: URL { root.appendingPathComponent(".musset/trash.json") }
    var dir: URL { root.appendingPathComponent(".musset/trash", isDirectory: true) }

    func load() -> [TrashItem] {
        // An item that cannot be read (written by hand, or by a Musset to come) is left out, not the whole Trash.
        struct Kept: Decodable {
            let item: TrashItem?
            init(from decoder: Decoder) { item = try? TrashItem(from: decoder) }
        }
        return (JSONFile.read([Kept].self, at: url, iso8601: true) ?? []).compactMap(\.item)
    }

    func save(_ items: [TrashItem]) throws {
        if items.isEmpty {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            return
        }
        try JSONFile.write(items, to: url, iso8601: true)
    }

    func sheetFile(_ id: UUID) -> URL { dir.appendingPathComponent(id.uuidString + ".md") }
}
