import AppKit
import SwiftUI

/// Lets other panels (chat, proofreader, Pangram) talk to the live text view.
@MainActor
@Observable
final class EditorBridge {
    @ObservationIgnored weak var textView: ZenTextView?
    /// The keyboard mode's state (WordStar, vi, Emacs); see `keys`.
    @ObservationIgnored var keyEngine: KeyEngine?
    /// What the keyboard mode says in the status line (« NORMAL », « ⌃K… »), and the card after a hesitation.
    var keyStatus: String?
    var keyHint: KeyHint?
    /// True while another page (the book's home, a Bible sheet, the grid) lies over the editor. The text view stays
    /// alive underneath and AppKit still sends it mouse moves: without this its hover cards opened over the other page.
    @ObservationIgnored var covered = false {
        didSet { if covered { textView?.closeIssueCard() } }
    }
    var selectedText: String = ""
    var selectedRange = NSRange(location: 0, length: 0)
    /// Background proofreader whose issues are underlined in the text.
    @ObservationIgnored weak var proof: AutoProofreader?
    /// Book search term, highlighted in the open chapter.
    var searchQuery = ""
    /// The find bar over the editor (⌘F).
    var findOpen = false
    var findShowsReplace = false
    /// Raised to put the caret back in the field when the bar is already open.
    var findFocus = 0
    /// "Who wrote what": the tint is on, each word's author, the word under the pointer.
    var blameOn = false { didSet { textView?.needsDisplay = true } }
    var blame = Attribution.Map()
    var blameHover: String?
    /// Ranges flagged by Pangram, highlighted in the text.
    var flagged: [NSRange] = []
    @ObservationIgnored weak var minimap: MinimapView?
    /// The open book, its notes and the AI annotator, for the note highlights and cards.
    @ObservationIgnored weak var session: BookSession?
    @ObservationIgnored weak var annotator: Annotator?
    /// The note whose conversation is open in the Notes tab.
    var openNoteID: UUID? { didSet { textView?.needsDisplay = true } }
    /// Revision mode: what is typed or deleted is kept as a correction to accept or reject.
    /// Not remembered: Musset always opens in Write mode (a shared book's reader is switched to Revise when it opens).
    var trackChanges = false { didSet { textView?.needsDisplay = true } }
    /// Corrections pending in the open chapter.
    var pendingRevisions = 0
    /// Tense agreement under way, then its outcome for a moment (status bar).
    var tenseWork: String?
    var tenseRunning = false

    func openNote(_ id: UUID?) { openNoteID = id; threadOpen = false }
    /// The note's discussion slides over the Notes tab.
    func openThread(_ id: UUID) { openNoteID = id; threadOpen = true }
    var threadOpen = false
    /// True while a chapter's text is being loaded: automatic corrections wait, so they stay undoable.
    @ObservationIgnored var loading = false
    var showResolvedNotes = UserDefaults.standard.bool(forKey: "showResolvedNotes") {
        didSet { UserDefaults.standard.set(showResolvedNotes, forKey: "showResolvedNotes"); textView?.needsDisplay = true; minimap?.needsDisplay = true }
    }
    /// Most repeated words of the open chapter (repetitions mode), for the list in the status bar.
    var repetitionCounts: [RepetitionAnalysis.Count] = []
    var closeRepetitions = 0
    /// Word picked in the list: all its occurrences stay lit.
    var focusedStem: String? { didSet { textView?.needsDisplay = true; minimap?.needsDisplay = true } }

    var currentParagraph: (range: NSRange, text: String)? {
        guard let tv = textView else { return nil }
        let s = tv.string as NSString
        let r = MarkdownStyler.paragraphRange(in: s, at: tv.selectedRange().location)
        return (r, s.substring(with: r))
    }

    /// Replaces a range through the text view so it is undoable and saved.
    func replace(_ range: NSRange, with text: String) {
        guard let tv = textView, NSMaxRange(range) <= (tv.string as NSString).length else { return }
        // The app's own edits (corrections applied, markers, renames) are not revisions.
        tv.untracked = true
        defer { tv.untracked = false }
        // Never edit inside another edit's processing: it desynchronises the layout.
        guard tv.textStorage?.editedMask.isEmpty ?? true else { return }
        if tv.shouldChangeText(in: range, replacementString: text) {
            tv.textStorage?.replaceCharacters(in: range, with: text)
            tv.didChangeText()
        }
    }

    func scroll(to range: NSRange) {
        guard let tv = textView else { return }
        tv.setSelectedRange(range)
        tv.scrollRangeToVisible(range)
        tv.showFindIndicator(for: range)
    }

    func refreshHighlights() { textView?.restyle() }

    /// Lights every occurrence of a word and moves to the next one after the caret.
    func focusRepetition(_ stem: String?) {
        focusedStem = stem
        guard let stem, let tv = textView, let all = tv.repetitions?.occurrences(of: stem), !all.isEmpty else { return }
        let caret = NSMaxRange(tv.selectedRange())
        let next = all.first { $0.location >= caret } ?? all[0]
        scroll(to: next)
    }

    /// Called from drawing code; deferred so SwiftUI state isn't changed mid-update.
    fileprivate func publish(_ a: RepetitionAnalysis?) {
        let counts = Array((a?.counts ?? []).prefix(40))
        let close = a?.close.count ?? 0
        guard counts != repetitionCounts || close != closeRepetitions else { return }
        DispatchQueue.main.async { [weak self] in
            self?.repetitionCounts = counts
            self?.closeRepetitions = close
        }
    }

    /// Search term changed: only the drawn highlights change, the text is not restyled.
    func setSearchQuery(_ q: String) {
        guard q != searchQuery else { return }
        searchQuery = q
        textView?.refreshSearchHighlights()
    }
}

final class ZenTextView: NSTextView {
    /// Set while the app itself edits the text, so revision mode does not record it.
    var untracked = false

    /// The caret never stops inside hidden correction syntax: it jumps over it in the direction it was going.
    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        let text = string
        guard text.contains("{"), !untracked else { return super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting) }
        let hidden = Revisions.hidden(in: text)
        let previous = selectedRange().location
        let fixed = ranges.map { v -> NSValue in
            var r = v.rangeValue
            guard r.length == 0, let h = hidden.first(where: { $0.location < r.location && r.location < NSMaxRange($0) }) else { return v }
            r.location = r.location >= previous ? NSMaxRange(h) : h.location
            return NSValue(range: r)
        }
        super.setSelectedRanges(fixed, affinity: affinity, stillSelecting: stillSelecting)
    }

    /// An apostrophe typed after a letter is curled at once (l'homme → l’homme), not when the caret leaves the paragraph:
    /// until then it stood underlined as a fault. Only with the book's typography on, in a language it knows.
    override func insertText(_ insert: Any, replacementRange: NSRange) {
        guard (insert as? String) == "'", !hasMarkedText(), let proof = bridge?.proof, proof.typography, Typography.supports(proof.lang) else {
            return super.insertText(insert, replacementRange: replacementRange)
        }
        let at = replacementRange.location == NSNotFound ? selectedRange().location : replacementRange.location
        let text = string as NSString
        guard at > 0, at <= text.length else { return super.insertText(insert, replacementRange: replacementRange) }
        let before = text.rangeOfComposedCharacterSequence(at: at - 1)
        let afterLetter = text.substring(with: before).unicodeScalars.first.map(CharacterSet.letters.contains) ?? false
        super.insertText(afterLetter ? "’" : insert, replacementRange: replacementRange)
    }

    /// Where each comment's bubble is drawn, and what it says.
    private var commentBubbles: [(rect: NSRect, mark: Revisions.Mark)] = []

    override func shouldChangeText(in range: NSRange, replacementString s: String?) -> Bool {
        guard bridge?.trackChanges == true, !untracked, !hasMarkedText(), let s,
              let plan = Revisions.track(text: string, range: range, replacement: s) else {
            return super.shouldChangeText(in: range, replacementString: s)
        }
        // Record the edit as a correction instead of making it.
        untracked = true
        defer { untracked = false }
        if plan.range.length > 0 || !plan.text.isEmpty, super.shouldChangeText(in: plan.range, replacementString: plan.text) {
            textStorage?.replaceCharacters(in: plan.range, with: plan.text)
            didChangeText()
        }
        setSelectedRange(NSRange(location: plan.caret, length: 0))
        return false
    }

    var theme = EditorTheme(fontName: "", fontSize: 18)
    var maxColumnWidth: CGFloat = 680
    var focusMode = false { didSet { if oldValue != focusMode { updateFocusVeil() } } }
    var focusVeil = FocusVeil()
    var focusTimer: Timer?
    var typewriter = false
    var showLineNumbers = true { didSet { if oldValue != showLineNumbers { recenter(); needsDisplay = true } } }
    var showRepetitions = false { didSet { if oldValue != showRepetitions { refreshSearchHighlights() } } }
    var repetitionWindow = 50 { didSet { if oldValue != repetitionWindow { refreshSearchHighlights() } } }
    var lang = "fr"
    private(set) var repetitions: RepetitionAnalysis?
    /// Word under the mouse in repetitions mode.
    private var hoverStem: String?
    /// Proofreading issues as last drawn, for hovering without recomputing.
    private var drawnIssues: [AutoProofreader.Issue] = []
    private var cardPopover: NSPopover?
    /// What the open card shows ("issue:…" or "note:…"), so hovering it again doesn't reopen it.
    private var cardKey: String?
    private var stickyCard = false
    private var hoverTimer: Timer?
    private var closeTimer: Timer?
    /// Margin dots as last drawn, with the notes each one stands for.
    private var noteDots: [(rect: NSRect, ids: [UUID])] = []
    weak var bridge: EditorBridge?
    /// Book-search matches, drawn behind the text (not stored as attributes, so restyling never loses them).
    private(set) var searchRanges: [NSRange] = []
    /// Start offset of every line, for line numbers.
    private var lineStarts: [Int] = [0]

    override func setFrameSize(_ newSize: NSSize) {
        let grew = newSize.height > frame.height
        super.setFrameSize(newSize)
        recenter()
        // New lines at the end extend the view: make sure the newly exposed area is drawn.
        if grew { needsDisplay = true }
    }

    static let minTextWidth: CGFloat = 160

    func recenter() {
        // Margins give way before the text does: a container narrower than zero sends TextKit 2 into an endless layout loop.
        // The column is the text's width: the line fragment padding comes on top of it.
        let column = maxColumnWidth + 2 * (textContainer?.lineFragmentPadding ?? 0)
        let wanted = max(showLineNumbers ? 60 : 32, (bounds.width - column) / 2)
        let pad = max(0, min(wanted, (bounds.width - Self.minTextWidth) / 2, bounds.width / 2 - 1))
        let vertical: CGFloat = typewriter ? max(80, (enclosingScrollView?.contentSize.height ?? 600) / 2) : 80
        if textContainerInset.width != pad || textContainerInset.height != vertical {
            textContainerInset = NSSize(width: pad, height: vertical)
        }
    }

    func restyle() {
        guard let storage = textStorage else { return }
        // Called in the middle of an edit (from a notification or an observer): restyle once it is done.
        guard storage.editedMask.isEmpty else {
            DispatchQueue.main.async { [weak self] in self?.restyle() }
            return
        }
        MarkdownStyler.style(storage, theme: theme, caret: selectedRange().location)
        let pending = Revisions.marks(in: string).count
        if bridge?.pendingRevisions != pending { bridge?.pendingRevisions = pending }
        if let bridge, let proof = bridge.proof {
            let issues = proof.issues(in: string)
            drawnIssues = issues
            storage.beginEditing()
            for issue in issues {
                // AI suggestions purple, LanguageTool blue, pending obvious fixes red; all distinct from the system's spelling dots.
                let color: NSColor = issue.fix.isObvious ? .systemRed : (issue.fix.isLanguageTool ? .systemBlue : .systemPurple)
                storage.addAttributes([.underlineStyle: NSUnderlineStyle.thick.rawValue | NSUnderlineStyle.patternDot.rawValue,
                                       .underlineColor: color], range: issue.range)
            }
            storage.endEditing()
            proof.updateCount(issues, text: string)
        }
        typingAttributes = theme.typingAttributes
        refreshSearchHighlights()
    }

    func refreshSearchHighlights() {
        let ns = string as NSString
        searchRanges = BookSearch.ranges(of: bridge?.searchQuery ?? "", in: string)
        var starts = [0]
        var i = 0
        while i < ns.length {
            // Paragraphs, not visual lines: a ⇧↩ line break (U+2028) stays in the same numbered paragraph.
            let r = ns.paragraphRange(for: NSRange(location: i, length: 0))
            i = NSMaxRange(r)
            if i < ns.length || ns.hasSuffix("\n") { starts.append(i) }
        }
        lineStarts = starts
        repetitions = showRepetitions ? Repetitions.analyze(string, lang: lang, window: repetitionWindow) : nil
        if hoverStem != nil && repetitions == nil { hoverStem = nil }
        bridge?.publish(repetitions)
        needsDisplay = true
        bridge?.minimap?.needsDisplay = true
    }

    // MARK: Drawn highlights and line numbers

    // The editor uses TextKit 1 (NSLayoutManager): TextKit 2's viewport layout could loop forever while the
    // whole chapter was restyled on every keystroke, freezing the app.

    /// Characters currently on screen.
    var visibleCharacterRange: NSRange {
        guard let lm = layoutManager, let tc = textContainer else { return NSRange(location: 0, length: 0) }
        let origin = textContainerOrigin
        let glyphs = lm.glyphRange(forBoundingRectWithoutAdditionalLayout: visibleRect.offsetBy(dx: -origin.x, dy: -origin.y), in: tc)
        return lm.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
    }

    private func rects(for range: NSRange) -> [NSRect] {
        guard let lm = layoutManager, let tc = textContainer, NSMaxRange(range) <= (string as NSString).length else { return [] }
        let glyphs = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let origin = textContainerOrigin
        var out: [NSRect] = []
        lm.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: tc) { r, _ in
            out.append(r.offsetBy(dx: origin.x, dy: origin.y))
        }
        return out
    }

    /// One box per line of `range`, ending at its last visible character: a passage that wraps is not
    /// underlined through the line's trailing space up to the column's edge.
    private func underlineRects(for range: NSRange) -> [NSRect] {
        guard let lm = layoutManager, let tc = textContainer, NSMaxRange(range) <= (string as NSString).length else { return [] }
        let ns = string as NSString
        let glyphs = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let origin = textContainerOrigin
        var out: [NSRect] = []
        lm.enumerateLineFragments(forGlyphRange: glyphs) { _, _, _, lineGlyphs, _ in
            let g = NSIntersectionRange(lineGlyphs, glyphs)
            guard g.length > 0 else { return }
            var chars = lm.characterRange(forGlyphRange: g, actualGlyphRange: nil)
            while chars.length > 0, let u = UnicodeScalar(ns.character(at: NSMaxRange(chars) - 1)),
                  CharacterSet.whitespacesAndNewlines.contains(u) { chars.length -= 1 }
            guard chars.length > 0 else { return }
            let trimmed = lm.glyphRange(forCharacterRange: chars, actualCharacterRange: nil)
            out.append(lm.boundingRect(forGlyphRange: trimmed, in: tc).offsetBy(dx: origin.x, dy: origin.y))
        }
        return out
    }

    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
        focusVeilReading()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawFocusVeil(in: dirtyRect)
    }

    /// vi outside INSERT: the caret is a block over the letter.
    private var blockCaretWidth: CGFloat { max(4, (font?.pointSize ?? theme.fontSize) * 0.6) }

    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        guard bridge?.keyEngine?.blockCaret == true else { return super.drawInsertionPoint(in: rect, color: color, turnedOn: flag) }
        var r = rect
        r.size.width = blockCaretWidth
        if flag {
            color.withAlphaComponent(0.45).setFill()
            r.fill()
        } else {
            setNeedsDisplay(r, avoidAdditionalLayout: true)
        }
    }

    override func setNeedsDisplay(_ invalidRect: NSRect, avoidAdditionalLayout flag: Bool) {
        var r = invalidRect
        if bridge?.keyEngine?.blockCaret == true { r.size.width += blockCaretWidth }
        super.setNeedsDisplay(r, avoidAdditionalLayout: flag)
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        let visible = visibleCharacterRange
        func fill(_ ranges: [NSRange], _ color: NSColor) {
            color.setFill()
            for r in ranges where NSIntersectionRange(r, visible).length > 0 || visible.length == 0 {
                for box in rects(for: r) where box.intersects(rect) {
                    NSBezierPath(roundedRect: box.insetBy(dx: -1, dy: 1), xRadius: 3, yRadius: 3).fill()
                }
            }
        }
        if let bridge { fill(bridge.flagged, NSColor.systemOrange.withAlphaComponent(0.18)) }
        // WordStar's block, marked with ⌃K B and ⌃K K: it stays lit until it is moved, copied or hidden.
        if let block = bridge?.keyEngine?.visibleBlock { fill([block], NSColor.controlAccentColor.withAlphaComponent(0.2)) }
        if let bridge, bridge.blameOn {
            for run in bridge.blame.runs where NSIntersectionRange(run.range, visible).length > 0 || visible.length == 0 {
                Attribution.tint(run.person).withAlphaComponent(0.2).setFill()
                for box in rects(for: run.range) where box.intersects(rect) { box.fill() }
            }
        }
        if let reps = repetitions {
            // Close repetitions: the closer, the stronger the tint.
            for o in reps.close where NSIntersectionRange(o.range, visible).length > 0 || visible.length == 0 {
                NSColor.systemPink.withAlphaComponent(0.08 + 0.32 * o.strength).setFill()
                for box in rects(for: o.range) where box.intersects(rect) {
                    NSBezierPath(roundedRect: box.insetBy(dx: -1, dy: 1), xRadius: 3, yRadius: 3).fill()
                }
            }
            // Hovered or picked word: every occurrence, framed.
            if let stem = activeStem {
                for r in reps.occurrences(of: stem) where NSIntersectionRange(r, visible).length > 0 || visible.length == 0 {
                    for box in rects(for: r) where box.intersects(rect) {
                        let path = NSBezierPath(roundedRect: box.insetBy(dx: -2, dy: 0), xRadius: 4, yRadius: 4)
                        NSColor.controlAccentColor.withAlphaComponent(0.22).setFill()
                        path.fill()
                        NSColor.controlAccentColor.withAlphaComponent(0.8).setStroke()
                        path.lineWidth = 1.2
                        path.stroke()
                    }
                }
            }
        }
        drawSceneRules(in: rect, visible: visible)
        drawCommentBubbles(in: rect)
        drawNotes(in: rect, visible: visible)
        fill(searchRanges, NSColor.systemYellow.withAlphaComponent(0.45))
        if showLineNumbers { drawLineNumbers(in: rect) }
    }

    var activeStem: String? { hoverStem ?? bridge?.focusedStem }

    /// A small speech bubble where each comment is (its text shows on hover).
    private func drawCommentBubbles(in rect: NSRect) {
        commentBubbles = []
        guard string.contains("{>>") else { return }
        let ns = string as NSString
        let tint = NSColor(srgbRed: 0.48, green: 0.23, blue: 0.85, alpha: 1)
        for m in Revisions.marks(in: string) where m.second != nil && (m.kind == .comment || m.kind == .highlight) {
            let anchorIndex = m.kind == .highlight ? NSMaxRange(m.first) - 1 : max(0, m.range.location - 1)
            guard anchorIndex >= 0, anchorIndex < ns.length, let glyph = rects(for: NSRange(location: anchorIndex, length: 1)).first else { continue }
            let size: CGFloat = 13
            let bubble = NSRect(x: glyph.maxX + 2, y: glyph.minY + 1, width: size, height: size)
            guard bubble.intersects(rect.insetBy(dx: -20, dy: -20)) else { commentBubbles.append((bubble, m)); continue }
            let path = NSBezierPath(roundedRect: bubble, xRadius: 4, yRadius: 4)
            tint.withAlphaComponent(0.16).setFill(); path.fill()
            if let img = NSImage(systemSymbolName: "text.bubble.fill", accessibilityDescription: nil) {
                let conf = NSImage.SymbolConfiguration(pointSize: 8, weight: .semibold).applying(.init(paletteColors: [tint]))
                img.withSymbolConfiguration(conf)?.draw(in: bubble.insetBy(dx: 2, dy: 2))
            }
            commentBubbles.append((bubble, m))
        }
    }

    /// The comment card: what was said, and a way to remove it.
    private func showCommentCard(_ mark: Revisions.Mark, at anchor: NSRect) {
        guard let c = mark.second else { return }
        let text = (string as NSString).substring(with: c)
        let card = CommentCard(text: text, remove: { [weak self] in
            guard let self else { return }
            self.closeIssueCard()
            self.setSelectedRange(NSRange(location: mark.range.location, length: 0))
            self.decideRevision(accept: false)
        })
        presentCard(card, at: anchor, key: "comment:\(mark.range.location)")
    }

    /// A hairline on each side of every scene marker, across the column.
    private func drawSceneRules(in rect: NSRect, visible: NSRange) {
        guard let tc = textContainer else { return }
        let search = visible.length > 0 ? visible : NSRange(location: 0, length: (string as NSString).length)
        let left = textContainerOrigin.x + tc.lineFragmentPadding
        let right = textContainerOrigin.x + tc.size.width - tc.lineFragmentPadding
        NSColor.separatorColor.setFill()
        for m in Scenes.pattern.matches(in: string, range: search) {
            guard let box = rects(for: m.range).first, box.intersects(rect) || rect.contains(NSPoint(x: rect.midX, y: box.midY)) else { continue }
            let y = box.midY.rounded() + 0.5
            if box.minX - 14 > left { NSRect(x: left, y: y, width: box.minX - 14 - left, height: 1).fill() }
            if right > box.maxX + 14 { NSRect(x: box.maxX + 14, y: y, width: right - box.maxX - 14, height: 1).fill() }
        }
    }

    /// Starts a new scene at the caret's paragraph (⇧⌘N): inserts its marker and selects the title to type over.
    func beginScene() {
        let ns = string as NSString
        let para = ns.paragraphRange(for: NSRange(location: min(selectedRange().location, ns.length), length: 0))
        let title = (bridge?.session?.manifest.lang ?? "fr").hasPrefix("fr") ? "Nouvelle scène" : "New scene"
        let marker = Scenes.markerLine(title)
        let insert = marker + "\n"
        untracked = true
        defer { untracked = false }
        guard shouldChangeText(in: NSRange(location: para.location, length: 0), replacementString: insert) else { return }
        textStorage?.replaceCharacters(in: NSRange(location: para.location, length: 0), with: insert)
        didChangeText()
        let titleStart = para.location + (marker as NSString).range(of: title).location
        setSelectedRange(NSRange(location: titleStart, length: (title as NSString).length))
        scrollRangeToVisible(selectedRange())
    }

    // MARK: Hover (repetitions mode)

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.userInfo?["musset"] != nil { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: ["musset": true]))
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        guard bridge?.covered != true else { return }
        let point = convert(event.locationInWindow, from: nil)
        hoverCards(at: point)
        if let bridge, bridge.blameOn { hoverBlame(at: characterIndexForInsertion(at: point), bridge) }
        guard let reps = repetitions else { return }
        let index = characterIndexForInsertion(at: point)
        let stem = (reps.word(at: index) ?? reps.word(at: index - 1)).map(\.stem)
        if stem != hoverStem {
            hoverStem = stem
            needsDisplay = true
            bridge?.minimap?.needsDisplay = true
        }
    }

    private func hoverBlame(at index: Int, _ bridge: EditorBridge) {
        let run = bridge.blame.runs.first { NSLocationInRange(index, $0.range) }
        let f = DateFormatter()
        f.locale = UILang.locale
        f.dateStyle = .medium
        f.timeStyle = .short
        let text = run.map { r in bridge.blame.people[r.person].person + " · " + (r.date.map(f.string) ?? L("not saved yet")) }
        if text != bridge.blameHover { bridge.blameHover = text }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hoverTimer?.invalidate()
        if hoverStem != nil { hoverStem = nil; needsDisplay = true; bridge?.minimap?.needsDisplay = true }
    }

    // MARK: One line per paragraph: ⇧↩, copy and paste

    override func keyDown(with event: NSEvent) {
        // The chosen keyboard mode reads the key first; whatever it leaves is the text view's.
        if let bridge, bridge.keys.handle(event, in: self) { return }
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if isReturn, event.modifierFlags.contains(.shift), !hasMarkedText() {
            // A line break inside the paragraph; on disk it is a Markdown hard break (two trailing spaces).
            insertText("  \u{2028}", replacementRange: selectedRange())
            return
        }
        super.keyDown(with: event)
    }

    /// Copy as standard Markdown (blank lines between paragraphs), so it pastes well anywhere.
    override func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        let r = selectedRange()
        guard r.length > 0 else { return false }
        pboard.clearContents()
        return pboard.setString(ParagraphCodec.encode((string as NSString).substring(with: r)), forType: .string)
    }

    /// Text with blank lines between paragraphs (from Word, a browser, Claude…) becomes one line per paragraph.
    override func paste(_ sender: Any?) {
        if let s = NSPasteboard.general.string(forType: .string), s.contains("\n\n") {
            insertText(ParagraphCodec.importExternal(s), replacementRange: selectedRange())
        } else {
            super.paste(sender)
        }
    }

    override func pasteAsPlainText(_ sender: Any?) { paste(sender) }

    /// A passage of some length that is cut goes to the Bible's Cuts, with where it came from.
    override func cut(_ sender: Any?) {
        let r = selectedRange()
        let ns = string as NSString
        let cutText = ns.substring(with: r)
        if BookStore.wordCount(cutText) >= 12 {
            bridge?.session?.keepCut(cutText, before: ns.substring(to: r.location))
        }
        super.cut(sender)
    }

    // MARK: Issue card (hover an underline)

    /// The character under the mouse, give or take one: a passage that doesn't hold it can't be under the mouse,
    /// so only the few that do get their rectangles computed. Computing every note's and issue's at each mouse
    /// move cost half a second a minute on a long chapter.
    private func candidates(_ range: NSRange, _ index: Int) -> Bool {
        range.location <= index + 1 && NSMaxRange(range) >= index - 1
    }

    private func issue(under point: NSPoint) -> AutoProofreader.Issue? {
        let index = characterIndexForInsertion(at: point)
        return drawnIssues.first { issue in
            candidates(issue.range, index) && rects(for: issue.range).contains { $0.insetBy(dx: -1, dy: -2).contains(point) }
        }
    }

    /// Hovering an underline opens its issue card, hovering a note's passage or dot opens the note.
    /// Moving away closes the card after a moment, unless the mouse went into it.
    private func hoverCards(at point: NSPoint) {
        if stickyCard, cardPopover?.isShown == true { return }
        if let b = commentBubbles.first(where: { $0.rect.insetBy(dx: -3, dy: -3).contains(point) }) {
            scheduleCard("comment:\(b.mark.range.location)") { [weak self] in self?.showCommentCard(b.mark, at: b.rect) }
        } else if let issue = issue(under: point) {
            scheduleCard("issue:\(issue.range)") { [weak self] in self?.showIssueCard(issue) }
        } else if case let ids = noteIDs(under: point), !ids.isEmpty {
            scheduleCard("note:" + ids.map(\.uuidString).joined(separator: ",")) { [weak self] in self?.showNoteCard(ids) }
        } else {
            hoverTimer?.invalidate()
            guard cardPopover?.isShown == true, closeTimer == nil else { return }
            closeTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.closeTimer = nil
                    if let frame = self.cardPopover?.contentViewController?.view.window?.frame, frame.contains(NSEvent.mouseLocation) { return }
                    self.closeIssueCard()
                }
            }
        }
    }

    private func scheduleCard(_ key: String, show: @escaping () -> Void) {
        closeTimer?.invalidate(); closeTimer = nil
        if cardPopover?.isShown == true && cardKey == key { return }
        hoverTimer?.invalidate()
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { _ in
            MainActor.assumeIsolated { show() }
        }
    }

    /// A sticky card, opened on purpose (a lookup, a note being written), stays when the mouse wanders off.
    private func presentCard<V: View>(_ view: V, at anchor: NSRect, key: String, sticky: Bool = false) {
        closeIssueCard()
        guard bridge?.covered != true, window != nil else { return }
        stickyCard = sticky
        let host = NSHostingController(rootView: view)
        host.sizingOptions = .preferredContentSize
        let pop = NSPopover()
        pop.behavior = .semitransient
        pop.animates = false
        pop.contentViewController = host
        pop.show(relativeTo: anchor, of: self, preferredEdge: .maxY)
        cardPopover = pop
        cardKey = key
    }

    func showIssueCard(_ issue: AutoProofreader.Issue, editing: Bool = false) {
        guard let proof = bridge?.proof, let anchor = rects(for: issue.range).first else { return }
        let card = IssueCard(issue: issue, proof: proof, startEditing: editing) { [weak self] in self?.closeIssueCard() }
        presentCard(card, at: anchor, key: "issue:\(issue.range)")
    }

    // MARK: Notes

    private func noteID(under point: NSPoint) -> UUID? { noteIDs(under: point).first }

    /// Every note on the passage under the mouse, or on the margin dot: several can share a sentence.
    private func noteIDs(under point: NSPoint) -> [UUID] {
        if let dot = noteDots.first(where: { $0.rect.contains(point) }) { return dot.ids }
        guard let store = bridge?.session?.notes else { return [] }
        let index = characterIndexForInsertion(at: point)
        let resolved = bridge?.showResolvedNotes == true
        return store.notes.filter { note in
            guard note.status == .open || resolved, let r = store.live[note.id], candidates(r, index) else { return false }
            return rects(for: r).contains { $0.insetBy(dx: -1, dy: -2).contains(point) }
        }.map(\.id)
    }

    /// Hover: a small preview of each note there; a conversation opens in the Notes tab.
    func showNoteCard(_ ids: [UUID]) {
        guard let session = bridge?.session, let first = ids.first else { return }
        let anchor = session.notes.live[first].flatMap { rects(for: $0).first }
            ?? noteDots.first { $0.ids.contains(first) }?.rect
        guard let anchor else { return }
        let card = NotePreviews(noteIDs: ids, session: session, open: { [weak self] id in
            self?.closeIssueCard()
            self?.bridge?.openThread(id)
        }, close: { [weak self] in
            self?.closeIssueCard()
            self?.needsDisplay = true
            self?.bridge?.minimap?.needsDisplay = true
        })
        presentCard(card, at: anchor, key: "note:" + ids.map(\.uuidString).joined(separator: ","))
    }

    /// A click on a note's margin dot opens its thread.
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let dot = noteDots.first(where: { $0.rect.contains(p) }), let id = dot.ids.first {
            closeIssueCard()
            bridge?.openNote(id)
            return
        }
        if let b = commentBubbles.first(where: { $0.rect.insetBy(dx: -3, dy: -3).contains(p) }) {
            showCommentCard(b.mark, at: b.rect)
            return
        }
        super.mouseDown(with: event)
    }

    /// « Accord temporel »: on the selection when there is one, or on the whole chapter.
    private func tenseMenu() -> NSMenuItem {
        let item = NSMenuItem(title: L("Agree Tenses"), action: nil, keyEquivalent: "")
        let menu = NSMenu()
        let sel = selectedRange()
        let whole = NSRange(location: 0, length: (string as NSString).length)
        func add(_ title: String, _ scope: NSRange) {
            let header = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for target in TenseAgreement.Target.allCases {
                let i = ClosureMenuItem(title: target.label) { [weak self] in self?.bridge?.agreeTenses(in: scope, target: target) }
                i.indentationLevel = 1
                menu.addItem(i)
            }
        }
        if sel.length > 0 {
            add(L("Selection"), sel)
            menu.addItem(.separator())
        }
        add(L("Whole Chapter"), whole)
        item.submenu = menu
        item.isEnabled = bridge?.tenseRunning != true && AIStatus.shared.isOn
        return item
    }

    /// The word to look up: the selection when it is a word or two, else the word under the click.
    private func lookupRange(at index: Int) -> NSRange? {
        let ns = string as NSString
        var r = selectedRange()
        if r.length == 0 || !(r.location...NSMaxRange(r)).contains(index) {
            guard index < ns.length else { return nil }
            r = selectionRange(forProposedRange: NSRange(location: index, length: 0), granularity: .selectByWord)
        }
        // Trim spaces and punctuation the word selection may carry.
        let edge = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters).union(.symbols)
        while r.length > 0, let u = UnicodeScalar(ns.character(at: r.location)), edge.contains(u) { r.location += 1; r.length -= 1 }
        while r.length > 0, let u = UnicodeScalar(ns.character(at: NSMaxRange(r) - 1)), edge.contains(u) { r.length -= 1 }
        let text = ns.substring(with: r)
        guard r.length > 0, r.length <= 40, !text.contains("\n"), text.rangeOfCharacter(from: .letters) != nil else { return nil }
        return r
    }

    /// Synonyms, homonyms or alliterations for the word, in a card under it; a synonym replaces it (one undo step).
    func showWordCard(_ kind: WordLookup.Kind, _ range: NSRange) {
        guard let session = bridge?.session, let anchor = rects(for: range).first else { NSSound.beep(); return }
        let ns = string as NSString
        let word = ns.substring(with: range)
        let paragraph = MarkdownStyler.paragraphRange(in: ns, at: range.location)
        let context = String(ns.substring(with: paragraph).trimmingCharacters(in: .whitespacesAndNewlines).prefix(1200))
        setSelectedRange(range)
        let card = WordCard(kind: kind, word: word, context: context, lang: session.manifest.lang, root: session.root) { [weak self] pick in
            guard let self else { return }
            self.closeIssueCard()
            // Only if the word is still where it was.
            guard NSMaxRange(range) <= (self.string as NSString).length, (self.string as NSString).substring(with: range) == word else { NSSound.beep(); return }
            self.insertText(WordLookup.matchingCase(pick, of: word), replacementRange: range)
        }
        presentCard(card, at: anchor, key: "words", sticky: true)
    }

    /// New note on the selection (⌥⌘N, context menu, toolbar).
    func beginNote() {
        let sel = selectedRange()
        guard sel.length > 0, let session = bridge?.session, let anchor = rects(for: sel).first else { NSSound.beep(); return }
        let quote = (string as NSString).substring(with: sel)
        let composer = NoteComposer(quote: quote, save: { [weak self] kind, body in
            guard let self else { return }
            session.notes.add(range: sel, text: self.string, author: .me, kind: kind, body: body)
            self.closeIssueCard()
            self.needsDisplay = true
            self.bridge?.minimap?.needsDisplay = true
        }, cancel: { [weak self] in self?.closeIssueCard() })
        presentCard(composer, at: anchor, key: "compose", sticky: true)
    }

    /// Soft highlight under each noted passage, and a dot in the right margin on its first line.
    private func drawNotes(in rect: NSRect, visible: NSRange) {
        noteDots = []
        guard let bridge, let store = bridge.session?.notes else { return }
        var byLine: [Int: [Note]] = [:]
        var lineRects: [Int: NSRect] = [:]
        for note in store.notes where note.status == .open || bridge.showResolvedNotes {
            guard let r = store.live[note.id], NSIntersectionRange(r, visible).length > 0 || visible.length == 0 else { continue }
            let boxes = underlineRects(for: r)
            let tint = note.kind.nsColor
            // A line under the passage; a soft tint only for the note whose thread is open.
            let open = bridge.openNoteID == note.id
            // Praise keeps to its margin dot while writing; its passage is underlined when revising.
            let quiet = note.kind.isPositive && !bridge.trackChanges && !open
            for box in boxes where box.intersects(rect) && !quiet {
                if open {
                    tint.withAlphaComponent(0.12).setFill()
                    NSBezierPath(roundedRect: box.insetBy(dx: -1, dy: 1), xRadius: 3, yRadius: 3).fill()
                }
                tint.withAlphaComponent(note.isClosed ? 0.25 : (note.kind.isPositive ? 0.55 : 0.8)).setFill()
                NSRect(x: box.minX, y: box.maxY - 2, width: box.width, height: 1.5).fill()
            }
            if let first = boxes.first {
                let key = Int(first.midY.rounded())
                byLine[key, default: []].append(note)
                lineRects[key] = first
            }
        }
        let x = min(bounds.width - 14, bounds.width - textContainerInset.width + 22)
        for (key, notes) in byLine {
            guard let line = lineRects[key] else { continue }
            let dot = NSRect(x: x, y: line.midY - 3.5, width: 7, height: 7)
            notes[0].kind.nsColor.withAlphaComponent(notes.allSatisfy { $0.isClosed || $0.kind.isPositive } ? 0.4 : 0.9).setFill()
            NSBezierPath(ovalIn: dot).fill()
            if notes.count > 1 {
                let label = "\(notes.count)" as NSString
                label.draw(at: NSPoint(x: dot.maxX + 3, y: dot.minY - 2),
                           withAttributes: [.font: NSFont.systemFont(ofSize: 10, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor])
            }
            noteDots.append((dot.insetBy(dx: -5, dy: -5), notes.map(\.id)))
        }
    }

    func closeIssueCard() {
        stickyCard = false
        hoverTimer?.invalidate()
        closeTimer?.invalidate(); closeTimer = nil
        cardPopover?.close()
        cardPopover = nil
        cardKey = nil
    }

    /// The book's dictionary for the system spell checker too (this text view only, not the user's global dictionary).
    func applyBookDictionary(_ words: [String]) {
        let forms = words.flatMap { [$0, $0.lowercased(), $0.capitalized] }
        NSSpellChecker.shared.setIgnoredWords(Array(Set(forms)), inSpellDocumentWithTag: spellCheckerDocumentTag)
        if isContinuousSpellCheckingEnabled {
            isContinuousSpellCheckingEnabled = false
            isContinuousSpellCheckingEnabled = true
        }
    }

    /// Source line numbers in the left margin (the same numbers as in git, pandoc errors or a chat with Claude).
    private func drawLineNumbers(in rect: NSRect) {
        guard let lm = layoutManager, let tc = textContainer else { return }
        let ns = string as NSString
        let font = NSFont.monospacedDigitSystemFont(ofSize: max(9, theme.fontSize * 0.6), weight: .regular)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.tertiaryLabelColor]
        let origin = textContainerOrigin
        let right = origin.x - 18
        // Never lay out while drawing: AppKit would not redraw what that layout changes.
        let glyphs = lm.glyphRange(forBoundingRectWithoutAdditionalLayout: rect.offsetBy(dx: -origin.x, dy: -origin.y), in: tc)
        lm.enumerateLineFragments(forGlyphRange: glyphs) { lineRect, _, _, lineGlyphs, _ in
            let start = lm.characterIndexForGlyph(at: lineGlyphs.location)
            // Only the first line of each paragraph is numbered.
            guard start < ns.length, start == 0 || ns.character(at: start - 1) == 10 else { return }
            let para = ns.lineRange(for: NSRange(location: start, length: 0))
            if ns.substring(with: para).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return }
            let label = "\(self.lineNumber(at: start))" as NSString
            let size = label.size(withAttributes: attrs)
            let baseline = origin.y + lineRect.minY + lm.location(forGlyphAt: lineGlyphs.location).y
            label.draw(at: NSPoint(x: right - size.width, y: baseline - font.ascender), withAttributes: attrs)
        }
    }

    func lineNumber(at offset: Int) -> Int {
        var lo = 0, hi = lineStarts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lineStarts[mid] <= offset { lo = mid } else { hi = mid - 1 }
        }
        return lo + 1
    }

    /// Scrolls so that `offset` sits in the middle of the window (minimap clicks).
    func scrollToCenter(offset: Int) {
        guard let lm = layoutManager, let tc = textContainer, let scroll = enclosingScrollView else { return }
        let index = min(offset, max(0, (string as NSString).length - 1))
        let glyph = lm.glyphIndexForCharacter(at: index)
        let line = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        _ = tc
        let clip = scroll.contentView
        let maxY = max(0, frame.height - clip.bounds.height)
        clip.setBoundsOrigin(NSPoint(x: clip.bounds.origin.x, y: min(maxY, max(0, line.midY + textContainerOrigin.y - clip.bounds.height / 2))))
        scroll.reflectScrolledClipView(clip)
    }

    /// Whether the selection is being made with the mouse: the page must not move under a click,
    /// or the second click of a double-click lands on another word.
    var selectingWithMouse: Bool {
        switch NSApp.currentEvent?.type {
        case .leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseDown: true
        default: false
        }
    }

    /// Typewriter scrolling follows typing and the keyboard; a click leaves the page where it is.
    func centerCaret() {
        guard typewriter, !selectingWithMouse, let scroll = enclosingScrollView else { return }
        var actual = NSRange()
        let screenRect = firstRect(forCharacterRange: selectedRange(), actualRange: &actual)
        guard let window, screenRect != .zero else { return }
        let inWindow = window.convertFromScreen(screenRect)
        let inView = convert(inWindow, from: nil)
        let clip = scroll.contentView
        let targetY = inView.midY - clip.bounds.height / 2
        clip.animator().setBoundsOrigin(NSPoint(x: clip.bounds.origin.x, y: max(0, targetY)))
        scroll.reflectScrolledClipView(clip)
    }

    // MARK: Proofreading menu (right-click on an underline, like the spell checker)

    private func issue(at point: NSPoint) -> AutoProofreader.Issue? {
        guard let proof = bridge?.proof else { return nil }
        let index = characterIndexForInsertion(at: point)
        return proof.issues(in: string).first { index >= $0.range.location && index <= NSMaxRange($0.range) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let base = super.menu(for: event) ?? NSMenu()
        let point = convert(event.locationInWindow, from: nil)
        var noteItems: [NSMenuItem] = []
        if selectedRange().length > 0 {
            noteItems.append(ClosureMenuItem(title: L("Add Note…")) { [weak self] in self?.beginNote() })
        }
        if let id = noteID(under: point) {
            noteItems.append(ClosureMenuItem(title: L("Open Note Thread")) { [weak self] in self?.bridge?.openThread(id) })
        }
        noteItems.append(ClosureMenuItem(title: L("New Scene Here")) { [weak self] in self?.beginScene() })
        let index = characterIndexForInsertion(at: point)
        if Revisions.mark(at: index, in: string) != nil {
            setSelectedRange(NSRange(location: index, length: 0))
            noteItems.insert(ClosureMenuItem(title: L("Reject Correction")) { [weak self] in self?.decideRevision(accept: false) }, at: 0)
            noteItems.insert(ClosureMenuItem(title: L("Accept Correction")) { [weak self] in self?.decideRevision(accept: true) }, at: 0)
        }
        if selectedRange().length > 0 {
            noteItems.append(ClosureMenuItem(title: L("Comment…")) { [weak self] in self?.commentSelection() })
        }
        noteItems.append(tenseMenu())
        if let word = lookupRange(at: index) {
            let shown = (string as NSString).substring(with: word)
            for kind in WordLookup.Kind.allCases {
                noteItems.append(ClosureMenuItem(title: kind.title(shown)) { [weak self] in self?.showWordCard(kind, word) })
            }
        }
        if !noteItems.isEmpty {
            for (i, item) in noteItems.enumerated() { base.insertItem(item, at: i) }
            base.insertItem(.separator(), at: noteItems.count)
        }
        guard let issue = issue(at: point) else { return base }
        let items = proofItems(for: issue)
        for (i, item) in items.enumerated() { base.insertItem(item, at: i) }
        base.insertItem(.separator(), at: items.count)
        return base
    }

    func showProofMenu(for issue: AutoProofreader.Issue) {
        let menu = NSMenu()
        proofItems(for: issue).forEach(menu.addItem)
        var actual = NSRange()
        guard let window else { return }
        let screen = firstRect(forCharacterRange: issue.range, actualRange: &actual)
        let local = convert(window.convertFromScreen(screen), from: nil)
        menu.popUp(positioning: nil, at: NSPoint(x: local.minX, y: local.maxY + 4), in: self)
    }

    private func proofItems(for issue: AutoProofreader.Issue) -> [NSMenuItem] {
        let fix = issue.fix
        let reason = LocalProofreader.shown(fix.reason)
        var title = reason.isEmpty ? "Suggestion" : reason.prefix(1).uppercased() + reason.dropFirst()
        if let checker = fix.checkerName { title = checker + " · " + title }
        let header = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        header.isEnabled = false
        header.toolTip = fix.message
        var items: [NSMenuItem] = [header]
        items += fix.choices.prefix(5).map { choice in
            ClosureMenuItem(title: L("Replace with « \(choice) »")) { [weak self] in self?.bridge?.proof?.accept(issue, replacement: choice) }
        }
        items.append(ClosureMenuItem(title: L("Correct It Myself…")) { [weak self] in self?.showIssueCard(issue, editing: true) })
        items.append(ClosureMenuItem(title: L("Keep as Written")) { [weak self] in self?.bridge?.proof?.ignore(fix) })
        let words = fix.changedWords
        if !words.isEmpty && words.count <= 3 {
            items.append(ClosureMenuItem(title: L("Add « \(words.joined(separator: " ")) » to Book Dictionary")) { [weak self] in
                words.forEach { self?.bridge?.proof?.learn($0) }
            })
        }
        if fix.isLanguageTool, let rule = fix.rule {
            items.append(ClosureMenuItem(title: L("Never Flag This Rule in This Book")) { [weak self] in self?.bridge?.proof?.disableRule(rule) })
        }
        return items
    }
}

/// NSMenuItem that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func run() { handler() }
}

struct ZenEditorView: NSViewRepresentable {
    @Bindable var session: BookSession
    let bridge: EditorBridge
    var fontName: String
    var fontSize: Double
    var columnWidth: Double
    var focusMode: Bool
    var typewriter: Bool
    var lineNumbers: Bool
    var repetitions: Bool = false
    var repetitionWindow: Int = 50
    var paragraphSpacing: Double = 0.5

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        let tv = ZenTextView(usingTextLayoutManager: false)
        tv.isRichText = false
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        // No system spell checker: LanguageTool and the AI proofreader do that work, with the book's dictionary.
        tv.isContinuousSpellCheckingEnabled = false
        tv.isGrammarCheckingEnabled = false
        tv.autoresizingMask = [.width]
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.textContainer?.widthTracksTextView = true
        tv.insertionPointColor = NSColor.controlAccentColor
        tv.delegate = context.coordinator
        tv.textStorage?.delegate = context.coordinator
        tv.bridge = bridge
        scroll.documentView = tv
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak bridge] _ in
            MainActor.assumeIsolated {
                bridge?.minimap?.needsDisplay = true
                bridge?.textView?.closeIssueCard()
            }
        }
        // Dragging the scroller reads too (the wheel and trackpad come through scrollWheel).
        NotificationCenter.default.addObserver(forName: NSScrollView.willStartLiveScrollNotification, object: scroll, queue: .main) { [weak bridge] _ in
            MainActor.assumeIsolated { bridge?.textView?.focusVeilReading() }
        }
        bridge.textView = tv
        context.coordinator.textView = tv
        apply(to: tv, context: context, force: true)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? ZenTextView else { return }
        context.coordinator.parent = self
        apply(to: tv, context: context, force: false)
    }

    private func apply(to tv: ZenTextView, context: Context, force: Bool) {
        let coord = context.coordinator
        bridge.session = session
        var needsStyle = force
        var theme = EditorTheme(fontName: fontName, fontSize: CGFloat(fontSize))
        theme.paragraphGap = CGFloat(paragraphSpacing)
        if tv.theme.fontName != theme.fontName || tv.theme.fontSize != theme.fontSize || tv.theme.paragraphGap != theme.paragraphGap {
            tv.theme = theme; needsStyle = true
        }
        tv.focusMode = focusMode
        if tv.typewriter != typewriter { tv.typewriter = typewriter; tv.recenter() }
        tv.showLineNumbers = lineNumbers
        tv.lang = session.manifest.lang
        tv.repetitionWindow = repetitionWindow
        tv.showRepetitions = repetitions
        if tv.maxColumnWidth != CGFloat(columnWidth) { tv.maxColumnWidth = CGFloat(columnWidth); tv.recenter() }
        if let lang = BookLanguage(code: session.manifest.lang).spellCheckerLanguage {
            NSSpellChecker.shared.automaticallyIdentifiesLanguages = false
            _ = NSSpellChecker.shared.setLanguage(lang)
        }

        // Chapter switched (or text replaced from outside): load new text.
        if coord.loadedChapter != session.selectedChapterID || (tv.string != session.text && !coord.isEditing) {
            let isNewChapter = coord.loadedChapter != session.selectedChapterID
            // Read before the text goes in: setting it moves the caret to the end, which would be remembered.
            let saved = session.savedSelection
            coord.loadedChapter = session.selectedChapterID
            // Loading text is not an edit: notes are re-found instead of being dragged along.
            coord.loading = true
            bridge.loading = true
            defer { bridge.loading = false }
            tv.string = session.text
            coord.loading = false
            session.notes.resolveAll(in: tv.string)
            needsStyle = true
            if isNewChapter {
                bridge.focusedStem = nil
                tv.closeIssueCard()
                tv.applyBookDictionary(bridge.proof?.dictionary ?? [])
                bridge.proof?.chapterOpened()
                tv.undoManager?.removeAllActions()
                let loc = min(saved, (tv.string as NSString).length)
                tv.setSelectedRange(NSRange(location: loc, length: 0))
                DispatchQueue.main.async {
                    // Back where the author left off, in the middle of the window.
                    tv.scrollToCenter(offset: loc)
                    tv.window?.makeFirstResponder(tv)
                }
            }
        }
        if needsStyle { tv.restyle() }

        // Jump to a search result once the right chapter is loaded.
        if let target = session.pendingSelection, coord.loadedChapter == session.selectedChapterID {
            DispatchQueue.main.async {
                session.pendingSelection = nil
                let length = (tv.string as NSString).length
                guard NSMaxRange(target) <= length else { return }
                tv.window?.makeFirstResponder(tv)
                tv.setSelectedRange(target)
                tv.scrollRangeToVisible(target)
                tv.showFindIndicator(for: target)
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
        var parent: ZenEditorView
        weak var textView: ZenTextView?
        var loadedChapter: String?
        var isEditing = false
        var loading = false

        /// Every change to the characters (typing, auto-correct, undo) moves the notes with it.
        func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                         range editedRange: NSRange, changeInLength delta: Int) {
            guard editedMask.contains(.editedCharacters), !loading else { return }
            parent.session.notes.applyEdit(edited: editedRange, delta: delta)
            parent.bridge.keyEngine?.applyEdit(edited: editedRange, delta: delta)
        }
        private var lastFocusParagraph = NSRange(location: NSNotFound, length: 0)

        init(_ parent: ZenEditorView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = textView else { return }
            isEditing = true
            tv.closeIssueCard()
            parent.session.textDidChange(tv.string)
            isEditing = false
            parent.bridge.proof?.textChanged()
            tv.restyle()
            // Finish layout now (chapters are small) so the view has its final height before it draws,
            // and redraw: new paragraphs at the end were sometimes left undrawn.
            if let lm = tv.layoutManager, let tc = tv.textContainer { lm.ensureLayout(for: tc) }
            tv.needsDisplay = true
            tv.updateFocusVeil()
            tv.centerCaret()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let tv = textView else { return }
            let r = tv.selectedRange()
            if !loading { parent.session.rememberSelection(r.location) }
            parent.bridge.selectedRange = r
            parent.bridge.selectedText = r.length > 0 ? (tv.string as NSString).substring(with: r) : ""
            // AppKit reports selection changes while it is still processing an edit: changing the text or its
            // attributes right here corrupts the layout manager (the end of the chapter stops being laid out).
            // Auto-fixes and focus restyling wait until the edit is over.
            tv.updateFocusVeil(animated: !loading)
            guard !selectionWorkPending else { tv.centerCaret(); return }
            selectionWorkPending = true
            // Restyling unfolds the * of the paragraph clicked into, which reflows it: after a click,
            // wait until a double- or triple-click is over so its next click finds the same word.
            let delay = tv.selectingWithMouse ? NSEvent.doubleClickInterval : 0
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, let tv = self.textView else { return }
                self.selectionWorkPending = false
                self.parent.bridge.proof?.selectionChanged()
                self.restyleParagraphs(tv)
            }
            tv.centerCaret()
        }
        private var selectionWorkPending = false

        /// Scene markers and emphasis show their syntax only under the caret.
        private func restyleParagraphs(_ tv: ZenTextView) {
            if NSEvent.pressedMouseButtons & 1 != 0 {
                // Still dragging a selection: try again when the button is up.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.restyleParagraphs(tv) }
                return
            }
            let p = MarkdownStyler.paragraphRange(in: tv.string as NSString, at: tv.selectedRange().location)
            guard p != lastFocusParagraph else { return }
            let ns = tv.string as NSString
            let marker = { (r: NSRange) in r.location != NSNotFound && NSMaxRange(r) <= ns.length
                && Scenes.pattern.firstMatch(in: tv.string, range: r) != nil }
            let folds = { (r: NSRange) in marker(r) || MarkdownStyler.hasEmphasis(tv.string, in: r) }
            let restyle = folds(p) || folds(lastFocusParagraph)
            lastFocusParagraph = p
            if restyle { tv.restyle() }
        }
    }
}
