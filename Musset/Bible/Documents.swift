import PDFKit
import Quartz
import SwiftUI
import Vision

/// Bringing things into the Bible: files, web pages, DOIs and ISBNs, bibliographies.
@MainActor
enum BibleImporter {
    /// Above this, a file is linked where it is rather than copied.
    static let linkThreshold: Int64 = 20_000_000

    @discardableResult
    static func importAll(_ urls: [URL], into folder: String, session: BookSession) async -> String? {
        var failures: [String] = []
        var linked = 0
        for url in urls {
            do {
                if url.isFileURL {
                    if try await importFile(url, into: folder, session: session) { linked += 1 }
                } else {
                    _ = try await importWeb(url, session: session)
                }
            } catch {
                failures.append(url.lastPathComponent + " : " + error.localizedDescription)
            }
        }
        session.bible.reload()
        session.pendingCommit = true
        if !failures.isEmpty { return failures.joined(separator: "\n") }
        return linked > 0 ? L("Large files are linked, not copied: they stay where they are and do not follow the book to another Mac.") : nil
    }

    /// Returns true when the file was linked rather than copied.
    private static func importFile(_ url: URL, into folder: String, session: BookSession) async throws -> Bool {
        let store = session.bible.store
        let ext = url.pathExtension.lowercased()
        if ["bib", "bibtex", "ris"].contains(ext) {
            try await importBibliography(url, session: session)
            return false
        }
        if ["md", "markdown", "txt"].contains(ext) {
            let text = try String(contentsOf: url, encoding: .utf8)
            let title = url.deletingPathExtension().lastPathComponent
            var entry = BibleEntry.parse(path: store.freePath(title: title, folder: folder == BibleStore.documents ? "a-trier" : folder), text: text)
            entry.title = entry.title == (entry.path as NSString).lastPathComponent ? title : entry.title
            try store.write(entry)
            return false
        }
        // A document always goes to the documents folder: out of git, never sent to a reader.
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0 ?? 0) } ?? 0
        if size > linkThreshold {
            let title = url.lastPathComponent
            var entry = BibleEntry(path: store.freePath(title: title, folder: BibleStore.documents), kind: .document, title: title)
            entry.meta["linked"] = url.path
            try store.write(entry)
            return true
        }
        let path = store.freePath(title: url.deletingPathExtension().lastPathComponent, folder: BibleStore.documents, ext: ext.isEmpty ? "bin" : ext)
        try store.prepare(store.url(path))
        try FileManager.default.copyItem(at: url, to: store.url(path))
        return false
    }

    /// A web address, a DOI or an ISBN, as pasted.
    static func add(identifier text: String, session: BookSession) async throws {
        if let doi = References.doi(in: text) {
            try await addReference(References.fetch(doi: doi), session: session)
        } else if let isbn = References.isbn(in: text) {
            try await addReference(References.fetch(isbn: isbn), session: session)
        } else if let url = URL(string: text), url.scheme?.hasPrefix("http") == true {
            _ = try await importWeb(url, session: session)
        } else {
            throw Failure(L("Not a web address, a DOI or an ISBN."))
        }
        session.bible.reload()
        session.pendingCommit = true
    }

    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    /// Keeps a readable copy: sites disappear, and the book's sources should not.
    static func importWeb(_ url: URL, session: BookSession) async throws -> BibleEntry {
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh) Musset", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw Failure(L("The site answered \(http.statusCode)."))
        }
        let html = String(decoding: data, as: UTF8.self)
        let title = Self.title(html) ?? url.host ?? url.absoluteString
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("musset-web-\(UUID()).html")
        try Self.mainContent(html).write(to: scratch, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let out = try await ExportService.runPandoc([scratch.path, "-f", "html-native_divs-native_spans", "-t", "gfm-raw_html", "--wrap=none"], cwd: session.root)
        guard out.ok else { throw Failure(out.stderr) }
        var meta = ["source": url.absoluteString, "date": ISO8601DateFormatter().string(from: Date())]
        if let archive = await WebArchiver.archive(url) {
            let path = session.bible.store.freePath(title: title, folder: BibleStore.documents, ext: "webarchive")
            if (try? session.bible.store.prepare(session.bible.store.url(path))) != nil,
               (try? archive.write(to: session.bible.store.url(path))) != nil { meta["archive"] = path }
        }
        return try session.bible.create(title: title, kind: .web, folder: BibleStore.documents, body: out.stdout, meta: meta)
    }

    static func title(_ html: String) -> String? {
        guard let r = html.range(of: "<title[^>]*>([^<]+)</title>", options: [.regularExpression, .caseInsensitive]) else { return nil }
        let t = html[r].replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// The article when the page marks one; otherwise the page, without its scripts, menus and footers.
    static func mainContent(_ html: String) -> String {
        var text = html
        for tag in ["script", "style", "nav", "footer", "aside", "form", "header", "svg", "noscript"] {
            text = text.replacingOccurrences(of: "<\(tag)\\b[^>]*>[\\s\\S]*?</\(tag)>", with: "", options: [.regularExpression, .caseInsensitive])
        }
        for tag in ["article", "main"] {
            if let r = text.range(of: "<\(tag)\\b[^>]*>[\\s\\S]*</\(tag)>", options: [.regularExpression, .caseInsensitive]) { return String(text[r]) }
        }
        return text
    }

    private static func addReference(_ ref: Reference, session: BookSession) async throws {
        _ = try session.bible.create(title: ref.title, kind: .reference, folder: BibleStore.documents, meta: ref.meta(taken: References.keys(session)))
    }

    /// `.bib` and `.ris`, through pandoc: each entry becomes a reference of its own.
    private static func importBibliography(_ url: URL, session: BookSession) async throws {
        let format = url.pathExtension.lowercased() == "ris" ? "ris" : "bibtex"
        let out = try await ExportService.runPandoc([url.path, "-f", format, "-t", "csljson"], cwd: session.root)
        guard out.ok else { throw Failure(out.stderr) }
        var taken = References.keys(session)
        for ref in try References.parseCSL(Data(out.stdout.utf8)) {
            let meta = ref.meta(taken: taken)
            taken.insert(meta["citekey"] ?? "")
            _ = try session.bible.create(title: ref.title, kind: .reference, folder: BibleStore.documents, meta: meta)
        }
    }
}

/// A book, an article: what a citation needs.
struct Reference: Equatable {
    var key = ""
    var title = ""
    var author = ""
    var year = ""
    var publisher = ""
    var doi = ""
    var isbn = ""

    func meta(taken: Set<String>) -> [String: String] {
        var base = key.isEmpty ? BibleStore.slug(author.split(whereSeparator: { $0 == " " || $0 == "," }).first.map(String.init) ?? title) + year : key
        base = base.replacingOccurrences(of: "-", with: "")
        var candidate = base
        var n = 2
        while taken.contains(candidate) { candidate = base + "-\(n)"; n += 1 }
        var m = ["citekey": candidate]
        if !author.isEmpty { m["author"] = author }
        if !year.isEmpty { m["year"] = year }
        if !publisher.isEmpty { m["publisher"] = publisher }
        if !doi.isEmpty { m["doi"] = doi }
        if !isbn.isEmpty { m["isbn"] = isbn }
        return m
    }
}

@MainActor
enum References {
    private static let citation = try! NSRegularExpression(pattern: "\\[(?:[^\\]\\n]*?)@([\\p{L}\\p{N}_:.#$%&+?<>~/-]+)[^\\]\\n]*\\]")

    /// `[@clé]` in a text. `@[Titre]` is a link and is not matched.
    nonisolated static func citations(in text: String) -> [String] {
        let ns = text as NSString
        return citation.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            ns.substring(with: m.range).hasPrefix("@") ? nil : ns.substring(with: m.range(at: 1))
        }
    }

    static func entries(_ session: BookSession) -> [BibleEntry] { session.bible.entries.filter { $0.kind == .reference } }
    static func keys(_ session: BookSession) -> Set<String> { Set(entries(session).compactMap { $0.meta["citekey"] }) }

    /// Chapter id → the citations of its text, as last read (keyed by the text's fingerprint).
    private static var cache: [String: (fingerprint: String, keys: [String])] = [:]

    static func citations(of chapter: String, in session: BookSession) -> [String] {
        let text = session.editorText(of: chapter)
        let f = PlotGrid.fingerprint(text)
        if let hit = cache[session.root.path + chapter], hit.fingerprint == f { return hit.keys }
        let keys = citations(in: text)
        cache[session.root.path + chapter] = (f, keys)
        return keys
    }

    private static func allCitations(_ session: BookSession) -> [String] {
        session.manifest.chapters.flatMap { citations(of: $0.id, in: session) }
    }

    /// Where a source is cited: chapter, and the sentence around each citation.
    static func places(of key: String, in session: BookSession) -> [(chapter: String, range: NSRange, excerpt: String)] {
        var out: [(String, NSRange, String)] = []
        for ch in session.manifest.chapters where citations(of: ch.id, in: session).contains(key) {
            let text = session.editorText(of: ch.id)
            let ns = text as NSString
            var search = NSRange(location: 0, length: ns.length)
            while true {
                let r = ns.range(of: "@" + key, range: search)
                guard r.location != NSNotFound else { break }
                let lo = max(0, r.location - 90), hi = min(ns.length, NSMaxRange(r) + 30)
                out.append((ch.id, r, "…" + ns.substring(with: NSRange(location: lo, length: hi - lo)).replacingOccurrences(of: "\n", with: " ") + "…"))
                search = NSRange(location: NSMaxRange(r), length: ns.length - NSMaxRange(r))
            }
        }
        return out
    }

    static func citeCount(of e: BibleEntry, in session: BookSession) -> Int {
        guard let key = e.meta["citekey"] else { return 0 }
        return allCitations(session).filter { $0 == key }.count
    }

    static func missing(in session: BookSession) -> [String] {
        let known = keys(session)
        return Array(Set(allCitations(session))).filter { !known.contains($0) }.sorted()
    }

    nonisolated static func doi(in text: String) -> String? {
        guard let r = text.range(of: "10\\.[0-9]{4,9}/\\S+", options: .regularExpression) else { return nil }
        return String(text[r])
    }

    nonisolated static func isbn(in text: String) -> String? {
        let digits = text.filter { $0.isNumber || $0 == "X" || $0 == "x" }
        guard digits.count == 10 || digits.count == 13, !text.contains("/"), !text.contains("."),
              text.allSatisfy({ $0.isNumber || "-xX isbnISBN:".contains($0) }) else { return nil }
        return digits
    }

    nonisolated static func parseCSL(_ data: Data) throws -> [Reference] {
        guard let items = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return items.map(reference)
    }

    nonisolated private static func reference(_ item: [String: Any]) -> Reference {
        let authors = (item["author"] as? [[String: Any]] ?? []).map { a -> String in
            if let l = a["literal"] as? String { return l }
            return [a["given"] as? String, a["family"] as? String].compactMap { $0 }.joined(separator: " ")
        }
        let issued = item["issued"] as? [String: Any]
        let parts = issued?["date-parts"] as? [[Any]]
        let year = parts?.first?.first.map { "\($0)" } ?? ""
        let title = item["title"] as? String ?? (item["title"] as? [String])?.first ?? ""
        return Reference(key: item["id"] as? String ?? "", title: title, author: authors.joined(separator: "; "), year: year,
                         publisher: item["publisher"] as? String ?? "", doi: item["DOI"] as? String ?? "")
    }

    static func fetch(doi: String) async throws -> Reference {
        guard let url = URL(string: "https://api.crossref.org/works/" + (doi.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? doi)) else {
            throw BibleImporter.Failure("DOI")
        }
        let (data, _) = try await URLSession.shared.data(from: url)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], let m = root["message"] as? [String: Any] else {
            throw BibleImporter.Failure(L("This DOI was not found."))
        }
        var r = reference(m)
        r.key = ""
        if r.year.isEmpty, let p = (m["published"] as? [String: Any])?["date-parts"] as? [[Any]], let y = p.first?.first { r.year = "\(y)" }
        r.doi = doi
        return r
    }

    static func fetch(isbn: String) async throws -> Reference {
        guard let url = URL(string: "https://openlibrary.org/api/books?bibkeys=ISBN:\(isbn)&format=json&jscmd=data") else {
            throw BibleImporter.Failure("ISBN")
        }
        let (data, _) = try await URLSession.shared.data(from: url)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], let m = root["ISBN:\(isbn)"] as? [String: Any] else {
            throw BibleImporter.Failure(L("This ISBN was not found."))
        }
        let authors = (m["authors"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        let publishers = (m["publishers"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        let date = m["publish_date"] as? String ?? ""
        let year = date.range(of: "[0-9]{4}", options: .regularExpression).map { String(date[$0]) } ?? ""
        return Reference(title: m["title"] as? String ?? isbn, author: authors.joined(separator: "; "), year: year, publisher: publishers.first ?? "", isbn: isbn)
    }
}

/// What a document says, read on this Mac: PDF text, or recognised text for scans and images. Nothing leaves the machine.
enum DocumentText {
    private static func cacheURL(_ path: String, store: BibleStore) -> URL {
        store.root.appendingPathComponent(".musset/proof/documents/\(BibleStore.slug(path)).txt")
    }

    /// What is already known; starts reading in the background otherwise.
    @MainActor
    static func cached(_ e: BibleEntry, store: BibleStore) -> String? {
        let cache = cacheURL(e.path, store: store)
        if let text = try? String(contentsOf: cache, encoding: .utf8) { return text }
        let file = store.url(e.path)
        Task.detached(priority: .utility) {
            guard let text = read(file) else { return }
            try? FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? text.write(to: cache, atomically: true, encoding: .utf8)
        }
        return nil
    }

    nonisolated static func read(_ file: URL) -> String? {
        let ext = file.pathExtension.lowercased()
        if ext == "pdf", let doc = PDFDocument(url: file) {
            if let text = doc.string, text.trimmingCharacters(in: .whitespacesAndNewlines).count > 20 { return text }
            return (0..<min(doc.pageCount, 200)).compactMap { i -> String? in
                guard let page = doc.page(at: i) else { return nil }
                let img = page.thumbnail(of: NSSize(width: 1600, height: 2200), for: .mediaBox)
                return img.cgImage(forProposedRect: nil, context: nil, hints: nil).flatMap(recognise)
            }.joined(separator: "\n")
        }
        if ["png", "jpg", "jpeg", "tif", "tiff", "heic", "gif"].contains(ext), let img = NSImage(contentsOf: file),
           let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return recognise(cg)
        }
        return nil
    }

    nonisolated private static func recognise(_ image: CGImage) -> String? {
        let request = VNRecognizeTextRequest()
        request.recognitionLanguages = ["fr-FR", "en-US"]
        request.usesLanguageCorrection = true
        try? VNImageRequestHandler(cgImage: image).perform([request])
        return request.results?.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
}

/// A document shown in the Bible. A PDF offers its selection as a kept passage.
struct DocumentPreview: View {
    let entry: BibleEntry
    let store: BibleStore

    private var file: URL { entry.meta["linked"].map { URL(fileURLWithPath: $0) } ?? store.url(entry.path) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(entry.title).font(.system(size: 20, design: .serif)).lineLimit(1)
                Spacer()
                Button(L("Open")) { NSWorkspace.shared.open(file) }.buttonStyle(.inkSecondary)
            }
            .padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 12)
            Divider()
            if !FileManager.default.fileExists(atPath: file.path) {
                Text(L("This linked file is no longer at \(file.path)"))
                    .foregroundStyle(.secondary).padding(20)
                Spacer()
            } else if file.pathExtension.lowercased() == "pdf" {
                PDFPane(url: file, sidecar: store.url(entry.path + ".md"), store: store)
            } else {
                QuickLookPane(url: file)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct QuickLookPane: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> QLPreviewView {
        let v = QLPreviewView(frame: .zero, style: .normal)!
        v.previewItem = url as NSURL
        return v
    }
    func updateNSView(_ v: QLPreviewView, context: Context) { v.previewItem = url as NSURL }
}

private struct PDFPane: View {
    let url: URL
    let sidecar: URL
    let store: BibleStore
    @State private var view = PDFView()

    var body: some View {
        VStack(spacing: 0) {
            PDFHost(view: view, url: url, sidecar: sidecar)
            Divider()
            HStack {
                Text(L("Select a passage to keep it.")).font(.ui(12)).foregroundStyle(.secondary)
                Spacer()
                Button(L("Keep the passage")) { keep() }.buttonStyle(.inkSecondary)
            }
            .padding(10)
        }
    }

    private func keep() {
        guard let sel = view.currentSelection, let text = sel.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return }
        let page = sel.pages.first.flatMap { $0.document?.index(for: $0) }.map { $0 + 1 } ?? 1
        let line = "> \(text.replacingOccurrences(of: "\n", with: " "))\n(p. \(page))\n\n"
        let current = (try? String(contentsOf: sidecar, encoding: .utf8)) ?? ""
        try? store.prepare(sidecar)
        try? (current + line).write(to: sidecar, atomically: true, encoding: .utf8)
        Highlights.mark(sel)
    }
}

private struct PDFHost: NSViewRepresentable {
    let view: PDFView
    let url: URL
    var sidecar: URL? = nil
    func makeNSView(context: Context) -> PDFView {
        view.autoScales = true
        view.document = PDFDocument(url: url)
        if let doc = view.document, let sidecar { Highlights.show(Highlights.read(sidecar), in: doc) }
        // Opened from a citation « p. 12 »: straight to that page.
        if let n = PDFJump.page, let page = view.document?.page(at: max(0, n - 1)) {
            PDFJump.page = nil
            DispatchQueue.main.async { view.go(to: page) }
        }
        return view
    }
    func updateNSView(_ v: PDFView, context: Context) {}
}

/// Citations for the Typst pages, which pandoc does not see: `(Author, year)` in the text, and a last page listing what was cited.
enum CitationPages {
    static func apply(to chapters: [(id: String, text: String)], root: URL, lang: String) -> [(id: String, text: String)] {
        let refs = BibleStore(root: root).scan().entries.filter { $0.kind == .reference }
        guard !refs.isEmpty, let re = try? NSRegularExpression(pattern: "\\[([^\\]\\n@]*)@([\\p{L}\\p{N}_:.#$%&+?<>~/-]+)([^\\]\\n]*)\\]") else { return chapters }
        let byKey = Dictionary(refs.compactMap { e in e.meta["citekey"].map { ($0, e) } }, uniquingKeysWith: { a, _ in a })
        var cited: [String] = []
        let out = chapters.map { ch -> (id: String, text: String) in
            let ns = ch.text as NSString
            var result = ""
            var last = 0
            for m in re.matches(in: ch.text, range: NSRange(location: 0, length: ns.length)) {
                let key = ns.substring(with: m.range(at: 2))
                guard let e = byKey[key] else { continue }
                if !cited.contains(key) { cited.append(key) }
                result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                let who = e.meta["author"]?.components(separatedBy: ";").first?.split(separator: " ").last.map(String.init) ?? e.title
                let prefix = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
                let suffix = ns.substring(with: m.range(at: 3)).trimmingCharacters(in: .whitespaces)
                result += "(" + (prefix.isEmpty ? "" : prefix + " ") + who + (e.meta["year"].map { " " + $0 } ?? "") + suffix + ")"
                last = m.range.location + m.range.length
            }
            result += ns.substring(from: last)
            return (id: ch.id, text: result)
        }
        guard !cited.isEmpty else { return chapters }
        let lines = cited.compactMap { byKey[$0] }.map { e in (Self.inverted(e.meta["author"] ?? ""), e) }
            .sorted { ($0.0.isEmpty ? $0.1.title : $0.0).localizedCaseInsensitiveCompare($1.0.isEmpty ? $1.1.title : $1.0) == .orderedAscending }
            .map { author, e in Self.entry(author: author, year: e.meta["year"], title: e.title, publisher: e.meta["publisher"]) }
        return out + [(id: "_bibliographie", text: "# " + (lang.hasPrefix("fr") ? "Bibliographie" : "Bibliography") + "\n\n" + lines.joined(separator: "\n\n") + "\n")]
    }

    /// « Hartley, M. 1994. *The Salt Coast*. Harbour Press. »: Chicago author-date, as pandoc's export writes it.
    static func entry(author: String, year: String?, title: String, publisher: String?) -> String {
        [author.isEmpty ? nil : author, year, "*\(title)*", publisher].compactMap { $0.flatMap { $0.isEmpty ? nil : $0 } }
            .map { $0.hasSuffix(".") ? $0 : $0 + "." }.joined(separator: " ")
    }

    /// The first author family name first: « M. Hartley; R. Abbott » → « Hartley, M., and R. Abbott ».
    static func inverted(_ authors: String) -> String {
        var names = authors.components(separatedBy: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let first = names.first else { return "" }
        var words = first.split(separator: " ").map(String.init)
        if !first.contains(","), words.count > 1 { names[0] = words.removeLast() + ", " + words.joined(separator: " ") }
        guard names.count > 1, let last = names.last else { return names[0] }
        return names.dropLast().joined(separator: ", ") + ", and " + last
    }
}

/// The page the next PDF opened should show (from a citation's « p. 12 »).
@MainActor enum PDFJump { static var page: Int? }

/// Passages kept from a PDF (its `.pdf.md` beside it, « > text (p. N) »), shown highlighted on their page.
enum Highlights {
    struct Kept: Equatable { var text: String; var page: Int }

    static func read(_ sidecar: URL) -> [Kept] {
        guard let text = try? String(contentsOf: sidecar, encoding: .utf8) else { return [] }
        return parse(text)
    }

    static func parse(_ text: String) -> [Kept] {
        var out: [Kept] = []
        var quote: String?
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("> ") { quote = String(line.dropFirst(2)) }
            else if let q = quote, let r = line.range(of: "^\\(p\\. ([0-9]+)\\)", options: .regularExpression) {
                out.append(Kept(text: q, page: Int(line[r].filter(\.isNumber)) ?? 1))
                quote = nil
            }
        }
        return out
    }

    static func show(_ kept: [Kept], in doc: PDFDocument) {
        for k in kept {
            guard let page = doc.page(at: max(0, k.page - 1)) else { continue }
            let found = doc.findString(k.text, withOptions: [.caseInsensitive]).first { $0.pages.contains(page) }
            if let found { mark(found) }
        }
    }

    static func mark(_ selection: PDFSelection) {
        for line in selection.selectionsByLine() {
            for page in line.pages {
                let a = PDFAnnotation(bounds: line.bounds(for: page), forType: .highlight, withProperties: nil)
                a.color = NSColor.systemYellow.withAlphaComponent(0.45)
                page.addAnnotation(a)
            }
        }
    }
}
