import Foundation

/// One thing that changed in a chapter between two states: a few words, a sentence or a whole paragraph.
struct TextChange: Identifiable, Hashable {
    enum Kind: Hashable { case removed, added, modified }
    let kind: Kind
    /// What the older state had here, whitespace included, so it can be put back exactly.
    let old: String
    /// What the newer state has here.
    let new: String
    /// The text right before and after, on the older side for a removal, the newer side for an addition.
    let before: String
    let after: String
    /// Paragraph in the newer state.
    let paragraph: Int
    var id: String { "\(paragraph):\(before.suffix(12)):\(old.prefix(24)):\(new.prefix(24))" }
}

/// Reading the difference between two states of a chapter, paragraph by paragraph, then word by word.
enum TextDiff {
    static let contextLength = 48

    /// `old` and `new` in editor form (one line per paragraph).
    static func changes(old: String, new: String) -> [TextChange] {
        guard old != new else { return [] }
        let a = old.components(separatedBy: "\n"), b = new.components(separatedBy: "\n")
        var out: [TextChange] = []
        for gap in Diff.gaps(a, b) { emit(Array(gap.old), Array(gap.new), a, b, into: &out) }
        return out
    }

    /// Pairs what looks alike (the same paragraph rewritten), keeping the order; the rest was cut or written whole.
    private static func emit(_ gone: [Int], _ come: [Int], _ a: [String], _ b: [String], into out: inout [TextChange]) {
        var nextCome = 0
        for g in gone {
            let match = (nextCome..<come.count).first { similarity(a[g], b[come[$0]]) >= 0.4 }
            if let match {
                for k in nextCome..<match { whole(added: come[k], b, into: &out) }
                words(a[g], b[come[match]], paragraph: come[match], into: &out)
                nextCome = match + 1
            } else {
                guard !a[g].trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                let before = g > 0 ? tail(a[g - 1] + "\n") : ""
                let after = g + 1 < a.count ? head(a[g + 1]) : ""
                out.append(TextChange(kind: .removed, old: a[g] + "\n", new: "", before: before, after: after, paragraph: come.first ?? max(0, g)))
            }
        }
        for k in nextCome..<max(nextCome, come.count) { whole(added: come[k], b, into: &out) }
    }

    private static func whole(added j: Int, _ b: [String], into out: inout [TextChange]) {
        guard !b[j].trimmingCharacters(in: .whitespaces).isEmpty else { return }
        out.append(TextChange(kind: .added, old: "", new: b[j] + "\n", before: j > 0 ? tail(b[j - 1] + "\n") : "", after: j + 1 < b.count ? head(b[j + 1]) : "", paragraph: j))
    }

    private static func words(_ x: String, _ y: String, paragraph: Int, into out: inout [TextChange]) {
        let a = Diff.tokens(x), b = Diff.tokens(y)
        guard a.count + b.count < 12_000 else {
            out.append(TextChange(kind: .modified, old: x, new: y, before: "", after: "", paragraph: paragraph))
            return
        }
        // Two changes a word or so apart read as one.
        var gaps: [(old: Range<Int>, new: Range<Int>)] = []
        for gap in Diff.gaps(a, b) {
            if let last = gaps.last, gap.old.lowerBound - last.old.upperBound < 4 {
                gaps[gaps.count - 1] = (last.old.lowerBound..<gap.old.upperBound, last.new.lowerBound..<gap.new.upperBound)
            } else {
                gaps.append(gap)
            }
        }
        for gap in gaps {
            let old = a[gap.old].joined(), new = b[gap.new].joined()
            if old.trimmingCharacters(in: .whitespaces).isEmpty, new.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            let kind: TextChange.Kind = new.isEmpty ? .removed : (old.isEmpty ? .added : .modified)
            let before = a[..<gap.old.lowerBound].joined(), after = a[gap.old.upperBound...].joined()
            out.append(TextChange(kind: kind, old: old, new: new, before: tail(before), after: head(after), paragraph: paragraph))
        }
    }

    static func tail(_ s: String) -> String { String(s.suffix(contextLength)) }
    static func head(_ s: String) -> String { String(s.prefix(contextLength)) }

    /// Share of words in common, from 0 to 1.
    static func similarity(_ x: String, _ y: String) -> Double {
        let a = Set(x.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })), b = Set(y.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }))
        guard !a.isEmpty, !b.isEmpty else { return x == y ? 1 : 0 }
        return Double(a.intersection(b).count) / Double(max(a.count, b.count))
    }

}

/// Putting one change back into today's text.
enum TextRestore {
    struct Place: Identifiable, Hashable {
        let range: NSRange
        /// Why here, in the author's words: the passage it follows or comes before.
        let hint: String
        let excerpt: String
        var id: Int { range.location }
    }
    enum Outcome: Equatable {
        /// The older text is already there.
        case alreadyThere
        /// One place for certain.
        case exact(NSRange, String)
        /// The surroundings changed: the author picks.
        case choose([Place], String)
    }

    /// How to go back to the older side of `c` in `text`.
    static func undo(_ c: TextChange, in text: String) -> Outcome {
        let ns = text as NSString
        let replacement = c.old
        let trimmedOld = c.old.trimmingCharacters(in: .whitespacesAndNewlines)
        // Still the newer words, in place.
        if !c.new.isEmpty {
            let spot = ns.range(of: c.before + c.new + c.after)
            if spot.location != NSNotFound {
                return .exact(NSRange(location: spot.location + (c.before as NSString).length, length: (c.new as NSString).length), replacement)
            }
        } else {
            let spot = ns.range(of: c.before + c.after)
            if spot.location != NSNotFound, !(c.before + c.after).isEmpty {
                return .exact(NSRange(location: spot.location + (c.before as NSString).length, length: 0), replacement)
            }
        }
        if !trimmedOld.isEmpty, ns.range(of: trimmedOld).location != NSNotFound { return .alreadyThere }
        if c.old.isEmpty {
            // An addition already gone.
            return ns.range(of: c.new.trimmingCharacters(in: .whitespacesAndNewlines)).location == NSNotFound ? .alreadyThere : places(for: c, in: ns, replacing: true)
        }
        return places(for: c, in: ns, replacing: false)
    }

    private static func places(for c: TextChange, in ns: NSString, replacing: Bool) -> Outcome {
        var found: [Place] = []
        func add(_ r: NSRange, _ hint: String) {
            guard !found.contains(where: { $0.range.location == r.location }), found.count < 3 else { return }
            let line = ns.lineRange(for: NSRange(location: min(r.location, max(0, ns.length - 1)), length: 0))
            let excerpt = line.location < ns.length ? ns.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines) : ""
            found.append(Place(range: r, hint: hint, excerpt: String(excerpt.prefix(180))))
        }
        if replacing {
            let target = ns.range(of: c.new.trimmingCharacters(in: .whitespacesAndNewlines))
            if target.location != NSNotFound { add(target, L("Where it is now")) }
        } else {
            for size in [c.before.count, 24, 12] where size > 0 {
                let piece = String(c.before.suffix(size)).trimmingCharacters(in: .newlines)
                guard piece.count >= 6 else { continue }
                let r = ns.range(of: piece, options: .backwards)
                if r.location != NSNotFound { add(NSRange(location: NSMaxRange(r), length: 0), L("After « \(short(piece)) »")); break }
            }
            for size in [c.after.count, 24, 12] where size > 0 {
                let piece = String(c.after.prefix(size)).trimmingCharacters(in: .newlines)
                guard piece.count >= 6 else { continue }
                let r = ns.range(of: piece)
                if r.location != NSNotFound { add(NSRange(location: r.location, length: 0), L("Before « \(short(piece)) »")); break }
            }
            add(NSRange(location: ns.length, length: 0), L("At the end of the chapter"))
        }
        return .choose(found, replacing ? "" : c.old)
    }

    private static func short(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count > 28 ? "…" + t.suffix(28) : t
    }
}

/// Work sessions: commits close together read as one sitting.
struct WorkSitting: Identifiable, Hashable {
    /// The newest commit of the sitting.
    let tip: GitService.Commit
    /// The commit before the oldest of the sitting (nil at the very beginning).
    let base: String?
    let first: Date
    /// Chapters the sitting touched.
    var chapters: [String]
    var id: String { tip.id }
}

/// What the history of a phrase looks like: when it came, when it changed, when it left.
struct PhraseEvent: Identifiable, Hashable {
    enum Kind: Hashable { case written, changed, removed, restored }
    let kind: Kind
    let commit: GitService.Commit
    let chapter: String
    /// The paragraph at that moment (before it left, for a removal).
    let text: String
    /// Where it stood, for putting it back.
    let before: String
    let after: String
    var id: String { commit.id + chapter + "\(kind)" }
}

/// Reads the history off the main thread. Blobs don't change: what was read once is kept.
final class HistoryReader: @unchecked Sendable {
    let git: GitService
    private let lock = NSLock()
    private var texts: [String: String] = [:]
    private var diffs: [String: [TextChange]] = [:]
    private var logs: [String: [GitService.Commit]] = [:]

    init(git: GitService) { self.git = git }

    static let sittingGap: TimeInterval = 45 * 60

    func log(_ file: String, refresh: Bool = false) -> [GitService.Commit] {
        lock.lock(); let known = logs[file]; lock.unlock()
        if let known, !refresh { return known }
        let out = git.log(path: file, limit: 400)
        lock.lock(); logs[file] = out; lock.unlock()
        return out
    }

    /// A chapter's text at a commit, in editor form.
    func text(_ commit: String, _ file: String) -> String {
        let key = commit + ":" + file
        lock.lock(); let known = texts[key]; lock.unlock()
        if let known { return known }
        let out = ParagraphCodec.decode(git.show(commit, path: file) ?? "")
        lock.lock()
        if texts.count > 2_000 { texts.removeAll() }
        texts[key] = out
        lock.unlock()
        return out
    }

    /// Newest first. `logs`: chapter id → its file's commits, newest first.
    static func sittings(_ logs: [String: [GitService.Commit]]) -> [WorkSitting] {
        var byCommit: [String: (commit: GitService.Commit, chapters: [String])] = [:]
        var previous: [String: String?] = [:]
        for (chapter, log) in logs {
            for (i, c) in log.enumerated() {
                byCommit[c.id, default: (c, [])].chapters.append(chapter)
                if previous[chapter + c.id] == nil { previous[chapter + c.id] = i + 1 < log.count ? log[i + 1].id : nil }
            }
        }
        let ordered = byCommit.values.sorted { $0.commit.date > $1.commit.date }
        var out: [WorkSitting] = []
        var tip: GitService.Commit?, oldest: GitService.Commit?, chapters: [String] = []
        func close() {
            guard let t = tip, let o = oldest else { return }
            let base = chapters.lazy.compactMap { (previous[$0 + o.id] ?? nil) }.first
            out.append(WorkSitting(tip: t, base: base, first: o.date, chapters: chapters.sorted()))
        }
        for entry in ordered {
            if let o = oldest, o.date.timeIntervalSince(entry.commit.date) > sittingGap {
                close(); tip = nil; chapters = []
            }
            if tip == nil { tip = entry.commit }
            oldest = entry.commit
            for c in entry.chapters where !chapters.contains(c) { chapters.append(c) }
        }
        close()
        return out
    }

    /// What a sitting changed in a chapter: its state before against its state after.
    func changes(in sitting: WorkSitting, file: String, log: [GitService.Commit]) -> [TextChange] {
        let key = sitting.id + ":" + file
        lock.lock(); let known = diffs[key]; lock.unlock()
        if let known { return known }
        // The chapter as it stood at the end of the sitting, and just before it.
        guard let after = log.first(where: { $0.date <= sitting.tip.date }) else { return [] }
        let before = log.first { $0.date < sitting.first }
        let out = TextDiff.changes(old: before.map { text($0.id, file) } ?? "", new: text(after.id, file))
        lock.lock(); diffs[key] = out; lock.unlock()
        return out
    }

    /// The life of a phrase in a chapter, oldest first, even if it no longer exists.
    func phrase(_ query: String, chapter: String, file: String) -> [PhraseEvent] {
        let q = Fold.search(query)
        guard q.count >= 3 else { return [] }
        var out: [PhraseEvent] = []
        var current: String?, last: (text: String, before: String, after: String)?
        for c in log(file).reversed() {
            let lines = text(c.id, file).components(separatedBy: "\n")
            let i = lines.firstIndex { Fold.search($0).contains(q) }
            if let i {
                let p = lines[i]
                if current == nil {
                    out.append(PhraseEvent(kind: out.isEmpty ? .written : .restored, commit: c, chapter: chapter, text: p, before: i > 0 ? TextDiff.tail(lines[i - 1] + "\n") : "", after: i + 1 < lines.count ? TextDiff.head(lines[i + 1]) : ""))
                } else if current != p {
                    out.append(PhraseEvent(kind: .changed, commit: c, chapter: chapter, text: p, before: i > 0 ? TextDiff.tail(lines[i - 1] + "\n") : "", after: i + 1 < lines.count ? TextDiff.head(lines[i + 1]) : ""))
                }
                current = p
                last = (p, i > 0 ? TextDiff.tail(lines[i - 1] + "\n") : "", i + 1 < lines.count ? TextDiff.head(lines[i + 1]) : "")
            } else if current != nil, let l = last {
                out.append(PhraseEvent(kind: .removed, commit: c, chapter: chapter, text: l.text, before: l.before, after: l.after))
                current = nil
            }
        }
        return out
    }

    /// The states a passage went through, newest first: followed backwards, paragraph by paragraph.
    func states(of passage: String, file: String) -> [(commit: GitService.Commit, text: String)] {
        var out: [(GitService.Commit, String)] = []
        var follow = passage
        for c in log(file) {
            let lines = text(c.id, file).components(separatedBy: "\n")
            guard let best = lines.filter({ !$0.isEmpty }).max(by: { TextDiff.similarity($0, follow) < TextDiff.similarity($1, follow) }),
                  TextDiff.similarity(best, follow) >= 0.3 else { break }
            if best != follow || out.isEmpty {
                if out.last?.1 != best { out.append((c, best)) }
                follow = best
            }
        }
        return out
    }
}
