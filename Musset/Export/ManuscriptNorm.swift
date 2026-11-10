import Foundation

/// How a manuscript is presented to publishers in each country: page, face, spacing, and the count they expect.
enum ManuscriptNorm: String, Codable, CaseIterable, Identifiable {
    /// English standard manuscript (William Shunn): US Letter or A4, double spaced, word count rounded to 100.
    case shunnUS = "shunn-us", shunnUK = "shunn-uk"
    /// French feuillet: 25 lines of 60 signs, 1,500 signs a page.
    case feuillet
    /// German Normseite: 30 lines of 60 characters, 1,800 a page.
    case normseite
    /// Italian cartella editoriale: 30 lines of 60 battute, 1,800 a page.
    case cartella
    /// Spanish: A4, Times 12, 1.5 spacing; counted in characters with spaces.
    case spanish = "es"
    /// Portuguese: A4, Times 12, 1.5 spacing, 3/2 cm margins; counted in characters with spaces.
    case portugueseBR = "pt-br", portuguesePT = "pt-pt"

    var id: String { rawValue }

    /// The norm a book in this language submits with.
    static func `for`(_ book: BookLanguage) -> ManuscriptNorm {
        switch book {
        case .enUS: .shunnUS
        case .enGB: .shunnUK
        case .frFR: .feuillet
        case .deDE, .deCH: .normseite
        case .itIT: .cartella
        case .esES, .es419: .spanish
        case .ptBR: .portugueseBR
        case .ptPT: .portuguesePT
        }
    }

    /// The preset's stored English name (shown through the interface's tables).
    var presetName: String {
        switch self {
        case .shunnUS: "Standard manuscript (US Letter)"
        case .shunnUK: "Standard manuscript (A4)"
        case .feuillet: "Manuscript in French pages (25 × 60)"
        case .normseite: "Manuscript in Normseiten (30 × 60)"
        case .cartella: "Manuscript in cartelle (30 × 60)"
        case .spanish: "Manuscript for Spanish publishers"
        case .portugueseBR: "Manuscript for Brazilian publishers"
        case .portuguesePT: "Manuscript for Portuguese publishers"
        }
    }

    var preset: ExportPreset {
        var p = ExportPreset(id: "manuscript-\(rawValue)", name: presetName, format: .pdf, includeContact: true)
        p.manuscript = self
        return p
    }

    private static let mono = #"("Courier New", "Courier", "IBM Plex Mono")"#
    private static let serif = #"("Times New Roman", "Times", "Libertinus Serif")"#

    /// The arguments of `manuscript.with(…)` in musset.typ.
    var typstArguments: String {
        switch self {
        case .shunnUS: "paper: (8.5in, 11in), margins: (left: 1in, right: 1in, top: 1in, bottom: 1in), font: \(Self.serif), pitch: 24pt, indent: 0.5in, shunn: true"
        case .shunnUK: "paper: (210mm, 297mm), margins: (left: 25.4mm, right: 25.4mm, top: 25.4mm, bottom: 25.4mm), font: \(Self.serif), pitch: 24pt, indent: 12.7mm, shunn: true"
        case .feuillet: "margins: (left: 25mm, top: 35mm), font: \(Self.mono), pitch: 24pt, lines: 25, chars: 60, indent: 3em"
        case .normseite, .cartella: "margins: (left: 25mm, top: 35mm), font: \(Self.mono), pitch: 20pt, lines: 30, chars: 60, indent: 3em"
        case .spanish: "margins: (left: 30mm, right: 25mm, top: 25mm, bottom: 25mm), font: \(Self.serif), pitch: 18pt, indent: 1.25cm"
        case .portugueseBR, .portuguesePT: "margins: (left: 30mm, right: 20mm, top: 30mm, bottom: 20mm), font: \(Self.serif), pitch: 18pt, indent: 1.25cm"
        }
    }

    /// The count for the title page, in the book's language: words for English, pages of the norm, or characters.
    func count(of text: String, lang: BookLanguage) -> String {
        let plain = text.replacingOccurrences(of: #"<!--[\s\S]*?-->"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[*_#>`]"#, with: "", options: .regularExpression)
        let words = plain.split(whereSeparator: \.isWhitespace).count
        let chars = plain.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces).count
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: lang.rawValue.replacingOccurrences(of: "-", with: "_"))
        func n(_ v: Int) -> String { f.string(from: NSNumber(value: v)) ?? "\(v)" }
        func pages(_ per: Int) -> Int { max(1, Int((Double(chars) / Double(per)).rounded())) }
        switch self {
        case .shunnUS, .shunnUK: return "about \(n(max(100, Int((Double(words) / 100).rounded()) * 100))) words"
        case .feuillet: return "\(n(pages(1500))) feuillets (\(n(chars)) signes)"
        case .normseite: return "ca. \(n(pages(1800))) Normseiten (\(n(chars)) Zeichen)"
        case .cartella: return "circa \(n(pages(1800))) cartelle (\(n(chars)) battute)"
        case .spanish: return "\(n(chars)) caracteres con espacios · \(n(words)) palabras"
        case .portugueseBR, .portuguesePT: return "\(n(chars)) caracteres com espaços · \(n(words)) palavras"
        }
    }

    /// The running head: "Surname / TITLE" in English, "Surname — Title" elsewhere.
    func running(author: String, title: String) -> String {
        let surname = author.split(separator: " ").last.map(String.init) ?? author
        switch self {
        case .shunnUS, .shunnUK: return "\(surname) / \(title.uppercased())"
        default: return "\(surname) — \(title)"
        }
    }
}
