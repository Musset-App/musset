import SwiftUI
import UniformTypeIdentifiers

/// What the Bible shows in place of the editor.
enum BibleRoute: Hashable {
    case folder(String)
    case entry(String)
}

extension BookSession {
    /// Counts the sheets' names in the chapters. Called when the Bible is opened and when a sheet changes.
    func refreshBibleMentions() {
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
    @State private var open: Set<String> = ["personnages"]
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

        var id: String {
            switch self {
            case .folder(let path, _): "f|" + path
            case .entry(let e, _): "e|" + e.path
            case .tag(let t, _): "t|" + t.name
            }
        }
    }

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
                out += bible.entries(in: folder).map { .entry($0, depth: depth + 1) }
                if folder == "personnages" { out += bible.tagsWithoutSheet(session.plot).map { .tag($0, depth: depth + 1) } }
            }
        }
        walk("", depth: 0)
        return out
    }

    var body: some View {
        header
        ForEach(rows) { row in
            switch row {
            case .folder(let path, let depth): folderRow(path, depth: depth)
            case .entry(let e, let depth): entryRow(e, depth: depth)
            case .tag(let tag, let depth): tagRow(tag, depth: depth)
            }
        }
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
            Text("Bible").font(.ui(11, .medium)).foregroundStyle(.secondary)
            Spacer()
            Menu {
                newEntryButtons(in: nil)
                Divider()
                Button(L("New folder…")) { ask(.newFolder(in: "")) }
            } label: { Image(systemName: "plus").font(.ui(11)) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help(L("New entry in the Bible"))
        }
        .padding(.horizontal, 8).padding(.top, 12).padding(.bottom, 4)
        .background { if target == "" { RoundedRectangle(cornerRadius: 6).fill(Ink.accent.opacity(0.12)) } }
        .onDrop(of: [.text], isTargeted: targeted("")) { providers in
            receive(providers, in: "")
        }
        .contextMenu { Button(L("New folder…")) { ask(.newFolder(in: "")) } }
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
            if let route = app.bibleRoute, BibleStore.isInside(routePath(route), path) { app.bibleRoute = nil }
        }
        deleting = nil
    }

    // MARK: Rows

    private func folderRow(_ folder: String, depth: Int) -> some View {
        let system = BibleStore.isSystem(folder)
        let count = bible.entries(in: folder).count + (folder == "personnages" ? bible.tagsWithoutSheet(session.plot).count : 0)
        return SidebarRowView(active: app.bibleRoute == .folder(folder)) {
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
        .background { if target == folder { RoundedRectangle(cornerRadius: 6).fill(Ink.accent.opacity(0.12)) } }
        .contentShape(Rectangle())
        .onTapGesture { app.show(.folder(folder)) }
        .shelfDraggable(system ? nil : .folder(folder), title: BibleStore.folderLabel(folder))
        .onDrop(of: [.fileURL, .text], isTargeted: targeted(folder)) { providers in
            receive(providers, in: folder)
        }
        .contextMenu { folderMenu(folder, system: system) }
        .sidebarRow()
    }

    private func entryRow(_ e: BibleEntry, depth: Int) -> some View {
        SidebarRowView(active: app.bibleRoute == .entry(e.path)) {
            Image(systemName: e.kind.icon).font(.ui(11)).foregroundStyle(.tertiary).frame(width: 14)
            Text(e.title).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.leading, CGFloat(depth) * 12 + 4)
        .contentShape(Rectangle())
        .onTapGesture { app.show(.entry(e.path)) }
        .shelfDraggable(.sheet(e.path), title: e.title)
        .contextMenu {
            Button(L("Open")) { app.show(.entry(e.path)) }
            moveMenu(excluding: [e.folder]) { session.moveBibleEntry(e.path, toFolder: $0).map { moved(e.path, to: $0) } }
            Divider()
            Button(L("Reveal in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([bible.store.url(e.path)]) }
            Button(L("Copy Path")) { copy(BibleStore.folderName + "/" + e.path) }
            Divider()
            Button(L("Move to Trash"), role: .destructive) {
                if e.isFile { try? bible.trash(e.path) } else { _ = session.drop([ShelfDrag.sheet(e.path).wire], on: .trash) }
                if app.bibleRoute == .entry(e.path) { app.bibleRoute = nil }
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
        .onTapGesture { if let e = try? bible.sheet(for: tag) { app.show(.entry(e.path)) } }
        .help(L("In the plot grid. Click to give it a sheet."))
        .sidebarRow()
    }

    // MARK: Menus

    @ViewBuilder
    private func folderMenu(_ folder: String, system: Bool) -> some View {
        Menu(L("New Sheet")) { newEntryButtons(in: folder) }
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
        case .newFolder(let parent): parent.isEmpty ? L("New folder") : L("New folder in « \(BibleStore.folderLabel(parent)) »")
        case .rename(let path): L("Rename « \(BibleStore.folderLabel(path)) »")
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

    /// Open folders and the page shown follow what moved.
    private func moved(_ old: String, to new: String) {
        open = Set(open.map { BookSession.retarget($0, from: old, to: new) })
        open.insert(BibleStore.parent(of: new))
        switch app.bibleRoute {
        case .folder(let p)?: app.bibleRoute = .folder(BookSession.retarget(p, from: old, to: new))
        case .entry(let p)?: app.bibleRoute = .entry(BookSession.retarget(p, from: old, to: new))
        case nil: break
        }
    }

    private func routePath(_ route: BibleRoute) -> String {
        switch route {
        case .folder(let p), .entry(let p): p
        }
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

    private func create(_ kind: BibleKind, in folder: String?) {
        if let e = try? bible.create(title: kind == .reference ? L("New reference") : kind.label, kind: kind, folder: folder) {
            open.insert(e.folder)
            app.show(.entry(e.path))
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(BibleStore.folderLabel(folder)).font(.system(size: 28, design: .serif))
                if folder == "chutes" {
                    Text(L("What you cut, and where from. Nothing is lost.")).foregroundStyle(.secondary)
                }
                Spacer()
                TextField(L("Search"), text: $query).textFieldStyle(.roundedBorder).frame(width: 200)
            }
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
                        .onTapGesture { app.show(.folder(sub)) }
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
                        .onTapGesture { if let e = try? bible.sheet(for: tag) { app.show(.entry(e.path)) } }
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
        .overlay { if dropping { RoundedRectangle(cornerRadius: 10).strokeBorder(Ink.accent, lineWidth: 2).padding(8) } }
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
             ? L("Passages of a dozen words or more that you cut with ⌘X land here.")
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
                Button(L("Put back")) { app.leaveBookPages(); session.restore(e, bridge: bridge) }.buttonStyle(.inkSecondary)
            }
            if e.kind == .reference, let key = e.meta["citekey"], session.selectedChapter != nil {
                Button(L("Cite")) { app.leaveBookPages(); bridge.textView?.insertText("[@\(key)]", replacementRange: bridge.textView?.selectedRange() ?? NSRange()) }.buttonStyle(.inkSecondary)
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture { app.show(.entry(e.path)) }
        .overlay(alignment: .bottom) { Divider() }
    }

    private func subtitle(_ e: BibleEntry) -> String {
        switch e.kind {
        case .cut:
            let from = session.manifest.chapters.first { $0.id == e.meta["from"] }?.title ?? ""
            return L("Cut from ") + from + " · \(BookStore.wordCount(e.body)) " + L("words")
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
            if let linked = e.meta["linked"] { return L("Linked: ") + linked }
            return e.kind.label
        }
    }

    /// Citations with no reference: the one mistake that would print in the book.
    @ViewBuilder private var unused: some View {
        let missing = References.missing(in: session)
        if !missing.isEmpty {
            Text(L("Cited but with no reference: ") + missing.joined(separator: ", "))
                .font(.ui(12)).foregroundStyle(.orange).padding(.top, 8)
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
        HStack(spacing: 0) {
            if draft.isFile || draft.meta["linked"] != nil {
                DocumentPreview(entry: draft, store: bible.store)
            } else {
                sheet
            }
            Divider()
            rail.frame(width: 300)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onAppear { session.refreshBibleMentions() }
        .onDisappear { saveNow() }
    }

    private var sheet: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(draft.kind.label).font(.ui(12)).foregroundStyle(.secondary)
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
                if let source = draft.meta["source"], let url = URL(string: source) {
                    HStack(spacing: 10) {
                        Link(L("Open the original"), destination: url)
                        if let date = draft.meta["date"] { Text(L("Copy of ") + date.prefix(10)).foregroundStyle(.secondary) }
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

    /// The sheet and its tag in the plot grid carry one name.
    private func commitTitle() {
        let title = draft.title.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty, title != originalTitle else { return }
        if session.plot.canonical(originalTitle, column: "characters") != nil {
            session.plot.renameTag(session.plot.canonical(originalTitle, column: "characters") ?? originalTitle, to: title, column: "characters")
            session.savePlot()
        }
        originalTitle = title
        saveNow()
    }

    private var rail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if [.character, .place, .biography].contains(draft.kind) { presence }
                if draft.isFile, let passages = keptPassages, !passages.isEmpty {
                    section(L("Kept passages")) {
                        Text(passages).font(.ui(12)).textSelection(.enabled)
                    }
                }
                links
                todos
                if draft.kind == .cut, draft.meta["from"] != nil {
                    Button(L("Put back in the chapter")) { app.leaveBookPages(); session.restore(draft, bridge: bridge) }.buttonStyle(.inkSecondary)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Ink.side)
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
        let absent = chapters.enumerated().filter { counts[$0.element.id] == nil }.map { "\($0.offset + 1)" }
        return section(L("In the book")) {
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(chapters) { ch in
                    let n = counts[ch.id] ?? 0
                    Button { app.leaveBookPages(); session.open(ch.id) } label: {
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
                 : "\(total) " + L("mentions") + (absent.isEmpty || absent.count == chapters.count ? "" : " · " + L("absent from ") + absent.prefix(8).joined(separator: ", ")))
                .font(.ui(12)).foregroundStyle(.secondary)
        }
    }

    private var links: some View {
        let out = BibleLinks.targets(in: draft.body)
        let chapters = session.manifest.chapters
        let linked: [(String, String, () -> Void)] = out.compactMap { name in
            let f = PlotGrid.fold(name)
            if let ch = chapters.first(where: { PlotGrid.fold($0.title) == f }) {
                return (L("Chapter"), ch.title, { app.leaveBookPages(); session.open(ch.id) })
            }
            if let e = bible.entry(named: name) { return (e.kind.label, e.title, { app.show(.entry(e.path)) }) }
            return nil
        }
        let back = bible.backlinks(to: draft)
        return Group {
            if !linked.isEmpty || !back.isEmpty {
                section(L("Linked to")) {
                    ForEach(Array(linked.enumerated()), id: \.offset) { _, l in linkRow(l.0, l.1, l.2) }
                    ForEach(back) { e in linkRow(e.kind.label, e.title) { app.show(.entry(e.path)) } }
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
        let names = Set(draft.names.map(PlotGrid.fold))
        let mine = session.collectTodos().filter { t in
            !t.done && (t.source == draft.title || names.contains { !$0.isEmpty && PlotGrid.fold(t.text).contains($0) })
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
