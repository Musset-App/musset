import AppKit

/// Focus mode as light: the sentence being written at full strength, its paragraph a little less,
/// the paragraphs on either side less again, the rest of the page faint. Drawn as a veil of the page's
/// colour over the text, so moving the caret only redraws: nothing is restyled or laid out again.
struct FocusVeil {
    /// How much of the text shows through, from the caret outwards.
    static let sentence: CGFloat = 1.0
    static let paragraphNear: CGFloat = 0.8
    static let paragraphFar: CGFloat = 0.62
    static let neighbours: CGFloat = 0.4
    static let rest: CGFloat = 0.18
    /// While scrolling to read, the veil keeps this share of its dimming: the page evens out.
    static let reading: CGFloat = 0.3

    struct Rings: Equatable {
        var sentence: NSRange
        var paragraph: NSRange
        var before: NSRange
        var after: NSRange

        /// Everything at full strength: focus mode off.
        static let none = Rings(sentence: NSRange(location: NSNotFound, length: 0), paragraph: NSRange(location: NSNotFound, length: 0),
                                before: NSRange(location: NSNotFound, length: 0), after: NSRange(location: NSNotFound, length: 0))
        var isNone: Bool { paragraph.location == NSNotFound }

        /// The rings around `caret`. Blank lines between paragraphs belong to no ring of their own.
        init(caret: Int, in s: NSString) {
            let p = Self.paragraph(in: s, at: caret)
            paragraph = p
            sentence = Self.sentence(in: s, paragraph: p, caret: caret)
            before = Self.neighbour(in: s, of: p, forward: false)
            after = Self.neighbour(in: s, of: p, forward: true)
        }

        private init(sentence: NSRange, paragraph: NSRange, before: NSRange, after: NSRange) {
            self.sentence = sentence; self.paragraph = paragraph; self.before = before; self.after = after
        }

        /// How much of the character at `i` shows through.
        func opacity(at i: Int) -> CGFloat {
            if isNone { return 1 }
            if NSLocationInRange(i, sentence) { return FocusVeil.sentence }
            if NSLocationInRange(i, paragraph) {
                // Fading away from the sentence, towards the paragraph's ends.
                let far = i < sentence.location ? sentence.location - paragraph.location : NSMaxRange(paragraph) - NSMaxRange(sentence)
                let d = i < sentence.location ? sentence.location - i : i - NSMaxRange(sentence)
                let t = far > 0 ? min(1, CGFloat(d) / CGFloat(far)) : 0
                return FocusVeil.paragraphNear + (FocusVeil.paragraphFar - FocusVeil.paragraphNear) * t
            }
            if NSLocationInRange(i, before) || NSLocationInRange(i, after) { return FocusVeil.neighbours }
            return FocusVeil.rest
        }

        /// Where the opacity may change: the rings' edges.
        var edges: [Int] {
            isNone ? [] : [sentence, paragraph, before, after].filter { $0.location != NSNotFound }.flatMap { [$0.location, NSMaxRange($0)] }
        }

        private static func paragraph(in s: NSString, at i: Int) -> NSRange {
            s.paragraphRange(for: NSRange(location: min(max(0, i), s.length), length: 0))
        }

        private static func isBlank(_ s: NSString, _ r: NSRange) -> Bool {
            s.substring(with: r).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        private static func neighbour(in s: NSString, of p: NSRange, forward: Bool) -> NSRange {
            var r = p
            repeat {
                if forward { guard NSMaxRange(r) < s.length else { return NSRange(location: NSNotFound, length: 0) }; r = paragraph(in: s, at: NSMaxRange(r)) }
                else { guard r.location > 0 else { return NSRange(location: NSNotFound, length: 0) }; r = paragraph(in: s, at: r.location - 1) }
            } while isBlank(s, r)
            return r
        }

        private static func sentence(in s: NSString, paragraph p: NSRange, caret: Int) -> NSRange {
            // The first sentence that ends after the caret; at the paragraph's end, its last sentence.
            var found: NSRange?
            s.enumerateSubstrings(in: p, options: [.bySentences, .substringNotRequired]) { _, _, enclosing, stop in
                found = enclosing
                if caret < NSMaxRange(enclosing) { stop.pointee = true }
            }
            return found ?? p
        }
    }

    private(set) var from = Rings.none
    private(set) var to = Rings.none
    /// 0 → `from`, 1 → `to`.
    private(set) var progress: CGFloat = 1
    private var started = Date.distantPast
    static let duration: TimeInterval = 0.32

    /// How much of the dimming is applied: 1 while writing, `reading` while scrolling.
    private(set) var strength: CGFloat = 1
    private var strengthFrom: CGFloat = 1
    private var strengthTo: CGFloat = 1
    private var strengthStarted = Date.distantPast
    static let strengthDuration: TimeInterval = 0.45

    var isAnimating: Bool { progress < 1 || strength != strengthTo }

    /// Scrolling softens the contrast to read; writing or moving the caret brings it back.
    mutating func setReading(_ reading: Bool) {
        let target = reading ? Self.reading : 1
        guard target != strengthTo else { return }
        strengthFrom = strength; strengthTo = target; strengthStarted = Date()
    }

    /// Moves to new rings. A move within the same sentence (typing) snaps; anything else fades.
    mutating func move(to rings: Rings, animated: Bool) {
        guard rings != to else { return }
        let sameSentence = rings.sentence.location == to.sentence.location && rings.paragraph.location == to.paragraph.location
        if !animated || sameSentence && !isAnimating {
            from = rings; to = rings; progress = 1
            return
        }
        from = to; to = rings; progress = 0; started = Date()
    }

    /// Advances the fade; returns whether it is still running.
    mutating func tick() -> Bool {
        progress = CGFloat(min(1, Date().timeIntervalSince(started) / Self.duration))
        let u = CGFloat(min(1, Date().timeIntervalSince(strengthStarted) / Self.strengthDuration))
        strength = u >= 1 ? strengthTo : strengthFrom + (strengthTo - strengthFrom) * Self.ease(u)
        return isAnimating
    }

    private static func ease(_ t: CGFloat) -> CGFloat { t * t * (3 - 2 * t) }

    func opacity(at i: Int) -> CGFloat {
        let a = from.opacity(at: i), b = to.opacity(at: i)
        let shown = a + (b - a) * Self.ease(progress)
        return 1 - (1 - shown) * strength
    }

    var edges: [Int] { Array(Set(from.edges + to.edges)).sorted() }
    var isClear: Bool { from.isNone && to.isNone }
}

extension ZenTextView {
    /// Covers each stretch of text with the page's colour at the strength that dims it to its ring.
    func drawFocusVeil(in rect: NSRect) {
        guard !focusVeil.isClear, let lm = layoutManager, let tc = textContainer else { return }
        let origin = textContainerOrigin
        let glyphs = lm.glyphRange(forBoundingRect: rect.offsetBy(dx: -origin.x, dy: -origin.y), in: tc)
        guard glyphs.length > 0 else { return }
        let edges = focusVeil.edges
        let page = NSColor.textBackgroundColor
        lm.enumerateLineFragments(forGlyphRange: glyphs) { lineRect, _, _, lineGlyphs, _ in
            let chars = lm.characterRange(forGlyphRange: lineGlyphs, actualGlyphRange: nil)
            var cuts = [chars.location] + edges.filter { $0 > chars.location && $0 < NSMaxRange(chars) } + [NSMaxRange(chars)]
            cuts = Array(Set(cuts)).sorted()
            for (a, b) in zip(cuts, cuts.dropFirst()) where b > a {
                let piece = NSRange(location: a, length: b - a)
                let shown = self.focusVeil.opacity(at: a + (b - a) / 2)
                guard shown < 0.995 else { continue }
                let g = lm.glyphRange(forCharacterRange: piece, actualCharacterRange: nil)
                let box = lm.boundingRect(forGlyphRange: g, in: tc)
                // The full line height, so no thin line of undimmed text shows between lines.
                let cover = NSRect(x: box.minX - 1, y: lineRect.minY, width: box.width + 2, height: lineRect.height)
                    .offsetBy(dx: origin.x, dy: origin.y)
                guard cover.intersects(rect) else { continue }
                page.withAlphaComponent(1 - shown).setFill()
                cover.fill(using: .sourceOver)
            }
        }
    }

    /// Follows the caret: called whenever the selection or the text changes. Writing restores full contrast.
    func updateFocusVeil(animated: Bool = true) {
        let rings = focusMode ? FocusVeil.Rings(caret: selectedRange().location, in: string as NSString) : .none
        let before = focusVeil
        focusVeil.move(to: rings, animated: animated)
        focusVeil.setReading(false)
        guard focusVeil.to != before.to || focusVeil.isAnimating else { return }
        needsDisplay = true
        animateFocusVeil()
    }

    /// Scrolling: the contrast softens, to read.
    func focusVeilReading() {
        guard focusMode else { return }
        focusVeil.setReading(true)
        animateFocusVeil()
    }

    private func animateFocusVeil() {
        guard focusVeil.isAnimating, focusTimer == nil else { return }
        focusTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                if !self.focusVeil.tick() { timer.invalidate(); self.focusTimer = nil }
                self.needsDisplay = true
            }
        }
    }
}
