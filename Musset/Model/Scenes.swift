import Foundation

/// A scene of a chapter. Scenes are marked in the chapter's Markdown by `<!-- scene: Title -->` on its own line,
/// at the start of the scene; the marker never reaches the page. A chapter without markers is one scene.
struct ChapterScene: Equatable, Identifiable {
    /// Title from the marker; nil for the whole chapter (no markers) or the text before the first marker.
    let title: String?
    /// The marker line, if any.
    let marker: NSRange?
    /// The scene, from its marker (or the chapter start) to the next marker.
    let range: NSRange
    /// Its length in the three units, the marker line left out.
    let counts: TextCounts
    var words: Int { counts.words }
    /// A fingerprint of its text without the marker line: what tells it apart from its neighbours once renamed.
    var body: UInt64 = 0
    /// The key its plot row is still under, when a rename could not take the row along yet (the new title is
    /// another scene's for now): see `PlotGrid.follow`.
    var heldRow: String? = nil

    /// Key of the scene in the plot grid: its title, "" for an untitled scene.
    var key: String { heldRow ?? title ?? "" }
    var id: String { key + "@\(range.location)" }
}

enum Scenes {
    /// `<!-- scene: Title -->` (also « scène »), alone on its line.
    static let pattern = try! NSRegularExpression(pattern: #"^[ \t]*<!--[ \t]*sc[eè]ne[ \t]*:[ \t]*(.*?)[ \t]*-->[ \t]*$"#,
                                                  options: [.anchorsMatchLines, .caseInsensitive])

    static func markerLine(_ title: String) -> String { "<!-- scene: \(title) -->" }

    /// The scenes of a chapter's text (editor or disk form). Text before the first marker counts as an untitled scene
    /// only when it holds more than a heading.
    static func parse(_ text: String) -> [ChapterScene] {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        let markers = pattern.matches(in: text, range: full)
        guard !markers.isEmpty else { return [ChapterScene(title: nil, marker: nil, range: full, counts: TextCounts(text), body: fingerprint(ns, full))] }
        var out: [ChapterScene] = []
        let lead = NSRange(location: 0, length: markers[0].range.location)
        let leadText = ns.substring(with: lead)
        let leadProse = leadText.components(separatedBy: .newlines).filter { !$0.hasPrefix("#") }.joined(separator: "\n")
        let leadCounts = TextCounts(leadProse)
        if leadCounts.words > 0 { out.append(ChapterScene(title: nil, marker: nil, range: lead, counts: leadCounts, body: fingerprint(ns, lead))) }
        for (i, m) in markers.enumerated() {
            let start = m.range.location
            let end = i + 1 < markers.count ? markers[i + 1].range.location : ns.length
            let r = NSRange(location: start, length: end - start)
            let title = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
            out.append(ChapterScene(title: title.isEmpty ? nil : title, marker: m.range, range: r, counts: TextCounts(ns.substring(with: r)),
                                    body: fingerprint(ns, NSRange(location: NSMaxRange(m.range), length: end - NSMaxRange(m.range)))))
        }
        return out
    }

    /// A fingerprint of a stretch of text, its spacing aside (FNV-1a over its UTF-16).
    private static func fingerprint(_ ns: NSString, _ range: NSRange) -> UInt64 {
        var units = [unichar](repeating: 0, count: range.length)
        ns.getCharacters(&units, range: range)
        var h: UInt64 = 0xcbf29ce484222325
        for u in units where u != 0x20 && u != 0x0A && u != 0x09 && u != 0x0D { h = (h ^ UInt64(u)) &* 0x100000001b3 }
        return h
    }

    /// Where the prose of a chapter starts, after its heading lines.
    private static func proseStart(_ ns: NSString) -> Int {
        var at = 0
        while at < ns.length {
            let line = ns.lineRange(for: NSRange(location: at, length: 0))
            let t = ns.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard t.isEmpty || t.hasPrefix("#") else { break }
            at = NSMaxRange(line)
        }
        return at
    }

    /// Takes one scene out of a chapter. A scene without a marker (the opening) gets one: it can't be told apart otherwise.
    static func extract(_ index: Int, from text: String, openingTitle: String) -> (rest: String, block: String, title: String)? {
        let scenes = parse(text)
        guard scenes.indices.contains(index) else { return nil }
        let s = scenes[index], ns = text as NSString
        var r = s.range
        if s.marker == nil {
            let start = min(proseStart(ns), NSMaxRange(r))
            r = NSRange(location: start, length: NSMaxRange(r) - start)
        }
        var block = ns.substring(with: r)
        if !block.hasSuffix("\n") { block += "\n" }
        let title = s.title ?? openingTitle
        if s.marker == nil { block = markerLine(title) + "\n" + block }
        return (ns.replacingCharacters(in: r, with: ""), block, title)
    }

    /// Puts a block before the scene at `index` (at the end if there is none). An opening that would no longer
    /// come first gets a marker, or the block would swallow it. Returns that title, for its plot row.
    static func insert(_ block: String, into text: String, at index: Int, openingTitle: String) -> (text: String, markedOpening: String?) {
        let scenes = parse(text)
        let ns = text as NSString
        guard index < scenes.count else {
            let glue = text.isEmpty || text.hasSuffix("\n") ? "" : "\n"
            return (text + glue + block, nil)
        }
        let s = scenes[index]
        if s.marker == nil {
            let at = min(proseStart(ns), ns.length)
            // Only a heading so far: nothing to mark.
            if at == ns.length {
                let glue = text.isEmpty || text.hasSuffix("\n") ? "" : "\n"
                return (text + glue + block, nil)
            }
            return (ns.replacingCharacters(in: NSRange(location: at, length: 0), with: block + markerLine(openingTitle) + "\n"), openingTitle)
        }
        return (ns.replacingCharacters(in: NSRange(location: s.range.location, length: 0), with: block), nil)
    }

    /// The chapter with one scene moved before the scene now at `slot` (0…count). Nil when it wouldn't move.
    static func moved(_ from: Int, to slot: Int, in text: String, openingTitle: String) -> (text: String, opening: String?)? {
        guard slot != from, slot != from + 1, let cut = extract(from, from: text, openingTitle: openingTitle) else { return nil }
        let wasOpening = parse(text)[from].marker == nil
        let put = insert(cut.block, into: cut.rest, at: slot > from ? slot - 1 : slot, openingTitle: openingTitle)
        var out = put.text
        if !text.hasSuffix("\n"), out.hasSuffix("\n") { out.removeLast() }
        return (out, wasOpening ? cut.title : put.markedOpening)
    }

    /// The edit that renames the scene at `index`: its marker line rewritten, or a marker put before the opening,
    /// which had none.
    static func renaming(_ index: Int, to title: String, in text: String) -> (range: NSRange, with: String)? {
        let scenes = parse(text)
        guard scenes.indices.contains(index) else { return nil }
        if let marker = scenes[index].marker { return (marker, markerLine(title)) }
        let ns = text as NSString
        return (NSRange(location: min(proseStart(ns), ns.length), length: 0), markerLine(title) + "\n")
    }

    /// The chapter with a new scene starting at the paragraph that holds `location`: a marker put before it. Nil
    /// where a scene already starts, in the chapter's heading or on a marker: a scene would be left without text.
    /// An opening without a marker stays one, as in `insert`: it still comes first.
    static func split(_ text: String, at location: Int, title: String) -> String? {
        let ns = text as NSString
        guard location >= 0, location <= ns.length else { return nil }
        let at = ns.lineRange(for: NSRange(location: location, length: 0)).location
        guard let scene = scene(at: at, in: parse(text)) else { return nil }
        let start = scene.marker.map { NSMaxRange(ns.lineRange(for: $0)) } ?? min(proseStart(ns), ns.length)
        let end = NSMaxRange(scene.range)
        func blank(_ from: Int, _ to: Int) -> Bool {
            to <= from || ns.substring(with: NSRange(location: from, length: to - from)).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard at > start, !blank(start, at), !blank(at, end) else { return nil }
        return ns.replacingCharacters(in: NSRange(location: at, length: 0), with: markerLine(title) + "\n")
    }

    /// The chapter with the scene at `index` and the next one made one: the next one's marker line goes, its text
    /// stays, under this scene's title. Nil for the last scene.
    static func merged(_ index: Int, in text: String) -> String? {
        let scenes = parse(text)
        guard index >= 0, scenes.indices.contains(index + 1), let marker = scenes[index + 1].marker else { return nil }
        let ns = text as NSString
        return ns.replacingCharacters(in: ns.lineRange(for: marker), with: "")
    }

    /// The scene holding `location`.
    static func scene(at location: Int, in scenes: [ChapterScene]) -> ChapterScene? {
        scenes.last { $0.range.location <= location } ?? scenes.first
    }
}
