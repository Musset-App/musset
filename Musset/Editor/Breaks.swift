import Foundation

/// Return, again and again: a paragraph, then a scene, then a chapter. Each step shows at once and steps back with
/// Backspace (or ⌘Z); only keys typed count, never pasted or imported text, and blank lines already in a book
/// keep the meaning they had.
///
/// - Return on an empty paragraph, after prose: that paragraph becomes a scene marker ("Scène 3"), the caret below it.
/// - Return on the empty paragraph just after a scene marker: the chapter is split there; what follows becomes the
///   next chapter, its title ("Chapitre 8") selected to type over.
enum Breaks {
    enum Step: Equatable {
        /// Insert `marker` at `at` (the empty paragraph's start), followed by a newline.
        case scene(at: Int, marker: String)
        /// Split the chapter: `before` stays, `after` opens a new chapter.
        case chapter(before: String, after: String)
    }

    /// What a Return at `caret` (no selection) does, or nil for an ordinary new paragraph.
    static func onReturn(_ text: String, caret: Int, lang: String, scene: String? = nil) -> Step? {
        let ns = text as NSString
        guard let empty = emptyParagraph(ns, caret), empty.location > 0 else { return nil }
        let previous = ns.paragraphRange(for: NSRange(location: empty.location - 1, length: 0))
        let prevText = ns.substring(with: previous).trimmingCharacters(in: .whitespacesAndNewlines)
        if isMarker(ns, previous) {
            let before = ns.substring(to: previous.location).replacingOccurrences(of: "\\n+$", with: "", options: .regularExpression)
            let after = ns.substring(from: NSMaxRange(empty))
            return .chapter(before: before, after: after)
        }
        // After a heading or a blank line, Return stays a Return.
        guard !prevText.isEmpty, !prevText.hasPrefix("#") else { return nil }
        let n = Scenes.parse(ns.substring(to: empty.location)).count + 1
        // The book's own word for the level (« Section 3 ») when it has one; else « Scène 3 » in the book's language.
        let title = scene.map { $0 + " \(n)" } ?? BookTerm.sceneNumber.in(lang).replacingOccurrences(of: "{n}", with: "\(n)")
        return .scene(at: empty.location, marker: Scenes.markerLine(title))
    }

    /// Backspace at the start of the empty paragraph below a scene marker removes the marker: the range to delete.
    static func onBackspace(_ text: String, caret: Int) -> NSRange? {
        let ns = text as NSString
        guard let empty = emptyParagraph(ns, caret), empty.location > 0, caret == empty.location else { return nil }
        let previous = ns.paragraphRange(for: NSRange(location: empty.location - 1, length: 0))
        return isMarker(ns, previous) ? previous : nil
    }

    /// The new chapter's title, in the book's language: "Chapitre 8".
    static func chapterTitle(_ number: Int, lang: String) -> String {
        BookTerm.chapterNumber.in(lang).replacingOccurrences(of: "{n}", with: "\(number)")
    }

    /// The paragraph holding the caret, if it holds nothing but spaces.
    private static func emptyParagraph(_ ns: NSString, _ caret: Int) -> NSRange? {
        guard caret >= 0, caret <= ns.length else { return nil }
        let p = ns.paragraphRange(for: NSRange(location: caret, length: 0))
        let content = ns.substring(with: p).trimmingCharacters(in: .whitespaces)
        return content.isEmpty || content == "\n" ? p : nil
    }

    private static func isMarker(_ ns: NSString, _ r: NSRange) -> Bool {
        Scenes.pattern.firstMatch(in: ns as String, range: r) != nil
    }
}
