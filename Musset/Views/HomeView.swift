import SwiftUI

/// A book on the shelf, read from its files.
struct BookCard: Identifiable {
    let path: String
    var manifest: BookManifest
    let counts: TextCounts
    var words: Int { counts.words }
    let todos: Int
    let touched: Date
    let lastSentence: String
    let lastChapter: String?
    /// Where the folder's repository goes: what tells Home the book is on the account.
    var remotes: [String] = []
    var id: String { path }
    var shelf: Shelf { manifest.shelf ?? .ongoing }

    nonisolated static func load(_ path: String) -> BookCard? {
        let root = URL(fileURLWithPath: path)
        let store = BookStore(root: root)
        guard let m = try? store.loadManifest() else { return nil }
        var counts = TextCounts.zero
        var todos = 0
        var touched = Date.distantPast
        for ch in m.chapters {
            counts = counts + TextCounts(store.read(ch))
            let date = (try? store.url(for: ch).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? nil
            if let date, date > touched { touched = date }
            todos += NoteStore.read(NoteStore.url(root, ch.id)).filter { $0.kind == .todo && $0.status == .open }.count
        }
        todos += NoteStore.read(NoteStore.url(root, NoteStore.bookPage)).filter { $0.kind == .todo && $0.status == .open }.count
        for e in BibleStore(root: root).scan().entries where !e.isFile { todos += e.body.components(separatedBy: "- [ ] ").count - 1 }
        let state = store.loadState()
        let last = state.layout?.lastChapter ?? state.lastChapter
        let chapter = m.chapters.first { $0.id == last } ?? m.chapters.last
        let text = chapter.map { ParagraphCodec.decode(store.read($0)) } ?? ""
        let caret = chapter.flatMap { state.selections[$0.id] }
        return BookCard(path: path, manifest: m, counts: counts, todos: todos, touched: touched,
                        lastSentence: sentence(before: caret, in: text), lastChapter: chapter?.title,
                        remotes: Array(GitService(root: root).remotes().values))
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

/// Every book, whichever one is open, and the Musset account beside them: the books of this Mac and those kept
/// online are one grid. Nothing here waits for the account: with no one signed in, the books open as ever.
struct HomeView: View {
    @Bindable var app: AppState
    /// The account as a test draws it. With one, no server is asked.
    var preview: HomeAccount? = nil
    @State private var cards: [BookCard] = []
    @State private var downloading: Int?
    @State private var error: String?
    private var collab: Collab { .shared }

    private var account: HomeAccount { preview ?? collab.homeAccount }
    /// Signed out there is one page: the books.
    private var section: HomeSection { account.signedIn ? app.homeSection : .books }
    private var recent: BookCard? { cards.filter { $0.shelf == .ongoing }.max { $0.touched < $1.touched } }

    var body: some View {
        let account = account
        let library = HomeLibrary(cards: cards, account: account, server: Collab.server.absoluteString)
        HStack(spacing: 0) {
            AccountColumn(app: app, account: account, library: library, section: section)
                .background(alignment: .top) { WindowDragArea().frame(height: 52) }
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    // Back to the book; or, with no book at all yet, back to the welcome.
                    if app.current != nil || app.libraryPaths.isEmpty {
                        Button { app.showHome = false } label: { Image(systemName: "xmark").font(.ui(12)) }
                            .buttonStyle(.plain).keyboardShortcut(.cancelAction)
                            .help(app.current != nil ? L("Back to the book") : L("Close"))
                            .accessibilityLabel(app.current != nil ? L("Back to the book") : L("Close"))
                    }
                }
                .padding(.horizontal, 20).frame(height: 44)
                .background(WindowDragArea())
                GeometryReader { geo in
                    ScrollView {
                        Group {
                            switch section {
                            case .books: books(library, account, width: geo.size.width - 88)
                            case .shared: SharedBooksSection(books: library.shared, downloading: downloading) { open($0) }
                            case .circle: CircleSection(writer: account.writer)
                            case .activity: ActivityList(app: app).frame(maxWidth: 720)
                            case .notices: NoticesSection()
                            case .plan: PlanSection(app: app, account: account)
                            }
                        }
                        .font(.ui(13))
                        .padding(.horizontal, 44).padding(.top, 12).padding(.bottom, 32)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .ignoresSafeArea(.container, edges: .top)
        .task(id: app.libraryPaths) { await loadBooks() }
        // On showing, and again when someone signs in: never on a redraw.
        .task(id: account.username) { await loadAccount() }
    }

    // MARK: My books

    private func books(_ library: HomeLibrary, _ account: HomeAccount, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 26) {
            HStack(spacing: 12) {
                AccountPageTitle(L("My books"))
                Spacer()
                Button(L("Open Book Folder…")) { app.addBookViaPanel(); app.showHome = false }.buttonStyle(.inkSecondary)
                Button(L("New Book…")) { app.showNewBook = true }.buttonStyle(.ink)
            }
            if let error { Text(error).font(.ui(12)).foregroundStyle(Ink.error).fixedSize(horizontal: false, vertical: true) }
            if let recent { resume(recent, library.books.first { $0.card?.path == recent.path }?.online ?? .unknown) }
            if library.books.isEmpty { EmptyNote(L("No book here yet. Open a folder, or start a new book.")) }
            ForEach(Shelf.allCases) { shelf in
                let books = library.books.filter { $0.card?.shelf == shelf }
                if !books.isEmpty { group(shelf.label, books, account, width: width) }
            }
            if !library.onlineOnly.isEmpty { group(L("Not on this Mac"), library.onlineOnly, account, width: width) }
            let unread = collab.activity.filter(\.isUnread)
            if account.signedIn, !unread.isEmpty || !library.shared.isEmpty {
                // Side by side as three fifths and two fifths; one under the other in a narrow window.
                let wide = width >= 760 && !unread.isEmpty && !library.shared.isEmpty
                let row = wide ? AnyLayout(HStackLayout(alignment: .top, spacing: 28)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 26))
                row {
                    if !unread.isEmpty { news(unread).frame(width: wide ? (width - 28) * 0.6 : min(width, 720), alignment: .leading) }
                    if !library.shared.isEmpty { shared(library.shared).frame(width: wide ? (width - 28) * 0.4 : min(width, 480), alignment: .leading) }
                }
            }
        }
    }

    /// Where the writing stopped, in the book last worked on.
    private func resume(_ card: BookCard, _ online: HomeBook.Online) -> some View {
        HStack(alignment: .center, spacing: 18) {
            cover(card.manifest.title, size: 9).frame(width: 54, height: 76)
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel(L("Pick up · \(card.manifest.title)") + (card.lastChapter.map { " · " + $0 } ?? ""), tracking: 0.8)
                if !card.lastSentence.isEmpty {
                    (Text(card.lastSentence) + Text(" ").foregroundColor(.clear))
                        .font(.uiMono(15)).lineSpacing(4).lineLimit(2).frame(maxWidth: 760, alignment: .leading)
                }
                Text(([card.counts.label(goal: card.manifest.goal)] + (card.todos > 0 ? [L("\(card.todos) to do")] : [])
                      + (stateWord(online).map { [$0.text] } ?? [])).joined(separator: " · "))
                    .font(.ui(12)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(L("Pick up here") + " ↩") { open(card) }
                .buttonStyle(.ink).keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 18).padding(.vertical, 16)
        .background(Ink.panel, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Ink.hairline))
    }

    /// A shelf's books, or those only online, in rows. Eager, like every list here: a lazy grid froze the app.
    private func group(_ title: String, _ books: [HomeBook], _ account: HomeAccount, width: CGFloat) -> some View {
        let grid = SceneGrid(width: width, size: 240, count: books.count)
        return VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.ui(13, .semibold))
            VStack(alignment: .leading, spacing: SceneGrid.gap) {
                ForEach(0..<grid.rows, id: \.self) { row in
                    HStack(alignment: .top, spacing: SceneGrid.gap) {
                        ForEach(books[grid.indices(row: row)]) { book in
                            card(for: book, account).frame(width: grid.cardWidth).frame(maxHeight: .infinity, alignment: .top)
                                .background(Ink.panel, in: RoundedRectangle(cornerRadius: 12))
                                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Ink.hairline))
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func card(for book: HomeBook, _ account: HomeAccount) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { if let card = book.card { open(card) } else if let repo = book.repo { download(repo) } } label: {
                VStack(alignment: .leading, spacing: 10) {
                    cover(book.title, size: 15).frame(height: 148)
                    Text(book.title).font(.ui(13, .semibold)).lineLimit(1)
                    if let card = book.card {
                        bar(card)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(card.counts.label(goal: card.manifest.goal)).lineLimit(1)
                            Text(facts(card).joined(separator: " · ")).lineLimit(1)
                        }
                        .font(.ui(12)).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(book.card == nil && downloading != nil)
            Spacer(minLength: 0)
            if let state = stateWord(book.online) {
                HStack(spacing: 7) {
                    Circle().fill(state.colour).frame(width: 7, height: 7).accessibilityHidden(true)
                    Text(state.text).font(.ui(12)).foregroundStyle(state.colour).lineLimit(1)
                }
            }
            action(book, account)
        }
        .padding(14)
        .contextMenu {
            if let card = book.card {
                ForEach(Shelf.allCases.filter { $0 != card.shelf }) { s in
                    Button(s.verb) { move(card, to: s) }
                }
                Divider()
                Button(L("Reveal in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: card.path)]) }
                Button(L("Remove from the library")) { app.removeFromLibrary(card.path) }
            }
        }
    }

    /// The card's one button: what its online state calls for.
    @ViewBuilder private func action(_ book: HomeBook, _ account: HomeAccount) -> some View {
        if let card = book.card {
            if book.online == .localOnly, account.writer {
                Button { putOnline(card) } label: { Text(L("Put online")).frame(maxWidth: .infinity) }.buttonStyle(.inkSecondary)
                    .help(L("Opens the book on its sharing page, where it is sent to your account."))
            } else {
                Button { open(card) } label: { Text(L("Open")).frame(maxWidth: .infinity) }.buttonStyle(.inkSecondary)
            }
        } else if let repo = book.repo {
            Button { download(repo) } label: {
                HStack(spacing: 8) {
                    if downloading == repo.id { ProgressView().controlSize(.small) }
                    Text(L("Download"))
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.inkSecondary).disabled(downloading != nil)
        }
    }

    /// The book's state on the account, in words and in the colour that goes with them; nothing when signed out.
    private func stateWord(_ online: HomeBook.Online) -> (text: String, colour: Color)? {
        switch online {
        case .unknown: nil
        case .synced: (L("On this Mac · online"), Ink.positive)
        case .onlineOnly: (L("Online · not on this Mac"), Ink.accent)
        case .localOnly: (L("On this Mac only"), Ink.warning)
        case .shared(let owner): (L("by \(owner)"), Color.secondary)
        }
    }

    private func facts(_ card: BookCard) -> [String] {
        var out: [String] = []
        if let genre = card.manifest.genre, let p = ScoringLibrary.shared.presets.first(where: { $0.id == genre }) { out.append(p.name) }
        if card.todos > 0 { out.append(L("\(card.todos) to do")) }
        let touched = when(card.touched)
        if !touched.isEmpty { out.append(touched) }
        return out
    }

    /// A book has no picture: its title on a quiet colour of its own, the same each time.
    private func cover(_ title: String, size: CGFloat) -> some View {
        let tints: [Color] = [Color(red: 0.20, green: 0.25, blue: 0.37), Color(red: 0.35, green: 0.27, blue: 0.21),
                              Color(red: 0.25, green: 0.29, blue: 0.24), Color(red: 0.29, green: 0.25, blue: 0.32),
                              Color(red: 0.36, green: 0.23, blue: 0.24), Color(red: 0.19, green: 0.30, blue: 0.33)]
        let hash = title.unicodeScalars.reduce(UInt32(2_166_136_261)) { ($0 ^ $1.value) &* 16_777_619 }
        let tint = tints[Int((hash >> 8) % UInt32(tints.count))]
        return Text(title)
            .font(.system(size: size, design: .serif)).foregroundStyle(.white.opacity(0.92))
            .lineLimit(size < 12 ? 3 : 4).multilineTextAlignment(.leading)
            .padding(size < 12 ? 6 : 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(tint, in: RoundedRectangle(cornerRadius: 5))
            .accessibilityHidden(true)
    }

    private func bar(_ card: BookCard) -> some View {
        let total = max(card.manifest.chapters.count, 1)
        return GeometryReader { geo in
            HStack(spacing: 1) {
                ForEach(ChapterStatus.allCases) { s in
                    let n = card.manifest.chapters.filter { ($0.status ?? .draft) == s }.count
                    if n > 0 { Rectangle().fill(s.dot).frame(width: geo.size.width * CGFloat(n) / CGFloat(total)) }
                }
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

    // MARK: Under the books

    /// What happened in the shared books since I last looked: milestones first, then notes and replies.
    private func news(_ items: [ActivityItem]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(L("New in your books"), tracking: 0.8)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(items.sorted { ($0.kind == "milestone" ? 0 : 1, -$0.at) < ($1.kind == "milestone" ? 0 : 1, -$1.at) }.prefix(4)) { item in
                    Divider()
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.sentence)
                            if let m = item.message, !m.isEmpty { Text("“" + m + "”").font(.ui(12)).foregroundStyle(.secondary).lineLimit(1) }
                        }
                        Spacer()
                        Text(when(item.date)).font(.ui(12)).foregroundStyle(.secondary)
                        if let repo = item.repo {
                            Button(item.kind == "milestone" ? L("Read \(item.tag ?? "")") : L("Open")) {
                                Task { await collab.markActivityRead(all: false, ids: [item.id]) }
                                app.open(mussetURL: URL(string: "musset://open?repo=" + (repo.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? repo))!)
                            }
                            .buttonStyle(.link)
                        }
                    }
                    .padding(.vertical, 9)
                }
                Divider()
                Button(L("All activity")) { app.homeSection = .activity }
                    .buttonStyle(.plain).foregroundStyle(.secondary).padding(.vertical, 9)
            }
        }
    }

    /// The books shared with me, in short; the section of that name has them all.
    private func shared(_ books: [SharedBook]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(L("Shared with me"), tracking: 0.8)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(books.prefix(4)) { b in
                    Divider()
                    HStack(spacing: 10) {
                        (Text(b.title) + Text(" · " + L("by \(b.owner)")).foregroundColor(.secondary)).lineLimit(1)
                        Spacer()
                        if let id = b.repo?.id, downloading == id { ProgressView().controlSize(.small) }
                        Button(b.path == nil ? L("Download") : L("Open")) { open(b) }
                            .buttonStyle(.link).disabled(b.path == nil && downloading != nil)
                    }
                    .padding(.vertical, 7)
                }
                if books.count > 4 {
                    Divider()
                    Button(L("Shared with me") + " (\(books.count))") { app.homeSection = .shared }
                        .buttonStyle(.plain).foregroundStyle(.secondary).padding(.vertical, 9)
                }
            }
        }
    }

    // MARK: Doing

    private func loadBooks() async {
        let paths = app.libraryPaths
        // The same folder reached through a symlink is one book.
        var seen = Set<String>()
        let unique = paths.filter { seen.insert(URL(fileURLWithPath: $0).resolvingSymlinksInPath().path).inserted }
        cards = await Task.detached(priority: .userInitiated) { unique.compactMap(BookCard.load) }.value
    }

    /// The plan, the circle, what happened and the books online, as the account's sheet asked for them when it opened.
    private func loadAccount() async {
        guard preview == nil, collab.signedIn else { return }
        await collab.refreshAccount()
        await collab.refreshCircle()
        await collab.refreshActivity()
        do { try await collab.refreshOnline(); error = nil } catch { self.error = error.localizedDescription }
    }

    private func open(_ card: BookCard) {
        app.openBook(URL(fileURLWithPath: card.path))
        app.showHome = false
    }

    private func open(_ book: SharedBook) {
        if let path = book.path {
            app.openBook(URL(fileURLWithPath: path))
            app.showHome = false
        } else if let repo = book.repo {
            download(repo)
        }
    }

    /// Putting a book online is done from the book: it opens on its Readers page, which sends it.
    private func putOnline(_ card: BookCard) {
        open(card)
        guard app.current != nil else { return }
        app.showReaders()
    }

    private func download(_ r: Collab.Repo) {
        guard downloading == nil, preview == nil else { return }
        let writings = BookStore.defaultFolder
        var folder = writings.appendingPathComponent(r.owner.login == collab.username ? r.name : "\(r.owner.login)-\(r.name)")
        var n = 2
        while FileManager.default.fileExists(atPath: folder.path) { folder = writings.appendingPathComponent("\(r.name)-\(n)"); n += 1 }
        downloading = r.id
        error = nil
        Task {
            do {
                try FileManager.default.createDirectory(at: writings, withIntermediateDirectories: true)
                try await collab.open(r, into: folder)
                app.openBook(folder)
                app.showHome = false
            } catch { self.error = error.localizedDescription }
            downloading = nil
        }
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
