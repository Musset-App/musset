import XCTest
@testable import Musset

/// The interface in six languages: every text everywhere, its placeholders kept, its plurals whole.
final class LocalizationTests: XCTestCase {
    private func table(_ lang: UILang) throws -> [String: Any] {
        let url = try XCTUnwrap(Bundle.main.url(forResource: lang.rawValue, withExtension: "json"), "\(lang.rawValue).json is not in the app")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func holes(_ s: String) -> [String] {
        let re = try! NSRegularExpression(pattern: #"\{%\d+\}"#)
        return re.matches(in: s, range: NSRange(location: 0, length: (s as NSString).length)).map { (s as NSString).substring(with: $0.range) }.sorted()
    }

    func testEveryTextInEveryLanguage() throws {
        let french = try table(.fr)
        XCTAssertGreaterThan(french.count, 1300)
        for lang in [UILang.de, .es, .it, .ptBR, .ptPT] {
            let t = try table(lang)
            let missing = french.keys.filter { t[$0] == nil }.sorted()
            XCTAssertTrue(missing.isEmpty, "\(lang.rawValue) lacks \(missing.count): \(missing.prefix(5))")
            for (key, value) in t {
                let base = key.components(separatedBy: "@@")[0]
                let forms = (value as? [String: String]).map { Array($0.values) } ?? [value as? String].compactMap { $0 }
                XCTAssertFalse(forms.isEmpty, "\(lang.rawValue): \(key)")
                for f in forms { XCTAssertEqual(holes(f), holes(base), "\(lang.rawValue): \(key) → \(f)") }
                if let p = value as? [String: String] { XCTAssertEqual(Set(p.keys), ["one", "other"], "\(lang.rawValue): \(key)") }
            }
        }
    }

    func testLookupPluralsAndContext() {
        let saved = UserDefaults.standard.string(forKey: UILang.key)
        defer { UserDefaults.standard.set(saved, forKey: UILang.key) }
        UserDefaults.standard.set(UILang.de.rawValue, forKey: UILang.key)
        XCTAssertEqual(L("Book A5"), "Buch A5")
        let one = 1, many = 3
        XCTAssertTrue(L("\(one) notes may lose their passage.").hasPrefix("1 Notiz kann"))
        XCTAssertTrue(L("\(many) notes may lose their passage.").hasPrefix("3 Notizen können"))
        UserDefaults.standard.set(UILang.fr.rawValue, forKey: UILang.key)
        XCTAssertEqual(L("Done", ctx: "Écrit"), "Écrit")
        XCTAssertEqual(L("Done", ctx: "Terminé"), "Terminé")
        let zero = 0
        XCTAssertTrue(L("\(zero) notes may lose their passage.").contains("note pourra"), "French: 0 is singular")
        UserDefaults.standard.set(UILang.en.rawValue, forKey: UILang.key)
        XCTAssertEqual(L("\(one) notes may lose their passage."), "1 note may lose its passage.")
        XCTAssertEqual(L(dynamic: "A name the author typed"), "A name the author typed")
    }

    func testSystemLanguagePicksTheClosest() {
        XCTAssertEqual(UILang.from("pt-BR"), .ptBR)
        XCTAssertEqual(UILang.from("pt"), .ptBR)
        XCTAssertEqual(UILang.from("pt_PT"), .ptPT)
        XCTAssertEqual(UILang.from("de-AT"), .de)
        XCTAssertNil(UILang.from("nl"))
    }
}
