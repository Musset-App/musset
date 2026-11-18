import SwiftUI

extension EditorBridge {
    /// Opens a scene in the editor: its chapter, then its marker (or start) selected and in view.
    func show(_ scene: ChapterScene, chapter: String, session: BookSession) {
        let target = scene.marker ?? NSRange(location: scene.range.location, length: 0)
        if chapter == session.selectedChapterID {
            scroll(to: target)
        } else {
            session.open(chapter)
            session.pendingSelection = target
        }
    }

    /// Opens a section in the editor: its chapter, the caret at the end of its heading, in view.
    func show(_ section: ChapterSection, chapter: String, session: BookSession) {
        let target = NSRange(location: NSMaxRange(section.line), length: 0)
        if chapter == session.selectedChapterID {
            scroll(to: target)
        } else {
            session.open(chapter)
            session.pendingSelection = target
        }
    }
}

/// Overview ▸ Grid (⌘5): every scene of the book in rows, the author's columns across, the word counts. Cells are edited in place; the AI fills the columns it may, and only proposes changes to the author's cells.
struct PlotGridView: View {
    let app: AppState
    @Bindable var session: BookSession
    let bridge: EditorBridge
    let analyst: PlotAnalyst
    let planner: ScenePlanner
    @State private var renamingColumn: PlotGrid.Column?
    @State private var columnTitle = ""
    @State private var addingColumn = false
    @State private var deletingColumn: PlotGrid.Column?
    /// The tag whose scenes stand out (the others fade).
    @State private var highlight: PlotGrid.Tag?
    @State private var showIndex = false
    /// Chapters shown at once: enough for most books; a longer one shows the rest on request.
    @State private var shownChapters = 60

    static let sceneWidth: CGFloat = 230
    static let wordsWidth: CGFloat = 80
    static let statusWidth: CGFloat = 104
    static let cellWidth: CGFloat = 230


    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    Divider()
                    ScrollView(.vertical) {
                        // Eager and bounded (a LazyVStack whose rows change height in place spun forever in the chat).
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(session.manifest.chapters.prefix(shownChapters).enumerated()), id: \.element.id) { idx, ch in
                                chapterHeader(ch, idx)
                                ForEach(session.scenes[ch.id] ?? []) { scene in
                                    row(ch, scene)
                                    Divider()
                                }
                            }
                            if session.manifest.chapters.count > shownChapters {
                                Button(L("Show more")) { shownChapters += 60 }.buttonStyle(.link).font(.ui(12)).padding(16)
                            }
                        }
                    }
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .sheet(isPresented: $showIndex) { TagIndexSheet(session: session) { tag in highlight = tag; showIndex = false } }
        .alert(L("Rename column"), isPresented: Binding(get: { renamingColumn != nil }, set: { if !$0 { renamingColumn = nil } })) {
            TextField(L("Title"), text: $columnTitle)
            Button(L("Rename")) {
                if let c = renamingColumn, let i = session.plot.columns.firstIndex(of: c), !columnTitle.isEmpty {
                    session.plot.columns[i].title = columnTitle; session.savePlot()
                }
                renamingColumn = nil
            }
            Button(L("Cancel"), role: .cancel) { renamingColumn = nil }
        }
        .alert(L("New column"), isPresented: $addingColumn) {
            TextField(L("Title"), text: $columnTitle)
            Button(L("Add")) {
                let t = columnTitle.trimmingCharacters(in: .whitespaces)
                guard !t.isEmpty else { return }
                session.plot.columns.append(.init(id: "c" + UUID().uuidString.prefix(6).lowercased(), title: t))
                session.savePlot()
            }
            Button(L("Cancel"), role: .cancel) {}
        }
        .confirmationDialog(deletingColumn.map { L("Delete the column « \($0.shownTitle) »?") } ?? "",
                            isPresented: Binding(get: { deletingColumn != nil }, set: { if !$0 { deletingColumn = nil } })) {
            Button(L("Delete Column…").titled, role: .destructive) {
                if let c = deletingColumn { session.plot.columns.removeAll { $0 == c }; session.savePlot() }
                deletingColumn = nil
            }
            Button(L("Cancel"), role: .cancel) { deletingColumn = nil }
        } message: {
            Text(L("What its cells hold is lost, in every scene."))
        }
    }

    // MARK: Parts

    private var toolbar: some View {
        HStack(spacing: 10) {
            let scenes = session.manifest.chapters.reduce(0) { $0 + (session.scenes[$1.id]?.count ?? 0) }
            Text(session.words.count(session.manifest.chapters.count, .piece) + " · " + session.words.count(scenes, .scene) + " · " + session.bookCounts.label)
                .foregroundStyle(.tertiary)
            Spacer()
            if let s = analyst.lastError ?? analyst.status {
                if analyst.running { ProgressView().controlSize(.small) }
                Text(s).font(.ui(11)).foregroundStyle(analyst.lastError != nil ? Ink.warning : .secondary).lineLimit(1)
                if analyst.running { Button(L("Stop")) { analyst.stop() }.controlSize(.small) }
            }
            if let h = highlight {
                let n = session.plot.scenes(with: h.name, in: h.column).count
                HStack(spacing: 8) {
                    TagChip(tag: h.name, motif: h.column != "characters", selected: true)
                    Text(session.words.count(n, .scene)).font(.ui(12)).foregroundStyle(.secondary)
                    Button { highlight = nil } label: { Image(systemName: "xmark").font(.ui(9, .semibold)) }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help(L("Clear"))
                }
                .padding(.leading, 4).padding(.trailing, 8).frame(height: 28)
                .background(Ink.panel, in: RoundedRectangle(cornerRadius: Radius.control))
            }
            Button { showIndex = true } label: {
                Text(L("Index")).toolbarButton()
            }
            .buttonStyle(.plain)
                .help(L("The book's characters and motifs: one name each, used as tags in the grid"))
            if AIStatus.shared.isOn {
                PopMenu(sections: AIStatus.shared.engines.map { engine in
                    PopSection(title: engine.label, items: [
                        PopItem(title: L("Update changed scenes")) { analyst.update(session, engine: engine) },
                        PopItem(title: L("Rebuild from the whole book")) { analyst.update(session, engine: engine, rebuild: true) },
                    ])
                }) {
                    HStack(spacing: 6) { Image(systemName: "sparkles").font(.ui(10)); Text(L("Update")) }
                        .toolbarButton(.filled)
                }
                .disabled(analyst.running)
                .help(L("Update: the AI reads the scenes changed since its last reading (orange dot). Rebuild: it first reads the whole book to rebuild the index of characters and motifs, then fills every scene. Your cells are never overwritten."))
            }
            Button { columnTitle = ""; addingColumn = true } label: { Image(systemName: "plus") }
                .buttonStyle(.plain).foregroundStyle(.secondary).help(L("Add a column"))
        }
        .font(.ui(13))
        .padding(.horizontal, 16).frame(height: 48)
    }

    private var header: some View {
        HStack(spacing: 0) {
            headerCell(session.words.name(.scene), width: Self.sceneWidth, leading: 16)
            headerCell(CountUnit.current.heading, width: Self.wordsWidth)
            headerCell(L("Status"), width: Self.statusWidth)
            ForEach(session.plot.columns) { c in
                headerCell(c.shownTitle, width: Self.cellWidth, ai: c.ai)
                    .contextMenu {
                        Button(L("Rename…")) { columnTitle = c.shownTitle; renamingColumn = c }
                        Toggle(L("The AI fills this column"), isOn: Binding(get: { c.ai }, set: { v in
                            if let i = session.plot.columns.firstIndex(of: c) { session.plot.columns[i].ai = v; session.savePlot() }
                        }))
                        Button(L("Move Left")) { move(c, by: -1) }.disabled(session.plot.columns.first == c)
                        Button(L("Move Right")) { move(c, by: 1) }.disabled(session.plot.columns.last == c)
                        Divider()
                        Button(L("Delete Column…"), role: .destructive) { deletingColumn = c }
                    }
            }
        }
    }

    private func headerCell(_ title: String, width: CGFloat, ai: Bool? = nil, leading: CGFloat = 8) -> some View {
        HStack(spacing: 4) {
            Text(title).font(.ui(12)).foregroundStyle(.secondary).lineLimit(1)
            if ai == false { Image(systemName: "person.fill").font(.ui(10)).foregroundStyle(.tertiary).help(L("Yours only: the AI does not fill it")) }
        }
        .padding(.leading, leading).padding(.trailing, 8).frame(height: 36)
        .frame(width: width, alignment: .leading)
    }

    private func chapterHeader(_ ch: ChapterEntry, _ idx: Int) -> some View {
        HStack(spacing: 8) {
            let mark = session.manifest.pieceMark(at: idx)
            if !mark.isEmpty { Text(mark).font(.uiMono(12)).foregroundStyle(.tertiary) }
            Text(session.manifest.shownTitle(of: ch)).font(.ui(13, .semibold)).lineLimit(1)
            Text((session.chapterCounts[ch.id]?.size ?? 0).ui).font(.ui(12)).foregroundStyle(.tertiary)
            if AIStatus.shared.isOn {
                Menu {
                    ForEach(AIStatus.shared.engines) { engine in
                        Button(L("Update with \(engine.label)")) { analyst.update(session, engine: engine, chapters: [ch.id]) }
                    }
                    Divider()
                    ForEach(AIStatus.shared.engines) { engine in
                        Button(L("Propose Scenes with \(engine.label)…")) {
                            if ch.id != session.selectedChapterID { session.open(ch.id) }
                            planner.propose(session, engine: engine)
                        }
                    }
                } label: { Image(systemName: "ellipsis").font(.ui(11)).foregroundStyle(.tertiary) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .disabled(analyst.running)
            }
            ChapterSynopsisField(session: session, chapter: ch.id)
                .font(.ui(12))
        }
        .padding(.horizontal, 24).padding(.top, 18).padding(.bottom, 6)
    }

    private func row(_ ch: ChapterEntry, _ scene: ChapterScene) -> some View {
        let text = session.editorText(of: ch.id) as NSString
        let read = session.plot.row(ch.id, scene.key).analyzed
        let stale = NSMaxRange(scene.range) <= text.length && read != PlotGrid.fingerprint(text.substring(with: scene.range))
        let row = session.plot.row(ch.id, scene.key)
        let lit = highlight.map { h in (row.cells[h.column]?.tags ?? []).contains(h.name) }
        return HStack(alignment: .top, spacing: 0) {
            Button { withAnimation { if app.activeTab?.overview != nil { app.showChapter() } }; bridge.show(scene, chapter: ch.id, session: session) } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Circle().fill(stale ? Ink.warning : Color.clear).frame(width: 6, height: 6)
                        .help(read == nil ? L("Not read by the AI yet") : L("Changed since the AI's last reading"))
                    Text(scene.title ?? (scene.marker == nil && (session.scenes[ch.id]?.count ?? 0) == 1 ? session.words.wholePiece : L("Opening")))
                        .foregroundStyle(scene.title == nil ? .secondary : .primary)
                        .multilineTextAlignment(.leading)
                }
            }
            .buttonStyle(.plain)
            .help(L("Open this scene in the editor"))
            .padding(8).frame(width: Self.sceneWidth, alignment: .leading)
            Text(scene.counts.size.ui).font(.ui(12).monospacedDigit()).foregroundStyle(.secondary)
                .padding(8).frame(width: Self.wordsWidth, alignment: .trailing)
            let st = session.sceneStatus(ch.id, scene.key)
            PopMenu(ChapterStatus.allCases.map { s2 in PopItem(title: s2.label, checked: s2 == st, dot: s2.dot) { session.setSceneStatus(ch.id, scene.key, s2) } }) {
                HStack(spacing: 6) { Circle().fill(st.dot).frame(width: 6, height: 6); Text(st.label).font(.ui(12)).foregroundStyle(.secondary) }
            }
            .padding(8).frame(width: Self.statusWidth, alignment: .leading)
            ForEach(session.plot.columns) { c in
                PlotCellView(session: session, chapter: ch.id, scene: scene.key, column: c, highlight: $highlight)
                    .frame(width: Self.cellWidth, alignment: .topLeading)
            }
        }
        .opacity(lit == false ? 0.28 : 1)
        .background(lit == true ? Ink.accent.opacity(0.06) : .clear)
    }

    private func move(_ c: PlotGrid.Column, by delta: Int) {
        guard let i = session.plot.columns.firstIndex(of: c) else { return }
        let j = i + delta
        guard session.plot.columns.indices.contains(j) else { return }
        session.plot.columns.swapAt(i, j)
        session.savePlot()
    }
}

/// One cell: edited in place. Free-text columns are typed; tagged columns hold chips from the book's index.
/// What the author changes is theirs (locked for the AI); the AI's content shows a sparkle, and a proposal for an
/// author cell waits under it to be used or dismissed.
struct PlotCellView: View {
    @Bindable var session: BookSession
    let chapter: String
    let scene: String
    let column: PlotGrid.Column
    @Binding var highlight: PlotGrid.Tag?
    @State private var draft = ""
    @State private var newTag = ""
    @State private var addingTag = false
    @FocusState private var focused: Bool

    private var cell: PlotGrid.Cell { session.plot.row(chapter, scene).cells[column.id] ?? PlotGrid.Cell() }
    private var motif: Bool { column.id != "characters" }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 3) {
                if column.isTagged { tags } else { textField }
                if cell.by != "me", !(cell.text.isEmpty && (cell.tags ?? []).isEmpty) {
                    Image(systemName: "sparkles").font(.ui(10)).foregroundStyle(.tertiary)
                        .help(L("Filled by \(cell.by.capitalized). Change it to make it yours."))
                }
            }
            if let p = cell.proposal {
                VStack(alignment: .leading, spacing: 4) {
                    Text(p).font(.ui(11)).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Button(L("Use")) { use(p) }
                        Button(L("Dismiss")) { set { $0.proposal = nil } }
                    }
                    .buttonStyle(.link).font(.ui(11))
                }
                .padding(6)
                .background(Ink.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: Radius.row))
                .help(L("The AI thinks the scene no longer matches your cell"))
            }
        }
        .padding(8)
        .onAppear { draft = cell.text }
        .onChange(of: cell.text) { _, t in if !focused { draft = t } }
        .onChange(of: focused) { _, f in if !f { commit() } }
        .onDisappear(perform: commit)
        .alert(motif ? L("New Motif…").titled : L("New Character…").titled, isPresented: $addingTag) {
            TextField(L("Name"), text: $newTag)
            Button(L("Add")) { addTag(newTag) }
            Button(L("Cancel"), role: .cancel) {}
        }
    }

    private var textField: some View {
        TextField("", text: $draft, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.ui(12))
            .foregroundStyle(cell.by == "me" ? .primary : .secondary)
            .focused($focused)
            .onSubmit(commit)
    }

    private var tags: some View {
        FlowLayout(spacing: 4) {
            ForEach(cell.tags ?? [], id: \.self) { t in
                let known = session.plot.canonical(t, column: column.id) == t
                Button { highlight = highlight?.name == t ? nil : session.plot.tags.first { $0.column == column.id && $0.name == t } } label: {
                    TagChip(tag: t, motif: motif, unknown: !known, selected: highlight?.name == t)
                }
                .buttonStyle(.plain)
                .help(session.plot.tags.first { $0.column == column.id && $0.name == t }?.note ?? (known ? t : L("Not in the book's index")))
                .contextMenu { Button(L("Remove from This Scene")) { setTags((cell.tags ?? []).filter { $0 != t }) } }
            }
            Menu {
                ForEach(session.plot.tags(in: column.id).filter { !(cell.tags ?? []).contains($0.name) }) { tag in
                    Button(tag.name) { setTags((cell.tags ?? []) + [tag.name]) }
                }
                Divider()
                Button(motif ? L("New Motif…") : L("New Character…")) { newTag = ""; addingTag = true }
            } label: { Image(systemName: "plus").font(.ui(10)) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .opacity(0.5)
        }
    }

    private func addTag(_ name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        if session.plot.canonical(n, column: column.id) == nil {
            session.plot.index = session.plot.tags + [.init(name: n, column: column.id)]
            // A name the Bible has a sheet for is that sheet from the start.
            session.bindPlot()
        }
        setTags((cell.tags ?? []) + [session.plot.canonical(n, column: column.id) ?? n])
    }

    private func setTags(_ t: [String]) {
        set { $0.tags = t.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }; $0.by = "me" }
    }

    private func use(_ p: String) {
        if column.isTagged {
            let t = p.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            set { $0.tags = t; $0.proposal = nil }
        } else {
            set { $0.text = p; $0.proposal = nil }
            draft = p
        }
    }

    private func commit() {
        guard !column.isTagged else { return }
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t != cell.text else { return }
        set { $0.text = t; $0.by = "me" }
    }

    private func set(_ change: (inout PlotGrid.Cell) -> Void) {
        session.plot.update(chapter, scene) { row in
            var c = row.cells[column.id] ?? PlotGrid.Cell()
            change(&c)
            row.cells[column.id] = c
        }
        session.savePlot()
    }
}

/// What a chapter is for: the one field for it, in Overview ▸ Synopsis, in the grid and in the Plan tab, each
/// giving it its own type. Saved when the field loses focus; the others showing the same chapter follow.
struct ChapterSynopsisField: View {
    @Bindable var session: BookSession
    let chapter: String
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(L("What this chapter is for"), text: $draft, axis: .vertical)
            .textFieldStyle(.plain)
            .focused($focused)
            .onAppear { draft = session.plot.chapterSynopsis(chapter) }
            .onChange(of: chapter) { old, new in save(old); draft = session.plot.chapterSynopsis(new) }
            .onChange(of: session.plot.chapterSynopsis(chapter)) { _, kept in if !focused { draft = kept } }
            .onChange(of: focused) { _, f in if !f { save(chapter) } }
            .onDisappear { save(chapter) }
    }

    private func save(_ id: String) {
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t != session.plot.chapterSynopsis(id) else { return }
        session.plot.setChapterSynopsis(id, t)
        session.savePlot()
    }
}

/// A tag of the index. Each name keeps one colour everywhere, so a motif is spotted down the whole grid.
/// Characters are round, motifs square-cornered; a name the index does not know is dashed.
struct TagChip: View {
    let tag: String
    var motif = false
    var unknown = false
    var selected = false

    static func hue(_ s: String) -> Double {
        var h: UInt64 = 5381
        for b in Fold.name(s).utf8 { h = (h &* 33) ^ UInt64(b) }
        return Double(h % 360) / 360
    }

    var body: some View {
        let color = Color(hue: Self.hue(tag), saturation: 0.55, brightness: 0.75)
        let shape = RoundedRectangle(cornerRadius: motif ? 3 : 9)
        Text(tag)
            .font(.ui(11))
            .lineLimit(1)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .foregroundStyle(unknown ? Color.secondary : color)
            .background(color.opacity(selected ? 0.35 : unknown ? 0 : 0.14), in: shape)
            .overlay(shape.strokeBorder(color.opacity(unknown ? 0.6 : selected ? 0.8 : 0), style: StrokeStyle(lineWidth: 1, dash: unknown ? [3, 2] : [])))
    }
}

/// Lays chips out in lines, wrapping at the cell's width. A chip wider than a whole line wraps its own text.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    private func size(of v: LayoutSubview, within width: CGFloat) -> CGSize {
        let s = v.sizeThatFits(.unspecified)
        return s.width > width ? v.sizeThatFits(ProposedViewSize(width: width, height: nil)) : s
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for v in subviews {
            let s = size(of: v, within: width)
            if x > 0, x + s.width > width { y += line + spacing; x = 0; line = 0 }
            x += s.width + spacing
            line = max(line, s.height)
            widest = max(widest, x)
        }
        return CGSize(width: proposal.width ?? widest, height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for v in subviews {
            let s = size(of: v, within: bounds.width)
            if x > bounds.minX, x + s.width > bounds.maxX { y += line + spacing; x = bounds.minX; line = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            line = max(line, s.height)
        }
    }
}

/// The book's index: every character and motif, how many scenes carry it, its other names.
/// Rename (onto an existing name to merge), delete, or pick one to light its scenes in the grid.
struct TagIndexSheet: View {
    @Bindable var session: BookSession
    let pick: (PlotGrid.Tag) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var renaming: PlotGrid.Tag?
    @State private var newName = ""
    @State private var deleting: PlotGrid.Tag?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("Index") + " — \(session.title)").font(.ui(15, .semibold))
            if let s = session.plot.synopsis, !s.isEmpty {
                Text(s).font(.ui(12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if session.plot.tags.isEmpty {
                Text(L("No index yet. In the grid, use Update ▸ Rebuild from the Whole Book: the AI reads the book and names its characters and recurring motifs."))
                    .foregroundStyle(.secondary).padding(.vertical, 20)
            }
            HStack(alignment: .top, spacing: 16) {
                list("characters", title: L("Characters"))
                list("motifs", title: L("Motifs"))
            }
            if let threads = session.plot.threads, !threads.isEmpty {
                Text(L("Threads")).font(.ui(13, .semibold))
                ForEach(threads, id: \.self) { t in
                    Text("**\(t.name)** (\(threadKind(t.kind))) — \(t.note)").font(.ui(11)).foregroundStyle(.secondary)
                }
            }
            HStack { Spacer(); Button(L("Done", ctx: "Terminé")) { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(18)
        .frame(width: 760, height: 620)
        .alert(L("Rename"), isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField(L("Name"), text: $newName)
            Button(L("Rename")) {
                if let r = renaming { session.renameTag(r, to: newName) }
                renaming = nil
            }
            Button(L("Cancel"), role: .cancel) { renaming = nil }
        } message: { Text(L("Give the name of another tag to merge the two.")) }
        .confirmationDialog(deleting.map { L("Delete the tag « \($0.name) »?") } ?? "",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button(L("Delete"), role: .destructive) {
                if let t = deleting { session.plot.deleteTag(t.name, column: t.column); session.savePlot() }
                deleting = nil
            }
            Button(L("Cancel"), role: .cancel) { deleting = nil }
        } message: {
            Text(L("It is taken out of every scene that carries it."))
        }
    }

    /// `kind` is the value the AI gave, kept as is in the book.
    private func threadKind(_ kind: String) -> String {
        switch kind {
        case "main": L("main")
        case "sub": L("sub")
        case "hidden": L("hidden")
        default: kind
        }
    }

    private func list(_ column: String, title: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.ui(13, .semibold))
            List(session.plot.tags(in: column)) { tag in
                let n = session.plot.scenes(with: tag.name, in: column).count
                HStack(alignment: .firstTextBaseline) {
                    Button { pick(tag) } label: { TagChip(tag: tag.name, motif: column != "characters") }.buttonStyle(.plain)
                        .help(L("Show its scenes in the grid"))
                    VStack(alignment: .leading, spacing: 1) {
                        if !tag.note.isEmpty { Text(tag.note).font(.ui(11)) }
                        if !tag.allAliases.isEmpty { Text(L("also: \(tag.allAliases.listed)")).font(.ui(10)).foregroundStyle(.tertiary) }
                    }
                    Spacer()
                    Text("\(n)").font(.ui(11).monospacedDigit()).foregroundStyle(.secondary).help(session.words.count(n, .scene))
                }
                .contextMenu {
                    Button(L("Rename or Merge…")) { newName = tag.name; renaming = tag }
                    Button(L("Delete…"), role: .destructive) { deleting = tag }
                }
            }
        }
    }
}

/// The AI's proposed scene breaks for the open chapter: tick, retitle, insert.
struct ScenePlanSheet: View {
    @Bindable var planner: ScenePlanner
    let session: BookSession
    let bridge: EditorBridge
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Scenes proposed by \(planner.engine.label)")).font(.system(size: 22, design: .serif))
            Text(L("« \(session.selectedChapter?.title ?? "") »: each ticked scene gets a <!-- scene: … --> marker before its first paragraph. You can undo it in the editor (⌘Z)."))
                .font(.ui(11)).foregroundStyle(.secondary)
            if planner.running {
                HStack { ProgressView().controlSize(.small); Text(L("\(planner.engine.label) is reading the chapter…")).foregroundStyle(.secondary) }
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else if let e = planner.error {
                Text(e).foregroundStyle(Ink.warning)
            } else {
                List($planner.proposals) { $p in
                    HStack(alignment: .top) {
                        Toggle("", isOn: $p.include).labelsHidden()
                        VStack(alignment: .leading, spacing: 2) {
                            TextField(L("Title"), text: $p.title).textFieldStyle(.roundedBorder)
                            Text(inQuotes("\(p.start)…")).font(.ui(11)).italic().foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                }
                .frame(minHeight: 260)
            }
            HStack {
                Spacer()
                Button(L("Cancel")) { planner.showing = false; dismiss() }.buttonStyle(.inkSecondary)
                Button(L("Insert \(planner.proposals.filter(\.include).count) Markers")) {
                    _ = planner.apply(session, bridge: bridge)
                    dismiss()
                }
                .buttonStyle(.ink)
                .keyboardShortcut(.defaultAction)
                .disabled(planner.running || planner.proposals.filter(\.include).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 560)
    }
}
