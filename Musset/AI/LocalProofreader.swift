import AppKit
import NaturalLanguage

/// Grammar and spelling checked on this Mac, with no network and no AI: the LanguageTool bundled in Musset,
/// for English, French, German, Spanish, Italian and Portuguese. Its issues are underlined in blue.
enum LocalProofreader {
    /// Which rule-based checker underlines in blue.
    enum Checker: String, CaseIterable, Identifiable {
        case local, languageTool, off
        var id: String { rawValue }
        var label: String {
            switch self {
            case .local: L("LanguageTool, on this Mac")
            case .languageTool: L("Another LanguageTool server")
            case .off: L("Off", ctx: "Désactivé")
            }
        }
    }

    static var checker: Checker { Checker(rawValue: UserDefaults.standard.string(forKey: "ruleChecker") ?? "") ?? .local }

    /// Musset's six languages, when the bundled LanguageTool is there.
    static func supports(_ lang: String) -> Bool { LanguageToolServer.isBundled && Typography.supports(lang) }

    /// Fixes for each paragraph. `words` is the book's dictionary: never flagged as misspelt.
    /// Sentences in another language than the book's are left alone: the book's English dialogue is not bad French.
    static func check(_ paragraphs: [String], lang: String, words: [String]) async throws -> [[ProofFix]] {
        guard supports(lang), !paragraphs.isEmpty else { return paragraphs.map { _ in [] } }
        let server = try await LanguageToolServer.shared.url()
        var starts: [Int] = []
        var offset = 0
        for t in paragraphs { starts.append(offset); offset += (t as NSString).length + 2 }
        let matches = try await LanguageTool.check(paragraphs.joined(separator: "\n\n"), lang: lang, server: server)
        let fixes = LanguageTool.fixes(matches, paragraphs: paragraphs, starts: starts, words: words, lang: lang)
        return zip(paragraphs, fixes).map { text, list in
            let foreign = foreignSentences(in: text, lang: lang)
            return list
                .filter { f in !foreign.contains { NSLocationInRange(f.anchor, $0) } }
        }
    }

    /// Spelling flags on capitalised words are mostly proper names, except in German, where every noun has a capital;
    /// words the author taught the book are never flagged.
    static func keepSpelling(_ word: String, words: [String], lang: String = "fr") -> Bool {
        guard let first = word.first, !first.isUppercase || lang.lowercased().hasPrefix("de") else { return false }
        return !words.contains { $0.lowercased() == word.lowercased() }
    }

    /// Sentences of a paragraph written in another language than the book's: the book's English dialogue is not bad French.
    /// Single words are left alone, too short to tell; short French sentences read as Italian or Portuguese below 0.9.
    static func foreignSentences(in text: String, lang: String = "fr") -> [NSRange] {
        let own = NLLanguage(BookLanguage(code: lang).base)
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var out: [NSRange] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let sentence = String(text[range])
            guard sentence.split(whereSeparator: \.isWhitespace).filter({ $0.contains(where: \.isLetter) }).count >= 2 else { return true }
            let recognizer = NLLanguageRecognizer()
            recognizer.languageConstraints = [.french, .english, .spanish, .italian, .german, .portuguese]
            recognizer.processString(sentence)
            if let language = recognizer.dominantLanguage, language != own,
               (recognizer.languageHypotheses(withMaximum: 1)[language] ?? 0) >= 0.9 {
                out.append(NSRange(range, in: text))
            }
            return true
        }
        return out
    }

    /// The one accepted French spelling that only adds accents or ligatures (« soeur » → « sœur »), or nil.
    /// Words the dictionary knows too many ways (« meme » → même, mème, mémé) stay suggestions.
    static func accentOnly(_ word: String, candidates: [String]) -> String? {
        func letters(_ s: String) -> String {
            s.replacingOccurrences(of: "œ", with: "oe").replacingOccurrences(of: "æ", with: "ae")
                .folding(options: .diacriticInsensitive, locale: Locale(identifier: "fr"))
        }
        let matches = Set(candidates.filter { $0 != word && letters($0) == word })
        return matches.count == 1 ? matches.first : nil
    }

    /// Marks a French spelling fix for automatic correction when it is only an accent or a ligature,
    /// unless the word is English: « the » → « thé », « debit » → « débit » must stay the author's call.
    /// Touches NSSpellChecker: main thread only.
    @MainActor
    static func promotingAccents(_ fix: ProofFix) -> ProofFix {
        guard fix.rule == "FR_SPELLING_RULE", NSSpellChecker.shared.availableLanguages.contains("en"),
              let accented = accentOnly(fix.original, candidates: fix.choices) else { return fix }
        let english = NSSpellChecker.shared.checkSpelling(of: fix.original, startingAt: 0, language: "en", wrap: false, inSpellDocumentWithTag: 0, wordCount: nil)
        guard english.location != NSNotFound else { return fix }
        var promoted = fix
        promoted.replacement = accented
        promoted.alternatives = nil
        promoted.kind = "obvious"
        return promoted
    }
}

extension LocalProofreader {
    /// A fix's reason in the interface's language: LanguageTool names its rule families in the book's language,
    /// which is what the author writes in; Musset's own words go through the tables.
    static func shown(_ reason: String) -> String { L(dynamic: reason) }
}
