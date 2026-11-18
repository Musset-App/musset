import XCTest
@testable import Musset

/// Prints the tiers the app computes for a copy of a book (MUSSET_TIERS_BOOK=<copy>). Never the original.
@MainActor
final class TierProbe: XCTestCase {
    func testTiers() async throws {
        guard let path = ProcessInfo.processInfo.environment["MUSSET_TIERS_BOOK"] else { throw XCTSkip("set MUSSET_TIERS_BOOK") }
        let root = URL(fileURLWithPath: path)
        let m = try XCTUnwrap(BookStore(root: root).loadManifest())
        let s = BookSession(root: root, manifest: m)
        for _ in 0..<300 where s.bible.writtenChapters == 0 { try await Task.sleep(for: .milliseconds(20)) }
        print("PROBE written", s.bible.writtenChapters)
        for e in s.bible.entries where e.kind == .character {
            let per = s.bible.occurrences[e.path] ?? [:]
            print("PROBE sheet", e.title, s.bible.tier(of: e).rawValue, per.count, per.values.reduce(0) { $0 + $1.count }, e.names)
        }
        for t in s.bible.tagsWithoutSheet(s.plot) {
            let per = s.bible.tagOccurrences[t.name] ?? [:]
            print("PROBE tag", t.name, s.bible.tier(of: t).rawValue, per.count, per.values.reduce(0, +))
        }
    }
}
