import SwiftUI

struct ChapterSidebar: View {
    @Bindable var session: BookSession
    let app: AppState
    let bridge: EditorBridge
    /// Asks an AI to propose where the open chapter's scenes begin.
    var scenePlanner: ((AgentKind) -> Void)? = nil
    @State private var renaming: ChapterEntry?
    @State private var newTitle = ""
    @State private var addingChapter = false
    @State private var expanded: Set<String> = []
    @State private var showFront = false
    @State private var showBack = false
    /// A long book folds away, so the Bible is one click from the top.
    @AppStorage("sidebarBookFolded") private var bookFolded = false
    @State private var renamingScene: (chapter: String, scene: ChapterScene)?
    @State private var renamingPart: BookPart?
    @AppStorage("sidebarFoldedParts") private var foldedParts = ""

    private var longest: Int { max(1, session.chapterWords.values.max() ?? 1) }

    var body: some View {
        VStack(spacing: 0) {
            BookSwitcher(app: app)
                .padding(.horizontal, 18)
                .padding(.top, 10)
                .padding(.bottom, 6)

            if app.showSearch {
                SearchPanel(app: app, bridge: bridge)
            } else {
                List {
                    let front = session.manifest.front ?? FrontMatter()
                    // On a special page, all of them are listed; otherwise only those that will print.
                    let all = app.specialPage != nil
                    let frontPages = SpecialPage.front.filter { all || front.has($0) }
                    let back = SpecialPage.back.filter { all || front.has($0) }
                    SidebarRowView(active: app.showOverview) {
                        Image(systemName: "square.grid.2x2").font(.ui(11)).foregroundStyle(.tertiary).frame(width: 16)
                        Text(L("Overview"))
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { app.openOverview() }
                    .sidebarRow()
                    foldLabel(L("Book"), folded: $bookFolded)
                    if !bookFolded, !frontPages.isEmpty { pagesGroup(L("Front"), frontPages, open: $showFront) }
                    let rows = bookFolded ? [] : bookRows
                    ForEach(rows) { row in
                        switch row {
                        case .part(let part):
                            partRow(part).sidebarRow()
                        case .chapter(let ch, let idx):
                            VStack(spacing: 1) {
                                chapterRow(ch, idx)
                                if expanded.contains(ch.id) {
                                    let scenes = session.scenes[ch.id] ?? []
                                    if scenes.contains(where: { $0.marker != nil }) {
                                        ForEach(Array(scenes.enumerated()), id: \.element.id) { i, scene in sceneRow(ch, scene, index: i) }
                                    }
                                }
                            }
                            .padding(.leading, ch.part.map { inPart($0) } == true ? 12 : 0)
                            .sidebarRow()
                        }
                    }
                    // Not onMove: the rows' tap gesture keeps the List from ever starting its own drag.
                    .dropDestination(for: String.self) { wires, offset in
                        let place = dropPlace(offset, in: rows)
                        session.dropOnBook(wires, at: place.index, part: .some(place.part))
                        // A draft sheet that became a chapter is no longer there to show.
                        if case .entry(let path)? = app.bibleRoute, session.bible.entry(path: path) == nil { app.bibleRoute = nil }
                    }
                    if !bookFolded, !back.isEmpty { pagesGroup(L("Back", ctx: "Fin"), back, open: $showBack) }
                    BibleSidebarSection(app: app, session: session, bridge: bridge)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .environment(\.defaultMinListRowHeight, 1)
            }

            if !app.showSearch {
                ShelfSection(app: app, session: session, bridge: bridge)
                VStack(spacing: 8) {
                    Divider()
                    HStack {
                        Text("\(session.bookWordCount.ui) " + L("words"))
                            .help(ChapterStatus.allCases.map { s in "\(s.label): \(session.manifest.chapters.filter { ($0.status ?? .draft) == s }.count)" }.joined(separator: " · "))
                        if let goal = session.manifest.goal, goal > 0 { Text("/ \(goal.ui)").foregroundStyle(.tertiary) }
                        Spacer()
                        if session.wordsToday > 0 { Text("+\(session.wordsToday) " + L("today")).foregroundStyle(Color(red: 0.18, green: 0.54, blue: 0.34)) }
                    }
                    .font(.ui(12).monospacedDigit()).foregroundStyle(.secondary)
                    HStack(spacing: 14) {
                        Button { newTitle = ""; addingChapter = true } label: { Image(systemName: "plus") }
                            .help(L("New chapter"))
                        Spacer()
                        Button { app.openSearch() } label: { Image(systemName: "magnifyingglass") }
                            .help(L("Search the book (⇧⌘F)"))
                        Button { withAnimation { app.showPlotGrid = true } } label: { Image(systemName: "tablecells") }
                            .help(L("Plot grid (⌘5)"))
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12).padding(.bottom, 10)
            }
        }
        .background(Ink.side)
        .alert(L("Rename chapter"), isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField(L("Title"), text: $newTitle)
            Button(L("Rename")) { if let r = renaming { session.renameChapter(r.id, to: newTitle) }; renaming = nil }
            Button(L("Cancel"), role: .cancel) { renaming = nil }
        }
        .alert(L("Name the part"), isPresented: Binding(get: { renamingPart != nil }, set: { if !$0 { renamingPart = nil } })) {
            TextField(L("Title (optional)"), text: $newTitle)
            Button("OK") { if let p = renamingPart { session.renamePart(p.id, to: newTitle) }; renamingPart = nil }
            Button(L("Cancel"), role: .cancel) { renamingPart = nil }
        } message: {
            Text(L("The numeral (I, II, III…) follows the order of the parts in the book."))
        }
        .alert(L("Rename scene"), isPresented: Binding(get: { renamingScene != nil }, set: { if !$0 { renamingScene = nil } })) {
            TextField(L("Title"), text: $newTitle)
            Button(L("Rename")) { if let r = renamingScene { renameScene(r.chapter, r.scene, to: newTitle) }; renamingScene = nil }
            Button(L("Cancel"), role: .cancel) { renamingScene = nil }
        }
        .onAppear { if let id = session.selectedChapterID { expanded.insert(id) } }
        .onChange(of: session.selectedChapterID) { _, id in if let id { expanded.insert(id) } }
        .alert(L("New chapter"), isPresented: $addingChapter) {
            TextField(L("Title"), text: $newTitle)
            Button(L("Create")) { if !newTitle.isEmpty { session.addChapter(title: newTitle) } }
            Button(L("Cancel"), role: .cancel) {}
        }
    }
}

/// A row of the book's list: a part's heading, or a chapter with its number in the book.
enum BookListRow: Identifiable {
    case part(BookPart)
    case chapter(ChapterEntry, Int)

    var id: String {
        switch self {
        case .part(let p): "part|" + p.id
        case .chapter(let ch, _): ch.id
        }
    }
}

extension ChapterSidebar {
    private var folded: Set<String> { Set(foldedParts.split(separator: ",").map(String.init)) }

    private func inPart(_ id: String) -> Bool { session.manifest.parts?.contains { $0.id == id } == true }

    /// Each part's heading before its first chapter; a folded part hides its chapters; empty parts come last.
    var bookRows: [BookListRow] {
        let m = session.manifest
        var out: [BookListRow] = []
        var previous: String?
        for (i, ch) in m.chapters.enumerated() {
            let part = ch.part.flatMap { id in m.parts?.first { $0.id == id } }
            if let part, part.id != previous { out.append(.part(part)) }
            previous = part?.id
            if part.map({ !folded.contains($0.id) }) ?? true { out.append(.chapter(ch, i)) }
        }
        for part in m.orderedParts where !m.chapters.contains(where: { $0.part == part.id }) { out.append(.part(part)) }
        return out
    }

    /// Where a drop between rows puts a chapter: its place in the book, and the part of the row above it.
    func dropPlace(_ offset: Int, in rows: [BookListRow]) -> (index: Int, part: String?) {
        guard offset > 0, let above = rows[safe: offset - 1] else { return (0, nil) }
        let chapters = session.manifest.chapters
        switch above {
        case .chapter(let ch, let i): return (i + 1, ch.part.flatMap { inPart($0) ? $0 : nil })
        case .part(let p):
            return (chapters.firstIndex { $0.part == p.id } ?? chapters.count, p.id)
        }
    }

    func partRow(_ part: BookPart) -> some View {
        let isFolded = folded.contains(part.id)
        let members = session.manifest.chapters.filter { $0.part == part.id }
        let words = members.reduce(0) { $0 + (session.chapterWords[$1.id] ?? 0) }
        return SidebarRowView(active: false) {
            Image(systemName: isFolded ? "chevron.right" : "chevron.down").font(.ui(8)).foregroundStyle(.tertiary).frame(width: 16)
            Text(session.manifest.numeral(of: part.id)).font(.ui(12, .semibold))
            if !part.title.isEmpty { Text(part.title).lineLimit(1).truncationMode(.tail).foregroundStyle(.secondary) }
            Spacer(minLength: 4)
            Text(members.isEmpty ? L("empty") : Self.compact(words)).font(.ui(11).monospacedDigit()).foregroundStyle(.tertiary)
                .frame(width: 34, alignment: .trailing)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            var f = folded
            if f.contains(part.id) { f.remove(part.id) } else { f.insert(part.id) }
            foldedParts = f.sorted().joined(separator: ",")
        }
        .help(L("Part \(session.manifest.numeral(of: part.id)): \(members.count) chapters. Drag chapters under it to put them in."))
        .contextMenu {
            Button(L("Name…")) { newTitle = part.title; renamingPart = part }
            Divider()
            Button(L("Delete Part (Chapters Stay)")) { session.deletePart(part.id) }
        }
    }

    /// Row tags: a chapter's id, or "<chapter>\u{1}<scene index>" for a scene.
    private func select(_ tag: String) {
        if tag.hasPrefix("special:") { app.specialPage = SpecialPage(rawValue: String(tag.dropFirst(8))); return }
        app.leaveBookPages()
        let parts = tag.components(separatedBy: "\u{1}")
        let chapterID = parts[0]
        guard parts.count == 2, let i = Int(parts[1]), let scene = session.scenes[chapterID]?[safe: i] else {
            if chapterID != session.selectedChapterID { session.open(chapterID) }
            return
        }
        bridge.show(scene, chapter: chapterID, session: session)
    }

    /// The scene the caret is in, in the open chapter.
    private var currentScene: ChapterScene? {
        guard let id = session.selectedChapterID, let scenes = session.scenes[id], scenes.contains(where: { $0.marker != nil }) else { return nil }
        return Scenes.scene(at: bridge.selectedRange.location, in: scenes)
    }

    @ViewBuilder
    func chapterRow(_ ch: ChapterEntry, _ idx: Int) -> some View {
        let open = app.specialPage == nil && ch.id == session.selectedChapterID
        let hasScenes = (session.scenes[ch.id] ?? []).contains { $0.marker != nil }
        SidebarRowView(active: open && !hasScenes) {
            Text("\(idx)").font(.uiMono(11)).foregroundStyle(.tertiary)
                .frame(width: 16, alignment: .trailing)
            Text(ch.title).lineLimit(1).truncationMode(.tail)
                .fontWeight(open ? .medium : .regular)
                .foregroundStyle(ch.excludeFromExport ? .secondary : .primary)
            Spacer(minLength: 4)
            if let n = session.versionCounts[ch.id] {
                HStack(spacing: 2) { Image(systemName: "square.on.square").font(.ui(9)); Text("\(n)").font(.ui(10).monospacedDigit()) }
                    .foregroundStyle(.secondary)
                    .help(L("\(n) versions"))
            }
            StatusDot(status: ch.status ?? .draft)
            Text(Self.compact(session.chapterWords[ch.id] ?? 0)).font(.ui(11).monospacedDigit()).foregroundStyle(.tertiary)
                .frame(width: 34, alignment: .trailing)
        }
        .onTapGesture {
            if open && hasScenes { if expanded.contains(ch.id) { expanded.remove(ch.id) } else { expanded.insert(ch.id) } }
            else { select(ch.id) }
        }
        .draggable(ShelfDrag.chapter(ch.id).wire)
        .help("\((ch.status ?? .draft).label) · \(session.chapterWords[ch.id] ?? 0) " + L("words"))
        .contextMenu {
            Picker(L("Status", ctx: "Statut"), selection: Binding(get: { ch.status ?? .draft }, set: { session.setStatus(ch.id, $0) })) {
                ForEach(ChapterStatus.allCases) { Text($0.label).tag($0) }
            }
            if AIStatus.shared.isOn {
                Menu(L("Propose Scenes")) {
                    ForEach(AIStatus.shared.engines) { engine in
                        Button(L("With ") + engine.label + "…") { if ch.id != session.selectedChapterID { session.open(ch.id) }; scenePlanner?(engine) }
                    }
                }
            }
            Button(L("Try Something Else…")) {
                if ch.id != session.selectedChapterID { select(ch.id) }
                app.showTryVersion = true
            }
            .help(L("Another version of this chapter; the book keeps its own until you choose."))
            Divider()
            Button(L("Rename…")) { newTitle = ch.title; renaming = ch }
            Button(ch.excludeFromExport ? L("Include in export") : L("Exclude from export")) { session.toggleExport(ch.id) }
            Button(L("Reveal file in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([session.store.url(for: ch)]) }
            Menu(L("Part")) {
                Button(L("New Part Starting Here")) { session.newPart(startingAt: ch.id) }
                let parts = session.manifest.orderedParts.filter { $0.id != ch.part }
                if !parts.isEmpty {
                    Divider()
                    ForEach(parts) { p in Button(L("Move to ") + session.manifest.label(of: p)) { session.movePart(of: ch.id, to: p.id) } }
                }
                if ch.part != nil {
                    Divider()
                    Button(L("Take Out of the Part")) { session.movePart(of: ch.id, to: nil) }
                }
            }
            Divider()
            Button(L("Move to Drafts")) { session.chapterToDrafts(ch.id) }
            Button(L("Move to Trash")) { session.chapterToTrash(ch.id) }
        }
    }

    @ViewBuilder
    func sceneRow(_ ch: ChapterEntry, _ scene: ChapterScene, index: Int) -> some View {
        let active = app.specialPage == nil && ch.id == session.selectedChapterID && currentScene?.id == scene.id
        SidebarRowView(active: active) {
            Text(scene.title ?? L("Opening"))
                .lineLimit(1).truncationMode(.tail)
                .fontWeight(active ? .medium : .regular)
                .foregroundStyle(active ? .primary : .secondary)
                .padding(.leading, 26)
            Spacer(minLength: 4)
            StatusDot(status: session.sceneStatus(ch.id, scene.key))
            Text(Self.compact(scene.words)).font(.ui(11).monospacedDigit()).foregroundStyle(.tertiary)
                .frame(width: 34, alignment: .trailing)
        }
        .onTapGesture { select("\(ch.id)\u{1}\(index)") }
        .help("\(session.sceneStatus(ch.id, scene.key).label) · \(scene.words) " + L("words"))
        .contextMenu {
            Picker(L("Status", ctx: "Statut"), selection: Binding(get: { session.sceneStatus(ch.id, scene.key) }, set: { session.setSceneStatus(ch.id, scene.key, $0) })) {
                ForEach(ChapterStatus.allCases) { Text($0.label).tag($0) }
            }
            if scene.marker != nil {
                Button(L("Rename Scene…")) { newTitle = scene.title ?? ""; renamingScene = (ch.id, scene) }
            }
        }
    }

    @ViewBuilder
    func specialRow(_ page: SpecialPage) -> some View {
        SidebarRowView(active: app.specialPage == page) {
            Image(systemName: page.icon).font(.ui(11)).foregroundStyle(.tertiary).frame(width: 16)
            Text(page.label).foregroundStyle(app.specialPage == page ? .primary : .secondary).lineLimit(1)
            Spacer()
        }
        .onTapGesture { select("special:" + page.rawValue) }
        .sidebarRow()
    }

    /// Front or back matter: folded away, since the chapters are what one comes for.
    @ViewBuilder
    func pagesGroup(_ title: String, _ pages: [SpecialPage], open: Binding<Bool>) -> some View {
        SidebarRowView(active: false) {
            Image(systemName: open.wrappedValue ? "chevron.down" : "chevron.right").font(.ui(8)).foregroundStyle(.tertiary).frame(width: 16)
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture { open.wrappedValue.toggle() }
        .sidebarRow()
        if open.wrappedValue { ForEach(pages) { specialRow($0) } }
    }

    func foldLabel(_ text: String, folded: Binding<Bool>) -> some View {
        HStack(spacing: 5) {
            Text(text).font(.ui(11, .medium)).foregroundStyle(.secondary)
            Image(systemName: folded.wrappedValue ? "chevron.right" : "chevron.down").font(.ui(8)).foregroundStyle(.tertiary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8).padding(.top, 12).padding(.bottom, 4)
        .contentShape(Rectangle())
        .onTapGesture { folded.wrappedValue.toggle() }
        .accessibilityAddTraits(.isButton)
        .sidebarRow()
    }

    func groupLabel(_ text: String) -> some View {
        Text(text).font(.ui(11, .medium)).foregroundStyle(.secondary)
            .padding(.horizontal, 8).padding(.top, 12).padding(.bottom, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .sidebarRow()
    }

    /// 1 248 → "1,2k" (or "1.2k"), short enough for the sidebar.
    static func compact(_ n: Int) -> String {
        guard n >= 1000 else { return "\(n)" }
        let v = (Double(n) / 1000 * 10).rounded() / 10
        let s = v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
        return s.replacingOccurrences(of: ".", with: UILang.locale.decimalSeparator ?? ".") + "k"
    }

    private func renameScene(_ chapterID: String, _ scene: ChapterScene, to title: String) {
        let t = title.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, let marker = scene.marker else { return }
        if chapterID == session.selectedChapterID {
            bridge.replace(marker, with: Scenes.markerLine(t))
            session.flushSave()
        } else {
            session.renameSceneOnDisk(chapterID, scene, to: t)
        }
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

/// One sidebar line: 28 points, a soft grey ground when it is where you are.
struct SidebarRowView<Content: View>: View {
    let active: Bool
    @ViewBuilder let content: () -> Content
    var body: some View {
        HStack(spacing: 8) { content() }
            .font(.ui(13))
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(active ? Ink.selected : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
    }
}

extension View {
    /// A List row with no system chrome: no insets, separator or selection ground.
    func sidebarRow() -> some View {
        listRowInsets(EdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 10))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}

/// Chapter length relative to the longest chapter of the book.
struct LengthBar: View {
    let words: Int
    let longest: Int

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(.quaternary.opacity(0.5))
            Capsule().fill(.secondary.opacity(0.55))
                .frame(width: max(2, 36 * CGFloat(words) / CGFloat(longest)))
        }
        .frame(width: 36, height: 4)
    }
}

struct BookSwitcher: View {
    let app: AppState

    var body: some View {
        Menu {
            ForEach(Array(app.books.enumerated()), id: \.element.path) { i, b in
                Button {
                    app.switchToBook(index: i)
                } label: {
                    if b.path == app.current?.root.standardizedFileURL.path { Label(b.title, systemImage: "checkmark") } else { Text(b.title) }
                }
            }
            Divider()
            Button(L("New book…")) { app.showNewBook = true }
            Button(L("Open Book Folder…")) { app.addBookViaPanel() }
            if app.current != nil {
                Divider()
                Button(L("Book settings…")) { app.showBookSettings = true }
                Button(L("Cover & special pages")) { app.specialPage = .cover }
            }
            if let cur = app.current {
                Button(L("Remove ") + cur.title + L(" from Library")) { app.removeFromLibrary(cur.root.standardizedFileURL.path) }
            }
        } label: {
            Text(app.current?.title ?? L("No book")).font(.ui(13, .semibold)).foregroundColor(.primary)
                + Text("  ") + Text(Image(systemName: "chevron.down")).font(.ui(9, .semibold)).foregroundColor(.secondary)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .tint(.primary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A chapter's status beside its title, always shown; click it to change it.
struct StatusBadge: View {
    let status: ChapterStatus
    let set: (ChapterStatus) -> Void

    var body: some View {
        Menu {
            ForEach(ChapterStatus.allCases) { s in
                Button { set(s) } label: {
                    if s == status { Label(s.label, systemImage: "checkmark") } else { Text(s.label) }
                }
            }
        } label: {
            Text(status.label)
                .font(.ui(10, .semibold))
                .foregroundStyle(status == .draft ? Color.secondary : status.color)
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(status.color.opacity(status == .draft ? 0.12 : 0.18), in: Capsule())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help("\(status.label): \(status.help). Click to change.")
    }
}

extension ChapterStatus {
    var color: Color {
        switch self {
        case .draft: .gray
        case .done: .blue
        case .edited: .orange
        case .final: .green
        }
    }
}
