import XCTest
@testable import Musset

final class FocusVeilTests: XCTestCase {
    let text = """
    Premier paragraphe, loin.

    Le voisin d’avant. Encore lui.

    Une phrase. La phrase du curseur ici. Une dernière, plus loin encore dans le paragraphe.

    Le voisin d’après.

    Un autre, loin.
    """ as NSString

    func testRingsFromTheCaretOutwards() {
        let caret = text.range(of: "curseur").location
        let rings = FocusVeil.Rings(caret: caret, in: text)
        XCTAssertEqual(text.substring(with: rings.sentence).trimmingCharacters(in: .whitespaces), "La phrase du curseur ici.")
        XCTAssertTrue(text.substring(with: rings.before).hasPrefix("Le voisin d’avant"))
        XCTAssertTrue(text.substring(with: rings.after).hasPrefix("Le voisin d’après"))

        XCTAssertEqual(rings.opacity(at: caret), 1)
        let near = rings.opacity(at: text.range(of: "Une phrase").location + 2)
        let far = rings.opacity(at: text.range(of: "paragraphe.").location + 3)
        XCTAssertTrue((FocusVeil.paragraphFar...FocusVeil.paragraphNear).contains(near) && (FocusVeil.paragraphFar...FocusVeil.paragraphNear).contains(far), "\(near) \(far)")
        XCTAssertGreaterThan(rings.opacity(at: text.range(of: "Une dernière").location), far)
        XCTAssertEqual(rings.opacity(at: text.range(of: "Encore lui").location), FocusVeil.neighbours)
        XCTAssertEqual(rings.opacity(at: text.range(of: "Le voisin d’après").location), FocusVeil.neighbours)
        XCTAssertEqual(rings.opacity(at: text.range(of: "Premier").location), FocusVeil.rest)
        XCTAssertEqual(rings.opacity(at: text.range(of: "Un autre").location), FocusVeil.rest)
    }

    func testTheSentenceJustTypedStaysLit() {
        let end = text.range(of: "ici.").location + 4
        let rings = FocusVeil.Rings(caret: end, in: text)
        XCTAssertTrue(text.substring(with: rings.sentence).contains("curseur"))
        let atEnd = FocusVeil.Rings(caret: text.range(of: "paragraphe.").location + 11, in: text)
        XCTAssertTrue(text.substring(with: atEnd.sentence).hasPrefix("Une dernière"))
    }

    func testTypingSnapsAndMovingFades() {
        var veil = FocusVeil()
        let a = FocusVeil.Rings(caret: text.range(of: "curseur").location, in: text)
        veil.move(to: a, animated: true)
        XCTAssertTrue(veil.isAnimating, "focus mode turning on fades in")
        while veil.tick() {}
        XCTAssertEqual(veil.opacity(at: text.range(of: "Premier").location), FocusVeil.rest, accuracy: 0.001)

        veil.move(to: FocusVeil.Rings(caret: text.range(of: "curseur").location + 3, in: text), animated: true)
        XCTAssertFalse(veil.isAnimating, "within the sentence: no fade")

        veil.move(to: FocusVeil.Rings(caret: text.range(of: "Un autre").location, in: text), animated: true)
        XCTAssertTrue(veil.isAnimating)
        XCTAssertEqual(veil.opacity(at: text.range(of: "Un autre").location), FocusVeil.rest, accuracy: 0.001, "starts where it was")
    }

    func testScrollingSoftensAndWritingRestores() {
        var veil = FocusVeil()
        let rings = FocusVeil.Rings(caret: text.range(of: "curseur").location, in: text)
        veil.move(to: rings, animated: false)
        let far = text.range(of: "Premier").location
        XCTAssertEqual(veil.opacity(at: far), FocusVeil.rest, accuracy: 0.001)

        veil.setReading(true)
        XCTAssertTrue(veil.isAnimating)
        while veil.tick() {}
        XCTAssertEqual(veil.opacity(at: far), 1 - (1 - FocusVeil.rest) * FocusVeil.reading, accuracy: 0.001)
        XCTAssertEqual(veil.opacity(at: text.range(of: "curseur").location), 1)

        veil.setReading(false)
        while veil.tick() {}
        XCTAssertEqual(veil.opacity(at: far), FocusVeil.rest, accuracy: 0.001)
    }

    /// Drawing the veil over a whole chapter of a real book stays well under a frame.
    @MainActor
    func testVeilIsCheapToDraw() throws {
        let body = String(repeating: "Une phrase assez longue pour remplir une ligne de la colonne. Et une autre, plus courte.\n\n", count: 400)
        let tv = ZenTextView(frame: NSRect(x: 0, y: 0, width: 700, height: 900))
        tv.string = body
        tv.layoutManager?.ensureLayout(for: tv.textContainer!)
        tv.setSelectedRange(NSRange(location: 20_000, length: 0))
        tv.focusMode = true
        while tv.focusVeil.tick() {}
        let image = NSImage(size: NSSize(width: 700, height: 900))
        image.lockFocus()
        let rect = NSRect(x: 0, y: 0, width: 700, height: 900)
        tv.drawFocusVeil(in: rect)   // warm up
        let t = CFAbsoluteTimeGetCurrent()
        for _ in 0..<10 { tv.drawFocusVeil(in: rect) }
        let ms = (CFAbsoluteTimeGetCurrent() - t) * 100
        image.unlockFocus()
        print("VEIL ms per frame", ms)
        XCTAssertLessThan(ms, 8)
    }
}
