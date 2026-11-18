import Foundation

// Lists in a piece's text: which lines are items. The editor's styling and keys, the typography and the sources
// written for pandoc all ask here; the typesetter reads the same rule in Rust (`musset-typeset/src/markup.rs`).

/// The lists a book recognises (`BookManifest.textFeatures`).
struct ListOptions: Equatable, Hashable {
    var bullets = true
    var numbered = false

    static let none = ListOptions(bullets: false, numbered: false)
    var any: Bool { bullets || numbered }
}

extension BookManifest {
    /// The lists the author writes with: what the editor styles and its keys act on, and what the typography leaves
    /// alone. A novel has none unless its author asks: there, a hyphen that opens a line is a line of dialogue, and
    /// the typography makes it a dash, as it always did.
    var listOptions: ListOptions {
        let t = textFeatures
        let rich = structure.map { BookStructure.preset($0.form).richText } ?? false
        return ListOptions(bullets: structure?.text?.bulletLists ?? rich, numbered: t.numberedLists)
    }

    /// The lists a book's outputs read. A hyphen line left in the text has always printed as a bullet: it still
    /// does until the author switches bullet lists off.
    var printedListOptions: ListOptions {
        let t = textFeatures
        return ListOptions(bullets: t.bulletLists, numbered: t.numberedLists)
    }
}

enum ListLines {
    /// A line that reads as a list item.
    struct Item: Equatable {
        /// Where the line starts, and its white space before the marker.
        var line: Int
        var indent: Int
        /// 0, 1 or 2: two to five columns of white space nest once, six or more twice (a tab counts for four).
        var level: Int
        /// The marker: « - », « 12. ».
        var marker: NSRange
        /// Nil for a bullet.
        var number: Int?
        /// Where the item's text starts, after the marker's spaces.
        var text: Int
        /// The line is its marker and nothing more.
        var isEmpty: Bool

        /// « ) » or « . » after a number.
        func delimiter(in ns: NSString) -> String { number == nil ? "" : ns.substring(with: NSRange(location: NSMaxRange(marker) - 1, length: 1)) }
    }

    static let maxLevel = 2
    /// What Tab writes for one level: pandoc nests under « 1. » only from three columns on, four suit every marker.
    static let step = "    "

    static func level(columns: Int) -> Int { min(maxLevel, (columns + 2) / 4) }

    /// Where the line that holds `location` ends, its terminator left out.
    static func contentEnd(_ ns: NSString, line: NSRange) -> Int {
        var end = NSMaxRange(line)
        while end > line.location, let u = Unicode.Scalar(ns.character(at: end - 1)), CharacterSet.newlines.contains(u) { end -= 1 }
        return end
    }

    /// The line starting at `start`, if it is written as an item: an ASCII « - », « + » or « * », or one to three
    /// digits and « . » or « ) », then a space. A dialogue dash (« — », « – ») is never one, nor a scene break
    /// (`* * *`, `---`), nor « 1943. » (four digits: a year opens a sentence). Whether it *is* an item also
    /// depends on the book and on the lines before it: see `item`.
    static func candidate(_ ns: NSString, at start: Int) -> Item? {
        let line = ns.lineRange(for: NSRange(location: start, length: 0))
        let end = contentEnd(ns, line: line)
        var i = line.location, columns = 0
        while i < end, case let c = ns.character(at: i), c == 0x20 || c == 0x09 { columns += c == 0x09 ? 4 : 1; i += 1 }
        guard i < end else { return nil }
        let markerStart = i
        var number: Int?
        let c = ns.character(at: i)
        if c == 0x2D || c == 0x2B || c == 0x2A {
            i += 1
        } else if c >= 0x30, c <= 0x39 {
            var n = 0
            while i < end, case let d = ns.character(at: i), d >= 0x30, d <= 0x39 { n = n * 10 + Int(d - 0x30); i += 1 }
            guard i - markerStart <= 3, i < end, ns.character(at: i) == 0x2E || ns.character(at: i) == 0x29 else { return nil }
            i += 1
            number = n
        } else {
            return nil
        }
        let marker = NSRange(location: markerStart, length: i - markerStart)
        // The marker alone, at the end of the line, is an item being started only once its space is typed.
        guard i < end, ns.character(at: i) == 0x20 || ns.character(at: i) == 0x09 else { return nil }
        while i < end, case let s = ns.character(at: i), s == 0x20 || s == 0x09 { i += 1 }
        if number == nil {
            // A scene break: only `*`, `-`, `_` and spaces, three marks or more.
            var marks = 0, only = true
            for k in markerStart..<end {
                let u = ns.character(at: k)
                if u == 0x2A || u == 0x2D || u == 0x5F { marks += 1 } else if u != 0x20 && u != 0x09 { only = false; break }
            }
            if only, marks >= 3 { return nil }
            // « * * »: stars, not a list of one star.
            if c == 0x2A, i < end, ns.character(at: i) == 0x2A { return nil }
        }
        return Item(line: line.location, indent: markerStart - line.location, level: level(columns: columns), marker: marker,
                    number: number, text: i, isEmpty: i >= end)
    }

    /// The start of the line before `start` that holds something, nil at the top of the text.
    private static func lineBefore(_ ns: NSString, _ start: Int) -> Int? {
        var at = start
        while at > 0 {
            let line = ns.lineRange(for: NSRange(location: at - 1, length: 0))
            if ns.substring(with: line).contains(where: { !$0.isWhitespace }) { return line.location }
            at = line.location
        }
        return nil
    }

    /// The item on the line starting at `start`, as the book reads it. A bullet is one whenever the book has bullet
    /// lists. A numbered line is one only in a book with numbered lists, and only when it starts a list at 1 or
    /// follows another item (blank lines aside): « 36. Guerre. » alone stays a sentence, and so does everything
    /// after it. `known`: a line start already found to be an item, to stop the walk back there.
    static func item(_ ns: NSString, at start: Int, _ options: ListOptions, known: Int? = nil) -> Item? {
        guard options.any, let found = candidate(ns, at: start) else { return nil }
        guard found.number != nil else { return options.bullets ? found : nil }
        guard options.numbered else { return nil }
        var at = found
        while true {
            if at.number == nil { return options.bullets ? found : nil }
            if at.number == 1 || at.line == known { return found }
            guard let before = lineBefore(ns, at.line), let previous = candidate(ns, at: before) else { return nil }
            at = previous
        }
    }

    // MARK: For pandoc

    /// A piece's Markdown as pandoc must read it (Word, EPUB) to make the lists the book has and no other: the
    /// items of a list on consecutive lines, nested by four columns, apart from the text around them; a line that
    /// only looks like an item (« 36. Guerre. », a dash when the book has no bullet lists) escaped, as the
    /// typesetter escapes it. Read with `markdown-fancy_lists`: « a. » and « (1) » open nothing.
    static func forPandoc(_ text: String, _ options: ListOptions) -> String {
        // Most texts have no such line: nothing to rewrite.
        guard text.range(of: #"(?m)^[ \t]*(?:[-+*]|\d+[.)])[ \t]"#, options: .regularExpression) != nil else { return text }
        var out: [String] = []
        var inList = false, previousLevel = 0, blanks = 0
        for line in text.components(separatedBy: "\n") {
            let ns = line as NSString
            if !line.contains(where: { !$0.isWhitespace }) { blanks += 1; continue }
            var found = candidate(ns, at: 0).flatMap { $0.isEmpty ? nil : $0 }
            if let c = found {
                if c.number == nil { if !options.bullets { found = nil } }
                else if !options.numbered || !(c.number == 1 || inList) { found = nil }
            }
            if let c = found {
                let level = min(c.level, inList ? previousLevel + 1 : 0)
                // The list apart from the text before it, its items together.
                if !inList, !out.isEmpty { out.append("") }
                let marker = c.number.map { "\($0)." } ?? "-"
                out.append(String(repeating: step, count: level) + marker + " " + ns.substring(from: c.text))
                inList = true
                previousLevel = level
            } else {
                if !out.isEmpty { out += Array(repeating: "", count: inList ? max(1, blanks) : blanks) }
                else { out += Array(repeating: "", count: blanks) }
                out.append(escaped(line))
                inList = false
            }
            blanks = 0
        }
        out += Array(repeating: "", count: blanks)
        return out.joined(separator: "\n")
    }

    private static let looksListed = try! NSRegularExpression(pattern: #"^([ \t]*)(?:([-+*])|(\d+)([.)]))(?=[ \t])"#)

    /// A line that is not an item, kept from reading as one: « \- », « 1943\. ».
    private static func escaped(_ line: String) -> String {
        let ns = line as NSString
        guard let m = looksListed.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return line }
        let rest = ns.substring(from: NSMaxRange(m.range))
        // A scene break keeps its marks.
        if m.range(at: 2).location != NSNotFound {
            if line.allSatisfy({ "*-_ \t".contains($0) }) { return line }
            return ns.substring(with: m.range(at: 1)) + "\\" + ns.substring(with: m.range(at: 2)) + rest
        }
        return ns.substring(with: m.range(at: 1)) + ns.substring(with: m.range(at: 3)) + "\\" + ns.substring(with: m.range(at: 4)) + rest
    }
}
