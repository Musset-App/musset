import XCTest
@testable import Musset

/// Each book language's typography: quotes, dialogue, dashes, and its own habits.
final class TypographyVariantTests: XCTestCase {
    private func t(_ s: String, _ lang: String) -> String { Typography.corrected(s, lang: lang) }

    func testOldCodesMapToVariants() {
        XCTAssertEqual(BookLanguage(code: "fr"), .frFR)
        XCTAssertEqual(BookLanguage(code: "en"), .enUS)
        XCTAssertEqual(BookLanguage(code: "de_CH"), .deCH)
        XCTAssertEqual(BookLanguage(code: "pt-br"), .ptBR)
        XCTAssertEqual(BookLanguage(code: "pt"), .ptPT)
        XCTAssertEqual(BookLanguage(code: "es-MX"), .es419)
        XCTAssertEqual(BookLanguage(code: "es"), .esES)
        XCTAssertEqual(BookLanguage(code: "en-GB"), .enGB)
    }

    func testFrenchAndUSEnglishUnchanged() {
        XCTAssertEqual(t("Il dit \"oui\" ; puis...", "fr-FR"), t("Il dit \"oui\" ; puis...", "fr"))
        XCTAssertEqual(t("He said \"yes\" -- then...", "en-US"), "He said “yes”—then…")
    }

    func testBritish() {
        XCTAssertEqual(t("He said \"yes\" - then left...", "en-GB"), "He said ‘yes’ – then left…")
        XCTAssertEqual(t("It's done ; really ?", "en-GB"), "It’s done; really?")
    }

    func testGerman() {
        XCTAssertEqual(t("Er sagte \"ja\" - und ging.", "de-DE"), "Er sagte „ja“ – und ging.")
        XCTAssertEqual(t("Das ist z.B. gut.", "de-DE"), "Das ist z.\u{202F}B. gut.")
        XCTAssertEqual(t("„Er rief \"Hilfe\" laut.“", "de-DE"), "„Er rief ‚Hilfe‘ laut.“")
    }

    func testSwissGerman() {
        XCTAssertEqual(t("Er sagte \"Strasse, Fuß\".", "de-CH"), "Er sagte «Strasse, Fuss».")
    }

    func testSpanishDialogue() {
        XCTAssertEqual(t("- Hola, dijo ella.", "es-ES"), "—Hola, dijo ella.")
        XCTAssertEqual(t("Dijo \"no\" y se fue...", "es-ES"), "Dijo «no» y se fue…")
        XCTAssertEqual(t("Dijo \"no\".", "es-419"), "Dijo “no”.")
        XCTAssertEqual(t("Fue a priori un error.", "es-ES"), "Fue *a priori* un error.")
    }

    func testItalian() {
        XCTAssertEqual(t("E' arrivato un po' tardi.", "it-IT"), "È arrivato un po’ tardi.")
        XCTAssertEqual(t("Disse \"no\".", "it-IT"), "Disse «no».")
        XCTAssertEqual(t("- Vieni?", "it-IT"), "— Vieni?")
    }

    func testPortuguese() {
        XCTAssertEqual(t("- Olá, disse ele.", "pt-PT"), "— Olá, disse ele.")
        XCTAssertEqual(t("Disse \"não\".", "pt-PT"), "Disse «não».")
        XCTAssertEqual(t("Disse \"não\".", "pt-BR"), "Disse “não”.")
        XCTAssertEqual(t("Ele disse : sim !", "pt-BR"), "Ele disse: sim!")
    }

    func testNotesAndCodeStayUntouched() {
        XCTAssertEqual(t("Il \"x\" <!-- \"y\" -->", "it-IT"), "Il «x» <!-- \"y\" -->")
    }
}
