import Foundation

/// One thing to do, wherever it was written. The list is computed; the source stays the truth.
struct TodoItem: Identifiable, Hashable {
    enum Origin: Hashable {
        /// A note in the margin of a chapter.
        case margin(chapter: String, note: UUID)
        /// A `- [ ]` line in a Markdown file: its URL and line number.
        case line(file: URL, index: Int)
    }
    var text: String
    var done: Bool
    var origin: Origin
    /// The chapter it belongs to, if any.
    var chapter: String?
    /// Where it comes from, in words.
    var source: String

    var id: String {
        switch origin {
        case .margin(_, let note): "note:\(note)"
        case .line(let file, let index): "\(file.path):\(index)"
        }
    }
}

/// `- [ ]` lines, and the shortcuts that make them.
enum TodoSyntax {
    static func parse(_ line: Substring) -> (text: String, done: Bool)? {
        let t = line.drop { $0 == " " || $0 == "\t" }
        for (prefix, done) in [("- [ ] ", false), ("- [x] ", true), ("- [X] ", true)] where t.hasPrefix(prefix) {
            return (String(t.dropFirst(prefix.count)), done)
        }
        return nil
    }

    /// `@todo` anywhere in a line, or `[]` at its start, makes that line a task.
    static func normalize(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let s = String(line)
            if parse(line) != nil { return s }
            if s.hasPrefix("[] ") { return "- [ ] " + s.dropFirst(3) }
            guard let re = s.range(of: "(^|\\s)@todo(?=\\s|$)", options: [.regularExpression, .caseInsensitive]) else { return s }
            var rest = s
            rest.removeSubrange(re)
            return "- [ ] " + rest.trimmingCharacters(in: .whitespaces)
        }.joined(separator: "\n")
    }

    /// The text with one line ticked or unticked.
    static func toggled(_ text: String, line index: Int) -> String? {
        var lines = text.components(separatedBy: "\n")
        guard lines.indices.contains(index), let found = parse(Substring(lines[index])) else { return nil }
        let indent = lines[index].prefix { $0 == " " || $0 == "\t" }
        lines[index] = indent + (found.done ? "- [ ] " : "- [x] ") + found.text
        return lines.joined(separator: "\n")
    }
}

extension BookSession {
    /// Every task of the book. Each source is read when asked: the list never drifts from the files.
    func collectTodos() -> [TodoItem] {
        var items: [TodoItem] = []
        let titles = Dictionary(manifest.chapters.map { ($0.id, $0.title) }, uniquingKeysWith: { a, _ in a })
        let byTitle = Dictionary(titles.map { (PlotGrid.fold($0.value), $0.key) }, uniquingKeysWith: { a, _ in a })
        for page in manifest.chapters.map(\.id) + [NoteStore.bookPage] {
            for n in notes.notes(of: page) where n.kind == .todo {
                // A task can name another chapter, with @[Titre].
                let linked = BibleLinks.targets(in: n.body).compactMap { byTitle[PlotGrid.fold($0)] }.first
                items.append(TodoItem(text: n.body.isEmpty ? n.anchor.quote : BibleLinks.plain(n.body), done: n.isClosed,
                                      origin: .margin(chapter: page, note: n.id), chapter: linked ?? (page == NoteStore.bookPage ? nil : page),
                                      source: L("notes")))
            }
        }
        for e in bible.entries where !e.isFile {
            items += lines(of: bible.store.url(e.path), chapter: nil, source: e.title, titles: titles)
        }
        return items
    }

    private func lines(of file: URL, chapter: String?, source: String, titles: [String: String]) -> [TodoItem] {
        guard let text = try? String(contentsOf: file, encoding: .utf8), text.contains("- [") else { return [] }
        let byTitle = Dictionary(titles.map { (PlotGrid.fold($0.value), $0.key) }, uniquingKeysWith: { a, _ in a })
        return text.components(separatedBy: "\n").enumerated().compactMap { i, line in
            guard let t = TodoSyntax.parse(Substring(line)) else { return nil }
            let linked = BibleLinks.targets(in: t.text).compactMap { byTitle[PlotGrid.fold($0)] }.first
            return TodoItem(text: BibleLinks.plain(t.text), done: t.done, origin: .line(file: file, index: i), chapter: linked ?? chapter, source: source)
        }
    }

    func toggle(_ todo: TodoItem) {
        switch todo.origin {
        case .margin(let chapter, let note):
            notes.change(note, in: chapter) { $0.status = todo.done ? .open : .done }
        case .line(let file, let index):
            guard let text = try? String(contentsOf: file, encoding: .utf8), let next = TodoSyntax.toggled(text, line: index) else { return }
            try? next.write(to: file, atomically: true, encoding: .utf8)
            bible.reload()
        }
        pendingCommit = true
    }
}
