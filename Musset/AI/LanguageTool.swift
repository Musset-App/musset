import Foundation

/// LanguageTool grammar and spelling checks: the one bundled in Musset, or the author's own server, or languagetool.org
/// when asked for. No account or key: the free public API allows about 20 requests and 75 KB of text a minute.
enum LanguageTool {
    enum Mode: String, CaseIterable, Identifiable {
        case auto, local, publicAPI = "public", off
        var id: String { rawValue }
        var label: String {
            switch self {
            case .auto: L("The LanguageTool inside Musset")
            case .local: L("Local server only")
            case .publicAPI: "languagetool.org"
            case .off: L("Off", ctx: "Désactivé")
            }
        }
    }

    static let publicURL = URL(string: "https://api.languagetool.org")!
    static var localURL: URL { URL(string: UserDefaults.standard.string(forKey: "languageToolLocalURL") ?? "http://localhost:8081")! }
    static var mode: Mode { Mode(rawValue: UserDefaults.standard.string(forKey: "languageTool") ?? "") ?? .auto }
    /// Largest text sent in one request (the public API refuses more than 20 KB).
    static let maxRequestBytes = 12_000

    struct Match: Decodable {
        struct Replacement: Decodable { let value: String }
        struct Category: Decodable { let id: String; let name: String? }
        struct Rule: Decodable { let id: String; let issueType: String?; let category: Category? }
        let message: String
        let shortMessage: String?
        let offset: Int
        let length: Int
        let replacements: [Replacement]
        let rule: Rule
    }

    struct Failure: LocalizedError {
        let message: String
        let rateLimited: Bool
        var errorDescription: String? { message }
    }

    private struct Response: Decodable { let matches: [Match] }

    /// "fr" → "fr", "en" → "en-US" (LanguageTool needs a variant to check English spelling).
    static func code(for lang: String) -> String {
        let l = lang.replacingOccurrences(of: "_", with: "-")
        if l.contains("-") { return l }
        return l.lowercased() == "en" ? "en-US" : l
    }

    /// The server to use now, or nil when LanguageTool is off or the local server is required but not running.
    static func server() async -> URL? {
        switch mode {
        case .off: return nil
        case .publicAPI: return publicURL
        case .local: return await isUp(localURL) ? localURL : nil
        case .auto:
            if LanguageToolServer.isBundled { return try? await LanguageToolServer.shared.url() }
            return await isUp(localURL) ? localURL : nil
        }
    }

    static func isUp(_ base: URL) async -> Bool {
        var req = URLRequest(url: base.appendingPathComponent("v2/languages"))
        req.timeoutInterval = 0.8
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }

    static func check(_ text: String, lang: String, server: URL) async throws -> [Match] {
        var req = URLRequest(url: server.appendingPathComponent("v2/check"))
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("Musset", forHTTPHeaderField: "User-Agent")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: allowed) ?? "" }
        req.httpBody = "language=\(enc(code(for: lang)))&text=\(enc(text))".data(using: .utf8)
        // Java's little HTTP server closes idle connections that URLSession would reuse: a fresh one each time,
        // and one more try if it was dropped all the same.
        req.setValue("close", forHTTPHeaderField: "Connection")
        let data: Data, resp: URLResponse
        do { (data, resp) = try await URLSession.shared.data(for: req) }
        catch let e as URLError where e.code == .networkConnectionLost { (data, resp) = try await URLSession.shared.data(for: req) }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let body = String(data: data, encoding: .utf8)?.prefix(200) ?? ""
            throw Failure(message: "LanguageTool (\(server.host ?? "")): HTTP \(status) \(body)", rateLimited: status == 429)
        }
        return try JSONDecoder().decode(Response.self, from: data).matches
    }

    /// Categories that fight literary prose or Musset's own typography: style advice, commas, capitals of points
    /// of the compass, spaces and quotes (Musset's typography owns them).
    static let droppedCategories: Set<String> = [
        "TYPOGRAPHY", "STYLE", "REDUNDANCY", "PUNCTUATION", "PONCTUATION_VIRGULE", "CASING", "REPETITIONS_STYLE",
        "PLAIN_ENGLISH", "WIKIPEDIA", "COLLOQUIALISMS", "GENDER_NEUTRALITY", "CREATIVE_WRITING", "TEXT_ANALYSIS",
        "SEMANTICS", "MISC", "FALSE_FRIENDS", "REGIONALISMS", "AMERICAN_ENGLISH_STYLE", "BRITISH_ENGLISH", "STYLE_FR",
        "ACADEMIC_WRITING", "CAT_TOURS_CRITIQUES", "CAT_TYPOGRAPHIE", "EMPFOHLENE_RECHTSCHREIBUNG", "PROPER_NOUNS",
    ]
    /// Rules a writer breaks on purpose: the dropped « ne » of speech.
    static let droppedRules: Set<String> = ["P_V_PAS", "PAS_DE_VIRGULE", "VIRG_NON_TROUVEE", "NORD_SUD"]

    /// Keeps spelling, grammar and doubled words; drops typography and style, which fight literary prose,
    /// spelling flags on capitalised words (mostly proper names) and words the author taught the book.
    /// French rules come "uncategorized": they are judged by their category, not their type.
    static func keep(_ m: Match, original: String, words: [String] = [], lang: String = "fr") -> Bool {
        guard !m.replacements.isEmpty, !droppedRules.contains(m.rule.id) else { return false }
        let type = m.rule.issueType ?? ""
        let id = m.rule.id
        // Doubled words only (« il y a avait »); "repeated word" style rules are left to the repetitions view.
        if id.hasSuffix("WORD_REPEAT_RULE") || type == "duplication" { return true }
        if type == "misspelling" { return LocalProofreader.keepSpelling(original, words: words, lang: lang) }
        if droppedCategories.contains(m.rule.category?.id ?? "") { return false }
        // "inconsistency" stays: Spanish agreement (« Los niño ») comes as one.
        return !["typographical", "style", "whitespace", "locale-violation", "register"].contains(type)
    }

    /// A spelling rule, whatever the language calls it (MORFOLOGIK_RULE_EN_US, FR_SPELLING_RULE, GERMAN_SPELLER_RULE…).
    static func isSpelling(_ rule: String?) -> Bool {
        guard let r = rule else { return false }
        return r.contains("SPELL") || r.hasPrefix("MORFOLOGIK") || r.contains("HUNSPELL")
    }

    /// Converts matches on `text` (paragraphs joined with blank lines, starting at `starts`) to fixes per paragraph.
    static func fixes(_ matches: [Match], paragraphs: [String], starts: [Int], words: [String] = [], lang: String = "fr") -> [[ProofFix]] {
        var out = Array(repeating: [ProofFix](), count: paragraphs.count)
        for m in matches {
            guard let i = starts.lastIndex(where: { $0 <= m.offset }) else { continue }
            let ns = paragraphs[i] as NSString
            let local = NSRange(location: m.offset - starts[i], length: m.length)
            guard NSMaxRange(local) <= ns.length, local.length > 0 else { continue }
            let original = ns.substring(with: local)
            guard keep(m, original: original, words: words, lang: lang) else { continue }
            // « Les enfant »: « Les enfants » before « L’enfant », the fix that keeps the author's first word.
            let first = original.split(separator: " ").first.map(String.init) ?? ""
            let raw = m.replacements.prefix(5).map(\.value)
            let values = original.contains(" ") ? raw.filter { $0.hasPrefix(first + " ") } + raw.filter { !$0.hasPrefix(first + " ") } : raw
            // The rule's family as LanguageTool names it in the book's language, else its short message.
            let reason = m.rule.category?.name ?? (m.shortMessage?.isEmpty == false ? m.shortMessage! : m.message)
            out[i].append(ProofFix(original: original, replacement: values[0], reason: reason, kind: "suggest",
                                   anchor: local.location, alternatives: Array(values.dropFirst()), source: "lt",
                                   message: m.message, rule: m.rule.id))
        }
        return out
    }
}
