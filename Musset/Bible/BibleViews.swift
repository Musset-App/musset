import SwiftUI
import UniformTypeIdentifiers

extension BookSession {
    /// Counts the sheets' names in the chapters. Called when the Bible is opened and when a sheet changes.
    func refreshBibleMentions() {
        bible.setFoundAliases(keeper.facts.entities.mapValues(\.aliases))
        bible.refreshMentions(chapters: manifest.chapters.map { ($0.id, editorText(of: $0.id)) }, plot: plot)
    }

    /// A passage cut from a chapter goes to the Cuts folder, with where it came from.
    func keepCut(_ text: String, before: String) {
        guard let chapter = selectedChapterID else { return }
        let words = text.split(whereSeparator: { $0.isWhitespace }).prefix(7).joined(separator: " ")
        try? bible.create(title: words, kind: .cut, body: ParagraphCodec.encode(text),
                          meta: ["from": chapter, "context": String(before.suffix(60)).replacingOccurrences(of: "\n", with: " "), "date": ISO8601DateFormatter().string(from: Date())])
        pendingCommit = true
    }

    /// Puts a cut back where it came from: after what preceded it, else at the caret.
    func restore(_ cut: BibleEntry, bridge: EditorBridge) {
        guard let chapter = cut.meta["from"], manifest.chapters.contains(where: { $0.id == chapter }) else { return }
        let text = ParagraphCodec.decode(cut.body)
        let insert = { [weak self] in
            guard let self, let tv = bridge.textView else { return }
            let ns = tv.string as NSString
            let context = cut.meta["context"] ?? ""
            var at = tv.selectedRange().location
            if !context.isEmpty {
                let found = ns.range(of: context)
                if found.location != NSNotFound { at = found.location + found.length }
            }
            bridge.replace(NSRange(location: at, length: 0), with: text)
            bridge.scroll(to: NSRange(location: at, length: (text as NSString).length))
            try? self.bible.trash(cut.path)
        }
        if chapter == selectedChapterID { insert() } else {
            open(chapter)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: insert)
        }
    }
}

// MARK: Sidebar

/// The Bible in the sidebar: a tree of folders, any depth, with what is in them, and the characters of the grid
/// without a sheet yet. Folders and entries move by drag or by their menu, as in a code editor's file tree.
struct BibleSidebarSection: View {
    let app: AppState
    @Bindable var session: BookSession
    let bridge: EditorBridge
    @State private var open: Set<String> = ["personnages", "personnages#main"]
    @State private var naming: Naming?
    @State private var name = ""
    @State private var deleting: String?
    @State private var target: String?

    /// What the name field is for.
    private enum Naming: Equatable {
        case newFolder(in: String)
        case rename(String)
    }

    private enum Row: Identifiable {
        case folder(String, depth: Int)
        case entry(BibleEntry, depth: Int)
        case tag(PlotGrid.Tag, depth: Int)
        /// Main, secondary or extras, inside Characters or Places: computed, not a folder.
        case tier(folder: String, NameTier, count: Int, depth: Int)

        var id: String {
            switch self {
            case .folder(let path, _): "f|" + path
            case .entry(let e, _): "e|" + e.path
            case .tag(let t, _): "t|" + t.name
            case .tier(let folder, let tier, _, _): "r|" + folder + "#" + tier.rawValue
            }
        }
    }

    /// The folders whose sheets are grouped by how much they're in the book.
    private static let tiered: Set<String> = ["personnages", "lieux"]

    private var bible: BibleModel { session.bible }

    /// Drafts have their own section, at the foot of the sidebar.
    private var folders: [String] { bible.folders.filter { !BibleStore.isInside($0, BibleKind.draft.folder) } }

    /// Folders first, then what they hold, as a file tree shows them.
    private var rows: [Row] {
        var out: [Row] = []
        func walk(_ parent: String, depth: Int) {
            for folder in BibleStore.children(of: parent, in: folders) {
                out.append(.folder(folder, depth: depth))
                guard open.contains(folder) else { continue }
                walk(folder, depth: depth + 1)
                let tags = folder == "personnages" ? bible.tagsWithoutSheet(session.plot) : []
                if Self.tiered.contains(folder) {
                    let here = bible.entries(in: folder)
                    let tracked = here.filter { BibleModel.trackedKinds.contains($0.kind) }
                    for tier in NameTier.allCases {
                        // Sheets and grid characters together, most present first, then by name: an order that holds.
                        let rows: [(Int, String, Row)] = tracked.filter { bible.tier(of: $0) == tier }.map { (bible.presence($0.path), $0.title, .entry($0, depth: depth + 2)) }
                            + tags.filter { bible.tier(of: $0) == tier }.map { (bible.presence(of: $0), $0.name, .tag($0, depth: depth + 2)) }
                        guard !rows.isEmpty else { continue }
                        out.append(.tier(folder: folder, tier, count: rows.count, depth: depth + 1))
                        guard open.contains(folder + "#" + tier.rawValue) else { continue }
                        out += rows.sorted { $0.0 != $1.0 ? $0.0 > $1.0 : $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }.map(\.2)
                    }
                    out += here.filter { !BibleModel.trackedKinds.contains($0.kind) }.map { .entry($0, depth: depth + 1) }
                } else {
                    out += bible.entries(in: folder).map { .entry($0, depth: depth + 1) }
                }
            }
        }
        walk("", depth: 0)
        return out
    }

    var body: some View {
        header
        let sources = bible.entries.filter { $0.kind == .reference }.count
        SidebarRowView(active: app.activeTab == .sources) {
            Image(systemName: "books.vertical").font(.ui(11)).foregroundStyle(.tertiary).frame(width: 14)
            Text(L("Sources")).lineLimit(1)
            Spacer(minLength: 4)
            if sources > 0 { Text("\(sources)").font(.ui(11).monospacedDigit()).foregroundStyle(.tertiary) }
        }
        .padding(.leading, 4)
        .contentShape(Rectangle())
        .onTapGesture { app.open(clicked: .sources) }
        .rowButton(L("Sources"), selected: app.activeTab == .sources)
        .contextMenu { OpenElsewhere(tab: .sources, app: app, session: session) }
        .sidebarRow()
        ForEach(rows) { row in
            switch row {
            case .folder(let path, let depth): folderRow(path, depth: depth)
            case .entry(let e, let depth): entryRow(e, depth: depth)
            case .tag(let tag, let depth): tagRow(tag, depth: depth)
            case .tier(let folder, let tier, let count, let depth): tierRow(folder, tier, count: count, depth: depth)
            }
        }
    }

    private func tierRow(_ folder: String, _ tier: NameTier, count: Int, depth: Int) -> some View {
        let key = folder + "#" + tier.rawValue
        return SidebarRowView(active: false) {
            Image(systemName: open.contains(key) ? "chevron.down" : "chevron.right").font(.ui(8)).foregroundStyle(.tertiary).frame(width: 14, height: 20)
            Text(tier.label).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 4)
            Text("\(count)").font(.ui(11).monospacedDigit()).foregroundStyle(.tertiary)
        }
        .padding(.leading, CGFloat(depth) * 12)
        .contentShape(Rectangle())
        .onTapGesture { if open.contains(key) { open.remove(key) } else { open.insert(key) } }
        .rowButton(tier.label)
        .help(tier == .extra ? L("In one chapter only. They move up on their own the day they appear in a second.") : "")
        .sidebarRow()
    }

    private func targeted(_ folder: String) -> Binding<Bool> {
        Binding(get: { target == folder }, set: { on in
            if on { target = folder } else if target == folder { target = nil }
        })
    }

    private var namingShown: Binding<Bool> { Binding(get: { naming != nil }, set: { if !$0 { naming = nil } }) }
    private var deletingShown: Binding<Bool> { Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }) }

    private var header: some View {
        HStack {
            Text(L("Bible")).font(.ui(11, .medium)).foregroundStyle(.secondary)
            Spacer()
            Menu {
                newEntryButtons(in: nil)
                Button(L("New board")) { newBoard() }
                Divider()
                Button(L("New Folder…")) { ask(.newFolder(in: "")) }
            } label: { Image(systemName: "plus").font(.ui(11)) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help(L("New Sheet")).accessibilityLabel(L("New Sheet"))
        }
        .padding(.horizontal, 8).padding(.top, 12).padding(.bottom, 4)
        .background { if target == "" { RoundedRectangle(cornerRadius: Radius.row).fill(Ink.accent.opacity(0.12)) } }
        .onDrop(of: [.text], isTargeted: targeted("")) { providers in
            receive(providers, in: "")
        }
        .contextMenu { Button(L("New Folder…")) { ask(.newFolder(in: "")) } }
        .sidebarRow()
        .alert(naming.map(title) ?? "", isPresented: namingShown) {
            TextField(L("Name"), text: $name)
            Button(L("OK")) { commitName() }
            Button(L("Cancel"), role: .cancel) { naming = nil }
        }
        .confirmationDialog(deleting.map { L("Delete « \(BibleStore.folderLabel($0)) »?") } ?? "",
                            isPresented: deletingShown) {
            Button(L("Delete"), role: .destructive) { deleteFolder() }
        } message: {
            Text(deleting.map(deleteMessage) ?? "")
        }
    }

    private func deleteFolder() {
        if let path = deleting, session.deleteBibleFolder(path) {
            open = open.filter { !BibleStore.isInside($0, path) }
            if let shown = app.activeTab?.biblePath, BibleStore.isInside(shown, path) { app.showChapter() }
        }
        deleting = nil
    }

    // MARK: Rows

    private func folderRow(_ folder: String, depth: Int) -> some View {
        let system = BibleStore.isSystem(folder)
        let count = bible.entries(in: folder).count + (folder == "personnages" ? bible.tagsWithoutSheet(session.plot).count : 0)
        return SidebarRowView(active: app.activeTab == .folder(folder)) {
            Button {
                if open.contains(folder) { open.remove(folder) } else { open.insert(folder) }
            } label: {
                Image(systemName: open.contains(folder) ? "chevron.down" : "chevron.right").font(.ui(8)).foregroundStyle(.tertiary).frame(width: 14, height: 20).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(open.contains(folder) ? L("Close folder") : L("Open folder"))
            Text(BibleStore.folderLabel(folder)).lineLimit(1).truncationMode(.middle)
            if system {
                Image(systemName: "gearshape").font(.ui(9)).foregroundStyle(.tertiary)
                    .help(L("System folder: Musset files sheets here, so it can’t be renamed, moved or deleted. It takes anything you put in it."))
                    .accessibilityLabel(L("System folder"))
            }
            Spacer(minLength: 4)
            if count > 0 { Text("\(count)").font(.ui(11).monospacedDigit()).foregroundStyle(.tertiary) }
        }
        .padding(.leading, CGFloat(depth) * 12)
        .background { if target == folder { RoundedRectangle(cornerRadius: Radius.row).fill(Ink.accent.opacity(0.12)) } }
        .contentShape(Rectangle())
        .onTapGesture { app.open(clicked: .folder(folder)) }
        // One element for VoiceOver: pressing it opens the folder's page; unfolding it is one of its actions.
        .rowButton(BibleStore.folderLabel(folder), selected: app.activeTab == .folder(folder))
        .accessibilityAction(.default) { app.open(.folder(folder)) }
        .accessibilityAction(named: open.contains(folder) ? L("Close folder") : L("Open folder")) {
            if open.contains(folder) { open.remove(folder) } else { open.insert(folder) }
        }
        .shelfDraggable(system ? nil : .folder(folder), title: BibleStore.folderLabel(folder))
        .onDrop(of: [.fileURL, .text], isTargeted: targeted(folder)) { providers in
            receive(providers, in: folder)
        }
        .contextMenu { folderMenu(folder, system: system) }
        .sidebarRow()
    }

    private func entryRow(_ e: BibleEntry, depth: Int) -> some View {
        SidebarRowView(active: app.activeTab == .sheet(e.path)) {
            Image(systemName: e.kind.icon).font(.ui(11)).foregroundStyle(.tertiary).frame(width: 14)
            Text(e.title).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.leading, CGFloat(depth) * 12 + 4)
        .contentShape(Rectangle())
        .onTapGesture { app.open(clicked: .sheet(e.path)) }
        .rowButton(e.title, selected: app.activeTab == .sheet(e.path))
        .shelfDraggable(.sheet(e.path), title: e.title)
        .contextMenu {
            Button(L("Open")) { app.open(.sheet(e.path)) }
            OpenElsewhere(tab: .sheet(e.path), app: app, session: session)
            if BibleModel.trackedKinds.contains(e.kind) { Button(L("Rename…")) { app.renaming = .init(path: e.path) } }
            moveMenu(excluding: [e.folder]) { session.moveBibleEntry(e.path, toFolder: $0).map { moved(e.path, to: $0) } }
            Divider()
            Button(L("Reveal in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([bible.store.url(e.path)]) }
            Button(L("Copy Path")) { copy(BibleStore.folderName + "/" + e.path) }
            Divider()
            Button(L("Move to Trash"), role: .destructive) {
                if e.isFile { try? bible.trash(e.path) } else { _ = session.drop([ShelfDrag.sheet(e.path).wire], on: .trash) }
                if app.activeTab == .sheet(e.path) { app.showChapter() }
            }
        }
        .sidebarRow()
    }

    private func tagRow(_ tag: PlotGrid.Tag, depth: Int) -> some View {
        SidebarRowView(active: false) {
            Image(systemName: "person").font(.ui(11)).foregroundStyle(.tertiary).frame(width: 14)
            Text(tag.name).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.leading, CGFloat(depth) * 12 + 4)
        .contentShape(Rectangle())
        .onTapGesture { if let e = try? bible.sheet(for: tag) { app.open(.sheet(e.path)) } }
        .rowButton(tag.name)
        .help(L("In the plot grid. Click to give it a sheet."))
        .sidebarRow()
    }

    // MARK: Menus

    @ViewBuilder
    private func folderMenu(_ folder: String, system: Bool) -> some View {
        OpenElsewhere(tab: .folder(folder), app: app, session: session)
        Divider()
        Menu(L("New Sheet")) { newEntryButtons(in: folder) }
        if folder == BibleKind.board.folder { Button(L("New board")) { newBoard() } }
        Button(L("New Folder…")) { ask(.newFolder(in: folder)) }
        Divider()
        Button(L("Rename…")) { ask(.rename(folder)) }.disabled(system)
        if !system {
            moveMenu(excluding: [BibleStore.parent(of: folder)], within: folder, top: BibleStore.parent(of: folder) != "") { parent in
                session.moveBibleFolder(folder, into: parent).map { moved(folder, to: $0) }
            }
        }
        Divider()
        Button(L("Reveal in Finder")) {
            try? FileManager.default.createDirectory(at: bible.store.url(folder), withIntermediateDirectories: true)
            NSWorkspace.shared.activateFileViewerSelecting([bible.store.url(folder)])
        }
        Button(L("Copy Path")) { copy(BibleStore.folderName + "/" + folder) }
        Divider()
        Button(L("Delete…"), role: .destructive) { deleting = folder }.disabled(system)
    }

    /// Every folder something can go to. A folder never goes inside itself.
    @ViewBuilder
    private func moveMenu(excluding: [String], within moving: String? = nil, top: Bool = false, to perform: @escaping (String) -> Void) -> some View {
        Menu(L("Move To")) {
            if top { Button(L("Top of the Bible")) { perform("") } }
            ForEach(folders.filter { f in !excluding.contains(f) && !(moving.map { BibleStore.isInside(f, $0) } ?? false) }, id: \.self) { f in
                Button(String(repeating: "    ", count: f.filter { $0 == "/" }.count) + BibleStore.folderLabel(f)) { perform(f) }
            }
        }
    }

    @ViewBuilder
    private func newEntryButtons(in folder: String?) -> some View {
        ForEach([BibleKind.character, .place, .event, .biography, .note, .reference]) { kind in
            Button(kind.label) { create(kind, in: folder) }
        }
    }

    // MARK: Actions

    private func title(_ n: Naming) -> String {
        switch n {
        case .newFolder(let parent): parent.isEmpty ? L("New Folder…").titled : L("New folder in « \(BibleStore.folderLabel(parent)) »")
        case .rename(let path): L("Rename « \(BibleStore.folderLabel(path)) »…").titled
        }
    }

    private func ask(_ n: Naming) {
        if case .rename(let path) = n { name = BibleStore.folderLabel(path) } else { name = "" }
        naming = n
    }

    private func commitName() {
        defer { naming = nil }
        switch naming {
        case .newFolder(let parent):
            guard let path = session.newBibleFolder(named: name, in: parent) else { return }
            if !parent.isEmpty { open.insert(parent) }
            open.insert(path)
        case .rename(let path):
            if let new = session.renameBibleFolder(path, to: name) { moved(path, to: new) }
        case nil: break
        }
    }

    private func deleteMessage(_ folder: String) -> String {
        let inside = bible.entries.filter { BibleStore.isInside($0.folder, folder) }
        let sheets = inside.filter { !$0.isFile }.count, files = inside.count - sheets
        return L("\(sheets) sheets go to the book’s Trash,") + " " + L("\(files) files and the folder to the Finder’s Trash.")
    }

    /// Open folders follow what moved (the tabs are the session's to move).
    private func moved(_ old: String, to new: String) {
        open = Set(open.map { BookSession.retarget($0, from: old, to: new) })
        open.insert(BibleStore.parent(of: new))
    }

    /// Our own drags (sheets, folders) move inside the Bible; files from the Finder are brought in.
    private func receive(_ providers: [NSItemProvider], in folder: String) -> Bool {
        target = nil
        let files = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        if !files.isEmpty {
            guard !folder.isEmpty else { return false }
            Task {
                var urls: [URL] = []
                for p in files {
                    if let url = try? await p.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? URL { urls.append(url) }
                    else if let data = try? await p.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) { urls.append(url) }
                }
                _ = await BibleImporter.importAll(urls, into: folder, session: session)
            }
            return true
        }
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let wire = object as? String else { return }
            DispatchQueue.main.async { place(wire, in: folder) }
        }
        return true
    }

    private func place(_ wire: String, in folder: String) {
        switch ShelfDrag(wire: wire) {
        case .sheet(let path)? where !folder.isEmpty:
            if let new = session.moveBibleEntry(path, toFolder: folder) { moved(path, to: new) }
        case .folder(let path)?:
            if BibleStore.parent(of: path) != folder, let new = session.moveBibleFolder(path, into: folder) { moved(path, to: new) }
        default: break
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func newBoard() {
        if let e = try? bible.createBoard(L("New board")) {
            open.insert(e.folder)
            session.pendingCommit = true
            app.open(.sheet(e.path))
        }
    }

    private func create(_ kind: BibleKind, in folder: String?) {
        if let e = try? bible.create(title: kind == .reference ? L("New reference") : kind.label, kind: kind, folder: folder) {
            open.insert(e.folder)
            app.open(.sheet(e.path))
        }
    }
}

// MARK: Folder

struct BibleFolderView: View {
    let app: AppState
    @Bindable var session: BookSession
    let bridge: EditorBridge
    let folder: String
    @State private var query = ""
    @State private var kind: BibleKind?
    @State private var identifier = ""
    @State private var working = false
    @State private var message: String?
    @State private var dropping = false

    private var bible: BibleModel { session.bible }
    private var isDocuments: Bool { folder == BibleStore.documents }
    private var gridOnly: [PlotGrid.Tag] {
        guard folder == "personnages" else { return [] }
        let tags = bible.tagsWithoutSheet(session.plot)
        return query.isEmpty ? tags : tags.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    private var subfolders: [String] { query.isEmpty ? BibleStore.children(of: folder, in: bible.folders) : [] }

    private var items: [BibleEntry] {
        var list = bible.entries(in: folder)
        if let kind { list = list.filter { $0.kind == kind } }
        guard !query.isEmpty else { return folder == "chutes" ? list.sorted { $0.modified > $1.modified } : list }
        return list.filter { e in
            e.title.localizedCaseInsensitiveContains(query) || e.body.localizedCaseInsensitiveContains(query)
                || e.aliases.contains { $0.localizedCaseInsensitiveContains(query) }
                || (e.isFile && DocumentText.cached(e, store: bible.store)?.localizedCaseInsensitiveContains(query) == true)
        }
    }

    @AppStorage("castAsBoard") private var asBoard = true
    private var tiered: Bool { Self.tiered(folder) }
    static func tiered(_ folder: String) -> Bool { folder == "personnages" || folder == "lieux" }
    /// The folder shows the cast in columns, where names are dragged from one to another.
    static func showsCast(_ folder: String) -> Bool {
        tiered(folder) && (UserDefaults.standard.object(forKey: "castAsBoard") as? Bool ?? true)
    }

    var body: some View {
        if tiered && asBoard && query.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                header.padding(.horizontal, 44).padding(.top, 32)
                CastBoard(app: app, session: session, folder: folder)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Ink.panel)
        } else {
            list
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(BibleStore.folderLabel(folder)).font(.system(size: 28, design: .serif))
            if folder == "chutes" {
                Text(L("What you cut, and where from. Nothing is lost.")).foregroundStyle(.secondary)
            }
            if tiered && asBoard {
                Text(L("Arranged by how much they’re in the book. Drag a card to keep it in a column.")).font(.ui(12)).foregroundStyle(.secondary)
            }
            Spacer()
            if tiered {
                Picker("", selection: $asBoard) { Text(L("Board")).tag(true); Text(L("List")).tag(false) }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            TextField(L("Search"), text: $query).textFieldStyle(.roundedBorder).frame(width: 200)
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isDocuments { filters.padding(.top, 12) }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if items.isEmpty && gridOnly.isEmpty && subfolders.isEmpty { empty }
                    ForEach(subfolders, id: \.self) { sub in
                        HStack(spacing: 12) {
                            Image(systemName: "folder").font(.ui(13)).foregroundStyle(.tertiary).frame(width: 18)
                            Text(BibleStore.folderLabel(sub)).lineLimit(1)
                            Spacer()
                            Text("\(bible.entries.filter { BibleStore.isInside($0.folder, sub) }.count)").font(.ui(12).monospacedDigit()).foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                        .onTapGesture { app.open(.folder(sub)) }
                        .overlay(alignment: .bottom) { Divider() }
                    }
                    ForEach(items) { row($0) }
                    ForEach(gridOnly) { tag in
                        HStack(spacing: 12) {
                            Image(systemName: "person").font(.ui(13)).foregroundStyle(.tertiary).frame(width: 18)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(tag.name).foregroundStyle(.secondary).lineLimit(1)
                                Text(L("In the plot grid. Click to give it a sheet.")).font(.ui(12)).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                        .onTapGesture { if let e = try? bible.sheet(for: tag) { app.open(.sheet(e.path)) } }
                        .overlay(alignment: .bottom) { Divider() }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.top, 12)
            if isDocuments { unused }
            footer
        }
        .padding(.horizontal, 44).padding(.top, 32).padding(.bottom, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
        .overlay { if dropping { RoundedRectangle(cornerRadius: Radius.card).strokeBorder(Ink.accent, lineWidth: 2).padding(8) } }
        .dropDestination(for: URL.self, action: { urls, _ in
            Task { await bringIn(urls) }
            return true
        }, isTargeted: { dropping = $0 })
    }

    private var filters: some View {
        HStack(spacing: 4) {
            chip(L("All", ctx: "Tout"), kind == nil) { kind = nil }
            chip("Web", kind == .web) { kind = .web }
            chip(L("References"), kind == .reference) { kind = .reference }
            chip(L("Files"), kind == .document) { kind = .document }
        }
    }

    private func chip(_ title: String, _ on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.ui(12)).padding(.horizontal, 9).frame(height: 24)
                .foregroundStyle(on ? Color.primary : .secondary)
                .overlay(Capsule().strokeBorder(on ? Color.primary : Ink.hairline))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var empty: some View {
        Text(folder == "chutes"
             ? L("Passages of a sentence or more that you cut or delete land here.")
             : L("Nothing yet. Drop a file here, or use + in the sidebar."))
            .foregroundStyle(.secondary).padding(.vertical, 20)
    }

    @ViewBuilder private func row(_ e: BibleEntry) -> some View {
        HStack(spacing: 12) {
            Image(systemName: e.kind.icon).font(.ui(13)).foregroundStyle(.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(e.title).lineLimit(1)
                Text(subtitle(e)).font(.ui(12)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if e.kind == .cut, e.meta["from"] != nil {
                Button(L("Put back in the chapter")) { app.showChapter(); session.restore(e, bridge: bridge) }.buttonStyle(.inkSecondary)
            }
            if e.kind == .reference, let key = e.meta["citekey"], session.selectedChapter != nil {
                Button(L("Cite")) { app.showChapter(); bridge.textView?.insertText("[@\(key)]", replacementRange: bridge.textView?.selectedRange() ?? NSRange()) }.buttonStyle(.inkSecondary)
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture { app.open(.sheet(e.path)) }
        .overlay(alignment: .bottom) { Divider() }
    }

    private func subtitle(_ e: BibleEntry) -> String {
        switch e.kind {
        case .cut:
            let from = session.manifest.chapters.first { $0.id == e.meta["from"] }?.title ?? ""
            return L("Cut from \(from) · \(BookStore.wordCount(e.body)) words")
        case .web:
            return (e.meta["source"].flatMap { URL(string: $0)?.host } ?? "") + (e.meta["date"].map { " · " + $0.prefix(10) } ?? "")
        case .reference:
            let cited = References.citeCount(of: e, in: session)
            return [e.meta["author"], e.meta["year"], e.meta["publisher"]].compactMap { $0 }.joined(separator: ", ")
                + " · " + (cited == 0 ? L("never cited") : (cited == 1 ? L("cited once") : L("cited \(cited) times")))
        case .character, .place, .biography:
            let n = bible.mentions[e.path]?.values.reduce(0, +) ?? 0
            return e.kind.label + (n > 0 ? " · \(n) " + L("mentions") : "")
        default:
            if let linked = e.meta["linked"] { return L("Linked: \(linked)") }
            return e.kind.label
        }
    }

    /// Citations with no reference: the one mistake that would print in the book.
    @ViewBuilder private var unused: some View {
        let missing = References.missing(in: session)
        if !missing.isEmpty {
            Text(L("Cited but with no reference: \(missing.listed)"))
                .font(.ui(12)).foregroundStyle(Ink.warning).padding(.top, 8)
        }
    }

    @ViewBuilder private var footer: some View {
        if isDocuments {
            HStack(spacing: 8) {
                TextField(L("Paste a web address, DOI or ISBN"), text: $identifier)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await add() } }
                if working { ProgressView().controlSize(.small) }
                Button(L("Add")) { Task { await add() } }.buttonStyle(.inkSecondary).disabled(identifier.isEmpty || working)
            }
            .padding(.top, 12)
        }
        if let message { Text(message).font(.ui(12)).foregroundStyle(.secondary).padding(.top, 6) }
    }

    private func bringIn(_ urls: [URL]) async {
        working = true
        message = await BibleImporter.importAll(urls, into: folder, session: session)
        working = false
    }

    private func add() async {
        let text = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        working = true
        defer { working = false }
        do {
            try await BibleImporter.add(identifier: text, session: session)
            identifier = ""
            message = nil
        } catch {
            message = error.localizedDescription
        }
    }
}

// MARK: Entry

struct BibleEntryView: View {
    let app: AppState
    @Bindable var session: BookSession
    let bridge: EditorBridge
    @State var draft: BibleEntry
    @State private var aliases: String
    @State private var saveTask: Task<Void, Never>?
    @State private var originalTitle: String

    init(app: AppState, session: BookSession, bridge: EditorBridge, entry: BibleEntry) {
        self.app = app
        self.session = session
        self.bridge = bridge
        _draft = State(initialValue: entry)
        _aliases = State(initialValue: entry.aliases.joined(separator: ", "))
        _originalTitle = State(initialValue: entry.title)
    }

    private var bible: BibleModel { session.bible }

    var body: some View {
        // In a narrow pane, what the book says goes under the sheet rather than beside it.
        GeometryReader { geo in
            let railWidth: CGFloat = BibleModel.trackedKinds.contains(draft.kind) ? 380 : 300
            if geo.size.width >= railWidth + 420 {
                HStack(spacing: 0) {
                    main
                    Divider()
                    rail.frame(width: railWidth)
                }
            } else {
                VSplitView {
                    main.frame(minHeight: 200)
                    rail.frame(minHeight: 160)
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onAppear { session.refreshBibleMentions() }
        .onDisappear { saveNow() }
    }

    @ViewBuilder private var main: some View {
        if draft.isFile || draft.meta["linked"] != nil {
            DocumentPreview(entry: draft, store: bible.store)
        } else {
            sheet
        }
    }

    private var sheet: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(draft.kind.label + (BibleModel.trackedKinds.contains(draft.kind) ? " · " + bible.tier(of: draft).label : ""))
                        .font(.ui(12)).foregroundStyle(.secondary)
                    Spacer()
                    if BibleModel.trackedKinds.contains(draft.kind) {
                        Button(L("Rename everywhere…")) { saveNow(); app.renaming = .init(path: draft.path) }
                            .buttonStyle(.link).font(.ui(12))
                    }
                }
                TextField("", text: $draft.title, onCommit: commitTitle)
                    .textFieldStyle(.plain).font(.system(size: 30, design: .serif))
                    .accessibilityLabel(L("Title"))
                if [.character, .place, .biography].contains(draft.kind) {
                    TextField(L("Also written: separated by commas"), text: $aliases)
                        .textFieldStyle(.plain).foregroundStyle(.secondary)
                        .onChange(of: aliases) { _, v in
                            draft.aliases = v.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                        }
                }
                if draft.kind == .place { PlaceMapSection(meta: $draft.meta, title: draft.title, save: saveNow) }
                if [.character, .place, .biography].contains(draft.kind) {
                    AttachmentsSection(draft: $draft, bible: bible, open: { app.open(.sheet($0)) }, save: saveNow)
                }
                if let source = draft.meta["source"], let url = URL(string: source) {
                    HStack(spacing: 10) {
                        Link(L("Open the original"), destination: url)
                        if let archive = draft.meta["archive"] {
                            Button(L("Open the kept copy")) { NSWorkspace.shared.open(bible.store.url(archive)) }.buttonStyle(.link)
                        }
                        if let date = draft.meta["date"] { Text(L("Copy of \(date.prefix(10))")).foregroundStyle(.secondary) }
                    }
                }
                if draft.kind == .reference { referenceFields }
                if !draft.fields.isEmpty {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                        ForEach($draft.fields, id: \.name) { $f in
                            GridRow {
                                Text(f.name).foregroundStyle(.secondary).gridColumnAlignment(.leading)
                                TextField("", text: $f.value).textFieldStyle(.plain)
                            }
                        }
                    }
                    Divider()
                }
                TextEditor(text: $draft.body)
                    .font(.uiMono(14))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 340)
                    .onChange(of: draft.body) { _, v in
                        let n = TodoSyntax.normalize(v)
                        if n != v { draft.body = n }
                    }
                Text(L("@[Name] links to a chapter or a sheet · - [ ] or @todo makes a task"))
                    .font(.ui(11)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 44).padding(.vertical, 32)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .onChange(of: draft) { _, _ in scheduleSave() }
    }

    private var referenceFields: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            ForEach([("author", L("Author")), ("year", L("Year")), ("publisher", L("Publisher")), ("doi", "DOI"), ("citekey", L("Key"))], id: \.0) { key, label in
                GridRow {
                    Text(label).foregroundStyle(.secondary)
                    TextField("", text: Binding(get: { draft.meta[key] ?? "" }, set: { draft.meta[key] = $0.isEmpty ? nil : $0 })).textFieldStyle(.plain)
                }
            }
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(600))
            if !Task.isCancelled { saveNow() }
        }
    }

    private func saveNow() {
        guard !draft.isFile, draft != bible.entry(path: draft.path) else { return }
        try? bible.save(draft)
        session.pendingCommit = true
    }

    /// The sheet's title is its name in the plot grid too: the grid's tag follows when the sheet is saved.
    private func commitTitle() {
        let title = draft.title.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty, title != originalTitle else { return }
        originalTitle = title
        let grid = session.plot
        saveNow()
        if session.plot != grid { session.savePlot() }
    }

    private var rail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if BibleModel.trackedKinds.contains(draft.kind) {
                    BookSaysView(app: app, session: session, path: draft.path)
                    presence
                    appearsWith
                }
                if draft.isFile, let passages = keptPassages, !passages.isEmpty {
                    section(L("Kept passages")) {
                        Text(passages).font(.ui(12)).textSelection(.enabled)
                    }
                }
                links
                todos
                if draft.kind == .cut, draft.meta["from"] != nil {
                    Button(L("Put back in the chapter")) { app.showChapter(); session.restore(draft, bridge: bridge) }.buttonStyle(.inkSecondary)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Ink.side)
    }

    /// The other characters and places found in the same chapters, most shared first.
    @ViewBuilder private var appearsWith: some View {
        let mine = Set((bible.occurrences[draft.path] ?? [:]).keys)
        let others = bible.entries.filter { $0.path != draft.path && BibleModel.trackedKinds.contains($0.kind) }
            .map { ($0, mine.intersection((bible.occurrences[$0.path] ?? [:]).keys).count) }
            .filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }.prefix(6)
        if !mine.isEmpty, !others.isEmpty {
            section(L("Appears with")) {
                ForEach(Array(others), id: \.0.path) { e, n in
                    Button { app.open(.sheet(e.path)) } label: {
                        HStack { Text(e.title); Spacer(); Text(session.words.count(n, .piece)).foregroundStyle(.tertiary) }.contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).font(.ui(12))
                }
            }
        }
    }

    private var keptPassages: String? { try? String(contentsOf: bible.store.url(draft.path + ".md"), encoding: .utf8) }

    private func section<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.ui(13, .semibold))
            content()
        }
    }

    private var presence: some View {
        let counts = bible.mentions[draft.path] ?? [:]
        let chapters = session.manifest.chapters
        let peak = max(counts.values.max() ?? 1, 1)
        let absent = chapters.enumerated().filter { counts[$0.element.id] == nil }.map { session.manifest.pieceReference(at: $0.offset) }
        return section(L("In the book")) {
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(chapters) { ch in
                    let n = counts[ch.id] ?? 0
                    Button { app.showChapter(); session.open(ch.id) } label: {
                        RoundedRectangle(cornerRadius: 1.5).fill(n == 0 ? Ink.hairline : Ink.accent)
                            .frame(height: n == 0 ? 3 : 6 + 34 * CGFloat(n) / CGFloat(peak))
                            .frame(maxWidth: .infinity, alignment: .bottom)
                    }
                    .buttonStyle(.plain)
                    .help("\(ch.title) · \(n) " + L("mentions"))
                }
            }
            .frame(height: 42, alignment: .bottom)
            let total = counts.values.reduce(0, +)
            Text(total == 0 ? L("Not mentioned yet")
                 : "\(total) " + L("mentions") + (absent.isEmpty || absent.count == chapters.count ? "" : " · " + L("absent from \(absent.prefix(8).listed)")))
                .font(.ui(12)).foregroundStyle(.secondary)
        }
    }

    private var links: some View {
        let out = BibleLinks.targets(in: draft.body)
        let chapters = session.manifest.chapters
        let linked: [(String, String, () -> Void)] = out.compactMap { name in
            let f = Fold.name(name)
            if let ch = chapters.first(where: { Fold.name($0.title) == f }) {
                return (session.words.name(.piece), ch.title, { app.showChapter(); session.open(ch.id) })
            }
            if let e = bible.entry(named: name) { return (e.kind.label, e.title, { app.open(.sheet(e.path)) }) }
            return nil
        }
        let back = bible.backlinks(to: draft)
        return Group {
            if !linked.isEmpty || !back.isEmpty {
                section(L("Linked to")) {
                    ForEach(Array(linked.enumerated()), id: \.offset) { _, l in linkRow(l.0, l.1, l.2) }
                    ForEach(back) { e in linkRow(e.kind.label, e.title) { app.open(.sheet(e.path)) } }
                }
            }
        }
    }

    private func linkRow(_ kind: String, _ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(kind).font(.ui(11)).foregroundStyle(.secondary).frame(width: 66, alignment: .leading)
                Text(title).font(.ui(12)).lineLimit(2).multilineTextAlignment(.leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var todos: some View {
        let names = Set(draft.names.map(Fold.name))
        let mine = session.collectTodos().filter { t in
            !t.done && (t.source == draft.title || names.contains { !$0.isEmpty && Fold.name(t.text).contains($0) })
        }
        if !mine.isEmpty {
            section(L("To do")) {
                ForEach(mine) { TodoRow(todo: $0, session: session) }
            }
        }
    }
}

/// A task, with its tick and where it comes from.
struct TodoRow: View {
    let todo: TodoItem
    let session: BookSession
    var onChange: () -> Void = {}

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Toggle("", isOn: Binding(get: { todo.done }, set: { _ in session.toggle(todo); onChange() }))
                .toggleStyle(.checkbox).labelsHidden()
            VStack(alignment: .leading, spacing: 1) {
                Text(todo.text).strikethrough(todo.done).foregroundStyle(todo.done ? .secondary : .primary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(place).font(.ui(11)).foregroundStyle(.secondary)
            }
        }
    }

    private var place: String {
        let chapter = todo.chapter.flatMap { id in session.manifest.chapters.first { $0.id == id }?.title }
        return [chapter, todo.source].compactMap { $0 }.joined(separator: " · ")
    }
}
