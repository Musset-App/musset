import Charts
import SwiftUI

/// The AI reader's home, one tab of the inspector: the conversation, the AI readings with their scores, the rubric
/// they are scored against, and the debate as its wide view (a tab among the panes).
struct AIHome: View {
    let app: AppState
    let chat: ChatModel
    let session: BookSession
    let bridge: EditorBridge
    let pangram: PangramModel
    @AppStorage("aiHomePage") private var page = Page.chat.rawValue
    @AppStorage("helpersSeen") private var helpersSeen = false

    enum Page: String { case chat, readings }

    /// Whether the inspector shows this tab: an AI engine is on; or none is set up yet and Musset has not said
    /// what one brings (the tab then says it, once). With « AI: off » in Settings it is hidden, like every AI feature.
    @MainActor static var shown: Bool {
        AIStatus.shared.isOn || (AIStatus.shared.enabled && !UserDefaults.standard.bool(forKey: "helpersSeen"))
    }

    var body: some View {
        if AIStatus.shared.isOn {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Segmented(options: [(Page.chat.rawValue, L("Chat")), (Page.readings.rawValue, L("AI readings"))], selection: $page)
                    Button { app.showRubric = true } label: { Text(L("Rubric…")).toolbarButton() }
                        .buttonStyle(.plain)
                        .help(L("What the AI reader scores a chapter against: the promise, the criteria and their weights"))
                    Button { app.open(.debate) } label: {
                        HStack(spacing: 5) { Text(L("Debate")); Image(systemName: "arrow.up.left.and.arrow.down.right").font(.ui(9)) }.toolbarButton()
                    }
                    .buttonStyle(.plain)
                    .help(L("Several imagined readers argue about the book, in a tab of its own"))
                }
                .font(.ui(12))
                .padding(.horizontal, 14).padding(.vertical, 10)
                Divider()
                if page == Page.readings.rawValue {
                    ReadingsPanel(app: app, session: session, bridge: bridge, pangram: pangram, reader: chat.reader)
                } else {
                    ChatPanel(chat: chat, session: session, bridge: bridge)
                }
            }
        } else {
            // No AI engine yet: what one brings, said here rather than in the title bar, until answered.
            VStack(alignment: .leading, spacing: 10) {
                Text(L("An AI reader?")).font(.system(size: 22, design: .serif))
                Text(L("It reads each chapter in its place in the book, scores it, says what to work on, and annotates the margin."))
                    .font(.ui(13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text(L("Musset works without one. It never rewrites your text."))
                    .font(.ui(12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button(L("Choose an AI Reader…")) { app.showHelpers = true }.buttonStyle(.ink)
                    Button(L("Not now")) { helpersSeen = true; app.inspectorTab = .edits }.buttonStyle(.inkSecondary)
                }
                .padding(.top, 6)
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

/// The AI readings of the open chapter: the score over time, AI reader by AI reader, each criterion with its proof,
/// the book chapter by chapter, and the AI detection. Older scores, from the chat and another rubric, stay visible
/// on their own: they are not comparable.
struct ReadingsPanel: View {
    let app: AppState
    let session: BookSession
    let bridge: EditorBridge
    let pangram: PangramModel
    let reader: ChapterReader
    /// The AI shown; nil for all of them.
    @State private var who: String?
    @State private var readings: [Reading] = []
    @State private var history: [ScoreHistory.Entry] = []
    @State private var legacy = false
    @State private var bareme: Bareme?
    @State private var book: [(chapter: ChapterEntry, fraction: Double?)] = []

    private struct Point { let index: Int; let total: Double; let agent: String }

    private var showingLegacy: Bool { legacy || (readings.isEmpty && !history.isEmpty) }
    private var all: [Point] {
        showingLegacy ? history.enumerated().map { Point(index: $0.offset, total: $0.element.score.total, agent: $0.element.agent) }
                      : readings.enumerated().map { Point(index: $0.offset, total: $0.element.total, agent: $0.element.agent) }
    }
    private var agents: [String] { all.reduce(into: [String]()) { if !$0.contains($1.agent) { $0.append($1.agent) } } }
    private var shown: [Point] { all.filter { who == nil || $0.agent == who } }
    private var lastReading: Reading? { readings.last { who == nil || $0.agent == who } }
    private var lastEntry: ScoreHistory.Entry? { history.last { who == nil || $0.agent == who } }
    private var threshold: Double? { showingLegacy ? lastEntry?.score.threshold : bareme?.threshold }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if all.isEmpty {
                        EmptyNote(L("No AI reading yet for this chapter."))
                    } else {
                        score
                        chart
                        if showingLegacy { legacyCriteria } else { criteria }
                    }
                    if book.contains(where: { $0.fraction != nil }) { bookStrip }
                    pangramBlock
                }
                .padding(14)
            }
            Divider()
            actions
        }
        // Going to another chapter reads that chapter's scores; the whole book's are read again only when one changed.
        .task(id: session.selectedChapterID) { reload(book: book.map(\.chapter.id) != session.manifest.chapters.map(\.id)) }
        .onChange(of: reader.completed) { _, _ in reload() }
        // The rubric saved: the threshold and the « changed since » line follow.
        .onChange(of: app.showRubric) { _, open in if !open { reload(book: false) } }
    }

    private func reload(book wholeBook: Bool = true) {
        bareme = Bareme.forBook(session.root)
        if let id = session.selectedChapterID {
            readings = Reading.load(session.root, id)
            history = ScoreHistory.load(session.root, id)
        }
        if let w = who, !agents.contains(w) { who = nil }
        guard wholeBook else { return }
        book = session.manifest.chapters.map { ch in
            if let r = Reading.load(session.root, ch.id).last { return (ch, r.total / 100) }
            return (ch, ScoreHistory.load(session.root, ch.id).last.map { $0.score.max > 0 ? $0.score.total / $0.score.max : 0 })
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            if let s = reader.lastError ?? reader.status {
                if reader.running { ProgressView().controlSize(.mini) }
                Text(s).font(.ui(11)).foregroundStyle(reader.lastError != nil ? Ink.warning : .secondary).lineLimit(2)
            }
            Spacer(minLength: 4)
            if reader.running {
                Button(L("Stop")) { reader.stop() }.controlSize(.small)
            } else if AIStatus.shared.isOn {
                PopMenu(sections: [PopSection(items: AIStatus.shared.engines.map { engine in
                    PopItem(title: engine.label) { reader.read(session, engine: engine) }
                })]) {
                    HStack(spacing: 5) { Image(systemName: "eye.slash").font(.ui(10)); Text(L("Read the chapter")).font(.ui(12, .medium)).lineLimit(1) }
                        .fixedSize().toolbarButton()
                }
                .help(L("A separate AI reader, outside the chat: the whole book, the chapter, your plan and its last advice; never an earlier score. It scores and advises in one reading."))
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    private var score: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(showingLegacy ? L("Former rubric, in conversation") : (lastReading?.baremeName ?? L("Rubric…").titled))
                    .font(.ui(11)).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                if !readings.isEmpty, !history.isEmpty {
                    Button(legacy ? L("New AI readings") : L("Former rubric")) { legacy.toggle(); who = nil }
                        .buttonStyle(.plain).font(.ui(11)).foregroundStyle(Ink.accent)
                }
            }
            if let last = shown.last {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(Int(last.total.rounded()))").font(.ui(44, .semibold))
                    Text("/100").font(.ui(16)).foregroundStyle(.tertiary)
                    if shown.count > 1, let previous = shown.dropLast().last(where: { $0.agent == last.agent }) {
                        let d = Int(last.total.rounded()) - Int(previous.total.rounded())
                        if d != 0 { Text(d > 0 ? "▲ +\(d)" : "▼ \(d)").font(.ui(12).monospacedDigit()).foregroundStyle(.secondary).padding(.leading, 6) }
                    }
                }
            }
            if !showingLegacy, let r = lastReading {
                if r.baremeVersion != bareme?.version {
                    Text(L("Rubric changed since this AI reading.")).font(.ui(11)).foregroundStyle(Ink.warning)
                }
                ForEach(r.risks, id: \.risk) { risk in
                    Label(risk.risk, systemImage: "exclamationmark.triangle").font(.ui(11)).foregroundStyle(Ink.warning).padding(.top, 2)
                }
            }
        }
    }

    private var chart: some View {
        let values = shown.map(\.total) + (threshold.map { [$0] } ?? [])
        let floor = Swift.max(0, ((values.min() ?? 0) / 10).rounded(.down) * 10 - 10)
        return VStack(alignment: .leading, spacing: 8) {
            Chart {
                ForEach(shown, id: \.index) { point in
                    LineMark(x: .value(L("AI reading"), point.index), y: .value(L("Score"), point.total),
                             series: .value(L("AI reader"), point.agent))
                        .foregroundStyle(AIColor.of(point.agent))
                        .lineStyle(StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                }
                ForEach(agents.filter { who == nil || $0 == who }, id: \.self) { agent in
                    if let last = shown.last(where: { $0.agent == agent }) {
                        PointMark(x: .value(L("AI reading"), last.index), y: .value(L("Score"), last.total))
                            .foregroundStyle(AIColor.of(agent)).symbolSize(30)
                    }
                }
                if let threshold {
                    RuleMark(y: .value(L("Threshold"), threshold))
                        .foregroundStyle(Color.secondary.opacity(0.6))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
            }
            .chartYScale(domain: floor...100)
            .chartXAxis(.hidden)
            .chartYAxis { AxisMarks(position: .leading, values: .stride(by: 10)) { _ in
                AxisGridLine().foregroundStyle(Ink.hairline)
                AxisValueLabel().font(.ui(10))
            } }
            .frame(height: 150)
            .accessibilityLabel(L("Rubric history"))
            HStack(spacing: 6) {
                if agents.count > 1 { Chip(label: L("All", ctx: "Toutes"), on: who == nil) { who = nil } }
                ForEach(agents, id: \.self) { agent in
                    Chip(label: agent.capitalized, on: who == agent || agents.count == 1, dot: AIColor.of(agent)) { who = agents.count == 1 ? nil : agent }
                }
                Spacer()
                Text(L("\(shown.count) AI readings"))
                    .font(.ui(11)).foregroundStyle(.tertiary)
            }
        }
    }

    private var criteria: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(L("Last AI reading")).font(.ui(11, .medium)).foregroundStyle(.secondary)
            if let r = lastReading {
                AdviceView(reading: r, show: { quote in
                    if let range = ReadingCheck.locate(quote, in: bridge.textView?.string ?? session.text) { bridge.scroll(to: range) }
                })
                let order = r.scores.sorted { (r.weights[$0.criterionId] ?? 0) > (r.weights[$1.criterionId] ?? 0) }
                ForEach(order) { s in
                    ScoreRow(score: s, weight: r.weights[s.criterionId] ?? 0, color: AIColor.of(r.agent), previous: previousScore(s, before: r)) { quote in
                        if let range = ReadingCheck.locate(quote, in: bridge.textView?.string ?? session.text) { bridge.scroll(to: range) }
                    }
                }
                ForEach(r.maluses ?? []) { m in
                    MalusRow(malus: m) { quote in
                        if let range = ReadingCheck.locate(quote, in: bridge.textView?.string ?? session.text) { bridge.scroll(to: range) }
                    }
                }
            }
        }
    }

    /// The same criterion in the same AI's previous reading under this grid.
    private func previousScore(_ s: Reading.Score, before r: Reading) -> Int? {
        readings.last { $0.id != r.id && $0.date < r.date && $0.agent == r.agent && $0.baremeVersion == r.baremeVersion }?
            .scores.first { $0.criterionId == s.criterionId && !$0.unverified }?.score
    }

    private var legacyCriteria: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(L("Last AI reading, criterion by criterion")).font(.ui(11, .medium)).foregroundStyle(.secondary)
            if let last = lastEntry {
                ForEach(last.score.criteria, id: \.self) { c in
                    HStack(spacing: 8) {
                        Text(c.name).font(.ui(12)).lineLimit(1).frame(width: 124, alignment: .leading)
                        Meter(fraction: c.max > 0 ? c.score / c.max : 0, color: AIColor.of(last.agent))
                        Text("\(Int(c.score))/\(Int(c.max))").font(.ui(11).monospacedDigit()).foregroundStyle(.secondary).frame(width: 34, alignment: .trailing)
                    }
                    .help(c.comment ?? c.name)
                }
            }
        }
    }

    private var bookStrip: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(L("The book, chapter by chapter")).font(.ui(11, .medium)).foregroundStyle(.secondary)
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(book, id: \.chapter.id) { row in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(row.chapter.id == session.selectedChapterID ? Ink.accent : Color.secondary.opacity(row.fraction == nil ? 0.15 : 0.45))
                        .frame(height: row.fraction.map { Swift.max(6, 54 * ($0 - 0.5) * 2) } ?? 3)
                        .frame(maxWidth: .infinity)
                        .help(row.fraction.map { "\(row.chapter.title) : \(Int(($0 * 100).rounded()))/100" } ?? L("\(row.chapter.title): not scored"))
                }
            }
            .frame(height: 54, alignment: .bottom)
        }
    }

    // MARK: Pangram

    private var pangramBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L("AI detection")).font(.subheadline.bold())
                Spacer()
                Button { Task { await pangram.run(session: session, bridge: bridge) } } label: {
                    Label(bridge.selectedText.isEmpty ? L("Check chapter") : L("Check selection"), systemImage: "waveform.path.ecg")
                }
                .controlSize(.small)
                .disabled(pangram.running)
            }
            if pangram.running {
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text(L("Pangram is reading…")).font(.ui(11)) }
            } else if let e = pangram.error {
                Text(e).font(.ui(11)).foregroundStyle(Ink.error)
            } else if let r = pangram.result {
                Text(r.headline ?? r.prediction_short ?? L("Done", ctx: "Terminé")).font(.callout.weight(.semibold))
                Text(L("AI \(pct(r.fraction_ai)) · assisted \(pct(r.fraction_ai_assisted)) · human \(pct(r.fraction_human))") + " · " + L("\(r.flaggedWindows.count) passages highlighted in orange"))
                    .font(.ui(11)).foregroundStyle(.secondary)
                Button(L("Clear")) { pangram.clear(bridge) }.buttonStyle(.link).font(.ui(11))
            }
        }
    }


    private func pct(_ v: Double?) -> String { v.map { "\(Int(($0 * 100).rounded()))%" } ?? "–" }
}

