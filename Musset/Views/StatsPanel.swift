import Charts
import SwiftUI

/// The chapter in numbers: readings over time, reader by reader, each score with its proof, then counts and the whole book.
/// Older scores, from the chat and another grid, stay visible on their own: they are not comparable.
struct StatsPanel: View {
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
    @State private var showBareme = false
    @State private var book: [(chapter: ChapterEntry, fraction: Double?)] = []

    private struct Point { let index: Int; let total: Double; let agent: String }

    static func color(_ agent: String) -> Color {
        agent == "codex" ? Color(red: 0.91, green: 0.64, blue: 0.35) : Ink.accent
    }

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
                        Text(L("No reading yet for this chapter."))
                            .font(.ui(12)).foregroundStyle(.secondary)
                    } else {
                        score
                        chart
                        if showingLegacy { legacyCriteria } else { criteria }
                    }
                    numbers
                    if book.contains(where: { $0.fraction != nil }) { bookStrip }
                    pangramBlock
                }
                .padding(14)
            }
            Divider()
            actions
        }
        .task(id: session.selectedChapterID) { reload() }
        .onChange(of: reader.completed) { _, _ in reload() }
        .sheet(isPresented: $showBareme) { BaremeSheet(session: session) { reload() } }
    }

    private func reload() {
        bareme = Bareme.forBook(session.root)
        if let id = session.selectedChapterID {
            readings = Reading.load(session.root, id)
            history = ScoreHistory.load(session.root, id)
        }
        if let w = who, !agents.contains(w) { who = nil }
        book = session.manifest.chapters.map { ch in
            if let r = Reading.load(session.root, ch.id).last { return (ch, r.total / 100) }
            return (ch, ScoreHistory.load(session.root, ch.id).last.map { $0.score.max > 0 ? $0.score.total / $0.score.max : 0 })
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button(L("Rubric…")) { showBareme = true }.buttonStyle(.plain).font(.ui(12)).foregroundStyle(.secondary)
            if let s = reader.lastError ?? reader.status {
                if reader.running { ProgressView().controlSize(.mini) }
                Text(s).font(.ui(11)).foregroundStyle(reader.lastError != nil ? .orange : .secondary).lineLimit(2)
            }
            Spacer(minLength: 4)
            if reader.running {
                Button(L("Stop")) { reader.stop() }.controlSize(.small)
            } else if AIStatus.shared.isOn {
                PopMenu(sections: [PopSection(items: AIStatus.shared.engines.map { engine in
                    PopItem(title: engine.label) { reader.read(session, engine: engine) }
                })]) {
                    HStack(spacing: 5) { Image(systemName: "eye.slash").font(.ui(10)); Text(L("Read the chapter")).font(.ui(12, .medium)).lineLimit(1) }
                        .fixedSize().padding(.horizontal, 10).frame(height: 26)
                        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Ink.hairline))
                }
                .help(L("A separate reader, outside the chat: the whole book, the chapter, your plan and its last advice; never an earlier score. It scores and advises in one reading."))
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    private var score: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(showingLegacy ? L("Former rubric, in conversation") : (lastReading?.baremeName ?? L("Rubric")))
                    .font(.ui(11)).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                if !readings.isEmpty, !history.isEmpty {
                    Button(legacy ? L("New readings") : L("Former rubric")) { legacy.toggle(); who = nil }
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
                    Text(L("Rubric changed since this reading.")).font(.ui(11)).foregroundStyle(.orange)
                }
                ForEach(r.risks, id: \.risk) { risk in
                    Label(risk.risk, systemImage: "exclamationmark.triangle").font(.ui(11)).foregroundStyle(.orange).padding(.top, 2)
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
                    LineMark(x: .value(L("Reading"), point.index), y: .value(L("Score"), point.total),
                             series: .value(L("Reader"), point.agent))
                        .foregroundStyle(Self.color(point.agent))
                        .lineStyle(StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                }
                ForEach(agents.filter { who == nil || $0 == who }, id: \.self) { agent in
                    if let last = shown.last(where: { $0.agent == agent }) {
                        PointMark(x: .value(L("Reading"), last.index), y: .value(L("Score"), last.total))
                            .foregroundStyle(Self.color(agent)).symbolSize(30)
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
                    Chip(label: agent.capitalized, on: who == agent || agents.count == 1, dot: Self.color(agent)) { who = agents.count == 1 ? nil : agent }
                }
                Spacer()
                Text("\(shown.count) " + (shown.count == 1 ? L("reading", ctx: "lecture") : L("readings")))
                    .font(.ui(11)).foregroundStyle(.tertiary)
            }
        }
    }

    private var criteria: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(L("Last reading")).font(.ui(11, .medium)).foregroundStyle(.secondary)
            if let r = lastReading {
                AdviceView(reading: r, show: { quote in
                    if let range = ReadingCheck.locate(quote, in: bridge.textView?.string ?? session.text) { bridge.scroll(to: range) }
                })
                let order = r.scores.sorted { (r.weights[$0.criterionId] ?? 0) > (r.weights[$1.criterionId] ?? 0) }
                ForEach(order) { s in
                    ScoreRow(score: s, weight: r.weights[s.criterionId] ?? 0, color: Self.color(r.agent), previous: previousScore(s, before: r)) { quote in
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
            Text(L("Last reading, criterion by criterion")).font(.ui(11, .medium)).foregroundStyle(.secondary)
            if let last = lastEntry {
                ForEach(last.score.criteria, id: \.self) { c in
                    HStack(spacing: 8) {
                        Text(c.name).font(.ui(12)).lineLimit(1).frame(width: 124, alignment: .leading)
                        Meter(fraction: c.max > 0 ? c.score / c.max : 0, color: Self.color(last.agent))
                        Text("\(Int(c.score))/\(Int(c.max))").font(.ui(11).monospacedDigit()).foregroundStyle(.secondary).frame(width: 34, alignment: .trailing)
                    }
                    .help(c.comment ?? c.name)
                }
            }
        }
    }

    private var numbers: some View {
        let s = TextStats(session.text)
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
            tile(s.words.ui, L("words"))
            tile("\(s.readingMinutes) min", L("reading", ctx: "de lecture"))
            tile(session.bookWordCount.ui, L("in the book"))
            tile(session.wordsToday.formatted(), L("today"))
            tile(String(format: "%.0f", s.meanSentence), L("words per sentence"))
            tile("\(s.longestSentence)", L("longest sentence"))
            tile("\(s.dialoguePercent) %", L("dialogue"))
            tile("\(s.paragraphs)", L("paragraphs"))
            tile("\(session.scenes[session.selectedChapterID ?? ""]?.count ?? 0)", L("scenes"))
        }
    }

    private func tile(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.ui(17, .semibold).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(.ui(11)).foregroundStyle(.secondary).lineLimit(2, reservesSpace: true)
        }
        .padding(.horizontal, 10).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Ink.panel, in: RoundedRectangle(cornerRadius: 8))
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
                        .help(row.fraction.map { "\(row.chapter.title) : \(Int(($0 * 100).rounded()))/100" } ?? row.chapter.title + L(": not scored"))
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
                Text(e).font(.ui(11)).foregroundStyle(.red)
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

/// What to do next: where to work, in the order that pays the most, and what to leave alone.
struct AdviceView: View {
    let reading: Reading
    let show: (String) -> Void

    var body: some View {
        if !reading.axes.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text(L("To go further")).font(.ui(11, .medium)).foregroundStyle(.secondary)
                ForEach(reading.axes) { axis in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(axis.title).font(.ui(13, .semibold)).fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            if let c = axis.criterionId, let g = reading.gain(c) {
                                Text("≈ +\(g) pts").font(.ui(11).monospacedDigit()).foregroundStyle(.secondary)
                                    .help(L("If this criterion reached 17/20"))
                            }
                        }
                        Text(axis.why).font(.ui(12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Text(axis.direction).font(.ui(12, .medium)).fixedSize(horizontal: false, vertical: true)
                        ForEach(Array((axis.steps ?? []).enumerated()), id: \.offset) { i, step in
                            stepRow(step, number: i + 1)
                        }
                        if (axis.steps ?? []).isEmpty, let q = axis.quote {
                            Button { show(q) } label: {
                                Text("« \(q) »").font(.uiMono(11)).italic().foregroundStyle(Ink.accent).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                            }
                            .buttonStyle(.plain).help(L("Show in the text"))
                        }
                    }
                }
                if let keep = reading.advice?.keep, !keep.isEmpty {
                    Label(keep, systemImage: "checkmark.seal").font(.ui(12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(10)
            .background(Ink.panel.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    /// One gesture: what to do, on which passage, and where to, each passage a click away in the text.
    private func stepRow(_ step: Reading.Axis.Step, number: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(number).").font(.ui(11).monospacedDigit()).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                (Text(step.action + " : ").fontWeight(.semibold) + Text(step.detail)).font(.ui(12)).fixedSize(horizontal: false, vertical: true)
                passage(step.quote)
                if let target = step.target {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Image(systemName: "arrow.turn.down.right").font(.ui(10)).foregroundStyle(.tertiary)
                        passage(target)
                    }
                }
            }
        }
        .padding(.top, 2)
    }

    private func passage(_ quote: String) -> some View {
        Button { show(quote) } label: {
            Text("« \(quote) »").font(.uiMono(11)).italic().foregroundStyle(Ink.accent).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
        }
        .buttonStyle(.plain).help(L("Show in the text"))
    }
}

/// A reading in the chat: the total, measured against the threshold, and each criterion with its proof.
struct ReadingCard: View {
    let reading: Reading
    let threshold: Double?
    let previous: Double?
    let show: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(Int(reading.total.rounded()))").font(.title2.monospacedDigit().bold())
                    .foregroundStyle(threshold.map { reading.total >= $0 } ?? true ? Color.primary : Color.orange)
                Text("/100").foregroundStyle(.secondary)
                if let threshold { Text(L("threshold") + " \(Int(threshold))").font(.ui(11)).foregroundStyle(.secondary) }
                if let previous, Int(previous.rounded()) != Int(reading.total.rounded()) {
                    let d = Int(reading.total.rounded()) - Int(previous.rounded())
                    Text(d > 0 ? "+\(d)" : "\(d)").font(.ui(11, .semibold)).foregroundStyle(.secondary)
                        .help(L("Since this AI's previous reading"))
                }
                Spacer()
            }
            AdviceView(reading: reading, show: show)
            Text(L("Criterion by criterion: click for the proof")).font(.ui(11, .medium)).foregroundStyle(.secondary).padding(.top, 4)
            ForEach(reading.scores.sorted { (reading.weights[$0.criterionId] ?? 0) > (reading.weights[$1.criterionId] ?? 0) }) { s in
                ScoreRow(score: s, weight: reading.weights[s.criterionId] ?? 0, color: StatsPanel.color(reading.agent), previous: nil, show: show)
            }
            ForEach(reading.maluses ?? []) { MalusRow(malus: $0, show: show) }
            ForEach(reading.risks, id: \.risk) { Label($0.risk, systemImage: "exclamationmark.triangle").font(.ui(11)).foregroundStyle(.orange) }
        }
        .padding(10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// A criterion of a reading: the gauge, and on click why it scored this, with quotes that lead to the passage.
struct ScoreRow: View {
    let score: Reading.Score
    let weight: Int
    let color: Color
    let previous: Int?
    let show: (String) -> Void
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { withAnimation(.easeOut(duration: 0.12)) { open.toggle() } } label: {
                HStack(spacing: 8) {
                    HStack(spacing: 4) {
                        Image(systemName: open ? "chevron.down" : "chevron.right").font(.ui(8)).foregroundStyle(.tertiary)
                        if score.unverified { Image(systemName: "questionmark.circle").font(.ui(10)).foregroundStyle(.orange) }
                        Text(score.label).font(.ui(12)).lineLimit(1)
                    }
                    .frame(width: 124, alignment: .leading)
                    Meter(fraction: score.unverified ? 0 : Double(score.score) / 20, color: color)
                    if let previous, !score.unverified, previous != score.score {
                        Text(score.score > previous ? "▲" : "▼").font(.ui(9)).foregroundStyle(.tertiary)
                    }
                    Text(score.unverified ? "—/\(weight)" : Self.points(score.score, weight)).font(.ui(11).monospacedDigit()).foregroundStyle(.secondary).frame(width: 46, alignment: .trailing)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(score.unverified ? L("No proof found in the text: out of the total") : "\(score.score)/20")
            if open {
                VStack(alignment: .leading, spacing: 5) {
                    if !score.justification.isEmpty { Text(score.justification).font(.ui(12)).fixedSize(horizontal: false, vertical: true) }
                    ForEach(score.quotes, id: \.self) { q in
                        Button { show(q) } label: {
                            Text("« \(q) »").font(.uiMono(11)).italic().foregroundStyle(.secondary).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                        }
                        .buttonStyle(.plain)
                        .help(L("Show in the text"))
                    }
                    pin(L("Reservation"), score.reservation)
                    pin(L("Strength"), score.strength)
                    if let s = score.suggestion {
                        (Text(L("To try: ")).fontWeight(.medium) + Text(s)).font(.ui(12)).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.leading, 8).padding(.bottom, 4)
            }
        }
    }

    @ViewBuilder private func pin(_ title: String, _ pin: Reading.Pin?) -> some View {
        if let pin {
            VStack(alignment: .leading, spacing: 2) {
                (Text(title + " : ").fontWeight(.medium) + Text(pin.note)).font(.ui(12)).fixedSize(horizontal: false, vertical: true)
                Button { show(pin.quote) } label: {
                    Text("« \(pin.quote) »").font(.uiMono(11)).italic().foregroundStyle(.secondary).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                }
                .buttonStyle(.plain).help(L("Show in the text"))
            }
        }
    }

    private static func points(_ score: Int, _ weight: Int) -> String {
        let p = Scoring.points(score: score, weight: weight)
        return (p == p.rounded() ? "\(Int(p))" : String(format: "%.1f", p)) + "/\(weight)"
    }
}

/// A family of faults: the points it takes off, and on click each fault with the passage it comes from.
struct MalusRow: View {
    let malus: Reading.Malus
    let show: (String) -> Void
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { withAnimation(.easeOut(duration: 0.12)) { open.toggle() } } label: {
                HStack(spacing: 4) {
                    Image(systemName: open ? "chevron.down" : "chevron.right").font(.ui(8)).foregroundStyle(.tertiary)
                    Text(malus.label).font(.ui(12)).lineLimit(1)
                    Spacer(minLength: 8)
                    Text("−" + String(format: "%.1f", malus.points)).font(.ui(11).monospacedDigit()).foregroundStyle(.orange)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("Taken off the total"))
            if open {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(malus.hits, id: \.self) { hit in
                        VStack(alignment: .leading, spacing: 2) {
                            if !hit.why.isEmpty { Text(hit.why).font(.ui(12)).fixedSize(horizontal: false, vertical: true) }
                            Button { show(hit.quote) } label: {
                                Text("« \(hit.quote) »").font(.uiMono(11)).italic().foregroundStyle(.secondary).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                            }
                            .buttonStyle(.plain).help(L("Show in the text"))
                        }
                    }
                }
                .padding(.leading, 8).padding(.bottom, 4)
            }
        }
    }
}

/// A thin horizontal gauge.
struct Meter: View {
    let fraction: Double
    let color: Color
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.2))
                Capsule().fill(color).frame(width: geo.size.width * Swift.min(1, Swift.max(0, fraction)))
            }
        }
        .frame(height: 6)
    }
}

struct TextStats {
    var words = 0
    var paragraphs = 0
    var meanSentence = 0.0
    var longestSentence = 0
    var dialoguePercent = 0
    var readingMinutes: Int { max(1, Int((Double(words) / 230).rounded())) }

    init(_ raw: String) {
        let text = BookStore.stripHTMLComments(raw)
        words = BookStore.wordCount(text)
        let paras = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") && !$0.allSatisfy({ "*-_ ".contains($0) }) }
        paragraphs = paras.count
        var lengths: [Int] = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .bySentences) { s, _, _, _ in
            guard let s else { return }
            let n = s.split(whereSeparator: { $0.isWhitespace }).count
            if n > 0 { lengths.append(n) }
        }
        meanSentence = lengths.isEmpty ? 0 : Double(lengths.reduce(0, +)) / Double(lengths.count)
        longestSentence = lengths.max() ?? 0
        // Dialogue: paragraphs opening with a dash or a guillemet / quote.
        let dialogueWords = paras.filter { $0.hasPrefix("—") || $0.hasPrefix("–") || $0.hasPrefix("«") || $0.hasPrefix("“") || $0.hasPrefix("\"") }
            .reduce(0) { $0 + $1.split(whereSeparator: { $0.isWhitespace }).count }
        dialoguePercent = words == 0 ? 0 : Int((Double(dialogueWords) / Double(words) * 100).rounded())
    }
}
