import SwiftUI
import UniformTypeIdentifiers

/// The book's sources: every reference, where each is cited, the citations with no source, the file read for each,
/// and the bibliography printed at the end of the book.
struct SourcesView: View {
    let app: AppState
    @Bindable var session: BookSession
    @State private var identifier = ""
    @State private var working = false
    @State private var message: String?
    @State private var filter = Filter.all
    @State private var selection: String?

    enum Filter: String, CaseIterable { case all, cited, uncited, file }

    private var bible: BibleModel { session.bible }
    private var references: [BibleEntry] { References.entries(session) }

    private var shown: [BibleEntry] {
        references.filter { e in
            switch filter {
            case .all: true
            case .cited: References.citeCount(of: e, in: session) > 0
            case .uncited: References.citeCount(of: e, in: session) == 0
            case .file: e.meta["file"] != nil
            }
        }
        .sorted { CitationPages.inverted($0.meta["author"] ?? $0.title).localizedCaseInsensitiveCompare(CitationPages.inverted($1.meta["author"] ?? $1.title)) == .orderedAscending }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(L("Sources")).font(.system(size: 28, design: .serif))
                    let cited = references.filter { References.citeCount(of: $0, in: session) > 0 }.count
                    Text(L("\(references.count) sources") + " · " + L("\(cited) cited in the book")).font(.ui(12)).foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    TextField(L("Paste a DOI, an ISBN or a link, or drop a .bib, .ris or PDF"), text: $identifier)
                        .textFieldStyle(.roundedBorder).onSubmit(add)
                    Button(L("Add"), action: add).buttonStyle(.ink).disabled(identifier.isEmpty || working)
                }
                if let message { Text(message).font(.ui(12)).foregroundStyle(.secondary) }
                ForEach(References.missing(in: session), id: \.self) { key in
                    HStack(spacing: 8) {
                        Text(L("Missing")).font(.ui(12, .semibold)).foregroundStyle(Ink.critique)
                        Text("[@\(key)]").font(.uiMono(12))
                        Text(L("is cited but isn’t among your sources.")).font(.ui(12))
                        Spacer()
                    }
                    .padding(8).background(RoundedRectangle(cornerRadius: Radius.control).fill(Ink.critique.opacity(0.08)))
                }
                Picker("", selection: $filter) {
                    Text(L("All", ctx: "Tout")).tag(Filter.all)
                    Text(L("Cited")).tag(Filter.cited)
                    Text(L("Not cited yet")).tag(Filter.uncited)
                    Text(L("With a file")).tag(Filter.file)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Table(shown, selection: $selection) {
                    TableColumn(L("Author")) { e in Text(CitationPages.inverted(e.meta["author"] ?? "")) }.width(min: 120, ideal: 160)
                    TableColumn(L("Title")) { e in Text(e.title) }
                    TableColumn(L("Year")) { e in Text(e.meta["year"] ?? "").foregroundStyle(.secondary) }.width(50)
                    TableColumn(L("Cited")) { e in
                        let n = References.citeCount(of: e, in: session)
                        Text("\(n)").foregroundStyle(n == 0 ? .tertiary : .primary).monospacedDigit()
                    }.width(50)
                }
            }
            .padding(.horizontal, 28).padding(.top, 28).padding(.bottom, 16)
            Divider()
            detail.frame(width: 400)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .dropDestination(for: URL.self) { urls, _ in
            Task { working = true; message = await BibleImporter.importAll(urls, into: BibleStore.documents, session: session); working = false }
            return true
        }
        .onAppear { selection = selection ?? shown.first?.path }
    }

    @ViewBuilder private var detail: some View {
        ScrollView {
            if let path = selection, let e = bible.entry(path: path) {
                VStack(alignment: .leading, spacing: 14) {
                    Text((e.meta["citekey"].map { "@" + $0 } ?? "")).font(.uiMono(12)).foregroundStyle(.secondary)
                    Text(e.title).font(.system(size: 21, design: .serif)).fixedSize(horizontal: false, vertical: true)
                    Grid(alignment: .leading, verticalSpacing: 6) {
                        field(L("Author"), e.meta["author"])
                        field(L("Publisher"), e.meta["publisher"])
                        field(L("Year"), e.meta["year"])
                        field("DOI", e.meta["doi"])
                        field("ISBN", e.meta["isbn"])
                    }
                    .font(.ui(13))
                    HStack {
                        if let file = e.meta["file"] {
                            Button((file as NSString).lastPathComponent) { app.open(.sheet(file)) }.buttonStyle(.link)
                            let kept = Highlights.read(bible.store.url(file + ".md")).count
                            if kept > 0 { Text(L("\(kept) highlights")).foregroundStyle(.secondary) }
                        } else {
                            Button(L("Attach the PDF…")) { attach(e) }.buttonStyle(.link)
                        }
                        Spacer()
                        Button(L("Edit")) { app.open(.sheet(e.path)) }.buttonStyle(.link)
                    }
                    .font(.ui(12))
                    let places = e.meta["citekey"].map { References.places(of: $0, in: session) } ?? []
                    if !places.isEmpty {
                        Text(L("Cited in the book")).font(.ui(11, .medium)).foregroundStyle(.secondary)
                        ForEach(Array(places.enumerated()), id: \.offset) { _, p in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(p.excerpt).font(.uiMono(11)).fixedSize(horizontal: false, vertical: true)
                                Button(session.manifest.chapters.first { $0.id == p.chapter }?.title ?? p.chapter) {
                                    app.showChapter(); session.open(p.chapter); session.pendingSelection = p.range
                                }
                                .buttonStyle(.link).font(.ui(11))
                            }
                            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: Radius.control).fill(Color(nsColor: .textBackgroundColor)))
                        }
                    }
                    if !e.body.isEmpty {
                        Text(L("Your notes")).font(.ui(11, .medium)).foregroundStyle(.secondary)
                        Text(e.body).font(.uiMono(12))
                    }
                    Divider()
                    Text(L("At the end of the book")).font(.ui(11, .medium)).foregroundStyle(.secondary)
                    Text(L("The cited sources, in author-date style (Chicago), in both exports.")).font(.ui(12))
                    // The title in italics, as it prints (the entry is Markdown).
                    Text((try? AttributedString(markdown: CitationPages.entry(author: CitationPages.inverted(e.meta["author"] ?? ""), year: e.meta["year"], title: e.title, publisher: e.meta["publisher"])))
                         ?? AttributedString(e.title))
                        .font(.uiMono(11)).foregroundStyle(.secondary)
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(L("Add a source by its DOI or ISBN, or drop a bibliography here.")).font(.ui(12)).foregroundStyle(.secondary).padding(24)
            }
        }
        .background(Ink.side)
    }

    @ViewBuilder private func field(_ name: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            GridRow {
                Text(name).foregroundStyle(.secondary)
                Text(value).textSelection(.enabled)
            }
        }
    }

    private func add() {
        let text = identifier.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        working = true
        message = nil
        Task {
            do { try await BibleImporter.add(identifier: text, session: session); identifier = "" }
            catch { message = error.localizedDescription }
            working = false
        }
    }

    /// A PDF read for this source: brought into the documents and kept with it.
    private func attach(_ e: BibleEntry) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        guard panel.runModal() == .OK, let url = panel.url, let path = try? bible.bring(url) else { return }
        var next = e
        next.meta["file"] = path
        try? bible.save(next)
        session.pendingCommit = true
    }
}
