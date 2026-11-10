import XCTest
@testable import Musset

/// The keyboard modes, with real key events sent to a real editor.
@MainActor
final class KeyModeTests: XCTestCase {
    private var window: NSWindow!
    private var tv: ZenTextView!
    private var bridge: EditorBridge!

    override func setUp() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        tv = ZenTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        bridge = EditorBridge()
        tv.bridge = bridge
        bridge.textView = tv
        tv.allowsUndo = true
        window.contentView?.addSubview(tv)
        window.makeFirstResponder(tv)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: KeyboardMode.defaultsKey)
        window.close()
    }

    private func mode(_ m: KeyboardMode) { UserDefaults.standard.set(m.rawValue, forKey: KeyboardMode.defaultsKey) }

    private func set(_ text: String, caret: Int = 0) {
        tv.string = text
        tv.setSelectedRange(NSRange(location: caret, length: 0))
    }

    /// One key, as the keyboard sends it.
    private func press(_ key: String, _ flags: NSEvent.ModifierFlags = [], code: UInt16 = 0) {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber,
                                     context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: code)!
        tv.keyDown(with: event)
    }

    private func type(_ keys: String) { for c in keys { press(String(c)) } }
    private func esc() { press("\u{1b}", code: 53) }
    private var caret: Int { tv.selectedRange().location }

    func testMacModeLeavesEverythingToTheTextView() {
        mode(.mac)
        set("Un deux", caret: 0)
        XCTAssertFalse(bridge.keys.handle(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.control], timestamp: 0, windowNumber: 0, context: nil,
                                                           characters: "k", charactersIgnoringModifiers: "k", isARepeat: false, keyCode: 40)!, in: tv))
    }

    func testWordStarDiamondBlocksAndMarkers() {
        mode(.wordstar)
        set("Un deux trois.\nQuatre cinq.", caret: 0)
        press("f", .control)
        XCTAssertEqual(caret, 3, "⌃F: next word")
        press("k", .control); press("b")
        press("k", .control); press("1")
        press("f", .control)
        press("k", .control); press("k")
        XCTAssertEqual(bridge.keys.visibleBlock, NSRange(location: 3, length: 5), "the block « deux »")

        press("q", .control); press("c")
        XCTAssertEqual(caret, (tv.string as NSString).length, "⌃Q C: end of the chapter")
        press("k", .control); press("v")
        XCTAssertEqual(tv.string, "Un trois.\nQuatre cinq.deux ", "⌃K V: moved here")
        XCTAssertEqual(bridge.keys.visibleBlock.map { (tv.string as NSString).substring(with: $0) }, "deux ", "the block follows it")

        press("q", .control); press("1")
        XCTAssertEqual(caret, 3, "⌃Q 1: back to the marker")
        press("y", .control)
        XCTAssertEqual(tv.string, "Quatre cinq.deux ", "⌃Y: the line goes")
    }

    func testWordStarPrefixShowsItsCardAndStatus() async throws {
        mode(.wordstar)
        set("Texte.")
        press("k", .control)
        XCTAssertEqual(bridge.keyStatus, "⌃K…")
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertEqual(bridge.keyHint?.title, "⌃K")
        press("h")
        XCTAssertNil(bridge.keyHint)
        XCTAssertNil(bridge.keyStatus)
    }

    func testViOperatorsMotionsAndTextObjects() {
        mode(.vi)
        set("Il pleut. Elle vient demain.\nLe train arrive.\nFin.", caret: 0)
        type("w")
        XCTAssertEqual(caret, 3, "w")
        XCTAssertEqual(bridge.keyStatus, "NORMAL")
        type("dw")
        XCTAssertEqual(tv.string, "Il Elle vient demain.\nLe train arrive.\nFin.", "dw takes the word and what follows it")
        type(")")
        XCTAssertEqual(caret, 22, ") goes to the next sentence")
        type("0")
        type("(")
        XCTAssertEqual(caret, 0, "( back to the one before")
        type("dis")
        XCTAssertEqual(tv.string, "\nLe train arrive.\nFin.", "dis: the sentence, its line break kept")
        type("j")
        type("dap")
        XCTAssertEqual(tv.string, "\nFin.", "dap: the whole paragraph")
        type("P")
        XCTAssertEqual(tv.string, "\nLe train arrive.\nFin.", "P puts it back above")
        type("ciw")
        XCTAssertEqual(bridge.keyStatus, "INSERTION")
        XCTAssertEqual(tv.string, "\n train arrive.\nFin.")
        esc()
        XCTAssertEqual(bridge.keyStatus, "NORMAL")
        XCTAssertTrue(bridge.keys.blockCaret)
    }

    func testViVisualAndRepeat() {
        mode(.vi)
        set("a b c d e", caret: 0)
        type("x")
        XCTAssertEqual(tv.string, " b c d e")
        type(".")
        XCTAssertEqual(tv.string, "b c d e", ". repeats the deletion")
        type("v")
        type("e")
        type("d")
        XCTAssertEqual(tv.string, " d e", "v e d: from b to the end of the next word, as vi does")
        XCTAssertEqual(bridge.keyStatus, "NORMAL")
    }

    func testEmacsKillYankAndAccentKeys() {
        mode(.emacs)
        set("Un deux trois.\nQuatre.", caret: 3)
        press("k", .control)
        XCTAssertEqual(tv.string, "Un \nQuatre.", "⌃K: to the end of the line")
        press("e", .control)   // macOS does ⌃E itself
        press("y", .control)
        XCTAssertEqual(tv.string, "Un deux trois.\nQuatre.", "⌃Y: back")
        press("a", .control)
        press("f", .option)
        XCTAssertEqual(caret, 2, "⌥F: end of the word")
        // ⌥E, ⌥U, ⌥C type accents on a Mac: they are not taken.
        let accent = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.option], timestamp: 0, windowNumber: window.windowNumber,
                                      context: nil, characters: "´", charactersIgnoringModifiers: "e", isARepeat: false, keyCode: 14)!
        XCTAssertFalse(bridge.keys.handle(accent, in: tv))
        // Esc then E: the same command, the Emacs way.
        set("Il pleut. Elle vient.", caret: 0)
        esc(); press("e")
        XCTAssertEqual(caret, 9, "Esc E: end of the sentence")
    }

    func testEmacsMarkAndRegion() {
        mode(.emacs)
        set("Un deux trois", caret: 3)
        press(" ", .control)
        XCTAssertEqual(bridge.keyStatus, "Marque posée")
        tv.setSelectedRange(NSRange(location: 8, length: 0))
        press("w", .control)
        XCTAssertEqual(tv.string, "Un trois", "⌃W: the region goes")
    }

    func testProseUnitsInFrench() {
        let s = "« Tu viens ? » demanda-t-elle. Je ne répondis pas.\nL’été passa." as NSString
        XCTAssertEqual(Prose.nextSentenceStart(s, 0), 31)
        XCTAssertEqual(Prose.word(s, at: 52, around: false), NSRange(location: 51, length: 5), "L’été is one word")
        XCTAssertEqual(Prose.sentences(s).count, 3, "the dialogue and its incise are one sentence")
        XCTAssertEqual(Prose.paragraph(s, at: 10).location, 0)
        XCTAssertEqual(Prose.nextParagraphStart(s, 10), 51)
    }
}
