import Foundation

struct ProofFix: Identifiable, Hashable, Codable {
    var id = UUID()
    var original: String
    var replacement: String
    var reason: String
    /// "obvious" fixes are applied automatically; anything else is only suggested.
    var kind: String? = nil
    /// Search starts here so repeated words resolve to the right occurrence.
    var anchor: Int = 0
    /// Other candidate replacements (LanguageTool gives several).
    var alternatives: [String]? = nil
    /// "lt" for LanguageTool, "gc" for Grammalecte, "harper" for Harper; nil for the AI proofreader.
    var source: String? = nil
    /// One-sentence explanation of the rule, shown when hovering the underline.
    var message: String? = nil
    /// Rule id from the rule-based checker, so a rule can be switched off for the book.
    var rule: String? = nil

    enum CodingKeys: String, CodingKey { case original, replacement, reason, kind, anchor, alternatives, source, message, rule }

    init(original: String, replacement: String, reason: String, kind: String? = nil, anchor: Int = 0,
         alternatives: [String]? = nil, source: String? = nil, message: String? = nil, rule: String? = nil) {
        self.original = original; self.replacement = replacement; self.reason = reason
        self.kind = kind; self.anchor = anchor; self.alternatives = alternatives; self.source = source
        self.message = message; self.rule = rule
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        original = try c.decode(String.self, forKey: .original)
        replacement = try c.decode(String.self, forKey: .replacement)
        reason = try c.decodeIfPresent(String.self, forKey: .reason) ?? ""
        kind = try c.decodeIfPresent(String.self, forKey: .kind)
        anchor = try c.decodeIfPresent(Int.self, forKey: .anchor) ?? 0
        alternatives = try c.decodeIfPresent([String].self, forKey: .alternatives)
        source = try c.decodeIfPresent(String.self, forKey: .source)
        message = try c.decodeIfPresent(String.self, forKey: .message)
        rule = try c.decodeIfPresent(String.self, forKey: .rule)
    }

    /// Words of `original` that the fix changes: what "Add to dictionary" would learn.
    var changedWords: [String] {
        let after = Set(Self.words(in: replacement).map { $0.lowercased() })
        return Self.words(in: original).filter { !after.contains($0.lowercased()) }
    }

    static func words(in s: String) -> [String] {
        s.split { !($0.isLetter || $0.isNumber || $0 == "-") }.map(String.init).filter { !$0.isEmpty }
    }

    var isObvious: Bool { kind == "obvious" }
    /// From a rule-based checker (LanguageTool; Grammalecte and Harper in older caches): underlined in blue, never applied automatically.
    var isLanguageTool: Bool { checkerName != nil }
    var checkerName: String? {
        switch source {
        case "lt": "LanguageTool"
        case "gc": "Grammalecte"
        case "harper": "Harper"
        default: nil
        }
    }
    /// Every replacement to offer, best first.
    var choices: [String] { [replacement] + (alternatives ?? []).filter { $0 != replacement } }
    var ignoreKey: String { "\(original)→\(replacement)" }

    /// Finds `original` in the text, tolerating the typography models flatten:
    /// curly vs straight apostrophes and quotes, non-breaking vs plain spaces.
    func locate(in s: NSString) -> NSRange {
        guard let re = Self.tolerantRegex(original) else { return NSRange(location: NSNotFound, length: 0) }
        let start = min(max(0, anchor), s.length)
        if let m = re.firstMatch(in: s as String, range: NSRange(location: start, length: s.length - start)) { return m.range }
        return re.firstMatch(in: s as String, range: NSRange(location: 0, length: s.length))?.range ?? NSRange(location: NSNotFound, length: 0)
    }

    /// True when `range` of `s` still holds exactly `original` (checked right before replacing).
    func matches(_ s: NSString, at range: NSRange) -> Bool {
        guard NSMaxRange(range) <= s.length, let re = Self.tolerantRegex(original) else { return false }
        return re.firstMatch(in: s as String, options: .anchored, range: range)?.range == range
    }

    /// Whole words only: "nou" must not match inside "nous".
    static func tolerantRegex(_ text: String, wholeWords: Bool = true) -> NSRegularExpression? {
        var pattern = ""
        if wholeWords, text.first.map({ $0.isLetter || $0.isNumber }) == true { pattern += "(?<![\\p{L}\\p{N}])" }
        for ch in text {
            switch ch {
            case "'", "’", "‘", "ʼ": pattern += "['’‘ʼ]"
            case "\"", "“", "”": pattern += "[\"“”]"
            case " ", "\u{00A0}", "\u{202F}": pattern += "[ \\u00A0\\u202F]+"
            default: pattern += NSRegularExpression.escapedPattern(for: String(ch))
            }
        }
        if wholeWords, text.last.map({ $0.isLetter || $0.isNumber }) == true { pattern += "(?![\\p{L}\\p{N}])" }
        return try? NSRegularExpression(pattern: pattern)
    }

    /// The replacement written in the surrounding text's typography (curly apostrophes, non-breaking spaces).
    func adapted(to context: String) -> String {
        var out = replacement
        if context.contains("’") { out = out.replacingOccurrences(of: "'", with: "’") }
        for nbsp in ["\u{00A0}", "\u{202F}"] where context.contains(nbsp) {
            for mark in [";", ":", "!", "?", "»"] { out = out.replacingOccurrences(of: " \(mark)", with: "\(nbsp)\(mark)") }
            out = out.replacingOccurrences(of: "« ", with: "«\(nbsp)")
        }
        return out
    }
}

/// Typo/grammar pass through Haiku (claude CLI) or a fast Codex model.
/// A selection is checked as is; otherwise the whole chapter, in paragraph chunks run in parallel.
enum Proofreader {
    static func prompt(text: String, lang: String, dictionary: [String] = [], people: String = "") -> String {
        let french = lang.hasPrefix("fr")
        let checklist = french ? """
        Check every sentence for:
        - spelling and typos (doubled or missing letters, words split or glued: « walk man »);
        - missing accents, including on capitals (« A gauche » → « À gauche ») and ligatures (« soeur » → « sœur », « oeil » → « œil »);
        - agreement: past participles with être and avoir (« nous sommes arrivé » → « arrivés »), gender and number, « c'était » vs « c'étaient »;
        - conjugation and wrong verb forms (« a écris » → « a écrit », « avait du » → « avait dû »), mood after « au cas où » (conditional);
        - missing « ne » in written negation (« on est jamais » → « on n'est jamais ») unless the line is clearly spoken dialogue;
        - doubled or missing words (« il y a avait »);
        - wrongly capitalised common nouns, misspelled proper names (artists, places);
        - italics missing (Markdown *…*) on titles of books, newspapers, films, songs and works of art (« Le Monde » → « *Le Monde* »), and on foreign words that are not naturalised in French: always "suggest".
        Never change spaces, apostrophes, quotes, dashes or ellipses: the app applies French typography itself.
        """ : """
        Check every sentence for spelling, typos, missing or doubled words, subject–verb agreement, wrong verb forms, \
        its/it's, their/there, wrongly capitalised common nouns and misspelled proper names. \
        Suggest italics (Markdown *…*) for titles of books, newspapers, films, songs and works of art, and for foreign words (always "suggest"). \
        Never change spaces, apostrophes, quotes, dashes or ellipses: the app applies typography itself.
        """
        return """
        You are a meticulous copy editor proofreading a literary manuscript in \(french ? "French" : "English").
        Be thorough: list EVERY objective error, even small ones.
        \(checklist)
        Do NOT touch style: word choice, rhythm, repetitions, sentence fragments, register, punctuation choices, \
        or anything that is a deliberate literary effect.

        Classify each fix:
        - "obvious": exactly one correct form and no reading where the author meant it (misspelling, missing accent or ligature, \
        doubled word, wrong past participle or conjugation in narration).
        - "suggest": anything that could be deliberate or debatable (dropped « ne », mood, register, capitals, proper names, dialogue).

        Return ONLY a JSON array, no prose, no code fence. Each item:
        {"original": "<exact substring copied from the text, 2 to 8 words, enough to be unique>", "replacement": "<the same substring corrected>", "reason": "<3-6 words, in the text's language>", "message": "<one sentence in the text's language: the rule and why this is wrong>", "kind": "obvious" | "suggest"}
        Copy "original" character for character from the text. Return [] if there is nothing to fix.
        Agreement with « je », « me », « m’ », « moi » follows whoever says it: in the narration, the narrator; \
        inside quotation marks or after a dialogue dash, the character speaking. A feminine word in someone's line \
        tells nothing about the narrator. If you cannot tell who « je » is, leave the agreement alone.
        \(people.isEmpty ? "" : "The book's people:\n" + people)
        \(dictionary.isEmpty ? "" : "The author has marked these words as correct; never flag them: " + dictionary.prefix(300).joined(separator: ", ") + ".")

        TEXT:
        \(text)
        """
    }

    /// Splits a chapter into chunks of whole paragraphs, about `words` long, keeping each chunk's offset.
    static func chunks(_ text: String, words: Int = 450) -> [(text: String, offset: Int)] {
        let ns = text as NSString
        var out: [(String, Int)] = []
        var start = 0, count = 0, cursor = 0
        while cursor < ns.length {
            let para = ns.paragraphRange(for: NSRange(location: cursor, length: 0))
            count += ns.substring(with: para).split(whereSeparator: \.isWhitespace).count
            cursor = NSMaxRange(para)
            if count >= words || cursor >= ns.length {
                out.append((ns.substring(with: NSRange(location: start, length: cursor - start)), start))
                start = cursor; count = 0
            }
        }
        return out.filter { !$0.0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    static func check(text: String, offset: Int, lang: String, engine: AgentKind, model: String, cwd: URL,
                      progress: (@MainActor (Int, Int) -> Void)? = nil) async throws -> [ProofFix] {
        let parts = chunks(text)
        var all: [ProofFix] = []
        var errors: [Error] = []
        var done = 0
        await progress?(0, parts.count)
        await withTaskGroup(of: Result<[ProofFix], Error>.self) { group in
            var next = 0
            func add() {
                guard next < parts.count else { return }
                let part = parts[next]
                next += 1
                group.addTask {
                    do {
                        let raw = try await Agents.oneShot(engine, prompt: prompt(text: part.text, lang: lang), model: model, cwd: cwd)
                        return .success(parse(raw, source: part.text, offset: offset + part.offset))
                    } catch { return .failure(error) }
                }
            }
            // At most four CLI processes at a time.
            for _ in 0..<min(4, parts.count) { add() }
            for await result in group {
                switch result {
                case .success(let fixes): all += fixes
                case .failure(let error): errors.append(error)
                }
                done += 1
                await progress?(done, parts.count)
                add()
            }
        }
        if let error = errors.first, errors.count == parts.count { throw error }
        return all.sorted { $0.anchor < $1.anchor }
    }

    static func parse(_ raw: String, source: String, offset: Int) -> [ProofFix] {
        guard let start = raw.firstIndex(of: "["), let end = raw.lastIndex(of: "]"), start < end,
              let data = String(raw[start...end]).data(using: .utf8),
              let decoded = try? JSONDecoder().decode([ProofFix].self, from: data) else { return [] }
        let ns = source as NSString
        var fixes: [ProofFix] = []
        for var fix in decoded where !fix.original.isEmpty && fix.original != fix.replacement {
            let r = fix.locate(in: ns)
            guard r.location != NSNotFound else { continue }
            fix.replacement = fix.adapted(to: source)
            if fix.replacement == ns.substring(with: r) { continue }
            fix.anchor = offset + r.location
            fixes.append(fix)
        }
        return fixes.sorted { $0.anchor < $1.anchor }
    }
}
