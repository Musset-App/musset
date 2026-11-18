import Foundation

/// Three-way merge by paragraph: the manuscript and a track, against the text they both started from.
/// Paragraphs are the editor's lines (see ParagraphCodec).
enum ParagraphMerge {
    enum Pick: Equatable { case mine, theirs, both }

    struct Block: Identifiable, Equatable {
        var id = 0
        /// Paragraphs both sides share.
        var same: [String] = []
        /// A difference: the manuscript's paragraphs and the track's.
        var mine: [String] = []
        var theirs: [String] = []
        var isChange = false
        /// Both sides wrote something new here since they parted.
        var conflict = false
        /// The side that changed, when only one did.
        var suggested: Pick?
    }

    static func blocks(base: String, mine: String, theirs: String) -> [Block] {
        let m = lines(mine), t = lines(theirs)
        let baseSet = Set(lines(base))
        var out: [Block] = []
        func add(_ b: Block) { var b = b; b.id = out.count; out.append(b) }
        func change(_ a: [String], _ b: [String]) {
            // As many paragraphs on each side: one choice per paragraph.
            let pairs = a.count == b.count && a.count > 1 ? zip(a, b).map { ([$0], [$1]) } : [(a, b)]
            for (x, y) in pairs {
                let mineNew = x.contains { !baseSet.contains($0) }, theirsNew = y.contains { !baseSet.contains($0) }
                var suggested: Pick?
                if theirsNew && !mineNew { suggested = .theirs }
                else if mineNew && !theirsNew { suggested = .mine }
                else if !mineNew && !theirsNew {
                    // Only paragraphs of the common text: one side deleted, the other kept.
                    if x.isEmpty { suggested = .mine } else if y.isEmpty { suggested = .theirs }
                }
                add(Block(mine: x, theirs: y, isChange: true, conflict: mineNew && theirsNew, suggested: suggested))
            }
        }
        var i = 0
        for gap in Diff.gaps(m, t) {
            if gap.old.lowerBound > i { add(Block(same: Array(m[i..<gap.old.lowerBound]))) }
            change(Array(m[gap.old]), Array(t[gap.new]))
            i = gap.old.upperBound
        }
        if i < m.count { add(Block(same: Array(m[i...]))) }
        return out
    }

    /// The chapter as chosen: shared paragraphs, then each difference's pick (the manuscript's when none).
    static func result(_ blocks: [Block], picks: [Int: Pick]) -> String {
        var out: [String] = []
        for b in blocks {
            if !b.isChange { out += b.same; continue }
            switch picks[b.id] ?? .mine {
            case .mine: out += b.mine
            case .theirs: out += b.theirs
            case .both: out += b.mine + b.theirs
            }
        }
        return out.joined(separator: "\n")
    }

    static func lines(_ s: String) -> [String] {
        s.isEmpty ? [] : s.components(separatedBy: "\n")
    }
}
