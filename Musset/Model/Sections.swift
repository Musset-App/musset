import Foundation

/// A section of a piece: a `## ` or `### ` sub-heading in its Markdown, in a book that reads them as sections
/// (`BookManifest.textFeatures.subheadings`). The piece's own `# ` title is not one.
struct ChapterSection: Equatable, Identifiable {
    let title: String
    /// 2 or 3.
    let level: Int
    /// The heading's line, without its line end.
    let line: NSRange
    var id: String { "\(line.location)|\(title)" }
}

enum Sections {
    /// `## Title`, `### Title`: beside `Scenes.pattern`, read whenever the scenes are.
    static let pattern = try! NSRegularExpression(pattern: #"^(#{2,3})[ \t]+(\S.*?)[ \t]*$"#, options: [.anchorsMatchLines])
    private static let comments = try! NSRegularExpression(pattern: "<!--.*?-->", options: [.dotMatchesLineSeparators])

    /// The sections of a piece's text (editor or disk form), in its order. Headings inside an author's note are not read.
    static func parse(_ text: String) -> [ChapterSection] {
        // Most pieces have none: no regex pass.
        guard text.contains("## ") || text.contains("##\t") else { return [] }
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        let notes = text.contains("<!--") ? comments.matches(in: text, range: full).map(\.range) : []
        return pattern.matches(in: text, range: full).compactMap { m in
            if notes.contains(where: { NSLocationInRange(m.range.location, $0) }) { return nil }
            var title = ns.substring(with: m.range(at: 2))
            for trailing in [PieceText.headingAttributes, #"\s+#+\s*$"#] {
                if let r = title.range(of: trailing, options: .regularExpression) { title.removeSubrange(r) }
            }
            title = title.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "*_")))
            return title.isEmpty ? nil : ChapterSection(title: title, level: m.range(at: 1).length, line: m.range)
        }
    }

    /// The section holding `location`: the last one that starts at or before it.
    static func section(at location: Int, in sections: [ChapterSection]) -> ChapterSection? {
        sections.last { $0.line.location <= location }
    }
}
