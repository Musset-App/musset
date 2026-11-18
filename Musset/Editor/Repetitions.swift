import Foundation

/// Repeated words in a chapter, computed locally: accents and capitals ignored, close forms grouped
/// (« regardais », « regardait », « regarder »), small grammatical words skipped. Shows, never corrects.
struct RepetitionAnalysis {
    struct Word {
        let range: NSRange
        let stem: String
        /// Position among all words of the text (stopwords included), used for distances.
        let ordinal: Int
    }

    struct Occurrence {
        let range: NSRange
        let stem: String
        /// 1 when the same word comes right after, falling to 0 at the window's edge.
        let strength: Double
    }

    struct Count: Identifiable, Equatable {
        var id: String { stem }
        let stem: String
        /// The form used most often, shown in the list.
        let display: String
        let count: Int
        /// Occurrences with another one closer than the window.
        let close: Int
    }

    var words: [Word] = []
    var close: [Occurrence] = []
    var counts: [Count] = []

    /// The same analysis after an edit, until the chapter is counted again: what came before the edit stays, what
    /// came after moves with it, the words under it are left out.
    func moved(by edit: (range: NSRange, delta: Int)) -> RepetitionAnalysis {
        let oldEnd = NSMaxRange(edit.range) - edit.delta
        func moved(_ r: NSRange) -> NSRange? {
            if NSMaxRange(r) <= edit.range.location { return r }
            if r.location >= oldEnd { return NSRange(location: r.location + edit.delta, length: r.length) }
            return nil
        }
        var out = self
        out.words = words.compactMap { w in moved(w.range).map { Word(range: $0, stem: w.stem, ordinal: w.ordinal) } }
        out.close = close.compactMap { o in moved(o.range).map { Occurrence(range: $0, stem: o.stem, strength: o.strength) } }
        return out
    }

    func occurrences(of stem: String) -> [NSRange] {
        words.filter { $0.stem == stem }.map(\.range)
    }

    /// The counted word at a character offset, if any.
    func word(at offset: Int) -> Word? {
        var lo = 0, hi = words.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            let r = words[mid].range
            if offset < r.location { hi = mid - 1 }
            else if offset >= NSMaxRange(r) { lo = mid + 1 }
            else { return words[mid] }
        }
        return nil
    }
}

enum Repetitions {
    private static let wordRegex = try! NSRegularExpression(pattern: #"[\p{L}\p{M}\p{N}]+"#)
    private static let skipRegex = try! NSRegularExpression(pattern: #"<!--.*?-->|^#{1,6}[ \t][^\n]*"#, options: [.dotMatchesLineSeparators, .anchorsMatchLines])

    static func analyze(_ text: String, lang: String, window: Int) -> RepetitionAnalysis {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        let french = !lang.lowercased().hasPrefix("en")
        let stop = french ? stopFR : stopEN
        // Author's notes and headings don't count.
        let skipped = skipRegex.matches(in: text, range: full).map(\.range)

        var analysis = RepetitionAnalysis()
        var surface: [String: [String: Int]] = [:]
        var ordinal = 0
        var skipIndex = 0
        for m in wordRegex.matches(in: text, range: full) {
            let r = m.range
            while skipIndex < skipped.count && NSMaxRange(skipped[skipIndex]) <= r.location { skipIndex += 1 }
            if skipIndex < skipped.count && skipped[skipIndex].location <= r.location { continue }
            ordinal += 1
            let lower = ns.substring(with: r).lowercased()
            let folded = lower.folding(options: .diacriticInsensitive, locale: nil)
            guard folded.count >= 3, !stop.contains(folded), !folded.allSatisfy(\.isNumber) else { continue }
            let s = stem(folded, french: french)
            analysis.words.append(.init(range: r, stem: s, ordinal: ordinal))
            surface[s, default: [:]][lower, default: 0] += 1
        }

        // Nearest same-stem neighbour of every word.
        var last: [String: Int] = [:]
        var nearest = Array(repeating: Int.max, count: analysis.words.count)
        for (i, w) in analysis.words.enumerated() {
            if let j = last[w.stem] {
                let d = w.ordinal - analysis.words[j].ordinal
                nearest[i] = min(nearest[i], d)
                nearest[j] = min(nearest[j], d)
            }
            last[w.stem] = i
        }
        var closeCount: [String: Int] = [:]
        var total: [String: Int] = [:]
        for (i, w) in analysis.words.enumerated() {
            total[w.stem, default: 0] += 1
            guard nearest[i] <= window else { continue }
            closeCount[w.stem, default: 0] += 1
            let strength = 1 - Double(nearest[i] - 1) / Double(max(window, 1))
            analysis.close.append(.init(range: w.range, stem: w.stem, strength: max(0.05, strength)))
        }
        analysis.counts = total.compactMap { stem, n in
            guard n >= 3 || (closeCount[stem] ?? 0) > 0 else { return nil }
            let display = surface[stem]?.max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }?.key ?? stem
            return RepetitionAnalysis.Count(stem: stem, display: display, count: n, close: closeCount[stem] ?? 0)
        }
        .sorted { ($0.close, $0.count, $1.display) > ($1.close, $1.count, $0.display) }
        return analysis
    }

    /// Light stemmer: strips one inflection suffix, keeping at least four letters, so related forms group
    /// without merging unrelated words (« mère » stays apart from « mer »).
    static func stem(_ w: String, french: Bool) -> String {
        let suffixes = french ? frenchSuffixes : englishSuffixes
        for suf in suffixes where w.hasSuffix(suf) && w.count - suf.count >= 4 {
            return String(w.dropLast(suf.count))
        }
        return w
    }

    private static let frenchSuffixes = ["eraient", "issaient", "issions", "eriez", "erions", "aient", "erait", "erais", "erons", "eront",
                                         "issait", "issant", "ions", "iez", "ons", "ais", "ait", "ant", "ent", "ees", "ee", "es", "er", "ez",
                                         "e", "s", "x"]
    private static let englishSuffixes = ["ingly", "edly", "ing", "ed", "es", "ly", "s"]

    /// Folded (no accents), at least three letters: shorter words are never counted anyway.
    static let stopFR: Set<String> = [
        "les", "des", "une", "aux", "que", "qui", "quoi", "dont", "mais", "donc", "car", "cet", "cette", "ces", "cela", "ceci", "ceux", "celle", "celles", "celui",
        "son", "sa", "ses", "mon", "mes", "ton", "tes", "notre", "nos", "votre", "vos", "leur", "leurs", "moi", "toi", "lui", "eux", "elle", "elles",
        "nous", "vous", "ils", "pas", "plus", "moins", "tres", "trop", "peu", "bien", "tout", "tous", "toute", "toutes", "rien", "sans", "avec", "pour",
        "par", "sur", "sous", "dans", "chez", "vers", "entre", "comme", "quand", "alors", "aussi", "encore", "deja", "meme", "memes", "puis", "ainsi",
        "etre", "est", "etait", "etaient", "ete", "suis", "sont", "sera", "serait", "seront", "soit", "fut", "avoir", "avait", "avaient", "avons", "avez",
        "ont", "aura", "aurait", "eut", "avais", "avions", "aviez", "aurai", "aurais", "auraient", "eurent", "etais", "etions", "etiez", "serai", "serais", "seraient", "furent", "fus", "sommes", "etes", "va", "vais", "allait", "faut", "fallait", "fait", "faire", "faisait", "dit", "dire", "ici", "oui", "non", "qu", "lorsque", "parce", "jamais", "toujours",
        "autre", "autres", "quelque", "quelques", "chaque", "apres", "avant", "depuis", "pendant", "contre", "selon", "peut", "etc", "quel", "quelle",
        "quels", "quelles", "lequel", "laquelle", "lesquels", "ou", "une", "uns", "unes", "sinon", "cependant", "pourtant", "tant", "tel", "telle",
    ]
    static let stopEN: Set<String> = [
        "the", "and", "for", "with", "from", "was", "were", "been", "being", "are", "have", "has", "had", "did", "does", "not", "but", "then", "than",
        "that", "this", "these", "those", "its", "she", "they", "them", "his", "her", "hers", "their", "our", "you", "your", "who", "whom", "which",
        "what", "when", "where", "there", "here", "very", "just", "also", "into", "out", "over", "about", "after", "before", "again", "more", "most",
        "some", "any", "all", "can", "could", "would", "should", "will", "shall", "may", "might", "must", "one", "him", "said", "like", "only",
        "now", "how", "why", "too", "yes", "off", "upon", "each", "such", "own", "other", "even", "still", "ever", "never",
    ]
}
