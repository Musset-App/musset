import CryptoKit
import Foundation

/// The text of a chapter as it reads on the page, with where each character comes from: what Word shows can be found
/// in the Markdown even when italics, footnote calls or typographic shortcuts stand in between.
struct FoldedText {
    let text: NSString
    private let starts: [Int]
    private let ends: [Int]
    let length: Int

    /// `inlineNotes`: read the inside of `^[…]` notes rather than skip it.
    init(_ source: String, inlineNotes: Bool = false) {
        let u = Array(source.utf16)
        var out: [UInt16] = []
        var starts: [Int] = [], ends: [Int] = []
        out.reserveCapacity(u.count); starts.reserveCapacity(u.count); ends.reserveCapacity(u.count)
        var i = 0
        var lineStart = true
        func code(_ c: Character) -> UInt16 { String(c).utf16.first! }
        func matches(_ s: String, at at: Int) -> Bool {
            let w = Array(s.utf16)
            return at + w.count <= u.count && Array(u[at..<at + w.count]) == w
        }
        func alnum(_ at: Int) -> Bool {
            guard at >= 0, at < u.count, let s = Unicode.Scalar(u[at]) else { return false }
            return CharacterSet.alphanumerics.contains(s)
        }
        func emit(_ value: UInt16, from: Int, to: Int) {
            if FoldedText.isSpace(value) {
                if let last = out.last, last == 32 { ends[ends.count - 1] = to; return }
                out.append(32)
            } else {
                out.append(FoldedText.foldUnit(value))
            }
            starts.append(from); ends.append(to)
        }
        func closing(_ open: Int, _ close: UInt16) -> Int? {
            var depth = 0, k = open
            while k < u.count {
                if u[k] == code("\\") { k += 2; continue }
                if u[k] == code("[") { depth += 1 }
                if u[k] == close { depth -= 1; if depth == 0 { return k } }
                if u[k] == 10 { return nil }
                k += 1
            }
            return nil
        }
        var hiddenCloses = Set<Int>()
        while i < u.count {
            let c = u[i]
            if hiddenCloses.contains(i) {
                // `](url)`, `]{.style}` or the end of a note: not on the page.
                var k = i + 1
                if k < u.count, u[k] == code("(") { while k < u.count, u[k] != code(")"), u[k] != 10 { k += 1 }; k += 1 }
                else if k < u.count, u[k] == code("{") { while k < u.count, u[k] != code("}"), u[k] != 10 { k += 1 }; k += 1 }
                i = k
                continue
            }
            if lineStart {
                lineStart = false
                var k = i
                while k < u.count, u[k] == code("#") { k += 1 }
                if k > i, k < u.count, u[k] == 32 { i = k + 1; continue }
                if c == code(">"), i + 1 < u.count, u[i + 1] == 32 { i += 2; continue }
                if c == code("-") || c == code("*"), i + 1 < u.count, u[i + 1] == 32 { i += 2; continue }
                if c == code("["), i + 1 < u.count, u[i + 1] == code("^"), let close = closing(i, code("]")), close + 1 < u.count, u[close + 1] == code(":") {
                    i = close + 2
                    if i < u.count, u[i] == 32 { i += 1 }
                    continue
                }
            }
            if matches("<!--", at: i) {
                var k = i + 4
                while k < u.count, !matches("-->", at: k) { k += 1 }
                i = min(u.count, k + 3)
                continue
            }
            if c == 10 || c == 0x2028 { emit(32, from: i, to: i + 1); lineStart = c == 10; i += 1; continue }
            if c == code("\\"), i + 1 < u.count { emit(u[i + 1], from: i, to: i + 2); i += 2; continue }
            if c == code("*") { i += 1; continue }
            if c == code("_"), !(alnum(i - 1) && alnum(i + 1)) { i += 1; continue }
            if c == code("["), i + 1 < u.count, u[i + 1] == code("^"), let close = closing(i, code("]")) {
                emit(FoldedText.noteUnit, from: i, to: close + 1)
                i = close + 1
                continue
            }
            if c == code("^"), i + 1 < u.count, u[i + 1] == code("["), let close = closing(i + 1, code("]")) {
                if inlineNotes { hiddenCloses.insert(close); i += 2 }
                else { emit(FoldedText.noteUnit, from: i, to: close + 1); i = close + 1 }
                continue
            }
            if c == code("["), let close = closing(i, code("]")), close + 1 < u.count, u[close + 1] == code("(") || u[close + 1] == code("{") {
                hiddenCloses.insert(close)
                i += 1
                continue
            }
            if c == code("{"), i > 0, u[i - 1] == 32, let end = (i..<u.count).first(where: { u[$0] == code("}") || u[$0] == 10 }), u[end] == code("}"), end + 1 >= u.count || u[end + 1] == 10 {
                i = end + 1
                continue
            }
            if matches("&nbsp;", at: i) { emit(32, from: i, to: i + 6); i += 6; continue }
            if matches("...", at: i) { emit(code("…"), from: i, to: i + 3); i += 3; continue }
            if matches("---", at: i) { emit(code("—"), from: i, to: i + 3); i += 3; continue }
            if matches("--", at: i) { emit(code("–"), from: i, to: i + 2); i += 2; continue }
            emit(c, from: i, to: i + 1)
            i += 1
        }
        text = String(decoding: out, as: UTF16.self) as NSString
        self.starts = starts
        self.ends = ends
        length = out.count
    }

    static let noteUnit: UInt16 = 0xFFFC

    private static func isSpace(_ c: UInt16) -> Bool {
        c == 32 || c == 9 || c == 10 || c == 0xA0 || c == 0x202F || c == 0x2009 || c == 0x2028
    }

    private static func foldUnit(_ c: UInt16) -> UInt16 {
        switch c {
        case 0x2019, 0x2018: return 39
        case 0x201C, 0x201D: return 34
        default: return c
        }
    }

    /// What Word shows, folded the same way.
    static func plain(_ s: String) -> String {
        var out: [UInt16] = []
        for c in s.utf16 {
            if isSpace(c) { if out.last != 32 { out.append(32) } }
            else { out.append(foldUnit(c)) }
        }
        return String(decoding: out, as: UTF16.self)
    }

    /// The source range of a found stretch.
    func sourceRange(foldedLocation: Int, length: Int) -> NSRange {
        if length == 0 { return NSRange(location: insertionPoint(foldedLocation), length: 0) }
        let start = starts[foldedLocation], end = ends[foldedLocation + length - 1]
        return NSRange(location: start, length: end - start)
    }

    func insertionPoint(_ folded: Int) -> Int {
        if folded > 0, folded - 1 < ends.count { return ends[folded - 1] }
        return starts.first ?? 0
    }

    /// The first place the words stand from `cursor` on, else anywhere if they stand only once.
    func find(_ needle: String, from cursor: Int) -> Int? {
        guard !needle.isEmpty, length > 0 else { return nil }
        let after = text.range(of: needle, options: .literal, range: NSRange(location: min(cursor, length), length: length - min(cursor, length)))
        if after.location != NSNotFound { return after.location }
        let first = text.range(of: needle, options: .literal)
        guard first.location != NSNotFound else { return nil }
        let end = NSMaxRange(first)
        let again = text.range(of: needle, options: .literal, range: NSRange(location: end, length: length - end))
        return again.location == NSNotFound ? first.location : nil
    }
}

/// A corrected Word file against what was sent: its changes, word by word, placed on the author's text as it is today.
enum WordReview {
    struct Token: Equatable {
        var text: String
        var format: WordRun.Format = []
        var note: String? = nil
        static func == (a: Token, b: Token) -> Bool { a.text == b.text && a.format == b.format }
        static let paragraph = Token(text: "\n")
    }

    struct Hunk: Equatable {
        /// The chapter of the paragraph it falls in, when known.
        var chapter: String?
        var isNote = false
        var before = ""
        var old: [Token] = []
        var new: [Token] = []
        var after = ""
        /// The format of the words on both sides: what new words there inherit.
        var ambient: WordRun.Format = []
        var previousFormat: WordRun.Format = []

        var oldText: String { old.map(\.text).joined() }
        var newPlain: String { new.map { $0.text == WordRun.noteMark ? "" : $0.text }.joined() }
    }

    /// Word's text, cut into words, spaces and signs. An apostrophe stays inside its word.
    static func tokens(_ paragraph: WordParagraph) -> [Token] {
        var out: [Token] = []
        for run in paragraph.runs {
            if run.note != nil { out.append(Token(text: WordRun.noteMark, format: [], note: run.note)); continue }
            var word = ""
            func flush() { if !word.isEmpty { out.append(Token(text: word, format: run.format)); word = "" } }
            for c in run.text {
                if c.isLetter || c.isNumber || c == "’" || c == "'" { word.append(c) }
                else { flush(); out.append(Token(text: String(c), format: run.format)) }
            }
            flush()
        }
        return out
    }

    private static func key(_ p: WordParagraph) -> String {
        p.runs.map { "\($0.format.rawValue)|\($0.note != nil ? WordRun.noteMark : $0.text)" }.joined(separator: "\u{1}")
    }

    /// Where each sent paragraph stands in the corrected file: pairs of stretches that differ.
    static func gaps(_ x: [String], _ a: [String]) -> [(x: Range<Int>, a: Range<Int>)] {
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in a.difference(from: x) {
            switch change {
            case .remove(let o, _, _): removed.insert(o)
            case .insert(let o, _, _): inserted.insert(o)
            }
        }
        var out: [(x: Range<Int>, a: Range<Int>)] = []
        var i = 0, j = 0
        while i < x.count || j < a.count {
            if removed.contains(i) || inserted.contains(j) {
                let si = i, sj = j
                while removed.contains(i) || inserted.contains(j) {
                    if removed.contains(i) { i += 1 }
                    if inserted.contains(j) { j += 1 }
                }
                out.append((si..<i, sj..<j))
            } else {
                i += 1; j += 1
            }
        }
        return out
    }

    /// Every change between two lists of paragraphs.
    static func hunks(sent x: [WordParagraph], corrected a: [WordParagraph], isNote: Bool = false) -> [Hunk] {
        var out: [Hunk] = []
        let contextLength = 60
        for gap in gaps(x.map(key), a.map(key)) {
            var from: [Token] = [], to: [Token] = []
            var owners: [Int] = []
            for i in gap.x { let t = tokens(x[i]) + [Token.paragraph]; from += t; owners += Array(repeating: i, count: t.count) }
            for j in gap.a { to += tokens(a[j]) + [Token.paragraph] }
            let previous = gap.x.lowerBound > 0 ? tokens(x[gap.x.lowerBound - 1]) + [Token.paragraph] : []
            let next = gap.x.upperBound < x.count ? tokens(x[gap.x.upperBound]) : []
            let prevChapter = gap.x.lowerBound > 0 ? x[gap.x.lowerBound - 1].chapter : nil
            let nextChapter = gap.x.upperBound < x.count ? x[gap.x.upperBound].chapter : nil
            func chapter(at index: Int) -> String? {
                if index < owners.count { return x[owners[index]].chapter }
                return owners.last.map { x[$0].chapter } ?? prevChapter ?? nextChapter
            }
            for s in stretches(from, to) {
                let where_ = chapter(at: s.x.lowerBound)
                var beforeTokens = Array(from[0..<s.x.lowerBound])
                if where_ == prevChapter || where_ == nil { beforeTokens = previous + beforeTokens }
                var afterTokens = Array(from[s.x.upperBound...])
                if where_ == nextChapter || where_ == nil { afterTokens += next }
                var h = Hunk(chapter: where_, isNote: isNote)
                h.before = String(beforeTokens.map(\.text).joined().suffix(contextLength))
                h.after = String(afterTokens.map(\.text).joined().prefix(contextLength))
                h.old = Array(from[s.x])
                h.new = Array(to[s.a])
                let left = beforeTokens.last { !$0.text.allSatisfy(\.isWhitespace) }?.format ?? []
                let right = afterTokens.first { !$0.text.allSatisfy(\.isWhitespace) }?.format ?? []
                h.previousFormat = left
                h.ambient = left == right ? left : []
                // A paragraph added at the very end of a chapter: there is no next paragraph to come before.
                if h.oldText.isEmpty, h.new.last == Token.paragraph, h.after.isEmpty {
                    h.new = [Token.paragraph] + h.new.dropLast()
                    while h.before.last?.isNewline == true { h.before.removeLast() }
                }
                out.append(h)
            }
        }
        return out
    }

    /// The token stretches that differ. Two changes one space apart read as one.
    private static func stretches(_ x: [Token], _ a: [Token]) -> [(x: Range<Int>, a: Range<Int>)] {
        // Beyond this, a word-by-word comparison says nothing more than « rewritten ».
        guard x.count * a.count < 400_000_000 else { return [(0..<x.count, 0..<a.count)] }
        var out = gaps(x.map { "\($0.format.rawValue)|\($0.text)" }, a.map { "\($0.format.rawValue)|\($0.text)" })
        var i = 0
        while i + 1 < out.count {
            let first = out[i], second = out[i + 1]
            let between = first.x.upperBound..<second.x.lowerBound
            if between.count == 1, x[between.lowerBound].text == " ", !first.x.isEmpty || !first.a.isEmpty, !(first.x.isEmpty && second.x.isEmpty) {
                out[i] = (first.x.lowerBound..<second.x.upperBound, first.a.lowerBound..<second.a.upperBound)
                out.remove(at: i + 1)
            } else {
                i += 1
            }
        }
        return out
    }

    // MARK: Markdown

    private static func wrap(_ text: String, _ format: WordRun.Format) -> String {
        let core = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !format.isEmpty, !core.isEmpty, let r = text.range(of: core) else { return text }
        var open = ""
        if format.contains(.bold) { open += "**" }
        if format.contains(.italic) { open += "*" }
        let close = String(open.reversed())
        var inner = open + core + close
        if format.contains(.sup) { inner = "^" + inner + "^" }
        if format.contains(.sub) { inner = "~" + inner + "~" }
        return String(text[..<r.lowerBound]) + inner + String(text[r.upperBound...])
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "*", with: "\\*")
    }

    /// The new words as Markdown. Nil when they can't be written here (roman inside an italic passage).
    static func markdown(_ tokens: [Token], inheriting inherit: WordRun.Format, notes: [String: String]) -> String? {
        var out = ""
        var run = ""
        var runFormat: WordRun.Format = []
        func flush() { out += wrap(run, runFormat); run = "" }
        for t in tokens {
            if t.text == WordRun.noteMark {
                flush()
                out += "^[\(notes[t.note ?? ""] ?? "")]"
                continue
            }
            let blank = t.text.allSatisfy(\.isWhitespace)
            if !blank, !inherit.isSubset(of: t.format) { return nil }
            let format = blank ? runFormat : t.format.subtracting(inherit)
            if format != runFormat { flush(); runFormat = format }
            run += escape(t.text)
        }
        flush()
        return out
    }

    // MARK: Placing

    /// Stands where the sender's name will go: they are named after the file has been read.
    static let senderSlot = "{@\u{E000}}"

    struct Placed {
        var text: String
        var placed = 0
        var alreadyThere = 0
        var unplaced: [String] = []
    }

    private static func uniformFormat(_ tokens: [Token]) -> WordRun.Format? {
        let words = tokens.filter { !$0.text.allSatisfy(\.isWhitespace) }
        guard let first = words.first?.format, words.allSatisfy({ $0.format == first }) else { return nil }
        return first
    }

    static func describe(_ h: Hunk) -> String {
        let old = h.oldText.trimmingCharacters(in: .whitespacesAndNewlines), new = h.newPlain.trimmingCharacters(in: .whitespacesAndNewlines)
        if old.isEmpty { return L("adds « \(new) »") }
        if new.isEmpty { return L("removes « \(old) »") }
        return "« \(old) » → « \(new) »"
    }

    /// Finds a change's place in `folded`: with its context, then with less of it.
    private static func locate(_ h: Hunk, in folded: FoldedText, cursor: Int) -> (location: Int, length: Int)? {
        let old = h.oldText
        for size in [60, 24] {
            let before = String(h.before.suffix(size)), after = String(h.after.prefix(size))
            for (b, a) in [(before, after), (before, ""), ("", after)] where !(b.isEmpty && a.isEmpty) {
                let prefix = FoldedText.plain(b)
                let whole = FoldedText.plain(b + old + a)
                var withOld = FoldedText.plain(b + old)
                if whole.hasSuffix(" "), a.isEmpty, !old.isEmpty, whole.utf16.count > 1 {
                    // A change running to the end of a paragraph, at the end of the text: no trailing space there.
                    if folded.find(whole, from: cursor) == nil { withOld = String(withOld.dropLast()) }
                }
                let needle = a.isEmpty ? withOld : whole
                guard needle.utf16.count >= 3, let at = folded.find(needle, from: cursor) else { continue }
                let start = at + prefix.utf16.count
                return (start, max(0, withOld.utf16.count - prefix.utf16.count))
            }
        }
        // The words alone, if they are long enough to mean something and stand once.
        let bare = FoldedText.plain(old).trimmingCharacters(in: .whitespaces)
        if bare.count >= 8, let at = folded.find(bare, from: 0), folded.find(bare, from: at + 1) == nil || folded.find(bare, from: at + 1) == at { return (at, bare.utf16.count) }
        return nil
    }

    private static func alreadyDone(_ h: Hunk, in folded: FoldedText) -> Bool {
        let new = h.newPlain
        // The same words: only their format or their kind of space changes, and that doesn't show in the folded text.
        guard FoldedText.plain(h.oldText) != FoldedText.plain(new) else { return false }
        let needle = FoldedText.plain(String(h.before.suffix(24)) + new + String(h.after.prefix(24)))
        guard needle.utf16.count >= 6 else { return false }
        return folded.text.range(of: needle, options: .literal).location != NSNotFound
    }

    /// Places changes on a chapter's current text as corrections. What the author has since rewritten comes back apart.
    static func place(_ hunks: [Hunk], on current: String, notes: [String: String]) -> Placed {
        let main = FoldedText(current)
        let inNotes = FoldedText(current, inlineNotes: true)
        let source = current as NSString
        let existing = Revisions.marks(in: current).map(\.range)
        // A change already there, decided or still waiting: read the text as if it were all accepted.
        let settled = existing.isEmpty ? main : FoldedText(Revisions.resolveAll(current, accept: true))
        let settledNotes = existing.isEmpty ? inNotes : FoldedText(Revisions.resolveAll(current, accept: true), inlineNotes: true)
        var edits: [(NSRange, String)] = []
        var result = Placed(text: current)
        var cursor = 0
        for h in hunks {
            let folded = h.isNote ? inNotes : main
            if alreadyDone(h, in: h.isNote ? settledNotes : settled) {
                result.alreadyThere += 1
                continue
            }
            guard let spot = locate(h, in: folded, cursor: h.isNote ? 0 : cursor) else {
                result.unplaced.append(describe(h))
                continue
            }
            var range = folded.sourceRange(foldedLocation: spot.location, length: spot.length)
            let oldFormat = uniformFormat(h.old)
            let newFormat = uniformFormat(h.new)
            // Same format on both sides: the new words sit in the old ones' place and inherit it.
            var inherit = h.ambient
            if let oldFormat, oldFormat == newFormat { inherit = oldFormat }
            else if let oldFormat, !oldFormat.isEmpty, h.ambient.isEmpty {
                // A format taken away or changed: its marks go with the old words.
                while range.location > 0, NSMaxRange(range) < source.length {
                    let l = source.character(at: range.location - 1), r = source.character(at: NSMaxRange(range))
                    guard l == r, l == 42 || l == 95 else { break }
                    range = NSRange(location: range.location - 1, length: range.length + 2)
                }
            }
            // A plain word typed right after an italic passage goes outside its closing mark.
            if range.length == 0, h.previousFormat != inherit {
                while range.location < source.length, source.character(at: range.location) == 42 || source.character(at: range.location) == 95 {
                    range.location += 1
                }
            }
            guard let new = markdown(h.new, inheriting: inherit, notes: notes),
                  !existing.contains(where: { NSIntersectionRange($0, range).length > 0 || ($0.location < range.location && range.location < NSMaxRange($0)) }),
                  !edits.contains(where: { NSIntersectionRange($0.0, range).length > 0 || ($0.0.location == range.location && range.length == 0 && $0.0.length == 0) }) else {
                result.unplaced.append(describe(h))
                continue
            }
            let old = source.substring(with: range)
            let mark = (old.isEmpty ? "{++\(new)++}" : new.isEmpty ? "{--\(old)--}" : "{~~\(old)~>\(new)~~}") + senderSlot
            edits.append((range, mark))
            if !h.isNote { cursor = spot.location + spot.length }
        }
        let out = NSMutableString(string: current)
        for (r, mark) in edits.sorted(by: { $0.0.location > $1.0.location }) { out.replaceCharacters(in: r, with: mark) }
        result.text = out as String
        result.placed = edits.count
        return result
    }

    // MARK: The whole file

    struct ChapterPlan: Identifiable {
        var id: String
        var title: String
        var text: String
        var placed = 0
        var alreadyThere = 0
        var unplaced: [String] = []
        var notes: [(reader: String, note: Note)] = []
    }

    struct Plan {
        var fileName: String
        var hash: String
        var sent: WordManuscript.Sent?
        var readers: [String: DocxContent.Tally]
        var chapters: [ChapterPlan]
        /// Comments and changes that touch no chapter (title page…).
        var bookNotes: [(reader: String, note: Note)] = []
        var previousImport: Date?
        var changedSince: [String] = []

        var placed: Int { chapters.reduce(0) { $0 + $1.placed } }
        var unplaced: Int { chapters.reduce(0) { $0 + $1.unplaced.count } }
        var noteCount: Int { chapters.reduce(0) { $0 + $1.notes.count } + bookNotes.count }
        /// Who Word says did it, to start the sender's name from.
        var suggestedSender: String? {
            readers.max { ($0.value.insertions + $0.value.deletions) < ($1.value.insertions + $1.value.deletions) }?.key
                ?? (chapters.flatMap(\.notes) + bookNotes).first { !$0.reader.isEmpty }?.reader
                ?? lastModifiedBy
        }
        var lastModifiedBy: String? = nil
    }

    /// The export a file came from: by the mark it carries, else by what it most resembles.
    static func sent(for doc: DocxContent, among all: [WordManuscript.Sent]) -> WordManuscript.Sent? {
        if let id = doc.exportID, let found = all.first(where: { $0.id == id }) { return found }
        let keys = Set(doc.rejected.map(key))
        guard !keys.isEmpty else { return nil }
        let scored = all.map { s in (s, s.main.filter { keys.contains(key($0)) }.count * 100 / max(1, s.main.count)) }
        return scored.filter { $0.1 >= 60 }.max { ($0.1, $0.0.date) < ($1.1, $1.0.date) }?.0
    }

    static func noteID(_ c: WordComment) -> UUID {
        let digest = SHA256.hash(data: Data("\(c.author)|\(c.date?.timeIntervalSince1970 ?? 0)|\(c.body)|\(c.quote)".utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// Reads a comment's thread into a note, on its passage in the chapter's current text.
    private static func note(for c: WordComment, replies: [WordComment], current: String?, version: String?) -> Note {
        var anchor = NoteAnchor(quote: c.quote, prefix: "", suffix: "", start: 0, version: version)
        var orphaned = !c.quote.isEmpty
        if let current {
            let folded = FoldedText(current)
            var probe = Hunk()
            probe.before = c.before
            probe.after = c.after
            probe.old = [Token(text: c.quote)]
            if !c.quote.isEmpty, let spot = locate(probe, in: folded, cursor: 0) {
                anchor = Anchoring.capture(folded.sourceRange(foldedLocation: spot.location, length: spot.length), in: current as NSString, version: version)
                orphaned = false
            }
        }
        let trimmed = c.body.trimmingCharacters(in: .whitespacesAndNewlines)
        var n = Note(id: noteID(c), author: .me, kind: trimmed.hasSuffix("?") ? .question : .note, body: c.body, anchor: anchor)
        n.created = c.date ?? Date()
        n.updated = n.created
        n.orphaned = orphaned
        n.status = c.done ? .resolved : .open
        n.replies = replies.map { Note.Reply(author: .me, body: "**\($0.author)** : \($0.body)", created: $0.date ?? Date()) }
        return n
    }

    /// Everything the file would bring. Nothing is written here.
    static func plan(doc: DocxContent, fileName: String, hash: String, sent: WordManuscript.Sent?, chapters: [(id: String, title: String, version: String, text: String)],
                     previousImport: Date?) -> Plan {
        let baseMain = sent?.main ?? doc.rejected
        let baseNotes = sent?.notes ?? doc.rejectedNotes
        // A footnote the corrector added is written at its call; it is not looked for among the existing ones.
        var noteBodies: [String: String] = [:]
        for p in doc.acceptedNotes { if let id = p.note { noteBodies[id, default: ""] += (noteBodies[id] == nil ? "" : " ") + p.text } }
        let mainHunks = hunks(sent: baseMain, corrected: doc.accepted)
        let newCalls = Set(mainHunks.flatMap { $0.new.compactMap(\.note) })
        let goneCalls = mainHunks.flatMap(\.old).filter { $0.text == WordRun.noteMark }.count
        var acceptedNotes = doc.acceptedNotes.filter { !newCalls.contains($0.note ?? "") }
        if goneCalls > 0, acceptedNotes.count > baseNotes.count { acceptedNotes = Array(acceptedNotes.prefix(baseNotes.count)) }
        let all = mainHunks + hunks(sent: baseNotes, corrected: acceptedNotes, isNote: true)

        var byChapter: [String: [Hunk]] = [:]
        var loose: [Hunk] = []
        let known = Set(chapters.map(\.id))
        for h in all {
            if let c = h.chapter, known.contains(c) { byChapter[c, default: []].append(h) } else { loose.append(h) }
        }
        // Without a known chapter (a file Musset didn't mark): wherever the words stand.
        var unplacedLoose: [Hunk] = []
        for h in loose {
            let probe = chapters.first { c in locate(h, in: FoldedText(c.text), cursor: 0) != nil }
            if h.chapter == nil, let probe { byChapter[probe.id, default: []].append(h) } else { unplacedLoose.append(h) }
        }

        var out: [ChapterPlan] = []
        for c in chapters {
            let placed = place(byChapter[c.id] ?? [], on: c.text, notes: noteBodies)
            out.append(ChapterPlan(id: c.id, title: c.title, text: placed.text, placed: placed.placed, alreadyThere: placed.alreadyThere, unplaced: placed.unplaced))
        }

        // Comments: on their passage, in the chapter of their paragraph.
        let rejectedKeys = doc.rejected.map(key)
        let baseIndex = Dictionary(baseMain.enumerated().map { (key($0.element), $0.offset) }, uniquingKeysWith: { a, _ in a })
        func chapter(of comment: WordComment) -> String? {
            var i = min(comment.paragraph, rejectedKeys.count - 1)
            while i >= 0 {
                if let at = baseIndex[rejectedKeys[i]], let c = baseMain[at].chapter { return c }
                i -= 1
            }
            return nil
        }
        var bookNotes: [(reader: String, note: Note)] = []
        let replies = Dictionary(grouping: doc.comments.filter { $0.parent != nil }, by: { $0.parent! })
        for c in doc.comments where c.parent == nil {
            let thread = replies[c.id] ?? []
            var target = chapter(of: c).flatMap { id in chapters.firstIndex { $0.id == id } }
            if target == nil, !c.quote.isEmpty {
                target = chapters.firstIndex { ch in FoldedText(ch.text).find(FoldedText.plain(c.quote), from: 0) != nil }
            }
            if let target {
                out[target].notes.append((c.author, note(for: c, replies: thread, current: chapters[target].text, version: chapters[target].version)))
            } else {
                bookNotes.append((c.author, note(for: c, replies: thread, current: nil, version: nil)))
            }
        }
        for h in unplacedLoose {
            var n = Note(author: .me, kind: .note, body: describe(h), anchor: NoteAnchor(quote: "", prefix: "", suffix: "", start: 0, version: nil))
            n.id = UUID()
            bookNotes.append((doc.lastModifiedBy ?? "", n))
        }
        var changed: [String] = []
        if let sent {
            let base = Set(sent.main.compactMap(\.chapter))
            for c in chapters where base.contains(c.id) {
                let was = sent.main.filter { $0.chapter == c.id }.map { FoldedText.plain($0.text) }.joined(separator: " ")
                let now = FoldedText(Revisions.resolveAll(c.text, accept: false)).text as String
                if !normalized(now).contains(normalized(was)) { changed.append(c.id) }
            }
        }
        return Plan(fileName: fileName, hash: hash, sent: sent, readers: doc.tallies, chapters: out, bookNotes: bookNotes, previousImport: previousImport, changedSince: changed, lastModifiedBy: doc.lastModifiedBy)
    }

    private static func normalized(_ s: String) -> String {
        s.replacingOccurrences(of: WordRun.noteMark, with: "").components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }
}

/// Files already brought in, so the same one isn't placed twice unawares.
enum WordImports {
    struct Entry: Codable { var hash: String; var date: Date; var file: String; var source: String? = nil }

    private static func url(_ root: URL) -> URL { WordManuscript.directory(root).appendingPathComponent("imports.json") }

    static func load(_ root: URL) -> [Entry] {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return (try? Data(contentsOf: url(root))).flatMap { try? dec.decode([Entry].self, from: $0) } ?? []
    }

    static func record(_ entry: Entry, root: URL) throws {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try FileManager.default.createDirectory(at: WordManuscript.directory(root), withIntermediateDirectories: true)
        try enc.encode(load(root) + [entry]).write(to: url(root), options: .atomic)
    }
}
