import SwiftUI

/// The book in numbers, the band Overview's first page opens on: what it weighs and how far it is from its goal,
/// every chapter as a bar, and the days. `Next` is what « What comes next » opens.
struct BookNumbersHeader<Next: View>: View {
    let session: BookSession
    /// The chapter the author is in, or last wrote in: its bar is ringed.
    let current: String?
    /// The page's width: the three columns stand side by side when it has the room, the days go under when not.
    let width: CGFloat
    /// Tasks still open.
    let todos: Int
    let days: BookNumbers.Days?
    /// The strand the board below is read along, if one is.
    var reading: BookStructure.Strand? = nil
    @Binding var showsNext: Bool
    let pick: (String) -> Void
    let enter: (String) -> Void
    let zoom: (String) -> Void
    /// A strand picked in the legend, to read alone; nil for the whole book again.
    var read: (String?) -> Void = { _ in }
    @ViewBuilder let next: () -> Next
    /// The bars in their strands' colours rather than their statuses': the author's choice, kept.
    @AppStorage(BookBars.byStrandKey) private var byStrand = false

    private var margin: CGFloat { BookOverviewPage.margin }

    var body: some View {
        let inner = width - 2 * margin
        Group {
            if inner >= 860 {
                HStack(alignment: .top, spacing: 0) {
                    weight.frame(width: 264, alignment: .leading).frame(maxHeight: .infinity, alignment: .top)
                    chapters.padding(.leading, 44).frame(maxHeight: .infinity, alignment: .top)
                    Rectangle().fill(Ink.hairline).frame(width: 1).padding(.leading, 32)
                    daysColumn.padding(.leading, 28).frame(width: 214, alignment: .leading).frame(maxHeight: .infinity, alignment: .top)
                }
                .fixedSize(horizontal: false, vertical: true)
            } else if inner >= 540 {
                VStack(alignment: .leading, spacing: 22) {
                    HStack(alignment: .top, spacing: 36) {
                        weight.frame(width: 216, alignment: .leading).frame(maxHeight: .infinity, alignment: .top)
                        chapters.frame(maxHeight: .infinity, alignment: .top)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    Rectangle().fill(Ink.hairline).frame(height: 1)
                    daysRow
                }
            } else {
                VStack(alignment: .leading, spacing: 22) {
                    weight
                    chapters
                    Rectangle().fill(Ink.hairline).frame(height: 1)
                    VStack(alignment: .leading, spacing: 16) {
                        today
                        if let days { week(days) }
                        nextButton
                    }
                }
            }
        }
        .padding(.horizontal, margin).padding(.top, 30).padding(.bottom, 28)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: What the book weighs

    private var weight: some View {
        let counts = session.bookCounts
        let size = counts.size.ui
        // The goal is in words: as everywhere else, it shows beside a count in words only.
        let goal = CountUnit.current == .words ? BookNumbers.goal(words: counts.words, goal: session.manifest.goal) : nil
        return VStack(alignment: .leading, spacing: 0) {
            Text(session.title).font(.system(size: 40, design: .serif)).lineLimit(2).minimumScaleFactor(0.6)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                CountButton(text: size).font(.ui(24, .semibold).monospacedDigit())
                // The unit's noun, as the count's own label writes it for this number.
                Text(counts.label.replacingOccurrences(of: size, with: "").trimmingCharacters(in: .whitespaces))
                    .font(.ui(15)).foregroundStyle(.secondary)
            }
            .lineLimit(1).minimumScaleFactor(0.7)
            .padding(.top, 16)
            if let goal, let target = session.manifest.goal {
                let line = BookNumbers.goalLine(goal, goal: target)
                Gauge(fraction: goal.fraction, color: Ink.accent, height: 6)
                    .padding(.top, 14)
                    .accessibilityLabel(L("Progress towards the goal")).accessibilityValue(line.percent)
                (Text(line.percent).font(.ui(12, .medium)).foregroundStyle(.primary) + Text(" " + line.rest))
                    .font(.ui(12).monospacedDigit()).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 9)
            }
            Spacer(minLength: 22)
            HStack(alignment: .top, spacing: 18) {
                figure("≈ " + BookNumbers.pages(words: counts.words).ui, L("estimated pages"))
                figure("≈ " + BookNumbers.reading(minutes: BookNumbers.readingMinutes(words: counts.words)), L("reading time"))
            }
        }
    }

    private func figure(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.ui(17, .semibold).monospacedDigit())
            Text(label).font(.ui(12)).foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    // MARK: Chapter by chapter

    private var chapters: some View {
        let m = session.manifest
        let groups = BookNumbers.groups(m, counts: session.chapterCounts, scenes: session.scenes.mapValues(\.count))
        let heading = SectionLabel(session.words.bookPieceByPiece, tracking: 1.4).lineLimit(1).fixedSize()
        let legend = HStack(spacing: 16) {
            ForEach(BookNumbers.statuses(m.chapters), id: \.status) { st, n in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2).fill(st.dot).frame(width: 9, height: 9)
                    Text(st.label).font(.ui(12))
                    Text("\(n)").font(.ui(12).monospacedDigit()).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .lineLimit(1).fixedSize()
        // A book without strands has one way to colour its bars, and nothing to choose.
        let strands = Dictionary(m.strands.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let coloured = byStrand && !strands.isEmpty
        let colouring = Segmented(options: [(false, L("Status")), (true, L("Strands"))], selection: $byStrand).frame(width: 132).fixedSize()
        return VStack(alignment: .leading, spacing: 0) {
            if strands.isEmpty {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 18) { heading; Spacer(minLength: 0); legend }
                    VStack(alignment: .leading, spacing: 8) { heading; legend }
                    VStack(alignment: .leading, spacing: 8) { heading }
                }
            } else if !coloured {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: 18) { heading; Spacer(minLength: 0); legend; colouring }
                    VStack(alignment: .leading, spacing: 8) { HStack(spacing: 18) { heading; Spacer(minLength: 0); colouring }; legend }
                    VStack(alignment: .leading, spacing: 8) { heading; colouring; legend }
                    VStack(alignment: .leading, spacing: 8) { heading; colouring }
                }
            } else {
                // The strands' legend is where one is picked to be read alone: it wraps rather than give way.
                VStack(alignment: .leading, spacing: 8) {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .center, spacing: 18) { heading; Spacer(minLength: 0); colouring }
                        VStack(alignment: .leading, spacing: 8) { heading; colouring }
                    }
                    strandLegend(BookNumbers.threads(m, counts: session.chapterCounts))
                }
            }
            Spacer(minLength: 16)
            BookBars(groups: groups, current: current, words: session.words, strands: coloured ? strands : nil, only: reading?.id,
                     pick: pick, enter: enter, zoom: zoom)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Each strand with what follows it: its mark, its name, how many chapters and how long. A click reads it alone
    /// on the board below; a second one, or « Whole book », brings the book back.
    private func strandLegend(_ threads: [BookNumbers.Thread]) -> some View {
        FlowLayout(spacing: 4) {
            ForEach(threads) { thread in
                let on = thread.strand != nil && thread.strand?.id == reading?.id
                let facts = session.words.count(thread.chapters.count, .piece) + " · " + thread.counts.label
                let chip = HStack(spacing: 6) {
                    StrandMark(colour: thread.strand?.colour, size: 9)
                    Text(thread.strand?.shownName ?? L("No strand")).font(.ui(12, on ? .medium : .regular))
                    Text(facts).font(.ui(12).monospacedDigit()).foregroundStyle(.secondary)
                }
                .lineLimit(1)
                .padding(.horizontal, 8).frame(height: 24)
                .background(on ? Ink.selected : .clear, in: RoundedRectangle(cornerRadius: Radius.row))
                .opacity(reading == nil || on ? 1 : 0.55)
                if let strand = thread.strand {
                    Button { read(strand.id) } label: { chip.contentShape(Rectangle()) }
                        .buttonStyle(.plain)
                        .help(on ? L("Show the whole book again") : L("Read this strand alone"))
                        .accessibilityLabel(strand.shownName + ", " + facts)
                        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
                } else {
                    chip.accessibilityElement(children: .combine)
                }
            }
            if reading != nil {
                Button { read(nil) } label: {
                    Text(L("Whole book")).font(.ui(12)).foregroundStyle(Ink.accent).padding(.horizontal, 8).frame(height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        // The first chip's text stands under the heading, not its padding.
        .padding(.leading, -8)
    }

    // MARK: The days

    private var today: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(L("today"), tracking: 1.4)
            Text(CountUnit.words.label(session.wordsToday)).font(.ui(20, .semibold).monospacedDigit()).lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }

    /// The week as the book's sittings tell it: its days written, each a dot, and the run of days up to today.
    private func week(_ days: BookNumbers.Days) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(L("This week"), tracking: 1.4)
            Text(L("\(days.written) days written")).font(.ui(15, .semibold).monospacedDigit()).lineLimit(1)
            HStack(spacing: 10) {
                HStack(spacing: 4) {
                    ForEach(0..<7, id: \.self) { i in
                        Circle().fill(days.week[i] ? Ink.positive : Color.primary.opacity(i > days.today ? 0.07 : 0.16))
                            .frame(width: 7, height: 7)
                    }
                }
                .accessibilityHidden(true)
                if days.streak > 1 { Text(L("\(days.streak) days in a row")).font(.ui(12).monospacedDigit()).foregroundStyle(.secondary).lineLimit(1) }
            }
            .padding(.top, 1)
        }
        .accessibilityElement(children: .combine)
    }

    private var nextButton: some View {
        Button { showsNext = true } label: {
            HStack(spacing: 6) {
                Text(L("What comes next")).font(.ui(12)).lineLimit(1)
                Spacer(minLength: 8)
                if todos > 0 { Text(L("\(todos) to do")).font(.ui(12).monospacedDigit()).foregroundStyle(.secondary).lineLimit(1) }
                Image(systemName: "chevron.right").font(.ui(9, .semibold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).frame(height: 34)
            .overlay(RoundedRectangle(cornerRadius: Radius.control).strokeBorder(Ink.hairline))
            .contentShape(RoundedRectangle(cornerRadius: Radius.control))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showsNext, arrowEdge: .bottom) { next() }
    }

    private var daysColumn: some View {
        VStack(alignment: .leading, spacing: 18) {
            today
            if let days { week(days) }
            Spacer(minLength: 4)
            nextButton
        }
    }

    private var daysRow: some View {
        HStack(alignment: .top, spacing: 36) {
            today.fixedSize()
            if let days { week(days).fixedSize() }
            Spacer(minLength: 0)
            nextButton.frame(maxWidth: 236).frame(maxHeight: .infinity, alignment: .bottom)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// A thin gauge on the page's own ground: the goal's.
private struct Gauge: View {
    let fraction: Double
    let color: Color
    let height: CGFloat

    var body: some View {
        Capsule().fill(Color.primary.opacity(0.1))
            .frame(height: height)
            .overlay(alignment: .leading) {
                GeometryReader { geo in
                    Capsule().fill(color).frame(width: max(geo.size.width * min(max(fraction, 0), 1), fraction > 0 ? height : 0))
                }
            }
            .clipShape(Capsule())
    }
}

/// Every chapter as a bar, in the book's order: as tall as it is long, in its status's colour, parts a little apart
/// with their name under them. A click shows the chapter on the board below, a second one goes into it; a part's
/// name shows that part. Plain shapes laid out by hand (`BookNumbers.layout`): sixty of them cost nothing.
struct BookBars: View {
    let groups: [BookNumbers.Group]
    let current: String?
    let words: BookWords
    /// The book's strands by id when the bars take their strands' colours; nil when they take their statuses'.
    var strands: [String: BookStructure.Strand]? = nil
    /// The strand read alone on the board: the other chapters' bars are dimmed.
    var only: String? = nil
    let pick: (String) -> Void
    let enter: (String) -> Void
    let zoom: (String) -> Void
    @State private var width: CGFloat = 0
    @State private var hovered: String?
    @Environment(\.displayScale) private var scale

    /// The row's height, and the tallest bar in it: the ring of the current chapter has room above.
    static let room: CGFloat = 132
    static let tallest: CGFloat = 124
    static let byStrandKey = "overviewBarsByStrand"

    /// The strand a bar is drawn in, when bars are drawn in their strands' colours.
    private func strand(_ bar: BookNumbers.Bar) -> BookStructure.Strand? { bar.strand.flatMap { strands?[$0] } }

    var body: some View {
        let unit = CountUnit.current
        let layout = BookNumbers.layout(groups.map { $0.bars.map { $0.counts[unit] } }, width: width, room: Self.tallest, scale: scale)
        let named = groups.contains { $0.part != nil }
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                ForEach(Array(groups.enumerated()), id: \.element.id) { g, group in
                    if layout.groups.indices.contains(g) {
                        // Told apart by their place, not by their chapter: the chapter's name is its card's on the
                        // board below, which the page scrolls to.
                        ForEach(Array(group.bars.enumerated()), id: \.offset) { i, bar in
                            column(bar, layout.groups[g][i], gap: layout.gap)
                        }
                        // The line each part stands on.
                        Rectangle().fill(Color.primary.opacity(0.22))
                            .frame(width: layout.spans[g].width, height: 1)
                            .offset(x: layout.spans[g].x, y: Self.room)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .frame(height: Self.room + 1, alignment: .topLeading)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .overlay(alignment: .topLeading) { tip(layout) }
            if named {
                // Every part's name is written the same way: on the line the narrowest of them has room for.
                let rooms = groups.indices.filter { groups[$0].part != nil && layout.spans.indices.contains($0) }.map { room(after: $0, layout) }
                let fit: LabelFit = (rooms.min() ?? 0) >= 250 ? .line : (rooms.min() ?? 0) >= 124 ? .stacked : .name
                ZStack(alignment: .topLeading) {
                    ForEach(Array(groups.enumerated()), id: \.element.id) { g, group in
                        if let part = group.part, layout.spans.indices.contains(g) {
                            partLabel(part, group, fit).frame(width: room(after: g, layout), alignment: .leading).offset(x: layout.spans[g].x)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    /// How a part's name is written under its bars: with its numbers beside it, under it, or alone.
    private enum LabelFit { case line, stacked, name }

    /// The room a part's name has: it may run on into the gap before the next part, never over its name.
    private func room(after g: Int, _ layout: BookNumbers.Layout) -> CGFloat {
        max((g + 1 < layout.spans.count ? layout.spans[g + 1].x - 12 : width) - layout.spans[g].x, 0)
    }

    private func column(_ bar: BookNumbers.Bar, _ slot: BookNumbers.Layout.Slot, gap: CGFloat) -> some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: min(3, slot.width / 2), topTrailingRadius: min(3, slot.width / 2))
        // The ring stands off the bar where the gaps leave it room.
        let off: CGFloat = gap >= 4 ? 2 : 1
        return Color.clear
            .frame(width: slot.reach, height: Self.room)
            .overlay(alignment: .bottomLeading) {
                // One colouring at a time: a status's colour, or a strand's (grey for none), never both.
                shape.fill(strands == nil ? bar.status.dot : strand(bar).map { Color(hex: $0.colour) } ?? StrandMark.none)
                    // A strand's own colour may be near the page's: a hairline keeps the bar's edge.
                    .overlay { if strands != nil, slot.width >= 3 { shape.strokeBorder(StrandMark.edge, lineWidth: 0.5) } }
                    .overlay { if hovered == bar.id { shape.fill(Color.primary.opacity(0.18)) } }
                    .opacity(only == nil || bar.strand == only ? 1 : 0.25)
                    .frame(width: slot.width, height: slot.height)
                    .overlay {
                        if bar.id == current {
                            RoundedRectangle(cornerRadius: min(3, slot.width / 2) + off).strokeBorder(Color.primary, lineWidth: 1.5)
                                .padding(-(off + 1.5))
                        }
                    }
            }
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { hovered = bar.id } else if hovered == bar.id { hovered = nil }
            }
            // One gesture, as on the cards: a single click is not held back until a double one cannot come.
            .onTapGesture {
                pick(bar.id)
                if NSApp.currentEvent?.clickCount == 2 { enter(bar.id) }
            }
            .offset(x: slot.x)
            .accessibilityElement()
            .accessibilityLabel(Self.words(bar, words) + ", " + (strands == nil ? bar.status.label : strand(bar)?.shownName ?? L("No strand")))
            .accessibilityAddTraits(bar.id == current ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { pick(bar.id) }
    }

    /// « 33 Flower Island · 12 scènes · 2 034 mots »
    /// In its strand's colour, the bar says its strand too: « … · 1943 ».
    static func words(_ bar: BookNumbers.Bar, _ words: BookWords, strand: String? = nil) -> String {
        (bar.mark.isEmpty ? "" : bar.mark + " ") + "\(bar.title) · " + words.count(bar.scenes, .scene) + " · " + bar.counts.label
            + (strand.map { " · " + $0 } ?? "")
    }

    /// The hovered chapter in words, over its bar; it leans to the side that has the room.
    @ViewBuilder private func tip(_ layout: BookNumbers.Layout) -> some View {
        if let hovered, let (bar, slot) = find(hovered, layout) {
            let right = slot.x + slot.width / 2 > width / 2
            Text(Self.words(bar, words, strand: strands == nil ? nil : strand(bar)?.shownName ?? L("No strand"))).font(.ui(11.5).monospacedDigit()).lineLimit(1)
                .padding(.horizontal, 9).frame(height: 26)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: Radius.row))
                .overlay(RoundedRectangle(cornerRadius: Radius.row).strokeBorder(Ink.hairline))
                .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
                .fixedSize()
                .frame(maxWidth: .infinity, alignment: right ? .trailing : .leading)
                .padding(right ? .trailing : .leading, right ? max(width - slot.x - slot.width - 2, 0) : max(slot.x - 2, 0))
                .offset(y: Self.room - slot.height - 10 - 26)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private func find(_ id: String, _ layout: BookNumbers.Layout) -> (BookNumbers.Bar, BookNumbers.Layout.Slot)? {
        for (g, group) in groups.enumerated() where layout.groups.indices.contains(g) {
            if let i = group.bars.firstIndex(where: { $0.id == id }) { return (group.bars[i], layout.groups[g][i]) }
        }
        return nil
    }

    private func partLabel(_ part: BookPart, _ group: BookNumbers.Group, _ fit: LabelFit) -> some View {
        let name = Text(words.groupName(part)).font(.ui(12, .semibold))
        let facts = Text(words.count(group.bars.count, .piece) + " · " + group.counts.label).font(.ui(fit == .line ? 12 : 11).monospacedDigit()).foregroundStyle(.secondary)
        return Button { zoom(part.id) } label: {
            Group {
                switch fit {
                case .line: HStack(alignment: .firstTextBaseline, spacing: 8) { name; facts }
                case .stacked: VStack(alignment: .leading, spacing: 2) { name; facts }
                case .name: name
                }
            }
            .lineLimit(1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(words.groupScenes)
        .accessibilityLabel(words.groupName(part) + ", " + words.count(group.bars.count, .piece) + ", " + group.counts.label)
    }
}
