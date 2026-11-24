import Foundation

/// The book's typographic conventions, applied without AI: spaces, quotes, apostrophes, dashes, ellipses,
/// italics for Latin locutions. Author's notes, code and links are never touched.
///
/// French follows the Imprimerie nationale with one deliberate choice: a regular non-breaking space (U+00A0)
/// before ; : ! ? and inside « », because the books' xelatex/polyglossia export turns it into the right thin
/// space, while a narrow one (U+202F) ends up doubled.
enum Typography {
    struct Edit: Equatable {
        let range: NSRange
        let replacement: String
    }

    static let nbsp = "\u{00A0}"

    /// Names whose punctuation is part of them: no space before it, whatever the language's rule.
    static let knownNames = ["Yahoo!", "Jeopardy!", "Wham!"]
    /// The same, taught by the author: the book's dictionary entries that end in such punctuation.
    nonisolated(unsafe) static var bookNames: [String] = []

    private static func keepNames(_ s: String) -> String {
        var out = s
        for name in knownNames + bookNames {
            guard let mark = name.last else { continue }
            let word = NSRegularExpression.escapedPattern(for: String(name.dropLast()))
            out = sub(out, #"(?<![\p{L}\p{N}])"# + word + #"[ \t\x{00A0}\x{202F}]*"# + NSRegularExpression.escapedPattern(for: String(mark)), NSRegularExpression.escapedTemplate(for: name))
        }
        return out
    }

    static func supports(_ lang: String) -> Bool {
        let l = lang.lowercased()
        return ["fr", "en", "de", "es", "it", "pt"].contains { l.hasPrefix($0) }
    }

    private static let authorNote = try! NSRegularExpression(pattern: "<!--.*?-->", options: [.dotMatchesLineSeparators])

    /// Paragraphs the rules may touch: not blank, not a scene break, not part of a multi-paragraph author's note.
    static func paragraphRanges(in text: String) -> [NSRange] {
        let ns = text as NSString
        let notes = ns.range(of: "<!--").location == NSNotFound ? [] : authorNote.matches(in: text, range: NSRange(location: 0, length: ns.length)).map(\.range)
        var out: [NSRange] = []
        var cursor = 0
        while cursor < ns.length {
            let r = ns.paragraphRange(for: NSRange(location: cursor, length: 0))
            cursor = NSMaxRange(r)
            let t = ns.substring(with: r).trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty || t.allSatisfy({ "*-_ ".contains($0) }) { continue }
            // A note spanning several paragraphs: leave every paragraph it touches alone.
            if notes.contains(where: { NSIntersectionRange($0, r).length > 0 && !(r.location <= $0.location && NSMaxRange($0) <= NSMaxRange(r)) }) { continue }
            out.append(r)
        }
        return out
    }

    /// The whole chapter as it should be typeset.
    static func correctedDocument(_ text: String, lang: String, lists: ListOptions = .none) -> (text: String, count: Int) {
        guard supports(lang) else { return (text, 0) }
        var out = text as NSString
        var count = 0
        for r in paragraphRanges(in: text).reversed() {
            let edits = self.edits(in: out.substring(with: r), lang: lang, lists: lists)
            guard !edits.isEmpty else { continue }
            count += edits.count
            out = out.replacingCharacters(in: r, with: corrected(out.substring(with: r), lang: lang, lists: lists)) as NSString
        }
        return (out as String, count)
    }

    /// The paragraph as it should be typeset. `lists`: the lists the book recognises; in a book with bullet lists,
    /// a « - » that opens an item is its marker and stays one, where it would otherwise become a dialogue dash.
    static func corrected(_ text: String, lang: String, lists: ListOptions = .none) -> String {
        let l = lang.lowercased()
        guard supports(l) else { return text }
        var (s, protected) = protect(text, lists: lists)
        let book = BookLanguage(code: l)
        switch book {
        case .frFR: s = french(s)
        case .enUS: s = english(s)
        default: s = rules(book)(s)
        }
        return restore(keepNames(s), protected)
    }

    /// Minimal edits turning `text` into its corrected form (character-level, so notes and the caret stay put).
    static func edits(in text: String, lang: String, lists: ListOptions = .none) -> [Edit] {
        let fixed = corrected(text, lang: lang, lists: lists)
        guard fixed != text else { return [] }
        return diff(Array((text as NSString).utf16Units), Array((fixed as NSString).utf16Units))
    }

    // MARK: Rules

    private static func french(_ input: String) -> String {
        var s = input
        s = apostrophes(s)
        s = pairQuotes(s, open: "«" + nbsp, close: nbsp + "»")
        s = sub(s, #"(?<!\.)\.\.\.(?!\.)"#, "…")
        // Dialogue at the start of a line: tiret cadratin. Incises inside a sentence: tiret demi-cadratin.
        s = sub(s, #"(?m)^[ \t]*(?:--?|–)[ \t]+"#, "— ")
        s = sub(s, #"(?<=\S)[ \t]+(?:--|-)[ \t]+(?=\S)"#, " – ")
        // Guillemets: non-breaking space inside.
        s = sub(s, #"«[ \t\x{00A0}\x{202F}]*"#, "«" + nbsp)
        s = sub(s, #"(?<=\S)[ \t\x{00A0}\x{202F}]*»"#, nbsp + "»")
        // High punctuation: non-breaking space before ; ! ? and before : (except in times like 12:30).
        s = sub(s, #"(?<=[^\s;:!?\x{00A0}\x{202F}(\[])[ \t\x{00A0}\x{202F}]*([;!?])(?!\[)"#, nbsp + "$1")
        s = sub(s, #"(?<=[^\s;:!?\x{00A0}\x{202F}(\[\d])[ \t\x{00A0}\x{202F}]*:"#, nbsp + ":")
        s = sub(s, #"(?<=\d)[ \t\x{00A0}\x{202F}]*:(?!\d)"#, nbsp + ":")
        s = sub(s, #"(?<=\d)[ \t]?%"#, nbsp + "%")
        s = sub(s, #"(?<=\S)[ \t]{2,}(?=\S)"#, " ")
        s = italicize(s, latinFR)
        return s
    }

    private static func english(_ input: String) -> String {
        var s = input
        s = apostrophes(s)
        s = pairQuotes(s, open: "“", close: "”")
        s = sub(s, #"(?<!\.)\.\.\.(?!\.)"#, "…")
        s = sub(s, #"(?<=\S)[ \t]*--[ \t]*(?=\S)"#, "—")
        s = sub(s, #"(?<=\p{L})[ \t]+-[ \t]+(?=\p{L})"#, "—")
        // No space before punctuation in English.
        s = sub(s, #"(?<=\S)[ \t\x{00A0}\x{202F}]+([;:!?])"#, "$1")
        s = sub(s, #"(?<=\S)[ \t]{2,}(?=\S)"#, " ")
        return s
    }

    /// The conventions of the other variants, as data: quotes, dialogue dash, incise dash, extras.
    struct Rules {
        var open: String, close: String
        /// Quotes inside quotes: "…" typed within the outer marks.
        var nestedOpen: String, nestedClose: String
        /// A dash typed at the start of a line (dialogue) becomes this.
        var dialogue: String
        /// A spaced hyphen or a double hyphen between words becomes this.
        var incise: String
        var latinItalics = false
        var extra: (String) -> String = { $0 }
    }

    static func rules(_ book: BookLanguage) -> (String) -> String {
        let r: Rules
        switch book {
        case .enGB:
            r = Rules(open: "‘", close: "’", nestedOpen: "“", nestedClose: "”", dialogue: "– ", incise: " – ")
        case .deDE:
            r = Rules(open: "„", close: "“", nestedOpen: "‚", nestedClose: "‘", dialogue: "– ", incise: " – ", extra: german)
        case .deCH:
            r = Rules(open: "«", close: "»", nestedOpen: "‹", nestedClose: "›", dialogue: "– ", incise: " – ",
                      extra: { german($0).replacingOccurrences(of: "ß", with: "ss") })
        case .esES:
            r = Rules(open: "«", close: "»", nestedOpen: "“", nestedClose: "”", dialogue: "—", incise: " —", latinItalics: true)
        case .es419:
            r = Rules(open: "“", close: "”", nestedOpen: "‘", nestedClose: "’", dialogue: "—", incise: " —", latinItalics: true)
        case .itIT:
            r = Rules(open: "«", close: "»", nestedOpen: "“", nestedClose: "”", dialogue: "— ", incise: " – ", latinItalics: true, extra: italian)
        case .ptPT:
            r = Rules(open: "«", close: "»", nestedOpen: "“", nestedClose: "”", dialogue: "— ", incise: " – ", latinItalics: true)
        case .ptBR:
            r = Rules(open: "“", close: "”", nestedOpen: "‘", nestedClose: "’", dialogue: "— ", incise: " – ", latinItalics: true)
        case .enUS, .frFR:
            return book == .frFR ? french : english
        }
        return { input in
            var s = apostrophes(input)
            s = quotes(s, r)
            s = sub(s, #"(?<!\.)\.\.\.(?!\.)"#, "…")
            s = sub(s, #"(?m)^([ \t]*)(?:--?|–|—)[ \t]*(?=\S)"#, "$1" + NSRegularExpression.escapedTemplate(for: r.dialogue))
            s = sub(s, #"(?<=\S)[ \t]*--[ \t]*(?=\S)"#, NSRegularExpression.escapedTemplate(for: r.incise))
            s = sub(s, #"(?<=\S)[ \t]+-[ \t]+(?=\S)"#, NSRegularExpression.escapedTemplate(for: r.incise))
            // No space before punctuation, none inside quotes.
            s = sub(s, #"(?<=\S)[ \t\x{00A0}\x{202F}]+([;:!?)])"#, "$1")
            s = sub(s, #"(?<=\S)[ \t]{2,}(?=\S)"#, " ")
            if r.latinItalics { s = italicize(s, latinFR) }
            return r.extra(s)
        }
    }

    /// Straight quotes to the variant's: outer marks, or nested ones when they fall inside outer marks already there.
    private static func quotes(_ s: String, _ r: Rules) -> String {
        guard s.contains("\"") else { return s }
        guard s.filter({ $0 == "\"" }).count % 2 == 0 else { return s }
        var out = "", opening = true, depth = 0
        for c in s {
            let ch = String(c)
            if ch == r.open && r.open != r.close { depth += 1 }
            if ch == r.close && r.open != r.close { depth = max(0, depth - 1) }
            guard c == "\"" else { out.append(c); continue }
            let nested = depth > 0
            if opening {
                out += nested ? r.nestedOpen : r.open
            } else {
                while out.last == " " { out.removeLast() }
                out += nested ? r.nestedClose : r.close
            }
            opening.toggle()
        }
        return out
    }

    /// z.B. → z. B. (narrow no-break space), the usual German abbreviations.
    private static func german(_ s: String) -> String {
        var out = s
        for a in ["z.B.", "d.h.", "u.a.", "u.U.", "z.T.", "v.a.", "o.Ä.", "u.Ä.", "i.d.R.", "s.o.", "s.u."] {
            let spaced = a.split(separator: ".").map { $0 + "." }.joined(separator: "\u{202F}")
            out = out.replacingOccurrences(of: a, with: spaced)
        }
        return out
    }

    /// E' at the start of a word → È; po' → po’.
    private static func italian(_ s: String) -> String {
        var out = sub(s, #"(?<![\p{L}’'])E['’](?=\s)"#, "È")
        out = sub(out, #"(?<=\b(?:po|mo|be|to|ve))'(?!\p{L})"#, "’")
        return out
    }

    /// l'homme → l’homme, aujourd'hui → aujourd’hui, don't → don’t.
    private static func apostrophes(_ s: String) -> String {
        sub(s, #"(?<=\p{L})'(?=\p{L})"#, "’")
    }

    /// "…" pairs → the language's quotes. An odd number of straight quotes is left alone (ambiguous).
    private static func pairQuotes(_ s: String, open: String, close: String) -> String {
        guard s.contains("\"") else { return s }
        let count = s.filter { $0 == "\"" }.count
        guard count % 2 == 0 else { return s }
        var out = ""
        var opening = true
        let chars = Array(s)
        for c in chars {
            guard c == "\"" else { out.append(c); continue }
            if opening {
                out += open
            } else {
                while let last = out.last, last == " " || last == "\u{00A0}" { out.removeLast() }
                out += close
            }
            opening.toggle()
        }
        // Remove the plain space that may follow an opening guillemet's non-breaking space.
        return out.replacingOccurrences(of: open + " ", with: open)
    }

    /// Latin locutions in italics (*in extremis*), unless already inside an emphasis.
    private static func italicize(_ s: String, _ words: [String]) -> String {
        let pattern = #"(?<![\p{L}*_])("# + words.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|") + #")(?![\p{L}*_])"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return s }
        let ns = s as NSString
        var out = s
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)).reversed() {
            let before = ns.substring(to: m.range.location)
            // Odd number of single asterisks before: we are inside *…*.
            let stars = before.replacingOccurrences(of: "**", with: "").filter { $0 == "*" }.count
            if stars % 2 == 1 { continue }
            let word = ns.substring(with: m.range)
            out = (out as NSString).replacingCharacters(in: m.range, with: "*\(word)*")
        }
        return out
    }

    static let latinFR = ["in extremis", "a priori", "a posteriori", "a fortiori", "de facto", "de jure", "ad hoc", "ad vitam aeternam",
                          "ex nihilo", "in vitro", "in vivo", "in situ", "sine qua non", "statu quo", "post mortem", "nec plus ultra",
                          "mea culpa", "vice versa", "ipso facto", "manu militari", "grosso modo", "honoris causa", "in memoriam",
                          "persona non grata", "modus operandi", "alter ego", "ex aequo", "urbi et orbi", "intra-muros", "extra-muros"]

    // MARK: Protected zones (notes, code, links)

    private static let protectRegex = try! NSRegularExpression(
        pattern: #"<!--.*?-->|`[^`\n]*`|\]\([^)\n]*\)|<https?://[^>\s]+>|https?://\S+|\{[^}\n]*\}|(?m:^[ \t]*(?:[-*_][ \t]*){3,}$)"#,
        options: [.dotMatchesLineSeparators])

    /// Swaps protected spans for private-use placeholders so no rule can touch them.
    private static func protect(_ s: String, lists: ListOptions) -> (String, [String]) {
        let ns = s as NSString
        var kept: [String] = []
        var out = s
        var spans = protectRegex.matches(in: s, range: NSRange(location: 0, length: ns.length)).map(\.range)
        // A bullet's marker, with the white space around it: the start of each line that is an item.
        if lists.bullets, ns.length > 1 {
            var at = 0
            while at < ns.length {
                let line = ns.lineRange(for: NSRange(location: at, length: 0))
                at = NSMaxRange(line)
                guard let item = ListLines.candidate(ns, at: line.location), item.number == nil else { continue }
                // A line of dialogue typed with a hyphen is not an item: it gets its dash.
                if lists.dialogue, ListLines.readsAsDialogue(ns, item) { continue }
                let r = NSRange(location: line.location, length: item.text - line.location)
                if !spans.contains(where: { NSIntersectionRange($0, r).length > 0 }) { spans.append(r) }
            }
            spans.sort { $0.location < $1.location }
        }
        for r in spans.reversed() {
            kept.insert(ns.substring(with: r), at: 0)
            out = (out as NSString).replacingCharacters(in: r, with: "\u{E000}")
        }
        return (out, kept)
    }

    private static func restore(_ s: String, _ kept: [String]) -> String {
        var out = ""
        var i = 0
        for c in s {
            if c == "\u{E000}", i < kept.count { out += kept[i]; i += 1 } else { out.append(c) }
        }
        return out
    }

    private static func sub(_ s: String, _ pattern: String, _ template: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        return re.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: template)
    }

    // MARK: Minimal edits

    /// Groups a UTF-16 difference into replacements on the original text.
    private static func diff(_ a: [unichar], _ b: [unichar]) -> [Edit] {
        Diff.gaps(a, b).map { gap in
            Edit(range: NSRange(location: gap.old.lowerBound, length: gap.old.count), replacement: String(utf16CodeUnits: Array(b[gap.new]), count: gap.new.count))
        }
    }

    // MARK: Cache key

    /// The paragraph with typography folded away, so typographic fixes never invalidate proofreading results.
    static func key(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for (from, to) in [("’", "'"), ("‘", "'"), ("ʼ", "'"), ("“", "\""), ("”", "\""), ("„", "\""), ("‚", "'"), ("«", "\""), ("»", "\""), ("‹", "\""), ("›", "\""), ("…", "..."),
                           ("—", "-"), ("–", "-"), ("*", ""), ("\u{00A0}", " "), ("\u{202F}", " ")] {
            s = s.replacingOccurrences(of: from, with: to)
        }
        s = sub(s, #"\s+"#, " ")
        s = sub(s, #" ?([;:!?%\"]) ?"#, "$1")
        s = sub(s, #" ?- ?"#, "-")
        s = sub(s, #"-+"#, "-")
        return s
    }
}

private extension NSString {
    var utf16Units: [unichar] {
        var buf = [unichar](repeating: 0, count: length)
        getCharacters(&buf, range: NSRange(location: 0, length: length))
        return buf
    }
}
