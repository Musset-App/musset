import Foundation

/// What the board of scenes shows of a chapter's text: how it opens, how it closes, and the first lines of each of
/// its scenes. Plain text as the author wrote it, scene markers, other comments, a reviewer's marks and the chapter's
/// heading left out.
struct ChapterExcerpt: Equatable {
    var opening = ""
    /// Empty when the chapter is short enough for its opening to hold all of it: the text is shown once.
    var closing = ""
    /// In the chapter's order, as `Scenes.parse` counts them.
    var scenes: [String] = []
}

enum SceneExcerpts {
    /// How many characters of each are kept: more than a card shows at its largest, little enough to stay cheap.
    static let opening = 320
    static let closing = 260
    static let scene = 240

    static func excerpt(of text: String, opening: Int = opening, closing: Int = closing, scene: Int = scene) -> ChapterExcerpt {
        let all = prose(text, skipHeadings: true)
        let head = head(all, opening)
        let ns = text as NSString
        let scenes = Scenes.parse(text).map { s -> String in
            let start = s.marker.map { NSMaxRange(ns.lineRange(for: $0)) } ?? s.range.location
            // Its first lines are in its first characters: the rest of a long scene is not read.
            let length = min(max(NSMaxRange(s.range) - start, 0), scene * 6 + 400)
            return self.head(prose(ns.substring(with: NSRange(location: start, length: length)), skipHeadings: s.marker == nil), scene).text
        }
        return ChapterExcerpt(opening: head.text, closing: tail(head.rest, closing), scenes: scenes)
    }

    /// The paragraphs of a text, one per line: comments (scene markers among them) taken out, blank lines dropped,
    /// and the headings it starts with, which the card already shows as the chapter's title.
    static func prose(_ text: String, skipHeadings: Bool) -> String {
        // A reviewer's pending corrections and comments are not the text yet: the author's words are shown.
        var lines = BookStore.stripHTMLComments(Revisions.resolveAll(text, accept: false)).split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if skipHeadings { lines.removeFirst(lines.prefix { $0.hasPrefix("#") }.count) }
        return lines.joined(separator: "\n")
    }

    /// The first `budget` characters, cut back to the end of a word, and what is left after them.
    static func head(_ text: String, _ budget: Int) -> (text: String, rest: Substring) {
        guard text.count > budget else { return (text, "") }
        let limit = text.index(text.startIndex, offsetBy: budget)
        let cut = text[..<limit].lastIndex(where: \.isWhitespace) ?? limit
        return (text[..<cut].trimmingCharacters(in: .whitespacesAndNewlines) + "…", text[cut...])
    }

    /// The last `budget` characters, from the start of a word; an ellipsis says a paragraph was cut into.
    static func tail(_ text: Substring, _ budget: Int) -> String {
        guard text.count > budget else { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        let from = text.index(text.endIndex, offsetBy: -budget)
        guard let cut = text[from...].firstIndex(where: \.isWhitespace) else { return "…" + text[from...] }
        let kept = text[cut...].trimmingCharacters(in: .whitespacesAndNewlines)
        return text[cut].isNewline ? kept : "… " + kept
    }

    /// The share of the chapter each scene takes, for the ticks under its card: by its words, and never nothing,
    /// so an empty scene still has its tick.
    static func ticks(_ scenes: [ChapterScene]) -> [Double] {
        let weights = scenes.map { Double(max($0.words, 1)) }
        let total = weights.reduce(0, +)
        return weights.map { $0 / total }
    }

    /// What tells a chapter's text apart from what it was, without reading it: its scenes as the session keeps them
    /// (each one's place, length, title and the fingerprint of its text).
    static func mark(_ scenes: [ChapterScene]) -> Int {
        var h = Hasher()
        for s in scenes {
            h.combine(s.range.location)
            h.combine(s.range.length)
            h.combine(s.title)
            h.combine(s.body)
        }
        return h.finalize()
    }
}

/// The book as the board of scenes lays it out: its chapters in order, in runs that share a part.
struct ScenesBand: Identifiable {
    /// Nil for chapters in no part: the whole book when it has none.
    let part: BookPart?
    /// Each chapter with its place in the book.
    var chapters: [(entry: ChapterEntry, index: Int)]
    var id: String { (part?.id ?? "") + "@\(chapters.first?.index ?? 0)" }
}

extension BookManifest {
    var scenesBands: [ScenesBand] {
        var out: [ScenesBand] = []
        for (i, ch) in chapters.enumerated() {
            let part = group(of: ch)
            if let last = out.indices.last, out[last].part?.id == part?.id {
                out[last].chapters.append((ch, i))
            } else {
                out.append(ScenesBand(part: part, chapters: [(ch, i)]))
            }
        }
        return out
    }

    /// The bands when one strand is read alone: its chapters only, and no band for a part that holds none of them.
    /// Nil is the whole book.
    func scenesBands(strand: String?) -> [ScenesBand] {
        guard let strand else { return scenesBands }
        return scenesBands.compactMap { band in
            let kept = band.chapters.filter { $0.entry.strand == strand }
            return kept.isEmpty ? nil : ScenesBand(part: band.part, chapters: kept)
        }
    }

    /// The chapters the board holds, in the book's order: all of them, or one part's, or one strand's, or both.
    func boardChapters(part: String? = nil, strand: String? = nil) -> [(entry: ChapterEntry, index: Int)] {
        chapters.enumerated().filter { (part == nil || $0.element.part == part) && (strand == nil || $0.element.strand == strand) }
            .map { (entry: $0.element, index: $0.offset) }
    }

    /// The part a chapter is in, if it is in one that still exists.
    func part(of chapterID: String) -> BookPart? {
        chapters.first { $0.id == chapterID }.flatMap(group(of:))
    }

    /// Whether the board of scenes has a part level to offer.
    var hasPartsInUse: Bool { chapters.contains { group(of: $0) != nil } }
}
