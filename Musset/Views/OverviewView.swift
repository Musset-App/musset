import SwiftUI

/// The pages of Overview, the one place the book is planned: the book in numbers over its scenes, its synopsis
/// chapter by chapter, its grid scene by scene. The first keeps the raw value it had as the Summary: saved layouts
/// and the sidebar's row land on it, and so does a layout kept on the Scenes page it took in.
/// Then the two that are about the book rather than its plan: who reads it, and its settings.
enum OverviewTab: String, CaseIterable, Identifiable {
    case summary, synopsis, grid, milestones, readers, settings
    /// The planning pages come first in the bar, then the debate, then these.
    static let planning: [OverviewTab] = [.summary, .synopsis, .grid]
    static let about: [OverviewTab] = [.milestones, .readers, .settings]
    var id: String { rawValue }
    var label: String {
        switch self {
        case .summary: L("Overview")
        case .synopsis: L("Synopsis")
        case .grid: L("Grid")
        case .milestones: L("Milestones")
        case .readers: L("Readers")
        case .settings: L("Settings")
        }
    }
    var tab: PaneTab { .overview(rawValue) }
}

/// The book's own home: its numbers and its scenes, its synopsis, its plot grid.
struct OverviewView: View {
    @Bindable var app: AppState
    @Bindable var session: BookSession
    let bridge: EditorBridge
    let analyst: PlotAnalyst
    let planner: ScenePlanner
    /// The pane this tab is in: the board of scenes opens chapters there.
    let workspace: Workspace
    let paneID: String
    let fontName: String
    /// The page this tab shows.
    let shown: OverviewTab
    /// Turns this tab to another page.
    let show: (OverviewTab) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                ForEach(OverviewTab.planning) { pageButton($0) }
                // The debate has a tab of its own; the book's home leads to it, as its other pages do.
                if AIHome.shown {
                    Button { app.open(.debate) } label: {
                        Text(L("Debate")).font(.ui(13)).foregroundStyle(.secondary)
                            .padding(.horizontal, 11).frame(height: 28).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                ForEach(OverviewTab.about) { pageButton($0) }
                Spacer()
            }
            .padding(.horizontal, 20).frame(height: 44)
            Divider()
            switch shown {
            case .summary: BookOverviewPage(app: app, session: session, workspace: workspace, paneID: paneID, fontName: fontName)
            case .synopsis: SynopsisView(app: app, session: session)
            case .grid: PlotGridView(app: app, session: session, bridge: bridge, analyst: analyst, planner: planner)
            case .milestones: MilestonesPage(app: app, session: session)
            case .readers: ReadersPage(app: app, session: session)
            case .settings: BookSettingsView(app: app, session: session)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func pageButton(_ tab: OverviewTab) -> some View {
        Button { show(tab) } label: {
            Text(tab.label).font(.ui(13, shown == tab ? .medium : .regular))
                .foregroundStyle(shown == tab ? .primary : .secondary)
                .padding(.horizontal, 11).frame(height: 28)
                .background(shown == tab ? Ink.selected : .clear, in: RoundedRectangle(cornerRadius: Radius.control))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(shown == tab ? [.isButton, .isSelected] : .isButton)
    }
}

/// What a chapter's row says, computed from its files.
struct ChapterSummary: Identifiable {
    let chapter: ChapterEntry
    /// Its number as the book writes it; empty for a piece that carries none.
    let mark: String
    let counts: TextCounts
    var words: Int { counts.words }
    let score: Double?
    let axis: String?
    let todos: Int
    let touched: Date?
    var id: String { chapter.id }
}

extension BookSession {
    func chapterSummaries(todos: [TodoItem]) -> [ChapterSummary] {
        let marks = manifest.pieceMarks
        return manifest.chapters.enumerated().map { i, ch in
            let last = Reading.load(root, ch.id).last
            let date = try? store.url(for: ch).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            return ChapterSummary(chapter: ch, mark: marks[i], counts: chapterCounts[ch.id] ?? .zero, score: last?.total, axis: last?.advice?.axes.first?.title,
                                  todos: todos.filter { $0.chapter == ch.id && !$0.done }.count, touched: date)
        }
    }

    /// What happened, in the author's words: readings and milestones, then the days written.
    func workEvents(limit: Int = 7) -> [(date: Date, text: String)] {
        var events: [(Date, String)] = []
        for ch in manifest.chapters {
            let readings = Reading.load(root, ch.id)
            for (i, r) in readings.enumerated().suffix(3) {
                let total = Int(r.total.rounded())
                let delta = i > 0 ? total - Int(readings[i - 1].total.rounded()) : 0
                events.append((r.date, L("AI reading of \(ch.title): \(String(total))") + (delta == 0 ? "" : " (\(delta > 0 ? "+" : "")\(delta))")))
            }
        }
        for tag in jalons { events.append((tag.date, L("Milestone: \(tag.title)"))) }
        let days = Dictionary(grouping: git.commitDates(limit: 400)) { Calendar.current.startOfDay(for: $0) }
        for (day, commits) in days { events.append((day, L("\(commits.count) sittings"))) }
        return events.sorted { $0.0 > $1.0 }.prefix(limit).map { (date: $0.0, text: $0.1) }
    }
}

/// Overview's first page: the book in numbers, then its scenes, in one scroll. The numbers are a band that scrolls
/// away; the board under it is the page's matter, as cards on their ground or as the list of chapters.
struct BookOverviewPage: View {
    let app: AppState
    @Bindable var session: BookSession
    let workspace: Workspace
    let paneID: String
    let fontName: String
    /// The board as the list of chapters rather than as cards: the author's choice, kept.
    @AppStorage(BookOverviewPage.listKey) private var asList = false
    @AppStorage("sceneCardSize") private var cardSize = 300.0
    @State private var chosenScene: BookScenesView.SceneRef?
    @State private var todos: [TodoItem] = []
    @State private var rows: [ChapterSummary] = []
    @State private var work: [(date: Date, text: String)] = []
    @State private var days: BookNumbers.Days?
    @State private var showsNext = false
    /// The chapters a strand is being made for, from their menu.
    @State private var newStrandFor: [String]?

    static let listKey = "overviewBoardAsList"
    static let margin = SceneCardsView.margin
    private static let board = "overview.board"

    var body: some View {
        let part = asList ? nil : session.scenesPart(in: workspace)
        // The strand read alone, if one is: the board, the list and the lanes keep its chapters only.
        let strand = session.scenesStrand(in: workspace)
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        BookNumbersHeader(session: session, current: session.selectedChapterID ?? workspace.saved.lastChapter,
                                          width: geo.size.width, todos: todos.filter { !$0.done }.count, days: days, reading: strand,
                                          showsNext: $showsNext,
                                          pick: { session.showOnBoard($0, in: workspace) },
                                          enter: { session.enterChapter($0, in: workspace, pane: paneID) },
                                          zoom: { session.showPartOnBoard($0, in: workspace) },
                                          read: { session.readStrand($0, in: workspace) }) {
                            ComesNext(session: session, rows: rows, todos: todos, work: work, open: open,
                                      allTasks: { showsNext = false; app.inspectorTab = .edits; app.showInspector = true },
                                      reload: reload)
                        }
                        .background(Color(nsColor: .textBackgroundColor))
                        Divider()
                        boardHeader(part, strand).id(Self.board)
                        if asList {
                            // The rows are kept from the last reload; what each follows is read from the book as it is now.
                            let m = session.manifest
                            let follows = m.strands.isEmpty ? [:] : Dictionary(m.chapters.compactMap { ch in m.strand(of: ch).map { (ch.id, $0) } }, uniquingKeysWith: { a, _ in a })
                            ChapterTable(rows: strand.map { s in rows.filter { follows[$0.id]?.id == s.id } } ?? rows, threshold: threshold,
                                         chosen: workspace.scenesChapter, open: open, hasStrands: !m.strands.isEmpty, strands: follows,
                                         menu: { id in StrandMenu(session: session, chapters: [id]) { newStrandFor = $0 } })
                                .padding(.horizontal, Self.margin).padding(.bottom, 40)
                        } else {
                            BookScenesView(session: session, workspace: workspace, paneID: paneID, fontName: fontName,
                                           width: geo.size.width, part: part, strand: strand, chosenScene: $chosenScene,
                                           newStrand: { newStrandFor = $0 })
                                .padding(.bottom, 88)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onAppear { jump(proxy) }
                .onChange(of: workspace.scenesJump) { _, _ in jump(proxy) }
            }
        }
        // The ground stays put under the cards, as under a chapter's; the list is read on the page's own colour.
        .background { if asList { Color(nsColor: .textBackgroundColor) } else { DotGround() } }
        .overlay(alignment: .bottomLeading) {
            if !asList {
                HStack(spacing: 10) {
                    SceneSizeControl(size: $cardSize)
                    SceneMoveUndoBar(session: session, shown: part != nil)
                }
                .padding(.leading, Self.margin).padding(.bottom, 16)
            }
        }
        .task(id: session.manifest.chapters.count) { reload() }
        .newStrandAlert(for: $newStrandFor, session: session)
    }

    private var threshold: Double { Bareme.forBook(session.root)?.threshold ?? 80 }

    private func reload() {
        todos = session.collectTodos()
        rows = session.chapterSummaries(todos: todos)
        work = session.workEvents()
        days = BookNumbers.days(session.git.commitDates(limit: 400))
    }

    private func open(_ ch: ChapterEntry) {
        showsNext = false
        app.showChapter()
        session.open(ch.id)
    }

    /// The scroll asked for from outside the page (a chapter's cards one zooms out of, a bar, a part's name): past
    /// the numbers to the board, on the chapter when there is one. Opened from anywhere else, the page starts at its top.
    private func jump(_ proxy: ScrollViewProxy) {
        guard let jump = workspace.takeScenesJump() else { return }
        // The cards a list gives way to are laid out before they can be scrolled to.
        let wait = jump.cards && asList ? 0.15 : 0
        if jump.cards { asList = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
            if let chapter = jump.chapter { proxy.scrollTo(chapter, anchor: .center) } else { proxy.scrollTo(Self.board, anchor: .top) }
        }
    }

    private func zoom(_ level: ScenesLevel) {
        switch level {
        case .book: workspace.zoomScenes(toPart: nil)
        case .part: if let id = session.scenesPartToZoom(in: workspace) { workspace.zoomScenes(toPart: id) }
        case .chapter:
            guard let id = session.scenesChapter(in: workspace) else { return }
            session.enterChapter(id, scene: chosenScene?.chapter == id ? chosenScene?.index : nil, in: workspace, pane: paneID)
        }
    }

    // MARK: The board's heading

    /// « Scènes », what the board holds, and on the right how it is seen: as cards or as a list, and from how far.
    private func boardHeader(_ part: BookPart?, _ strand: BookStructure.Strand?) -> some View {
        let title = Text(session.words.plural(.scene)).font(.system(size: 22, design: .serif)).fixedSize()
        let facts = boardFacts(part, strand)
        let controls = HStack(spacing: 12) {
            Segmented(options: [(false, L("Cards")), (true, L("List"))], selection: $asList).frame(width: 136).fixedSize()
            if !asList {
                ScenesZoomPill(level: part == nil ? .book : .part, hasParts: session.manifest.hasPartsInUse,
                               disabled: session.manifest.chapters.isEmpty ? [.chapter] : [], pick: zoom)
            }
        }
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 14) {
                title
                facts.fixedSize()
                Spacer(minLength: 16)
                controls
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 14) { title; facts }
                controls
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Self.margin).padding(.top, 18).padding(.bottom, 16)
    }

    /// What the board holds. Read along one strand, it says so first (« Strand: 1943 · 5 chapters · 12 034 words »),
    /// with the way back to the whole book beside it.
    private func boardFacts(_ part: BookPart?, _ strand: BookStructure.Strand?) -> some View {
        let m = session.manifest
        let chapters = m.boardChapters(part: part?.id, strand: strand?.id).map(\.entry)
        let scenes = chapters.reduce(0) { $0 + (session.scenes[$1.id]?.count ?? 0) }
        let parts = Set(m.scenesBands.compactMap { $0.part?.id }).count
        let words = session.words
        let length = chapters.reduce(TextCounts.zero) { $0 + (session.chapterCounts[$1.id] ?? .zero) }.label
        let facts = strand != nil ? [words.count(chapters.count, .piece), length]
            : (part == nil && parts > 0 ? [words.count(parts, .group)] : []) + [words.count(chapters.count, .piece), words.count(scenes, .scene)]
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            if let part { Text(session.partName(part)).font(.ui(12, .semibold)) }
            if let strand {
                HStack(alignment: .center, spacing: 6) {
                    StrandMark(colour: strand.colour, size: 9)
                    Text(L("Strand: \(strand.shownName)")).font(.ui(12, .semibold))
                }
            }
            Text(facts.joined(separator: " · ")).font(.ui(12).monospacedDigit()).foregroundStyle(.secondary)
            if strand != nil {
                Button { session.readStrand(nil, in: workspace) } label: {
                    Text(L("Whole book")).font(.ui(12)).foregroundStyle(Ink.accent).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .lineLimit(1)
    }
}

/// The book chapter by chapter, as a table: status, length, the AI reader's score, what is left to do, when it was
/// last touched. The board's other face, for who reads a list better than cards.
struct ChapterTable<Menu: View>: View {
    @Environment(\.bookWords) private var words
    let rows: [ChapterSummary]
    let threshold: Double
    /// The chapter chosen on the board.
    let chosen: String?
    let open: (ChapterEntry) -> Void
    /// The book has strands: the table has their column. Without, it is the table it always was.
    var hasStrands = false
    /// The strand each chapter follows, by the chapter's id.
    var strands: [String: BookStructure.Strand] = [:]
    /// A chapter's menu, by its id.
    @ViewBuilder let menu: (String) -> Menu
    @State private var width: CGFloat = 800

    /// Below this width, the table keeps what matters most: title, words, score.
    private var wide: Bool { width > 640 }

    private func columns<A: View, B: View, C: View, D: View, E: View, F: View, G: View, S: View>(_ a: A, _ b: B, strand s: S, _ c: C, _ d: D, _ e: E, _ f: F, _ g: G) -> some View {
        HStack(spacing: 10) {
            a.frame(width: 22, alignment: .trailing)
            b.frame(maxWidth: .infinity, alignment: .leading)
            // A narrow table keeps the strand's mark and lets its name go.
            if hasStrands { s.frame(width: wide ? 124 : 10, alignment: .leading).clipped() }
            if wide { c.frame(width: 84, alignment: .leading) }
            d.frame(width: 62, alignment: .trailing)
            e.frame(width: 36, alignment: .trailing)
            if wide { f.frame(width: 44, alignment: .trailing) }
            if wide { g.frame(width: 84, alignment: .trailing) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            columns(Text(""), Text(words.name(.piece)), strand: Text(wide ? L("Strand") : ""), Text(L("Status")), Text(CountUnit.current.heading), Text(L("Score")), Text(L("To do")), Text(L("Last time")))
                .font(.ui(11)).foregroundStyle(.secondary).lineLimit(1).padding(.bottom, 6)
            Divider()
            ForEach(rows) { r in
                columns(
                    Text(r.mark).font(.uiMono(11)).foregroundStyle(.secondary),
                    Button { open(r.chapter) } label: {
                        Text(words.manifest.shownTitle(of: r.chapter)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain),
                    strand: HStack(spacing: 6) {
                        if let strand = strands[r.id] {
                            StrandMark(colour: strand.colour)
                            Text(strand.shownName).font(.ui(12)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    },
                    HStack(spacing: 6) { StatusDot(status: r.chapter.status ?? .draft); Text((r.chapter.status ?? .draft).label).font(.ui(12)).foregroundStyle(.secondary).lineLimit(1) },
                    Text(r.counts.size.ui).font(.ui(12).monospacedDigit()).foregroundStyle(.secondary).lineLimit(1),
                    Text(r.score.map { "\(Int($0.rounded()))" } ?? "—").font(.ui(12, .medium).monospacedDigit())
                        .foregroundStyle((r.score ?? threshold) < threshold ? Ink.warning : .primary),
                    Text(r.todos == 0 ? "" : "\(r.todos)").font(.ui(12).monospacedDigit()).foregroundStyle(.secondary),
                    Text(r.touched.map(ChapterSummary.relative) ?? "").font(.ui(12)).foregroundStyle(.secondary).lineLimit(1))
                .frame(height: 32)
                .background(r.id == chosen ? Ink.selected : .clear)
                .contentShape(Rectangle())
                .contextMenu { menu(r.id) }
                .id(r.id)
                Divider()
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

}

extension ChapterSummary {
    /// « il y a 3 j »: when something was last touched, as the interface's language shortens it.
    static func relative(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.locale = UILang.locale
        f.unitsStyle = .short
        return f.localizedString(for: d, relativeTo: Date())
    }
}

/// What comes next, opened from the book's numbers: the one chapter to go to, the tasks, the work done lately.
struct ComesNext: View {
    let session: BookSession
    let rows: [ChapterSummary]
    let todos: [TodoItem]
    let work: [(date: Date, text: String)]
    let open: (ChapterEntry) -> Void
    let allTasks: () -> Void
    let reload: () -> Void

    private var threshold: Double { Bareme.forBook(session.root)?.threshold ?? 80 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                nextStep
                todoList
                if !work.isEmpty { workList }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 360, height: 520)
    }

    /// One recommendation only: the chapter furthest from the threshold, with its reader's first axis.
    @ViewBuilder private var nextStep: some View {
        let below = rows.filter { ($0.score ?? threshold) < threshold }.min { ($0.score ?? 0) < ($1.score ?? 0) }
        let unread = rows.first { $0.score == nil && $0.words > 0 }
        VStack(alignment: .leading, spacing: 6) {
            Text(L("The next step")).font(.ui(12, .medium)).foregroundStyle(Ink.accent)
            if let below, let score = below.score {
                Text(L("\(below.chapter.title) is the chapter furthest from the threshold: \(Int(score.rounded())) of \(Int(threshold))."))
                    .font(.system(size: 17, design: .serif))
                if let axis = below.axis { Text(L("Your AI reader’s last axis: \(axis)")).foregroundStyle(.secondary) }
                Button(L("Open \(below.chapter.title)")) { open(below.chapter) }.buttonStyle(.ink)
            } else if let unread {
                Text(L("\(unread.chapter.title) has not been read yet.")).font(.system(size: 17, design: .serif))
                Button(L("Open \(unread.chapter.title)")) { open(unread.chapter) }.buttonStyle(.ink)
            } else {
                Text(L("Every chapter read is at the threshold. Keep writing.")).font(.system(size: 17, design: .serif))
            }
            // The count the Summary gave beside the book's length.
            if rows.contains(where: { $0.score != nil }) {
                Text(L("\(rows.filter { ($0.score ?? 0) >= threshold }.count) of \(rows.count) chapters at the threshold"))
                    .font(.ui(11)).foregroundStyle(.secondary).padding(.top, 2)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Ink.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: Radius.card))
    }

    @ViewBuilder private var todoList: some View {
        let open = todos.filter { !$0.done }
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L("To do")).font(.ui(13, .semibold))
                Spacer()
                Text("\(open.count)").foregroundStyle(.secondary)
            }
            if open.isEmpty { EmptyNote(L("Nothing to do yet. ⌃⌥N captures a note or a task.")) }
            ForEach(open.prefix(6)) { TodoRow(todo: $0, session: session) { reload() } }
            if open.count > 6 {
                Button(L("All tasks")) { allTasks() }.buttonStyle(.link)
            }
        }
    }

    private var workList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("Work")).font(.ui(13, .semibold))
            ForEach(Array(work.enumerated()), id: \.offset) { _, w in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(ChapterSummary.relative(w.date)).font(.ui(11)).foregroundStyle(.secondary).frame(width: 66, alignment: .leading)
                    Text(w.text).font(.ui(12)).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
