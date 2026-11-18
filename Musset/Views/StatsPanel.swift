import SwiftUI

/// The open chapter and the book in numbers: words, sentences, scenes, the day's words, and the book chapter by
/// chapter. Nothing here comes from an AI: its readings and scores are in the AI reader's tab.
struct StatsPanel: View {
    let app: AppState
    let session: BookSession
    /// The open chapter in numbers, counted when it opens and each time typing pauses (not in `body`, at every letter).
    @State private var stats = TextStats("")

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                numbers
                bookStrip
            }
            .padding(14)
        }
        .task(id: session.selectedChapterID) { stats = TextStats(session.text) }
        .background(WhenTypingPauses(session: session, after: .milliseconds(400)) { stats = TextStats(session.text) })
    }

    private var numbers: some View {
        let s = stats
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
            tile(s.words.ui, L("words"))
            tile("\(s.readingMinutes) min", L("reading time"))
            tile(session.bookWordCount.ui, L("in the book"))
            tile(session.wordsToday.formatted(), L("today"))
            tile(String(format: "%.0f", s.meanSentence), L("words per sentence"))
            tile("\(s.longestSentence)", L("longest sentence"))
            tile("\(s.dialoguePercent) %", L("dialogue"))
            tile("\(s.paragraphs)", L("paragraphs"))
            tile("\(session.scenes[session.selectedChapterID ?? ""]?.count ?? 0)", session.words.usual(.scene) ? L("scenes") : session.words.plural(.scene).lowercased())
        }
    }

    /// « 3. La fuite · 2 034 words · Draft »; a piece without a number says its title alone.
    private func barHelp(_ ch: ChapterEntry, words: Int) -> String {
        let mark = session.manifest.pieceMark(of: ch.id)
        let name = (mark.isEmpty ? "" : mark + ". ") + session.manifest.shownTitle(of: ch)
        return name + " · \(words.ui) " + L("words") + " · " + (ch.status ?? .draft).label
    }

    private func tile(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.ui(17, .semibold).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(.ui(11)).foregroundStyle(.secondary).lineLimit(2, reservesSpace: true)
        }
        .padding(.horizontal, 10).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Ink.panel, in: RoundedRectangle(cornerRadius: Radius.control))
    }

    /// Each chapter as a bar: as tall as it is long, in the colour of its status; the open one outlined.
    private var bookStrip: some View {
        let chapters = session.manifest.chapters
        let peak = max(chapters.map { session.chapterCounts[$0.id]?.words ?? 0 }.max() ?? 1, 1)
        return VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(session.words.bookPieceByPiece).font(.ui(11, .medium)).foregroundStyle(.secondary)
                Spacer()
                if let goal = session.manifest.goal, goal > 0 {
                    Text("\(session.bookWordCount.ui) / \(goal.ui)").font(.ui(11).monospacedDigit()).foregroundStyle(.tertiary)
                }
            }
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(Array(chapters.enumerated()), id: \.element.id) { i, ch in
                    let words = session.chapterCounts[ch.id]?.words ?? 0
                    Button { app.showChapter(); session.open(ch.id) } label: {
                        RoundedRectangle(cornerRadius: 2).fill((ch.status ?? .draft).dot)
                            .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(ch.id == session.selectedChapterID ? Color.primary : .clear, lineWidth: 1.5))
                            .frame(height: max(4, 54 * CGFloat(words) / CGFloat(peak)))
                            .frame(maxWidth: .infinity)
                            .frame(height: 54, alignment: .bottom)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(barHelp(ch, words: words))
                }
            }
            .frame(height: 54, alignment: .bottom)
            HStack(spacing: 10) {
                ForEach(ChapterStatus.allCases, id: \.self) { st in
                    let n = chapters.filter { ($0.status ?? .draft) == st }.count
                    if n > 0 {
                        HStack(spacing: 4) { Circle().fill(st.dot).frame(width: 6, height: 6); Text("\(st.label) \(n)").font(.ui(11)).foregroundStyle(.secondary) }
                    }
                }
            }
        }
    }
}

/// The colour of an AI reader, in the charts and the score rows.
enum AIColor {
    static func of(_ agent: String) -> Color {
        agent == "codex" ? Color(red: 0.91, green: 0.64, blue: 0.35) : Ink.accent
    }
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
                                Text(inQuotes(q)).font(.uiMono(11)).italic().foregroundStyle(Ink.accent).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
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
            .background(Ink.panel.opacity(0.6), in: RoundedRectangle(cornerRadius: Radius.control))
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
            Text(inQuotes(quote)).font(.uiMono(11)).italic().foregroundStyle(Ink.accent).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
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
                    .foregroundStyle(threshold.map { reading.total >= $0 } ?? true ? Color.primary : Ink.warning)
                Text("/100").foregroundStyle(.secondary)
                if let threshold { Text(L("threshold \(String(Int(threshold)))")).font(.ui(11)).foregroundStyle(.secondary) }
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
                ScoreRow(score: s, weight: reading.weights[s.criterionId] ?? 0, color: AIColor.of(reading.agent), previous: nil, show: show)
            }
            ForEach(reading.maluses ?? []) { MalusRow(malus: $0, show: show) }
            ForEach(reading.risks, id: \.risk) { Label($0.risk, systemImage: "exclamationmark.triangle").font(.ui(11)).foregroundStyle(Ink.warning) }
        }
        .padding(10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: Radius.control))
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
                        if score.unverified { Image(systemName: "questionmark.circle").font(.ui(10)).foregroundStyle(Ink.warning) }
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
                            Text(inQuotes(q)).font(.uiMono(11)).italic().foregroundStyle(.secondary).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                        }
                        .buttonStyle(.plain)
                        .help(L("Show in the text"))
                    }
                    pin(L("Reservation"), score.reservation)
                    pin(L("Strength"), score.strength)
                    if let s = score.suggestion {
                        (Text(L("To try:") + " ").fontWeight(.medium) + Text(s)).font(.ui(12)).fixedSize(horizontal: false, vertical: true)
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
                    Text(inQuotes(pin.quote)).font(.uiMono(11)).italic().foregroundStyle(.secondary).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
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
                    Text("−" + String(format: "%.1f", malus.points)).font(.ui(11).monospacedDigit()).foregroundStyle(Ink.warning)
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
                                Text(inQuotes(hit.quote)).font(.uiMono(11)).italic().foregroundStyle(.secondary).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
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
    var readingMinutes: Int { max(1, BookNumbers.readingMinutes(words: words)) }

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
