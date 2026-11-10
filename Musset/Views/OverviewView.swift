import SwiftUI

enum OverviewTab: String, CaseIterable, Identifiable {
    case summary, grid, debate, settings
    var id: String { rawValue }
    var label: String {
        switch self {
        case .summary: L("Summary")
        case .grid: L("Plot grid", ctx: "Grille d’intrigue")
        case .debate: L("Debate")
        case .settings: L("Settings")
        }
    }
}

/// The book's own home: its chapters and what comes next, the plot grid, its settings.
struct OverviewView: View {
    @Bindable var app: AppState
    @Bindable var session: BookSession
    let bridge: EditorBridge
    let analyst: PlotAnalyst
    let planner: ScenePlanner
    let proof: AutoProofreader

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                ForEach(OverviewTab.allCases) { tab in
                    Button { app.overviewTab = tab } label: {
                        Text(tab.label).font(.ui(13, app.overviewTab == tab ? .medium : .regular))
                            .foregroundStyle(app.overviewTab == tab ? .primary : .secondary)
                            .padding(.horizontal, 11).frame(height: 28)
                            .background(app.overviewTab == tab ? Ink.selected : .clear, in: RoundedRectangle(cornerRadius: 7))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(.horizontal, 20).frame(height: 44)
            Divider()
            switch app.overviewTab {
            case .summary: BookSummaryView(app: app, session: session, bridge: bridge)
            case .grid: PlotGridView(app: app, session: session, bridge: bridge, analyst: analyst, planner: planner)
            case .debate: DebatePage(session: session)
            case .settings: BookSettingsView(app: app, session: session, proof: proof, startSection: nil, embedded: true)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

/// What a chapter's row says, computed from its files.
struct ChapterSummary: Identifiable {
    let chapter: ChapterEntry
    let index: Int
    let words: Int
    let score: Double?
    let axis: String?
    let todos: Int
    let touched: Date?
    var id: String { chapter.id }
}

extension BookSession {
    func chapterSummaries(todos: [TodoItem]) -> [ChapterSummary] {
        manifest.chapters.enumerated().map { i, ch in
            let last = Reading.load(root, ch.id).last
            let date = try? store.url(for: ch).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            return ChapterSummary(chapter: ch, index: i + 1, words: chapterWords[ch.id] ?? 0, score: last?.total, axis: last?.advice?.axes.first?.title,
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
                events.append((r.date, L("Reading of ") + ch.title + " : \(total)" + (delta == 0 ? "" : " (\(delta > 0 ? "+" : "")\(delta))")))
            }
        }
        for tag in jalons { events.append((tag.date, L("Milestone: ") + tag.title)) }
        let days = Dictionary(grouping: git.commitDates(limit: 400)) { Calendar.current.startOfDay(for: $0) }
        for (day, commits) in days { events.append((day, commits.count > 1 ? L("\(commits.count) saves") : L("1 save"))) }
        return events.sorted { $0.0 > $1.0 }.prefix(limit).map { (date: $0.0, text: $0.1) }
    }
}

struct BookSummaryView: View {
    let app: AppState
    @Bindable var session: BookSession
    let bridge: EditorBridge
    @State private var todos: [TodoItem] = []
    @State private var rows: [ChapterSummary] = []
    @State private var work: [(date: Date, text: String)] = []
    @State private var width: CGFloat = 800

    private var threshold: Double { Bareme.forBook(session.root)?.threshold ?? 80 }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    strip
                    table
                }
                .padding(.horizontal, 28).padding(.vertical, 22)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    nextStep
                    todoList
                    workList
                }
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: 340)
        }
        .task(id: session.manifest.chapters.count) { reload() }
    }

    private func reload() {
        todos = session.collectTodos()
        rows = session.chapterSummaries(todos: todos)
        work = session.workEvents()
    }

    private var header: some View {
        let words = rows.reduce(0) { $0 + $1.words }
        let passing = rows.filter { ($0.score ?? 0) >= threshold }.count
        return VStack(alignment: .leading, spacing: 4) {
            Text(session.title).font(.system(size: 30, design: .serif))
            Text(words.ui + (session.manifest.goal.map { " / \($0.ui)" } ?? "") + " " + L("words")
                 + " · " + L("\(passing) of \(rows.count) chapters at the threshold"))
                .foregroundStyle(.secondary)
        }
    }

    private var strip: some View {
        let peak = max(rows.map(\.words).max() ?? 1, 1)
        return GeometryReader { geo in
            let total = max(rows.reduce(0) { $0 + $1.words }, 1)
            let gaps = CGFloat(max(rows.count - 1, 0)) * 3
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(rows) { r in
                    Button { open(r.chapter) } label: {
                        RoundedRectangle(cornerRadius: 2).fill((r.chapter.status ?? .draft).dot)
                            .frame(width: max(3, (geo.size.width - gaps) * CGFloat(r.words) / CGFloat(total)),
                                   height: max(6, 74 * CGFloat(r.words) / CGFloat(peak)))
                    }
                    .buttonStyle(.plain)
                    .help("\(r.index). \(r.chapter.title) · \(r.words.ui) " + L("words"))
                }
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .frame(height: 74)
    }

    /// Below this width, the table keeps what matters most: title, words, score.
    private var wide: Bool { width > 640 }

    private func columns<A: View, B: View, C: View, D: View, E: View, F: View, G: View>(_ a: A, _ b: B, _ c: C, _ d: D, _ e: E, _ f: F, _ g: G) -> some View {
        HStack(spacing: 10) {
            a.frame(width: 22, alignment: .trailing)
            b.frame(maxWidth: .infinity, alignment: .leading)
            if wide { c.frame(width: 84, alignment: .leading) }
            d.frame(width: 52, alignment: .trailing)
            e.frame(width: 36, alignment: .trailing)
            if wide { f.frame(width: 44, alignment: .trailing) }
            if wide { g.frame(width: 84, alignment: .trailing) }
        }
    }

    private var table: some View {
        VStack(spacing: 0) {
            columns(Text(""), Text(L("Chapter")), Text(L("Status", ctx: "État")), Text(L("Words")), Text(L("Score")), Text(L("To do")), Text(L("Last time")))
                .font(.ui(11)).foregroundStyle(.secondary).lineLimit(1).padding(.bottom, 6)
            Divider()
            ForEach(rows) { r in
                columns(
                    Text("\(r.index)").font(.uiMono(11)).foregroundStyle(.secondary),
                    Button { open(r.chapter) } label: {
                        Text(r.chapter.title).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain),
                    HStack(spacing: 6) { StatusDot(status: r.chapter.status ?? .draft); Text((r.chapter.status ?? .draft).label).font(.ui(12)).foregroundStyle(.secondary).lineLimit(1) },
                    Text(r.words.ui).font(.ui(12).monospacedDigit()).foregroundStyle(.secondary).lineLimit(1),
                    Text(r.score.map { "\(Int($0.rounded()))" } ?? "—").font(.ui(12, .medium).monospacedDigit())
                        .foregroundStyle((r.score ?? threshold) < threshold ? Color.orange : .primary),
                    Text(r.todos == 0 ? "" : "\(r.todos)").font(.ui(12).monospacedDigit()).foregroundStyle(.secondary),
                    Text(r.touched.map(Self.relative) ?? "").font(.ui(12)).foregroundStyle(.secondary).lineLimit(1))
                .frame(height: 32)
                Divider()
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    private static func relative(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.locale = UILang.locale
        f.unitsStyle = .short
        return f.localizedString(for: d, relativeTo: Date())
    }

    private func open(_ ch: ChapterEntry) {
        app.leaveBookPages()
        session.open(ch.id)
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
                if let axis = below.axis { Text(L("Your reader's last axis: ") + axis).foregroundStyle(.secondary) }
                Button(L("Open ") + below.chapter.title) { open(below.chapter) }.buttonStyle(.ink)
            } else if let unread {
                Text(L("\(unread.chapter.title) has not been read yet.")).font(.system(size: 17, design: .serif))
                Button(L("Open ") + unread.chapter.title) { open(unread.chapter) }.buttonStyle(.ink)
            } else {
                Text(L("Every chapter read is at the threshold. Keep writing.")).font(.system(size: 17, design: .serif))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Ink.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder private var todoList: some View {
        let open = todos.filter { !$0.done }
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L("To do")).font(.ui(13, .semibold))
                Spacer()
                Text("\(open.count)").foregroundStyle(.secondary)
            }
            if open.isEmpty { Text(L("Nothing to do yet. ⌃⌥N captures a note or a task.")).font(.ui(12)).foregroundStyle(.secondary) }
            ForEach(open.prefix(6)) { TodoRow(todo: $0, session: session) { reload() } }
            if open.count > 6 {
                Button(L("All tasks")) { app.inspectorTab = .edits; app.showInspector = true }.buttonStyle(.link)
            }
        }
    }

    private var workList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("Work")).font(.ui(13, .semibold))
            ForEach(Array(work.enumerated()), id: \.offset) { _, w in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(Self.relative(w.date)).font(.ui(11)).foregroundStyle(.secondary).frame(width: 66, alignment: .leading)
                    Text(w.text).font(.ui(12)).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
