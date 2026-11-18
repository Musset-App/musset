import AppKit
import SwiftUI

/// The language a book is written in, with its regional variant: it decides typography, proofing,
/// hyphenation and the manuscript conventions of the export. Stored in `book.json` as its code.
enum BookLanguage: String, CaseIterable, Identifiable {
    case enUS = "en-US", enGB = "en-GB"
    case frFR = "fr-FR"
    case deDE = "de-DE", deCH = "de-CH"
    case esES = "es-ES", es419 = "es-419"
    case itIT = "it-IT"
    case ptPT = "pt-PT", ptBR = "pt-BR"

    var id: String { rawValue }

    /// A stored code, old or new ("fr", "en", "de_CH", "pt-br"…), as one of Musset's variants.
    init(code: String) {
        let c = code.replacingOccurrences(of: "_", with: "-").lowercased()
        if let exact = BookLanguage.allCases.first(where: { $0.rawValue.lowercased() == c }) { self = exact; return }
        switch c.split(separator: "-").first.map(String.init) ?? c {
        case "fr": self = .frFR
        case "de": self = c.hasSuffix("ch") ? .deCH : .deDE
        case "es": self = c == "es-es" ? .esES : (c.count > 2 ? .es419 : .esES)
        case "it": self = .itIT
        case "pt": self = c.hasSuffix("br") ? .ptBR : .ptPT
        default: self = c.hasSuffix("gb") || c.hasSuffix("uk") ? .enGB : .enUS
        }
    }

    /// "fr", "de"…: the language without its region.
    var base: String { String(rawValue.prefix(2)) }
    /// "US", "CH", "419"…
    var region: String { String(rawValue.split(separator: "-").last ?? "") }

    var label: String {
        switch self {
        case .enUS: "English (US)"
        case .enGB: "English (UK)"
        case .frFR: "Français"
        case .deDE: "Deutsch (Deutschland)"
        case .deCH: "Deutsch (Schweiz)"
        case .esES: "Español (España)"
        case .es419: "Español (Latinoamérica)"
        case .itIT: "Italiano"
        case .ptPT: "Português (Portugal)"
        case .ptBR: "Português (Brasil)"
        }
    }

    /// The name NSSpellChecker knows, if the Mac has it: the variant first, then the language.
    @MainActor var spellCheckerLanguage: String? {
        let available = NSSpellChecker.shared.availableLanguages
        for candidate in [rawValue.replacingOccurrences(of: "-", with: "_"), base] where available.contains(candidate) { return candidate }
        return nil
    }

    /// The book language matching the interface's, for a new book.
    static var forInterface: BookLanguage { BookLanguage(code: UILang.current.rawValue) }
}

/// The book's language and variant, as a menu. Old codes ("fr", "en") show as their variant and are rewritten on choice.
struct BookLanguagePicker: View {
    @Binding var code: String
    var body: some View {
        Picker(L("Book language"), selection: Binding(get: { BookLanguage(code: code).rawValue }, set: { code = $0 })) {
            ForEach(BookLanguage.allCases) { Text($0.label).tag($0.rawValue) }
        }
        .labelsHidden().fixedSize()
    }
}

/// Words printed in the book itself, in the book's language (not the interface's).
enum BookTerm: String {
    case contents, acknowledgements, colophon
    case noIndent, author, dedication, epigraph, epigraphSource, partNumber, partTitle, sceneBreak, blockQuote, colophonStyle
    /// The Word styles of a formed book's piece: the line over its title (« Chapitre 3 », « Prologue ») and the title under it.
    case pieceLine, pieceTitle
    /// A scene's or a chapter's title by its number, as Return makes them: "Scène 3", "Chapitre 8".
    case sceneNumber, chapterNumber

    private var forms: [String: String] {
        switch self {
        case .contents: ["en": "Contents", "fr": "Table", "de": "Inhalt", "es": "Índice", "it": "Indice", "pt": "Índice"]
        case .acknowledgements: ["en": "Acknowledgements", "en-US": "Acknowledgments", "fr": "Remerciements", "de": "Danksagung",
                                 "es": "Agradecimientos", "it": "Ringraziamenti", "pt": "Agradecimentos"]
        case .colophon: ["en": "Printed in {year}.\nTypeset with Musset.", "fr": "Achevé d’imprimer en {year}.\nComposé avec Musset.",
                         "de": "Gedruckt {year}.\nGesetzt mit Musset.", "es": "Se terminó de imprimir en {year}.\nCompuesto con Musset.",
                         "it": "Finito di stampare nel {year}.\nComposto con Musset.", "pt": "Impresso em {year}.\nComposto com Musset."]
        case .noIndent: ["en": "No Indent", "fr": "Texte sans retrait", "de": "Ohne Einzug", "es": "Sin sangría", "it": "Senza rientro", "pt": "Sem recuo"]
        case .author: ["en": "Author", "fr": "Auteur", "de": "Autor", "es": "Autor", "it": "Autore", "pt": "Autor"]
        case .dedication: ["en": "Dedication", "fr": "Dédicace", "de": "Widmung", "es": "Dedicatoria", "it": "Dedica", "pt": "Dedicatória"]
        case .epigraph: ["en": "Epigraph", "fr": "Exergue", "de": "Motto", "es": "Epígrafe", "it": "Epigrafe", "pt": "Epígrafe"]
        case .epigraphSource: ["en": "Epigraph Source", "fr": "Source de l’exergue", "de": "Mottoquelle", "es": "Fuente del epígrafe",
                               "it": "Fonte dell’epigrafe", "pt": "Fonte da epígrafe"]
        case .partNumber: ["en": "Part Number", "fr": "Numéro de partie", "de": "Teilnummer", "es": "Número de parte", "it": "Numero di parte", "pt": "Número da parte"]
        case .partTitle: ["en": "Part Title", "fr": "Titre de partie", "de": "Teiltitel", "es": "Título de parte", "it": "Titolo di parte", "pt": "Título da parte"]
        case .sceneBreak: ["en": "Scene Break", "fr": "Saut de scène", "de": "Szenenwechsel", "es": "Cambio de escena", "it": "Stacco di scena", "pt": "Quebra de cena"]
        case .blockQuote: ["en": "Block Quote", "fr": "Citation", "de": "Blockzitat", "es": "Cita en bloque", "it": "Citazione", "pt": "Citação"]
        case .colophonStyle: ["en": "Colophon", "fr": "Achevé d’imprimer", "de": "Impressum", "es": "Colofón", "it": "Colophon", "pt": "Cólofon"]
        case .pieceLine: ["en": "Chapter Number", "fr": "Numéro de chapitre", "de": "Kapitelnummer", "es": "Número de capítulo", "it": "Numero di capitolo", "pt": "Número do capítulo"]
        case .pieceTitle: ["en": "Chapter Title", "fr": "Titre de chapitre", "de": "Kapiteltitel", "es": "Título de capítulo", "it": "Titolo di capitolo", "pt": "Título do capítulo"]
        case .sceneNumber: ["en": "Scene {n}", "fr": "Scène {n}", "de": "Szene {n}", "es": "Escena {n}", "it": "Scena {n}", "pt": "Cena {n}"]
        case .chapterNumber: ["en": "Chapter {n}", "fr": "Chapitre {n}", "de": "Kapitel {n}", "es": "Capítulo {n}", "it": "Capitolo {n}", "pt": "Capítulo {n}"]
        }
    }

    /// The term in the book's language ("fr", "de-CH", "pt-BR"…).
    func `in`(_ lang: String) -> String {
        let book = BookLanguage(code: lang)
        return forms[book.rawValue] ?? forms[book.base] ?? forms["en"]!
    }
}
