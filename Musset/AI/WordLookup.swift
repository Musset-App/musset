import Foundation

/// Words around a word, in the sense its sentence gives it, from the right-click menu. Three purposes,
/// each its own question: a word to put in its place, words that sound like it, words to echo it.
/// Asked of the engine set for Settings › AI › Vocabulary.
enum WordLookup {
    enum Kind: CaseIterable {
        case synonyms, homonyms, alliterations

        func title(_ word: String) -> String {
            switch self {
            case .synonyms: L("Synonyms of « \(word) »…")
            case .homonyms: L("Homonyms of « \(word) »…")
            case .alliterations: L("Alliterations on « \(word) »…")
            }
        }

        var heading: String {
            switch self {
            case .synonyms: L("Synonyms")
            case .homonyms: L("Homonyms")
            case .alliterations: L("Alliterations")
            }
        }

        /// Synonyms take the word's place; homonyms and alliterations are copied, to be used elsewhere.
        var replaces: Bool { self == .synonyms }

        fileprivate var ask: String {
            switch self {
            case .synonyms:
                "Up to 10 synonyms, closest first, each in the same form as the word (gender, number, tense), ready to replace it in the passage."
            case .homonyms:
                "Up to 8 homonyms: words that sound the same (homophones) or are spelled the same (homographs) with another meaning, each with its sense."
            case .alliterations:
                "Up to 12 words from the same field of vocabulary as the word, in its sense, that begin with the same sound as the word, for an alliteration in the passage."
            }
        }
    }

    struct Word: Codable, Hashable {
        var word: String
        var sense: String?
    }

    static func prompt(_ kind: Kind, word: String, context: String, lang: String) -> String {
        let french = lang.lowercased().hasPrefix("fr")
        return """
        You help a writer with a word. Language of the book: \(french ? "French" : lang).
        The word: «\(word)»
        Its passage, for its sense:
        \"\"\"
        \(context)
        \"\"\"

        In the book's language, in the sense the passage gives the word: \(kind.ask)
        Words a careful writer could use. An empty list rather than padding. No word from the passage itself, no explanations.

        Reply with JSON only: [{"word": "…", "sense": "…"}]
        "sense": four words at most, a nuance or a register; omit it when it adds nothing.
        """
    }

    static func decode(_ raw: String) -> [Word]? {
        guard let start = raw.firstIndex(of: "["), let end = raw.lastIndex(of: "]"), start < end,
              let data = String(raw[start...end]).data(using: .utf8),
              let words = try? JSONDecoder().decode([Word].self, from: data) else { return nil }
        return words.compactMap { w in
            let word = w.word.trimmingCharacters(in: .whitespaces)
            let sense = w.sense?.trimmingCharacters(in: .whitespaces)
            return word.isEmpty ? nil : Word(word: word, sense: sense?.isEmpty == false ? sense : nil)
        }
    }

    /// The replacement with the replaced word's capital: « Maison » → « Demeure ».
    static func matchingCase(_ replacement: String, of word: String) -> String {
        guard let first = word.first, first.isUppercase, let r = replacement.first, r.isLowercase else { return replacement }
        return r.uppercased() + replacement.dropFirst()
    }

    @MainActor static func lookup(_ kind: Kind, word: String, context: String, lang: String, root: URL) async throws -> [Word] {
        guard let engine = TaskModels.engine(.words) else {
            throw Agents.err(L("No AI engine is on. Turn one on in Settings › AI."))
        }
        let raw = try await Agents.oneShot(engine, prompt: prompt(kind, word: word, context: context, lang: lang),
                                           model: TaskModels.model(.words, for: engine), cwd: root)
        guard let words = decode(raw) else { throw Agents.err(L("The answer could not be read.")) }
        return words
    }
}
