import Foundation

/// The interface language: the system's, or one of Musset's six by choice (Settings ▸ General).
enum UILang: String, CaseIterable, Identifiable {
    case system, en, fr, de, es, it, ptBR = "pt-BR", ptPT = "pt-PT"
    var id: String { rawValue }
    static let key = "uiLanguage"

    /// The language the interface is in now: the chosen one, or the first of the system's that Musset speaks.
    static var current: UILang {
        let chosen = UILang(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .system
        if chosen != .system { return chosen }
        for code in Locale.preferredLanguages {
            if let l = from(code) { return l }
        }
        return .en
    }

    /// "pt-BR", "pt_PT", "de-CH", "fr"… → the interface language, if Musset has it.
    static func from(_ code: String) -> UILang? {
        let c = code.replacingOccurrences(of: "_", with: "-").lowercased()
        if c.hasPrefix("pt") { return c.hasPrefix("pt-pt") ? .ptPT : .ptBR }
        return [UILang.en, .fr, .de, .es, .it].first { c.hasPrefix($0.rawValue) }
    }

    static var isFrench: Bool { current == .fr }

    /// Dates and numbers in the interface's language.
    static var locale: Locale { Locale(identifier: current.localeID) }

    var localeID: String {
        switch self {
        case .system: UILang.current.localeID
        case .en: "en_US"
        case .fr: "fr_FR"
        case .de: "de_DE"
        case .es: "es_ES"
        case .it: "it_IT"
        case .ptBR: "pt_BR"
        case .ptPT: "pt_PT"
        }
    }

    /// Each language in its own name, so anyone can find theirs.
    var label: String {
        switch self {
        case .system: L("System")
        case .en: "English"
        case .fr: "Français"
        case .de: "Deutsch"
        case .es: "Español"
        case .it: "Italiano"
        case .ptBR: "Português (Brasil)"
        case .ptPT: "Português (Portugal)"
        }
    }

    /// One when the count takes the singular (CLDR): French and Brazilian Portuguese count 0 as singular.
    func isOne(_ n: Int) -> Bool {
        switch self {
        case .fr, .ptBR: n == 0 || n == 1
        default: n == 1
        }
    }
}

/// A piece of interface text, written in English at the call site: `L("\(n) notes")`.
/// Its key is the English with `{%0}`, `{%1}`… for what is interpolated, so a translation may reorder them.
struct LKey: ExpressibleByStringInterpolation {
    var key: String
    var args: [String]
    /// The first whole number interpolated: it picks the singular or plural form.
    var count: Int?

    init(stringLiteral value: String) { key = value; args = []; count = nil }
    init(stringInterpolation s: StringInterpolation) { key = s.key; args = s.args; count = s.count }

    struct StringInterpolation: StringInterpolationProtocol {
        var key = "", args: [String] = [], count: Int?
        init(literalCapacity: Int, interpolationCount: Int) {}
        mutating func appendLiteral(_ literal: String) { key += literal }
        mutating func appendInterpolation<T>(_ value: T) {
            key += "{%\(args.count)}"
            if count == nil, let n = value as? Int { count = n }
            args.append(String(describing: value))
        }
    }
}

/// The interface's text tables, one per language, keyed by the English (`Resources/Localization/<lang>.json`).
/// An entry is a string, or `{"one": …, "other": …}` when it holds a count.
enum Strings {
    nonisolated(unsafe) private static var tables: [UILang: [String: Any]] = [:]
    private static let lock = NSLock()

    static func table(_ lang: UILang) -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        if let t = tables[lang] { return t }
        var t: [String: Any] = [:]
        if let url = Bundle.main.url(forResource: lang.rawValue, withExtension: "json", subdirectory: "Localization")
            ?? Bundle.main.url(forResource: lang.rawValue, withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            t = json
        }
        tables[lang] = t
        return t
    }

    static func text(_ key: LKey, ctx: String? = nil, lang: UILang = UILang.current) -> String {
        let lookup = ctx.map { key.key + "@@" + $0 } ?? key.key
        var form: String?
        for l in [lang, .en] {
            let entry = table(l)[lookup] ?? (ctx == nil ? nil : table(l)[key.key])
            if let s = entry as? String { form = s; break }
            if let p = entry as? [String: String] {
                let one = key.count.map { l.isOne($0) } ?? false
                form = (one ? p["one"] : p["other"]) ?? p["other"]
                break
            }
        }
        // The English itself (the keys quote « like this »): English quotes.
        var out = form ?? key.key.replacingOccurrences(of: "« ", with: "“").replacingOccurrences(of: " »", with: "”")
        for (i, a) in key.args.enumerated().reversed() { out = out.replacingOccurrences(of: "{%\(i)}", with: a) }
        return out
    }
}

/// A piece of interface text in the interface's language. `ctx` tells apart two senses of the same English
/// (« Done » the status, « Done » the button): it is the French sense, which the tables also key on.
func L(_ key: LKey, ctx: String? = nil) -> String { Strings.text(key, ctx: ctx) }

/// A text that is only known at run time (a preset's stored name, an engine's label): looked up as it is.
func L(dynamic text: String) -> String { Strings.text(LKey(stringLiteral: text)) }

/// Words quoted the way the interface's language quotes: “…” in English and Brazilian Portuguese, « … » in French,
/// „…“ in German, «…» in Spanish, Italian and European Portuguese.
func inQuotes(_ s: some StringProtocol) -> String {
    switch UILang.current {
    case .fr: "«\u{00A0}\(s)\u{00A0}»"
    case .de: "„\(s)“"
    case .es, .it, .ptPT: "«\(s)»"
    case .en, .ptBR, .system: "“\(s)”"
    }
}

extension String {
    /// A command's name as the title of what it opens, or as the button that confirms it:
    /// « Book Settings… » → « Book Settings ». One key in the tables serves both.
    var titled: String {
        var s = self
        while s.hasSuffix("…") || s.hasSuffix(" ") || s.hasSuffix("\u{00A0}") || s.hasSuffix("\u{202F}") { s.removeLast() }
        return s
    }
}

extension Sequence where Element: StringProtocol {
    /// « a, b, c »: a list inside a sentence.
    var listed: String { joined(separator: ", ") }
}
