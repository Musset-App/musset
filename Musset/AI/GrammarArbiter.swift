import Foundation

/// A rule-based checker matches patterns and cannot read: « sans oser la toucher » has no way of knowing who « la » is.
/// Grammar alerts (agreement, confusion, capitals) are shown only once the AI, given the passage and the book's characters,
/// confirms them. Spelling and doubled words don't hang on meaning and show at once.
enum GrammarArbiter {
    struct Item {
        let id: Int
        let fix: ProofFix
        let paragraph: String
        let before: String
        let after: String
    }

    static func applies(to fix: ProofFix) -> Bool {
        fix.source == "lt" && !LanguageTool.isSpelling(fix.rule) && !(fix.rule ?? "").hasSuffix("WORD_REPEAT_RULE")
    }

    /// A verdict holds for this paragraph as written: changing a word in it asks again.
    static func key(paragraph hash: String, fix: ProofFix) -> String { "\(hash)|\(fix.ignoreKey)" }

    /// Who the book's people are, from the plot index, so gender and names don't have to be guessed.
    static func facts(plot: PlotGrid) -> String {
        plot.tags(in: "characters").prefix(40).map { tag in
            let aliases = tag.aliases.isEmpty ? "" : " (\(tag.aliases.prefix(4).joined(separator: ", ")))"
            return "- \(tag.name)\(aliases)\(tag.note.isEmpty ? "" : " : \(tag.note.prefix(120))")"
        }.joined(separator: "\n")
    }

    static func prompt(items: [Item], facts: String, lang: String = "fr") -> String {
        let language = Locale(identifier: "en").localizedString(forLanguageCode: BookLanguage(code: lang).base) ?? "French"
        let alerts = items.map { item -> String in
            let ns = item.paragraph as NSString
            let r = item.fix.locate(in: ns)
            let marked = r.location == NSNotFound ? item.paragraph
                : ns.replacingCharacters(in: r, with: "⟦" + ns.substring(with: r) + "⟧")
            return """
            ALERT \(item.id)
            Before: \(item.before.suffix(400))
            Passage: \(marked)
            After: \(item.after.prefix(400))
            Checker's proposal: ⟦\(item.fix.original)⟧ → \(item.fix.replacement)
            Checker's reason: \(item.fix.message ?? item.fix.reason)
            """
        }.joined(separator: "\n\n")
        return """
        A rule-based grammar checker flagged words in a \(language) literary manuscript. It matches patterns and cannot read, \
        so most of its alerts on a careful text are false. Decide each one by working out what the sentence means: \
        what a pronoun refers to, who or what a word agrees with, whether a word is a noun, an adjective or a verb here.

        Say "real": true only if the marked words are certainly wrong as written, even if the checker's proposal is not the right fix. \
        When in doubt, or when it could be a deliberate choice of the author, say false. Answer from the text alone; \
        style and register are not your concern.
        \(facts.isEmpty ? "" : "\nThe book's people:\n\(facts)\n")
        \(alerts)

        Return ONLY a JSON array with one object per alert, no prose, no code fence: [{"id": 1, "real": false}]
        """
    }

    /// On a real novel, Haiku flipped its verdicts when real mistakes sat in the same batch; Sonnet held them. Codex uses the proofreader's model.
    static func model(for engine: AgentKind) -> String {
        engine == .claude ? "sonnet" : TaskModels.model(.proof, for: engine)
    }

    /// Verdicts by alert id; empty when the reply can't be read.
    static func decode(_ raw: String) -> [Int: Bool] {
        struct Verdict: Decodable { let id: Int; let real: Bool }
        guard let start = raw.firstIndex(of: "["), let end = raw.lastIndex(of: "]"), start < end,
              let data = String(raw[start...end]).data(using: .utf8),
              let verdicts = try? JSONDecoder().decode([Verdict].self, from: data) else { return [:] }
        return Dictionary(verdicts.map { ($0.id, $0.real) }, uniquingKeysWith: { _, last in last })
    }
}
