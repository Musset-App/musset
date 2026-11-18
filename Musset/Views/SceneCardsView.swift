import SwiftUI

/// A chapter as its scenes, each on a card with its whole text, in reading order on a board's ground: to see the
/// chapter at a glance and reorganise it. A card's header drags its scene elsewhere, its title is renamed in place,
/// the gap between two paragraphs splits it, its menu joins it with the next. The text itself is only read here:
/// writing stays in the editor, a double-click away. A way of showing a chapter's tab (`Workspace.sceneCards`).
struct SceneCardsView: View {
    let session: BookSession
    let workspace: Workspace
    let paneID: String
    let chapterID: String
    let fontName: String
    @AppStorage("sceneCardSize") private var cardSize = 300.0
    /// The scene whose title is being typed, and what is typed.
    @State private var renaming: Int?
    @State private var draft = ""
    /// The scene whose card is being dragged, and where it would land.
    @State private var dragging: Int?
    @State private var target: SceneGrid.Place?

    static let margin: CGFloat = 40
    static let sizes = 220.0...460.0

    private var selected: Int? {
        workspace.selectedSceneCard(pane: paneID, chapter: chapterID)
    }

    var body: some View {
        let text = session.editorText(of: chapterID)
        // Read so that a change written to a chapter's file (not open in an editor) redraws the cards.
        let _ = session.scenes[chapterID]
        let scenes = Scenes.parse(text)
        let ns = text as NSString
        GeometryReader { geo in
            let grid = SceneGrid(width: geo.size.width - 2 * Self.margin, size: cardSize, count: scenes.count)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header(scenes)
                    VStack(alignment: .leading, spacing: SceneGrid.gap) {
                        ForEach(0..<grid.rows, id: \.self) { row in
                            HStack(alignment: .top, spacing: SceneGrid.gap) {
                                ForEach(grid.indices(row: row), id: \.self) { i in
                                    card(i, scenes, ns).frame(width: grid.cardWidth, height: grid.cardHeight)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .topLeading) {
                        if let target {
                            let at = grid.bar(target)
                            RoundedRectangle(cornerRadius: 1.5).fill(Ink.accent)
                                .frame(width: 3, height: grid.cardHeight)
                                .offset(x: at.x, y: at.y)
                                .allowsHitTesting(false)
                        }
                    }
                    .padding(.horizontal, Self.margin)
                    .contentShape(Rectangle())
                    .onDrop(of: [.text], delegate: SceneCardDrop(grid: grid, inset: Self.margin, dragging: $dragging, target: $target,
                                                                 carried: dragging.map { title(scenes, $0) }) { from, slot in move(from, to: slot) })
                }
                .padding(.bottom, 88)
            }
        }
        .background(DotGround())
        .overlay(alignment: .bottomLeading) {
            HStack(spacing: 10) {
                ScenesZoomPill(level: .chapter, hasParts: session.manifest.hasPartsInUse,
                               disabled: session.manifest.part(of: chapterID) == nil ? [.part] : []) { level in
                    if level != .chapter { session.zoomOut(from: chapterID, toPart: level == .part, in: workspace, pane: paneID) }
                }
                SceneSizeControl(size: $cardSize)
                SceneMoveUndoBar(session: session, shown: session.lastSceneMove?.chapters.contains { $0.id == chapterID } == true)
            }
            .padding(.leading, Self.margin).padding(.bottom, 16)
        }
        .onAppear { if selected == nil { select(caretScene(scenes)) } }
        .onChange(of: scenes.count) { _, count in
            if let s = selected, s >= count { select(count - 1) }
            if let r = renaming, r >= count { renaming = nil }
        }
    }

    /// The scene the caret was last in, in this chapter.
    private func caretScene(_ scenes: [ChapterScene]) -> Int {
        let caret = session.state.selections[chapterID] ?? 0
        return scenes.lastIndex { $0.range.location <= caret } ?? 0
    }

    private func title(_ scenes: [ChapterScene], _ i: Int) -> String {
        scenes.indices.contains(i) ? scenes[i].title ?? session.words.scene(i + 1) : ""
    }

    // MARK: The chrome

    private func header(_ scenes: [ChapterScene]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(session.anyChapter(chapterID)?.title ?? chapterID).font(.system(size: 28, design: .serif)).lineLimit(1)
                HStack(spacing: 0) {
                    Text(session.words.count(scenes.count, .scene) + " · ")
                    CountButton(text: scenes.reduce(TextCounts.zero) { $0 + $1.counts }.label)
                }
                .font(.ui(12).monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
            }
            Text(L("Drag a scene by its header to move it. Double-click its text to write in it."))
                .font(.ui(12)).foregroundStyle(.secondary)
        }
        .padding(.leading, Self.margin).padding(.trailing, 16).padding(.top, 18).padding(.bottom, 24)
    }

    // MARK: A card

    private func card(_ i: Int, _ scenes: [ChapterScene], _ ns: NSString) -> some View {
        let scene = scenes[i]
        return SceneCard(index: i, scene: scene, paragraphs: SceneCard.paragraphs(of: scene, in: ns), fontName: fontName,
                         selected: selected == i, isLast: i == scenes.count - 1,
                         renaming: renaming == i, draft: $draft,
                         actions: SceneCard.Actions(
                            select: { select(i) },
                            beginRename: { beginRename(i, from: scene.title ?? "") },
                            commitRename: { commitRename(keepOpen: true) },
                            endRename: { if renaming == i { commitRename(keepOpen: false) } },
                            cancelRename: { renaming = nil },
                            open: { openInText($0 ?? scene.marker ?? NSRange(location: scene.range.location, length: 0)) },
                            split: { split(at: $0) },
                            merge: { merge(i) },
                            drag: {
                                dragging = i
                                return NSItemProvider(object: title(scenes, i) as NSString)
                            }))
    }

    private func select(_ i: Int) {
        workspace.selectSceneCard(i, pane: paneID, chapter: chapterID)
    }

    private func beginRename(_ i: Int, from title: String) {
        select(i)
        draft = title
        renaming = i
    }

    /// Return keeps the field open on a title that is refused (another scene's), to correct it; leaving the field
    /// lets it go. An empty title is no rename.
    private func commitRename(keepOpen: Bool) {
        guard let i = renaming else { return }
        let empty = draft.trimmingCharacters(in: .whitespaces).isEmpty
        if empty || session.renameScene(chapterID, index: i, to: draft) || !keepOpen { renaming = nil }
    }

    /// A new scene from the paragraph at `location`, its title ready to type.
    private func split(at location: Int) {
        guard let new = session.splitScene(chapterID: chapterID, at: location) else { return }
        beginRename(new, from: "")
    }

    private func merge(_ i: Int) {
        renaming = nil
        if session.mergeScene(chapterID: chapterID, index: i) { select(i) }
    }

    private func move(_ from: Int, to slot: Int) {
        guard slot != from, slot != from + 1 else { return }
        renaming = nil
        session.moveScene(from: chapterID, index: from, to: chapterID, slot: slot)
        select(slot > from ? slot - 1 : slot)
    }

    /// Back to the chapter's text in this pane, the caret at `range`.
    private func openInText(_ range: NSRange) {
        workspace.setSceneCards(false, pane: paneID, chapter: chapterID)
        session.activate(workspace)
        workspace.focus(paneID)
        if session.selectedChapterID != chapterID { session.open(chapterID, show: false) }
        session.pendingSelection = range
    }
}

/// Where the cards lie: as many columns as fit at the size chosen, sharing the width; rows of one height.
struct SceneGrid: Equatable {
    static let gap: CGFloat = 16
    let columns: Int
    let cardWidth: CGFloat
    let cardHeight: CGFloat
    let count: Int

    /// A place between two cards: before the card at `column` of `row` (after the row's last card when there is none).
    struct Place: Equatable {
        var row: Int
        var column: Int
    }

    /// `height`: the cards' own, for those that are not a chapter's scenes (a book's chapters, a part's scenes).
    init(width: CGFloat, size: CGFloat, count: Int, height: CGFloat? = nil) {
        let width = max(width, 120)
        columns = max(1, Int((width + Self.gap) / (size + Self.gap)))
        cardWidth = (width - CGFloat(columns - 1) * Self.gap) / CGFloat(columns)
        cardHeight = (height ?? size * 1.15).rounded()
        self.count = count
    }

    var rows: Int { (count + columns - 1) / columns }

    func indices(row: Int) -> Range<Int> { min(row * columns, count)..<min((row + 1) * columns, count) }

    /// The place a point of the grid points at: the nearest gap between cards in the row it is over.
    func place(at p: CGPoint) -> Place {
        let row = min(max(0, Int(p.y / (cardHeight + Self.gap))), max(rows - 1, 0))
        let column = Int(((p.x + Self.gap / 2) / (cardWidth + Self.gap)).rounded())
        return Place(row: row, column: min(max(0, column), indices(row: row).count))
    }

    /// The slot (0…count) a place stands for, as `BookSession.moveScene` counts them.
    func slot(_ place: Place) -> Int { min(place.row * columns + place.column, count) }

    /// The top left corner of the 3-point bar that shows a place, in the middle of the gap.
    func bar(_ place: Place) -> CGPoint {
        CGPoint(x: CGFloat(place.column) * (cardWidth + Self.gap) - Self.gap / 2 - 1.5, y: CGFloat(place.row) * (cardHeight + Self.gap))
    }
}

/// A card dropped among the others. The drag carries the scene's title as text (what lands if it is dropped in
/// another app); what is moved is the card remembered when the drag began. A part's lanes each have one, over
/// their own grid.
struct SceneCardDrop: DropDelegate {
    let grid: SceneGrid
    let inset: CGFloat
    @Binding var dragging: Int?
    @Binding var target: SceneGrid.Place?
    /// What the card's drag carries: another drag passing over (a tab, text from elsewhere) is not one of ours.
    let carried: String?
    let perform: (Int, Int) -> Void

    private var ours: Bool { dragging != nil && NSPasteboard(name: .drag).string(forType: .string) == carried }
    private func place(_ info: DropInfo) -> SceneGrid.Place { grid.place(at: CGPoint(x: info.location.x - inset, y: info.location.y)) }

    func validateDrop(info: DropInfo) -> Bool { ours }
    func dropEntered(info: DropInfo) { if ours { target = place(info) } }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard ours else { return nil }
        let p = place(info)
        if target != p { target = p }
        return DropProposal(operation: .move)
    }
    func dropExited(info: DropInfo) { target = nil }
    func performDrop(info: DropInfo) -> Bool {
        defer { dragging = nil; target = nil }
        guard ours, let from = dragging else { return false }
        perform(from, grid.slot(place(info)))
        return true
    }
}

/// One scene: its number, its title and its length over a hairline, then its whole text, scrolling in the card.
private struct SceneCard: View {
    struct Actions {
        let select: () -> Void
        let beginRename: () -> Void
        /// Return in the title field.
        let commitRename: () -> Void
        /// The title field left.
        let endRename: () -> Void
        let cancelRename: () -> Void
        /// Opens the text at a paragraph, or at the scene's start.
        let open: (NSRange?) -> Void
        let split: (Int) -> Void
        let merge: () -> Void
        let drag: () -> NSItemProvider
    }

    /// A paragraph of the scene and where it starts in the chapter's text.
    struct Paragraph: Identifiable {
        let location: Int
        let text: AttributedString
        var id: Int { location }
    }

    let index: Int
    let scene: ChapterScene
    let paragraphs: [Paragraph]
    let fontName: String
    let selected: Bool
    let isLast: Bool
    let renaming: Bool
    @Binding var draft: String
    let actions: Actions
    @FocusState private var typing: Bool

    /// The scene's prose, one paragraph per line of the editor's text; the marker and the chapter's heading left out.
    static func paragraphs(of scene: ChapterScene, in ns: NSString) -> [Paragraph] {
        let end = min(NSMaxRange(scene.range), ns.length)
        var at = scene.marker.map { NSMaxRange(ns.lineRange(for: $0)) } ?? scene.range.location
        var out: [Paragraph] = []
        while at < end {
            let found = ns.range(of: "\n", range: NSRange(location: at, length: end - at)).location
            let stop = found == NSNotFound ? end : found
            let raw = ns.substring(with: NSRange(location: at, length: stop - at)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !raw.isEmpty, !(scene.marker == nil && raw.hasPrefix("#")) {
                // A line break inside a paragraph (⇧↩) is U+2028 in the editor's text.
                let shown = raw.replacingOccurrences(of: String(ParagraphCodec.lineBreak), with: "\n")
                let styled = try? AttributedString(markdown: shown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
                out.append(Paragraph(location: at, text: styled ?? AttributedString(shown)))
            }
            at = stop + 1
        }
        return out
    }

    @Environment(\.bookWords) private var words
    private var name: String { scene.title ?? words.scene(index + 1) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle().fill(Ink.hairline).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(paragraphs.enumerated()), id: \.element.id) { i, p in
                        if i > 0 { SplitGap { actions.split(p.location) } }
                        Text(p.text)
                            .font(.custom(fontName, size: 11.5)).lineSpacing(3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .contentShape(Rectangle())
                            // One gesture, not a single and a double one: SwiftUI holds a single click until a double one can't come.
                            .onTapGesture {
                                actions.select()
                                if NSApp.currentEvent?.clickCount == 2 { actions.open(NSRange(location: p.location, length: 0)) }
                            }
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
            }
        }
        .background(Ink.side, in: RoundedRectangle(cornerRadius: Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Radius.card).strokeBorder(selected ? Ink.accent : Ink.hairline, lineWidth: selected ? 1.5 : 1))
        .clipShape(RoundedRectangle(cornerRadius: Radius.card))
        .contentShape(RoundedRectangle(cornerRadius: Radius.card))
        .onTapGesture { actions.select() }
        .contextMenu {
            Button(L("Rename")) { actions.beginRename() }
            Button(L("Open in the Text")) { actions.open(nil) }
            if !isLast {
                Divider()
                Button(words.mergeWithNextScene) { actions.merge() }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(index + 1), \(name)")
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(index + 1)").font(.ui(11).monospacedDigit()).foregroundStyle(.secondary)
            if renaming {
                TextField(name, text: $draft)
                    .textFieldStyle(.plain).font(.ui(11, .semibold)).focused($typing)
                    .onSubmit { actions.commitRename() }
                    .onExitCommand { actions.cancelRename() }
                    .onAppear { typing = true }
                    .onChange(of: typing) { _, on in if !on { actions.endRename() } }
            } else {
                Text(name.uppercased(with: Locale(identifier: UILang.current.localeID)))
                    .font(.ui(11, .semibold)).tracking(0.8)
                    .foregroundStyle(scene.title == nil ? .secondary : .primary)
                    .lineLimit(1)
                    .help(L("Double-click to rename"))
            }
            Spacer(minLength: 6)
            Text(scene.counts.label).font(.ui(11).monospacedDigit()).foregroundStyle(.tertiary).lineLimit(1).fixedSize()
        }
        .padding(.horizontal, 14).frame(height: 36)
        .contentShape(Rectangle())
        .onTapGesture {
            actions.select()
            if NSApp.currentEvent?.clickCount == 2, !renaming { actions.beginRename() }
        }
        // The header is the card's handle.
        .onDrag {
            actions.drag()
        } preview: {
            Text(name).font(.ui(12)).lineLimit(1)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Ink.panel, in: RoundedRectangle(cornerRadius: Radius.row))
        }
    }
}

/// The gap between two paragraphs of a card: under the pointer, a dashed line and the button that starts a new
/// scene there.
private struct SplitGap: View {
    let split: () -> Void
    @State private var hovering = false

    var body: some View {
        Color.clear
            .frame(maxWidth: .infinity).frame(height: 14)
            .contentShape(Rectangle())
            .overlay {
                if hovering {
                    ZStack {
                        Line().stroke(Ink.accent, style: StrokeStyle(lineWidth: 1, dash: [4, 3])).frame(height: 1)
                        Button(action: split) {
                            Text(L("Split here")).font(.ui(9.5, .medium)).foregroundStyle(Ink.onAccent)
                                .padding(.horizontal, 8).frame(height: 14)
                                .background(Ink.accent, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .onHover { hovering = $0 }
    }

    private struct Line: Shape {
        func path(in rect: CGRect) -> Path {
            Path { p in
                p.move(to: CGPoint(x: rect.minX, y: rect.midY))
                p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            }
        }
    }
}

/// The three levels the scenes are seen from, bottom left of their board: the book, a part, a chapter.
/// A book without parts has no part level.
struct ScenesZoomPill: View {
    let level: ScenesLevel
    let hasParts: Bool
    /// Levels with nowhere to go from here: the part of a chapter that is in none.
    var disabled: Set<ScenesLevel> = []
    let pick: (ScenesLevel) -> Void

    @Environment(\.bookWords) private var words

    private var levels: [(ScenesLevel, String)] {
        [(.book, L("Book"))] + (hasParts ? [(.part, words.name(.group))] : []) + [(.chapter, words.name(.piece))]
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(levels, id: \.0) { value, label in
                let on = value == level
                Button { if !on { pick(value) } } label: {
                    Text(label).font(.ui(12, on ? .semibold : .regular))
                        .foregroundStyle(on ? Ink.onAccent : .secondary)
                        .padding(.horizontal, 14).frame(height: 24)
                        .background(on ? Ink.accent : .clear, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(disabled.contains(value))
                .opacity(disabled.contains(value) ? 0.45 : 1)
                .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(3)
        .background(Capsule().fill(Color(nsColor: .textBackgroundColor)))
        .overlay(Capsule().strokeBorder(Ink.hairline))
        .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
        .fixedSize()
    }
}

/// How large the cards are, beside the levels: one size for the three, each level drawing its cards to its scale.
struct SceneSizeControl: View {
    @Binding var size: Double
    @Environment(\.bookWords) private var words

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "square.grid.3x3").font(.ui(10))
            Slider(value: $size, in: SceneCardsView.sizes).controlSize(.mini).frame(width: 110)
            Image(systemName: "square.grid.2x2").font(.ui(12))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12).frame(height: 30)
        .background(Capsule().fill(Color(nsColor: .textBackgroundColor)))
        .overlay(Capsule().strokeBorder(Ink.hairline))
        .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
        .help(words.sceneSizes)
        .accessibilityLabel(words.sceneSizes)
    }
}

/// The move just made, to take back: the same one the Plan offers (`BookSession.lastSceneMove`).
struct SceneMoveUndoBar: View {
    let session: BookSession
    let shown: Bool

    var body: some View {
        if shown, let undo = session.lastSceneMove {
            HStack(spacing: 10) {
                Text(L("Moved: \(undo.title)")).font(.ui(12)).foregroundStyle(.secondary).lineLimit(1)
                Button(L("Undo the move")) { session.undoSceneMove() }.controlSize(.small)
            }
            .padding(.leading, 14).padding(.trailing, 8).frame(height: 32)
            .background(Capsule().fill(Color(nsColor: .textBackgroundColor)))
            .overlay(Capsule().strokeBorder(Ink.hairline))
            .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
        }
    }
}
