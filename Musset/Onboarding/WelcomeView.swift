import SwiftUI
import UniformTypeIdentifiers

/// The genres offered first; every preset stays one click away.
enum BookGenres {
    static let first = ["litterature-blanche", "fantasy", "sf", "polar", "romance", "essai"]

    static func label(_ id: String) -> String {
        switch id {
        case "litterature-blanche": L("Literary")
        case "fantasy": "Fantasy"
        case "sf": L("Sci-fi")
        case "polar": L("Crime")
        case "romance": "Romance"
        case "essai": L("Essay")
        default: ScoringLibrary.shared.presets.first { $0.id == id }?.name ?? id
        }
    }

    /// What choosing it changes, said plainly.
    static func effect(_ id: String) -> String {
        let columns = PlotGrid.columns(forGenre: id).dropFirst().map(\.shownTitle).joined(separator: ", ")
        return L("Scoring set for this genre. Outline: \(columns).")
    }
}

extension PlotGrid {
    /// A genre's outline: fantasy needs a world, an essay a thesis. Synopsis stays first.
    static func columns(forGenre genre: String?) -> [Column] {
        func tagged(_ id: String, _ title: String) -> Column { var c = Column(id: id, title: title); c.tagged = true; return c }
        let synopsis = Column(id: "main", title: "Synopsis")
        switch genre {
        case "fantasy": return [synopsis, tagged("characters", "Personnages"), tagged("monde", "Monde"), Column(id: "magie", title: "Magie"), Column(id: "hidden", title: "Intrigue cachée", ai: false)]
        case "sf": return [synopsis, tagged("characters", "Personnages"), tagged("monde", "Monde"), Column(id: "technologies", title: "Technologies"), Column(id: "hidden", title: "Intrigue cachée", ai: false)]
        case "polar", "thriller": return [synopsis, tagged("characters", "Personnages"), Column(id: "enquete", title: "Enquête"), tagged("indices", "Indices"), Column(id: "fausses", title: "Fausses pistes", ai: false)]
        case "romance", "chick-lit": return [synopsis, tagged("characters", "Personnages"), Column(id: "relation", title: "Relation"), Column(id: "obstacles", title: "Obstacles"), Column(id: "hidden", title: "Intrigue cachée", ai: false)]
        case "essai": return [synopsis, Column(id: "these", title: "Thèse"), Column(id: "arguments", title: "Arguments"), tagged("sources", "Sources")]
        default: return defaultColumns
        }
    }
}

/// The first page. A title and Return, or a book that already exists. No wizard.
struct WelcomeView: View {
    @Bindable var app: AppState
    /// Shown as a sheet from an open library.
    var sheet = false
    @Environment(\.dismiss) private var dismiss
    @AppStorage(UILang.key) private var uiLanguage = UILang.system.rawValue
    @State private var title = ""
    @State private var genre = BookGenres.first[0]
    @State private var form = BookStructure.Form.novel
    /// The second step of a new book: its form.
    @State private var choosingForm = false
    @State private var lang = BookLanguage.forInterface.rawValue
    @State private var author = UserDefaults.standard.string(forKey: "lastAuthor") ?? NSFullUserName()
    @State private var location = BookStore.defaultFolder
    @State private var editing = false
    /// Musset Sync, offered once, unticked, when the book is made.
    @State private var keepInSync = false
    @State private var plan: ImportPlan?
    @State private var working = false
    @State private var error: String?
    @State private var dropping = false
    @FocusState private var focused: Bool

    private var slug: String { BibleStore.slug(title) }
    private var hasTitle: Bool { !title.trimmingCharacters(in: .whitespaces).isEmpty }
    private var path: String { location.appendingPathComponent(slug).path.replacingOccurrences(of: NSHomeDirectory(), with: "~") }

    var body: some View {
        Group {
            if plan != nil { ImportReviewView(plan: Binding(get: { plan! }, set: { plan = $0 }), genre: $genre, lang: $lang, author: $author, location: $location, error: $error, working: working, cancel: { plan = nil }, create: importBook) }
            else if choosingForm {
                FormChooser(form: $form, lang: lang, title: title, working: working, error: error, back: { choosingForm = false }, create: createBlank)
            } else { first }
        }
        // The form step lays eight cards beside their preview: it needs the room.
        .frame(minWidth: sheet ? (choosingForm ? 1160 : 960) : nil, minHeight: sheet ? (choosingForm ? 760 : 680) : nil)
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var first: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Spacer()
                if !sheet { languageSwitch }
                if sheet { Button { dismiss() } label: { Image(systemName: "xmark").font(.ui(12)) }.buttonStyle(.plain).keyboardShortcut(.cancelAction).accessibilityLabel(L("Close")) }
            }
            .padding(.horizontal, 16).frame(height: 44)
            .background(WindowDragArea())
            VStack(alignment: .leading, spacing: 0) {
                Text("Musset").font(.system(size: 22, design: .serif)).foregroundStyle(.secondary).padding(.top, 24)
                Text(L("What is your book called?")).foregroundStyle(.secondary).padding(.top, 40)
                TextField(L("Untitled"), text: $title)
                    .textFieldStyle(.plain).font(.uiMono(34)).focused($focused)
                    .padding(.top, 10).padding(.bottom, 12)
                    .overlay(alignment: .bottom) { Rectangle().fill(Ink.accent).frame(height: 1.5) }
                    .onSubmit { if hasTitle { choosingForm = true } }
                    .accessibilityLabel(L("Book title"))
                if hasTitle { details } else {
                    Text(L("A working title will do. You can change it whenever you like."))
                        .foregroundStyle(.secondary).padding(.top, 14)
                }
                if let error { Text(error).font(.ui(12)).foregroundStyle(Ink.error).padding(.top, 8) }
                Spacer(minLength: 16)
                existing
            }
            .frame(width: 720)
            .frame(maxWidth: .infinity)
            .padding(.bottom, 28)
        }
        .overlay { if dropping { RoundedRectangle(cornerRadius: 12).strokeBorder(Ink.accent, lineWidth: 2).padding(10) } }
        .dropDestination(for: URL.self, action: { urls, _ in
            if let u = urls.first { Task { await begin(u) } }
            return !urls.isEmpty
        }, isTargeted: { dropping = $0 })
        .ignoresSafeArea(.container, edges: .top)
        .onAppear {
            focused = true
            // Development aid, like -musset-screen: opens the check screen for a file at launch.
            let args = ProcessInfo.processInfo.arguments
            if let i = args.firstIndex(of: "-musset-import"), i + 1 < args.count { Task { await begin(URL(fileURLWithPath: args[i + 1])) } }
        }
    }

    private var languageSwitch: some View {
        Menu {
            ForEach(UILang.allCases.filter { $0 != .system }) { l in
                Button { uiLanguage = l.rawValue } label: {
                    if l == UILang.current { Label(l.label, systemImage: "checkmark") } else { Text(l.label) }
                }
            }
        } label: {
            Label(UILang.current.label, systemImage: "globe").font(.ui(12))
        }
        .menuStyle(.borderlessButton).fixedSize()
        .accessibilityLabel(L("Interface language"))
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text(L("Genre")).foregroundStyle(.secondary).frame(width: 104, alignment: .leading)
                GenrePicker(genre: $genre)
            }
            HStack(spacing: 12) {
                Text(L("Book language")).foregroundStyle(.secondary).frame(width: 104, alignment: .leading)
                BookLanguagePicker(code: $lang)
            }
            Text(BookGenres.effect(genre)).font(.ui(12)).foregroundStyle(.secondary).padding(.leading, 116)
            HStack(spacing: 16) {
                if editing {
                    TextField(L("Author"), text: $author).textFieldStyle(.roundedBorder).frame(width: 180)
                    Button(L("Choose a place…")) { chooseLocation() }.buttonStyle(.inkSecondary)
                } else {
                    (Text(path).font(.uiMono(12)) + Text(" · " + author)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Button(L("Change")) { editing = true }.buttonStyle(.link)
                }
                Spacer()
                if working { ProgressView().controlSize(.small) }
                Button(L("Continue") + " ↩") { choosingForm = true }.buttonStyle(.ink).disabled(working)
            }
            .padding(.top, 4)
            if !Collab.shared.canSync {
                Toggle(isOn: $keepInSync) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L("Also keep it in Musset Sync")).fontWeight(.medium) + Text(" · " + SyncPrice.perMonth).foregroundColor(.secondary)
                        Text(L("The book on all your Macs, with every version, and safe if this one is lost. Invite an editor or beta readers: they don’t pay."))
                            .font(.ui(12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.checkbox)
                .padding(12)
                .background(Ink.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: Radius.card))
                .overlay(RoundedRectangle(cornerRadius: Radius.card).strokeBorder(Ink.accent.opacity(0.2)))
                .padding(.top, 10)
            }
        }
        .padding(.top, 14)
    }

    private var existing: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("Or pick up a book that already exists")).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                tile("folder", L("A folder"), L("Markdown files")) { app.addBookViaPanel(); finish() }
                tile("doc.richtext", "Word", L(".docx file")) { pick(types: ["docx"], directories: false) }
                tile("books.vertical", "Scrivener", L(".scriv project")) { pick(types: ["scriv"], directories: true) }
                tile("text.justify.left", "Ulysses", L("Markdown export")) { pick(types: [], directories: true) }
            }
            HStack {
                Text(L("You can also drop a file on this window."))
                Spacer()
                Button(L("Find my books with my Musset account")) { app.showAccount(); if sheet { dismiss() } }.buttonStyle(.link)
            }
            .font(.ui(12)).foregroundStyle(.secondary)
        }
    }

    private func tile(_ icon: String, _ name: String, _ what: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: icon).font(.ui(17)).frame(height: 22)
                VStack(alignment: .leading, spacing: 0) {
                    Text(name).font(.ui(13, .medium))
                    Text(what).font(.ui(12)).foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
            .background(Ink.panel, in: RoundedRectangle(cornerRadius: Radius.card))
            .overlay(RoundedRectangle(cornerRadius: Radius.card).strokeBorder(Ink.hairline))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func pick(types: [String], directories: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = directories
        panel.canChooseFiles = !types.isEmpty
        panel.treatsFilePackagesAsDirectories = false
        panel.allowedContentTypes = types.compactMap { UTType(filenameExtension: $0) }
        if panel.runModal() == .OK, let u = panel.url { Task { await begin(u) } }
    }

    /// Whatever was given, what it holds, for the author to check.
    private func begin(_ url: URL) async {
        error = nil
        working = true
        defer { working = false }
        do {
            let scratch = FileManager.default.temporaryDirectory
            switch url.pathExtension.lowercased() {
            case "docx": plan = try await BookImporter.planWord(url)
            case "scriv": plan = try await BookImporter.planScrivener(url, cwd: scratch)
            default:
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
                    throw BibleImporter.Failure(L("Musset takes a .docx, a .scriv project or a folder."))
                }
                plan = try BookImporter.planFolder(url)
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func chooseLocation() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = location
        if panel.runModal() == .OK, let u = panel.url { location = u }
    }

    private func createBlank() {
        guard hasTitle else { return }
        Task {
            working = true
            defer { working = false }
            do {
                // The first piece, named as the form names its pieces: « Chapitre 1 », « Entrée 1 ».
                var shape = BookManifest(title: "", author: "", lang: lang, chapters: [])
                shape.setForm(form)
                let name = shape.newPieceTitle(1)
                try await app.createBook(at: location.appendingPathComponent(slug), title: title.trimmingCharacters(in: .whitespaces), author: author, lang: lang, genre: genre,
                                         form: form, chapters: [PlannedChapter(title: name, text: "# \(name)\n\n")])
                finish()
            } catch { self.error = error.localizedDescription }
        }
    }

    private func importBook() {
        guard let plan else { return }
        Task {
            working = true
            defer { working = false }
            error = nil
            do {
                let chapters = plan.source == .word ? try await BookImporter.chapters(of: plan, cwd: FileManager.default.temporaryDirectory) : plan.chapters
                try await app.createBook(at: location.appendingPathComponent(BibleStore.slug(plan.title)), title: plan.title, author: author, lang: lang, genre: genre, chapters: chapters)
                self.plan = nil
                finish()
            } catch { self.error = error.localizedDescription }
        }
    }

    private func finish() {
        UserDefaults.standard.set(author, forKey: "lastAuthor")
        app.showHome = false
        if sheet { dismiss() }
        let offer = keepInSync && !Collab.shared.canSync
        let firstBook = !UserDefaults.standard.bool(forKey: "helpersSeen") && !AIStatus.shared.isOn
        guard offer || firstBook else { return }
        Task { @MainActor in
            // After this window closes: one sheet at a time.
            try? await Task.sleep(nanoseconds: 450_000_000)
            if offer { app.offerSync(for: app.current) } else { app.showHelpers = true }
        }
    }
}

struct PillRow: View {
    let options: [(String, String)]
    @Binding var selection: String
    var body: some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.0) { id, name in
                Button { selection = id } label: {
                    Text(name).font(.ui(12)).padding(.horizontal, 10).frame(height: 26)
                        .foregroundStyle(selection == id ? Color.primary : .secondary)
                        .background(selection == id ? Ink.selected : .clear, in: Capsule())
                        .overlay(Capsule().strokeBorder(selection == id ? Color.primary : Ink.hairline))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct GenrePicker: View {
    @Binding var genre: String
    var body: some View {
        HStack(spacing: 4) {
            PillRow(options: BookGenres.first.map { ($0, BookGenres.label($0)) }, selection: $genre)
            Menu(BookGenres.first.contains(genre) ? L("Other…") : BookGenres.label(genre)) {
                ForEach(ScoringLibrary.shared.presets.filter { !BookGenres.first.contains($0.id) }) { p in
                    Button(p.name) { genre = p.id }
                }
            }
            .menuStyle(.borderlessButton).fixedSize().font(.ui(12))
        }
    }
}

/// What was found in the file, before anything is created.
struct ImportReviewView: View {
    @Binding var plan: ImportPlan
    @Binding var genre: String
    @Binding var lang: String
    @Binding var author: String
    @Binding var location: URL
    @Binding var error: String?
    let working: Bool
    let cancel: () -> Void
    let create: () -> Void
    @State private var showText = false

    private var heading: String {
        switch plan.source {
        case .word: L("Import from Word")
        case .scrivener: L("Import from Scrivener")
        case .ulysses: L("Import from Ulysses")
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack { Text(heading).foregroundStyle(.secondary).padding(.leading, 76); Spacer() }
                .frame(height: 44).background(WindowDragArea())
            Divider()
            HStack(spacing: 0) {
                left.frame(width: 400)
                Divider()
                right
            }
        }
        .ignoresSafeArea(.container, edges: .top)
    }

    private var left: some View {
        ScrollView { leftContent }.background(Ink.side)
    }

    private var leftContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L("Title")).font(.ui(12)).foregroundStyle(.secondary)
                TextField("", text: $plan.title).textFieldStyle(.plain).font(.system(size: 26, design: .serif))
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(L("Genre")).font(.ui(12)).foregroundStyle(.secondary)
                Picker("", selection: $genre) { ForEach(ScoringLibrary.shared.presets) { Text($0.name).tag($0.id) } }.labelsHidden()
                Text(L("Book language")).font(.ui(12)).foregroundStyle(.secondary)
                BookLanguagePicker(code: $lang)
                Text(L("Author")).font(.ui(12)).foregroundStyle(.secondary)
                TextField("", text: $author).textFieldStyle(.roundedBorder)
                Text(location.appendingPathComponent(BibleStore.slug(plan.title)).path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(.uiMono(12)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(L("What Musset keeps")).font(.ui(13, .medium))
                ForEach(Array(plan.keeps.enumerated()), id: \.offset) { _, k in
                    HStack(alignment: .firstTextBaseline, spacing: 8) { Text(k.from).foregroundStyle(.secondary).frame(width: 150, alignment: .leading); Text(k.to) }
                }
            }
            Text(plan.rule).font(.ui(12)).padding(.horizontal, 12).padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Ink.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: Radius.control))
            Text(L("Your original file stays as it is. Musset works on a copy.")).font(.ui(12)).foregroundStyle(.secondary)
        }
        .padding(28)
    }

    private var right: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(L("\(plan.chapterCount) chapters, \(plan.wordCount.ui) words")).font(.ui(15, .medium))
                Spacer()
                if plan.source == .word { Toggle(L("Show the text"), isOn: $showText).toggleStyle(.checkbox) }
            }
            .padding(.horizontal, 32).padding(.top, 28).padding(.bottom, 12)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if plan.source == .word {
                        if showText { textLines } else { wordRows }
                    } else {
                        ForEach(Array(plan.chapters.enumerated()), id: \.element.id) { i, c in
                            row(number: "\(i + 1)", title: c.title, words: "\(BookStore.wordCount(c.text).ui)") {
                                Button { plan.chapters.remove(at: i) } label: { Image(systemName: "xmark").font(.ui(11)) }.buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel(L("Leave out"))
                            }
                        }
                    }
                }
                .padding(.horizontal, 32)
            }
            Divider()
            HStack(spacing: 8) {
                if let error { Text(error).font(.ui(12)).foregroundStyle(Ink.error).lineLimit(2) }
                Spacer()
                if working { ProgressView().controlSize(.small) }
                Button(L("Cancel"), action: cancel).buttonStyle(.inkSecondary).keyboardShortcut(.cancelAction)
                Button(L("Create book"), action: create).buttonStyle(.ink).disabled(working || plan.title.isEmpty || plan.chapterCount == 0 && plan.source != .word)
            }
            .padding(.horizontal, 32).padding(.vertical, 14)
        }
    }

    private func row<T: View>(number: String, title: String, words: String, @ViewBuilder trailing: () -> T) -> some View {
        HStack(spacing: 10) {
            Text(number).font(.uiMono(11)).foregroundStyle(.secondary).frame(width: 22, alignment: .trailing)
            Text(title).lineLimit(1)
            Spacer()
            Text(words).font(.ui(12)).foregroundStyle(.secondary)
            trailing()
        }
        .frame(height: 34)
        .overlay(alignment: .bottom) { Divider() }
    }

    @ViewBuilder private var wordRows: some View {
        let rows = plan.wordRows
        let numbered = rows.filter { $0.mark == .chapter }
        ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
            if r.mark == .candidate {
                row(number: "", title: r.title, words: L("Marked, but alone: not a chapter")) {
                    Button(L("Make it a chapter")) { plan.marks[r.index] = .chapter }.buttonStyle(.inkSecondary)
                }
            } else {
                row(number: "\((numbered.firstIndex { $0.index == r.index } ?? 0) + 1)", title: r.title, words: r.words.ui) {
                    if r.index >= 0 {
                        Button { plan.marks[r.index] = .body } label: { Image(systemName: "xmark").font(.ui(11)) }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                            .help(L("Remove this break"))
                            .accessibilityLabel(L("Remove this break"))
                    }
                }
            }
        }
    }

    /// Every line: a click cuts there, for a chapter Musset missed.
    private var textLines: some View {
        ForEach(Array(plan.paragraphs.enumerated()).filter { !$0.element.text.isEmpty }, id: \.offset) { i, p in
            Button {
                plan.marks[i] = plan.marks[i] == .chapter ? .body : .chapter
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: plan.marks[i] == .chapter ? "scissors" : "minus").font(.ui(10)).foregroundStyle(plan.marks[i] == .chapter ? Ink.accent : Color(nsColor: .tertiaryLabelColor)).frame(width: 14)
                    Text(p.text).lineLimit(1).font(.ui(12, plan.marks[i] == .chapter ? .semibold : .regular))
                    Spacer(minLength: 0)
                }
                .frame(height: 24).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}
