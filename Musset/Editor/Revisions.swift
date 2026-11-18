import Foundation

/// Editor's corrections in the text, as CriticMarkup: {++added++}, {--deleted--}, {~~old~>new~~},
/// {==highlighted==}{>>comment<<} and {>>comment<<}. Plain text, readable anywhere and tracked by git;
/// each mark is accepted or rejected, and the printed book never shows a pending one.
enum Revisions {
    enum Kind: Equatable { case insertion, deletion, substitution, highlight, comment }

    struct Mark: Equatable {
        let kind: Kind
        /// The whole mark, syntax included.
        let range: NSRange
        /// Inserted, deleted or highlighted text; the old text of a substitution.
        let first: NSRange
        /// The new text of a substitution, or the comment (of a highlight, or alone).
        let second: NSRange?
        /// Who it comes from, written right after the mark: `{~~old~>new~~}{@Jean}`.
        var source: NSRange? = nil
    }

    /// A pending change as the Notes list shows it.
    struct Pending: Identifiable, Equatable {
        var chapter: String
        var location: Int
        var kind: Kind
        var old: String
        var new: String
        var source: String?
        var id: String { "\(chapter):\(location):\(old.hashValue):\(new.hashValue)" }
    }

    static func sourceName(_ m: Mark, in text: String) -> String? {
        m.source.map { (text as NSString).substring(with: $0) }
    }

    /// The name as it can stand in a mark.
    static func sourceTag(_ name: String) -> String {
        let clean = name.components(separatedBy: CharacterSet(charactersIn: "{}\n")).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return clean.isEmpty ? "" : "{@\(clean)}"
    }

    /// The additions, deletions and replacements waiting for a decision.
    static func pending(in text: String, chapter: String) -> [Pending] {
        let ns = text as NSString
        return marks(in: text).compactMap { m in
            switch m.kind {
            case .insertion: Pending(chapter: chapter, location: m.range.location, kind: m.kind, old: "", new: ns.substring(with: m.first), source: sourceName(m, in: text))
            case .deletion: Pending(chapter: chapter, location: m.range.location, kind: m.kind, old: ns.substring(with: m.first), new: "", source: sourceName(m, in: text))
            case .substitution: Pending(chapter: chapter, location: m.range.location, kind: m.kind, old: ns.substring(with: m.first), new: m.second.map { ns.substring(with: $0) } ?? "", source: sourceName(m, in: text))
            case .highlight, .comment: nil
            }
        }
    }

    /// The text with the marks that `matching` picks decided, the others left waiting.
    static func resolve(_ text: String, accept: Bool, matching: (Mark) -> Bool) -> String {
        let out = NSMutableString(string: text)
        for m in marks(in: text).reversed() where matching(m) { out.replaceCharacters(in: m.range, with: resolved(m, in: text, accept: accept)) }
        return out as String
    }

    /// A mark may cross paragraphs: a paragraph an editor removed, split or joined.
    private static let pattern = try! NSRegularExpression(pattern:
        #"(?:\{\+\+(.*?)\+\+\}|\{--(.*?)--\}|\{~~(.*?)~>(.*?)~~\}|\{==(.*?)==\}(?:\{>>(.*?)<<\})?|\{>>(.*?)<<\})(?:\{@([^}\n]*)\})?"#, options: [.dotMatchesLineSeparators])

    static func marks(in text: String) -> [Mark] {
        // Every mark opens with a brace: most chapters have none, and are not searched.
        guard (text as NSString).range(of: "{").location != NSNotFound else { return [] }
        return marks(in: text, range: NSRange(location: 0, length: (text as NSString).length))
    }

    /// The marks inside `range` (whole paragraphs that no mark runs out of).
    static func marks(in text: String, range: NSRange) -> [Mark] {
        pattern.matches(in: text, range: range).compactMap { m in
            func g(_ i: Int) -> NSRange? { m.range(at: i).location == NSNotFound ? nil : m.range(at: i) }
            let source = g(8)
            if let r = g(1) { return Mark(kind: .insertion, range: m.range, first: r, second: nil, source: source) }
            if let r = g(2) { return Mark(kind: .deletion, range: m.range, first: r, second: nil, source: source) }
            if let a = g(3), let b = g(4) { return Mark(kind: .substitution, range: m.range, first: a, second: b, source: source) }
            if let r = g(5) { return Mark(kind: .highlight, range: m.range, first: r, second: g(6), source: source) }
            if let r = g(7) { return Mark(kind: .comment, range: m.range, first: r, second: r, source: source) }
            return nil
        }
    }

    static func mark(at location: Int, in text: String) -> Mark? {
        marks(in: text).first { $0.range.location <= location && location <= NSMaxRange($0.range) }
    }

    /// The parts of the text never shown: the CriticMarkup syntax, and comment bodies (shown as a bubble instead).
    static func hidden(in text: String) -> [NSRange] { hidden(of: marks(in: text)) }

    static func hidden(of marks: [Mark]) -> [NSRange] {
        var out: [NSRange] = []
        for m in marks {
            var visible: [NSRange] = []
            switch m.kind {
            case .insertion, .deletion, .highlight: visible = [m.first]
            case .substitution: visible = [m.first] + (m.second.map { [$0] } ?? [])
            case .comment: visible = []
            }
            var cursor = m.range.location
            for v in visible.sorted(by: { $0.location < $1.location }) {
                if v.location > cursor { out.append(NSRange(location: cursor, length: v.location - cursor)) }
                cursor = NSMaxRange(v)
            }
            if NSMaxRange(m.range) > cursor { out.append(NSRange(location: cursor, length: NSMaxRange(m.range) - cursor)) }
        }
        return out
    }

    /// What a mark becomes once decided.
    static func resolved(_ mark: Mark, in text: String, accept: Bool) -> String {
        let ns = text as NSString
        switch mark.kind {
        case .insertion: return accept ? ns.substring(with: mark.first) : ""
        case .deletion: return accept ? "" : ns.substring(with: mark.first)
        case .substitution: return ns.substring(with: accept ? mark.second! : mark.first)
        case .highlight: return ns.substring(with: mark.first)
        case .comment: return ""
        }
    }

    /// The text with every mark decided the same way. Rejecting all gives the text as it stood before the
    /// corrections: that is what is printed while corrections are pending.
    static func resolveAll(_ text: String, accept: Bool) -> String {
        let all = marks(in: text)
        guard !all.isEmpty else { return text }
        let out = NSMutableString(string: text)
        for m in all.reversed() { out.replaceCharacters(in: m.range, with: resolved(m, in: text, accept: accept)) }
        return out as String
    }

    /// Marks crossing paragraphs decided as refused, for what reads the text line by line. Others stay.
    static func refusingMultiline(_ text: String) -> String {
        let all = marks(in: text).filter { (text as NSString).substring(with: $0.range).contains("\n") }
        guard !all.isEmpty else { return text }
        let out = NSMutableString(string: text)
        for m in all.reversed() { out.replaceCharacters(in: m.range, with: resolved(m, in: text, accept: false)) }
        return out as String
    }

    // MARK: Typing in revision mode

    /// An edit to perform instead of the one typed: what to replace, with what, and where the caret goes.
    struct Plan: Equatable {
        let range: NSRange
        let text: String
        let caret: Int
    }

    /// How a typed edit is recorded in revision mode. Nil: let it through as is (editing inside one's own
    /// insertion, or the new text of a substitution). A plan that changes nothing blocks an edit that would
    /// break a mark's syntax.
    static func track(text: String, range: NSRange, replacement s: String) -> Plan? {
        let ns = text as NSString
        let all = marks(in: text)
        // Inside the text one is adding (or the new side of a substitution): plain editing.
        for m in all {
            let editable = m.kind == .insertion ? m.first : (m.kind == .substitution ? m.second : nil)
            if let e = editable, range.location >= e.location, NSMaxRange(range) <= NSMaxRange(e) { return nil }
        }
        let blocked = Plan(range: NSRange(location: range.location, length: 0), text: "", caret: range.location)
        if s.isEmpty, range.length > 0 {
            let deleted = ns.substring(with: range)
            // Backspace just before a deletion: it grows to the left.
            if let m = all.first(where: { $0.kind == .deletion && $0.range.location == NSMaxRange(range) }) {
                let merged = "{--" + deleted + ns.substring(with: m.first) + "--}"
                return Plan(range: NSUnionRange(range, m.range), text: merged, caret: range.location)
            }
            // Forward delete just after a deletion: it grows to the right.
            if let m = all.first(where: { $0.kind == .deletion && NSMaxRange($0.range) == range.location }) {
                let merged = "{--" + ns.substring(with: m.first) + deleted + "--}"
                return Plan(range: NSUnionRange(m.range, range), text: merged, caret: m.range.location + (merged as NSString).length)
            }
            if all.contains(where: { NSIntersectionRange($0.range, range).length > 0 }) { return blocked }
            return Plan(range: range, text: "{--" + deleted + "--}", caret: range.location)
        }
        if range.length == 0 {
            if all.contains(where: { $0.range.location < range.location && range.location < NSMaxRange($0.range) }) { return blocked }
            return Plan(range: range, text: "{++" + s + "++}", caret: range.location + 3 + (s as NSString).length)
        }
        if all.contains(where: { NSIntersectionRange($0.range, range).length > 0 }) { return blocked }
        let old = ns.substring(with: range)
        let text = "{~~" + old + "~>" + s + "~~}"
        return Plan(range: range, text: text, caret: range.location + (text as NSString).length - 3)
    }
}
