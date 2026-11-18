import Foundation

/// A Word file as a publishing house expects one: named styles and no manual layout, so it flows into InDesign;
/// A4, Times 12, one and a half lines; real footnotes; change tracking already on, so nothing an editor does goes unseen.
enum WordManuscript {
    static let exportProperty = "musset_export"
    static let chapterBookmark = "mch_"
    /// The line over a piece's title, and the title that follows it on the same page.
    static let pieceLineStyle = "ChapterNumber"
    static let pieceTitleStyle = "ChapterTitle"

    /// What was sent, kept in the book (`.musset/word-exports/<id>.json`): the reference a corrected file is compared with.
    struct Sent: Codable {
        var id: String
        var date: Date
        var title: String
        var commit: String?
        var chapters: [String]
        var main: [WordParagraph]
        var notes: [WordParagraph]
    }

    static func directory(_ root: URL) -> URL { root.appendingPathComponent(".musset/word-exports", isDirectory: true) }

    static func save(_ sent: Sent, root: URL) throws {
        try JSONFile.write(sent, to: directory(root).appendingPathComponent(sent.id + ".json"), [.sortedKeys, .withoutEscapingSlashes], iso8601: true)
    }

    static func allSent(root: URL) -> [Sent] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory(root), includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" && $0.lastPathComponent != "imports.json" }
            .compactMap { JSONFile.read(Sent.self, at: $0, iso8601: true) }
    }

    // MARK: The source

    /// The chapters for pandoc, each inside a bookmark, its scene breaks in their style.
    static func source(_ m: BookManifest, store: BookStore) -> (text: String, chapters: [String]) {
        let chapters = m.chapters.filter { !$0.excludeFromExport }
        let parts = m.groupOpenings
        var out = ""
        for (i, ch) in chapters.enumerated() {
            // Outside the chapters' bookmarks: a corrected Word file brings back only what is inside them.
            // The group's line is never empty: « II », « Acte II », or its title for a level without numbers.
            if let p = parts[ch.id] {
                out += "::: {custom-style=\"PartNumber\"}\n\(p.line)\n:::\n\n"
                if !p.title.isEmpty { out += "::: {custom-style=\"PartTitle\"}\n\(p.title)\n:::\n\n" }
            }
            let source = ListLines.forPandoc(Revisions.resolveAll(store.read(ch), accept: false), m.printedListOptions)
            // A formed book's piece: its line (« Chapitre 3 », « Prologue ») in a style of its own, and a heading for
            // a text that has none. Outside the bookmark too: they are the form's, not the text's to correct.
            if let opening = m.opening(of: ch, text: source) {
                if let label = opening.label { out += "::: {custom-style=\"\(pieceLineStyle)\"}\n\(label)\n:::\n\n" }
                if let title = opening.title { out += "# \(title)\n\n" }
            }
            var text = BookStore.sceneBreaks(source, m.sceneBreak ?? .none)
            text = BookStore.stripHTMLComments(text)
            text = text.components(separatedBy: "\n").map { line in
                line == "⁂" || line == "&nbsp;" ? "::: {custom-style=\"SceneBreak\"}\n\(line)\n:::" : line
            }.joined(separator: "\n")
            out += "::: {#\(chapterBookmark)\(i)}\n\n" + text + "\n\n:::\n\n"
        }
        return (out, chapters.map(\.id))
    }

    static func front(_ m: BookManifest, contact: Bool) -> String {
        let f = m.front ?? FrontMatter()
        func clean(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
        var out = ""
        if contact, !m.contact.isEmpty { out += "::: {custom-style=\"Contact\"}\n\(clean(m.contact).replacingOccurrences(of: "\n", with: "  \n"))\n:::\n\n" }
        if f.has(.dedication), let d = f.dedication { out += "::: {custom-style=\"Dedication\"}\n\(clean(d))\n:::\n\n" }
        if f.has(.epigraph), let e = f.epigraph {
            out += "::: {custom-style=\"Epigraph\"}\n\(clean(e))\n:::\n\n"
            if let s = f.epigraphSource, !s.isEmpty { out += "::: {custom-style=\"EpigraphSource\"}\n\(clean(s))\n:::\n\n" }
        }
        return out
    }

    static func back(_ m: BookManifest) -> String {
        let f = m.front ?? FrontMatter()
        var out = ""
        if f.has(.acknowledgements), let a = f.acknowledgements {
            out += "\n# \(BookTerm.acknowledgements.in(m.lang)) {.unnumbered}\n\n\(a.trimmingCharacters(in: .whitespacesAndNewlines))\n"
        }
        if f.has(.colophon) { out += "\n::: {custom-style=\"Colophon\"}\n\(Colophon.text(m).replacingOccurrences(of: "\n", with: "  \n"))\n:::\n" }
        return out
    }

    // MARK: After pandoc

    /// Finishes the file pandoc wrote and returns what was sent. `styled`: Musset's styles and page; the author's own template otherwise.
    static func finish(docx: URL, manifest m: BookManifest, store: BookStore, chapters: [String], id: String, styled: Bool) async throws -> Sent {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("musset-word-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        guard try await Shell.runAsync("/usr/bin/unzip", ["-q", docx.path, "-d", dir.path]).ok else { throw failure("unzip") }
        func edit(_ path: String, _ change: (String) -> String) throws {
            let url = dir.appendingPathComponent(path)
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            try change(text).write(to: url, atomically: true, encoding: .utf8)
        }
        try edit("word/settings.xml") { settings($0, lang: wordLanguage(m.lang)) }
        if styled {
            try edit("word/styles.xml") { styles($0, lang: m.lang, running: m.hasForm ? m.level(.piece).opens == .inPage : nil) }
            try edit("word/document.xml", document)
            try edit("word/footnotes.xml") { characterStyles($0) }
            try header(m).write(to: dir.appendingPathComponent("word/header1.xml"), atomically: true, encoding: .utf8)
            try footer.write(to: dir.appendingPathComponent("word/footer1.xml"), atomically: true, encoding: .utf8)
            try edit("word/_rels/document.xml.rels") {
                $0.replacingOccurrences(of: "</Relationships>", with:
                    #"<Relationship Id="rIdMussetHeader" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/header" Target="header1.xml"/><Relationship Id="rIdMussetFooter" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/footer" Target="footer1.xml"/></Relationships>"#)
            }
            try edit("[Content_Types].xml") {
                $0.replacingOccurrences(of: "</Types>", with:
                    #"<Override PartName="/word/header1.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.header+xml"/><Override PartName="/word/footer1.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.footer+xml"/></Types>"#)
            }
        }
        let sentContent = try DocxContent.read(dir: dir, chapterBookmarks: chapters)
        try? FileManager.default.removeItem(at: docx)
        guard try await Shell.runAsync("/usr/bin/zip", ["-q", "-X", "-r", docx.path, "[Content_Types].xml", "."], cwd: dir).ok else { throw failure("zip") }

        // A footnote belongs to the chapter that calls it.
        var owners: [String: String] = [:]
        for p in sentContent.accepted { for run in p.runs { if let n = run.note, let c = p.chapter { owners[n] = c } } }
        let notesWithChapters = sentContent.acceptedNotes.map { p -> WordParagraph in
            var p = p
            p.chapter = p.note.flatMap { owners[$0] }
            return p
        }
        return Sent(id: id, date: Date(), title: m.title, commit: GitService(root: store.root).resolve(store.revision ?? "HEAD"), chapters: chapters,
                    main: sentContent.accepted, notes: notesWithChapters)
    }

    private static func failure(_ tool: String) -> NSError {
        NSError(domain: "Musset.word", code: 2, userInfo: [NSLocalizedDescriptionKey: L("Could not finish the Word file (\(tool)).")])
    }

    static func wordLanguage(_ lang: String) -> String {
        if lang.contains("-") { return lang }
        switch lang.lowercased().prefix(2) {
        case "fr": return "fr-FR"
        case "en": return "en-GB"
        case "es": return "es-ES"
        case "de": return "de-DE"
        case "it": return "it-IT"
        default: return lang
        }
    }

    /// Change tracking on from the first keystroke; no hyphenation, that is for the layout.
    static func settings(_ xml: String, lang: String) -> String {
        var out = xml
        if !out.contains("<w:trackRevisions") {
            if let r = out.range(of: "<w:doNotTrackMoves") { out.insert(contentsOf: "<w:trackRevisions />", at: r.lowerBound) }
            else if let r = out.range(of: "<w:defaultTabStop") { out.insert(contentsOf: "<w:trackRevisions />", at: r.lowerBound) }
        }
        return out.replacingOccurrences(of: #"<w:themeFontLang w:val="[^"]*" />"#, with: "<w:themeFontLang w:val=\"\(lang)\" />", options: .regularExpression)
    }

    /// Italics and bold through their character styles; the first paragraph after a break sits flush; the page is set once.
    static func document(_ xml: String) -> String {
        var out = characterStyles(xml)
        let pattern = try! NSRegularExpression(pattern: #"<w:pStyle w:val="([^"]+)" />"#)
        let ns = out as NSString
        var previous = ""
        var replacements: [NSRange] = []
        var titles: [NSRange] = []
        for m in pattern.matches(in: out, range: NSRange(location: 0, length: ns.length)) {
            let style = ns.substring(with: m.range(at: 1))
            if style == "BodyText", previous == "SceneBreak" { replacements.append(m.range) }
            // Under its line, a title stays on the line's page: the line took the new page.
            if style == "Heading1", previous == pieceLineStyle { titles.append(m.range) }
            previous = style
        }
        let mutable = NSMutableString(string: out)
        for (r, style) in (replacements.map { ($0, "FirstParagraph") } + titles.map { ($0, pieceTitleStyle) }).sorted(by: { $0.0.location > $1.0.location }) {
            mutable.replaceCharacters(in: r, with: #"<w:pStyle w:val="\#(style)" />"#)
        }
        out = mutable as String
        // Only the last one is left: one page setting for the whole manuscript.
        let section = #"<w:sectPr><w:headerReference w:type="default" r:id="rIdMussetHeader"/><w:footerReference w:type="default" r:id="rIdMussetFooter"/><w:pgSz w:w="11906" w:h="16838"/><w:pgMar w:top="1418" w:right="1418" w:bottom="1418" w:left="1418" w:header="709" w:footer="709" w:gutter="0"/><w:titlePg/></w:sectPr>"#
        if let open = out.range(of: "<w:sectPr", options: .backwards), let close = out.range(of: "</w:sectPr>", range: open.upperBound..<out.endIndex) {
            out.replaceSubrange(open.lowerBound..<close.upperBound, with: section)
        } else if let end = out.range(of: "</w:body>") {
            out.insert(contentsOf: section, at: end.lowerBound)
        }
        return out
    }

    static func characterStyles(_ xml: String) -> String {
        xml.replacingOccurrences(of: #"<w:rPr><w:i /><w:iCs /></w:rPr>"#, with: #"<w:rPr><w:rStyle w:val="Emphasis" /></w:rPr>"#)
            .replacingOccurrences(of: #"<w:rPr><w:b /><w:bCs /></w:rPr>"#, with: #"<w:rPr><w:rStyle w:val="Strong" /></w:rPr>"#)
    }

    private static let wordNamespace = #"xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships""#

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func header(_ m: BookManifest) -> String {
        #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:hdr \#(wordNamespace)><w:p><w:pPr><w:pStyle w:val="Header"/></w:pPr><w:r><w:t xml:space="preserve">\#(escape(m.author)) — \#(escape(m.title))</w:t></w:r></w:p></w:hdr>"#
    }

    private static var footer: String {
        #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:ftr \#(wordNamespace)><w:p><w:pPr><w:pStyle w:val="Footer"/></w:pPr><w:r><w:fldChar w:fldCharType="begin"/></w:r><w:r><w:instrText xml:space="preserve"> PAGE </w:instrText></w:r><w:r><w:fldChar w:fldCharType="separate"/></w:r><w:r><w:t>1</w:t></w:r><w:r><w:fldChar w:fldCharType="end"/></w:r></w:p></w:ftr>"#
    }

    // MARK: Styles

    private struct Style {
        var id: String
        var name: String
        var type = "paragraph"
        var basedOn: String? = "Normal"
        var next: String? = nil
        var paragraph = ""
        var run = ""
        var custom = false
    }

    /// Word's own names for what it knows (it shows them in the author's language), the book's language for the rest.
    /// `running`: nil for a book without a form, whose styles are the ones Musset always wrote; in a formed book,
    /// whether its pieces open in the page (fragments, a journal's entries), one after the other.
    private static func styleSet(lang: String, running: Bool?) -> [Style] {
        func n(_ term: BookTerm) -> String { term.in(lang) }
        let body = #"<w:widowControl/><w:spacing w:before="0" w:after="0" w:line="360" w:lineRule="auto"/>"#
        var styles = [
            Style(id: "Normal", name: "Normal", basedOn: nil, paragraph: body),
            Style(id: "BodyText", name: "Body Text", paragraph: #"<w:ind w:firstLine="425"/>"#),
            Style(id: "FirstParagraph", name: n(.noIndent), basedOn: "Normal", next: "BodyText", custom: true),
            Style(id: "Compact", name: "Compact", paragraph: #"<w:spacing w:before="0" w:after="0" w:line="240" w:lineRule="auto"/>"#, custom: true),
            Style(id: "Title", name: "Title", next: "Author", paragraph: #"<w:spacing w:before="3600" w:after="240" w:line="240" w:lineRule="auto"/><w:jc w:val="center"/>"#, run: #"<w:sz w:val="48"/><w:szCs w:val="48"/>"#),
            Style(id: "Subtitle", name: "Subtitle", next: "Author", paragraph: #"<w:spacing w:after="240" w:line="240" w:lineRule="auto"/><w:jc w:val="center"/>"#, run: #"<w:sz w:val="28"/><w:szCs w:val="28"/>"#),
            Style(id: "Author", name: n(.author), paragraph: #"<w:spacing w:after="240" w:line="240" w:lineRule="auto"/><w:jc w:val="center"/>"#, run: #"<w:sz w:val="28"/><w:szCs w:val="28"/>"#, custom: true),
            Style(id: "Date", name: "Date", paragraph: #"<w:jc w:val="center"/>"#),
            Style(id: "Contact", name: "Contact", paragraph: #"<w:spacing w:before="1200" w:line="240" w:lineRule="auto"/><w:jc w:val="center"/>"#, custom: true),
            Style(id: "Dedication", name: n(.dedication), next: "Normal", paragraph: #"<w:pageBreakBefore/><w:spacing w:before="2400"/><w:ind w:left="3402"/>"#, run: "<w:i/><w:iCs/>", custom: true),
            Style(id: "Epigraph", name: n(.epigraph), next: "EpigraphSource", paragraph: #"<w:pageBreakBefore/><w:spacing w:before="2400"/><w:ind w:left="3402"/>"#, run: "<w:i/><w:iCs/>", custom: true),
            Style(id: "EpigraphSource", name: n(.epigraphSource), paragraph: #"<w:spacing w:before="120"/><w:ind w:left="3402"/><w:jc w:val="right"/>"#, custom: true),
            Style(id: "PartNumber", name: n(.partNumber), next: "PartTitle", paragraph: #"<w:keepNext/><w:pageBreakBefore/><w:spacing w:before="3600" w:after="360" w:line="240" w:lineRule="auto"/><w:jc w:val="center"/>"#, run: #"<w:sz w:val="40"/><w:szCs w:val="40"/>"#, custom: true),
            Style(id: "PartTitle", name: n(.partTitle), paragraph: #"<w:spacing w:line="240" w:lineRule="auto"/><w:jc w:val="center"/>"#, run: #"<w:i/><w:iCs/><w:sz w:val="28"/><w:szCs w:val="28"/>"#, custom: true),
            Style(id: "SceneBreak", name: n(.sceneBreak), next: "FirstParagraph", paragraph: #"<w:keepNext/><w:spacing w:before="240" w:after="240"/><w:jc w:val="center"/>"#, custom: true),
            Style(id: "BlockText", name: n(.blockQuote), next: "BodyText", paragraph: #"<w:spacing w:before="120" w:after="120" w:line="300" w:lineRule="auto"/><w:ind w:left="567" w:right="567"/>"#, custom: true),
            Style(id: "Colophon", name: n(.colophonStyle), paragraph: #"<w:pageBreakBefore/><w:spacing w:line="240" w:lineRule="auto"/><w:jc w:val="center"/>"#, custom: true),
            Style(id: "FootnoteText", name: "footnote text", paragraph: #"<w:spacing w:after="60" w:line="240" w:lineRule="auto"/>"#, run: #"<w:sz w:val="20"/><w:szCs w:val="20"/>"#),
            Style(id: "FootnoteBlockText", name: "Footnote Block Text", basedOn: "FootnoteText", paragraph: #"<w:ind w:left="284" w:right="284"/>"#, custom: true),
            Style(id: "Header", name: "header", paragraph: #"<w:spacing w:line="240" w:lineRule="auto"/><w:jc w:val="right"/>"#, run: #"<w:sz w:val="20"/><w:szCs w:val="20"/>"#),
            Style(id: "Footer", name: "footer", paragraph: #"<w:spacing w:line="240" w:lineRule="auto"/><w:jc w:val="center"/>"#, run: #"<w:sz w:val="20"/><w:szCs w:val="20"/>"#),
            Style(id: "Emphasis", name: "Emphasis", type: "character", basedOn: nil, run: "<w:i/><w:iCs/>"),
            Style(id: "Strong", name: "Strong", type: "character", basedOn: nil, run: "<w:b/><w:bCs/>"),
            Style(id: "FootnoteReference", name: "footnote reference", type: "character", basedOn: nil, run: #"<w:vertAlign w:val="superscript"/>"#),
        ]
        if running == true {
            // A formed book whose pieces run on: the same heading, without its page.
            styles.append(Style(id: "Heading1", name: "heading 1", next: "FirstParagraph",
                                paragraph: #"<w:keepNext/><w:keepLines/><w:spacing w:before="720" w:after="360" w:line="240" w:lineRule="auto"/><w:jc w:val="center"/><w:outlineLvl w:val="0"/>"#,
                                run: #"<w:sz w:val="32"/><w:szCs w:val="32"/>"#))
        } else {
            styles.append(Style(id: "Heading1", name: "heading 1", next: "FirstParagraph",
                                paragraph: #"<w:keepNext/><w:keepLines/><w:pageBreakBefore/><w:spacing w:before="1200" w:after="720" w:line="240" w:lineRule="auto"/><w:jc w:val="center"/><w:outlineLvl w:val="0"/>"#,
                                run: #"<w:sz w:val="32"/><w:szCs w:val="32"/>"#))
        }
        guard let running else { return styles + headings() }
        // A formed book's piece: its line where the heading would start, its title close under it.
        styles.append(Style(id: pieceLineStyle, name: n(.pieceLine), next: pieceTitleStyle,
                            paragraph: "<w:keepNext/>" + (running ? "" : "<w:pageBreakBefore/>") + #"<w:spacing w:before="\#(running ? 720 : 1200)" w:after="120" w:line="240" w:lineRule="auto"/><w:jc w:val="center"/>"#,
                            run: #"<w:sz w:val="26"/><w:szCs w:val="26"/>"#, custom: true))
        styles.append(Style(id: pieceTitleStyle, name: n(.pieceTitle), basedOn: "Heading1", next: "FirstParagraph",
                            paragraph: #"<w:pageBreakBefore w:val="0"/><w:spacing w:before="0" w:after="\#(running ? 360 : 720)" w:line="240" w:lineRule="auto"/>"#, custom: true))
        return styles + headings()
    }

    private static func headings() -> [Style] {
        (2...9).map { level in
            Style(id: "Heading\(level)", name: "heading \(level)", next: "FirstParagraph",
                  paragraph: #"<w:keepNext/><w:keepLines/><w:spacing w:before="480" w:after="240" w:line="240" w:lineRule="auto"/><w:jc w:val="center"/><w:outlineLvl w:val="\#(level - 1)"/>"#,
                  run: #"<w:sz w:val="26"/><w:szCs w:val="26"/>"#)
        }
    }

    /// The styles of the file become these; everything pandoc needs and these don't name stays.
    static func styles(_ xml: String, lang: String, running: Bool? = nil) -> String {
        let set = styleSet(lang: lang, running: running)
        let code = wordLanguage(lang)
        var out = xml
        let defaults = #"<w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Times New Roman" w:hAnsi="Times New Roman" w:eastAsia="Times New Roman" w:cs="Times New Roman"/><w:sz w:val="24"/><w:szCs w:val="24"/><w:lang w:val="\#(code)" w:eastAsia="\#(code)" w:bidi="ar-SA"/></w:rPr></w:rPrDefault><w:pPrDefault/></w:docDefaults>"#
        // Pandoc's blues and fonts go: nothing colours or sets a manuscript's text.
        out = out.replacingOccurrences(of: #"<w:color [^>]*/>"#, with: "", options: .regularExpression)
        out = out.replacingOccurrences(of: #"<w:rFonts [^>]*/>"#, with: "", options: .regularExpression)
        out = out.replacingOccurrences(of: #"<w:docDefaults>[\s\S]*?</w:docDefaults>"#, with: defaults, options: .regularExpression)
        for style in set {
            let pattern = #"<w:style [^>]*w:styleId="\#(style.id)"[^>]*>[\s\S]*?</w:style>"#
            out = out.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        let added = set.map { s -> String in
            var xml = #"<w:style w:type="\#(s.type)""# + (s.id == "Normal" ? #" w:default="1""# : "") + (s.custom ? #" w:customStyle="1""# : "") + #" w:styleId="\#(s.id)">"#
            xml += #"<w:name w:val="\#(escape(s.name))"/>"#
            if let b = s.basedOn { xml += #"<w:basedOn w:val="\#(b)"/>"# }
            if let n = s.next { xml += #"<w:next w:val="\#(n)"/>"# }
            xml += "<w:qFormat/>"
            if !s.paragraph.isEmpty { xml += "<w:pPr>\(s.paragraph)</w:pPr>" }
            if !s.run.isEmpty { xml += "<w:rPr>\(s.run)</w:rPr>" }
            return xml + "</w:style>"
        }.joined()
        return out.replacingOccurrences(of: "</w:styles>", with: added + "</w:styles>")
    }
}
