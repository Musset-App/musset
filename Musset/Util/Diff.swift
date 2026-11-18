import Foundation

/// Where two texts differ: the one comparison under the history, the tracks, readers' corrections, Word's, the
/// typography pass and the word diff shown in the book's story. Each of them cuts its text its own way (paragraphs,
/// words and spaces, Word's formatted runs, UTF-16); what they share is here.
enum Diff {
    /// The stretches where `new` differs from `old`, in order: what went on one side, what came on the other
    /// (either may be empty). What both ends share is set aside first: an edit is usually small.
    static func gaps<T: Equatable>(_ old: [T], _ new: [T]) -> [(old: Range<Int>, new: Range<Int>)] {
        let ends = commonEnds(old, new)
        let a = Array(old[ends.head..<(old.count - ends.tail)]), b = Array(new[ends.head..<(new.count - ends.tail)])
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in b.difference(from: a) {
            switch change {
            case .remove(let o, _, _): removed.insert(o)
            case .insert(let o, _, _): inserted.insert(o)
            }
        }
        var out: [(old: Range<Int>, new: Range<Int>)] = []
        var i = 0, j = 0
        while i < a.count || j < b.count {
            if !removed.contains(i), !inserted.contains(j) { i += 1; j += 1; continue }
            let si = i, sj = j
            while removed.contains(i) { i += 1 }
            while inserted.contains(j) { j += 1 }
            out.append(((ends.head + si)..<(ends.head + i), (ends.head + sj)..<(ends.head + j)))
        }
        return out
    }

    /// How many items the two share at their start, and then at their end.
    static func commonEnds<T: Equatable>(_ old: [T], _ new: [T]) -> (head: Int, tail: Int) {
        var head = 0
        while head < old.count, head < new.count, old[head] == new[head] { head += 1 }
        var tail = 0
        while tail < old.count - head, tail < new.count - head, old[old.count - 1 - tail] == new[new.count - 1 - tail] { tail += 1 }
        return (head, tail)
    }

    /// A text as its words and the spaces between them, in turn: joined, they are the text again.
    static func tokens(_ s: String) -> [String] {
        var out: [String] = [], current = "", space = false
        for c in s {
            let isSpace = c.isWhitespace
            if isSpace != space, !current.isEmpty { out.append(current); current = "" }
            space = isSpace
            current.append(c)
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    /// Word diff between two texts, in git's `--word-diff=plain` form: `[-removed-]{+added+}` inside the
    /// new text, after a `@@` line. Words are runs of non-space characters. Empty when nothing changed.
    static func words(_ a: String, _ b: String) -> String {
        let old = Word.split(a), new = Word.split(b)
        let gaps = gaps(old.map(\.word), new.map(\.word))
        guard !gaps.isEmpty else { return "" }
        var out = "@@ -1 +1 @@\n"
        var j = 0
        var afterRemoval = false
        func same(upTo end: Int, oldAt: Int) {
            var i = oldAt
            while j < end {
                // After a removal at the very start, keep the space the old text had.
                out += (afterRemoval && new[j].space.isEmpty ? old[i].space : new[j].space) + new[j].word
                i += 1; j += 1
                afterRemoval = false
            }
        }
        var i = 0
        for gap in gaps {
            same(upTo: gap.new.lowerBound, oldAt: i)
            if !gap.old.isEmpty {
                out += old[gap.old.lowerBound].space + "[-" + old[gap.old].enumerated().map { ($0 == 0 ? "" : $1.space) + $1.word }.joined() + "-]"
                afterRemoval = true
            }
            if !gap.new.isEmpty {
                out += (afterRemoval ? "" : new[gap.new.lowerBound].space) + "{+" + new[gap.new].enumerated().map { ($0 == 0 ? "" : $1.space) + $1.word }.joined() + "+}"
                afterRemoval = false
            }
            i = gap.old.upperBound
            j = gap.new.upperBound
        }
        same(upTo: new.count, oldAt: i)
        out += String(b.reversed().prefix { $0.isWhitespace }.reversed())
        return out
    }

    /// A word and the whitespace before it.
    private struct Word {
        let space: String
        let word: String

        static func split(_ s: String) -> [Word] {
            var out: [Word] = []
            var space = "", word = ""
            for c in s {
                if c.isWhitespace {
                    if !word.isEmpty { out.append(Word(space: space, word: word)); space = ""; word = "" }
                    space.append(c)
                } else {
                    word.append(c)
                }
            }
            if !word.isEmpty { out.append(Word(space: space, word: word)) }
            return out
        }
    }
}
