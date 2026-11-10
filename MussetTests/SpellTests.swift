import AppKit
import XCTest
@testable import Musset

@MainActor
final class SpellTests: XCTestCase {
    func spellingRanges(_ tv: NSTextView) -> Int {
        guard let lm = tv.layoutManager else { return -1 }
        var n = 0, i = 0
        let length = (tv.string as NSString).length
        while i < length {
            var r = NSRange()
            if lm.temporaryAttribute(.spellingState, atCharacterIndex: i, effectiveRange: &r) != nil { n += 1 }
            i = max(i + 1, NSMaxRange(r))
        }
        return n
    }

    func testLiveSpellcheckSurvivesRestyle() throws {
        print("SPELL languages:", NSSpellChecker.shared.availableLanguages.filter { $0.hasPrefix("fr") || $0.hasPrefix("en") })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        let tv = ZenTextView(usingTextLayoutManager: false)
        tv.frame = window.contentView!.bounds
        tv.isContinuousSpellCheckingEnabled = true
        window.contentView!.addSubview(tv)
        _ = NSSpellChecker.shared.setLanguage("fr")
        NSSpellChecker.shared.automaticallyIdentifiesLanguages = false
        tv.string = "La maisonn était encore une maison. Il y avait des portte et des lampes."
        tv.restyle()
        tv.checkTextInDocument(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(2))
        let before = spellingRanges(tv)
        print("SPELL marks before restyle:", before)
        tv.restyle()
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        let after = spellingRanges(tv)
        print("SPELL marks after restyle:", after)
        XCTAssertGreaterThanOrEqual(before, 2)
        XCTAssertEqual(after, before)
        print("SPELL direct check fr:", NSSpellChecker.shared.checkSpelling(of: "La maisonn était", startingAt: 0, language: "fr", wrap: false, inSpellDocumentWithTag: 0, wordCount: nil))
    }
}
