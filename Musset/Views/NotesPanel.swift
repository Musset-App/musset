import SwiftUI

/// Everything said about the text, in one list: the author's notes and tasks, the AIs', the faults. Beside the editor (⌘2).
/// A note unfolds where it is; its discussion slides over the panel.
struct NotesPanel: View {
    let app: AppState
    let session: BookSession
    let bridge: EditorBridge
    let annotator: Annotator
    let proof: AutoProofreader

    @State private var wholeBook = false
    /// What the list leaves out, ticked off in the filters. Remembered from one session to the next.
    @AppStorage("notesHidden") private var hiddenList = "kind:praise"
    @AppStorage("notesShowFinished") private var showFinished = false
    @State private var filtering = false
    /// The faults of the open chapter, refreshed when the proofreader moves: finding them is not free.
    @State private var issues: [AutoProofreader.Issue] = []
    /// Ticked or resolved just now: they stay in place until the chapter changes.
    @State private var justClosed = Set<UUID>()
    @State private var openIssue: String?
    @State private var composer = ""
    @State private var composerIsTask = false
    @FocusState private var composing: Bool
    @State private var deleted: (note: Note, chapter: String, index: Int)?
    @State private var deletedTask: Task<Void, Never>?
    @State private var bookPages: [(id: String, title: String, notes: [Note])] = []
    @State private var customTask: AgentKind?
    @State private var customText = ""
    /// The corrections waiting in the open chapter, and across the book. They live in the text; these are read from it.
    @State private var pending: [Revisions.Pending] = []
    @State private var bookPending: [String: [Revisions.Pending]] = [:]
    /// The AI reading whose notes are about to be dismissed, once confirmed.
    @State private var dismissingRun: String?
    /// Where each note's passage starts in the open chapter, as of the last pause in typing: the list is ordered from
    /// this, not from the live ranges, which move at every letter typed above them.
    @State private var places: [UUID: Int] = [:]
    /// Rows built at once; the rest on request.
    @State private var shownRows = 200

    private var page: String { session.selectedChapterID ?? NoteStore.bookPage }
    private var threadNote: UUID? {
        guard bridge.threadOpen, let id = bridge.openNoteID, session.notes.notes.contains(where: { $0.id == id }) else { return nil }
        return id
    }

    var body: some View {
        ZStack {
            list.opacity(threadNote == nil ? 1 : 0).allowsHitTesting(threadNote == nil)
            if let id = threadNote {
                NoteThread(noteID: id, session: session, annotator: annotator, bridge: bridge) { withAnimation(.easeOut(duration: 0.2)) { bridge.threadOpen = false } }
                    .background(Color(nsColor: .textBackgroundColor))
                    .transition(.move(edge: .trailing))
            }
        }
        .clipped()
        .animation(.easeOut(duration: 0.2), value: threadNote)
    }

    private var list: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if Collab.shared.link(session.git) != nil {
                ConversationsSection(session: session, bridge: bridge)
                Divider()
            }
            if let status = annotator.status ?? annotator.lastError {
                HStack(spacing: 6) {
                    if annotator.running { ProgressView().controlSize(.small) }
                    Text(status).font(.ui(11)).foregroundStyle(annotator.lastError != nil ? Ink.warning : .secondary).lineLimit(3)
                    Spacer()
                    if let run = annotator.lastRun, !annotator.running {
                        Button(L("Dismiss all…")) { dismissingRun = run }
                            .controlSize(.small)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                Divider()
            }
            ScrollViewReader { proxy in
                ScrollView {
                    // Eager and bounded: rows that unfold in place inside a LazyVStack that is scrolled to by id are
                    // what spun forever in SwiftUI's prefetch in the chat.
                    VStack(alignment: .leading, spacing: 4) {
                        if wholeBook { bookRows } else { chapterRows }
                        composerRow.id("composer")
                    }
                    .padding(.vertical, 10)
                }
                .onChange(of: bridge.openNoteID) { _, id in
                    guard let id else { return }
                    // A note further down than what is shown: shown first.
                    if !wholeBook, let i = entries.firstIndex(where: { $0.id == id.uuidString }), i >= shownRows { shownRows = i + 50 }
                    withAnimation { proxy.scrollTo(id, anchor: .center) }
                }
            }
            if let deleted {
                HStack(spacing: 8) {
                    Text(L("Note deleted")).font(.ui(12))
                    Spacer()
                    Button(L("Undo")) { undoDelete(deleted) }.buttonStyle(.plain).font(.ui(12, .medium)).foregroundStyle(Ink.accent)
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Ink.selected)
                .accessibilityAddTraits(.updatesFrequently)
            }
            Divider()
            footer
        }
        .onAppear { refreshIssues(); reloadBook(); refreshPending() }
        // The text is watched from a view of its own: typing does not evaluate the list, and the corrections are
        // read again once it pauses.
        .background(WhenTypingPauses(session: session) { refreshPending(typed: true) })
        .onChange(of: session.notes.notes) { _, _ in places = session.notes.live.mapValues(\.location) }
        .onChange(of: proof.issueCount) { _, _ in refreshIssues() }
        .onChange(of: session.selectedChapterID) { _, _ in refreshIssues(); justClosed = []; openIssue = nil; refreshPending() }
        .onChange(of: wholeBook) { _, _ in reloadBook(); refreshPending() }
        .onChange(of: session.shelfChanges) { _, _ in reloadBook(); refreshPending() }
        .onChange(of: showFinished) { _, _ in justClosed = [] }
        .confirmationDialog(L("Dismiss all the notes of this AI reading?"),
                            isPresented: Binding(get: { dismissingRun != nil }, set: { if !$0 { dismissingRun = nil } })) {
            Button(L("Dismiss all…").titled, role: .destructive) {
                if let run = dismissingRun {
                    session.notes.deleteRun(run); annotator.lastRun = nil; annotator.status = nil; bridge.refreshHighlights()
                }
                dismissingRun = nil
            }
            Button(L("Cancel"), role: .cancel) { dismissingRun = nil }
        } message: {
            Text(L("The notes the AI just left on this chapter are deleted, with the replies under them."))
        }
        .alert(L("Annotate with \(customTask?.label ?? "")"), isPresented: Binding(get: { customTask != nil }, set: { if !$0 { customTask = nil } })) {
            TextField(L("What should it look for?"), text: $customText)
            Button(L("Annotate")) { if let e = customTask { run(.custom, e) }; customTask = nil }
            Button(L("Cancel"), role: .cancel) { customTask = nil }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Segmented(options: [(false, session.words.thisPiece), (true, L("Whole book"))], selection: $wholeBook)
            Button { filtering.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "line.3.horizontal.decrease").font(.ui(11))
                    Text("\(visibleCount)").font(.ui(12).monospacedDigit())
                }
                .foregroundStyle(filtersAreDefault ? AnyShapeStyle(.primary) : AnyShapeStyle(Ink.accent))
                .toolbarButton(.panel)
            }
            .buttonStyle(.plain)
            .help(L("Filter the notes"))
            .accessibilityLabel(L("Filter the notes: \(visibleCount) shown"))
            .popover(isPresented: $filtering, arrowEdge: .bottom) {
                NoteFilters(rows: filterRows, sources: sourceRows, hidden: hidden, showFinished: $showFinished, finished: finishedCount, showResolvedInText: Binding(get: { bridge.showResolvedNotes }, set: { bridge.showResolvedNotes = $0 })) { hidden = $0 }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var scopeNotes: [Note] { wholeBook ? bookPages.flatMap(\.notes) : session.notes.notes }

    private var hidden: Set<String> {
        get { Set(hiddenList.split(separator: ",").map(String.init)) }
        nonmutating set { hiddenList = newValue.sorted().joined(separator: ",") }
    }
    private var filtersAreDefault: Bool { hidden == ["kind:praise"] && !showFinished }

    /// One line per type present in what is being looked at; Réussite always, it is the one that starts unticked.
    private var filterRows: [NoteFilters.Row] {
        let open = scopeNotes.filter { $0.kind != .text && !$0.isClosed }
        var rows: [NoteFilters.Row] = []
        for k in Note.Kind.choices {
            let n = open.filter { $0.kind == k }.count
            if n > 0 || k == .praise || !hidden.isDisjoint(with: ["kind:\(k.rawValue)"]) { rows.append(.init(key: "kind:\(k.rawValue)", label: k.label, color: k.color, count: n)) }
        }
        let waiting = scopePending.count
        if waiting > 0 || hidden.contains(Self.correctionKey) { rows.insert(.init(key: Self.correctionKey, label: L("Corrections"), color: Ink.accent, count: waiting), at: 0) }
        if !wholeBook { rows.append(.init(key: "faults", label: L("Faults"), color: .red, count: issues.count)) }
        return rows
    }
    private static let correctionKey = "kind:correction"
    /// A filter key can't hold the list's separator.
    private static func sourceKey(_ name: String) -> String { "source:" + name.replacingOccurrences(of: ",", with: " ") }

    private var scopePending: [Revisions.Pending] { wholeBook ? bookPending.values.flatMap { $0 } : pending }

    /// Everyone something came from, with how much is still open.
    private var sourceRows: [NoteFilters.Row] {
        let notes = scopeNotes.filter { !$0.isClosed }.compactMap(\.source)
        let names = notes + scopePending.compactMap(\.source)
        return Set(names).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }.map { name in
            .init(key: Self.sourceKey(name), label: name, color: .primary, count: names.filter { $0 == name }.count)
        }
    }

    private func keeps(_ p: Revisions.Pending) -> Bool {
        guard !hidden.contains(Self.correctionKey) else { return false }
        return !hidden.contains(p.source.map(Self.sourceKey) ?? "author:me")
    }

    private var visiblePending: [Revisions.Pending] {
        scopePending.filter(keeps).sorted { ($0.chapter, $0.location) < ($1.chapter, $1.location) }
    }

    /// `typed`: only the open chapter moved, the others are as they were last read.
    private func refreshPending(typed: Bool = false) {
        let now = session.notes.live.mapValues(\.location)
        if now != places { places = now }
        let found = session.selectedChapterID.map { Revisions.pending(in: session.text, chapter: $0) } ?? []
        if found != pending { pending = found }
        guard wholeBook else { return }
        if typed {
            guard let id = session.selectedChapterID, (bookPending[id] ?? []) != found else { return }
            bookPending[id] = found.isEmpty ? nil : found
            return
        }
        var all: [String: [Revisions.Pending]] = [:]
        for ch in session.manifest.chapters + session.draftChapters {
            let found = Revisions.pending(in: session.editorText(of: ch.id), chapter: ch.id)
            if !found.isEmpty { all[ch.id] = found }
        }
        bookPending = all
    }

    private var finishedCount: Int { scopeNotes.filter { $0.kind != .text && $0.isClosed }.count }

    private var visibleCount: Int {
        let notes = scopeNotes.filter { $0.kind != .text && keeps($0) }.count
        return notes + visiblePending.count + (wholeBook || hidden.contains("faults") ? 0 : issues.count)
    }

    private func keeps(_ n: Note) -> Bool {
        if n.kind == .text { return !hidden.contains("kind:note") && !hidden.contains("author:me") }
        guard !hidden.contains("kind:\(n.kind.rawValue)") else { return false }
        guard !hidden.contains(n.source.map(Self.sourceKey) ?? (n.author.isAI ? "author:ai" : "author:me")) else { return false }
        return !n.isClosed || showFinished || justClosed.contains(n.id)
    }

    // MARK: Rows

    private enum Entry: Identifiable {
        case note(Note)
        case issue(AutoProofreader.Issue)
        case correction(Revisions.Pending)
        var id: String {
            switch self {
            case .correction(let p): p.id
            case .note(let n): n.id.uuidString
            case .issue(let i): "\(i.range.location):\(i.fix.ignoreKey)"
            }
        }
    }

    /// Notes and faults as they come in the text; what has no passage comes after, in the order it was written.
    private var entries: [Entry] {
        let all = session.notes.notes.sorted { (places[$0.id] ?? Int.max, $0.created) < (places[$1.id] ?? Int.max, $1.created) }.filter(keeps)
        let placed = all.filter(\.hasPassage).map { (places[$0.id] ?? $0.anchor.start, Entry.note($0)) }
        let faults = hidden.contains("faults") ? [] : issues.map { ($0.range.location, Entry.issue($0)) }
        let waiting = pending.filter(keeps).map { ($0.location, Entry.correction($0)) }
        return (placed + faults + waiting).sorted { $0.0 < $1.0 }.map(\.1) + all.filter { !$0.hasPassage }.map(Entry.note)
    }

    @ViewBuilder private var chapterRows: some View {
        let entries = entries
        decideAll
        ForEach(entries.prefix(shownRows)) { e in
            switch e {
            case .correction(let p): correctionRow(p)
            case .note(let n): noteRow(n, chapter: page).id(n.id)
            case .issue(let i): issueRow(i)
            }
        }
        if entries.count > shownRows { showMore }
        if showFinished { corrections }
        if entries.isEmpty && composer.isEmpty {
            EmptyNote(session.notes.notes.isEmpty && issues.isEmpty ? L("Nothing yet. Write below, or select a passage and press \(AppCommand.glyphs("write.note")).") : L("Nothing with these filters."))
                .padding(.horizontal, 14).padding(.vertical, 8)
        }
    }

    @ViewBuilder private var bookRows: some View {
        decideAll
        let pages = boundedBookPages
        ForEach(pages.shown, id: \.id) { p in
            Text(p.title).font(.ui(11, .medium)).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 2)
            ForEach(p.waiting) { correctionRow($0) }
            ForEach(p.notes) { noteRow($0, chapter: p.id).id($0.id) }
        }
        if pages.more { showMore }
    }

    private var showMore: some View {
        Button(L("Show more")) { shownRows += 200 }.buttonStyle(.link).font(.ui(12)).padding(.horizontal, 16).padding(.vertical, 8)
    }

    /// The whole book's rows, page by page, up to the number shown at once.
    private var boundedBookPages: (shown: [(id: String, title: String, waiting: [Revisions.Pending], notes: [Note])], more: Bool) {
        var out: [(id: String, title: String, waiting: [Revisions.Pending], notes: [Note])] = []
        var left = shownRows, more = false
        for p in bookPages {
            let list = p.notes.filter(keeps)
            let waiting = (bookPending[p.id] ?? []).filter(keeps)
            guard !list.isEmpty || !waiting.isEmpty else { continue }
            guard left > 0 else { more = true; break }
            let w = Array(waiting.prefix(left))
            let n = Array(list.prefix(left - w.count))
            if w.count + n.count < waiting.count + list.count { more = true }
            left -= w.count + n.count
            out.append((p.id, p.title, w, n))
        }
        return (out, more)
    }

    // MARK: Corrections

    /// What is on screen, decided in one go: all of Jean's once the list shows only Jean.
    @ViewBuilder private var decideAll: some View {
        let shown = visiblePending
        if shown.count > 1 {
            HStack(spacing: 10) {
                Text(L("\(shown.count) corrections")).font(.ui(12)).foregroundStyle(.secondary)
                Spacer()
                Button(L("Accept all")) { session.decide(shown, accept: true, bridge: bridge); bridge.refreshHighlights() }
                Button(L("Reject all…")) {
                    RejectAll.confirm(shown.count) { session.decide(shown, accept: false, bridge: bridge); bridge.refreshHighlights() }
                }
            }
            .buttonStyle(.plain).font(.ui(12)).foregroundStyle(Ink.accent)
            .padding(.horizontal, 16).padding(.vertical, 4)
        }
    }

    private func correctionRow(_ p: Revisions.Pending) -> some View {
        func shown(_ s: String) -> String { s.replacingOccurrences(of: "\n", with: " ¶ ").trimmingCharacters(in: .whitespaces) }
        return HStack(alignment: .top, spacing: 8) {
            Button { show(p) } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Group {
                        if p.kind == .insertion { Text(shown(p.new)).foregroundStyle(Ink.positive) }
                        else if p.kind == .deletion { Text(shown(p.old)).strikethrough().foregroundStyle(Ink.revision) }
                        else {
                            Text(shown(p.old)).strikethrough().foregroundStyle(.secondary) + Text("  →  ").foregroundStyle(.tertiary) + Text(shown(p.new))
                        }
                    }
                    .font(.ui(13)).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 0) {
                        Text(L("Correction")).font(.ui(12, .medium)).foregroundStyle(Ink.accent)
                        if let source = p.source { Text(" · " + source).font(.ui(12)).foregroundStyle(.secondary).lineLimit(1) }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button { session.decide(p, accept: true, bridge: bridge); bridge.refreshHighlights() } label: { Image(systemName: "checkmark").frame(width: 24, height: 24).contentShape(Rectangle()) }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help(L("Accept")).accessibilityLabel(L("Accept"))
            Button { session.decide(p, accept: false, bridge: bridge); bridge.refreshHighlights() } label: { Image(systemName: "xmark").frame(width: 24, height: 24).contentShape(Rectangle()) }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help(L("Reject")).accessibilityLabel(L("Reject"))
        }
        .font(.ui(11, .medium))
        .padding(.horizontal, 8).padding(.vertical, 8)
        .padding(.horizontal, 8)
    }

    private func show(_ p: Revisions.Pending) {
        if p.chapter != session.selectedChapterID {
            app.jump(bookPath: session.root.standardizedFileURL.path, chapterID: p.chapter)
            session.pendingSelection = NSRange(location: p.location, length: 0)
        } else {
            bridge.scroll(to: NSRange(location: p.location, length: 0))
        }
    }

    private func reloadBook() {
        guard wholeBook else { return }
        bookPages = (session.manifest.chapters + session.draftChapters).map { ($0.id, $0.title, session.noteStore(for: $0.id).notes(of: $0.id)) }
            + [(NoteStore.bookPage, L("The book"), session.noteStore(for: NoteStore.bookPage).notes(of: NoteStore.bookPage))]
    }

    private func noteRow(_ note: Note, chapter: String) -> some View {
        Group {
            if note.kind == .text {
                FreeTextRow(note: note, drag: .note(chapter: chapter, id: note.id)) { edited in
                    if edited.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { delete(note, chapter: chapter) }
                    else { session.noteStore(for: chapter).change(note.id, in: chapter) { $0.body = edited } }
                }
            } else {
                NoteRow(note: note, session: session, chapter: chapter, open: bridge.openNoteID == note.id,
                        tick: { tick(note, chapter: chapter) },
                        toggle: { toggle(note, chapter: chapter) },
                        thread: { openThread(note, chapter: chapter) },
                        resolve: { resolve(note, chapter: chapter) },
                        delete: { delete(note, chapter: chapter) },
                        reattach: { reattach(note) },
                        findPassage: {
                            app.historyQuery = String(note.anchor.quote.prefix(60))
                            app.inspectorTab = .history
                        },
                        showPassage: { if chapter == session.selectedChapterID, let r = session.notes.live[note.id] { bridge.scroll(to: r) } })
                .shelfDraggable(.note(chapter: chapter, id: note.id), title: note.body)
            }
        }
    }

    private func toggle(_ note: Note, chapter: String) {
        withAnimation(.easeOut(duration: 0.16)) {
            if bridge.openNoteID == note.id { bridge.openNote(nil); return }
            if chapter != session.selectedChapterID, session.manifest.chapters.contains(where: { $0.id == chapter }) {
                app.jump(bookPath: session.root.standardizedFileURL.path, chapterID: chapter)
            }
            bridge.openNote(note.id)
        }
        if let r = session.notes.live[note.id] { bridge.scroll(to: r) }
    }

    private func tick(_ note: Note, chapter: String) {
        let next: Note.Status = note.isClosed ? .open : .done
        if next != .open { justClosed.insert(note.id) }
        session.noteStore(for: chapter).change(note.id, in: chapter) { $0.status = next }
        session.pendingCommit = true
        bridge.refreshHighlights()
        reloadBook()
    }

    private func resolve(_ note: Note, chapter: String) {
        let next: Note.Status = note.status == .resolved ? .open : .resolved
        if next != .open { justClosed.insert(note.id) }
        session.noteStore(for: chapter).change(note.id, in: chapter) { $0.status = next }
        session.pendingCommit = true
        withAnimation(.easeOut(duration: 0.16)) { bridge.openNote(nil) }
        bridge.refreshHighlights()
        reloadBook()
    }

    private func delete(_ note: Note, chapter: String) {
        guard let i = session.noteStore(for: chapter).remove(note.id, in: chapter) else { return }
        withAnimation { deleted = (note, chapter, i) }
        if bridge.openNoteID == note.id { bridge.openNote(nil) }
        session.pendingCommit = true
        bridge.refreshHighlights()
        reloadBook()
        deletedTask?.cancel()
        deletedTask = Task {
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation { deleted = nil }
        }
    }

    private func undoDelete(_ d: (note: Note, chapter: String, index: Int)) {
        deletedTask?.cancel()
        session.noteStore(for: d.chapter).restore(d.note, in: d.chapter, at: d.index)
        session.resolveNotes(in: d.chapter)
        withAnimation { deleted = nil }
        bridge.refreshHighlights()
        reloadBook()
    }

    private func openThread(_ note: Note, chapter: String) {
        if chapter != session.selectedChapterID, session.manifest.chapters.contains(where: { $0.id == chapter }) {
            app.jump(bookPath: session.root.standardizedFileURL.path, chapterID: chapter)
        }
        withAnimation(.easeOut(duration: 0.2)) { bridge.openThread(note.id) }
    }

    private func reattach(_ note: Note) {
        let sel = bridge.selectedRange
        guard sel.length > 0 else { NSSound.beep(); return }
        session.notes.reattach(note.id, to: sel, text: session.text)
        bridge.refreshHighlights()
    }

    // MARK: Faults

    private func refreshIssues() {
        issues = proof.issues(in: bridge.textView?.string ?? session.text)
    }

    /// The fault as it stands now: the text may have moved since the list was made.
    private func current(_ issue: AutoProofreader.Issue) -> AutoProofreader.Issue? {
        refreshIssues()
        return issues.first { $0.fix.ignoreKey == issue.fix.ignoreKey }
    }

    private func issueColor(_ i: AutoProofreader.Issue) -> Color { i.fix.isObvious ? .red : (i.fix.isLanguageTool ? .blue : .purple) }

    private func issueRow(_ issue: AutoProofreader.Issue) -> some View {
        let open = openIssue == issue.fix.ignoreKey
        let title = issue.fix.reason.isEmpty ? L("Suggestion") : LocalProofreader.shown(issue.fix.reason)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                NoteCase(status: .open) { if let i = current(issue) { proof.accept(i); refreshIssues() } }
                    .help(L("Correct"))
                Button {
                    withAnimation(.easeOut(duration: 0.16)) { openIssue = open ? nil : issue.fix.ignoreKey }
                    if let i = current(issue) { bridge.scroll(to: i.range) }
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title).font(.ui(13)).lineLimit(open ? nil : 1).frame(maxWidth: .infinity, alignment: .leading)
                        HStack(spacing: 0) {
                            Text(L("Fault")).font(.ui(12, .medium)).foregroundStyle(issueColor(issue))
                            Text(" · " + (issue.fix.checkerName ?? (issue.fix.isObvious ? L("automatic") : L("AI proofreading", ctx: "relecture IA")))).font(.ui(12)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if open {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(issue.fix.original).strikethrough().foregroundStyle(.secondary).lineLimit(3)
                        Image(systemName: "arrow.right").font(.ui(10)).foregroundStyle(.tertiary)
                        Text(issue.fix.replacement).lineLimit(3)
                    }
                    .font(.uiMono(12))
                    HStack(spacing: 6) {
                        Button(L("Correct")) { if let i = current(issue) { proof.accept(i); refreshIssues() } }
                        Button(L("Ignore")) { proof.ignore(issue.fix); refreshIssues() }
                        Button(L("Other choices…")) { if let i = current(issue) { bridge.scroll(to: i.range); bridge.textView?.showIssueCard(i) } }
                            .buttonStyle(.plain).font(.ui(12)).foregroundStyle(.secondary)
                    }
                    .controlSize(.small)
                }
                .padding(.leading, 22).padding(.top, 6).padding(.bottom, 4)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 8)
        .background(open ? Ink.panel : .clear, in: RoundedRectangle(cornerRadius: Radius.control))
        .padding(.horizontal, 8).padding(.vertical, open ? 4 : 0)
    }

    /// What the proofreader already changed by itself.
    @ViewBuilder private var corrections: some View {
        if proof.typographyFixed > 0 {
            Text(L("\(proof.typographyFixed) automatic typographic fixes since Musset opened"))
                .font(.ui(11)).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.vertical, 6)
        }
        ForEach(proof.corrections) { c in
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(c.original).strikethrough().foregroundStyle(.secondary)
                Image(systemName: "arrow.right").font(.ui(10)).foregroundStyle(.tertiary)
                Text(c.replacement)
                Spacer()
                Button(L("Undo")) { proof.revert(c) }.controlSize(.small)
            }
            .font(.ui(12))
            .help(LocalProofreader.shown(c.reason))
            .padding(.horizontal, 16).padding(.vertical, 6)
        }
    }

    // MARK: Writing

    /// Typing `- [ ] ` or `[] ` makes a case; Return adds the line and keeps writing, Return on an empty case goes back to text.
    private var composerRow: some View {
        HStack(alignment: .top, spacing: 8) {
            if composerIsTask {
                NoteCase(status: .open) {}.allowsHitTesting(false)
            } else {
                Color.clear.frame(width: 14, height: 14)
            }
            TextField(composerIsTask ? "" : L("Write… - [ ] for a case"), text: $composer, axis: .vertical)
                .textFieldStyle(.plain).font(.ui(13)).focused($composing)
                .onChange(of: composer) { _, new in
                    if !composerIsTask, ["- [ ] ", "[] "].contains(new) { composerIsTask = true; composer = "" }
                    // Return arrives as a new line in a vertical field.
                    if new.contains("\n") { submit(new.replacingOccurrences(of: "\n", with: "")) }
                }
                .onSubmit { submit(composer) }
                .onKeyPress(.delete) {
                    guard composerIsTask, composer.isEmpty else { return .ignored }
                    composerIsTask = false
                    return .handled
                }
        }
        .padding(.horizontal, 16).padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture { composing = true }
    }

    private func submit(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespaces)
        defer { composing = true }
        guard !text.isEmpty else {
            composer = ""
            composerIsTask = false
            return
        }
        // « @todo » and a pasted `- [ ]` still make a task.
        let line = TodoSyntax.normalize(text)
        let chapter = wholeBook ? NoteStore.bookPage : page
        if let task = TodoSyntax.parse(Substring(line)) {
            session.noteStore(for: chapter).addPlain(task.text, kind: .todo, in: chapter)
        } else if composerIsTask {
            session.noteStore(for: chapter).addPlain(text, kind: .todo, in: chapter)
        } else {
            session.noteStore(for: chapter).addPlain(text, kind: .text, in: chapter)
        }
        session.pendingCommit = true
        composer = ""
        // What was just written must show.
        let kind = composerIsTask || TodoSyntax.parse(Substring(line)) != nil ? "kind:todo" : "kind:note"
        hidden = hidden.subtracting([kind, "author:me"])
        reloadBook()
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Menu {
                // The same three switches as Settings ▸ Proofreading, under the same names.
                Toggle(L("Proofread while I write", ctx: "Corriger pendant que j’écris"), isOn: Binding(get: { proof.enabled }, set: { proof.enabled = $0 }))
                Toggle(L("Fix obvious mistakes"), isOn: Binding(get: { proof.autoCorrect }, set: { proof.autoCorrect = $0 }))
                Toggle(L("The book’s typography"), isOn: Binding(get: { proof.typography }, set: { proof.typography = $0 }))
                Divider()
                Button(L("Check chapter again")) { proof.recheckAll() }
                Button(L("Dictionary & Exceptions…")) { NotificationCenter.default.post(name: .mussetProofExceptions, object: nil) }
            } label: { Image(systemName: "gearshape").font(.ui(12)) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help(L("Proofreading"))
            if proof.running > 0 { ProgressView().controlSize(.mini) }
            if let e = proof.lastError ?? proof.languageToolError {
                Text(e).font(.ui(11)).foregroundStyle(Ink.warning).lineLimit(2)
            }
            Spacer(minLength: 4)
            if AIStatus.shared.isOn { annotateMenu } else {
                Button { bridge.textView?.beginNote() } label: {
                    HStack(spacing: 5) { Image(systemName: "plus.bubble").font(.ui(10)); Text(L("Note")).font(.ui(12, .medium)).lineLimit(1) }
                        .fixedSize()
                        .toolbarButton()
                }
                .buttonStyle(.plain)
                .help(AppCommand.hint(L("Add a note on the selection"), "write.note"))
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    private var annotateMenu: some View {
        PopMenu(sections: [PopSection(items: [PopItem(title: L("My note on the selection…")) { bridge.textView?.beginNote() }])]
                + AIStatus.shared.engines.map { engine in
                    PopSection(title: engine.label, items: Annotator.Task.allCases.map { task in
                        PopItem(title: task.label) { if task == .custom { customText = ""; customTask = engine } else { run(task, engine) } }
                    })
                }) {
            HStack(spacing: 5) { Image(systemName: "sparkles").font(.ui(10)); Text(L("Annotate")).font(.ui(12, .medium)).lineLimit(1) }
                .fixedSize()
                .toolbarButton()
        }
        .disabled(annotator.running)
        .help(L("Ask Claude or Codex to leave notes on the chapter, or on the selection"))
    }

    private func run(_ task: Annotator.Task, _ engine: AgentKind) {
        let sel = bridge.selectedRange
        annotator.annotate(task, custom: customText, session: session, selection: sel.length > 0 ? sel : nil, engine: engine)
    }
}

/// The filters: tick what to see, one type or several.
struct NoteFilters: View {
    struct Row: Identifiable {
        let key: String
        let label: String
        let color: Color
        let count: Int
        var id: String { key }
    }
    let rows: [Row]
    /// The people things came back from: Jean, Paul…
    var sources: [Row] = []
    let hidden: Set<String>
    @Binding var showFinished: Bool
    let finished: Int
    @Binding var showResolvedInText: Bool
    let set: (Set<String>) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L("Types")).font(.ui(11, .medium)).foregroundStyle(.secondary)
                Spacer()
                Button(L("All", ctx: "Tout")) { set(hidden.subtracting(rows.map(\.key))) }.buttonStyle(.plain).font(.ui(11)).foregroundStyle(Ink.accent)
                Button(L("None", ctx: "Aucun")) { set(hidden.union(rows.map(\.key))) }.buttonStyle(.plain).font(.ui(11)).foregroundStyle(Ink.accent)
            }
            ForEach(rows) { r in
                line(r.label, color: r.color, count: r.count, on: !hidden.contains(r.key)) { on in
                    set(on ? hidden.subtracting([r.key]) : hidden.union([r.key]))
                }
            }
            Divider().padding(.vertical, 2)
            HStack {
                Text(L("From", ctx: "De")).font(.ui(11, .medium)).foregroundStyle(.secondary)
                Spacer()
                Button(L("All", ctx: "Tout")) { set(hidden.subtracting(fromKeys)) }.buttonStyle(.plain).font(.ui(11)).foregroundStyle(Ink.accent)
                Button(L("None", ctx: "Aucun")) { set(hidden.union(fromKeys)) }.buttonStyle(.plain).font(.ui(11)).foregroundStyle(Ink.accent)
            }
            line(L("Me"), on: !hidden.contains("author:me")) { set($0 ? hidden.subtracting(["author:me"]) : hidden.union(["author:me"])) }
            line("Claude", on: !hidden.contains("author:ai")) { set($0 ? hidden.subtracting(["author:ai"]) : hidden.union(["author:ai"])) }
            ForEach(sources) { r in
                line(r.label, count: r.count, on: !hidden.contains(r.key)) { on in
                    set(on ? hidden.subtracting([r.key]) : hidden.union([r.key]))
                }
            }
            Divider().padding(.vertical, 2)
            line(L("Resolved", ctx: "Résolues"), count: finished, on: showFinished) { showFinished = $0 }
            line(L("Resolved ones in the text too"), on: showResolvedInText) { showResolvedInText = $0 }
        }
        .padding(14)
        .frame(width: 250)
    }

    private var fromKeys: [String] { ["author:me", "author:ai"] + sources.map(\.key) }

    private func line(_ label: String, color: Color? = nil, count: Int? = nil, on: Bool, change: @escaping (Bool) -> Void) -> some View {
        Toggle(isOn: Binding(get: { on }, set: change)) {
            HStack(spacing: 6) {
                Text(label).font(.ui(13)).foregroundStyle(color ?? .primary)
                Spacer(minLength: 8)
                if let count { Text("\(count)").font(.ui(12).monospacedDigit()).foregroundStyle(.secondary) }
            }
            .frame(maxWidth: .infinity)
        }
        .toggleStyle(.checkbox)
    }
}

/// The case of a note: empty, ticked, or a dash when it was resolved without being done.
struct NoteCase: View {
    let status: Note.Status
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 3)
                    .fill(status == .done ? Ink.accent : .clear)
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(status == .done ? Ink.accent : Color.secondary.opacity(0.8), lineWidth: 1.5)
                if status == .done {
                    Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Ink.onAccent)
                } else if status == .resolved {
                    RoundedRectangle(cornerRadius: 1).fill(Color.secondary).frame(width: 7, height: 1.5)
                }
            }
            .frame(width: 14, height: 14)
            .padding(.top, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(status == .open ? L("Mark as done") : L("Reopen"))
    }
}

/// One note: closed, a line and its type; open, its full text, its discussion and what can be done with it.
private struct NoteRow: View {
    let note: Note
    let session: BookSession
    let chapter: String
    let open: Bool
    let tick: () -> Void
    let toggle: () -> Void
    let thread: () -> Void
    let resolve: () -> Void
    let delete: () -> Void
    let reattach: () -> Void
    let findPassage: () -> Void
    let showPassage: () -> Void

    /// The AIs start their notes with a [Tag]: the type already says it.
    private var title: String {
        var first = (note.body.components(separatedBy: "\n").first ?? "").trimmingCharacters(in: .whitespaces)
        guard note.author.isAI else { return first }
        while first.hasPrefix("["), let close = first.firstIndex(of: "]") {
            first = first[first.index(after: close)...].trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ":")))
        }
        return first
    }

    private var subline: String {
        var parts: [String] = []
        if note.author.isAI { parts.append(note.author.label) }
        if let source = note.source { parts.append(source) }
        if note.status == .resolved {
            let last = note.replies.last?.body.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            parts.append(last.isEmpty ? L("Resolved") : L("Resolved: \(last)"))
        } else if note.orphaned {
            parts.append(L("Lost passage"))
        } else if note.hasPassage {
            parts.append("« " + note.anchor.quote.replacingOccurrences(of: "\n", with: " ") + " »")
        }
        return parts.map { " · " + $0 }.joined()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                NoteCase(status: note.status, action: tick)
                Button(action: toggle) {
                    VStack(alignment: .leading, spacing: 3) {
                        if !open {
                            Text(title.isEmpty ? note.anchor.quote : title).font(.ui(13)).lineLimit(1)
                                .strikethrough(note.status == .done)
                                .foregroundStyle(note.isClosed ? .secondary : .primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        HStack(spacing: 0) {
                            Text(note.kind.label).font(.ui(12, .medium)).foregroundStyle(note.kind.color)
                            Text(subline).font(.ui(12)).foregroundStyle(.tertiary).lineLimit(1)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if !open, !note.replies.isEmpty {
                    Button(action: thread) {
                        Label("\(note.replies.count)", systemImage: "bubble.left").font(.ui(11)).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(L("Open Thread"))
                }
            }
            if open { details }
        }
        .padding(.horizontal, 8).padding(.vertical, 8)
        .background(open ? Ink.panel : .clear, in: RoundedRectangle(cornerRadius: Radius.control))
        .overlay(RoundedRectangle(cornerRadius: Radius.control).strokeBorder(open ? Ink.hairline : .clear))
        .padding(.horizontal, 8).padding(.vertical, open ? 4 : 0)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("", text: Binding(get: { note.body }, set: { new in session.noteStore(for: chapter).change(note.id, in: chapter) { $0.body = new }; session.pendingCommit = true }), axis: .vertical)
                .textFieldStyle(.plain).font(.ui(13))
                .accessibilityLabel(L("The note"))
            if note.hasPassage, !note.orphaned {
                Button(action: showPassage) {
                    Text(inQuotes(note.anchor.quote)).font(.uiMono(12)).italic().foregroundStyle(.secondary).lineLimit(4).multilineTextAlignment(.leading)
                }
                .buttonStyle(.plain)
                .help(L("Show the passage in the text"))
            }
            if note.orphaned {
                HStack(spacing: 10) {
                    Button(L("Find it in the history"), action: findPassage)
                        .buttonStyle(.link)
                    Button(L("Re-attach to selection"), action: reattach)
                        .buttonStyle(.link)
                }
                .font(.ui(12))
            }
            Button(action: thread) {
                HStack(spacing: 8) {
                    Text(L("Thread")).font(.ui(13))
                    Spacer()
                    Text("\(note.replies.count)").font(.ui(12).monospacedDigit()).foregroundStyle(.secondary)
                    Image(systemName: "chevron.right").font(.ui(10)).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 8).frame(height: 28)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: Radius.row))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            HStack(spacing: 6) {
                Button(note.status == .resolved ? L("Reopen") : L("Resolve"), action: resolve).controlSize(.small)
                Menu(note.kind.label) {
                    ForEach(Note.Kind.choices, id: \.self) { k in
                        Button(k.label) { session.noteStore(for: chapter).change(note.id, in: chapter) { $0.kind = k }; session.pendingCommit = true }
                    }
                }
                .controlSize(.small).fixedSize()
                .help(L("The type of this note"))
                Spacer()
                Button(action: delete) { Image(systemName: "trash").font(.ui(12)).foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
                    .help(L("Delete Note"))
                    .accessibilityLabel(L("Delete Note"))
            }
        }
        .padding(.leading, 22).padding(.top, 6).padding(.bottom, 4)
    }
}

/// Free text among the notes: it edits where it is, and leaves when emptied.
private struct FreeTextRow: View {
    let note: Note
    let drag: ShelfDrag
    let save: (String) -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $draft, axis: .vertical)
            .textFieldStyle(.plain).font(.ui(13)).focused($focused)
            .padding(.leading, 38).padding(.trailing, 16).padding(.vertical, 6)
            .onAppear { draft = note.body }
            .onChange(of: note.body) { _, new in if !focused { draft = new } }
            .onChange(of: focused) { _, on in if !on, draft != note.body { save(draft) } }
            .onSubmit { if draft != note.body { save(draft) } }
            .accessibilityLabel(L("Free note"))
            // The text itself selects with the mouse: the margin carries the drag.
            .overlay(alignment: .topLeading) {
                Image(systemName: "line.3.horizontal").font(.ui(9)).foregroundStyle(.quaternary)
                    .frame(width: 30, height: 28).contentShape(Rectangle())
                    .shelfDraggable(drag, title: note.body)
                    .help(L("Drag to Drafts or Trash"))
            }
    }
}
