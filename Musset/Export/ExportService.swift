import Foundation
import MussetPage

/// Concatenates active chapters in manifest order and runs pandoc with the book's own templates.
enum ExportService {
    struct Output { let file: URL; let log: String }

    /// pandoc bundled in the app, else from PATH.
    static var pandoc: String? { Shell.bundledOrPath("pandoc") }

    static func runPandoc(_ args: [String], cwd: URL) async throws -> Shell.Result {
        guard let pandoc else {
            throw NSError(domain: "Musset.export", code: 127,
                          userInfo: [NSLocalizedDescriptionKey: L("pandoc is missing from the app.")])
        }
        return try await Shell.runAsync(pandoc, args, cwd: cwd)
    }

    /// Dedication and epigraph before the chapters, for pandoc formats (DOCX, EPUB, LaTeX).
    static func pandocFront(_ m: BookManifest) -> String {
        let f = m.front ?? FrontMatter()
        var out = ""
        if f.has(.dedication), let d = f.dedication { out += "::: {.dedication}\n*\(d.trimmingCharacters(in: .whitespacesAndNewlines))*\n:::\n\n" }
        if f.has(.epigraph), let e = f.epigraph {
            out += "::: {.epigraph}\n*\(e.trimmingCharacters(in: .whitespacesAndNewlines))*"
            if let s = f.epigraphSource, !s.isEmpty { out += "\n\n— \(s)" }
            out += "\n:::\n\n"
        }
        return out
    }

    static func pandocBack(_ m: BookManifest) -> String {
        let f = m.front ?? FrontMatter()
        var out = ""
        if f.has(.acknowledgements), let a = f.acknowledgements {
            out += "\n# \(BookTerm.acknowledgements.in(m.lang)) {.unnumbered}\n\n\(a.trimmingCharacters(in: .whitespacesAndNewlines))\n"
        }
        if f.has(.colophon) { out += "\n::: {.colophon}\n\(Colophon.text(m).replacingOccurrences(of: "\n", with: "  \n"))\n:::\n" }
        return out
    }

    /// The Bible's references, as pandoc reads them.
    @MainActor
    private static func bibliography(store: BookStore, work: URL) -> URL? {
        let model = BibleModel(root: store.root)
        let items: [[String: Any]] = model.entries.filter { $0.kind == .reference }.compactMap { e in
            guard let key = e.meta["citekey"] else { return nil }
            var item: [String: Any] = ["id": key, "type": "book", "title": e.title]
            if let a = e.meta["author"] { item["author"] = a.components(separatedBy: ";").map { ["literal": $0.trimmingCharacters(in: .whitespaces)] } }
            if let y = e.meta["year"], let n = Int(y) { item["issued"] = ["date-parts": [[n]]] }
            if let p = e.meta["publisher"] { item["publisher"] = p }
            if let d = e.meta["doi"] { item["DOI"] = d }
            return item
        }
        guard !items.isEmpty, let data = try? JSONSerialization.data(withJSONObject: items, options: [.prettyPrinted, .sortedKeys]) else { return nil }
        let url = work.appendingPathComponent("references.json")
        return (try? data.write(to: url)) == nil ? nil : url
    }

    /// TITLE[_MILESTONE][_WHAT]_FIRSTNAME_LASTNAME_LAYOUT_2026-11-08_1432: what is in it (chapters or statuses,
    /// nothing for the whole book), whose it is, which layout, when.
    static func fileName(_ m: BookManifest, store: BookStore, preset p: ExportPreset, contents: String?, date: Date = Date()) -> String {
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyy-MM-dd_HHmm"
        // « Manuscrit A4 (envoi aux éditeurs) » names itself « MANUSCRIT_A4 ».
        let layout = p.shownName.components(separatedBy: "(").first ?? p.shownName
        return [safe(m.title), store.revisionName.map(safe), contents.map { $0.components(separatedBy: "-").map(safe).filter { !$0.isEmpty }.joined(separator: "-") }, safe(m.author), safe(layout), stamp.string(from: date)]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "_") + "." + p.format.rawValue
    }

    static func export(manifest m: BookManifest, store: BookStore, preset p: ExportPreset, contents: String? = nil) async throws -> Output {
        if p.format == .pdf { return try await exportPDF(manifest: m, store: store, preset: p, contents: contents) }
        try store.ensureMussetDir()
        let work = store.exportsDir.appendingPathComponent("build", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

        let source = work.appendingPathComponent("\(safe(m.title)).md")
        let wordID = UUID().uuidString.lowercased()
        var wordChapters: [String] = []
        if p.format == .docx {
            let manuscript = WordManuscript.source(m, store: store)
            wordChapters = manuscript.chapters
            try (WordManuscript.front(m, contact: p.includeContact) + manuscript.text + WordManuscript.back(m)).write(to: source, atomically: true, encoding: .utf8)
        } else {
            try (pandocFront(m) + store.concatenatedManuscript(m, stripComments: true) + pandocBack(m)).write(to: source, atomically: true, encoding: .utf8)
        }

        let out = store.exportsDir.appendingPathComponent(fileName(m, store: store, preset: p, contents: contents))

        // Without pandoc's fancy lists: only what Musset reads as a list is one (« a. », « (1) » open nothing).
        var args = [source.path, "--from", "markdown-fancy_lists", "-o", out.path, "--resource-path", store.root.path,
                    "--metadata", "title=\(m.title)", "--metadata", "author=\(m.author)"]
        if p.format == .docx {
            // No date, no number typed into the titles, no section per chapter: a manuscript's page is set once.
            // The language too: once in the styles, not on every run.
            args += ["--metadata", "\(WordManuscript.exportProperty)=\(wordID)"]
        } else {
            args += ["--metadata", "lang=\(m.lang)", "--metadata", "date=\(Calendar.current.component(.year, from: Date()))", "--top-level-division=chapter"]
            // A formed book says its own numbers in its headings: pandoc would count a prologue too.
            if p.numberSections, !m.hasForm { args.append("--number-sections") }
        }
        if (m.front ?? FrontMatter()).has(.contents) { args += ["--toc", "--toc-depth=1"] }

        switch p.format {
        case .pdf:
            break  // PDF goes through the typesetter (exportPDF).
        case .docx:
            if let t = p.template, FileManager.default.fileExists(atPath: store.root.appendingPathComponent(t).path) {
                args += ["--reference-doc", store.root.appendingPathComponent(t).path]
            }
        case .epub:
            if let t = p.template, FileManager.default.fileExists(atPath: store.root.appendingPathComponent(t).path) {
                args += ["--css", store.root.appendingPathComponent(t).path]
            }
            args += ["--split-level=1"]
        }
        args += p.extraArgs
        if let refs = await bibliography(store: store, work: work), !References.citations(in: store.concatenatedManuscript(m, stripComments: true)).isEmpty {
            args += ["--citeproc", "--bibliography", refs.path]
        }

        let r = try await runPandoc(args, cwd: store.root)
        guard r.ok, FileManager.default.fileExists(atPath: out.path) else {
            throw NSError(domain: "Musset.export", code: Int(r.status),
                          userInfo: [NSLocalizedDescriptionKey: L("pandoc failed:\n\(String((r.stderr + r.stdout).suffix(2000)))")])
        }
        if p.format == .docx {
            let ownTemplate = p.template.map { FileManager.default.fileExists(atPath: store.root.appendingPathComponent($0).path) } ?? false
            let sent = try await WordManuscript.finish(docx: out, manifest: m, store: store, chapters: wordChapters, id: wordID, styled: !ownTemplate)
            try WordManuscript.save(sent, root: store.root)
        }
        return Output(file: out, log: r.stderr)
    }

    /// PDF by the typesetter Read mode sets its pages with: the same pages, written out.
    static func exportPDF(manifest m: BookManifest, store: BookStore, preset p: ExportPreset, contents: String? = nil) async throws -> Output {
        try store.ensureMussetDir()
        let source = try Typesetting.source(manifest: m, store: store, preset: p)
        let out = store.exportsDir.appendingPathComponent(fileName(m, store: store, preset: p, contents: contents))
        try FileManager.default.createDirectory(at: store.exportsDir, withIntermediateDirectories: true)
        let start = Date()
        let pdf: Data
        do { pdf = try await Task.detached(priority: .userInitiated) { try TypesetBook.pdf(source) }.value }
        catch let failure as TypesetError { throw Typesetting.Failure(message: "Typst: " + failure.message) }
        try pdf.write(to: out, options: .atomic)
        return Output(file: out, log: String(format: "Typst (%@), %.1f s", p.typstStyle, Date().timeIntervalSince(start)))
    }

    static func safe(_ s: String) -> String {
        s.slug("_").uppercased()
    }
}
