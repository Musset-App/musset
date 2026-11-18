import Foundation

extension StringProtocol {
    /// Without case or accents: what two spellings of a word have in common.
    var folded: String { folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }

    /// Its words in lower case and without accents, joined: a file name, an id, a git ref. `words`: no more than so many.
    /// Empty when it has neither letter nor digit: the caller says what stands for it then.
    func slug(_ separator: String = "-", words: Int? = nil) -> String {
        let parts = lowercased().folding(options: .diacriticInsensitive, locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        return parts.prefix(words ?? parts.count).joined(separator: separator)
    }
}

/// Folded forms for matching, each for what is matched.
enum Fold {
    /// A name (a character, a place, a scene's title): case, accents, leading article and spacing ignored.
    static func name(_ s: String) -> String {
        var t = s.folded.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        for article in ["le ", "la ", "les ", "l'", "l’", "un ", "une ", "des ", "the ", "a "] where t.hasPrefix(article) {
            t = String(t.dropFirst(article.count)); break
        }
        return t.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Prose searched for a passage: case and accents don't matter, quotes and spaces are one.
    static func search(_ s: String) -> String {
        s.folded.replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "\u{00A0}", with: " ").replacingOccurrences(of: "\u{202F}", with: " ")
    }
}
