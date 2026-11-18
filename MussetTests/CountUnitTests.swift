import XCTest
@testable import Musset

/// One unit for every count: what a word, a character and a space are, and the round a click makes.
final class CountUnitTests: XCTestCase {
    func testAClickGoesRoundTheThreeUnits() {
        XCTAssertEqual(CountUnit.words.next, .characters)
        XCTAssertEqual(CountUnit.characters.next, .charactersWithSpaces)
        XCTAssertEqual(CountUnit.charactersWithSpaces.next, .words)
        XCTAssertEqual(CountUnit(rawValue: "") ?? .words, .words, "nothing kept yet: words")
    }

    func testAccentsAndApostrophesAreOneCharacterEach() {
        let c = TextCounts("L’été, déjà.")
        XCTAssertEqual(c.words, BookStore.wordCount("L’été, déjà."))
        XCTAssertEqual(c.characters, 11)
        XCTAssertEqual(c.charactersWithSpaces, 12)
        // The same letters written with combining accents count the same.
        XCTAssertEqual(TextCounts("e\u{301}te\u{301}").characters, 3)
    }

    func testEverySpaceIsASpaceAndLineEndsAreNot() {
        // « Quoi ? » with the no-break spaces French typography puts there, then a narrow one and a tab.
        let c = TextCounts("«\u{A0}Quoi\u{A0}?\u{A0}»\nOui\u{202F}!\tNon\r\n\nFin")
        XCTAssertEqual(c.characters, 17)
        XCTAssertEqual(c.charactersWithSpaces, 17 + 5)
        XCTAssertEqual(TextCounts("\n \n").charactersWithSpaces, 1)
        XCTAssertEqual(TextCounts(""), .zero)
    }

    func testAnEmojiIsOneCharacter() {
        let c = TextCounts("Oui 👍🏽 👨‍👩‍👧 🇫🇷")
        XCTAssertEqual(c.characters, 6)
        XCTAssertEqual(c.charactersWithSpaces, 9)
    }

    func testSceneMarkersAndMarkdownMarksAreNotTheText() {
        let text = "# Un\n<!-- scene: Le quai -->\nIl *court*.\n<!-- scene: La gare -->\nElle attend."
        let c = TextCounts(text)
        XCTAssertEqual(c.words, BookStore.wordCount(text))
        XCTAssertEqual(c.words, 5)
        XCTAssertEqual(c.characters, 2 + 8 + 11)
        // The space after the heading's # is one of the text's spaces.
        XCTAssertEqual(c.charactersWithSpaces, 3 + 9 + 12)
    }

    func testScenesAddUpToTheirChapter() {
        let text = "<!-- scene: Le quai -->\nIl court sur le quai.\n<!-- scene: La gare -->\nElle attend, là."
        let (counts, scenes) = BookSession.count(text)
        XCTAssertEqual(scenes.count, 2)
        XCTAssertEqual(scenes.reduce(TextCounts.zero) { $0 + $1.counts }, counts)
        XCTAssertEqual(scenes[0].counts, TextCounts("Il court sur le quai."))
        XCTAssertEqual(scenes[0].words, 5)
        XCTAssertEqual(counts[.characters], 17 + 14)
        XCTAssertEqual(counts[.charactersWithSpaces], 21 + 16)
    }

    func testTheCountIsWrittenInTheInterfaceLanguage() {
        let saved = UserDefaults.standard.string(forKey: UILang.key)
        defer { UserDefaults.standard.set(saved, forKey: UILang.key) }
        UserDefaults.standard.set(UILang.fr.rawValue, forKey: UILang.key)
        XCTAssertEqual(CountUnit.words.label(2034), "2\u{202F}034 mots")
        XCTAssertEqual(CountUnit.characters.label(11742), "11\u{202F}742 signes")
        XCTAssertEqual(CountUnit.charactersWithSpaces.label(13775), "13\u{202F}775 signes espaces comprises")
        XCTAssertEqual(CountUnit.characters.label(1), "1 signe")
        XCTAssertEqual(CountUnit.words.label(0), "0 mot")
        UserDefaults.standard.set(UILang.en.rawValue, forKey: UILang.key)
        XCTAssertEqual(CountUnit.words.label(1), "1 word")
        XCTAssertEqual(CountUnit.charactersWithSpaces.label(TextCounts("a b")), "3 characters with spaces")
        UserDefaults.standard.set(UILang.de.rawValue, forKey: UILang.key)
        XCTAssertEqual(CountUnit.characters.label(1), "1 Zeichen")
    }
}
