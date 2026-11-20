import AppKit
import SwiftUI

// MARK: Book settings

/// What is the book's own: its identity, what its AI reader reads it against, who it is shared with, its folder.
/// Its special pages are in the sidebar (and « Cover & Special Pages »); what an export takes, down to what goes
/// between two scenes, is chosen in the export sheet; what holds for every book is in the app's Settings.
/// The book's settings, a page of its home (Overview ▸ Settings). Who reads the book is its neighbour, Readers.
struct BookSettingsView: View {
    let app: AppState
    @Bindable var session: BookSession
    @State private var section = Section.general
    /// The section to open on, for a caller that builds the page itself; the app asks through `bookSettingsSection`.
    var startSection: Section? = nil
    @State private var showRubric = false
    @State private var showCheckers = false
    @State private var showTics = false

    enum Section: String, CaseIterable, Identifiable {
        case general, structure, critic, folder
        var id: String { rawValue }
        var label: String {
            switch self {
            case .general: L("General")
            case .structure: L("Structure")
            case .critic: L("AI reader")
            case .folder: L("Folder & history")
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Section.allCases) { s in
                    Button { section = s } label: {
                        Text(s.label).frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10).frame(height: 28)
                            .background(section == s ? Ink.selected : .clear, in: RoundedRectangle(cornerRadius: Radius.row))
                            .fontWeight(section == s ? .medium : .regular)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(12)
            .frame(width: 190)
            .background(Ink.side)
            Divider()
            if section == .structure {
                // Its own page: a table too wide for the column, and what it gives beside it.
                StructureSettings(session: session)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        header
                        content
                    }
                    .padding(32)
                    .frame(maxWidth: 620, alignment: .leading)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showRubric) { BaremeSheet(session: session) }
        .sheet(isPresented: $showCheckers) { CheckersSheet(session: session) }
        .sheet(isPresented: $showTics) { TicsSheet(session: session) }
        // No button to confirm: what changes is kept when the page is left, and as each field is submitted.
        .onDisappear { session.saveManifest() }
        .onChange(of: section) { session.saveManifest() }
        .onAppear { if let asked = app.bookSettingsSection ?? startSection { section = asked; app.bookSettingsSection = nil } }
        .onChange(of: app.bookSettingsSection) { _, asked in if let asked { section = asked; app.bookSettingsSection = nil } }
    }

    private var header: some View {
        HStack(spacing: 18) {
            CoverThumb(manifest: session.manifest, root: session.root).frame(width: 64, height: 96)
            VStack(alignment: .leading, spacing: 4) {
                Text(session.title).font(.system(size: 28, design: .serif).weight(.regular))
                let scenes = session.manifest.chapters.reduce(0) { $0 + (session.scenes[$1.id]?.count ?? 0) }
                HStack(spacing: 0) {
                    Text(session.words.count(session.manifest.chapters.count, .piece) + " · " + session.words.count(scenes, .scene) + " · ")
                    CountButton(text: session.bookCounts.label)
                }
                .foregroundStyle(.secondary)
                if let goal = session.manifest.goal, goal > 0 {
                    ProgressView(value: min(1, Double(session.bookWordCount) / Double(goal))).frame(width: 220)
                        .help("\(Int(100 * Double(session.bookWordCount) / Double(goal))) % " + L("of the goal"))
                }
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch section {
        case .general:
            SettingsCard(filled: true) {
                field(L("Title"), text: $session.manifest.title)
                field(L("Subtitle"), text: Binding(get: { session.manifest.subtitle ?? "" }, set: { session.manifest.subtitle = $0.isEmpty ? nil : $0 }))
                field(L("Author"), text: $session.manifest.author)
                field(L("Word goal"), text: Binding(get: { session.manifest.goal.map(String.init) ?? "" },
                                                                     set: { session.manifest.goal = Int($0.filter(\.isNumber)) }))
                field(L("Contact (manuscript)"), text: $session.manifest.contact)
            }
            SettingsCard(filled: true) {
                SettingsRow(title: L("Book language"), style: .form) {
                    BookLanguagePicker(code: $session.manifest.lang)
                }
            }
        case .structure:
            EmptyView()
        case .critic:
            HStack(alignment: .top, spacing: 12) {
                criticCard(L("Rubric…").titled, L("Used by « Critique ». Markdown in .musset/rubric.md."),
                           L("Edit rubric")) { showRubric = true }
                criticCard(L("Tics grid…").titled, L("Six families, each with its test. Used by « Tics »."),
                           L("Edit grid")) { showTics = true }
                criticCard(L("Checkers…").titled, L("Your own writing rules, checked on a chapter. Shared by all your books."),
                           L("Edit checkers")) { showCheckers = true }
            }
        case .folder:
            SettingsCard(filled: true) {
                SettingsRow(title: L("Folder"), style: .form) {
                    Text(session.root.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(.uiMono(12))
                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                SettingsRow(title: L("History"), style: .form) {
                    Text(session.git.isRepo
                         ? (session.lastCommitAt.map { L("Last save \($0.formatted(date: .omitted, time: .shortened))") } ?? L("In the history"))
                         : L("Not in the history"))
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                Button(L("Reveal in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([session.root]) }
                Button(L("History")) { app.inspectorTab = .history; app.showInspector = true }
            }
        }
    }

    // MARK: Parts

    private func field(_ label: String, text: Binding<String>) -> some View {
        SettingsRow(title: label, style: .form) {
            TextField("", text: text).textFieldStyle(.roundedBorder).onSubmit { session.saveManifest() }
        }
    }

    private func criticCard(_ title: String, _ body: String, _ link: String, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).fontWeight(.medium)
            Text(body).font(.ui(11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button(link, action: action).buttonStyle(.link).font(.ui(11)).padding(.top, 4)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Radius.card).strokeBorder(Ink.hairline))
    }
}

extension SceneBreak {
    var localizedLabel: String {
        switch self {
        case .none: L("Nothing")
        case .blank: L("Blank line")
        case .asterism: "⁂"
        }
    }
}

// MARK: Cover

extension Color {
    init(hex: String) {
        let h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        let v = UInt64(h, radix: 16) ?? 0
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}

/// The cover as Musset typesets it: drawn here at any size (the PDF uses the same layout in Typst).
struct CoverThumb: View {
    let manifest: BookManifest
    var root: URL? = nil

    var body: some View {
        GeometryReader { geo in
            let c = manifest.front?.cover ?? FrontMatter.Cover()
            let k = geo.size.width / 300
            ZStack {
                Color(hex: c.style == "plain" ? "#FFFFFF" : c.ground)
                if c.style == "image", let img = c.image, let root, let ns = NSImage(contentsOf: root.appendingPathComponent(img)) {
                    Image(nsImage: ns).resizable().scaledToFill()
                }
                VStack(spacing: 0) {
                    Text(manifest.author.uppercased()).font(.system(size: 13 * k, design: .serif)).tracking(2 * k)
                    Spacer().frame(height: 54 * k)
                    Text(manifest.title).font(.system(size: 40 * k, design: .serif)).foregroundStyle(Color(hex: c.style == "plain" ? "#1A1A18" : c.accent))
                        .multilineTextAlignment(.center)
                    if !c.genre.isEmpty {
                        Text(c.genre).font(.system(size: 14 * k, design: .serif).italic()).padding(.top, 10 * k)
                    }
                    Spacer()
                    if !c.publisher.isEmpty { Text(c.publisher.uppercased()).font(.system(size: 10 * k, design: .serif)).tracking(2 * k) }
                }
                .foregroundStyle(Color(hex: "#1E1E1C"))
                .padding(.top, 48 * k).padding(.bottom, 32 * k).padding(.horizontal, 24 * k)
                if c.style == "typographic" {
                    Rectangle().strokeBorder(Color(hex: c.accent), lineWidth: max(0.5, k)).padding(16 * k)
                    Rectangle().strokeBorder(Color(hex: c.accent), lineWidth: max(0.5, k)).padding(21 * k)
                }
            }
            .clipped()
        }
        .aspectRatio(2 / 3, contentMode: .fit)
        .shadow(color: .black.opacity(0.12), radius: 10, y: 6)
    }
}

// MARK: Special pages

/// A special page open in place of the editor: its fields on the left, how it prints on the right.
struct SpecialPageView: View {
    let app: AppState
    @Bindable var session: BookSession
    let page: SpecialPage

    private var front: Binding<FrontMatter> {
        Binding(get: { session.manifest.front ?? FrontMatter() }, set: { session.manifest.front = $0; session.saveManifest() })
    }
    private var cover: Binding<FrontMatter.Cover> {
        // No cover yet: show the defaults, not printed until the author turns it on (or edits it).
        Binding(get: { front.wrappedValue.cover ?? FrontMatter.Cover(genre: session.manifest.lang.hasPrefix("fr") ? "roman" : "a novel", inPDF: false) },
                set: { front.wrappedValue.cover = $0 })
    }

    var body: some View {
        HStack(spacing: 0) {
            // No scroll view: the form is short, and a plain column draws reliably over the hidden editor.
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        Button { app.showChapter() } label: {
                            HStack(spacing: 5) { Image(systemName: "chevron.left").font(.ui(10, .semibold)); Text(L("Editor")) }
                        }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        Spacer()
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(page.label).font(.system(size: 26, design: .serif))
                        Text(hint).font(.ui(12)).foregroundStyle(.secondary)
                    }
                    form
                }
                .padding(28)
                Spacer(minLength: 0)
            }
            .frame(width: 400)
            .frame(maxHeight: .infinity, alignment: .top)
            Divider()
            ZStack {
                Color(nsColor: .underPageBackgroundColor)
                preview.padding(40)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var hint: String {
        switch page {
        case .cover: L("Typeset with the book, at the export size. No image needed.")
        case .title: L("Author, title and subtitle, after the cover.")
        case .dedication: L("A line alone on its page, a third of the way down.")
        case .epigraph: L("A quotation before the first chapter.")
        case .contents: L("The chapters and their pages.")
        case .acknowledgements: L("After the last chapter.")
        case .colophon: L("The last page of the book.")
        }
    }

    @ViewBuilder private var form: some View {
        switch page {
        case .cover:
            Segmented(options: [("typographic", L("Typographic")), ("image", L("Image…").titled), ("plain", L("Plain"))],
                      selection: cover.style)
            labeled(L("Genre")) { TextField("", text: cover.genre).textFieldStyle(.roundedBorder) }
            labeled(L("Publisher line")) { TextField(L("[PUBLISHER]"), text: cover.publisher).textFieldStyle(.roundedBorder) }
            if cover.wrappedValue.style == "image" {
                labeled(L("Image…").titled) {
                    HStack {
                        Text(cover.wrappedValue.image.map { ($0 as NSString).lastPathComponent } ?? L("None", ctx: "Aucune")).foregroundStyle(.secondary)
                        Spacer()
                        Button(L("Choose…")) { chooseImage() }
                    }
                }
            }
            if cover.wrappedValue.style != "plain" {
                labeled(L("Ground and accent")) {
                    HStack(spacing: 8) {
                        ForEach(["#F3EEE2", "#FFFFFF", "#1E2433"], id: \.self) { hex in swatch(hex, selected: cover.wrappedValue.ground == hex) { cover.wrappedValue.ground = hex } }
                        Divider().frame(height: 18)
                        ForEach(["#9B2F26", "#1A1A18", "#2E4BC6"], id: \.self) { hex in swatch(hex, selected: cover.wrappedValue.accent == hex) { cover.wrappedValue.accent = hex } }
                    }
                }
            }
            Toggle(L("Include in the PDF"), isOn: cover.inPDF).toggleStyle(.switch).controlSize(.small)
        case .title:
            Toggle(L("Title page in the book"), isOn: Binding(get: { front.wrappedValue.titlePage ?? true }, set: { front.wrappedValue.titlePage = $0 }))
                .toggleStyle(.switch).controlSize(.small)
            Text(L("Author, title and subtitle come from Book settings.")).font(.ui(11)).foregroundStyle(.secondary)
        case .dedication:
            textArea(Binding(get: { front.wrappedValue.dedication ?? "" }, set: { front.wrappedValue.dedication = $0 }))
            Text(L("Leave empty for no dedication.")).font(.ui(11)).foregroundStyle(.secondary)
        case .epigraph:
            textArea(Binding(get: { front.wrappedValue.epigraph ?? "" }, set: { front.wrappedValue.epigraph = $0 }))
            labeled(L("Source")) { TextField("", text: Binding(get: { front.wrappedValue.epigraphSource ?? "" }, set: { front.wrappedValue.epigraphSource = $0 })).textFieldStyle(.roundedBorder) }
        case .contents:
            Toggle(L("Table of contents in the book"), isOn: Binding(get: { front.wrappedValue.contents ?? false }, set: { front.wrappedValue.contents = $0 }))
                .toggleStyle(.switch).controlSize(.small)
            Text(L("Built from the chapter titles when the book is typeset.")).font(.ui(11)).foregroundStyle(.secondary)
        case .acknowledgements:
            textArea(Binding(get: { front.wrappedValue.acknowledgements ?? "" }, set: { front.wrappedValue.acknowledgements = $0 }))
        case .colophon:
            Toggle(L("Colophon at the end"), isOn: Binding(get: { front.wrappedValue.colophon ?? false }, set: { front.wrappedValue.colophon = $0 }))
                .toggleStyle(.switch).controlSize(.small)
        }
    }

    @ViewBuilder private var preview: some View {
        if page == .cover {
            VStack(spacing: 28) {
                CoverThumb(manifest: session.manifest, root: session.root).frame(maxWidth: 300)
                HStack(spacing: 12) {
                    ForEach([SpecialPage.title, .dedication, .epigraph, .contents]) { p in
                        Button { app.open(p.tab) } label: {
                            VStack(spacing: 6) {
                                PagePreview(page: p, manifest: session.manifest, chapters: session.manifest.chapters.map(\.title))
                                    .frame(width: 300, height: 450).scaleEffect(64.0 / 300).frame(width: 64, height: 96)
                                    .allowsHitTesting(false)
                                Text(p.label).font(.ui(11)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .frame(width: 76)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        } else {
            PagePreview(page: page, manifest: session.manifest, chapters: session.manifest.chapters.filter { !$0.excludeFromExport }.map(\.title))
                .frame(maxWidth: 340)
        }
    }

    private func labeled<C: View>(_ label: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.ui(12, .medium)).foregroundStyle(.secondary)
            c()
        }
    }

    private func textArea(_ text: Binding<String>) -> some View {
        TextEditor(text: text)
            .font(.system(size: 15, design: .serif))
            .frame(minHeight: 140)
            .scrollContentBackground(.hidden)
            .padding(8)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: Radius.control))
            .overlay(RoundedRectangle(cornerRadius: Radius.control).strokeBorder(Ink.hairline))
    }

    private func swatch(_ hex: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Circle().fill(Color(hex: hex)).frame(width: 24, height: 24)
                .overlay(Circle().strokeBorder(selected ? Color.primary : Ink.hairline, lineWidth: selected ? 2 : 1))
        }
        .buttonStyle(.plain)
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .heic]
        panel.directoryURL = session.root
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // Kept inside the book, so it travels (and is committed) with it.
        let name = ".musset/cover." + url.pathExtension.lowercased()
        let dest = session.root.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: dest)
        do { try FileManager.default.copyItem(at: url, to: dest); cover.wrappedValue.image = name }
        catch { session.lastError = error.localizedDescription }
    }
}

/// A special page as it prints, in miniature.
struct PagePreview: View {
    let page: SpecialPage
    let manifest: BookManifest
    let chapters: [String]

    var body: some View {
        let f = manifest.front ?? FrontMatter()
        VStack(spacing: 0) {
            switch page {
            case .title:
                Text(manifest.author.uppercased()).font(.system(size: 12, design: .serif)).tracking(2).padding(.top, 60)
                Text(manifest.title).font(.system(size: 30, design: .serif)).padding(.top, 50)
                if let s = manifest.subtitle { Text(s).font(.system(size: 13, design: .serif).italic()).padding(.top, 8) }
                Spacer()
            case .dedication:
                Spacer().frame(height: 140)
                Text(f.dedication?.nilIfEmpty ?? L("[DEDICATION]")).font(.system(size: 14, design: .serif).italic()).multilineTextAlignment(.center)
                Spacer()
            case .epigraph:
                Spacer().frame(height: 120)
                VStack(alignment: .trailing, spacing: 8) {
                    Text(f.epigraph?.nilIfEmpty ?? L("[EPIGRAPH]")).font(.system(size: 13, design: .serif).italic()).multilineTextAlignment(.trailing)
                    if let s = f.epigraphSource?.nilIfEmpty { Text(s).font(.system(size: 11, design: .serif)) }
                }
                .frame(maxWidth: .infinity, alignment: .trailing).padding(.leading, 60)
                Spacer()
            case .contents:
                Text(L("Contents", ctx: "Table")).font(.system(size: 18, design: .serif)).padding(.vertical, 28)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(chapters.prefix(16).enumerated()), id: \.offset) { i, t in
                        HStack { Text(t); Spacer(); Text("\(9 + i * 12)").foregroundStyle(.secondary) }.font(.system(size: 11, design: .serif))
                    }
                }
                Spacer()
            case .acknowledgements:
                Text(L("Acknowledgements")).font(.system(size: 16, design: .serif)).padding(.vertical, 28)
                Text(f.acknowledgements?.nilIfEmpty ?? "[…]").font(.system(size: 11, design: .serif)).frame(maxWidth: .infinity, alignment: .leading)
                Spacer()
            case .colophon:
                Spacer()
                Text(Colophon.text(manifest)).font(.system(size: 10, design: .serif)).multilineTextAlignment(.center).foregroundStyle(.secondary)
                    .padding(.bottom, 60)
            case .cover:
                EmptyView()
            }
        }
        .foregroundStyle(Color(hex: "#1E1E1C"))
        .padding(36)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .aspectRatio(2 / 3, contentMode: .fit)
        .background(Color.white)
        .shadow(color: .black.opacity(0.1), radius: 10, y: 6)
    }
}

enum Colophon {
    static func text(_ m: BookManifest) -> String {
        let year = Calendar.current.component(.year, from: Date())
        return m.lang.hasPrefix("fr")
            ? "Achevé d’imprimer en \(year).\nComposé avec Musset."
            : "Printed in \(year).\nTypeset with Musset."
    }
}

// MARK: New book

extension AppState {
    /// A new book folder: its chapters, a rubric and outline for its genre, a manifest, git, then opens it.
    func createBook(at root: URL, title: String, author: String, lang: String, genre: String?, form: BookStructure.Form? = nil,
                    chapters planned: [PlannedChapter]) async throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: root.path), !((try? fm.contentsOfDirectory(atPath: root.path)) ?? []).filter({ !$0.hasPrefix(".") }).isEmpty {
            throw NSError(domain: "Musset", code: 1, userInfo: [NSLocalizedDescriptionKey: L("This folder already exists and is not empty.")])
        }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let store = BookStore(root: root)
        var chapters: [ChapterEntry] = []
        var plot = PlotGrid.load(root)
        plot.columns = PlotGrid.columns(forGenre: genre)
        // The parts of the book it comes from: each run of chapters under one title is a part.
        var parts: [BookPart] = []
        var partIDs: [String?] = []
        for (i, ch) in planned.enumerated() {
            if let name = ch.part {
                if i == 0 || planned[i - 1].part != name { parts.append(BookPart(title: name)) }
                partIDs.append(parts.last?.id)
            } else { partIDs.append(nil) }
        }
        for (i, part) in planned.enumerated() {
            let slug = part.title.slug("_", words: 5)
            let id = String(format: "%02d_%@", i + 1, slug.isEmpty ? "chapitre" : slug)
            var entry = ChapterEntry(id: id, file: "\(id).md", title: part.title)
            entry.part = partIDs[i]
            try store.write(part.text, to: entry)
            chapters.append(entry)
            for (scene, synopsis) in part.synopsis {
                plot.update(id, scene) { $0.cells["main", default: .init()].text = synopsis }
            }
        }
        var m = BookManifest(title: title, author: author, lang: lang, chapters: chapters)
        m.genre = genre
        if !parts.isEmpty { m.parts = parts }
        // The form chosen for a new book; an imported one has none and reads as the book Musset always made.
        if let form { m.setForm(form) }
        try store.saveManifest(m)
        try plot.save(root)
        if let preset = ScoringLibrary.shared.presets.first(where: { $0.id == genre }), var bareme = Bareme.forBook(root) ?? Bareme(migrating: nil) {
            bareme.adopt(preset)
            try bareme.save(root)
        }
        let git = GitService(root: root)
        if !git.isRepo { try git.initRepo() }
        _ = try git.commit(paths: chapters.map(\.file) + [".musset"], message: "musset: new book")
        openBook(root)
    }
}
