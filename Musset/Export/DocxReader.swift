import Foundation

/// A stretch of text with one format, as Word shows it.
struct WordRun: Codable, Equatable {
    struct Format: OptionSet, Codable, Hashable {
        let rawValue: Int
        static let italic = Format(rawValue: 1)
        static let bold = Format(rawValue: 2)
        static let sup = Format(rawValue: 4)
        static let sub = Format(rawValue: 8)
    }
    var text: String
    var format: Format = []
    /// The footnote this run calls, for a reference run (its text is `WordRun.noteMark`).
    var note: String? = nil

    static let noteMark = "\u{FFFC}"
}

struct WordParagraph: Codable, Equatable {
    var runs: [WordRun] = []
    var style: String? = nil
    /// The chapter this paragraph belongs to, known in what Musset exported.
    var chapter: String? = nil
    /// A footnote's paragraph: which one.
    var note: String? = nil

    var text: String { runs.map(\.text).joined() }
}

/// A comment of the document, with its passage as it stood before the changes.
struct WordComment: Equatable {
    var id: String
    var author: String
    var date: Date?
    var body: String
    var done = false
    /// The comment it answers, in a thread.
    var parent: String?
    var quote = ""
    var before = ""
    var after = ""
    /// Index in `DocxContent.rejected` of the paragraph it starts in.
    var paragraph = 0
}

/// What a .docx says: its text with every change accepted, its text with every change refused, its comments.
struct DocxContent {
    struct Tally: Equatable { var insertions = 0; var deletions = 0 }

    var accepted: [WordParagraph] = []
    var rejected: [WordParagraph] = []
    var acceptedNotes: [WordParagraph] = []
    var rejectedNotes: [WordParagraph] = []
    var comments: [WordComment] = []
    /// Tracked changes per author.
    var tallies: [String: Tally] = [:]
    /// The export this file came from, when the custom property survived.
    var exportID: String?
    var lastModifiedBy: String?

    var hasRevisions: Bool { !tallies.isEmpty }

    /// Reads an unzipped .docx.
    static func read(dir: URL, chapterBookmarks: [String] = []) throws -> DocxContent {
        func document(_ path: String) -> XMLDocument? {
            guard let raw = try? String(contentsOf: dir.appendingPathComponent(path), encoding: .utf8) else { return nil }
            return try? XMLDocument(xmlString: protectingSpaces(raw), options: [.nodePreserveWhitespace])
        }
        guard let main = document("word/document.xml")?.rootElement() else {
            throw NSError(domain: "Musset.word", code: 1, userInfo: [NSLocalizedDescriptionKey: L("This file could not be read as a .docx.")])
        }
        var out = DocxContent()
        out.exportID = customProperty(WordManuscript.exportProperty, in: document("docProps/custom.xml"))
        out.lastModifiedBy = document("docProps/core.xml")?.rootElement()?.elements(forName: "cp:lastModifiedBy").first?.stringValue
        let walker = Walker(styles: characterStyles(document("word/styles.xml")), bookmarks: chapterBookmarks)
        walker.comments = comments(document("word/comments.xml"), extended: document("word/commentsExtended.xml"))
        walker.walk(main)
        walker.finishParagraph(state: .normal, style: nil)

        // Footnotes: the same reading, each in the order the text calls it.
        var notes: [String: XMLElement] = [:]
        for element in document("word/footnotes.xml")?.rootElement()?.elements(forName: "w:footnote") ?? [] {
            if let id = element.attribute(forName: "w:id")?.stringValue, element.attribute(forName: "w:type") == nil { notes[id] = element }
        }
        let body = (accepted: walker.accepted, rejected: walker.rejected)
        let noteWalker = Walker(styles: walker.styles, bookmarks: [])
        for id in walker.noteOrder {
            guard let element = notes[id] else { continue }
            noteWalker.currentNote = id
            noteWalker.walk(element)
            noteWalker.finishParagraph(state: .normal, style: nil)
        }
        out.accepted = body.accepted
        out.rejected = body.rejected
        out.acceptedNotes = noteWalker.accepted
        out.rejectedNotes = noteWalker.rejected
        out.comments = walker.finishedComments()
        out.tallies = walker.tallies.merging(noteWalker.tallies) { a, b in Tally(insertions: a.insertions + b.insertions, deletions: a.deletions + b.deletions) }
        return out
    }

    /// XMLDocument drops a text made only of spaces, whatever it is asked: and `<w:t> </w:t>` is the space between
    /// a word in italics and the next. It goes through as a private character, put back when the run is read.
    static let protectedSpace = "\u{E001}"
    private static let blankText = try! NSRegularExpression(pattern: #"(<w:(?:t|delText)(?:\s[^>]*)?>)[ \t\r\n]+(</w:(?:t|delText)>)"#)

    static func protectingSpaces(_ xml: String) -> String {
        blankText.stringByReplacingMatches(in: xml, range: NSRange(location: 0, length: (xml as NSString).length), withTemplate: "$1\(protectedSpace)$2")
    }

    private static func customProperty(_ name: String, in doc: XMLDocument?) -> String? {
        for property in doc?.rootElement()?.elements(forName: "property") ?? [] where property.attribute(forName: "name")?.stringValue == name {
            return property.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    /// Which character styles mean italic or bold, whatever they are called in this copy of Word.
    private static func characterStyles(_ doc: XMLDocument?) -> [String: WordRun.Format] {
        var out: [String: WordRun.Format] = [:]
        for style in doc?.rootElement()?.elements(forName: "w:style") ?? [] where style.attribute(forName: "w:type")?.stringValue == "character" {
            guard let id = style.attribute(forName: "w:styleId")?.stringValue, let props = style.elements(forName: "w:rPr").first else { continue }
            out[id] = Walker.format(of: props, styles: [:])
        }
        return out
    }

    private static func comments(_ doc: XMLDocument?, extended: XMLDocument?) -> [String: WordComment] {
        var extras: [String: (parent: String?, done: Bool)] = [:]
        for ex in extended?.rootElement()?.elements(forName: "w15:commentEx") ?? [] {
            guard let para = ex.attribute(forName: "w15:paraId")?.stringValue else { continue }
            extras[para] = (ex.attribute(forName: "w15:paraIdParent")?.stringValue, ex.attribute(forName: "w15:done")?.stringValue == "1")
        }
        var byParaID: [String: String] = [:]
        var out: [String: WordComment] = [:]
        let dates = ISO8601DateFormatter()
        for c in doc?.rootElement()?.elements(forName: "w:comment") ?? [] {
            guard let id = c.attribute(forName: "w:id")?.stringValue else { continue }
            let paragraphs = c.elements(forName: "w:p")
            let body = paragraphs.map { p in Walker.plainText(p) }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            var comment = WordComment(id: id, author: c.attribute(forName: "w:author")?.stringValue ?? "",
                                      date: c.attribute(forName: "w:date")?.stringValue.flatMap { dates.date(from: $0) }, body: body)
            // Word ties a thread to the last paragraph of each comment.
            if let last = paragraphs.last?.attribute(forName: "w14:paraId")?.stringValue {
                byParaID[last] = id
                if let extra = extras[last] { comment.done = extra.done; comment.parent = extra.parent }
            }
            out[id] = comment
        }
        for id in out.keys { if let parent = out[id]?.parent { out[id]?.parent = byParaID[parent] } }
        return out
    }
}

/// One pass over Word's XML, building both readings of the text at once.
private final class Walker {
    enum State { case normal, inserted, deleted }

    let styles: [String: WordRun.Format]
    let bookmarks: [String]
    var accepted: [WordParagraph] = []
    var rejected: [WordParagraph] = []
    var noteOrder: [String] = []
    var tallies: [String: DocxContent.Tally] = [:]
    var comments: [String: WordComment] = [:]
    var currentNote: String?

    private var openA = WordParagraph()
    private var openR = WordParagraph()
    private var chapter: String?
    private var chapterBookmarkIDs: [String: Bool] = [:]
    private var openComments: Set<String> = []
    private var started: Set<String> = []
    private var quotes: [String: String] = [:]
    private var starts: [String: (paragraph: Int, offset: Int)] = [:]
    private var ends: [String: (paragraph: Int, offset: Int)] = [:]

    init(styles: [String: WordRun.Format], bookmarks: [String]) {
        self.styles = styles
        self.bookmarks = bookmarks
    }

    static func format(of props: XMLElement, styles: [String: WordRun.Format]) -> WordRun.Format {
        var f: WordRun.Format = []
        func on(_ name: String) -> Bool {
            guard let e = props.elements(forName: name).first else { return false }
            let v = e.attribute(forName: "w:val")?.stringValue
            return v != "0" && v != "false" && v != "none"
        }
        if on("w:i") { f.insert(.italic) }
        if on("w:b") { f.insert(.bold) }
        switch props.elements(forName: "w:vertAlign").first?.attribute(forName: "w:val")?.stringValue {
        case "superscript": f.insert(.sup)
        case "subscript": f.insert(.sub)
        default: break
        }
        if let style = props.elements(forName: "w:rStyle").first?.attribute(forName: "w:val")?.stringValue, let s = styles[style] { f.formUnion(s) }
        return f
    }

    static func plainText(_ element: XMLElement) -> String {
        var out = ""
        for child in element.children ?? [] {
            guard let e = child as? XMLElement else { continue }
            switch e.name {
            case "w:t": out += (e.stringValue ?? "").replacingOccurrences(of: DocxContent.protectedSpace, with: " ")
            case "w:tab": out += "\t"
            case "w:br": out += "\n"
            case "w:delText", "w:instrText": break
            default: out += plainText(e)
            }
        }
        return out
    }

    func walk(_ element: XMLElement) {
        for child in element.children ?? [] {
            guard let e = child as? XMLElement else { continue }
            visit(e, state: .normal, author: nil)
        }
    }

    private func visit(_ e: XMLElement, state: State, author: String?) {
        switch e.name {
        case "w:p": paragraph(e)
        case "w:ins", "w:moveTo": container(e, state: .inserted)
        case "w:del", "w:moveFrom": container(e, state: .deleted)
        case "w:r": run(e, state: state, author: author)
        case "w:bookmarkStart":
            // Pandoc may hide the name behind an underscore.
            if let name = e.attribute(forName: "w:name")?.stringValue.map({ $0.hasPrefix("_") ? String($0.dropFirst()) : $0 }), name.hasPrefix(WordManuscript.chapterBookmark),
               let i = Int(name.dropFirst(WordManuscript.chapterBookmark.count)), bookmarks.indices.contains(i) {
                flushEmptyOpen()
                chapter = bookmarks[i]
                if let id = e.attribute(forName: "w:id")?.stringValue { chapterBookmarkIDs[id] = true }
            }
        case "w:bookmarkEnd":
            if let id = e.attribute(forName: "w:id")?.stringValue, chapterBookmarkIDs[id] == true { chapter = nil }
        case "w:commentRangeStart":
            if let id = e.attribute(forName: "w:id")?.stringValue {
                openComments.insert(id)
                started.insert(id)
                starts[id] = (rejected.count, utf16(openR))
            }
        case "w:commentRangeEnd":
            if let id = e.attribute(forName: "w:id")?.stringValue {
                openComments.remove(id)
                ends[id] = (rejected.count, utf16(openR))
            }
        case "w:pPr", "w:rPr", "w:sectPr", "w:tblPr", "w:tblGrid", "w:trPr", "w:tcPr", "w:proofErr": break
        // A table of contents is not the book's text.
        case "w:sdt" where isTableOfContents(e): break
        default:
            for child in e.children ?? [] {
                if let inner = child as? XMLElement { visit(inner, state: state, author: author) }
            }
        }
    }

    private func isTableOfContents(_ sdt: XMLElement) -> Bool {
        guard let props = sdt.elements(forName: "w:sdtPr").first?.elements(forName: "w:docPartObj").first else { return false }
        return props.elements(forName: "w:docPartGallery").first?.attribute(forName: "w:val")?.stringValue?.contains("Table of Contents") == true
    }

    private func container(_ e: XMLElement, state: State) {
        let author = e.attribute(forName: "w:author")?.stringValue ?? ""
        for child in e.children ?? [] {
            guard let inner = child as? XMLElement else { continue }
            if inner.name == "w:r" { tally(author, state) }
            visit(inner, state: state, author: author)
        }
    }

    private func tally(_ author: String, _ state: State) {
        if state == .inserted { tallies[author, default: .init()].insertions += 1 }
        if state == .deleted { tallies[author, default: .init()].deletions += 1 }
    }

    private func paragraph(_ p: XMLElement) {
        let props = p.elements(forName: "w:pPr").first
        let style = props?.elements(forName: "w:pStyle").first?.attribute(forName: "w:val")?.stringValue
        for child in p.children ?? [] {
            guard let e = child as? XMLElement else { continue }
            visit(e, state: .normal, author: nil)
        }
        // A tracked paragraph mark decides where each reading breaks.
        var state = State.normal
        if let mark = props?.elements(forName: "w:rPr").first {
            if let i = mark.elements(forName: "w:ins").first ?? mark.elements(forName: "w:moveTo").first {
                state = .inserted
                tally(i.attribute(forName: "w:author")?.stringValue ?? "", .inserted)
            } else if let d = mark.elements(forName: "w:del").first ?? mark.elements(forName: "w:moveFrom").first {
                state = .deleted
                tally(d.attribute(forName: "w:author")?.stringValue ?? "", .deleted)
            }
        }
        finishParagraph(state: state, style: style)
    }

    func finishParagraph(state: State, style: String?) {
        if state != .deleted {
            openA.style = style ?? openA.style
            flush(&openA, into: &accepted)
        }
        if state != .inserted {
            openR.style = style ?? openR.style
            flush(&openR, into: &rejected)
        }
    }

    /// Word's empty paragraphs and section breaks say nothing.
    private func flush(_ open: inout WordParagraph, into list: inout [WordParagraph]) {
        open.chapter = chapter
        open.note = currentNote
        if !open.runs.isEmpty { list.append(open) }
        open = WordParagraph()
    }

    private func flushEmptyOpen() {
        if openA.runs.isEmpty { openA = WordParagraph() }
        if openR.runs.isEmpty { openR = WordParagraph() }
    }

    private func utf16(_ p: WordParagraph) -> Int { p.runs.reduce(0) { $0 + $1.text.utf16.count } }

    private func run(_ r: XMLElement, state: State, author: String?) {
        let props = r.elements(forName: "w:rPr").first
        let format = props.map { Self.format(of: $0, styles: styles) } ?? []
        // A tracked change of format: refusing it gives back the old one.
        let old = props?.elements(forName: "w:rPrChange").first?.elements(forName: "w:rPr").first.map { Self.format(of: $0, styles: styles) } ?? format
        func add(_ text: String, note: String? = nil) {
            guard !text.isEmpty else { return }
            if state != .deleted { append(WordRun(text: text, format: format, note: note), to: &openA) }
            if state != .inserted { append(WordRun(text: text, format: old, note: note), to: &openR) }
        }
        for child in r.children ?? [] {
            guard let e = child as? XMLElement else { continue }
            switch e.name {
            case "w:t", "w:delText": add((e.stringValue ?? "").replacingOccurrences(of: DocxContent.protectedSpace, with: " "))
            case "w:tab": add("\t")
            case "w:br", "w:cr":
                if e.attribute(forName: "w:type")?.stringValue != "page" { add(String(ParagraphCodec.lineBreak)) }
            case "w:noBreakHyphen": add("\u{2011}")
            case "w:footnoteReference":
                if let id = e.attribute(forName: "w:id")?.stringValue {
                    noteOrder.append(id)
                    add(WordRun.noteMark, note: id)
                }
            default: break
            }
        }
    }

    /// Word cuts its text into runs at will: runs of one format are one stretch.
    private func append(_ run: WordRun, to paragraph: inout WordParagraph) {
        if run.note == nil, let last = paragraph.runs.last, last.format == run.format, last.note == nil {
            paragraph.runs[paragraph.runs.count - 1].text += run.text
        } else {
            paragraph.runs.append(run)
        }
    }

    func finishedComments() -> [WordComment] {
        comments.values.compactMap { c -> WordComment? in
            var c = c
            guard let start = starts[c.id] else {
                // Without a range (some editors), on the paragraph the reference was left in: nothing to quote.
                return c.body.isEmpty ? nil : c
            }
            let end = ends[c.id] ?? start
            c.paragraph = start.paragraph
            c.quote = slice(from: start, to: end)
            let here = rejected[safe: start.paragraph]?.text ?? ""
            let units = Array(here.utf16)
            c.before = String(decoding: units[max(0, start.offset - 60)..<min(units.count, start.offset)], as: UTF16.self)
            if end.paragraph == start.paragraph, let tail = rejected[safe: end.paragraph]?.text {
                let t = Array(tail.utf16)
                c.after = String(decoding: t[min(t.count, end.offset)..<min(t.count, end.offset + 60)], as: UTF16.self)
            }
            return c
        }
        .sorted { (Int($0.id) ?? 0) < (Int($1.id) ?? 0) }
    }

    private func slice(from a: (paragraph: Int, offset: Int), to b: (paragraph: Int, offset: Int)) -> String {
        guard a.paragraph <= b.paragraph, a.paragraph < rejected.count else { return "" }
        var parts: [String] = []
        for i in a.paragraph...min(b.paragraph, rejected.count - 1) {
            let units = Array(rejected[i].text.utf16)
            let from = i == a.paragraph ? min(a.offset, units.count) : 0
            let to = i == b.paragraph ? min(b.offset, units.count) : units.count
            if from < to { parts.append(String(decoding: units[from..<to], as: UTF16.self)) }
        }
        return parts.joined(separator: "\n")
    }
}
