import SwiftUI

struct SearchHit: Identifiable {
    let id = UUID()
    let bookPath: String
    let bookTitle: String
    let chapter: ChapterEntry
    let range: NSRange
    let snippet: AttributedString
}

enum BookSearch {
    static let options: NSString.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

    /// All matches of `query` in `text`, accent- and case-insensitive.
    static func ranges(of query: String, in text: String) -> [NSRange] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { return [] }
        let ns = text as NSString
        var out: [NSRange] = []
        var from = 0
        while from < ns.length {
            let r = ns.range(of: q, options: options, range: NSRange(location: from, length: ns.length - from))
            if r.location == NSNotFound { break }
            out.append(r)
            from = NSMaxRange(r)
        }
        return out
    }

    static func snippet(_ text: NSString, _ r: NSRange) -> AttributedString {
        let start = max(0, r.location - 50), end = min(text.length, NSMaxRange(r) + 70)
        func clean(_ s: String) -> String { s.replacingOccurrences(of: "\n", with: " ") }
        var before = AttributedString((start > 0 ? "…" : "") + clean(text.substring(with: NSRange(location: start, length: r.location - start))))
        var match = AttributedString(clean(text.substring(with: r)))
        match.font = .body.bold()
        match.backgroundColor = .yellow.opacity(0.35)
        let after = AttributedString(clean(text.substring(with: NSRange(location: NSMaxRange(r), length: end - NSMaxRange(r)))) + (end < text.length ? "…" : ""))
        before.append(match)
        before.append(after)
        return before
    }

    struct Source: Sendable {
        let bookPath: String
        let bookTitle: String
        let chapter: ChapterEntry
        let url: URL
        /// Text as shown in the editor for the open chapter; read from disk otherwise.
        let live: String?
    }

    /// File contents keyed by path, reused while the file's modification date is unchanged.
    /// Shared with everything that reads closed chapters (the Bible's counts, the notes of the whole book, the
    /// reading view): a chapter is read from disk once, and again only when its file changes.
    static let texts = TextCache()
    private static var cache: TextCache { texts }

    final class TextCache: @unchecked Sendable {
        private var store: [String: (date: Date, size: Int, text: String)] = [:]
        private let lock = NSLock()
        func text(at url: URL) -> String {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let date = values?.contentModificationDate ?? .distantPast
            let size = values?.fileSize ?? -1
            lock.lock(); defer { lock.unlock() }
            if let hit = store[url.path], hit.date == date, hit.size == size { return hit.text }
            // Editor form, so match offsets land on the right place when the chapter opens.
            let text = ParagraphCodec.decode((try? String(contentsOf: url, encoding: .utf8)) ?? "")
            store[url.path] = (date, size, text)
            return text
        }
    }

    /// What to search, gathered on the main thread; the search itself runs anywhere.
    @MainActor
    static func sources(app: AppState, allBooks: Bool) -> [Source] {
        guard let current = app.current else { return [] }
        let currentPath = current.root.standardizedFileURL.path
        let paths = allBooks ? app.libraryPaths : [currentPath]
        var out: [Source] = []
        for path in paths {
            let isCurrent = path == currentPath
            let store = BookStore(root: URL(fileURLWithPath: path))
            guard let manifest = isCurrent ? current.manifest : (try? store.loadManifest()) else { continue }
            for ch in manifest.chapters {
                let live = isCurrent && ch.id == current.selectedChapterID ? current.text : nil
                out.append(Source(bookPath: path, bookTitle: manifest.title, chapter: ch, url: store.url(for: ch), live: live))
            }
        }
        return out
    }

    struct Group: Identifiable, Sendable {
        var id: String { bookPath + "|" + chapter.id }
        let bookPath: String
        let bookTitle: String
        let chapter: ChapterEntry
        let total: Int
        let hits: [SearchHit]
    }

    /// Matches grouped by chapter, in book order. Only the first `perChapter` matches of a chapter get a snippet.
    static func search(_ query: String, in sources: [Source], perChapter: Int = 25) -> [Group] {
        var groups: [Group] = []
        for src in sources {
            if Task.isCancelled { return [] }
            let text = src.live ?? cache.text(at: src.url)
            let found = ranges(of: query, in: text)
            guard !found.isEmpty else { continue }
            let ns = text as NSString
            let hits = found.prefix(perChapter).map {
                SearchHit(bookPath: src.bookPath, bookTitle: src.bookTitle, chapter: src.chapter, range: $0, snippet: snippet(ns, $0))
            }
            groups.append(Group(bookPath: src.bookPath, bookTitle: src.bookTitle, chapter: src.chapter, total: found.count, hits: hits))
        }
        return groups
    }

    @MainActor
    static func run(_ query: String, app: AppState, allBooks: Bool) -> [SearchHit] {
        search(query, in: sources(app: app, allBooks: allBooks)).flatMap(\.hits)
    }
}

/// Search across the book (⇧⌘F), shown in place of the chapter list.
struct SearchPanel: View {
    @Bindable var app: AppState
    let bridge: EditorBridge
    @State private var groups: [BookSearch.Group] = []
    @State private var expanded: Set<String> = []
    @State private var task: Task<Void, Never>?
    @FocusState private var focused: Bool

    private var total: Int { groups.reduce(0) { $0 + $1.total } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(L("Search the Book…").titled, text: $app.searchQuery)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit { if let h = groups.first?.hits.first { open(h) } }
                if !app.searchQuery.isEmpty {
                    Button { app.searchQuery = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
                Button(L("Done", ctx: "Terminé")) { app.closeSearch() }.buttonStyle(.plain).foregroundStyle(.secondary).font(.ui(11))
            }
            .padding(10)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: Radius.control))
            .padding(.horizontal, 10).padding(.top, 8)

            HStack {
                Toggle(L("All Books"), isOn: $app.searchAllBooks).toggleStyle(.checkbox).font(.ui(11))
                Spacer()
                if app.searchQuery.trimmingCharacters(in: .whitespaces).count >= 2 {
                    Text(L("\(total) matches") + " " + L("in \(groups.count) chapters"))
                        .font(.ui(11)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 6)

            List {
                ForEach(groups) { group in
                    Section {
                        let shown = expanded.contains(group.id) ? group.hits : Array(group.hits.prefix(5))
                        ForEach(shown) { hit in
                            Text(hit.snippet)
                                .font(.ui(12))
                                .lineLimit(3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                                .onTapGesture { open(hit) }
                        }
                        if group.total > shown.count {
                            Button(expanded.contains(group.id) || group.hits.count <= 5
                                   ? L("\(group.total - shown.count) more — open the chapter")
                                   : L("Show \(min(group.hits.count, group.total) - shown.count) more")) {
                                if expanded.contains(group.id) || group.hits.count <= 5, let first = group.hits.first { open(first) }
                                else { expanded.insert(group.id) }
                            }
                            .buttonStyle(.link).font(.ui(11))
                        }
                    } header: {
                        Text(app.searchAllBooks ? "\(group.bookTitle) · \(group.chapter.title)  (\(group.total))" : "\(group.chapter.title)  (\(group.total))")
                            .lineLimit(1)
                    }
                }
            }
            .listStyle(.sidebar)
        }
        .onAppear { focused = true; refresh(debounce: false) }
        .onChange(of: app.searchQuery) { _, _ in refresh(debounce: true) }
        .onChange(of: app.searchAllBooks) { _, _ in refresh(debounce: false) }
        .onChange(of: app.searchFocusRequest) { _, _ in focused = true }
        .onExitCommand { app.closeSearch() }
    }

    private func refresh(debounce: Bool) {
        task?.cancel()
        let q = app.searchQuery
        // The open chapter is highlighted at once; the book-wide list follows.
        bridge.setSearchQuery(q)
        let sources = BookSearch.sources(app: app, allBooks: app.searchAllBooks)
        task = Task {
            if debounce { try? await Task.sleep(nanoseconds: 120_000_000) }
            guard !Task.isCancelled else { return }
            let result = await Task.detached(priority: .userInitiated) { BookSearch.search(q, in: sources) }.value
            guard !Task.isCancelled else { return }
            groups = result
            expanded = []
        }
    }

    private func open(_ hit: SearchHit) {
        app.jump(bookPath: hit.bookPath, chapterID: hit.chapter.id)
        app.current?.pendingSelection = hit.range
        bridge.setSearchQuery(app.searchQuery)
    }
}
