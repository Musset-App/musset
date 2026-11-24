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
        default: ScoringLibrary.shared.presets.first { $0.id == id }?.shownName ?? id
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
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Musset").font(.system(size: 30, design: .serif)).padding(.top, 12)
                    Text(L("A calm place to write a book, and to watch it become one.")).font(.ui(15)).foregroundStyle(.secondary).padding(.top, 6)
                    // The one question. Return starts the book: a novel, in the language of the interface.
                    Text(L("What is your book called?")).foregroundStyle(.secondary).padding(.top, 40)
                    TextField("", text: $title, prompt: Text(L("A working title")).foregroundColor(Color(nsColor: .tertiaryLabelColor)))
                        .textFieldStyle(.plain).font(.uiMono(34)).focused($focused)
                        .padding(.top, 10).padding(.bottom, 12)
                        .overlay(alignment: .bottom) { Rectangle().fill(Ink.accent).frame(height: 1.5) }
                        .onSubmit { if hasTitle { createBlank() } }
                        .accessibilityLabel(L("Book title"))
                    if editing { details } else { start }
                    if let error { Text(error).font(.ui(12)).foregroundStyle(Ink.error).padding(.top, 8) }
                    doors.padding(.top, 44)
                    HStack {
                        Spacer()
                        Button(L("Find my books with my Musset account")) { app.showAccount(); if sheet { dismiss() } }.buttonStyle(.link)
                    }
                    .font(.ui(12)).foregroundStyle(.secondary).padding(.top, 18)
                }
                .frame(width: 720)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 28)
            }
        }
        .overlay { if dropping { RoundedRectangle(cornerRadius: 12).strokeBorder(Ink.accent, lineWidth: 2).padding(10) } }
        .dropDestination(for: URL.self, action: { urls, _ in
            if let u = urls.first { Task { await begin(u) } }
            return !urls.isEmpty
        }, isTargeted: { dropping = $0 })
        .ignoresSafeArea(.container, edges: .top)
        .onAppear {
            focused = true
            // Development aids, like -musset-screen: `-musset-import <file>` opens the check screen for a file at launch,
            // `-musset-title <title>` types a title, `-musset-step more` opens the other choices and `-musset-step form`
            // goes on to the form. (Launch arguments are read as defaults, so a test can set them too.)
            let d = UserDefaults.standard
            if let t = d.string(forKey: "musset-title") {
                title = t
                editing = d.string(forKey: "musset-step") != nil
                choosingForm = d.string(forKey: "musset-step") == "form"
            }
            if let f = d.string(forKey: "musset-import") { Task { await begin(URL(fileURLWithPath: f)) } }
        }
    }

    /// Under the title: what Return does, and the way to the other choices for those who want them.
    private var start: some View {
        HStack(spacing: 16) {
            Text(hasTitle ? L("Press Return and start writing. Nothing else to decide.") : L("Anything will do. You can change it whenever you like."))
                .foregroundStyle(.secondary)
            Spacer()
            if working { ProgressView().controlSize(.small) }
            if hasTitle {
                Button(L("More choices")) { editing = true }.buttonStyle(.link)
                Button(L("Start writing") + " ↩") { createBlank() }.buttonStyle(.ink).disabled(working)
            }
        }
        .padding(.top, 14)
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

    /// The other choices, for those who asked: genre, language, form, where it is kept.
    private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text(L("Genre")).foregroundStyle(.secondary).frame(width: 104, alignment: .leading)
                GenrePicker(genre: $genre)
                    // An essay is written with sub-headings and lists: it takes the essay's form, unless another was chosen.
                    .onChange(of: genre) { old, new in
                        if new == "essai", form == .novel { form = .essay } else if old == "essai", form == .essay { form = .novel }
                    }
            }
            HStack(spacing: 12) {
                Text(L("Book language")).foregroundStyle(.secondary).frame(width: 104, alignment: .leading)
                BookLanguagePicker(code: $lang)
            }
            HStack(spacing: 12) {
                Text(L("Author")).foregroundStyle(.secondary).frame(width: 104, alignment: .leading)
                TextField(L("Author"), text: $author).textFieldStyle(.roundedBorder).frame(width: 220)
            }
            HStack(spacing: 12) {
                Text(L("Kept in")).foregroundStyle(.secondary).frame(width: 104, alignment: .leading)
                Text(path).font(.uiMono(12)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Button(L("Choose a place…")) { chooseLocation() }.buttonStyle(.link)
            }
            HStack(spacing: 10) {
                Spacer()
                if working { ProgressView().controlSize(.small) }
                Button(L("Novel, journal, play…")) { choosingForm = true }.buttonStyle(.inkSecondary).disabled(working || !hasTitle)
                Button(L("Start writing") + " ↩") { createBlank() }.buttonStyle(.ink).disabled(working || !hasTitle)
            }
            .padding(.top, 6)
        }
        .padding(.top, 14)
    }

    /// The two other doors: a book that already exists, and a book to look around in.
    private var doors: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                Text(L("Bring a book you have started")).font(.ui(13, .medium))
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    tile("doc.richtext", "Word", L(".docx file")) { pick(types: ["docx"], directories: false) }
                    tile("books.vertical", "Scrivener", L(".scriv project")) { pick(types: ["scriv"], directories: true) }
                    tile("text.justify.left", "Ulysses", L("Markdown export")) { pick(types: [], directories: true) }
                    tile("folder", L("A folder"), L("Markdown files")) { app.addBookViaPanel(); finish() }
                }
                Text(L("Or drop it on this window. Your original is never changed.")).font(.ui(12)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 10) {
                Text(L("Or look around first")).font(.ui(13, .medium))
                Button { openExample() } label: {
                    HStack(alignment: .center, spacing: 16) {
                        ExamplePage(lang: lang)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(ExampleBook.title(lang)).font(.system(size: 19, design: .serif))
                            Text(ExampleBook.author).foregroundStyle(.secondary)
                            Spacer(minLength: 6)
                            Text(L("Open the example book") + " →").font(.ui(13, .medium)).foregroundStyle(Ink.accent)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, minHeight: 136, maxHeight: 136, alignment: .leading)
                    .background(Ink.panel, in: RoundedRectangle(cornerRadius: Radius.card))
                    .overlay(RoundedRectangle(cornerRadius: Radius.card).strokeBorder(Ink.hairline))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).disabled(working)
                Text(L("A finished novel with its characters, places, notes and versions. Remove it whenever you like.")).font(.ui(12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func openExample() {
        Task {
            working = true
            defer { working = false }
            error = nil
            do {
                try await ExampleBook.open(in: app, at: location, lang: lang)
                finish()
            } catch { self.error = error.localizedDescription }
        }
    }

    private func tile(_ icon: String, _ name: String, _ what: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: icon).font(.ui(17)).frame(width: 24)
                VStack(alignment: .leading, spacing: 0) {
                    Text(name).font(.ui(13, .medium))
                    Text(what).font(.ui(12)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
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
                finish(imported: true)
            } catch { self.error = error.localizedDescription }
        }
    }

    /// The book is open. Nothing is offered over it: the AI readers and Musset Sync wait until there is something
    /// written to offer them on (`AppState.considerOffers`, in FirstSteps.swift). An imported book opens as a book, typeset.
    private func finish(imported: Bool = false) {
        UserDefaults.standard.set(author, forKey: "lastAuthor")
        app.showHome = false
        if sheet { dismiss() }
        if imported { app.showAsBook() }
    }
}

/// A small printed page, for the example book's door.
struct ExamplePage: View {
    let lang: String
    var body: some View {
        VStack(spacing: 5) {
            Text(ExampleBook.title(lang).uppercased()).font(.system(size: 6.5, design: .serif)).tracking(0.8).multilineTextAlignment(.center).padding(.top, 16)
            Rectangle().fill(Color.black.opacity(0.25)).frame(width: 14, height: 0.5).padding(.bottom, 4)
            ForEach(0..<9, id: \.self) { i in
                Rectangle().fill(Color.black.opacity(0.16)).frame(width: i == 8 ? 34 : (i == 0 ? 50 : 56), height: 1.5).frame(width: 56, alignment: i == 0 ? .trailing : .leading)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(Color.black.opacity(0.75))
        .frame(width: 78, height: 112)
        .background(Color.white)
        .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
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
                    Button(p.shownName) { genre = p.id }
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
                Picker("", selection: $genre) { ForEach(ScoringLibrary.shared.presets) { Text(BookGenres.label($0.id)).tag($0.id) } }.labelsHidden()
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
