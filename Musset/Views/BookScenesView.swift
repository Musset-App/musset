import SwiftUI

/// The scenes seen from further away than a chapter's cards (`SceneCardsView`), on the same ground: the whole book,
/// each chapter a card that shows how it opens and how it closes; or one part, each chapter a lane of its scenes,
/// which move from one lane to another. The board of Overview's first page (`BookOverviewPage`), which scrolls it
/// under the book's numbers and holds its heading and its zoom; which of the two it shows is the workspace's
/// (`Workspace.scenesLevel`).
struct BookScenesView: View {
    let session: BookSession
    let workspace: Workspace
    let paneID: String
    let fontName: String
    /// The width the page gives it, margins included.
    let width: CGFloat
    /// The part shown at the part level; nil at the book's.
    let part: BookPart?
    /// The strand read alone: only its chapters show, and a part that holds none of them has no band. Nil is the book.
    var strand: BookStructure.Strand? = nil
    /// The scene chosen at the part level: the page's zoom goes into its chapter on it.
    @Binding var chosenScene: SceneRef?
    /// Asks for the name of a new strand these chapters will follow.
    var newStrand: ([String]) -> Void = { _ in }
    @AppStorage("sceneCardSize") private var cardSize = 300.0
    /// The scene being dragged, and where it would land.
    @State private var dragging: SceneRef?
    @State private var target: LanePlace?

    struct SceneRef: Equatable {
        var chapter: String
        var index: Int
    }

    struct LanePlace: Equatable {
        var chapter: String
        var place: SceneGrid.Place
    }

    static let margin = SceneCardsView.margin
    static let labelWidth: CGFloat = 150
    /// The cards of each level beside a chapter's scene cards, which the size is the width of.
    static let chapterScale = 0.72
    static let sceneScale = 0.56

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let part { partLevel(part, width: width) } else { bookLevel(width: width) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func counts(_ chapters: [String]) -> TextCounts {
        chapters.reduce(.zero) { $0 + (session.chapterCounts[$1] ?? .zero) }
    }

    // MARK: The book

    @ViewBuilder private func bookLevel(width: CGFloat) -> some View {
        let bands = session.manifest.scenesBands(strand: strand?.id)
        ForEach(bands) { band in
            let folded = band.part.map { workspace.scenesFolded.contains($0.id) } ?? false
            VStack(alignment: .leading, spacing: 12) {
                if let part = band.part { bandHeader(part, band, folded: folded) }
                if !folded { chapterGrid(band, width: width - 2 * Self.margin) }
            }
            .padding(.horizontal, Self.margin).padding(.bottom, 20)
        }
    }

    /// A part's name over its chapters: the chevron folds them away, the name goes into the part.
    private func bandHeader(_ part: BookPart, _ band: ScenesBand, folded: Bool) -> some View {
        HStack(spacing: 8) {
            Button { workspace.foldScenes(part.id, !folded) } label: {
                Image(systemName: folded ? "chevron.right" : "chevron.down").font(.ui(9, .semibold)).foregroundStyle(.secondary)
                    .frame(width: 16, height: 20).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(session.words.foldGroup).accessibilityLabel(session.words.foldGroup)
            Button { workspace.zoomScenes(toPart: part.id) } label: {
                Text(session.partName(part).uppercased(with: UILang.locale)).font(.ui(11, .semibold)).tracking(1.4).lineLimit(1)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(session.words.groupScenes)
            Text(session.words.count(band.chapters.count, .piece) + " · " + counts(band.chapters.map(\.entry.id)).label)
                .font(.ui(12).monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
            Rectangle().fill(Ink.hairline).frame(height: 1)
        }
    }

    private func chapterGrid(_ band: ScenesBand, width: CGFloat) -> some View {
        let size = cardSize * Self.chapterScale
        let grid = SceneGrid(width: width, size: size, count: band.chapters.count, height: size * 1.22)
        return VStack(alignment: .leading, spacing: SceneGrid.gap) {
            ForEach(0..<grid.rows, id: \.self) { row in
                HStack(alignment: .top, spacing: SceneGrid.gap) {
                    ForEach(grid.indices(row: row), id: \.self) { i in
                        let ch = band.chapters[i]
                        ChapterCard(mark: session.manifest.pieceMark(at: ch.index), title: session.manifest.shownTitle(of: ch.entry), entry: ch.entry,
                                    scenes: session.scenes[ch.entry.id] ?? [], counts: session.chapterCounts[ch.entry.id] ?? .zero,
                                    text: session.cardText(of: ch.entry.id), height: grid.cardHeight, fontName: fontName,
                                    selected: workspace.scenesChapter == ch.entry.id,
                                    strand: session.manifest.strand(of: ch.entry),
                                    choose: { workspace.chooseScenesChapter(ch.entry.id) },
                                    enter: { session.enterChapter(ch.entry.id, in: workspace, pane: paneID) })
                            .frame(width: grid.cardWidth, height: grid.cardHeight)
                            .contextMenu { StrandMenu(session: session, chapters: [ch.entry.id], new: newStrand) }
                            .id(ch.entry.id)
                    }
                }
            }
        }
    }

    // MARK: A part

    @ViewBuilder private func partLevel(_ part: BookPart, width: CGFloat) -> some View {
        let chapters = session.manifest.boardChapters(part: part.id, strand: strand?.id)
        let size = cardSize * Self.sceneScale
        let laneWidth = max(width - Self.margin - Self.labelWidth - 16 - 24, size)
        // Nothing on a lane says its scenes can be carried to another: one line does.
        Text(L("Drag a scene to another place, or into another chapter. Double-click it to go into its chapter."))
            .font(.ui(12)).foregroundStyle(.secondary)
            .padding(.leading, Self.margin).padding(.trailing, 16).padding(.bottom, 18)
        VStack(alignment: .leading, spacing: 22) {
            ForEach(chapters, id: \.entry.id) { ch, i in
                let scenes = session.scenes[ch.id] ?? []
                let grid = SceneGrid(width: laneWidth, size: size, count: scenes.count, height: size * 0.73)
                HStack(alignment: .top, spacing: 16) {
                    laneLabel(ch, mark: session.manifest.pieceMark(at: i), scenes: scenes)
                    lane(ch.id, scenes, grid).frame(width: laneWidth, alignment: .leading)
                }
                .id(ch.id)
            }
        }
        .padding(.leading, Self.margin)
    }

    private func laneLabel(_ ch: ChapterEntry, mark: String, scenes: [ChapterScene]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if !mark.isEmpty { Text(mark).font(.uiMono(11)).foregroundStyle(.secondary) }
                Text(session.manifest.shownTitle(of: ch)).font(.ui(12, .semibold)).lineLimit(2)
                    .foregroundStyle(workspace.scenesChapter == ch.id ? Ink.accent : .primary)
            }
            Text(session.words.count(scenes.count, .scene) + " · " + (session.chapterCounts[ch.id] ?? .zero).label)
                .font(.ui(11).monospacedDigit()).foregroundStyle(.secondary).lineLimit(2)
            if let strand = session.manifest.strand(of: ch) {
                HStack(spacing: 5) {
                    StrandMark(colour: strand.colour, size: 7)
                    Text(strand.shownName).font(.ui(10.5)).foregroundStyle(.secondary).lineLimit(1)
                }
                .padding(.top, 1)
            }
        }
        .frame(width: Self.labelWidth, alignment: .leading)
        .padding(.top, 8)
        .contentShape(Rectangle())
        .onTapGesture {
            workspace.chooseScenesChapter(ch.id)
            if NSApp.currentEvent?.clickCount == 2 { session.enterChapter(ch.id, in: workspace, pane: paneID) }
        }
        .contextMenu { StrandMenu(session: session, chapters: [ch.id], new: newStrand) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { session.enterChapter(ch.id, in: workspace, pane: paneID) }
    }

    /// A chapter's scenes in reading order, wrapping under one another rather than scrolling sideways: every place
    /// a scene can be dropped at stays in sight.
    private func lane(_ chapter: String, _ scenes: [ChapterScene], _ grid: SceneGrid) -> some View {
        let text = session.cardText(of: chapter)
        return VStack(alignment: .leading, spacing: SceneGrid.gap) {
            ForEach(0..<grid.rows, id: \.self) { row in
                HStack(alignment: .top, spacing: SceneGrid.gap) {
                    ForEach(grid.indices(row: row), id: \.self) { i in
                        let ref = SceneRef(chapter: chapter, index: i)
                        MiniSceneCard(index: i, scene: scenes[i], text: text.scenes.indices.contains(i) ? text.scenes[i] : AttributedString(),
                                      fontName: fontName, selected: chosenScene == ref,
                                      choose: { chosenScene = ref; workspace.chooseScenesChapter(chapter) },
                                      enter: { session.enterChapter(chapter, scene: i, in: workspace, pane: paneID) },
                                      drag: {
                                          dragging = ref
                                          return NSItemProvider(object: title(ref) as NSString)
                                      })
                            .frame(width: grid.cardWidth, height: grid.cardHeight)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: grid.cardHeight, alignment: .topLeading)
        .overlay(alignment: .topLeading) {
            if let target, target.chapter == chapter {
                let at = grid.bar(target.place)
                RoundedRectangle(cornerRadius: 1.5).fill(Ink.accent)
                    .frame(width: 3, height: grid.cardHeight)
                    .offset(x: at.x, y: at.y)
                    .allowsHitTesting(false)
            }
        }
        .contentShape(Rectangle())
        // Each lane takes drops over its own grid; one scene is in hand for all of them.
        .onDrop(of: [.text], delegate: SceneCardDrop(
            grid: grid, inset: 0,
            dragging: Binding(get: { dragging?.index }, set: { if $0 == nil { dragging = nil } }),
            // A lane left only clears the bar if it is still its own: the next lane may have been entered first.
            target: Binding(get: { target?.chapter == chapter ? target?.place : nil },
                            set: { place in
                                if let place { target = LanePlace(chapter: chapter, place: place) } else if target?.chapter == chapter { target = nil }
                            }),
            carried: dragging.map(title)) { _, slot in
                if let from = dragging { move(from, to: chapter, slot: slot) }
            })
    }

    private func title(_ ref: SceneRef) -> String {
        guard let scenes = session.scenes[ref.chapter], scenes.indices.contains(ref.index) else { return "" }
        return scenes[ref.index].title ?? session.words.scene(ref.index + 1)
    }

    /// The same move as the sidebar's and the Plan's: the text, its notes and its plot row go together, in one
    /// commit, and the bar bottom left takes it back.
    private func move(_ from: SceneRef, to chapter: String, slot: Int) {
        let same = from.chapter == chapter
        if same, slot == from.index || slot == from.index + 1 { return }
        session.moveScene(from: from.chapter, index: from.index, to: chapter, slot: slot)
        chosenScene = SceneRef(chapter: chapter, index: same && slot > from.index ? slot - 1 : slot)
        workspace.chooseScenesChapter(chapter)
    }
}

/// A chapter at the book's level: its number, title and status, how many scenes and how long, the lines it opens
/// on and the lines it closes on, and one tick per scene, as wide as the scene is long.
private struct ChapterCard: View {
    let mark: String
    let title: String
    @Environment(\.bookWords) private var words
    let entry: ChapterEntry
    let scenes: [ChapterScene]
    let counts: TextCounts
    let text: ChapterCardText
    let height: CGFloat
    let fontName: String
    let selected: Bool
    /// The strand it follows: its mark and its name, beside the counts.
    var strand: BookStructure.Strand? = nil
    let choose: () -> Void
    let enter: () -> Void

    /// What the card's height leaves to the two excerpts, once its other lines are counted.
    private var room: CGFloat { max(height - (text.excerpt.closing.isEmpty ? 92 : 126), 24) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                if !mark.isEmpty { Text(mark).font(.uiMono(11)).foregroundStyle(.secondary) }
                Text(title).font(.ui(12, .medium)).lineLimit(1)
                Spacer(minLength: 4)
                StatusDot(status: entry.status ?? .draft)
            }
            HStack(spacing: 6) {
                Text(words.count(scenes.count, .scene) + " · " + counts.label)
                    .font(.ui(11).monospacedDigit()).foregroundStyle(.secondary).lineLimit(1).layoutPriority(1)
                if let strand {
                    Spacer(minLength: 0)
                    // A small card keeps the mark and lets the name go.
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 5) {
                            Text(strand.shownName).font(.ui(10.5)).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                            StrandMark(colour: strand.colour, size: 7)
                        }
                        StrandMark(colour: strand.colour, size: 7)
                    }
                    .help(L("Strand: \(strand.shownName)"))
                }
            }
            .padding(.top, 3)
            if text.excerpt.opening.isEmpty {
                Text(L("empty")).font(.ui(11)).foregroundStyle(.tertiary).padding(.top, 10)
            } else {
                label(L("Beginning")).padding(.top, 10)
                lines(text.opening, height: text.excerpt.closing.isEmpty ? room : (room * 0.57).rounded(), from: .top)
                if !text.excerpt.closing.isEmpty {
                    HStack(spacing: 6) {
                        Dashes()
                        Text("⋯").font(.ui(10)).foregroundStyle(.secondary)
                        Dashes()
                    }
                    .frame(height: 16)
                    label(L("End"))
                    lines(text.closing, height: (room * 0.43).rounded(), from: .bottom)
                }
            }
            Spacer(minLength: 6)
            Ticks(shares: SceneExcerpts.ticks(scenes)).frame(height: 5)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Ink.side, in: RoundedRectangle(cornerRadius: Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Radius.card).strokeBorder(selected ? Ink.accent : Ink.hairline, lineWidth: selected ? 1.5 : 1))
        .clipShape(RoundedRectangle(cornerRadius: Radius.card))
        .contentShape(RoundedRectangle(cornerRadius: Radius.card))
        // One gesture, not a single and a double one: SwiftUI holds a single click until a double one can't come.
        .onTapGesture {
            choose()
            if NSApp.currentEvent?.clickCount == 2 { enter() }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { enter() }
    }

    private func label(_ text: String) -> some View {
        Text(text.uppercased(with: UILang.locale)).font(.ui(9.5, .semibold)).tracking(1.1).foregroundStyle(.secondary)
            .frame(height: 12)
    }

    /// An excerpt in the room it has: the opening from its first line down, the ending from its last line up.
    /// The side it is cut on fades, rather than showing half a line.
    private func lines(_ text: AttributedString, height: CGFloat, from edge: VerticalEdge) -> some View {
        Text(text).font(.custom(fontName, size: 10.5)).lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: height, alignment: edge == .top ? .top : .bottom)
            .clipped()
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: min(14 / max(height, 1), 1))],
                                 startPoint: edge == .top ? .bottom : .top, endPoint: edge == .top ? .top : .bottom))
            .padding(.top, 4)
    }

    private struct Dashes: View {
        var body: some View {
            Canvas { ctx, size in
                var line = Path()
                line.move(to: CGPoint(x: 0, y: size.height / 2))
                line.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                ctx.stroke(line, with: .color(.primary.opacity(0.22)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
            .frame(height: 1)
        }
    }

    /// One tick per scene, sharing the card's width as the scenes share the chapter.
    private struct Ticks: View {
        let shares: [Double]
        var body: some View {
            Canvas { ctx, size in
                let gap: CGFloat = shares.count > 40 ? 1 : 2
                let room = max(size.width - gap * CGFloat(shares.count - 1), 0)
                var x: CGFloat = 0
                for share in shares {
                    let w = room * share
                    ctx.fill(Path(roundedRect: CGRect(x: x, y: 0, width: max(w, 1), height: size.height), cornerRadius: 2), with: .color(.primary.opacity(0.3)))
                    x += w + gap
                }
            }
            .accessibilityHidden(true)
        }
    }
}

/// A scene at a part's level: its number, title and length, and its first lines. The whole card is its handle.
private struct MiniSceneCard: View {
    let index: Int
    let scene: ChapterScene
    let text: AttributedString
    let fontName: String
    let selected: Bool
    let choose: () -> Void
    let enter: () -> Void
    let drag: () -> NSItemProvider

    @Environment(\.bookWords) private var words
    private var name: String { scene.title ?? words.scene(index + 1) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(index + 1)").font(.ui(10, .semibold).monospacedDigit()).foregroundStyle(.secondary)
                Text(name.uppercased(with: UILang.locale)).font(.ui(10, .semibold)).tracking(0.8).lineLimit(1)
                    .foregroundStyle(scene.title == nil ? .secondary : .primary)
            }
            Text(scene.counts.label).font(.ui(10.5).monospacedDigit()).foregroundStyle(.secondary).lineLimit(1).padding(.top, 2)
            // The text takes the room the card has left, whatever its own length: laid over it, and cut there.
            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .topLeading) {
                    Text(text).font(.custom(fontName, size: 10)).lineSpacing(2.5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .clipped()
                .mask(LinearGradient(colors: [.black, .black, .black, .clear], startPoint: .top, endPoint: .bottom))
                .padding(.top, 6)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(Ink.side, in: RoundedRectangle(cornerRadius: Radius.control))
        .overlay(RoundedRectangle(cornerRadius: Radius.control).strokeBorder(selected ? Ink.accent : Ink.hairline, lineWidth: selected ? 1.5 : 1))
        .clipShape(RoundedRectangle(cornerRadius: Radius.control))
        .contentShape(RoundedRectangle(cornerRadius: Radius.control))
        .onTapGesture {
            choose()
            if NSApp.currentEvent?.clickCount == 2 { enter() }
        }
        .onDrag {
            drag()
        } preview: {
            Text(name).font(.ui(12)).lineLimit(1)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Ink.panel, in: RoundedRectangle(cornerRadius: Radius.row))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(index + 1), \(name), \(scene.counts.label)")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { enter() }
    }
}
