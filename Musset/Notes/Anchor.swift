import Foundation

/// Where a note sits, without touching the text: the quoted passage, a little of what surrounds it,
/// and where it was last seen (W3C Web Annotation's text-quote + text-position selectors).
struct NoteAnchor: Codable, Hashable {
    var quote: String
    var prefix: String
    var suffix: String
    /// UTF-16 offset where the passage was last seen.
    var start: Int
    /// Chapter version the note was written on.
    var version: String?
}

enum Anchoring {
    static let contextLength = 32
    /// Below this, a rewritten passage is considered gone.
    static let fuzzyThreshold = 0.7
    /// Longer quotes are not compared word by word: the cost grows with the square of their length, on the main thread.
    static let fuzzyMaxWords = 200

    static func capture(_ range: NSRange, in text: NSString, version: String?) -> NoteAnchor {
        let pre = NSRange(location: max(0, range.location - contextLength), length: min(range.location, contextLength))
        let sufStart = NSMaxRange(range)
        let suf = NSRange(location: sufStart, length: min(contextLength, max(0, text.length - sufStart)))
        return NoteAnchor(quote: text.substring(with: range), prefix: text.substring(with: pre),
                          suffix: text.substring(with: suf), start: range.location, version: version)
    }

    /// Finds the passage again: exactly where it was, else the best-placed copy of the quote, else a close rewrite.
    /// `words` lets a caller resolving many notes split the text into words only once.
    static func resolve(_ a: NoteAnchor, in text: String, words: (() -> [Token])? = nil) -> NSRange? {
        let ns = text as NSString
        let q = a.quote as NSString
        guard q.length > 0 else { return nil }
        if a.start >= 0, a.start + q.length <= ns.length, ns.substring(with: NSRange(location: a.start, length: q.length)) == a.quote {
            return NSRange(location: a.start, length: q.length)
        }
        if let re = ProofFix.tolerantRegex(a.quote, wholeWords: false) {
            let found = re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map(\.range)
            if let best = found.max(by: { score($0, a, ns) < score($1, a, ns) }) { return best }
        }
        return fuzzy(a, in: ns, words: words?() ?? tokens(ns))
    }

    /// Context agreement (0…2) minus a small penalty for distance from the last known position.
    private static func score(_ r: NSRange, _ a: NoteAnchor, _ ns: NSString) -> Double {
        let before = ns.substring(with: NSRange(location: max(0, r.location - contextLength), length: min(r.location, contextLength)))
        let afterStart = NSMaxRange(r)
        let after = ns.substring(with: NSRange(location: afterStart, length: min(contextLength, ns.length - afterStart)))
        let p = commonSuffix(before, a.prefix), s = commonPrefix(after, a.suffix)
        let distance = Double(abs(r.location - a.start)) / Double(max(ns.length, 1))
        return Double(p) / Double(max(a.prefix.count, 1)) + Double(s) / Double(max(a.suffix.count, 1)) - distance
    }

    private static func commonPrefix(_ x: String, _ y: String) -> Int { zip(x, y).prefix { $0 == $1 }.count }
    private static func commonSuffix(_ x: String, _ y: String) -> Int { zip(x.reversed(), y.reversed()).prefix { $0 == $1 }.count }

    // MARK: Fuzzy (the passage was rewritten)

    struct Token { let key: String; let range: NSRange }
    private static let wordRegex = try! NSRegularExpression(pattern: #"[\p{L}\p{M}\p{N}]+"#)

    static func tokens(_ s: NSString) -> [Token] {
        wordRegex.matches(in: s as String, range: NSRange(location: 0, length: s.length)).map {
            Token(key: s.substring(with: $0.range).lowercased().folding(options: .diacriticInsensitive, locale: nil), range: $0.range)
        }
    }

    /// Slides a window of about the quote's word count over the text and keeps the closest one
    /// (longest common word subsequence), preferring windows near the last known position.
    /// The words a window shares with the quote bound its common subsequence, so windows that can't reach
    /// the threshold are skipped without comparing them.
    private static func fuzzy(_ a: NoteAnchor, in ns: NSString, words: [Token]) -> NSRange? {
        let q = tokens(a.quote as NSString).map(\.key)
        guard q.count >= 3, q.count <= fuzzyMaxWords, !words.isEmpty else { return nil }
        var wanted: [String: Int] = [:]
        for k in q { wanted[k, default: 0] += 1 }
        var best: (score: Double, range: NSRange)?
        for size in Set([q.count - 1, q.count, q.count + 1]) where size >= 1 && size <= words.count {
            let needed = fuzzyThreshold * Double(max(q.count, size))
            var inWindow: [String: Int] = [:]
            var shared = 0
            func add(_ k: String) {
                guard let w = wanted[k] else { return }
                let n = inWindow[k, default: 0]
                if n < w { shared += 1 }
                inWindow[k] = n + 1
            }
            func remove(_ k: String) {
                guard let w = wanted[k], let n = inWindow[k] else { return }
                inWindow[k] = n - 1
                if n - 1 < w { shared -= 1 }
            }
            for j in 0..<size { add(words[j].key) }
            for i in 0...(words.count - size) {
                if i > 0 { remove(words[i - 1].key); add(words[i + size - 1].key) }
                guard Double(shared) >= needed else { continue }
                let window = words[i..<(i + size)]
                let sim = Double(lcs(q, window.map(\.key))) / Double(max(q.count, size))
                guard sim >= fuzzyThreshold else { continue }
                let r = NSRange(location: window.first!.range.location, length: NSMaxRange(window.last!.range) - window.first!.range.location)
                let score = sim - Double(abs(r.location - a.start)) / Double(max(ns.length, 1)) * 0.1
                if best == nil || score > best!.score { best = (score, r) }
            }
        }
        return best?.range
    }

    private static func lcs(_ x: [String], _ y: [String]) -> Int {
        var prev = Array(repeating: 0, count: y.count + 1)
        for xi in x {
            var cur = Array(repeating: 0, count: y.count + 1)
            for (j, yj) in y.enumerated() {
                cur[j + 1] = xi == yj ? prev[j] + 1 : max(prev[j + 1], cur[j])
            }
            prev = cur
        }
        return prev[y.count]
    }

    // MARK: Following edits

    /// Moves a note's range through one edit. `edited` is the edit's range in the new text (as NSTextStorage reports it)
    /// and `delta` the change in length. Typing right before or after a passage does not stretch it; replacing
    /// part of it keeps the new text in; deleting all of it, or pasting over more than it, returns nil (the note
    /// becomes an orphan): the note must not stretch to cover whatever was pasted.
    static func adjust(_ r: NSRange, edited e: NSRange, delta: Int) -> NSRange? {
        let s = r.location, t = NSMaxRange(r)
        let oldStart = e.location, oldEnd = e.location + e.length - delta, newEnd = NSMaxRange(e)
        if t <= oldStart && !(oldStart == oldEnd && s == t) { return r }          // edit after the passage
        if s >= oldEnd { return NSRange(location: s + delta, length: r.length) } // edit before it
        let newS = s < oldStart ? s : oldStart
        let newT = t > oldEnd ? t + delta : newEnd
        if s >= oldStart && t <= oldEnd && (e.length == 0 || s > oldStart || t < oldEnd) { return nil } // passage deleted or swallowed
        return newT > newS ? NSRange(location: newS, length: newT - newS) : nil
    }
}
