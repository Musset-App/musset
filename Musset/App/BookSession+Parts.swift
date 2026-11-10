import Foundation

/// A part of the book: I, II, III… with an optional title. Its chapters are the ones that name it, one run in the book's order.
struct BookPart: Codable, Equatable, Identifiable, Hashable {
    var id: String = UUID().uuidString
    var title: String = ""
}

extension BookManifest {
    /// Parts in the book's order: by where their first chapter stands, empty ones last.
    var orderedParts: [BookPart] {
        let all = parts ?? []
        var seen: [String] = []
        for ch in chapters { if let p = ch.part, !seen.contains(p), all.contains(where: { $0.id == p }) { seen.append(p) } }
        return seen.compactMap { id in all.first { $0.id == id } } + all.filter { !seen.contains($0.id) }
    }

    func numeral(of part: String) -> String {
        Self.roman((orderedParts.firstIndex { $0.id == part } ?? 0) + 1)
    }

    /// « II » or « II. La fuite ».
    func label(of part: BookPart) -> String {
        part.title.isEmpty ? numeral(of: part.id) : numeral(of: part.id) + ". " + part.title
    }

    /// Where each part begins among the chapters that print: the chapter id, with the part's numeral and title.
    var partOpenings: [String: (numeral: String, title: String)] {
        var out: [String: (String, String)] = [:]
        var previous: String?
        for ch in chapters where !ch.excludeFromExport {
            if let p = ch.part, p != previous, let part = parts?.first(where: { $0.id == p }) {
                out[ch.id] = (numeral(of: p), part.title)
            }
            previous = ch.part
        }
        return out
    }

    static func roman(_ n: Int) -> String {
        guard n > 0 else { return "" }
        let table: [(Int, String)] = [(1000, "M"), (900, "CM"), (500, "D"), (400, "CD"), (100, "C"), (90, "XC"),
                                      (50, "L"), (40, "XL"), (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I")]
        var n = n, out = ""
        for (value, letters) in table { while n >= value { out += letters; n -= value } }
        return out
    }
}

extension BookSession {
    /// A new part from this chapter on: it takes the chapter and those after it that were in the same place
    /// (the rest of its part, or the loose chapters that follow). Right-click chapter 1, then chapter 8: I and II.
    @discardableResult
    func newPart(startingAt chapterID: String, title: String = "") -> String? {
        guard let i = manifest.chapters.firstIndex(where: { $0.id == chapterID }) else { return nil }
        let old = manifest.chapters[i].part
        let part = BookPart(title: title)
        manifest.parts = (manifest.parts ?? []) + [part]
        var j = i
        while j < manifest.chapters.count, manifest.chapters[j].part == old {
            manifest.chapters[j].part = part.id
            j += 1
        }
        saveManifest()
        commitNow("musset: nouvelle partie")
        return part.id
    }

    func renamePart(_ id: String, to title: String) {
        guard let i = manifest.parts?.firstIndex(where: { $0.id == id }) else { return }
        manifest.parts?[i].title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        saveManifest()
        commitNow("musset: partie renommée")
    }

    /// The part goes; its chapters stay where they are, outside any part.
    func deletePart(_ id: String) {
        manifest.parts?.removeAll { $0.id == id }
        if manifest.parts?.isEmpty == true { manifest.parts = nil }
        for i in manifest.chapters.indices where manifest.chapters[i].part == id { manifest.chapters[i].part = nil }
        saveManifest()
        commitNow("musset: partie supprimée")
    }

    /// Into a part, at the end of it; out of any part (nil), just after the part it leaves. A part stays one run.
    func movePart(of chapterID: String, to part: String?) {
        guard let i = manifest.chapters.firstIndex(where: { $0.id == chapterID }), manifest.chapters[i].part != part else { return }
        var entry = manifest.chapters.remove(at: i)
        let anchor = part ?? entry.part
        entry.part = part
        let end = manifest.chapters.lastIndex { $0.part == anchor }.map { $0 + 1 } ?? min(i, manifest.chapters.count)
        manifest.chapters.insert(entry, at: end)
        saveManifest()
        commitNow(part == nil ? "musset: \(chapterID) hors partie" : "musset: \(chapterID) dans une partie")
    }

    /// Sets a chapter's part where it already stands (a drop chose the place).
    func putInPart(_ chapterID: String, _ part: String?) {
        guard let i = manifest.chapters.firstIndex(where: { $0.id == chapterID }), manifest.chapters[i].part != part,
              part == nil || manifest.parts?.contains(where: { $0.id == part }) == true else { return }
        manifest.chapters[i].part = part
        saveManifest()
        commitNow("musset: \(chapterID) change de partie")
    }
}
