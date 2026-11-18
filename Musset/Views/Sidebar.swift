import SwiftUI

/// Follows the caret from a view of its own and says which scene it is in: the sidebar reads the caret nowhere
/// else, so it is evaluated again when the scene changes, not at every move of the caret. In a book with
/// sections, it is the innermost of the two the caret is in: the section's id then starts with « § ».
private struct CaretScene: View {
    let session: BookSession
    let bridge: EditorBridge
    @Binding var id: String?

    private var now: String? {
        guard let chapter = session.selectedChapterID else { return nil }
        let at = bridge.selectedRange.location
        let scenes = session.scenes[chapter] ?? []
        let scene = scenes.contains(where: { $0.marker != nil }) ? Scenes.scene(at: at, in: scenes) : nil
        guard let section = Sections.section(at: at, in: session.sections[chapter] ?? []) else { return scene?.id }
        if let scene, scene.range.location > section.line.location { return scene.id }
        return "§" + section.id
    }

    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .onChange(of: now, initial: true) { _, new in if id != new { id = new } }
    }
}

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
    /// The chapters a strand is being made for, from their menu.
    @State private var newStrandFor: [String]?
    @AppStorage("sidebarFoldedParts") private var foldedParts = ""
    /// The scene the caret is in, in the open chapter (see `CaretScene`).
    @State private var currentSceneID: String?

    /// Overview's row is lit on Summary and Grid; Synopsis has its own row, which opens Overview on that page.
    private var overviewShown: Bool { app.activeTab?.overview.map { $0 != .synopsis } ?? false }

    var body: some View {
        VStack(spacing: 0) {
            CaretScene(session: session, bridge: bridge, id: $currentSceneID)
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
                    let all = app.activeTab?.special != nil
                    let frontPages = SpecialPage.front.filter { all || front.has($0) }
                    let back = SpecialPage.back.filter { all || front.has($0) }
                    SidebarRowView(active: overviewShown) {
                        Image(systemName: "square.grid.2x2").font(.ui(11)).foregroundStyle(.tertiary).frame(width: 16)
                        Text(L("Overview"))
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { app.open(clicked: OverviewTab.summary.tab) }
                    .rowButton(L("Overview"), selected: overviewShown)
                    .contextMenu { OpenElsewhere(tab: .overview(OverviewTab.summary.rawValue), app: app, session: session) }
                    .sidebarRow()
                    SidebarRowView(active: app.activeTab == OverviewTab.synopsis.tab) {
                        Image(systemName: "text.alignleft").font(.ui(11)).foregroundStyle(.tertiary).frame(width: 16)
                        Text(L("Synopsis"))
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { app.open(clicked: OverviewTab.synopsis.tab) }
                    .rowButton(L("Synopsis"), selected: app.activeTab == OverviewTab.synopsis.tab)
                    .contextMenu { OpenElsewhere(tab: OverviewTab.synopsis.tab, app: app, session: session) }
                    .sidebarRow()
                    foldLabel(L("Book"), folded: $bookFolded)
                    if !bookFolded, !frontPages.isEmpty { pagesGroup(L("Front"), frontPages, open: $showFront) }
                    let rows = bookFolded ? [] : bookRows
                    let marks = session.manifest.pieceMarks
                    ForEach(rows) { row in
                        switch row {
                        case .part(let part):
                            partRow(part).sidebarRow()
                        case .chapter(let ch, let idx):
                            VStack(spacing: 1) {
                                chapterRow(ch, idx, mark: marks[safe: idx] ?? "")
                                if expanded.contains(ch.id) {
                                    // Its scenes and, in a book that has them, its sections, in the text's order.
                                    ForEach(inside(ch.id)) { row in
                                        switch row {
                                        case .scene(let scene, let i): sceneRow(ch, scene, index: i)
                                        case .section(let section): sectionRow(ch, section)
                                        }
                                    }
                                }
                            }
                            .padding(.leading, session.manifest.group(of: ch) != nil ? 12 : 0)
                            .sidebarRow()
                        }
                    }
                    // Not onMove: the rows' tap gesture keeps the List from ever starting its own drag.
                    .dropDestination(for: String.self) { wires, offset in
                        let place = dropPlace(offset, in: rows)
                        session.dropOnBook(wires, at: place.index, part: .some(place.part))
                        // A draft sheet that became a chapter is no longer there to show.
                        if case .sheet(let path)? = app.activeTab, session.bible.entry(path: path) == nil { app.showChapter() }
                    }
                    // The chapters still to write, greyed: they open the plan.
                    if !bookFolded {
                        ForEach(session.plot.planned ?? []) { p in
                            SidebarRowView(active: false) {
                                Text(p.title).foregroundStyle(.tertiary).lineLimit(1)
                                Spacer(minLength: 4)
                                Text(L("planned")).font(.ui(11)).foregroundStyle(.tertiary)
                            }
                            .padding(.leading, 18)
                            .contentShape(Rectangle())
                            .onTapGesture { app.open(OverviewTab.synopsis.tab) }
                            .rowButton(p.title + ", " + L("planned"))
                            .sidebarRow()
                        }
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
                        Text(session.bookCounts.label)
                            .help(ChapterStatus.allCases.map { s in "\(s.label): \(session.manifest.chapters.filter { ($0.status ?? .draft) == s }.count)" }.joined(separator: " · "))
                        if CountUnit.current == .words, let goal = session.manifest.goal, goal > 0 { Text("/ \(goal.ui)").foregroundStyle(.tertiary) }
                        Spacer()
                        if session.wordsToday > 0 { Text(L("+\(session.wordsToday) today")).foregroundStyle(Ink.positive) }
                    }
                    .font(.ui(12).monospacedDigit()).foregroundStyle(.secondary)
                    HStack(spacing: 14) {
                        Button { newTitle = ""; addingChapter = true } label: { Image(systemName: "plus") }
                            .help(session.words.newPiece).accessibilityLabel(session.words.newPiece)
                        Spacer()
                        Button { app.openSearch() } label: { Image(systemName: "magnifyingglass") }
                            .help(AppCommand.hint(L("Search the Book…").titled, "book.search")).accessibilityLabel(L("Search the Book…").titled)
                        Button { app.open(OverviewTab.grid.tab) } label: { Image(systemName: "tablecells") }
                            .help(AppCommand.hint(L("Plot Grid"), "view.grid")).accessibilityLabel(L("Plot Grid"))
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12).padding(.bottom, 10)
            }
        }
        .background(Ink.side)
        .alert(session.words.renamePiece, isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField(L("Title"), text: $newTitle)
            Button(L("Rename")) { if let r = renaming { session.renameChapter(r.id, to: newTitle) }; renaming = nil }
            Button(L("Cancel"), role: .cancel) { renaming = nil }
        }
        .alert(session.words.nameGroup, isPresented: Binding(get: { renamingPart != nil }, set: { if !$0 { renamingPart = nil } })) {
            TextField(L("Title (optional)"), text: $newTitle)
            Button("OK") { if let p = renamingPart { session.renamePart(p.id, to: newTitle) }; renamingPart = nil }
            Button(L("Cancel"), role: .cancel) { renamingPart = nil }
        } message: {
            Text(session.words.groupNumberNote)
        }
        .alert(session.words.renameScene.titled, isPresented: Binding(get: { renamingScene != nil }, set: { if !$0 { renamingScene = nil } })) {
            TextField(L("Title"), text: $newTitle)
            Button(L("Rename")) { if let r = renamingScene { renameScene(r.chapter, r.scene, to: newTitle) }; renamingScene = nil }
            Button(L("Cancel"), role: .cancel) { renamingScene = nil }
        }
        .newStrandAlert(for: $newStrandFor, session: session)
        .onAppear { if let id = session.selectedChapterID { expanded.insert(id) } }
        .onChange(of: session.selectedChapterID) { _, id in if let id { expanded.insert(id) } }
        .alert(session.words.newPiece, isPresented: $addingChapter) {
            TextField(L("Title"), text: $newTitle)
            Button(L("Create")) { if !newTitle.isEmpty { session.addChapter(title: newTitle) } }
            Button(L("Cancel"), role: .cancel) {}
        }
    }
}

/// What a chapter unfolds to in the sidebar: a scene, or a section (a sub-heading).
enum ChapterInside: Identifiable {
    case scene(ChapterScene, Int)
    case section(ChapterSection)

    var id: String {
        switch self {
        case .scene(let s, _): s.id
        case .section(let s): "§" + s.id
        }
    }

    var location: Int {
        switch self {
        case .scene(let s, _): s.range.location
        case .section(let s): s.line.location
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

    private func inPart(_ id: String) -> Bool { session.manifest.groupsOn && session.manifest.parts?.contains { $0.id == id } == true }

    /// Each part's heading before its first chapter; a folded part hides its chapters; empty parts come last.
    var bookRows: [BookListRow] {
        let m = session.manifest
        var out: [BookListRow] = []
        var previous: String?
        for (i, ch) in m.chapters.enumerated() {
            let part = m.group(of: ch)
            if let part, part.id != previous { out.append(.part(part)) }
            previous = part?.id
            if part.map({ !folded.contains($0.id) }) ?? true { out.append(.chapter(ch, i)) }
        }
        for part in m.shownParts where !m.chapters.contains(where: { $0.part == part.id }) { out.append(.part(part)) }
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
        let size = members.reduce(0) { $0 + (session.chapterCounts[$1.id]?.size ?? 0) }
        return SidebarRowView(active: false) {
            Image(systemName: isFolded ? "chevron.right" : "chevron.down").font(.ui(8)).foregroundStyle(.tertiary).frame(width: 16)
            // A level without numbers has only its title to show, or its name for want of one.
            let numeral = session.manifest.numeral(of: part.id)
            // « I » for a part, as always; a level with a name of its own says it when it has no title: « Acte I ».
            let named = part.title.isEmpty && !session.words.usual(.group)
            if !numeral.isEmpty { Text(named ? session.manifest.heading(of: part) : numeral).font(.ui(12, .semibold)).lineLimit(1) }
            if !part.title.isEmpty {
                Text(part.title).lineLimit(1).truncationMode(.tail).foregroundStyle(numeral.isEmpty ? .primary : .secondary)
                    .fontWeight(numeral.isEmpty ? .semibold : .regular)
            } else if numeral.isEmpty {
                Text(session.manifest.level(.group).name).font(.ui(12, .semibold))
            }
            Spacer(minLength: 4)
            Text(members.isEmpty ? L("empty") : Self.compact(size)).font(.ui(11).monospacedDigit()).foregroundStyle(.tertiary)
                .frame(width: 34, alignment: .trailing)
            strandSlot(nil)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            var f = folded
            if f.contains(part.id) { f.remove(part.id) } else { f.insert(part.id) }
            foldedParts = f.sorted().joined(separator: ",")
        }
        .rowButton(session.manifest.label(of: part))
        .help(session.words.groupHelp(part, members: members.count))
        .contextMenu {
            Button(L("Name…")) { newTitle = part.title; renamingPart = part }
            Divider()
            Button(session.words.deleteGroup) { session.deletePart(part.id) }
        }
    }

    /// A chapter's scenes (when it has markers) and sections, as they come in its text. A scene and a section that
    /// start together (a marker just above a sub-heading) list the section first: the scene is in it.
    func inside(_ chapterID: String) -> [ChapterInside] {
        let scenes = session.scenes[chapterID] ?? []
        var rows: [ChapterInside] = scenes.contains(where: { $0.marker != nil }) ? scenes.enumerated().map { .scene($1, $0) } : []
        let sections = session.sections[chapterID] ?? []
        guard !sections.isEmpty else { return rows }
        rows += sections.map { .section($0) }
        return rows.enumerated().sorted { a, b in a.element.location != b.element.location ? a.element.location < b.element.location : a.offset < b.offset }.map(\.element)
    }

    /// Row tags: a chapter's id, or "<chapter>\u{1}<scene index>" for a scene.
    private func select(_ tag: String) {
        if tag.hasPrefix("special:") { app.open(.special(String(tag.dropFirst(8)))); return }
        app.showChapter()
        let parts = tag.components(separatedBy: "\u{1}")
        let chapterID = parts[0]
        guard parts.count == 2, let i = Int(parts[1]), let scene = session.scenes[chapterID]?[safe: i] else {
            if chapterID != session.selectedChapterID { session.open(chapterID) }
            return
        }
        bridge.show(scene, chapter: chapterID, session: session)
    }


    @ViewBuilder
    func chapterRow(_ ch: ChapterEntry, _ idx: Int, mark: String) -> some View {
        let open = app.activeTab?.special == nil && ch.id == session.selectedChapterID
        // What unfolds under it: its scenes, and its sections in a book that has them.
        let hasScenes = (session.scenes[ch.id] ?? []).contains { $0.marker != nil } || session.sections[ch.id]?.isEmpty == false
        let unfolded = expanded.contains(ch.id)
        let strand = session.manifest.strand(of: ch)
        // What the row says under the pointer: « Chapitre 3 · Fil : 1943 · Écrit · 1 204 mots ».
        let heading: String = session.manifest.heading(of: ch).map { $0 + " · " } ?? ""
        let thread: String = strand.map { L("Strand: \($0.shownName)") + " · " } ?? ""
        let said: String = heading + thread + "\((ch.status ?? .draft).label) · " + (session.chapterCounts[ch.id] ?? .zero).label
        let spoken: String = "\(session.manifest.heading(of: ch) ?? "") \(ch.title), \((ch.status ?? .draft).label)".trimmingCharacters(in: .whitespaces)
            + (strand.map { ", " + $0.shownName } ?? "")
        let fold = { if expanded.contains(ch.id) { expanded.remove(ch.id) } else { expanded.insert(ch.id) } }
        let click = {
            if open && hasScenes { fold() } else { app.open(.chapter(ch.id)) { select(ch.id) } }
        }
        SidebarRowView(active: open && !hasScenes) {
            // An unnumbered piece (a prologue, an interlude) carries no number and reads in italics.
            let unnumbered = BookManifest.kind(of: ch) != nil
            Text(mark).font(.uiMono(11)).foregroundStyle(.tertiary)
                .frame(minWidth: 16, alignment: .trailing)
            Text(session.manifest.shownTitle(of: ch)).lineLimit(1).truncationMode(.tail)
                .font(unnumbered ? .system(size: 13.5, design: .serif).italic() : .ui(13))
                .fontWeight(open ? .medium : .regular)
                .foregroundStyle(ch.excludeFromExport || unnumbered && !open ? .secondary : .primary)
            // Its scenes unfold from here, whether or not the chapter is the open one.
            if hasScenes {
                Button(action: fold) {
                    Image(systemName: unfolded ? "chevron.down" : "chevron.right").font(.ui(8)).foregroundStyle(.tertiary)
                        .frame(width: 14, height: 20).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(unfolded ? session.words.hideScenes : session.words.showScenes)
            }
            Spacer(minLength: 4)
            if let n = session.versionCounts[ch.id] {
                HStack(spacing: 2) { Image(systemName: "square.on.square").font(.ui(9)); Text("\(n)").font(.ui(10).monospacedDigit()) }
                    .foregroundStyle(.secondary)
                    .help(L("\(n) versions"))
            }
            StatusDot(status: ch.status ?? .draft)
            Text(Self.compact(session.chapterCounts[ch.id]?.size ?? 0)).font(.ui(11).monospacedDigit()).foregroundStyle(.tertiary)
                .frame(width: 34, alignment: .trailing)
            strandSlot(strand)
        }
        .onTapGesture(perform: click)
        .shelfDraggable(.chapter(ch.id), title: ch.title)
        .help(said)
        // One element for VoiceOver: pressing it is the click; the scenes unfold from its actions.
        .rowButton(spoken, selected: open)
        .accessibilityAction(.default, click)
        .accessibilityAction(named: unfolded ? session.words.hideScenes : session.words.showScenes) { if hasScenes { fold() } }
        .contextMenu {
            OpenElsewhere(tab: .chapter(ch.id), app: app, session: session)
            Divider()
            Picker(L("Status"), selection: Binding(get: { ch.status ?? .draft }, set: { session.setStatus(ch.id, $0) })) {
                ForEach(ChapterStatus.allCases) { Text($0.label).tag($0) }
            }
            if AIStatus.shared.isOn {
                Menu(session.words.proposeScenes.titled) {
                    ForEach(AIStatus.shared.engines) { engine in
                        Button(L("With \(engine.label)…")) { if ch.id != session.selectedChapterID { session.open(ch.id) }; scenePlanner?(engine) }
                    }
                }
            }
            Button(session.words.newVersion) {
                if ch.id != session.selectedChapterID { select(ch.id) }
                app.showTryVersion = true
            }
            .help(L("Another version of this chapter; the book keeps its own until you choose."))
            Divider()
            Button(L("Rename…")) { newTitle = ch.title; renaming = ch }
            Button(ch.excludeFromExport ? L("Include in export") : L("Exclude from export")) { session.toggleExport(ch.id) }
            Button(L("Reveal in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([session.store.url(for: ch)]) }
            if session.manifest.groupsOn {
                Menu(session.words.name(.group)) {
                    Button(session.words.newGroupHere) { session.newPart(startingAt: ch.id) }
                    let parts = session.manifest.orderedParts.filter { $0.id != ch.part }
                    if !parts.isEmpty {
                        Divider()
                        ForEach(parts) { p in Button(L("Move to \(session.words.groupName(p))")) { session.movePart(of: ch.id, to: p.id) } }
                    }
                    if ch.part != nil {
                        Divider()
                        Button(session.words.takeOutOfGroup) { session.movePart(of: ch.id, to: nil) }
                    }
                }
            }
            // A prologue, an interlude: it carries its kind's name and takes no number.
            Menu(L("Unnumbered")) {
                let kind = BookManifest.kind(of: ch)
                ForEach(session.manifest.unnumberedKinds, id: \.self) { k in
                    Toggle(session.manifest.kindName(k), isOn: Binding(get: { kind == k }, set: { _ in session.setKind(ch.id, k) }))
                }
                // A kind the book no longer offers stays on the pieces that carry it.
                if let kind, !session.manifest.unnumberedKinds.contains(kind) {
                    Toggle(session.manifest.kindName(kind), isOn: .constant(true))
                }
                Divider()
                Toggle(L("Numbered"), isOn: Binding(get: { kind == nil }, set: { _ in session.setKind(ch.id, nil) }))
            }
            // The thread it follows through the book: a period, a narrator, a place.
            StrandMenu(session: session, chapters: [ch.id]) { newStrandFor = $0 }
            Divider()
            Button(L("Move to Drafts")) { session.chapterToDrafts(ch.id) }
            Button(L("Move to Trash"), role: .destructive) { session.chapterToTrash(ch.id) }
        }
    }

    /// The strand's mark, at the row's far right: a column of its own down the list, the count between it and the
    /// status's dot. Only in a book that has strands; there, every row keeps the column, so the counts stay in line.
    @ViewBuilder
    func strandSlot(_ strand: BookStructure.Strand?) -> some View {
        if !session.manifest.strands.isEmpty {
            if let strand { StrandMark(colour: strand.colour).padding(.leading, -2) } else { Color.clear.frame(width: 8, height: 8).padding(.leading, -2) }
        }
    }

    @ViewBuilder
    func sceneRow(_ ch: ChapterEntry, _ scene: ChapterScene, index: Int) -> some View {
        let active = app.activeTab?.special == nil && ch.id == session.selectedChapterID && currentSceneID == scene.id
        SidebarRowView(active: active) {
            Text(scene.title ?? L("Opening"))
                .lineLimit(1).truncationMode(.tail)
                .fontWeight(active ? .medium : .regular)
                .foregroundStyle(active ? .primary : .secondary)
                .padding(.leading, 26)
            Spacer(minLength: 4)
            StatusDot(status: session.sceneStatus(ch.id, scene.key))
            Text(Self.compact(scene.counts.size)).font(.ui(11).monospacedDigit()).foregroundStyle(.tertiary)
                .frame(width: 34, alignment: .trailing)
            strandSlot(nil)
        }
        .onTapGesture { select("\(ch.id)\u{1}\(index)") }
        .rowButton((scene.title ?? L("Opening")) + ", " + session.sceneStatus(ch.id, scene.key).label, selected: active)
        .help("\(session.sceneStatus(ch.id, scene.key).label) · " + scene.counts.label)
        .contextMenu {
            Picker(L("Status"), selection: Binding(get: { session.sceneStatus(ch.id, scene.key) }, set: { session.setSceneStatus(ch.id, scene.key, $0) })) {
                ForEach(ChapterStatus.allCases) { Text($0.label).tag($0) }
            }
            if scene.marker != nil {
                Button(session.words.renameScene) { newTitle = scene.title ?? ""; renamingScene = (ch.id, scene) }
            }
        }
    }

    /// A section of the chapter: its sub-heading, a deeper one further in. A click puts the caret there.
    @ViewBuilder
    func sectionRow(_ ch: ChapterEntry, _ section: ChapterSection) -> some View {
        let active = app.activeTab?.special == nil && ch.id == session.selectedChapterID && currentSceneID == "§" + section.id
        SidebarRowView(active: active) {
            Text(section.title)
                .lineLimit(1).truncationMode(.tail)
                .fontWeight(active ? .medium : .regular)
                .foregroundStyle(active ? .primary : .secondary)
                .padding(.leading, section.level > 2 ? 38 : 26)
            Spacer(minLength: 4)
        }
        .onTapGesture {
            app.showChapter()
            bridge.show(section, chapter: ch.id, session: session)
        }
        .rowButton(section.title, selected: active)
        .help(session.manifest.shownTitle(of: ch) + " · " + section.title)
    }

    @ViewBuilder
    func specialRow(_ page: SpecialPage) -> some View {
        SidebarRowView(active: app.activeTab == page.tab) {
            Image(systemName: page.icon).font(.ui(11)).foregroundStyle(.tertiary).frame(width: 16)
            Text(page.label).foregroundStyle(app.activeTab == page.tab ? .primary : .secondary).lineLimit(1)
            Spacer()
        }
        .onTapGesture { app.open(.special(page.rawValue)) { select("special:" + page.rawValue) } }
        .rowButton(page.label, selected: app.activeTab == page.tab)
        .contextMenu { OpenElsewhere(tab: .special(page.rawValue), app: app, session: session) }
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
        .rowButton(title)
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

    /// 1 248 → "1,2k" (or "1.2k"), short enough for the sidebar. Characters run longer: 135 400 → "135k".
    static func compact(_ n: Int) -> String {
        guard n >= 1000 else { return "\(n)" }
        guard n < 100_000 else { return "\(Int((Double(n) / 1000).rounded()))k" }
        let v = (Double(n) / 1000 * 10).rounded() / 10
        let s = v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
        return s.replacingOccurrences(of: ".", with: UILang.locale.decimalSeparator ?? ".") + "k"
    }

    /// In the chapter one is in, with its editor on screen, the rename is the editor's own edit: ⌘Z takes it back.
    private func renameScene(_ chapterID: String, _ scene: ChapterScene, to title: String) {
        guard let index = session.scenes[chapterID]?.firstIndex(where: { $0.id == scene.id }) else { return }
        let live = chapterID == session.selectedChapterID && bridge.textView != nil
        session.renameScene(chapterID, index: index, to: title, editor: live ? { bridge.replace($0, with: $1) } : nil)
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
            .background(active ? Ink.selected : .clear, in: RoundedRectangle(cornerRadius: Radius.row))
            .contentShape(Rectangle())
    }
}

/// "Open Beside" and "Open in New Window": the context menu of every sidebar row that opens a tab.
struct OpenElsewhere: View {
    let tab: PaneTab
    let app: AppState
    let session: BookSession

    var body: some View {
        // The one place that says what the clicks do: ⌘-click for the next pane, ⌥-click for a new tab.
        Button(L("Open Beside")) { session.open(tab, in: .nextPane) }
            .help(L("Or ⌘-click the row. ⌥-click opens it in a new tab."))
        Button(L("Open in New Window")) { app.openInNewWindow(tab, of: session) }
    }
}

extension View {
    /// What a sidebar row made of a tap gesture lacks for VoiceOver: one element, said to be a button, and
    /// selected when it is where one is. The gestures themselves are left as they are.
    func rowButton(_ label: String, selected: Bool = false) -> some View {
        accessibilityElement(children: .combine)
            .accessibilityLabel(label)
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    /// A List row with no system chrome: no insets, separator or selection ground.
    func sidebarRow() -> some View {
        listRowInsets(EdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 10))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}

struct BookSwitcher: View {
    let app: AppState

    var body: some View {
        Menu {
            // Home: every book, with its cover. Then the books themselves, one click away.
            Button(L("All Books")) { app.showHome = true }
            Divider()
            ForEach(Array(app.books.enumerated()), id: \.element.path) { i, b in
                Button {
                    app.switchToBook(index: i)
                } label: {
                    if b.path == app.current?.root.standardizedFileURL.path { Label(b.title, systemImage: "checkmark") } else { Text(b.title) }
                }
            }
            Divider()
            Button(L("New Book…")) { app.showNewBook = true }
            Button(L("Open Book Folder…")) { app.addBookViaPanel() }
            if app.current != nil {
                Divider()
                Button(L("Book Settings…")) { app.showBookSettings = true }
                Button(L("Cover & Special Pages")) { app.open(SpecialPage.cover.tab) }
            }
            if let cur = app.current {
                Button(L("Remove \(cur.title) from Library")) { app.removeFromLibrary(cur.root.standardizedFileURL.path) }
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
