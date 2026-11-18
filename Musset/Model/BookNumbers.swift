import CoreGraphics
import Foundation

/// The book in numbers, as Overview's first page shows it above the scenes: each chapter a bar, the goal, the
/// pages and the reading it makes, the days written. Nothing here reads a chapter's text: it works from the counts
/// the session keeps.
enum BookNumbers {
    /// A page of a printed novel, and a reader's pace: the same pace the chapter's own numbers use.
    static let wordsPerPage = 250
    static let wordsPerMinute = 230

    // MARK: The chapters as bars

    struct Bar: Identifiable, Equatable {
        let id: String
        /// Its number as the book writes it; empty for a piece that carries none.
        let mark: String
        let title: String
        let status: ChapterStatus
        let counts: TextCounts
        let scenes: Int
        /// The strand it follows, by its id; nil for none, or for one the book no longer has.
        var strand: String? = nil
    }

    /// The chapters in a row that share a part; `part` is nil for those in none (the whole book when it has none).
    struct Group: Identifiable, Equatable {
        let id: String
        let part: BookPart?
        let bars: [Bar]
        var counts: TextCounts { bars.reduce(.zero) { $0 + $1.counts } }
    }

    static func groups(_ manifest: BookManifest, counts: [String: TextCounts], scenes: [String: Int]) -> [Group] {
        let marks = manifest.pieceMarks
        return manifest.scenesBands.map { band in
            Group(id: band.id, part: band.part, bars: band.chapters.map { ch in
                Bar(id: ch.entry.id, mark: marks[ch.index], title: manifest.shownTitle(of: ch.entry),
                    status: ch.entry.status ?? .draft, counts: counts[ch.entry.id] ?? .zero, scenes: scenes[ch.entry.id] ?? 0,
                    strand: manifest.strand(of: ch.entry)?.id)
            })
        }
    }

    /// How many chapters are at each status, in the statuses' own order; those no chapter is at are left out.
    static func statuses(_ chapters: [ChapterEntry]) -> [(status: ChapterStatus, count: Int)] {
        ChapterStatus.allCases.compactMap { st in
            let n = chapters.filter { ($0.status ?? .draft) == st }.count
            return n > 0 ? (st, n) : nil
        }
    }

    // MARK: The strands

    /// A strand as the legend lists it: the chapters that follow it, in the book's order, and what they weigh.
    /// `strand` is nil for the chapters that follow none.
    struct Thread: Identifiable, Equatable {
        let strand: BookStructure.Strand?
        let chapters: [String]
        let counts: TextCounts
        var id: String { strand?.id ?? "" }
    }

    /// The book's strands in the author's order, those no chapter follows left out, then the chapters that follow
    /// none. Empty for a book without strands: it has no such legend.
    static func threads(_ manifest: BookManifest, counts: [String: TextCounts]) -> [Thread] {
        let strands = manifest.strands
        guard !strands.isEmpty else { return [] }
        var members: [String: [String]] = [:]
        for ch in manifest.chapters { members[manifest.strand(of: ch)?.id ?? "", default: []].append(ch.id) }
        func thread(_ strand: BookStructure.Strand?) -> Thread? {
            guard let ids = members[strand?.id ?? ""] else { return nil }
            return Thread(strand: strand, chapters: ids, counts: ids.reduce(.zero) { $0 + (counts[$1] ?? .zero) })
        }
        return strands.compactMap(thread) + [thread(nil)].compactMap { $0 }
    }

    /// A bar as tall as its chapter is long beside the longest one, in whole points. An empty chapter, or one too
    /// short to show, keeps a stub: it is still there to be seen and clicked.
    static func height(_ size: Int, peak: Int, room: CGFloat, minimum: CGFloat = 4) -> CGFloat {
        guard size > 0, peak > 0 else { return minimum }
        return min(max(minimum, (room * CGFloat(size) / CGFloat(peak)).rounded()), room)
    }

    /// Where the bars stand in the width they have: all on one baseline, parts a little apart.
    struct Layout: Equatable {
        struct Slot: Equatable {
            /// The bar's left edge and width, and how far its column reaches (to the next bar): the column takes the pointer.
            var x: CGFloat
            var width: CGFloat
            var reach: CGFloat
            var height: CGFloat
        }
        var groups: [[Slot]] = []
        /// Each group's left edge and width, for the line it stands on and the part's name under it.
        var spans: [(x: CGFloat, width: CGFloat)] = []
        var gap: CGFloat = 0

        static func == (a: Layout, b: Layout) -> Bool {
            a.groups == b.groups && a.gap == b.gap && a.spans.map(\.x) == b.spans.map(\.x) && a.spans.map(\.width) == b.spans.map(\.width)
        }
    }

    /// The widest a bar gets: a book of five chapters does not fill the row with slabs.
    static let widestPitch: CGFloat = 34

    /// `sizes`: each group's chapters' lengths, in the unit shown. Edges fall on device pixels (`scale` of them to
    /// a point), so every bar is crisp, and the row fills its width exactly when the bars are not at their widest.
    static func layout(_ sizes: [[Int]], width: CGFloat, room: CGFloat, scale: CGFloat = 2) -> Layout {
        let sizes = sizes.filter { !$0.isEmpty }
        let n = sizes.reduce(0) { $0 + $1.count }
        guard n > 0, width > 0 else { return Layout() }
        let peak = sizes.joined().max() ?? 0
        let rough = width / CGFloat(n)
        let gap: CGFloat = rough >= 12 ? 4 : rough >= 6 ? 2 : 1
        let partGap: CGFloat = sizes.count > 1 ? (rough >= 12 ? 18 : rough >= 6 ? 12 : 6) : 0
        // Each group ends on a bar, not on a gap: the row is n pitches less one gap a group, plus the parts' gaps.
        let pitch = min(max((width - partGap * CGFloat(sizes.count - 1) + gap * CGFloat(sizes.count)) / CGFloat(n), gap + 1 / scale), widestPitch)
        func snap(_ v: CGFloat) -> CGFloat { (v * scale).rounded() / scale }
        var out = Layout(gap: gap)
        var origin: CGFloat = 0
        for group in sizes {
            var slots: [Layout.Slot] = []
            for (i, size) in group.enumerated() {
                let x = snap(origin + CGFloat(i) * pitch), next = snap(origin + CGFloat(i + 1) * pitch)
                slots.append(.init(x: x, width: max(next - gap - x, 1 / scale), reach: next - x, height: height(size, peak: peak, room: room)))
            }
            let first = slots[0].x, last = slots[slots.count - 1]
            out.groups.append(slots)
            out.spans.append((first, last.x + last.width - first))
            origin += CGFloat(group.count) * pitch - gap + partGap
        }
        return out
    }

    // MARK: The goal, the pages, the reading

    /// The book beside its goal. Both are in words.
    struct Goal: Equatable {
        /// Whole percents, past 100 when the goal is passed.
        let percent: Int
        /// What the bar fills: never more than all of it.
        let fraction: Double
        let left: Int
        let over: Int
    }

    static func goal(words: Int, goal: Int?) -> Goal? {
        guard let goal, goal > 0 else { return nil }
        let share = Double(max(words, 0)) / Double(goal)
        return Goal(percent: Int((share * 100).rounded()), fraction: min(share, 1), left: max(goal - words, 0), over: max(words - goal, 0))
    }

    /// The goal in a line, in two parts: the percentage, which the page sets apart, and the rest of the sentence.
    static func goalLine(_ g: Goal, goal: Int) -> (percent: String, rest: String) {
        let percent = (Double(g.percent) / 100).formatted(.percent.precision(.fractionLength(0)).locale(UILang.locale))
        let rest = if g.over > 0 {
            L("of the goal of \(goal.ui) words · \(CountUnit.words.label(g.over)) over")
        } else if g.left == 0 {
            L("of the goal of \(goal.ui) words · reached")
        } else {
            L("of the goal of \(goal.ui) words · \(CountUnit.words.label(g.left)) left")
        }
        return (percent, rest)
    }

    static func pages(words: Int) -> Int { Int((Double(max(words, 0)) / Double(wordsPerPage)).rounded()) }

    static func readingMinutes(words: Int) -> Int { Int((Double(max(words, 0)) / Double(wordsPerMinute)).rounded()) }

    /// « 4h 31min »: hours and minutes as the interface's language abbreviates them.
    static func reading(minutes: Int, locale: Locale = UILang.locale) -> String {
        let units: Set<Duration.UnitsFormatStyle.Unit> = minutes >= 60 ? [.hours, .minutes] : [.minutes]
        return Duration.seconds(minutes * 60).formatted(.units(allowed: units, width: .narrow).locale(locale))
    }

    // MARK: The days

    /// The days written, from the dates of the book's sittings (its commits).
    struct Days: Equatable {
        /// The seven days of this week, from its first: whether each was written on.
        var week: [Bool]
        /// Which of the seven today is.
        var today: Int
        /// Days in a row up to today; a day not written on yet does not break yesterday's run.
        var streak: Int
        var written: Int { week.filter { $0 }.count }
    }

    static func days(_ dates: [Date], now: Date = Date(), calendar: Calendar = .current) -> Days? {
        guard !dates.isEmpty else { return nil }
        let written = Set(dates.map { calendar.startOfDay(for: $0) })
        let today = calendar.startOfDay(for: now)
        let start = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? today
        let week = (0..<7).map { i in calendar.date(byAdding: .day, value: i, to: start).map { written.contains(calendar.startOfDay(for: $0)) } ?? false }
        var day = written.contains(today) ? today : calendar.date(byAdding: .day, value: -1, to: today) ?? today
        var streak = 0
        while written.contains(day), let before = calendar.date(byAdding: .day, value: -1, to: day) {
            streak += 1
            day = calendar.startOfDay(for: before)
        }
        return Days(week: week, today: calendar.dateComponents([.day], from: start, to: today).day ?? 0, streak: streak)
    }
}
