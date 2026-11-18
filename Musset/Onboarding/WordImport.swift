import Foundation

/// One paragraph of a Word document, as far as chapter detection cares.
struct DocxParagraph: Equatable {
    var text = ""
    var centered = false
    var bold = false
    var size = 0
    var pageBreakBefore = false
    /// 1 for a Heading 1 style or outline level 0, 2 for the next, 0 otherwise.
    var headingLevel = 0
    /// Where this paragraph sits in the XML, to mark it later.
    var xmlRange: Range<String.Index>?

    var words: Int { text.split(whereSeparator: \.isWhitespace).count }
    var isCaps: Bool { text == text.uppercased() && text != text.lowercased() }
    var isSeparator: Bool {
        let t = text.trimmingCharacters(in: .whitespaces)
        return !t.isEmpty && t.count <= 12 && !t.contains { $0.isLetter || $0.isNumber }
    }
    var isNumbered: Bool {
        let t = text.trimmingCharacters(in: .whitespaces)
        let pattern = "^(?i)(chapitre|chapter|partie|part|livre|book|acte|act)\\b.{0,30}$|^(?i)(premi[eè]re|deuxi[eè]me|seconde|troisi[eè]me|quatri[eè]me|cinqui[eè]me) partie$|^[IVXLCDM]+\\.?$|^[0-9]{1,3}[.)]?$|^[0-9]{1,3}[.)] .{0,50}$"
        return t.range(of: pattern, options: .regularExpression) != nil
    }
}

/// How the manuscript marks its chapters, found in the document itself: its styles when it has any,
/// otherwise the habit it repeats (centred, bold, larger, numbered, after a page break).
struct DocxDetection: Equatable {
    enum Mark: Equatable { case body, chapter, scene, candidate }
    var marks: [Mark]
    /// The rule found, in the author's words.
    var rule: String
}

enum DocxAnalyzer {
    static func paragraphs(xml: String) -> [DocxParagraph] {
        guard let re = try? NSRegularExpression(pattern: "<w:p(?: [^>]*)?>[\\s\\S]*?</w:p>") else { return [] }
        var pendingBreak = false
        return re.matches(in: xml, range: NSRange(xml.startIndex..., in: xml)).compactMap { m -> DocxParagraph? in
            guard let r = Range(m.range, in: xml) else { return nil }
            let p = String(xml[r])
            var para = DocxParagraph(xmlRange: r)
            para.text = text(p)
            let props = first(p, "<w:pPr>[\\s\\S]*?</w:pPr>") ?? ""
            para.centered = props.contains("w:jc w:val=\"center\"")
            let hasBreak = p.contains("w:type=\"page\"") || props.contains("<w:pageBreakBefore") || p.contains("<w:sectPr")
            para.pageBreakBefore = pendingBreak || props.contains("<w:pageBreakBefore")
            let runs = matches(p, "<w:r(?: [^>]*)?>[\\s\\S]*?</w:r>").filter { $0.contains("<w:t") }
            para.bold = !runs.isEmpty && runs.allSatisfy { $0.contains("<w:b/>") || $0.contains("<w:b ") } || props.contains("<w:b/>")
            para.size = matches(p, "<w:sz w:val=\"[0-9]+\"").compactMap { Int($0.filter(\.isNumber)) }.max() ?? 0
            let style = first(props, "<w:pStyle w:val=\"[^\"]+\"")?.lowercased() ?? ""
            if style.contains("heading1") || style.contains("titre1") || style.hasSuffix("title\"") || props.contains("<w:outlineLvl w:val=\"0\"") { para.headingLevel = 1 }
            else if style.contains("heading2") || style.contains("titre2") || props.contains("<w:outlineLvl w:val=\"1\"") { para.headingLevel = 2 }
            // A break alone on its line belongs to what follows.
            if para.text.isEmpty { pendingBreak = pendingBreak || hasBreak; return para }
            pendingBreak = false
            if !para.pageBreakBefore, hasBreak, p.range(of: "w:type=\"page\"")?.lowerBound ?? p.endIndex < (p.range(of: "<w:t")?.lowerBound ?? p.endIndex) { para.pageBreakBefore = true }
            return para
        }
    }

    private static func text(_ p: String) -> String {
        let raw = matches(p, "<w:t(?: [^>]*)?>[^<]*</w:t>").map { $0.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression) }.joined()
        return raw.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&apos;", with: "'").replacingOccurrences(of: "&quot;", with: "\"")
    }

    private static func first(_ s: String, _ pattern: String) -> String? {
        s.range(of: pattern, options: .regularExpression).map { String(s[$0]) }
    }

    private static func matches(_ s: String, _ pattern: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap { Range($0.range, in: s).map { String(s[$0]) } }
    }

    static func detect(_ paras: [DocxParagraph]) -> DocxDetection {
        var marks = paras.map { $0.isSeparator ? DocxDetection.Mark.scene : .body }
        // Its own styles, when it uses them, are the author's explicit word.
        if paras.filter({ $0.headingLevel == 1 && !$0.text.isEmpty }).count >= 2 {
            for (i, p) in paras.enumerated() where !p.text.isEmpty {
                if p.headingLevel == 1 { marks[i] = .chapter } else if p.headingLevel == 2 { marks[i] = .scene }
            }
            return DocxDetection(marks: marks, rule: L("Musset used the document's heading styles."))
        }
        let filled = paras.filter { !$0.text.isEmpty }
        let sizes = filled.filter { $0.words > 20 }.map(\.size).sorted()
        let body = sizes.isEmpty ? 0 : sizes[sizes.count / 2]

        struct Signature: Hashable { var centered, bold, larger, caps, broken, numbered: Bool }
        func signature(_ p: DocxParagraph) -> Signature {
            Signature(centered: p.centered, bold: p.bold, larger: p.size > body && body > 0, caps: p.isCaps && !p.isNumbered, broken: p.pageBreakBefore, numbered: p.isNumbered)
        }
        func score(_ s: Signature) -> Int {
            (s.centered ? 2 : 0) + (s.bold ? 1 : 0) + (s.larger ? 2 : 0) + (s.caps ? 1 : 0) + (s.broken ? 3 : 0) + (s.numbered ? 3 : 0)
        }
        func isShort(_ p: DocxParagraph) -> Bool {
            !p.text.isEmpty && !p.isSeparator && p.words <= 12 && !(p.text.hasSuffix(".") && !p.isNumbered)
        }
        var groups: [Signature: [Int]] = [:]
        for (i, p) in paras.enumerated() where isShort(p) {
            let s = signature(p)
            if score(s) >= 2 { groups[s, default: []].append(i) }
        }
        // The convention is what the manuscript repeats: the strongest mark seen at least twice.
        let chosen = groups.filter { $0.value.count >= 2 }.max { a, b in
            (score(a.key) * a.value.count, score(a.key)) < (score(b.key) * b.value.count, score(b.key))
        }
        guard let chosen else {
            // Nothing repeats exactly, as when titles were formatted by hand one by one: the strong marks still stand out.
            let strong = groups.filter { score($0.key) >= 4 }.flatMap(\.value)
            if strong.count >= 2 {
                for i in strong { marks[i] = .chapter }
                return DocxDetection(marks: marks, rule: L("No regular habit here: Musset took the lines that stand out. Check the list."))
            }
            return DocxDetection(marks: marks, rule: L("No chapter marks found. Click a line to cut there."))
        }
        for i in chosen.value { marks[i] = .chapter }
        // Marked as strongly but alone: a dedication, a part title. The author decides.
        for (s, list) in groups where s != chosen.key && score(s) >= 3 {
            for i in list where marks[i] == .body { marks[i] = .candidate }
        }
        return DocxDetection(marks: marks, rule: describe(chosen.key.centered, chosen.key.bold, chosen.key.larger, chosen.key.caps, chosen.key.broken, chosen.key.numbered, count: chosen.value.count))
    }

    private static func describe(_ centered: Bool, _ bold: Bool, _ larger: Bool, _ caps: Bool, _ broken: Bool, _ numbered: Bool, count: Int) -> String {
        var parts: [String] = []
        if numbered { parts.append(L("numbered")) }
        if centered { parts.append(L("centred")) }
        if bold { parts.append(L("bold")) }
        if larger { parts.append(L("larger")) }
        if caps { parts.append(L("in capitals")) }
        if broken { parts.append(L("after a page break")) }
        return L("No heading styles here. Musset spotted your habit: \(parts.listed), \(count) times.")
    }
}

/// A chapter about to be created.
struct PlannedChapter: Identifiable, Equatable {
    var id = UUID()
    var title: String
    var text: String
    var synopsis: [String: String] = [:]
}

/// A book about to be imported: what was found, for the author to check. The original is never changed.
struct ImportPlan: Identifiable {
    enum Source { case word, scrivener, ulysses }
    var id = UUID()
    var source: Source
    var file: URL
    var title: String
    var rule: String
    var chapters: [PlannedChapter] = []
    /// Word: the paragraphs and their marks, editable until the book is created.
    var paragraphs: [DocxParagraph] = []
    var marks: [DocxDetection.Mark] = []
    var keeps: [(from: String, to: String)] = []
    var sourceXML = ""
    var workDir: URL?

    var chapterCount: Int { source == .word ? wordRows.filter { $0.mark == .chapter }.count : chapters.count }
    var wordCount: Int {
        source == .word ? paragraphs.reduce(0) { $0 + $1.words } : chapters.reduce(0) { $0 + BookStore.wordCount($1.text) }
    }

    /// Word: the chapters as the marks stand, with their length.
    var wordRows: [(index: Int, title: String, words: Int, mark: DocxDetection.Mark)] {
        var rows: [(index: Int, title: String, words: Int, mark: DocxDetection.Mark)] = []
        for (i, p) in paragraphs.enumerated() {
            switch marks[i] {
            case .chapter, .candidate: rows.append((i, p.text, 0, marks[i]))
            case .scene, .body:
                if rows.isEmpty, !p.text.isEmpty { rows.append((-1, L("Opening"), 0, .chapter)) }
                if !rows.isEmpty { rows[rows.count - 1].words += p.words }
            }
        }
        return rows
    }
}

enum BookImporter {
    private static let chapterMark = "⟦MUSSET-CH⟧"
    private static let sceneMark = "⟦MUSSET-SC⟧"

    // MARK: Word

    static func planWord(_ file: URL) async throws -> ImportPlan {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("musset-import-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let unzip = try await Shell.runAsync("/usr/bin/unzip", ["-q", file.path, "-d", dir.path])
        guard unzip.ok else { throw BibleImporter.Failure(L("This file could not be read as a .docx.")) }
        let xml = try String(contentsOf: dir.appendingPathComponent("word/document.xml"), encoding: .utf8)
        let paragraphs = DocxAnalyzer.paragraphs(xml: xml)
        let found = DocxAnalyzer.detect(paragraphs)
        return ImportPlan(source: .word, file: file, title: file.deletingPathExtension().lastPathComponent, rule: found.rule,
                          paragraphs: paragraphs, marks: found.marks,
                          keeps: [(L("Chapter marks"), L("Chapters")), (L("Centred * * *"), L("Scene breaks")), (L("Italics, footnotes"), L("As they are"))],
                          sourceXML: xml, workDir: dir)
    }

    /// Word: a copy of the document with each cut marked, through pandoc so italics and footnotes survive, split at the marks.
    static func chapters(of plan: ImportPlan, cwd: URL) async throws -> [PlannedChapter] {
        guard let dir = plan.workDir else { return [] }
        var xml = plan.sourceXML
        for (i, p) in plan.paragraphs.enumerated().reversed() {
            guard let range = p.xmlRange, plan.marks[i] == .chapter || plan.marks[i] == .scene else { continue }
            let mark = plan.marks[i] == .chapter ? chapterMark : sceneMark
            let run = "<w:r><w:t>\(mark)</w:t></w:r>"
            let body = String(xml[range])
            let insert: String
            if let props = body.range(of: "</w:pPr>") {
                insert = body[..<props.upperBound] + run + body[props.upperBound...]
            } else if let open = body.range(of: ">") {
                insert = body[..<open.upperBound] + run + body[open.upperBound...]
            } else { continue }
            xml.replaceSubrange(range, with: insert)
        }
        try xml.write(to: dir.appendingPathComponent("word/document.xml"), atomically: true, encoding: .utf8)
        let copy = dir.deletingLastPathComponent().appendingPathComponent(dir.lastPathComponent + ".docx")
        defer { try? FileManager.default.removeItem(at: copy) }
        let zipped = try await Shell.runAsync("/usr/bin/zip", ["-q", "-r", copy.path, "."], cwd: dir)
        guard zipped.ok else { throw BibleImporter.Failure(zipped.stderr) }
        let out = try await ExportService.runPandoc([copy.path, "-t", "gfm", "--wrap=none"], cwd: cwd)
        guard out.ok else { throw BibleImporter.Failure(out.stderr) }
        return split(markdown: out.stdout)
    }

    /// Cuts pandoc's text at the marks. A chapter's mark may sit inside the title's bold or `#`.
    static func split(markdown: String) -> [PlannedChapter] {
        var chapters: [PlannedChapter] = []
        var lines: [String] = []
        var title: String?
        func flush() {
            let body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if let title { chapters.append(.init(title: title, text: "# \(title)\n\n" + (body.isEmpty ? "" : body + "\n"))) }
            else if !body.isEmpty { let t = L("Opening"); chapters.append(.init(title: t, text: "# \(t)\n\n\(body)\n")) }
            lines = []
        }
        for line in markdown.components(separatedBy: "\n") {
            if line.contains(chapterMark) {
                flush()
                title = cleanTitle(line.replacingOccurrences(of: chapterMark, with: ""))
            } else if line.contains(sceneMark) {
                let name = cleanTitle(line.replacingOccurrences(of: sceneMark, with: ""))
                let hasWords = name.contains { $0.isLetter || $0.isNumber }
                lines.append(Scenes.markerLine(hasWords ? name : ""))
            } else {
                lines.append(line)
            }
        }
        flush()
        return chapters
    }

    private static func cleanTitle(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespaces)
        while t.hasPrefix("#") { t.removeFirst() }
        t = t.replacingOccurrences(of: "\\", with: "").replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "")
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: "* _").union(.whitespaces))
        return t
    }

    // MARK: Scrivener

    /// A `.scriv` project read without Scrivener: the binder gives the order, each document its text and synopsis.
    static func planScrivener(_ project: URL, cwd: URL) async throws -> ImportPlan {
        let items = try FileManager.default.contentsOfDirectory(at: project, includingPropertiesForKeys: nil)
        guard let binder = items.first(where: { $0.pathExtension == "scrivx" }) else {
            throw BibleImporter.Failure(L("No binder in this project."))
        }
        let doc = try XMLDocument(contentsOf: binder)
        guard let draft = try doc.nodes(forXPath: "//BinderItem[@Type='DraftFolder']").first as? XMLElement else {
            throw BibleImporter.Failure(L("No draft folder in this project."))
        }
        var chapters: [PlannedChapter] = []
        for item in children(of: draft) { try await collect(item, into: &chapters, project: project, cwd: cwd) }
        return ImportPlan(source: .scrivener, file: project, title: project.deletingPathExtension().lastPathComponent,
                          rule: L("Musset reads the project without opening Scrivener, and does not change it."),
                          chapters: chapters,
                          keeps: [(L("Binder"), L("Chapters and scenes")), (L("Synopsis"), L("Scene synopsis"))])
    }

    private static func children(of item: XMLElement) -> [XMLElement] {
        item.elements(forName: "Children").first?.elements(forName: "BinderItem") ?? []
    }

    private static func title(_ item: XMLElement) -> String {
        item.elements(forName: "Title").first?.stringValue ?? L("Untitled")
    }

    /// A folder is a chapter, its documents are its scenes; a document on its own is a chapter.
    private static func collect(_ item: XMLElement, into chapters: inout [PlannedChapter], project: URL, cwd: URL) async throws {
        let kids = children(of: item)
        let name = title(item)
        if kids.contains(where: { !children(of: $0).isEmpty }) {
            for kid in kids { try await collect(kid, into: &chapters, project: project, cwd: cwd) }
            return
        }
        var text = "# \(name)\n\n"
        var synopsis: [String: String] = [:]
        if let own = try await documentText(item, project: project, cwd: cwd), !own.isEmpty { text += own + "\n\n" }
        if let s = documentSynopsis(item, project: project) { synopsis[""] = s }
        for kid in kids {
            let scene = title(kid)
            text += Scenes.markerLine(scene) + "\n\n"
            if let t = try await documentText(kid, project: project, cwd: cwd), !t.isEmpty { text += t + "\n\n" }
            if let s = documentSynopsis(kid, project: project) { synopsis[scene] = s }
        }
        chapters.append(.init(title: name, text: text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n", synopsis: synopsis))
    }

    private static func dataDir(_ item: XMLElement, project: URL) -> URL? {
        guard let uuid = item.attribute(forName: "UUID")?.stringValue ?? item.attribute(forName: "ID")?.stringValue else { return nil }
        return project.appendingPathComponent("Files/Data/\(uuid)", isDirectory: true)
    }

    private static func documentSynopsis(_ item: XMLElement, project: URL) -> String? {
        guard let dir = dataDir(item, project: project) else { return nil }
        let s = try? String(contentsOf: dir.appendingPathComponent("synopsis.txt"), encoding: .utf8)
        return s?.isEmpty == true ? nil : s
    }

    private static func documentText(_ item: XMLElement, project: URL, cwd: URL) async throws -> String? {
        guard let dir = dataDir(item, project: project) else { return nil }
        let id = item.attribute(forName: "ID")?.stringValue ?? ""
        let candidates = [dir.appendingPathComponent("content.rtf"), project.appendingPathComponent("Files/Docs/\(id).rtf")]
        guard let file = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else { return nil }
        let out = try await ExportService.runPandoc([file.path, "-f", "rtf", "-t", "gfm", "--wrap=none"], cwd: cwd)
        if out.ok { return out.stdout.trimmingCharacters(in: .whitespacesAndNewlines) }
        let attr = try NSAttributedString(url: file, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
        return attr.string.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Ulysses

    /// A Markdown export: a subfolder is a chapter and its sheets are scenes; a sheet on its own is a chapter.
    static func planFolder(_ folder: URL) throws -> ImportPlan {
        let fm = FileManager.default
        func listing(_ dir: URL) throws -> [URL] {
            try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        }
        func isSheet(_ u: URL) -> Bool { ["md", "markdown", "txt", "textbundle", "ulysses"].contains(u.pathExtension.lowercased()) }
        func sheet(_ u: URL) -> String {
            let file = u.pathExtension == "textbundle" ? u.appendingPathComponent("text.md") : u
            return (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        }
        func name(_ u: URL) -> String { u.deletingPathExtension().lastPathComponent }
        var chapters: [PlannedChapter] = []
        for u in try listing(folder) {
            if isSheet(u) {
                let t = sheet(u)
                chapters.append(.init(title: Self.heading(t) ?? name(u), text: Self.withHeading(t, name(u))))
            } else if (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                let sheets = try listing(u).filter(isSheet)
                guard !sheets.isEmpty else { continue }
                let body = sheets.map { Scenes.markerLine(Self.heading(sheet($0)) ?? name($0)) + "\n\n" + Self.withoutHeading(sheet($0)) }.joined(separator: "\n\n")
                chapters.append(.init(title: name(u), text: "# \(name(u))\n\n\(body)\n"))
            }
        }
        guard !chapters.isEmpty else {
            throw BibleImporter.Failure(L("No Markdown sheets in this folder. In Ulysses, export the group as Markdown first."))
        }
        return ImportPlan(source: .ulysses, file: folder, title: folder.lastPathComponent,
                          rule: L("Ulysses keeps its texts in its library: this is the Markdown you exported."),
                          chapters: chapters, keeps: [(L("Groups"), L("Chapters")), (L("Sheets"), L("Scenes")), ("Markdown", L("As it is"))])
    }

    private static func heading(_ t: String) -> String? {
        t.split(separator: "\n", maxSplits: 1).first.flatMap { $0.hasPrefix("# ") ? String($0.dropFirst(2)).trimmingCharacters(in: .whitespaces) : nil }
    }
    private static func withHeading(_ t: String, _ fallback: String) -> String { heading(t) != nil ? t : "# \(fallback)\n\n\(t)" }
    private static func withoutHeading(_ t: String) -> String {
        guard heading(t) != nil, let nl = t.firstIndex(of: "\n") else { return heading(t) != nil ? "" : t }
        return String(t[nl...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
