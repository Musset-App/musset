import SwiftUI

/// A past state to bring things from. With `base`, what happened between the two comes already chosen.
struct BringPoint: Identifiable, Equatable {
    var id: String { rev + (base ?? "") }
    var rev: String
    var base: String?
    var label: String
    var chapters: [String]?
}

/// The Historique tab: every change, in the order it happened, each one able to come back.
struct HistoryPanel: View {
    @Bindable var app: AppState
    let session: BookSession
    let bridge: EditorBridge

    enum Scope: Hashable { case selection, chapter, several, book }
    enum Show: String, CaseIterable, Identifiable {
        case all, removed, added, modified
        var id: String { rawValue }
        var label: String {
            switch self {
            case .all: L("Everything")
            case .removed: L("Removed", ctx: "Effacé")
            case .added: L("Added")
            case .modified: L("Changed")
            }
        }
        func keeps(_ c: TextChange) -> Bool {
            switch self {
            case .all: true
            case .removed: c.kind == .removed
            case .added: c.kind == .added
            case .modified: c.kind == .modified
            }
        }
    }

    @State private var scope = Scope.chapter
    @State private var show = Show.all
    @State private var query = ""
    @State private var checked = Set<String>()
    @State private var pickingChapters = false
    @State private var logs: [String: [GitService.Commit]] = [:]
    @State private var sittings: [WorkSitting] = []
    @State private var loading = false
    @State private var events: [PhraseEvent] = []
    @State private var searching = false
    @State private var states: [(commit: GitService.Commit, text: String)] = []
    @State private var statesRange: NSRange?
    @State private var comparing: CompareItem?
    @State private var placing: Placing?
    @State private var goingBack: WorkSitting?
    @State private var message: String?

    struct Placing: Identifiable {
        let id = UUID()
        let places: [TextRestore.Place]
        let text: String
    }

    private var chapterIDs: [String] {
        switch scope {
        case .selection, .chapter: session.selectedChapterID.map { [$0] } ?? []
        case .several: session.manifest.chapters.map(\.id).filter(checked.contains)
        case .book: session.manifest.chapters.map(\.id)
        }
    }
    private var loadKey: String { "\(scope)|\(chapterIDs.joined(separator: ","))|\(session.lastCommitAt?.timeIntervalSince1970 ?? 0)" }
    private func file(_ id: String) -> String? { session.manifest.chapters.first { $0.id == id }?.file }
    private func title(_ id: String) -> String { session.manifest.chapters.first { $0.id == id }?.title ?? id }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            if !session.git.isRepo {
                empty(L("This book has no history yet."))
            } else if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                searchResults
            } else if scope == .selection {
                selectionStates
            } else if scope == .several && checked.isEmpty {
                empty(L("Tick the chapters to read."))
            } else {
                list
            }
            if let message {
                Divider()
                Text(message).font(.ui(12)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).padding(.vertical, 8)
            }
        }
        .task(id: loadKey) { await load() }
        .task(id: query) { await search() }
        .onAppear { query = app.historyQuery ?? query; app.historyQuery = nil }
        .onChange(of: app.historyQuery) { _, q in if let q { query = q; app.historyQuery = nil } }
        .sheet(item: $comparing) { CompareView(item: $0) }
        .sheet(item: $placing) { p in PlacementSheet(places: p.places, text: p.text) { place in put(p.text, at: place.range) } }
        .sheet(item: $goingBack) { GoBackSheet(session: session, sitting: $0, chapterIDs: chapterIDs) }
    }

    private var controls: some View {
        VStack(spacing: 10) {
            Segmented(options: [(Scope.selection, L("Selection")), (.chapter, session.words.name(.piece)), (.several, L("Several…")), (.book, L("Book"))], selection: $scope)
            if scope == .several {
                Button { pickingChapters = true } label: {
                    Text(checked.isEmpty ? session.words.choosePieces : session.words.count(checked.count, .piece))
                        .font(.ui(12)).frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $pickingChapters) { chapterPicker }
            }
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.ui(11)).foregroundStyle(.tertiary)
                    TextField(L("Search, even what no longer exists"), text: $query)
                        .textFieldStyle(.plain).font(.ui(12))
                }
                .padding(.horizontal, 8).frame(height: 26)
                .background(Ink.panel, in: RoundedRectangle(cornerRadius: Radius.control))
                Picker("", selection: $show) { ForEach(Show.allCases) { Text($0.label).tag($0) } }
                    .labelsHidden().pickerStyle(.menu).fixedSize().font(.ui(12))
                    .accessibilityLabel(L("Show"))
                sourcesMenu
                // The wide view: the same history as a tab, with the tracks and the milestones on one line.
                Button { app.open(.story) } label: { Image(systemName: "arrow.up.left.and.arrow.down.right").font(.ui(12)).frame(width: 22, height: 22).contentShape(Rectangle()) }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help(L("The Book’s History")).accessibilityLabel(L("The Book’s History"))
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var chapterPicker: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(session.manifest.chapters, id: \.id) { ch in
                    Toggle(ch.title, isOn: Binding(get: { checked.contains(ch.id) }, set: { on in if on { checked.insert(ch.id) } else { checked.remove(ch.id) } }))
                        .toggleStyle(.checkbox).font(.ui(12))
                }
            }
            .padding(12)
        }
        .frame(width: 280, height: 320)
    }

    /// Tracks and milestones can be brought from too, and started from here.
    private var sourcesMenu: some View {
        Menu {
            if !session.pistes.isEmpty {
                Section(L("Bring from a track")) {
                    ForEach(session.pistes) { p in Button(p.name) { app.takingBack = p } }
                }
            }
            if !session.jalons.isEmpty {
                Section(L("Bring from a milestone")) {
                    ForEach(session.jalons) { j in Button(j.title) { app.bringing = BringPoint(rev: j.commit, base: nil, label: j.title) } }
                }
            }
            Divider()
            Button(L("New Track…")) { app.newPiste = TrackStart() }
            Button(L("Set a Milestone…")) { app.newJalon = TrackStart() }
        } label: { Image(systemName: "ellipsis.circle").font(.ui(13)) }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help(L("Tracks and milestones: bring from one, start one"))
        .accessibilityLabel(L("Tracks and milestones"))
    }

    private func empty(_ text: String) -> some View {
        EmptyNote(text).padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: The list

    /// Sittings shown at once. An eager stack, bounded: a LazyVStack here spun forever in SwiftUI's prefetch (11 Nov),
    /// like the chat before it.
    @State private var shown = 40

    private var list: some View {
        let files = session.manifest.chapters.reduce(into: [String: String]()) { $0[$1.id] = $1.file }
        let titles = session.manifest.chapters.reduce(into: [String: String]()) { $0[$1.id] = $1.title }
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if loading && sittings.isEmpty { ProgressView().controlSize(.small).padding(16) }
                ForEach(sittings.prefix(shown)) { s in
                    SittingSection(sitting: s, reader: session.historyReader, logs: logs, files: files,
                                   titles: titles,
                                   showChapter: scope != .chapter, show: show,
                                   current: session.selectedChapterID,
                                   restore: { c, ch in restore(c, chapter: ch) },
                                   compare: { compare(s, chapter: $0) },
                                   bring: { app.bringing = BringPoint(rev: s.tip.id, base: s.base, label: Self.when(s.tip.date), chapters: chapterIDs) },
                                   goBack: { goingBack = s },
                                   track: { session.newPiste(named: L("From \(Self.when(s.tip.date))"), from: s.tip.id, fromLabel: Self.when(s.tip.date)) },
                                   milestone: { session.addJalon(title: Self.when(s.tip.date), note: "", at: s.tip.id); message = L("Milestone set.") })
                }
                if sittings.count > shown {
                    Button(L("Show older")) { shown += 40 }.buttonStyle(.link).font(.ui(12)).padding(16)
                }
                if !loading && sittings.isEmpty { EmptyNote(L("Nothing yet.")).padding(16) }
            }
        }
    }

    private func load() async {
        session.flushSave()
        // What was just written or deleted is in the history at once, not at the next idle commit: once it is
        // committed, the list loads again.
        session.commitIfPending(message: session.editMessage, background: true)
        let reader = session.historyReader
        let targets = chapterIDs.compactMap { id in file(id).map { (id, $0) } }
        loading = true
        let result = await Task.detached(priority: .userInitiated) { () -> [String: [GitService.Commit]] in
            var out: [String: [GitService.Commit]] = [:]
            for (id, f) in targets where !Task.isCancelled { out[id] = reader.log(f, refresh: true) }
            return out
        }.value
        guard !Task.isCancelled else { return }
        logs = result
        sittings = HistoryReader.sittings(result)
        loading = false
    }

    private func compare(_ s: WorkSitting, chapter: String) {
        guard let f = file(chapter) else { return }
        let old = session.historyReader.text(s.tip.id, f)
        comparing = CompareItem(title: "\(title(chapter)) · \(Self.when(s.tip.date))", left: old, right: session.editorText(of: chapter))
    }

    // MARK: Putting back

    private func restore(_ c: TextChange, chapter: String) {
        if session.selectedChapterID != chapter { app.jump(bookPath: session.root.standardizedFileURL.path, chapterID: chapter) }
        switch TextRestore.undo(c, in: bridge.textView?.string ?? session.text) {
        case .alreadyThere:
            message = L("This text is already there.")
        case .exact(let range, let text):
            put(text, at: range)
        case .choose(let places, let text):
            placing = Placing(places: places, text: text)
        }
    }

    /// Through the editor: ⌘Z takes it back.
    private func put(_ text: String, at range: NSRange) {
        bridge.replace(range, with: text)
        bridge.scroll(to: NSRange(location: range.location, length: (text as NSString).length))
        message = text.isEmpty ? L("Removed.") : L("Put back. ⌘Z to undo.")
    }

    // MARK: Search

    private func search() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        events = []
        guard q.count >= 3 else { return }
        try? await Task.sleep(nanoseconds: 250_000_000)
        guard !Task.isCancelled else { return }
        searching = true
        defer { searching = false }
        let reader = session.historyReader
        for id in chapterIDs.isEmpty ? session.manifest.chapters.map(\.id) : chapterIDs {
            guard let f = file(id) else { continue }
            let found = await Task.detached(priority: .userInitiated) { reader.phrase(q, chapter: id, file: f) }.value
            guard !Task.isCancelled else { return }
            events += found
        }
    }

    private var searchResults: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if searching { ProgressView().controlSize(.small).padding(12) }
                ForEach(events.reversed().prefix(200)) { e in eventRow(e) }
                if !searching && events.isEmpty {
                    Text(query.count < 3 ? L("Three letters at least.") : L("Never written in these chapters."))
                        .font(.ui(12)).foregroundStyle(.secondary).padding(16)
                }
            }
        }
    }

    private func eventRow(_ e: PhraseEvent) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(label(e.kind)).font(.ui(12, .medium)).foregroundStyle(e.kind == .removed ? Ink.removed : .secondary)
                Text("· " + Self.when(e.commit.date)).font(.ui(12)).foregroundStyle(.secondary)
                Spacer()
                Text(title(e.chapter)).font(.ui(11)).foregroundStyle(.tertiary).lineLimit(1)
            }
            Text(e.text).font(.uiMono(12)).lineLimit(4).foregroundStyle(e.kind == .removed ? .secondary : .primary).textSelection(.enabled)
            HStack(spacing: 8) {
                if e.kind == .removed {
                    Button(L("Put Back")) { restore(TextChange(kind: .removed, old: e.text + "\n", new: "", before: e.before, after: e.after, paragraph: 0), chapter: e.chapter) }
                }
                Button(L("Open that day’s text")) {
                    guard let f = file(e.chapter) else { return }
                    comparing = CompareItem(title: "\(title(e.chapter)) · \(Self.when(e.commit.date))", left: session.historyReader.text(e.commit.id, f), right: session.editorText(of: e.chapter))
                }
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func label(_ k: PhraseEvent.Kind) -> String {
        switch k {
        case .written: L("Written")
        case .changed: L("Reworked")
        case .removed: L("Removed", ctx: "Effacée")
        case .restored: L("Back", ctx: "Revenue")
        }
    }

    // MARK: Selection

    private var selectionStates: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if bridge.selectedRange.length == 0 && states.isEmpty {
                    Text(L("Select a passage: its past states show here.")).font(.ui(12)).foregroundStyle(.secondary).padding(16)
                }
                ForEach(Array(states.enumerated()), id: \.offset) { i, s in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(i == 0 ? L("Now") : Self.when(s.commit.date)).font(.ui(12, .medium)).foregroundStyle(.secondary)
                        Text(s.text).font(.uiMono(12)).lineLimit(8).textSelection(.enabled)
                        if i > 0, let r = statesRange {
                            Button(L("Put this one back")) { put(s.text, at: r); statesRange = NSRange(location: r.location, length: (s.text as NSString).length) }.controlSize(.small)
                        }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .overlay(alignment: .bottom) { Divider() }
                }
            }
        }
        .task(id: "\(scope)-\(bridge.selectedRange.location)-\(bridge.selectedRange.length)") { await loadStates() }
    }

    private func loadStates() async {
        guard scope == .selection, bridge.selectedRange.length > 0, let f = session.selectedChapter?.file else { return }
        let ns = (bridge.textView?.string ?? session.text) as NSString
        guard NSMaxRange(bridge.selectedRange) <= ns.length else { return }
        let line = ns.paragraphRange(for: bridge.selectedRange)
        var trimmed = line
        if trimmed.length > 0, ns.substring(with: NSRange(location: NSMaxRange(trimmed) - 1, length: 1)) == "\n" { trimmed.length -= 1 }
        let passage = ns.substring(with: trimmed)
        let reader = session.historyReader
        let found = await Task.detached(priority: .userInitiated) { reader.states(of: passage, file: f) }.value
        guard !Task.isCancelled else { return }
        states = found
        statesRange = trimmed
    }

    static func when(_ d: Date) -> String { d.formatted(date: .abbreviated, time: .shortened) }
}

/// One sitting: its date, what it did, and what can be done from it.
private struct SittingSection: View {
    let sitting: WorkSitting
    let reader: HistoryReader
    let logs: [String: [GitService.Commit]]
    let files: [String: String]
    let titles: [String: String]
    let showChapter: Bool
    let show: HistoryPanel.Show
    let current: String?
    let restore: (TextChange, String) -> Void
    let compare: (String) -> Void
    let bring: () -> Void
    let goBack: () -> Void
    let track: () -> Void
    let milestone: () -> Void
    @State private var changes: [String: [TextChange]] = [:]
    @State private var open = false
    @State private var loaded = false

    private var delta: (added: Int, removed: Int) {
        changes.values.joined().reduce((0, 0)) { acc, c in
            (acc.0 + BookStore.wordCount(c.new), acc.1 + BookStore.wordCount(c.old))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button { withAnimation(.easeOut(duration: 0.14)) { open.toggle() } } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right").font(.ui(9)).rotationEffect(.degrees(open ? 90 : 0)).foregroundStyle(.tertiary)
                        Text(HistoryPanel.when(sitting.tip.date)).font(.ui(12, .semibold))
                        if loaded {
                            let d = delta
                            Text("+\(d.added.ui) −\(d.removed.ui)").font(.ui(11).monospacedDigit()).foregroundStyle(.secondary)
                        }
                        if showChapter { Text(sitting.chapters.count == 1 ? (titles[sitting.chapters[0]] ?? "") : L("\(sitting.chapters.count) chapters")).font(.ui(11)).foregroundStyle(.tertiary).lineLimit(1) }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Menu {
                    Button(L("Bring this sitting…"), action: bring)
                    Button(L("Go Back to This Sitting…"), action: goBack)
                    Button(L("Start a Track from Here…"), action: track)
                    Button(L("Set a Milestone…"), action: milestone)
                } label: { Image(systemName: "ellipsis").font(.ui(12)).frame(width: 22, height: 22) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel(L("What to do from this sitting"))
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            if open {
                ForEach(sitting.chapters, id: \.self) { ch in
                    let list = (changes[ch] ?? []).filter(show.keeps)
                    if showChapter && !list.isEmpty {
                        Button(titles[ch] ?? ch) { compare(ch) }.buttonStyle(.plain).font(.ui(11, .medium)).foregroundStyle(.secondary).padding(.horizontal, 14).padding(.top, 4)
                    }
                    ForEach(list) { c in ChangeRow(change: c) { restore(c, ch) } }
                }
                if loaded && changes.values.allSatisfy({ $0.filter(show.keeps).isEmpty }) {
                    Text(L("No change of this kind.")).font(.ui(12)).foregroundStyle(.secondary).padding(.horizontal, 14).padding(.bottom, 8)
                }
            }
            Divider()
        }
        .task(id: open) {
            guard open, !loaded else { return }
            await load()
        }
    }

    private func load() async {
        let reader = reader, sitting = sitting, files = files, logs = logs
        let out = await Task.detached(priority: .userInitiated) { () -> [String: [TextChange]] in
            var r: [String: [TextChange]] = [:]
            for ch in sitting.chapters { if let f = files[ch], let log = logs[ch] { r[ch] = reader.changes(in: sitting, file: f, log: log) } }
            return r
        }.value
        guard !Task.isCancelled else { return }
        changes = out
        loaded = true
    }
}

private struct ChangeRow: View {
    let change: TextChange
    let restore: () -> Void
    @State private var hovered = false

    private var mark: (String, Color) {
        switch change.kind {
        case .removed: ("−", Ink.removed)
        case .added: ("+", Ink.added)
        case .modified: ("~", Ink.accent)
        }
    }
    private var action: String {
        switch change.kind {
        case .removed: L("Put Back")
        case .added: L("Remove")
        case .modified: L("Put the old one back")
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(mark.0).font(.ui(13, .semibold)).foregroundStyle(mark.1).frame(width: 12)
            VStack(alignment: .leading, spacing: 3) {
                content.font(.uiMono(12)).lineLimit(6).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                if change.kind == .removed, !change.before.isEmpty || !change.after.isEmpty {
                    Text(L("between « …\(tail) » and « \(head)… »")).font(.ui(11)).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            Button(action, action: restore).controlSize(.small).opacity(hovered ? 1 : 0.65)
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
        .background(hovered ? Ink.panel : .clear)
        .onHover { hovered = $0 }
    }

    private var tail: String { String(change.before.trimmingCharacters(in: .whitespacesAndNewlines).suffix(18)) }
    private var head: String { String(change.after.trimmingCharacters(in: .whitespacesAndNewlines).prefix(18)) }

    private var content: Text {
        let old = change.old.trimmingCharacters(in: .whitespacesAndNewlines), new = change.new.trimmingCharacters(in: .whitespacesAndNewlines)
        switch change.kind {
        case .removed: return Text(old).foregroundColor(Ink.removed).strikethrough()
        case .added: return Text(new).foregroundColor(Ink.added)
        case .modified: return Text(old).foregroundColor(Ink.removed).strikethrough() + Text(" ") + Text(new).foregroundColor(Ink.added)
        }
    }
}

/// « Remettre » when the text around has changed: Musset shows where, the author chooses.
struct PlacementSheet: View {
    let places: [TextRestore.Place]
    let text: String
    let choose: (TextRestore.Place) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var picked: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("Where should it go back?")).font(.ui(16, .semibold))
            Text(L("The text around it has changed since.")).font(.ui(12)).foregroundStyle(.secondary)
            Text(text.trimmingCharacters(in: .whitespacesAndNewlines)).font(.uiMono(12)).lineLimit(5).padding(10).frame(maxWidth: .infinity, alignment: .leading).background(Ink.panel, in: RoundedRectangle(cornerRadius: Radius.control))
            ForEach(places) { p in
                Button { picked = p.id } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: picked == p.id ? "largecircle.fill.circle" : "circle").font(.ui(13)).foregroundStyle(picked == p.id ? Ink.accent : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.hint).font(.ui(13))
                            if !p.excerpt.isEmpty { Text(p.excerpt).font(.uiMono(11)).foregroundStyle(.secondary).lineLimit(2) }
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            HStack {
                Spacer()
                Button(L("Cancel")) { dismiss() }.buttonStyle(.inkSecondary).keyboardShortcut(.cancelAction)
                Button(L("Put it here")) {
                    if let p = places.first(where: { $0.id == picked }) { choose(p) }
                    dismiss()
                }
                .buttonStyle(.ink).disabled(picked == nil)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear { picked = places.first?.id }
    }
}

/// « Revenir à ce point » : nothing is erased, the old text becomes the newest one.
struct GoBackSheet: View {
    let session: BookSession
    let sitting: WorkSitting
    let chapterIDs: [String]
    @Environment(\.dismiss) private var dismiss
    @State private var scope = 0
    @State private var compare: CompareItem?

    private var options: [(id: Int, label: String, ids: [String], order: Bool)] {
        var out: [(Int, String, [String], Bool)] = []
        if let ch = session.selectedChapter { out.append((0, ch.title, [ch.id], false)) }
        if chapterIDs.count > 1 && chapterIDs.count < session.manifest.chapters.count { out.append((1, L("The \(chapterIDs.count) ticked chapters"), chapterIDs, false)) }
        out.append((2, L("The whole manuscript and the order of the chapters"), session.manifest.chapters.map(\.id), true))
        return out
    }
    private var label: String { HistoryPanel.when(sitting.tip.date) }
    private var chosen: (id: Int, label: String, ids: [String], order: Bool)? { options.first { $0.id == scope } ?? options.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("Go back to \(label)?")).font(.ui(18, .semibold))
            Text(L("Today’s text stays in the history and can come back at any time.")).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                Text(L("What comes back")).font(.ui(12, .medium)).foregroundStyle(.secondary)
                ForEach(options, id: \.id) { o in
                    Button { scope = o.id } label: {
                        HStack(spacing: 8) {
                            Image(systemName: chosen?.id == o.id ? "largecircle.fill.circle" : "circle").foregroundStyle(chosen?.id == o.id ? Ink.accent : .secondary)
                            Text(o.label)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            if let c = chosen {
                let p = session.goBackPreview(to: sitting.tip.id, chapters: c.ids)
                Text(L("\(p.chapters) chapters change,") + " " + L("\(p.words >= 0 ? "+" : "−")\(abs(p.words).ui) words."))
                    .font(.ui(12))
                Text(L("A milestone is set first. Notes, the Bible and settings don’t move.") + (p.lostNotes > 0 ? " " + L("\(p.lostNotes) notes may lose their passage.") : ""))
                    .font(.ui(12)).foregroundStyle(.secondary)
            }
            HStack {
                if let ch = session.selectedChapter {
                    Button(L("See the differences…")) {
                        compare = CompareItem(title: ch.title, left: session.historyReader.text(sitting.tip.id, ch.file), right: session.editorText(of: ch.id))
                    }
                    .buttonStyle(.inkSecondary)
                }
                Spacer()
                Button(L("Cancel")) { dismiss() }.buttonStyle(.inkSecondary).keyboardShortcut(.cancelAction)
                Button(L("Go Back to This Sitting…").titled) {
                    if let c = chosen { session.goBack(to: sitting.tip.id, label: label, chapters: c.ids, order: c.order) }
                    dismiss()
                }
                .buttonStyle(.ink)
            }
        }
        .padding(24)
        .frame(width: 600)
        .sheet(item: $compare) { CompareView(item: $0) }
    }
}
