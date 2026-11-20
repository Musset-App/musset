import AppKit
import Foundation

/// A `.scriv` project read without Scrivener. The binder gives the order; each document its text, synopsis and notes.
/// Scrivener 3 keeps a document in `Files/Data/<UUID>/`, Scrivener 2 in `Files/Docs/<ID>…`.
extension BookImporter {
    static func planScrivener(_ project: URL, cwd: URL) async throws -> ImportPlan {
        let binder = try Scrivener.binder(of: project)
        let doc = try XMLDocument(contentsOf: binder)
        guard let draft = try doc.nodes(forXPath: "//BinderItem[@Type='DraftFolder']").first as? XMLElement else {
            throw BibleImporter.Failure(L("No draft folder in this project."))
        }
        let root = Scrivener.Item(draft)
        var pieces: [Scrivener.Piece] = []
        var leftOut = 0
        for item in root.children { Scrivener.outline(item, part: nil, into: &pieces, leftOut: &leftOut) }

        let reader = Scrivener.Reader(project: project, styleNames: Scrivener.styleNames(project))
        let raw = try await reader.texts(of: pieces.flatMap { [$0.head] + $0.scenes }, cwd: cwd)
        let chapters = pieces.compactMap { piece -> PlannedChapter? in
            // A part with nothing written on its own page is only a shelf for its chapters.
            if piece.part, Scrivener.isEmpty(raw[piece.head.uuid]) { return nil }
            return Scrivener.chapter(piece, raw: raw, reader: reader)
        }
        guard !chapters.isEmpty else { throw BibleImporter.Failure(L("No draft folder in this project.")) }

        var keeps = [(L("Binder"), L("Parts, chapters and scenes")), (L("Synopsis"), L("Scene synopsis")),
                     (L("Italics, footnotes"), L("As they are")), (L("Comments, annotations"), L("Notes in the text"))]
        if leftOut > 0 { keeps.append((L("Not included in Compile"), L("Left out"))) }
        return ImportPlan(source: .scrivener, file: project, title: project.deletingPathExtension().lastPathComponent,
                          rule: L("Musset reads the project without opening Scrivener, and does not change it."),
                          chapters: chapters, keeps: keeps)
    }
}

enum Scrivener {
    /// A binder item, out of the XML.
    struct Item {
        let uuid: String, id: String, type: String, title: String, included: Bool
        let children: [Item]

        init(_ e: XMLElement) {
            id = e.attribute(forName: "ID")?.stringValue ?? ""
            uuid = e.attribute(forName: "UUID")?.stringValue ?? id
            type = e.attribute(forName: "Type")?.stringValue ?? "Text"
            title = (e.elements(forName: "Title").first?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let meta = e.elements(forName: "MetaData").first
            included = meta?.elements(forName: "IncludeInCompile").first?.stringValue != "No"
            children = (e.elements(forName: "Children").first?.elements(forName: "BinderItem") ?? []).map(Item.init)
        }

        var isFolder: Bool { type.hasSuffix("Folder") }
        /// Only texts and folders hold manuscript; a picture or a PDF dropped in the draft does not.
        var isText: Bool { type == "Text" || isFolder }
        var descendants: [Item] { children.flatMap { [$0] + $0.descendants } }
    }

    /// A chapter to be: the item that names it, and the documents that are its scenes.
    struct Piece { var head: Item; var scenes: [Item]; var part = false; var partTitle: String? = nil }

    /// The project's binder file. A project synced by a cloud folder may hold a conflicted copy beside it.
    static func binder(of project: URL) throws -> URL {
        let items = (try? FileManager.default.contentsOfDirectory(at: project, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let binders = items.filter { $0.pathExtension.lowercased() == "scrivx" }
        let named = binders.first { $0.deletingPathExtension().lastPathComponent == project.deletingPathExtension().lastPathComponent }
        let newest = binders.max { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return da < db
        }
        guard let binder = named ?? newest else { throw BibleImporter.Failure(L("No binder in this project.")) }
        return binder
    }

    /// A folder that holds folders is a part: its chapters are inside. Any other folder, and a document on its own,
    /// is a chapter; the documents under it, however deep, are its scenes in the binder's order. A part inside a
    /// part belongs to the outer one: a book's parts are one level.
    static func outline(_ item: Item, part: String?, into pieces: inout [Piece], leftOut: inout Int) {
        guard item.isText else { return }
        if item.isFolder, item.children.contains(where: \.isFolder) {
            // The part's own page, if it has one, stays as a chapter of its own; `chapter` drops it when it is empty.
            let name = part ?? (item.title.isEmpty ? L("Untitled") : item.title)
            if item.included { pieces.append(Piece(head: item, scenes: [], part: true, partTitle: name)) } else { leftOut += 1 }
            for kid in item.children { outline(kid, part: name, into: &pieces, leftOut: &leftOut) }
            return
        }
        let scenes = item.descendants.filter(\.isText)
        leftOut += ([item] + scenes).filter { !$0.included }.count
        let kept = scenes.filter(\.included)
        if item.included || !kept.isEmpty { pieces.append(Piece(head: item, scenes: kept, partTitle: part)) }
    }

    /// The paragraph and character style names of the project, by id.
    static func styleNames(_ project: URL) -> [String: String] {
        guard let doc = try? XMLDocument(contentsOf: project.appendingPathComponent("Files/styles.xml")),
              let styles = try? doc.nodes(forXPath: "//Style") as? [XMLElement] else { return [:] }
        var names: [String: String] = [:]
        for s in styles { if let id = s.attribute(forName: "ID")?.stringValue { names[id] = s.attribute(forName: "Name")?.stringValue ?? "" } }
        return names
    }

    static func chapter(_ piece: Piece, raw: [String: String], reader: Reader) -> PlannedChapter {
        var notes = 0
        let own = piece.head.included ? reader.clean(raw[piece.head.uuid] ?? "", of: piece.head, notes: &notes) : ""
        let name = piece.head.title.isEmpty ? firstWords(own) ?? L("Untitled") : piece.head.title
        var text = "# \(name)\n\n"
        var synopsis: [String: String] = [:]
        if !own.isEmpty { text += own + "\n\n" }
        if piece.head.included, let s = reader.synopsis(piece.head) { synopsis[""] = s }
        var used: [String: Int] = [:]
        for scene in piece.scenes {
            let body = reader.clean(raw[scene.uuid] ?? "", of: scene, notes: &notes)
            var title = scene.title.isEmpty ? firstWords(body) ?? L("Untitled") : scene.title
            title = title.replacingOccurrences(of: "--", with: "–")   // a scene's name lives in a comment
            used[title, default: 0] += 1
            if let n = used[title], n > 1 { title += " \(n)" }   // a synopsis is kept under the scene's name
            text += Scenes.markerLine(title) + "\n\n"
            if !body.isEmpty { text += body + "\n\n" }
            if let s = reader.synopsis(scene) { synopsis[title] = s }
        }
        return PlannedChapter(title: name, text: text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n", synopsis: synopsis, part: piece.partTitle)
    }

    static func isEmpty(_ text: String?) -> Bool { (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Scrivener names an untitled document after its first words.
    static func firstWords(_ text: String) -> String? {
        let line = text.split(separator: "\n").first { !$0.hasPrefix("[^") }.map(String.init) ?? ""
        let plain = line.replacingOccurrences(of: "\\{>>.*?<<\\}|\\[\\^\\d+\\]|[*_>#\\\\{}=]", with: "", options: .regularExpression)
        let words = plain.split(separator: " ").prefix(6).joined(separator: " ")
        return words.isEmpty ? nil : words
    }

    /// Reads the documents of one project.
    struct Reader: Sendable {
        let project: URL
        let styleNames: [String: String]

        private func file(_ item: Item, _ v3: String, _ v2: String) -> URL? {
            let candidates = [project.appendingPathComponent("Files/Data/\(item.uuid)/\(v3)"),
                              project.appendingPathComponent("Files/Docs/\(item.id)\(v2)")]
            return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
        }

        func synopsis(_ item: Item) -> String? {
            guard let f = file(item, "synopsis.txt", "_synopsis.txt"), let s = Scrivener.read(f) else { return nil }
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }

        /// Each document through pandoc, a few at a time: its Markdown, still with Scrivener's own marks in it.
        func texts(of items: [Item], cwd: URL) async throws -> [String: String] {
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("musset-scriv-\(UUID())", isDirectory: true)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: work) }
            var out: [String: String] = [:]
            var rest = items[...]
            while !rest.isEmpty {
                let batch = rest.prefix(8)
                rest = rest.dropFirst(8)
                try await withThrowingTaskGroup(of: (String, String).self) { group in
                    for item in batch { group.addTask { (item.uuid, try await text(item, work: work, cwd: cwd)) } }
                    for try await (id, t) in group { out[id] = t }
                }
            }
            return out
        }

        private func text(_ item: Item, work: URL, cwd: URL) async throws -> String {
            if let rtf = file(item, "content.rtf", ".rtf"), let source = Scrivener.read(rtf) {
                let prepared = work.appendingPathComponent("\(UUID()).rtf")
                try Scrivener.prepare(rtf: source).write(to: prepared, atomically: true, encoding: .utf8)
                let out = try await ExportService.runPandoc([prepared.path, "-f", "rtf", "-t", "gfm", "--wrap=none"], cwd: cwd)
                if out.ok { return out.stdout }
                // pandoc could not read it: the words at least, as macOS reads them.
                if let attr = try? NSAttributedString(url: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil) {
                    return Scrivener.paragraphs(attr.string)
                }
                return ""
            }
            if let txt = file(item, "content.txt", ".txt") ?? file(item, "content.md", ".md"), let s = Scrivener.read(txt) {
                return Scrivener.paragraphs(s)
            }
            return ""
        }

        /// The comments and linked footnotes of a document, by id.
        private func comments(_ item: Item) -> [String: (text: String, footnote: Bool)] {
            guard let f = file(item, "content.comments", ".comments"), let doc = try? XMLDocument(contentsOf: f),
                  let nodes = try? doc.nodes(forXPath: "//Comment") as? [XMLElement] else { return [:] }
            var out: [String: (text: String, footnote: Bool)] = [:]
            for c in nodes {
                guard let id = c.attribute(forName: "ID")?.stringValue else { continue }
                let body = c.stringValue ?? ""
                var text = body
                if body.hasPrefix("{\\rtf"), let data = body.data(using: .utf8),
                   let attr = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil) {
                    text = attr.string
                }
                out[id.uppercased()] = (Scrivener.oneLine(text), c.attribute(forName: "Footnote")?.stringValue == "Yes")
            }
            return out
        }

        /// The names of the styles a document uses, in the order its marks number them.
        private func styles(_ item: Item) -> [String] {
            guard let f = file(item, "content.styles", ".styles"), let s = Scrivener.read(f) else { return [] }
            return s.split(separator: "\n").map { styleNames[$0.trimmingCharacters(in: .whitespaces)] ?? "" }
        }

        /// pandoc's Markdown without Scrivener's marks: styles, notes, links to the binder, pictures.
        func clean(_ markdown: String, of item: Item, notes: inout Int) -> String {
            Scrivener.clean(markdown, styles: styles(item), comments: comments(item), notes: &notes)
        }
    }

    static func read(_ file: URL) -> String? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252) ?? String(data: data, encoding: .isoLatin1)
    }

    /// Plain text: a line is a paragraph.
    static func paragraphs(_ s: String) -> String {
        s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    static func oneLine(_ s: String) -> String {
        s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }

    /// The RTF as pandoc reads it best. The Mac writes a paragraph's end as a backslash before the line's end, which
    /// pandoc takes for a line break inside one long paragraph; a table becomes its cells' paragraphs; pictures go.
    static func prepare(rtf: String) -> String {
        var s = rtf.replacingOccurrences(of: "\r\n", with: "\n")
        s = s.replacingOccurrences(of: "(?<!\\\\)((?:\\\\\\\\)*)\\\\\\n", with: "$1\\\\par\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\{\\\\pict[^{}]*\\}", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "(?<!\\\\)((?:\\\\\\\\)*)\\\\(?:nest)?cell(?![a-zA-Z])", with: "$1\\\\par", options: .regularExpression)
        s = s.replacingOccurrences(of: "(?<!\\\\)((?:\\\\\\\\)*)\\\\(?:trowd|row|lastrow|intbl|nestrow|itap\\d+)(?![a-zA-Z0-9])", with: "$1", options: .regularExpression)
        return s
    }

    static func clean(_ markdown: String, styles: [String], comments: [String: (text: String, footnote: Bool)], notes: inout Int) -> String {
        var s = markdown
        var definitions: [String] = []
        func footnote(_ text: String) -> String {
            notes += 1
            definitions.append("[^\(notes)]: \(oneLine(text))")
            return "[^\(notes)]"
        }
        func replace(_ pattern: String, _ body: ([String]) -> String) {
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return }
            let ns = s as NSString
            var out = "", last = 0
            for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
                out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                out += body((0..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? "" : ns.substring(with: m.range(at: $0)) })
                last = m.range.location + m.range.length
            }
            s = out + ns.substring(from: last)
        }

        // Style marks, as pandoc escapes them in text and in the HTML it falls back to. A quotation keeps its shape.
        let open = "\u{E000}", close = "\u{E001}"
        replace("(?:\\\\?<|&lt;)(!?)\\\\?\\$Scr_(Ps|Cs|H)::(\\d+)(?:\\\\?>|&gt;)") { g in
            guard g[2] == "Ps", let i = Int(g[3]), i < styles.count else { return "" }
            let name = styles[i].lowercased()
            guard name.contains("quot") || name.contains("citation") || name.contains("zitat") || name.contains("cita") else { return "" }
            return g[1].isEmpty ? open : close
        }

        // Inline notes: a footnote stays a footnote, an annotation becomes a note in the text.
        replace("\\{\\\\{1,2}Scrv_fn=(.*?)\\\\{1,2}end_Scrv_fn\\}") { footnote($0[1]) }
        replace("\\{\\\\{1,2}Scrv_annot\\s*(?:\\\\{1,2}color=\\{[^}]*\\})?\\s*\\\\{1,2}text=(.*?)\\\\{1,2}end_Scrv_annot\\}") { g in
            let t = oneLine(g[1])
            return t.isEmpty ? "" : "{>>\(t)<<}"
        }

        // pandoc cuts a link where the RTF changes encoding (at an accent): pieces of one link are one link again.
        let cut = "\\[([^\\]]*)\\]\\(((?:scrivcmt|scrivlnk|x-scrivener-item)://[^)]*)\\)\\[([^\\]]*)\\]\\(\\2\\)"
        while s.range(of: cut, options: .regularExpression) != nil {
            s = s.replacingOccurrences(of: cut, with: "[$1$3]($2)", options: .regularExpression)
        }

        // Linked notes: the comment or footnote is in a file beside the text.
        func linked(_ text: String, _ id: String) -> String {
            guard let c = comments[id.uppercased()], !c.text.isEmpty else { return text }
            if c.footnote { return text + footnote(c.text) }
            return "{==\(text)==}{>>\(c.text.replacingOccurrences(of: "<<}", with: "<< }"))<<}"
        }
        replace("\\[([^\\]]*)\\]\\(scrivcmt://([0-9A-Fa-f-]+)\\)") { linked($0[1], $0[2]) }
        replace("<a href=\"scrivcmt://([0-9A-Fa-f-]+)\"[^>]*>(.*?)</a>") { linked($0[2], $0[1]) }

        // Links to other documents of the binder lead nowhere outside Scrivener: their words stay.
        replace("\\[([^\\]]*)\\]\\((?:scrivlnk|x-scrivener-item)://[^)]*\\)") { $0[1] }
        replace("<a href=\"(?:scrivlnk|x-scrivener-item)://[^\"]*\"[^>]*>(.*?)</a>") { $0[1] }

        // Pictures are not part of a manuscript here.
        replace("<img\\b[^>]*>") { _ in "" }
        replace("!\\[[^\\]]*\\]\\([^)]*\\)(\\{[^}]*\\})?") { _ in "" }

        // Quotations, paragraph by paragraph.
        var quoting = false
        let blocks = s.components(separatedBy: "\n\n").map { block -> String in
            let starts = quoting || block.contains(open)
            if block.contains(open) { quoting = true }
            if block.contains(close) { quoting = false }
            let text = block.replacingOccurrences(of: open, with: "").replacingOccurrences(of: close, with: "")
            guard starts, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return text }
            return text.split(separator: "\n", omittingEmptySubsequences: false).map { "> " + $0 }.joined(separator: "\n")
        }
        s = blocks.joined(separator: "\n\n")

        s = s.replacingOccurrences(of: "[ \\t]+\\n", with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if !definitions.isEmpty { s += "\n\n" + definitions.joined(separator: "\n\n") }
        return s
    }
}
