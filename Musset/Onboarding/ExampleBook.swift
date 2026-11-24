import Foundation

/// The book to look around in: « The Time Machine », H. G. Wells (1895), in the public domain, with what a book
/// in progress has around it: sheets for its people and places, a synopsis and an outline, notes in the margin,
/// chapters at different stages, two milestones in its history. It is made on the author's disk like any book,
/// from a text and a description kept in the app (`Resources/Example`, see `scripts/example-book`).
enum ExampleBook {
    static let author = "H. G. Wells"
    private static let marker = ".musset/example"

    struct Content: Decodable {
        struct Sheet: Decodable { var kind: String; var folder: String?; var title: String; var aliases: [String]; var fields: [String: String]; var body: String }
        struct Margin: Decodable { var quote: String; var kind: String; var body: String }
        struct Milestone: Decodable { var title: String; var note: String }
        /// A passage the first milestone has and the book no longer does: it went to the Cuts.
        struct Cut: Decodable { var chapter: Int; var after: String; var title: String; var text: String }
        var title: String
        var synopsis: String
        var chapters: [String]
        var statuses: [String]
        var sheets: [Sheet]
        var notes: [Margin]
        var milestones: [Milestone]
        var cut: Cut?
    }

    /// The languages the example exists in; the others read it in English.
    private static func code(_ lang: String) -> String {
        let short = String(lang.prefix(2)).lowercased()
        return resource(short, "json") != nil && resource(short, "md") != nil ? short : "en"
    }

    private static func resource(_ code: String, _ ext: String) -> URL? {
        Bundle.main.url(forResource: "example-time-machine-\(code)", withExtension: ext)
    }

    static func content(_ lang: String) -> Content? {
        guard let url = resource(code(lang), "json"), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Content.self, from: data)
    }

    static func title(_ lang: String) -> String { content(lang)?.title ?? "The Time Machine" }

    static func isExample(_ root: URL) -> Bool { FileManager.default.fileExists(atPath: root.appendingPathComponent(marker).path) }

    /// The chapters of the text: a `# Title` line opens each.
    static func chapters(_ markdown: String) -> [(title: String, body: String)] {
        var out: [(title: String, body: String)] = []
        for block in markdown.components(separatedBy: "\n\n") {
            if block.hasPrefix("# ") { out.append((String(block.dropFirst(2)).trimmingCharacters(in: .whitespaces), "")) }
            else if !out.isEmpty { out[out.count - 1].body += (out[out.count - 1].body.isEmpty ? "" : "\n\n") + block }
        }
        return out
    }

    /// Opens the example, making it first if it is not on this Mac yet.
    @MainActor
    static func open(in app: AppState, at location: URL, lang: String) async throws {
        guard let content = content(lang), let textURL = resource(code(lang), "md") else {
            throw BibleImporter.Failure(L("The example book is missing from the app."))
        }
        let fm = FileManager.default
        var root = location.appendingPathComponent(BibleStore.slug(content.title), isDirectory: true)
        if !isExample(root), fm.fileExists(atPath: root.path) { root = location.appendingPathComponent(BibleStore.slug(content.title) + "-example", isDirectory: true) }
        if !isExample(root) { try build(content, text: try String(contentsOf: textURL, encoding: .utf8), at: root, lang: lang) }
        app.openBook(root)
        app.showHome = false
    }

    static func build(_ content: Content, text: String, at root: URL, lang: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let store = BookStore(root: root)
        let pieces = chapters(text)

        // The chapters, as the first milestone had them: with the passage that was cut later.
        var entries: [ChapterEntry] = []
        var plot = PlotGrid.load(root)
        plot.columns = PlotGrid.columns(forGenre: "sf")
        plot.synopsis = content.synopsis
        func page(_ i: Int, cut: Bool) -> String {
            var body = pieces[i].body
            if cut, let c = content.cut, c.chapter == i, let at = body.range(of: c.after), let end = body.range(of: "\n\n", range: at.upperBound..<body.endIndex) {
                body.insert(contentsOf: "\n\n" + c.text, at: end.lowerBound)
            }
            return "# \(pieces[i].title)\n\n\(body)\n"
        }
        for (i, piece) in pieces.enumerated() {
            let slug = piece.title.slug("_", words: 5)
            let id = String(format: "%02d_%@", i + 1, slug.isEmpty ? "chapter" : slug)
            let entry = ChapterEntry(id: id, file: "\(id).md", title: piece.title)
            try store.write(page(i, cut: true), to: entry)
            entries.append(entry)
            if i < content.chapters.count { plot.update(id, "") { $0.cells["main", default: .init()].text = content.chapters[i] } }
        }
        var manifest = BookManifest(title: content.title, author: author, lang: lang, chapters: entries)
        manifest.genre = "sf"
        try store.saveManifest(manifest)
        try plot.save(root)
        try "".write(to: root.appendingPathComponent(marker), atomically: true, encoding: .utf8)

        let git = GitService(root: root)
        if !git.isRepo { try git.initRepo() }
        let paths = entries.map(\.file) + [".musset", BibleStore.folderName]
        _ = try git.commit(paths: entries.map(\.file) + [".musset"], message: "musset: new book")
        func milestone(_ i: Int) throws {
            guard i < content.milestones.count else { return }
            let m = content.milestones[i]
            try git.createTag("jalon/" + BibleStore.slug(m.title), message: m.title + (m.note.isEmpty ? "" : "\n\n" + m.note))
        }
        try milestone(0)

        // The revision: the passage is cut and kept, the chapters move on, the Bible fills.
        let bible = BibleStore(root: root)
        if let c = content.cut, c.chapter < entries.count {
            try store.write(page(c.chapter, cut: false), to: entries[c.chapter])
            var entry = BibleEntry(path: bible.freePath(title: c.title, folder: BibleKind.cut.folder), kind: .cut, title: c.title)
            entry.meta = ["from": entries[c.chapter].id, "context": String(c.after.suffix(60)), "date": ISO8601DateFormatter().string(from: Date())]
            entry.body = c.text
            try bible.write(entry)
        }
        for (i, status) in content.statuses.enumerated() where i < manifest.chapters.count {
            manifest.chapters[i].status = ChapterStatus(rawValue: status)
        }
        try store.saveManifest(manifest)
        for sheet in content.sheets {
            guard let kind = BibleKind(rawValue: sheet.kind) else { continue }
            var entry = BibleEntry(path: bible.freePath(title: sheet.title, folder: sheet.folder ?? kind.folder), kind: kind, title: sheet.title, aliases: sheet.aliases)
            // The fields in the order Musset suggests them, in the interface's language, then any other.
            let named = Dictionary(uniqueKeysWithValues: zip(Self.fieldKeys(kind), kind.suggestedFields))
            entry.fields = Self.fieldKeys(kind).compactMap { key in sheet.fields[key].map { .init(name: named[key] ?? key, value: $0) } }
                + sheet.fields.filter { !Self.fieldKeys(kind).contains($0.key) }.sorted { $0.key < $1.key }.map { .init(name: $0.key, value: $0.value) }
            entry.body = sheet.body
            try bible.write(entry)
        }
        if let first = entries.first {
            let page = try String(contentsOf: root.appendingPathComponent(first.file), encoding: .utf8)
            let editor = ParagraphCodec.decode(page) as NSString
            let notes = content.notes.compactMap { n -> Note? in
                let range = editor.range(of: n.quote)
                guard range.location != NSNotFound, let kind = Note.Kind(rawValue: n.kind) else { return nil }
                return Note(author: .me, kind: kind, body: n.body, anchor: Anchoring.capture(range, in: editor, version: nil))
            }
            if !notes.isEmpty {
                let file = NoteStore.url(root, first.id)
                try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try NoteMarkdown.encode(notes).write(to: file, atomically: true, encoding: .utf8)
            }
        }
        _ = try git.commit(paths: paths, message: "musset: revision")
        try milestone(1)
    }

    /// The suggested fields of a kind, by the English names the description uses.
    private static func fieldKeys(_ kind: BibleKind) -> [String] {
        switch kind {
        case .character: ["Born", "Occupation", "Wants", "Hides"]
        case .biography: ["Born", "Died"]
        case .place: ["Where", "When"]
        case .event: ["Date"]
        default: []
        }
    }
}
