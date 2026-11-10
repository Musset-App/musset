import SwiftUI

/// The open chapter's outline: its synopsis, then its scenes, each opening on the plot grid's columns. Same data as the grid (⌘5).
struct PlanPanel: View {
    let app: AppState
    @Bindable var session: BookSession
    let bridge: EditorBridge
    let analyst: PlotAnalyst
    let planner: ScenePlanner
    @State var openScene: String?
    @State private var titleDraft = ""
    @State private var wholeBook = false
    @State private var dragging: PlanDrag?
    /// The insertion line: before scene `slot` of `chapter`.
    @State private var dropSlot: PlanSlot?
    @State private var noteCounts: [String: [String: Int]] = [:]

    /// The editable fields, a shade off the open scene's card.
    private static let field = Color(nsColor: .textBackgroundColor)

    private var chapter: ChapterEntry? { session.selectedChapter }
    private var scenes: [ChapterScene] { chapter.flatMap { session.scenes[$0.id] } ?? [] }

    var body: some View {
        if let chapter {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Segmented(options: [(false, L("This chapter")), (true, L("Whole book"))], selection: $wholeBook)
                        if wholeBook {
                            bookOutline
                        } else {
                        header(chapter)
                        synopsis(chapter)
                        lengths
                        VStack(spacing: 0) {
                            ForEach(Array(scenes.enumerated()), id: \.element.id) { i, scene in
                                insertionLine(chapter.id, i)
                                sceneRow(chapter, scene, i)
                                    .onDrag { startDrag(.scene(chapter.id, i)) }
                                    .onDrop(of: [.text], delegate: PlanDrop(slot: PlanSlot(chapter: chapter.id, index: i), dragging: $dragging, target: $dropSlot, perform: perform))
                            }
                            insertionLine(chapter.id, scenes.count)
                        }
                        .onDrop(of: [.text], delegate: PlanDrop(slot: PlanSlot(chapter: chapter.id, index: scenes.count), dragging: $dragging, target: $dropSlot, perform: perform))
                        Button { bridge.textView?.beginScene() } label: {
                            Text(L("+ Scene at the caret")).font(.ui(12)).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, minHeight: 34)
                                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Ink.hairline, style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(L("New scene at the caret, the title ready to type (⇧⌘N)"))
                        }
                    }
                    .padding(14)
                }
                if let undo = session.lastSceneMove {
                    Divider()
                    HStack(spacing: 8) {
                        Text(L("Moved: \(undo.title)")).font(.ui(12)).foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: 4)
                        Button(L("Undo the move")) { session.undoSceneMove(); bridge.refreshHighlights(); countNotes() }.controlSize(.small)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 8)
                }
                if AIStatus.shared.isOn {
                    Divider()
                    aiBar(chapter)
                }
            }
            .onChange(of: session.selectedChapterID) { _, _ in openScene = nil }
            .onChange(of: wholeBook) { _, on in if on { countNotes() } }
        }
    }

    private func header(_ chapter: ChapterEntry) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(chapter.title).font(.ui(15, .semibold)).lineLimit(1)
            Spacer()
            Button { withAnimation { app.showPlotGrid = true } } label: { Text(L("Grid ⌘5")).font(.ui(12)).foregroundStyle(Ink.accent) }
                .buttonStyle(.plain)
                .help(L("The same outline for the whole book"))
        }
    }

    private func synopsis(_ chapter: ChapterEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("Chapter synopsis")).font(.ui(11, .medium)).foregroundStyle(.secondary)
            ChapterSynopsisField(session: session, chapter: chapter.id, placeholder: L("What the chapter accomplishes, in two or three sentences."))
                .font(.ui(13))
                .lineLimit(3...)
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(Ink.panel, in: RoundedRectangle(cornerRadius: 7))
        }
    }

    private var lengths: some View {
        let total = scenes.reduce(0) { $0 + $1.words }
        return VStack(spacing: 6) {
            HStack {
                Text("\(scenes.count) " + (scenes.count == 1 ? L("scene") : L("scenes"))).font(.ui(11, .medium))
                Spacer()
                Text("\(total.ui) " + L("words")).font(.ui(11))
            }
            .foregroundStyle(.secondary)
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(scenes) { s in
                        let on = openScene == s.key
                        RoundedRectangle(cornerRadius: 2)
                            .fill(on ? Ink.accent : Color.secondary.opacity(s.words == 0 ? 0.15 : 0.4))
                            .frame(width: barWidth(s, in: geo.size.width, total: total))
                            .help(sceneTitle(s))
                    }
                }
            }
            .frame(height: 6)
            .accessibilityLabel(L("Relative length of the scenes"))
        }
    }

    /// A scene not yet written still gets a sliver.
    private func barWidth(_ s: ChapterScene, in width: CGFloat, total: Int) -> CGFloat {
        let sliver: CGFloat = 8
        let room = width - CGFloat(max(0, scenes.count - 1)) * 2 - CGFloat(scenes.count) * sliver
        return sliver + max(0, room) * (total > 0 ? CGFloat(s.words) / CGFloat(total) : 1 / CGFloat(max(1, scenes.count)))
    }

    private func sceneTitle(_ s: ChapterScene) -> String {
        s.title ?? (s.marker == nil && scenes.count == 1 ? L("Whole chapter", ctx: "Tout le chapitre") : L("Opening"))
    }

    @ViewBuilder
    private func sceneRow(_ chapter: ChapterEntry, _ scene: ChapterScene, _ i: Int) -> some View {
        let open = openScene == scene.key
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.12)) { openScene = open ? nil : scene.key }
            } label: {
                HStack(spacing: 8) {
                    PlanGrip()
                    Text(sceneTitle(scene)).font(.ui(13, open ? .medium : .regular)).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 4)
                    fillDots(chapter, scene)
                    Text(scene.words > 0 ? scene.words.ui : "—").font(.ui(11).monospacedDigit()).foregroundStyle(.tertiary).frame(width: 34, alignment: .trailing)
                }
                .padding(.horizontal, 9).frame(minHeight: 36)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open { fields(chapter, scene, i) }
        }
        .background(open ? Ink.panel : .clear, in: RoundedRectangle(cornerRadius: 8))
    }

    private func fillDots(_ chapter: ChapterEntry, _ scene: ChapterScene) -> some View {
        let filled = session.plot.filled(chapter.id, scene.key)
        return HStack(spacing: 3) {
            ForEach(Array(filled.enumerated()), id: \.offset) { _, on in
                Circle().fill(on ? Ink.accent : Color.secondary.opacity(0.25)).frame(width: 5, height: 5)
            }
        }
        .help("\(filled.filter { $0 }.count)/\(filled.count) " + L("fields filled"))
    }

    private func fields(_ chapter: ChapterEntry, _ scene: ChapterScene, _ i: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let marker = scene.marker {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L("Title")).font(.ui(11)).foregroundStyle(.secondary)
                    TextField("", text: $titleDraft)
                        .textFieldStyle(.plain).font(.ui(12)).padding(8)
                        .background(Self.field, in: RoundedRectangle(cornerRadius: 6))
                        .onAppear { titleDraft = scene.title ?? "" }
                        .onSubmit { rename(marker) }
                }
            }
            ForEach(session.plot.columns) { column in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        Text(column.shownTitle).font(.ui(11)).foregroundStyle(.secondary)
                        if !column.ai { Image(systemName: "person.fill").font(.ui(9)).foregroundStyle(.tertiary).help(L("Yours only: the AI does not fill it")) }
                    }
                    PlotCellView(session: session, chapter: chapter.id, scene: scene.key, column: column, highlight: .constant(nil))
                        .frame(maxWidth: .infinity, minHeight: column.isTagged ? 0 : 34, alignment: .topLeading)
                        .background(Self.field, in: RoundedRectangle(cornerRadius: 6))
                }
            }
            HStack(spacing: 12) {
                Button(L("Show in text")) { bridge.show(scene, chapter: chapter.id, session: session) }
                Spacer()
            }
            .buttonStyle(.plain).font(.ui(12)).foregroundStyle(.secondary)
        }
        .padding(.leading, 33).padding(.trailing, 10).padding(.top, 2).padding(.bottom, 12)
    }

    private func aiBar(_ chapter: ChapterEntry) -> some View {
        HStack {
            if let s = analyst.lastError ?? analyst.status {
                Text(s).font(.ui(11)).foregroundStyle(analyst.lastError != nil ? .orange : .secondary).lineLimit(2)
            }
            Spacer()
            PopMenu(sections: AIStatus.shared.engines.map { engine in
                PopSection(title: engine.label, items: [
                    PopItem(title: L("Fill this chapter's scenes")) { analyst.update(session, engine: engine, chapters: [chapter.id]) },
                    PopItem(title: L("Propose scenes…")) { planner.propose(session, engine: engine) },
                ])
            }) {
                HStack(spacing: 6) { Image(systemName: "sparkles").font(.ui(10)); Text(L("AI")).font(.ui(12, .medium)) }
                    .padding(.horizontal, 10).frame(height: 28)
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Ink.hairline))
            }
            .disabled(analyst.running)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private func rename(_ marker: NSRange) {
        let t = titleDraft.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, t != openScene else { return }
        bridge.replace(marker, with: Scenes.markerLine(t))
        openScene = t
    }

    private func startDrag(_ drag: PlanDrag) -> NSItemProvider {
        dragging = drag
        return NSItemProvider(object: drag.title(session) as NSString)
    }

    @ViewBuilder
    private func insertionLine(_ chapter: String, _ index: Int) -> some View {
        Rectangle().fill(dropSlot == PlanSlot(chapter: chapter, index: index) ? Ink.accent : .clear)
            .frame(height: 2).padding(.horizontal, 4).padding(.vertical, 1)
    }

    /// Everything in order, each scene and chapter draggable.
    private var bookOutline: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(session.manifest.chapters, id: \.id) { ch in
                let list = session.scenes[ch.id] ?? []
                let on = PlanSlot(chapter: "", index: session.manifest.chapters.firstIndex { $0.id == ch.id } ?? 0)
                Rectangle().fill(dropSlot == on ? Ink.accent : .clear).frame(height: 2).padding(.horizontal, 4)
                Button { session.open(ch.id) } label: {
                    HStack(spacing: 8) {
                        PlanGrip()
                        Text(ch.title).font(.ui(13, .semibold)).lineLimit(1)
                        Spacer(minLength: 4)
                        Text((session.chapterWords[ch.id] ?? 0).ui).font(.ui(11).monospacedDigit()).foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 9).frame(minHeight: 30)
                    .background(ch.id == session.selectedChapterID ? Ink.selected : .clear, in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onDrag { startDrag(.chapter(ch.id)) }
                .onDrop(of: [.text], delegate: PlanDrop(slot: on, dragging: $dragging, target: $dropSlot, perform: perform, alsoScene: PlanSlot(chapter: ch.id, index: 0)))
                ForEach(Array(list.enumerated()), id: \.element.id) { i, scene in
                    insertionLine(ch.id, i)
                    Button { bridge.show(scene, chapter: ch.id, session: session) } label: {
                        HStack(spacing: 8) {
                            PlanGrip()
                            Text(scene.title ?? (scene.marker == nil && list.count == 1 ? L("Whole chapter", ctx: "Tout le chapitre") : L("Opening"))).font(.ui(13)).lineLimit(1)
                            Spacer(minLength: 4)
                            if let n = noteCounts[ch.id]?[scene.id], n > 0 { Text("\(n) " + (n == 1 ? L("note") : L("notes"))).font(.ui(11)).foregroundStyle(.secondary) }
                            Text(scene.words > 0 ? scene.words.ui : "—").font(.ui(11).monospacedDigit()).foregroundStyle(.tertiary).frame(width: 34, alignment: .trailing)
                        }
                        .padding(.leading, 26).padding(.trailing, 9).frame(minHeight: 28)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onDrag { startDrag(.scene(ch.id, i)) }
                    .onDrop(of: [.text], delegate: PlanDrop(slot: PlanSlot(chapter: ch.id, index: i), dragging: $dragging, target: $dropSlot, perform: perform))
                }
                insertionLine(ch.id, list.count)
            }
        }
        .onAppear(perform: countNotes)
    }

    /// How many notes sit in each scene: read when the outline opens, not at every redraw.
    private func countNotes() {
        var out: [String: [String: Int]] = [:]
        for ch in session.manifest.chapters {
            let list = session.scenes[ch.id] ?? []
            for n in session.notes.notes(of: ch.id) where n.status == .open {
                let at = ch.id == session.selectedChapterID ? (session.notes.live[n.id]?.location ?? n.anchor.start) : n.anchor.start
                if let s = Scenes.scene(at: at, in: list) { out[ch.id, default: [:]][s.id, default: 0] += 1 }
            }
        }
        noteCounts = out
    }

    /// The drop. In the open chapter the move is one edit of the editor, so ⌘Z takes it back.
    private func perform(_ drag: PlanDrag, _ slot: PlanSlot) {
        switch drag {
        case .chapter(let id):
            guard slot.chapter.isEmpty else { return }
            session.moveChapters(ids: [id], to: slot.index)
        case .scene(let chapter, let index):
            guard !slot.chapter.isEmpty else { return }
            if chapter == slot.chapter, chapter == session.selectedChapterID {
                let before = session.text
                guard let out = Scenes.moved(index, to: slot.index, in: before, openingTitle: L("Opening")) else { return }
                bridge.replace(NSRange(location: 0, length: (before as NSString).length), with: out.text)
                if let title = out.opening { session.plot.rename(chapter, from: "", to: title); session.savePlot() }
                session.notes.resolveAll(in: session.text)
            } else {
                session.moveScene(from: chapter, index: index, to: slot.chapter, slot: slot.index)
            }
            bridge.refreshHighlights()
            openScene = nil
            countNotes()
        }
    }
}

/// What is being dragged in the Plan.
enum PlanDrag: Equatable {
    case scene(String, Int)
    case chapter(String)

    @MainActor func title(_ session: BookSession) -> String {
        switch self {
        case .chapter(let id): session.manifest.chapters.first { $0.id == id }?.title ?? id
        case .scene(let ch, let i): session.scenes[ch].flatMap { $0.indices.contains(i) ? $0[i].title : nil } ?? L("Opening")
        }
    }
}

/// A place between two rows; `chapter` empty means a place among the chapters.
struct PlanSlot: Equatable {
    var chapter: String
    var index: Int
}

/// Six dots: this row can be picked up.
struct PlanGrip: View {
    var body: some View {
        Image(systemName: "line.3.horizontal").font(.ui(10)).foregroundStyle(.tertiary).frame(width: 14)
            .accessibilityHidden(true)
    }
}

struct PlanDrop: DropDelegate {
    let slot: PlanSlot
    @Binding var dragging: PlanDrag?
    @Binding var target: PlanSlot?
    let perform: (PlanDrag, PlanSlot) -> Void
    /// A scene dropped on a chapter's title goes to the head of that chapter.
    var alsoScene: PlanSlot?

    private func resolved() -> PlanSlot? {
        switch dragging {
        case .chapter: slot.chapter.isEmpty ? slot : nil
        case .scene: slot.chapter.isEmpty ? alsoScene : slot
        case nil: nil
        }
    }
    func validateDrop(info: DropInfo) -> Bool { dragging != nil && resolved() != nil }
    func dropEntered(info: DropInfo) { target = resolved() }
    func dropUpdated(info: DropInfo) -> DropProposal? { target = resolved(); return DropProposal(operation: .move) }
    func dropExited(info: DropInfo) { if target == resolved() { target = nil } }
    func performDrop(info: DropInfo) -> Bool {
        defer { dragging = nil; target = nil }
        guard let drag = dragging, let at = resolved() else { return false }
        perform(drag, at)
        return true
    }
}
