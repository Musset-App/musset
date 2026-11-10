import SwiftUI

/// Where a book stands on the shelf.
enum Shelf: String, Codable, CaseIterable, Identifiable {
    case ongoing, finished, aside
    var id: String { rawValue }
    var label: String {
        switch self {
        case .ongoing: L("In progress")
        case .finished: L("Finished", ctx: "Terminés")
        case .aside: L("Set aside", ctx: "Mis de côté")
        }
    }
    var verb: String {
        switch self {
        case .ongoing: L("Back in progress")
        case .finished: L("Mark as finished")
        case .aside: L("Set aside", ctx: "Mettre de côté")
        }
    }
}

/// A book on the shelf, read from its files.
struct BookCard: Identifiable {
    let path: String
    var manifest: BookManifest
    let words: Int
    let todos: Int
    let touched: Date
    let lastSentence: String
    let lastChapter: String?
    var id: String { path }
    var shelf: Shelf { manifest.shelf ?? .ongoing }

    nonisolated static func load(_ path: String) -> BookCard? {
        let root = URL(fileURLWithPath: path)
        let store = BookStore(root: root)
        guard let m = try? store.loadManifest() else { return nil }
        var words = 0
        var todos = 0
        var touched = Date.distantPast
        for ch in m.chapters {
            words += BookStore.wordCount(store.read(ch))
            let date = (try? store.url(for: ch).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? nil
            if let date, date > touched { touched = date }
            todos += NoteStore.read(NoteStore.url(root, ch.id)).filter { $0.kind == .todo && $0.status == .open }.count
        }
        todos += NoteStore.read(NoteStore.url(root, NoteStore.bookPage)).filter { $0.kind == .todo && $0.status == .open }.count
        for e in BibleStore(root: root).scan().entries where !e.isFile { todos += e.body.components(separatedBy: "- [ ] ").count - 1 }
        let state = store.loadState()
        let chapter = m.chapters.first { $0.id == state.lastChapter } ?? m.chapters.last
        let text = chapter.map { ParagraphCodec.decode(store.read($0)) } ?? ""
        let caret = chapter.flatMap { state.selections[$0.id] }
        return BookCard(path: path, manifest: m, words: words, todos: todos, touched: touched,
                        lastSentence: sentence(before: caret, in: text), lastChapter: chapter?.title)
    }

    /// The sentence the caret stopped at: where to pick up again. Not a heading, not a marker.
    nonisolated static func sentence(before caret: Int?, in text: String) -> String {
        let ns = text as NSString
        let end = min(max(caret ?? ns.length, 0), ns.length)
        let lines = ns.substring(to: end).components(separatedBy: "\n").reversed()
        var line = lines.first { l in
            let t = l.trimmingCharacters(in: .whitespaces)
            return !t.isEmpty && !t.hasPrefix("#") && !t.hasPrefix("<!--")
        }
        if line == nil { line = text.components(separatedBy: "\n").last { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.hasPrefix("#") } }
        guard var s = line?.trimmingCharacters(in: .whitespaces) else { return "" }
        if s.count > 220 { s = "…" + s.suffix(220) }
        return s
    }
}

/// Every book, whichever one is open.
struct HomeView: View {
    @Bindable var app: AppState
    @State private var cards: [BookCard] = []

    private var recent: BookCard? { cards.filter { $0.shelf == .ongoing }.max { $0.touched < $1.touched } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Color.clear.frame(width: 64)
                Text("Musset").font(.system(size: 20, design: .serif))
                Spacer()
                Button { app.showAccount = true } label: { Label(Collab.shared.username ?? L("Sign in"), systemImage: "person.crop.circle").font(.ui(12)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help(L("Your Musset account: your books on all your Macs"))
                Button(L("Open a folder…")) { app.addBookViaPanel(); app.showHome = false }.buttonStyle(.inkSecondary)
                Button(L("New book")) { app.showNewBook = true }.buttonStyle(.ink)
                if app.current != nil {
                    Button { app.showHome = false } label: { Image(systemName: "xmark").font(.ui(12)) }
                        .buttonStyle(.plain).keyboardShortcut(.cancelAction)
                        .help(L("Back to the book"))
                        .accessibilityLabel(L("Back to the book"))
                }
            }
            .padding(.horizontal, 20).frame(height: 52)
            .background(WindowDragArea())
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    if let recent { resume(recent) }
                    ForEach(Shelf.allCases) { shelf in
                        let books = cards.filter { $0.shelf == shelf }
                        if !books.isEmpty { section(shelf, books) }
                    }
                }
                .padding(.horizontal, 56).padding(.top, 12).padding(.bottom, 32)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .ignoresSafeArea(.container, edges: .top)
        .task(id: app.libraryPaths) { await load() }
    }

    private func load() async {
        let paths = app.libraryPaths
        // The same folder reached through a symlink is one book.
        var seen = Set<String>()
        let unique = paths.filter { seen.insert(URL(fileURLWithPath: $0).resolvingSymlinksInPath().path).inserted }
        cards = await Task.detached(priority: .userInitiated) { unique.compactMap(BookCard.load) }.value
    }

    private func open(_ card: BookCard) {
        app.openBook(URL(fileURLWithPath: card.path))
        app.showHome = false
    }

    private func resume(_ card: BookCard) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("Pick up · ") + card.manifest.title + (card.lastChapter.map { " · " + $0 } ?? "")).foregroundStyle(.secondary)
            (Text(card.lastSentence) + Text(" ").foregroundColor(.clear))
                .font(.uiMono(19)).lineSpacing(6).frame(maxWidth: 760, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Button(L("Pick up here") + " ↩") { open(card) }
                .buttonStyle(.ink).keyboardShortcut(.defaultAction)
        }
    }

    private func section(_ shelf: Shelf, _ books: [BookCard]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(shelf.label).font(.ui(13, .semibold))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 270), spacing: 20, alignment: .topLeading)], alignment: .leading, spacing: 20) {
                ForEach(books) { card(for: $0) }
            }
        }
    }

    private func card(for card: BookCard) -> some View {
        Button { open(card) } label: {
            HStack(alignment: .top, spacing: 14) {
                Text(card.manifest.title)
                    .font(.system(size: 13, design: .serif))
                    .padding(9)
                    .frame(width: 92, height: 132, alignment: .topLeading)
                    .background(Ink.panel, in: RoundedRectangle(cornerRadius: 3))
                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Ink.hairline))
                VStack(alignment: .leading, spacing: 4) {
                    Text(card.manifest.title).font(.ui(13, .medium)).lineLimit(2).multilineTextAlignment(.leading)
                    if let genre = card.manifest.genre, let p = ScoringLibrary.shared.presets.first(where: { $0.id == genre }) {
                        Text(p.name).font(.ui(12)).foregroundStyle(.secondary)
                    }
                    bar(card).padding(.top, 6)
                    Text(card.words.ui + (card.manifest.goal.map { " / \($0.ui)" } ?? "") + " " + L("words")).font(.ui(12)).foregroundStyle(.secondary)
                    if card.todos > 0 { Text(L("\(card.todos) to do")).font(.ui(12)).foregroundStyle(.secondary) }
                    Text(when(card.touched)).font(.ui(12)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            ForEach(Shelf.allCases.filter { $0 != card.shelf }) { s in
                Button(s.verb) { move(card, to: s) }
            }
            Divider()
            Button(L("Reveal in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: card.path)]) }
            Button(L("Remove from the library")) { app.removeFromLibrary(card.path) }
        }
    }

    private func bar(_ card: BookCard) -> some View {
        let total = max(card.manifest.chapters.count, 1)
        return HStack(spacing: 1) {
            ForEach(ChapterStatus.allCases) { s in
                let n = card.manifest.chapters.filter { ($0.status ?? .draft) == s }.count
                if n > 0 { Rectangle().fill(s.dot).frame(width: 150 * CGFloat(n) / CGFloat(total)) }
            }
        }
        .frame(height: 5)
        .clipShape(RoundedRectangle(cornerRadius: 2))
    }

    private func when(_ d: Date) -> String {
        guard d > .distantPast else { return "" }
        let f = RelativeDateTimeFormatter()
        f.locale = UILang.locale
        return f.localizedString(for: d, relativeTo: Date())
    }

    private func move(_ card: BookCard, to shelf: Shelf) {
        var m = card.manifest
        m.shelf = shelf
        let store = BookStore(root: URL(fileURLWithPath: card.path))
        try? store.saveManifest(m)
        if app.current?.root.standardizedFileURL.path == card.path { app.current?.manifest.shelf = shelf }
        if let i = cards.firstIndex(where: { $0.path == card.path }) { cards[i].manifest = m }
    }
}
