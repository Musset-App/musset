import SwiftUI

/// First open of a folder: confirm which files are chapters, and whether to start git.
struct SetupSheet: View {
    let app: AppState
    @State var setup: AppState.PendingSetup
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("Open “\(setup.root.lastPathComponent)”")).font(.ui(17))
            Text(L("Musset found these chapters. Only they will appear in the app; nothing else in the folder is shown or touched. You can reorder later by dragging."))
                .font(.ui(12)).foregroundStyle(.secondary)
            HStack {
                TextField(L("Title"), text: $setup.manifest.title)
                BookLanguagePicker(code: $setup.manifest.lang)
            }
            List {
                ForEach(setup.manifest.chapters) { ch in
                    HStack {
                        Text(ch.title)
                        Spacer()
                        Text(ch.file).font(.ui(11)).foregroundStyle(.secondary)
                    }
                }
                .onDelete { setup.manifest.chapters.remove(atOffsets: $0) }
                .onMove { setup.manifest.chapters.move(fromOffsets: $0, toOffset: $1) }
            }
            .frame(minHeight: 300)
            if setup.manifest.chapters.isEmpty {
                Text(L("No chapters detected. You can add them from the sidebar after opening.")).font(.ui(11)).foregroundStyle(Ink.warning)
            }
            if setup.isRepo {
                Label(L("This folder already keeps a history. Musset will save the chapters in it before writing anything."), systemImage: "checkmark.seal")
                    .font(.ui(12)).foregroundStyle(.secondary)
            } else {
                Toggle(L("Keep this book’s history (recommended: needed for versions, tracks and milestones)"), isOn: $setup.initGit)
            }
            HStack {
                Spacer()
                Button(L("Cancel")) { app.cancelSetup(); dismiss() }
                Button(L("Open Book")) { app.completeSetup(setup); dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 640)
    }
}

struct QuickOpenView: View {
    let app: AppState
    @State private var query = ""
    @State private var index = 0
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    private var results: [(bookPath: String, bookTitle: String, chapter: ChapterEntry)] {
        let all = app.allChapters()
        let q = query.folded
        guard !q.isEmpty else { return Array(all.prefix(60)) }
        return all.filter {
            "\($0.bookTitle) \($0.chapter.title) \($0.chapter.id)".folded.localizedStandardContains(q)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField(app.current?.words.jumpToPiece ?? L("Jump to chapter…"), text: $query)
                .textFieldStyle(.plain)
                .font(.ui(15))
                .padding(14)
                .focused($focused)
                .onSubmit(openSelected)
                .onKeyPress(.downArrow) { index = min(index + 1, max(0, results.count - 1)); return .handled }
                .onKeyPress(.upArrow) { index = max(index - 1, 0); return .handled }
                .onKeyPress(.escape) { dismiss(); return .handled }
                .onChange(of: query) { _, _ in index = 0 }
            Divider()
            ScrollViewReader { proxy in
                List(Array(results.enumerated()), id: \.offset) { i, r in
                    HStack {
                        Text(r.chapter.title)
                        Spacer()
                        Text(r.bookTitle).font(.ui(11)).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                    .listRowBackground(i == index ? Ink.accent.opacity(0.18) : Color.clear)
                    .contentShape(Rectangle())
                    .onTapGesture { index = i; openSelected() }
                    .id(i)
                }
                .onChange(of: index) { _, i in proxy.scrollTo(i) }
            }
        }
        .frame(width: 520, height: 420)
        .onAppear { focused = true }
    }

    private func openSelected() {
        let r = results
        guard r.indices.contains(index) else { return }
        app.jump(bookPath: r[index].bookPath, chapterID: r[index].chapter.id)
        dismiss()
    }
}

struct ExportSheet: View {
    @Bindable var session: BookSession
    /// Opens the book in reading mode.
    var preview: (() -> Void)? = nil
    /// The book as it was at a milestone, instead of today's.
    var at: GitService.Tag? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var selected: String = ""
    @State private var running = false
    @State private var message: String?
    @State private var lastFile: URL?
    @State private var scope = Scope.book.rawValue
    @State private var statusList = "edited,final"
    @State private var picked: Set<String> = []
    @State private var specials: Set<SpecialPage> = []
    @State private var format: ExportFormat = .pdf
    /// The layout last used for each format, so going PDF → Word → PDF comes back to it.
    @State private var layouts: [String: String] = [:]
    @State private var facing = false

    typealias Scope = ChapterScopeMode

    private var statuses: Set<ChapterStatus> { Set(statusList.split(separator: ",").compactMap { ChapterStatus(rawValue: String($0)) }) }

    /// The chapters this export holds, in book order.
    private var chosen: [ChapterEntry] { ChapterScopePicker.chapters(session.manifest, scope: scope, statusList: statusList, picked: picked) }

    /// Every layout of the book (Musset's own and the author's), and those of the format chosen.
    private var allLayouts: [ExportPreset] { session.store.presets(session.manifest) }
    private var presets: [ExportPreset] { allLayouts.filter { $0.format == format } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Text(L("Export…").titled).font(.system(size: 26, design: .serif))
                if let source = sourceName {
                    Label(source, systemImage: at == nil ? "arrow.triangle.branch" : "flag")
                        .font(.ui(12)).foregroundStyle(at == nil ? Ink.piste : Ink.jalon).lineLimit(1)
                }
                Spacer()
                Segmented(options: ExportFormat.allCases.map { ($0, $0.rawValue.uppercased()) }, selection: $format).frame(width: 210)
            }
            .padding(.horizontal, 28).padding(.top, 22).padding(.bottom, 14)
            Divider()
            HStack(alignment: .top, spacing: 0) {
                contents.padding(.horizontal, 28).padding(.vertical, 20).frame(maxWidth: .infinity, alignment: .topLeading)
                Divider()
                layout.padding(.horizontal, 28).padding(.vertical, 20).frame(width: 300, alignment: .topLeading)
            }
            .frame(height: 430)
            if let message {
                ScrollView { Text(message).font(.uiMono(11)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: 70).padding(.horizontal, 28).padding(.vertical, 8)
            }
            Divider()
            HStack(spacing: 8) {
                Text(summary).monospacedDigit()
                if let lastFile {
                    Button(L("Open")) { NSWorkspace.shared.open(lastFile) }.buttonStyle(.link)
                    Button(L("Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([lastFile]) }.buttonStyle(.link)
                }
                Spacer()
                if running { ProgressView().controlSize(.small) }
                Button(L("Close")) { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(.inkSecondary)
                if let preview { Button(L("Preview")) { dismiss(); preview() }.buttonStyle(.inkSecondary) }
                Button(L("Export \(format.rawValue.uppercased())")) { Task { await run() } }
                    .buttonStyle(.ink)
                    .keyboardShortcut(.defaultAction)
                    .disabled(running || selected.isEmpty || chosen.isEmpty)
            }
            .padding(.horizontal, 28).padding(.vertical, 14)
            .background(Ink.side)
        }
        .frame(width: 780)
        .onAppear(perform: restore)
        .onChange(of: format) { _, _ in pickPreset() }
        .onChange(of: selected) { _, id in
            if !id.isEmpty { layouts[format.rawValue] = id }
            // Each edition comes with its own pages: single for readers, facing for the printer.
            if let f = allLayouts.first(where: { $0.id == id })?.facing { facing = f }
        }
    }

    private var contents: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(L("Contents", ctx: "Contenu"))
            ChapterScopePicker(session: session, scope: $scope, statusList: $statusList, picked: $picked, pickHint: L("For a reader, a submission…"))
        }
    }

    private var layout: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(L("Layout"))
                Picker("", selection: $selected) {
                    ForEach(presets) { p in
                        Text([p.shownName, p.paper?.label].compactMap { $0 }.joined(separator: " · ")).tag(p.id)
                    }
                }
                .labelsHidden()
                if let chosen = presets.first(where: { $0.id == selected }), chosen.manuscript != nil {
                    TextField(L("Pseudonym (prizes)"), text: Binding(get: { chosen.pseudonym ?? "" },
                                                                    set: { session.manifest.setPseudonym($0.isEmpty ? nil : $0, for: chosen.id); session.saveManifest() }))
                        .textFieldStyle(.roundedBorder).frame(width: 180)
                        .help(L("For a literary prize: the manuscript carries this pseudonym instead of your name and contact."))
                } else if format == .pdf {
                    Segmented(options: [(false, L("Single pages")), (true, L("Facing pages"))], selection: $facing)
                        .help(L("Single pages: the same margin left and right, for a manuscript or reading on screen. Facing pages: a printed book, the wider margin at the spine, parts on a right-hand page."))
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel(L("Special pages"))
                ForEach([SpecialPage.cover, .title, .dedication, .epigraph, .contents, .acknowledgements]) { page in
                    Toggle(page.label, isOn: Binding(get: { specials.contains(page) }, set: { if $0 { specials.insert(page) } else { specials.remove(page) } }))
                        .toggleStyle(.checkbox)
                        .disabled(!available(page))
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(L("Between scenes"))
                Segmented(options: SceneBreak.allCases.map { ($0, $0.localizedLabel) },
                          selection: Binding(get: { session.manifest.sceneBreak ?? .none }, set: { session.manifest.sceneBreak = $0 == .none ? nil : $0; session.saveManifest() }))
            }
            Text(L("Author’s notes (<!-- -->), margin notes and scene markers are never exported."))
                .font(.ui(11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// A page with nothing in it (an empty dedication) cannot be printed.
    private func available(_ page: SpecialPage) -> Bool {
        let f = session.manifest.front ?? FrontMatter()
        switch page {
        case .dedication: return !(f.dedication ?? "").isEmpty
        case .epigraph: return !(f.epigraph ?? "").isEmpty
        case .acknowledgements: return !(f.acknowledgements ?? "").isEmpty
        default: return true
        }
    }

    private var summary: String {
        let counts = chosen.reduce(TextCounts.zero) { $0 + (session.chapterCounts[$1.id] ?? .zero) }
        let n = chosen.count
        return session.words.count(n, .piece) + " · " + counts.label
            + (format == .pdf ? " · ~" + L("\(max(1, counts.words / 260)) pages") : "")
    }

    private func pickPreset() {
        if let last = layouts[format.rawValue], presets.contains(where: { $0.id == last }) { selected = last }
        if !presets.contains(where: { $0.id == selected }) { selected = presets.first?.id ?? "" }
    }

    /// The last export's choices; the first time, the book's special pages, without the made-up cover.
    private func restore() {
        let ids = Set(session.manifest.chapters.map(\.id))
        if let c = session.state.export {
            format = ExportFormat(rawValue: c.format) ?? .pdf
            layouts = c.layouts
            scope = c.scope.rawValue
            statusList = c.statuses
            picked = Set(c.picked).intersection(ids)
            specials = Set(c.specials.compactMap(SpecialPage.init(rawValue:)))
            facing = c.facing ?? false
        } else {
            let f = session.manifest.front ?? FrontMatter()
            specials = Set(SpecialPage.allCases.filter { $0 != .cover && f.has($0) })
        }
        if picked.isEmpty { picked = Set(session.selectedChapterID.map { [$0] } ?? []) }
        pickPreset()
    }

    private func remember() {
        session.state.export = ExportChoice(format: format.rawValue, layouts: layouts, scope: Scope(rawValue: scope) ?? .book, statuses: statusList,
                                            picked: session.manifest.chapters.map(\.id).filter(picked.contains), specials: specials.map(\.rawValue).sorted(), facing: facing)
        session.stateChanged()
    }

    /// What the file name says is in it: nothing for the whole book, the statuses, or the chapters.
    private var contentsName: String? {
        switch Scope(rawValue: scope) ?? .book {
        case .book: return nil
        case .status: return ChapterStatus.allCases.filter(statuses.contains).map(\.label).joined(separator: "-")
        case .pick:
            let titles = chosen.map(\.title)
            if titles.count <= 3 { return titles.joined(separator: "-") }
            let all = session.manifest.chapters.map(\.id)
            return L("CH") + chosen.compactMap { all.firstIndex(of: $0.id) }.map(String.init).joined(separator: "-")
        }
    }

    /// What is exported when it isn't the manuscript today: a milestone, or the track one writes in.
    private var sourceName: String? {
        if let at { return L("as at « \(at.title) »") }
        return session.piste.map { L("the track « \($0.name) »") }
    }

    private func run() async {
        guard var preset = allLayouts.first(where: { $0.id == selected }) else { return }
        preset.facing = facing
        session.flushSave()
        session.saveManifest()
        remember()
        // This export's book: the chosen chapters, and only the special pages ticked here.
        var m = session.manifest
        m.chapters = chosen.map { var c = $0; c.excludeFromExport = false; return c }
        var f = m.front ?? FrontMatter()
        if specials.contains(.cover) { if f.cover == nil { f.cover = FrontMatter.Cover() }; f.cover?.inPDF = true } else { f.cover?.inPDF = false }
        // The printer's interior never holds the cover: it is printed apart, on the cover stock.
        if preset.interior == true { f.cover?.inPDF = false }
        f.titlePage = specials.contains(.title)
        if !specials.contains(.dedication) { f.dedication = nil }
        if !specials.contains(.epigraph) { f.epigraph = nil }
        f.contents = specials.contains(.contents)
        if !specials.contains(.acknowledgements) { f.acknowledgements = nil }
        m.front = f
        running = true; message = nil
        defer { running = false }
        do {
            var store = session.store
            if let at {
                store.revision = at.commit
                store.revisionName = at.title
            } else if let p = session.piste {
                // A track exports as written in it: its chapters, committed first.
                session.commitNow(session.editMessage)
                store.revision = p.branch
                store.revisionName = p.name
            }
            let out = try await ExportService.export(manifest: m, store: store, preset: preset, contents: contentsName)
            lastFile = out.file
            message = L("Saved \(out.file.lastPathComponent)")
            NSWorkspace.shared.activateFileViewerSelecting([out.file])
        } catch {
            message = error.localizedDescription
        }
    }
}
