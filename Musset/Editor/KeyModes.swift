import AppKit

/// How the hands speak to the editor. One at a time, chosen in Settings › Keyboard.
/// ⌘ stays Musset's in every mode: the modes own ⌃, ⌥ and, in vi's NORMAL mode, plain letters.
enum KeyboardMode: String, CaseIterable, Identifiable {
    case mac, wordstar, vi, emacs

    var id: String { rawValue }
    static let defaultsKey = "keyboardMode"
    static var current: KeyboardMode { KeyboardMode(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .mac }

    var label: String {
        switch self {
        case .mac: "Mac / Word"
        case .wordstar: "WordStar"
        case .vi: "vi"
        case .emacs: "Emacs"
        }
    }

    var hint: String {
        switch self {
        case .mac: L("macOS’s shortcuts, Word’s.")
        case .wordstar: L("The diamond under the left hand, blocks that stay.")
        case .vi: L("Modal: NORMAL, INSERT, VISUAL. Esc belongs to the editor.")
        case .emacs: L("⌃ and ⌥ chords, the mark, the kill ring.")
        }
    }

    var signature: [String] {
        switch self {
        case .mac: ["⌥→", "⌘⌫", "⇧⌘E"]
        case .wordstar: ["⌃E ⌃S ⌃D ⌃X", "⌃K B", "⌃Q 1"]
        case .vi: ["ciw", "dap", "( )"]
        case .emacs: ["⌃K", "⌃Y ⌥Y", "⌥A ⌥E"]
        }
    }

    /// The few actions worth learning first, with their keys.
    var cheatSheet: [(what: String, keys: String)] {
        switch self {
        case .mac:
            [(L("Next word"), "⌥→"), (L("Start of line"), "⌘←"),
             (L("Next paragraph"), "⌥↓"), (L("Select the word"), "⌥⇧→"),
             (L("Delete the word"), "⌥⌫"), (L("Italic"), "⌘I"),
             (L("Find…").titled, "⌘F"), (L("Tracked changes"), "⇧⌘E")]
        case .wordstar:
            [(L("Up, left, right, down"), "⌃E ⌃S ⌃D ⌃X"), (L("Previous, next word"), "⌃A ⌃F"),
             (L("Delete the word"), "⌃T"), (L("Delete the line"), "⌃Y"),
             (L("Block start, end"), "⌃K B · ⌃K K"), (L("Move, copy the block"), "⌃K V · ⌃K C"),
             (L("Set, go to a marker"), "⌃K 1 · ⌃Q 1"), (L("Find…").titled, "⌃Q F")]
        case .vi:
            [(L("Insert, back to NORMAL"), "i · Échap"), (L("Next, previous word"), "w · b"),
             (L("Previous, next sentence"), "( )"), (L("Paragraph"), "{ }"),
             (L("Change the word"), "ciw"), (L("Delete the paragraph"), "dap"),
             (L("Repeat the last change"), "."), (L("Musset command"), ":")]
        case .emacs:
            [(L("Next, previous word"), "⌥F · ⌥B"), (L("Previous, next sentence"), "⌥A · Échap E"),
             (L("Kill to the end"), "⌃K"), (L("Yank, then the one before"), "⌃Y · ⌥Y"),
             (L("Set the mark"), "⌃Espace"), (L("Kill, copy the region"), "⌃W · ⌥W"),
             (L("Search as you type"), "⌃S"), (MainActor.assumeIsolated { AppCommand.hint(L("Command"), "app.palette") }, "⌥X")]
        }
    }

    var prefixHelp: String {
        switch self {
        case .mac: L("No prefix in this mode.")
        case .wordstar: L("After ⌃K or ⌃Q, the possible letters show if you hesitate.")
        case .vi: L("After d, c, y, g, the possible keys show if you hesitate.")
        case .emacs: L("After ⌃X or Esc, the possible keys show if you hesitate.")
        }
    }
}

/// What a prefix can be followed by, shown after a short hesitation.
struct KeyHint: Equatable {
    struct Item: Equatable, Hashable { let key: String; let label: String }
    let title: String
    let items: [Item]
}

/// Words, sentences and paragraphs in the editor's text (one line per paragraph).
enum Prose {
    static func isWord(_ c: unichar) -> Bool {
        guard let s = Unicode.Scalar(c) else { return false }
        return CharacterSet.alphanumerics.contains(s) || c == 0x2019 || c == 0x27
    }

    static func nextWordStart(_ s: NSString, _ i: Int) -> Int {
        var j = i
        while j < s.length, isWord(s.character(at: j)) { j += 1 }
        while j < s.length, !isWord(s.character(at: j)) { j += 1 }
        return j
    }

    static func previousWordStart(_ s: NSString, _ i: Int) -> Int {
        var j = i
        while j > 0, !isWord(s.character(at: j - 1)) { j -= 1 }
        while j > 0, isWord(s.character(at: j - 1)) { j -= 1 }
        return j
    }

    /// Just past the end of the word under or after `i`.
    static func wordEnd(_ s: NSString, _ i: Int) -> Int {
        var j = min(i + 1, s.length)
        while j < s.length, !isWord(s.character(at: j)) { j += 1 }
        while j < s.length, isWord(s.character(at: j)) { j += 1 }
        return j
    }

    /// The word at `i` (vi's `iw`); with `around`, its following spaces too (`aw`).
    static func word(_ s: NSString, at i: Int, around: Bool) -> NSRange {
        guard s.length > 0 else { return NSRange(location: 0, length: 0) }
        let at = min(i, s.length - 1)
        let inWord = isWord(s.character(at: at))
        var a = at, b = at
        while a > 0, isWord(s.character(at: a - 1)) == inWord, s.character(at: a - 1) != 10 { a -= 1 }
        while b < s.length, isWord(s.character(at: b)) == inWord, s.character(at: b) != 10 { b += 1 }
        if around { while b < s.length, s.character(at: b) == 32 { b += 1 } }
        return NSRange(location: a, length: b - a)
    }

    /// Sentences as a reader sees them: « Tu viens ? » demanda-t-elle. is one, so a « sentence » that starts
    /// in lower case (after a closing guillemet, a dash) belongs to the one before.
    static func sentences(_ s: NSString) -> [NSRange] {
        var out: [NSRange] = []
        s.enumerateSubstrings(in: NSRange(location: 0, length: s.length), options: [.bySentences, .substringNotRequired]) { _, r, _, _ in
            if let last = out.last, startsLower(s, r), s.character(at: NSMaxRange(last) - 1) != 10 {
                out[out.count - 1] = NSUnionRange(last, r)
            } else {
                out.append(r)
            }
        }
        return out
    }

    private static func startsLower(_ s: NSString, _ r: NSRange) -> Bool {
        var i = r.location
        let skip = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "»”\u{00A0}\u{202F}—–-"))
        while i < NSMaxRange(r), let c = Unicode.Scalar(s.character(at: i)), skip.contains(c) { i += 1 }
        guard i < NSMaxRange(r), let c = Unicode.Scalar(s.character(at: i)) else { return false }
        return CharacterSet.lowercaseLetters.contains(c)
    }

    static func nextSentenceStart(_ s: NSString, _ i: Int) -> Int {
        sentences(s).first { $0.location > i }?.location ?? s.length
    }

    static func previousSentenceStart(_ s: NSString, _ i: Int) -> Int {
        sentences(s).last { $0.location < i }?.location ?? 0
    }

    /// The sentence at `i`; with `around`, its trailing spaces too. Without, they are left out.
    static func sentence(_ s: NSString, at i: Int, around: Bool) -> NSRange {
        guard var r = sentences(s).first(where: { NSLocationInRange(i, $0) }) ?? sentences(s).last else { return NSRange(location: i, length: 0) }
        if !around {
            while r.length > 0, let c = Unicode.Scalar(s.character(at: NSMaxRange(r) - 1)), CharacterSet.whitespacesAndNewlines.contains(c) { r.length -= 1 }
        }
        return r
    }

    /// The paragraph (line) at `i`, its line break included when it has one.
    static func paragraph(_ s: NSString, at i: Int) -> NSRange {
        s.paragraphRange(for: NSRange(location: min(i, s.length), length: 0))
    }

    static func nextParagraphStart(_ s: NSString, _ i: Int) -> Int { min(NSMaxRange(paragraph(s, at: i)), s.length) }

    static func previousParagraphStart(_ s: NSString, _ i: Int) -> Int {
        let here = paragraph(s, at: i).location
        return here < i ? here : paragraph(s, at: max(0, here - 1)).location
    }
}

extension EditorBridge {
    /// The keyboard mode's state for this editor: created on first use.
    var keys: KeyEngine {
        if let k = keyEngine { return k }
        let k = KeyEngine(bridge: self)
        keyEngine = k
        return k
    }
}

/// Reads the keys of the chosen mode before the text view does. Returns false for whatever is the text view's.
@MainActor
final class KeyEngine {
    weak var bridge: EditorBridge?
    private(set) var mode: KeyboardMode = .mac

    init(bridge: EditorBridge) { self.bridge = bridge }

    // Prefixes (⌃K, ⌃Q, ⌃X, Esc as Meta) and the card that names what may follow.
    private var prefix: String?
    private var hintTask: Task<Void, Never>?

    // WordStar: a block that stays, markers 0–9.
    struct Spot { var chapter: String; var location: Int }
    private(set) var blockStart: Spot?
    private(set) var blockEnd: Spot?
    private var blockHidden = false
    private var markers: [Int: Spot] = [:]

    // Emacs: the mark and the kill ring.
    private var mark: Int?
    private var killRing: [String] = []
    private var yanked: (range: NSRange, index: Int)?

    // vi
    enum ViState { case normal, insert, visual, visualLine }
    private(set) var vi: ViState = .normal
    private var count = ""
    private var op: Character?
    private var opCount = 1
    private var objectKind: Character?
    private var pendingG = false
    private var visualAnchor = 0
    private var register: (text: String, lines: Bool) = ("", false)
    private var lastChange: ((ZenTextView) -> Void)?

    /// The caret drawn as a block: vi outside INSERT.
    var blockCaret: Bool { mode == .vi && vi != .insert }

    /// The WordStar block in the open chapter, when both ends are marked there and it is shown.
    var visibleBlock: NSRange? {
        guard mode == .wordstar, !blockHidden, let a = blockStart, let b = blockEnd, a.chapter == b.chapter,
              a.chapter == chapter, b.location > a.location else { return nil }
        return NSRange(location: a.location, length: b.location - a.location)
    }

    private var chapter: String { bridge?.session?.selectedChapterID ?? "" }

    // MARK: Entry

    func handle(_ event: NSEvent, in tv: ZenTextView) -> Bool {
        let wanted = KeyboardMode.current
        if wanted != mode { switchTo(wanted, tv) }
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        // ⌘ is Musset's in every mode. Marked text (an accent being composed) is the input method's.
        guard !flags.contains(.command), !tv.hasMarkedText() else { return false }
        let key = event.charactersIgnoringModifiers ?? ""
        let esc = event.keyCode == 53
        switch mode {
        case .mac: return false
        case .wordstar: return wordstar(key, flags, tv)
        case .emacs: return emacs(key, flags, esc: esc, tv)
        case .vi: return viKey(key, flags, esc: esc || (flags == [.control] && key == "["), tv)
        }
    }

    private func switchTo(_ m: KeyboardMode, _ tv: ZenTextView) {
        mode = m
        endPrefix()
        vi = m == .vi ? .normal : .insert
        count = ""; op = nil; objectKind = nil; pendingG = false
        mark = nil; yanked = nil
        tv.needsDisplay = true
        status()
    }

    /// Where an edit moved the marks: everything after it shifts with the text.
    func applyEdit(edited: NSRange, delta: Int) {
        guard delta != 0 else { return }
        let here = chapter
        func shift(_ s: inout Spot?) {
            guard var v = s, v.chapter == here, v.location > edited.location else { return }
            v.location = max(edited.location, v.location + delta)
            s = v
        }
        shift(&blockStart); shift(&blockEnd)
        for (k, v) in markers where v.chapter == here && v.location > edited.location {
            markers[k] = Spot(chapter: here, location: max(edited.location, v.location + delta))
        }
        if let m = mark, m > edited.location { mark = max(edited.location, m + delta) }
    }

    // MARK: Shared

    private func run(_ tv: ZenTextView, _ sel: Selector) { tv.doCommand(by: sel) }

    private func caret(_ tv: ZenTextView) -> Int { tv.selectedRange().location }

    private func move(_ tv: ZenTextView, to i: Int) {
        let r = NSRange(location: max(0, min(i, (tv.string as NSString).length)), length: 0)
        tv.setSelectedRange(r)
        tv.scrollRangeToVisible(r)
    }

    /// Through the text view's own edit path: undo, tracked changes and notes follow.
    private func replace(_ tv: ZenTextView, _ r: NSRange, with s: String) {
        let len = (tv.string as NSString).length
        guard r.location <= len else { return }
        let range = NSRange(location: r.location, length: min(r.length, len - r.location))
        tv.insertText(s, replacementRange: range)
    }

    private func text(_ tv: ZenTextView, _ r: NSRange) -> String {
        let s = tv.string as NSString
        guard NSMaxRange(r) <= s.length else { return "" }
        return s.substring(with: r)
    }

    private func toPasteboard(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ParagraphCodec.encode(s), forType: .string)
    }

    private func beginPrefix(_ p: String, _ items: [KeyHint.Item]) {
        prefix = p
        status()
        hintTask?.cancel()
        hintTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(UserDefaults.standard.object(forKey: "keyPrefixHelp") as? Bool == false ? 999_999 : 500))
            guard !Task.isCancelled, let self, self.prefix == p else { return }
            self.bridge?.keyHint = KeyHint(title: p, items: items)
        }
    }

    private func endPrefix() {
        prefix = nil
        hintTask?.cancel()
        bridge?.keyHint = nil
        status()
    }

    private func status() {
        guard let bridge else { return }
        var s: String?
        switch mode {
        case .vi:
            switch vi {
            case .normal: s = "NORMAL"
            case .insert: s = L("INSERT")
            case .visual: s = L("VISUAL")
            case .visualLine: s = L("VISUAL LINE")
            }
            let pending = count + (op.map(String.init) ?? "") + (objectKind.map(String.init) ?? "") + (pendingG ? "g" : "")
            if !pending.isEmpty { s! += "  " + pending }
        case .wordstar, .emacs:
            if let prefix { s = prefix + "…" } else if mode == .emacs, mark != nil { s = L("Mark set") }
        case .mac: s = nil
        }
        if bridge.keyStatus != s { bridge.keyStatus = s }
    }

    private func commandBar() { NotificationCenter.default.post(name: .mussetCommandBar, object: nil) }

    // MARK: WordStar

    private static let ctrlK: [KeyHint.Item] = [
        .init(key: "B", label: L("Block start")), .init(key: "K", label: L("Block end")),
        .init(key: "V", label: L("Move the block here")), .init(key: "C", label: L("Copy the block here")),
        .init(key: "Y", label: L("Delete the block")), .init(key: "H", label: L("Hide, show the block")),
        .init(key: "0–9", label: L("Set a marker")), .init(key: "S", label: L("Save")),
    ]
    private static let ctrlQ: [KeyHint.Item] = [
        .init(key: "S · D", label: L("Start, end of line")), .init(key: "R · C", label: L("Start, end of chapter")),
        .init(key: "B · K", label: L("Block start, end")), .init(key: "0–9", label: L("Go to a marker")),
        .init(key: "F", label: L("Find…").titled), .init(key: "A", label: L("Find and Replace…").titled),
        .init(key: "Y", label: L("Delete to end of line")),
    ]

    private func wordstar(_ key: String, _ flags: NSEvent.ModifierFlags, _ tv: ZenTextView) -> Bool {
        let k = key.lowercased()
        if let p = prefix {
            endPrefix()
            if p == "⌃K" { wordstarK(k, tv) } else { wordstarQ(k, tv) }
            return true
        }
        guard flags == [.control] else { return false }
        switch k {
        case "e": run(tv, #selector(NSResponder.moveUp(_:)))
        case "x": run(tv, #selector(NSResponder.moveDown(_:)))
        case "s": run(tv, #selector(NSResponder.moveBackward(_:)))
        case "d": run(tv, #selector(NSResponder.moveForward(_:)))
        case "a": move(tv, to: Prose.previousWordStart(tv.string as NSString, caret(tv)))
        case "f": move(tv, to: Prose.nextWordStart(tv.string as NSString, caret(tv)))
        case "r": run(tv, #selector(NSResponder.pageUp(_:)))
        case "c": run(tv, #selector(NSResponder.pageDown(_:)))
        case "g": run(tv, #selector(NSResponder.deleteForward(_:)))
        case "t":
            let s = tv.string as NSString, at = caret(tv)
            replace(tv, NSRange(location: at, length: Prose.nextWordStart(s, at) - at), with: "")
        case "y": replace(tv, Prose.paragraph(tv.string as NSString, at: caret(tv)), with: "")
        case "u": tv.undoManager?.undo()
        case "l": bridge?.findNext()
        case "n":
            let at = caret(tv)
            replace(tv, NSRange(location: at, length: 0), with: "\n")
            move(tv, to: at)
        case "k": beginPrefix("⌃K", Self.ctrlK)
        case "q": beginPrefix("⌃Q", Self.ctrlQ)
        default: return false
        }
        return true
    }

    private func wordstarK(_ k: String, _ tv: ZenTextView) {
        let here = chapter, at = caret(tv), sel = tv.selectedRange()
        switch k {
        case "b":
            blockStart = Spot(chapter: here, location: sel.length > 0 ? sel.location : at)
            if sel.length > 0 { blockEnd = Spot(chapter: here, location: NSMaxRange(sel)) }
            blockHidden = false
        case "k":
            blockEnd = Spot(chapter: here, location: sel.length > 0 ? NSMaxRange(sel) : at)
            blockHidden = false
        case "h": blockHidden.toggle()
        case "c", "v": placeBlock(tv, move: k == "v")
        case "y":
            if let r = visibleBlock { replace(tv, r, with: ""); blockStart = nil; blockEnd = nil }
        case "s", "d": bridge?.session?.flushSave()
        default:
            if let n = Int(k) { markers[n] = Spot(chapter: here, location: at) }
        }
        tv.needsDisplay = true
    }

    private func wordstarQ(_ k: String, _ tv: ZenTextView) {
        switch k {
        case "s": run(tv, #selector(NSResponder.moveToBeginningOfLine(_:)))
        case "d": run(tv, #selector(NSResponder.moveToEndOfLine(_:)))
        case "r": run(tv, #selector(NSResponder.moveToBeginningOfDocument(_:)))
        case "c": run(tv, #selector(NSResponder.moveToEndOfDocument(_:)))
        case "f": bridge?.openFind()
        case "a": bridge?.openFind(replace: true)
        case "y": run(tv, #selector(NSResponder.deleteToEndOfParagraph(_:)))
        case "b": if let s = blockStart { go(to: s, tv) }
        case "k": if let e = blockEnd { go(to: e, tv) }
        default:
            if let n = Int(k), let spot = markers[n] { go(to: spot, tv) }
        }
    }

    /// A spot in this chapter, or in another one, which opens.
    private func go(to spot: Spot, _ tv: ZenTextView) {
        if spot.chapter == chapter { move(tv, to: spot.location); return }
        guard let session = bridge?.session else { return }
        session.open(spot.chapter)
        session.pendingSelection = NSRange(location: spot.location, length: 0)
    }

    /// ⌃K C / ⌃K V: the block at the caret. From another chapter, it is copied, and moved only out of the book's version.
    private func placeBlock(_ tv: ZenTextView, move: Bool) {
        guard let a = blockStart, let b = blockEnd, a.chapter == b.chapter, b.location > a.location else { return }
        let at = caret(tv)
        if a.chapter == chapter {
            let r = NSRange(location: a.location, length: b.location - a.location)
            guard !NSLocationInRange(at, r) || at == r.location else { return }
            let body = text(tv, r)
            if move {
                tv.undoManager?.beginUndoGrouping()
                if at > r.location {
                    replace(tv, NSRange(location: at, length: 0), with: body)
                    replace(tv, r, with: "")
                    let start = at - r.length
                    blockStart = Spot(chapter: chapter, location: start); blockEnd = Spot(chapter: chapter, location: start + r.length)
                } else {
                    replace(tv, r, with: "")
                    replace(tv, NSRange(location: at, length: 0), with: body)
                    blockStart = Spot(chapter: chapter, location: at); blockEnd = Spot(chapter: chapter, location: at + r.length)
                }
                tv.undoManager?.endUndoGrouping()
            } else {
                replace(tv, NSRange(location: at, length: 0), with: body)
                blockStart = Spot(chapter: chapter, location: at); blockEnd = Spot(chapter: chapter, location: at + r.length)
            }
            return
        }
        // From another chapter: its text as the book has it.
        guard let session = bridge?.session else { return }
        let source = session.editorText(of: a.chapter) as NSString
        guard b.location <= source.length else { return }
        let r = NSRange(location: a.location, length: b.location - a.location)
        let body = source.substring(with: r)
        replace(tv, NSRange(location: at, length: 0), with: body)
        if move, session.removeFromChapter(a.chapter, range: r, expected: body) {
            blockStart = Spot(chapter: chapter, location: at); blockEnd = Spot(chapter: chapter, location: at + r.length)
        }
    }

    // MARK: Emacs

    private static let ctrlX: [KeyHint.Item] = [
        .init(key: "⌃S", label: L("Save")), .init(key: "U", label: L("Undo")),
        .init(key: "H", label: L("Select the chapter")), .init(key: "⌃X", label: L("Swap caret and mark")),
    ]
    private static let meta: [KeyHint.Item] = [
        .init(key: "F · B", label: L("Next, previous word")), .init(key: "A · E", label: L("Previous, next sentence")),
        .init(key: "D", label: L("Kill the word")), .init(key: "U · L · C", label: L("Upper, lower, capital")),
        .init(key: "T", label: L("Swap two words")), .init(key: "W", label: L("Copy the region")),
        .init(key: "X", label: L("Command Bar…").titled),
    ]
    /// ⌥ + these letters types accents on a Mac (é, ü, ç, ê, ñ, è): they stay accents; Esc then the letter does the command.
    private static let accentKeys: Set<String> = ["e", "u", "c", "i", "n", "`"]

    private func emacs(_ key: String, _ flags: NSEvent.ModifierFlags, esc: Bool, _ tv: ZenTextView) -> Bool {
        let k = key.lowercased()
        var wasYank = false
        defer { if !wasYank { yanked = nil } }
        if let p = prefix {
            endPrefix()
            if p == "Esc" { _ = emacsMeta(key, tv, yank: &wasYank); return true }
            switch (k, flags.contains(.control)) {
            case ("s", true): bridge?.session?.flushSave()
            case ("u", _): tv.undoManager?.undo()
            case ("h", _): tv.selectAll(nil)
            case ("x", true):
                if let m = mark { let here = caret(tv); move(tv, to: m); mark = here }
            default: break
            }
            return true
        }
        if esc, flags.isEmpty { beginPrefix("Esc", Self.meta); return true }
        if flags == [.control] {
            switch k {
            case "k":
                let s = tv.string as NSString, at = caret(tv)
                let para = Prose.paragraph(s, at: at)
                var end = NSMaxRange(para)
                if end > at, s.character(at: end - 1) == 10 { end -= 1 }
                let r = NSRange(location: at, length: max(end - at, at < s.length ? 1 : 0))
                kill(tv, r)
            case "y": yank(tv, index: 0); wasYank = true
            case "w": if let r = region(tv) { kill(tv, r) }
            case " ", "@":
                mark = caret(tv); status()
            case "g": mark = nil; tv.setSelectedRange(NSRange(location: caret(tv), length: 0)); status()
            case "s": bridge?.openFind()
            case "r": bridge?.findNext(forward: false)
            case "/", "_": tv.undoManager?.undo()
            case "v": run(tv, #selector(NSResponder.pageDown(_:)))
            case "x": beginPrefix("⌃X", Self.ctrlX)
            default: return false   // ⌃F ⌃B ⌃N ⌃P ⌃A ⌃E ⌃D ⌃T ⌃O: macOS already does them, the Emacs way.
            }
            return true
        }
        if flags.contains(.option), !flags.contains(.control) {
            if Self.accentKeys.contains(k) { return false }
            return emacsMeta(key, tv, yank: &wasYank)
        }
        return false
    }

    private func emacsMeta(_ key: String, _ tv: ZenTextView, yank wasYank: inout Bool) -> Bool {
        let s = tv.string as NSString, at = caret(tv)
        switch key.lowercased() {
        case "f": move(tv, to: Prose.wordEnd(s, max(0, at - 1)))
        case "b": move(tv, to: Prose.previousWordStart(s, at))
        case "d": kill(tv, NSRange(location: at, length: Prose.wordEnd(s, max(0, at - 1)) - at))
        case "a": move(tv, to: Prose.previousSentenceStart(s, at))
        case "e": move(tv, to: NSMaxRange(Prose.sentence(s, at: at, around: false)))
        case "t": run(tv, #selector(NSTextView.transposeWords(_:)))
        case "u": run(tv, #selector(NSResponder.uppercaseWord(_:)))
        case "l": run(tv, #selector(NSResponder.lowercaseWord(_:)))
        case "c": run(tv, #selector(NSResponder.capitalizeWord(_:)))
        case "w": if let r = region(tv) { killRing.insert(text(tv, r), at: 0); toPasteboard(text(tv, r)); mark = nil; tv.setSelectedRange(NSRange(location: caret(tv), length: 0)); status() }
        case "y":
            if let y = yanked { yank(tv, index: y.index + 1, replacing: y.range); wasYank = true }
        case "x": commandBar()
        case "<": run(tv, #selector(NSResponder.moveToBeginningOfDocument(_:)))
        case ">": run(tv, #selector(NSResponder.moveToEndOfDocument(_:)))
        case "v": run(tv, #selector(NSResponder.pageUp(_:)))
        case "{": move(tv, to: Prose.previousParagraphStart(s, at))
        case "}": move(tv, to: Prose.nextParagraphStart(s, at))
        default: return false
        }
        return true
    }

    /// The selection, or what lies between the mark and the caret.
    private func region(_ tv: ZenTextView) -> NSRange? {
        let sel = tv.selectedRange()
        if sel.length > 0 { return sel }
        guard let m = mark else { return nil }
        let at = caret(tv)
        return NSRange(location: min(m, at), length: abs(m - at))
    }

    private func kill(_ tv: ZenTextView, _ r: NSRange) {
        guard r.length > 0 else { return }
        let cut = text(tv, r)
        killRing.insert(cut, at: 0)
        if killRing.count > 30 { killRing.removeLast() }
        toPasteboard(cut)
        replace(tv, r, with: "")
        mark = nil
        status()
    }

    private func yank(_ tv: ZenTextView, index: Int, replacing: NSRange? = nil) {
        guard !killRing.isEmpty else { return }
        let i = index % killRing.count
        let body = killRing[i]
        let at = replacing ?? NSRange(location: caret(tv), length: 0)
        replace(tv, at, with: body)
        yanked = (NSRange(location: at.location, length: (body as NSString).length), i)
    }

    // MARK: vi

    private static let viOperator: [KeyHint.Item] = [
        .init(key: "w · b · e", label: L("To a word")), .init(key: "( )", label: L("To a sentence")),
        .init(key: "{ }", label: L("To a paragraph")), .init(key: "iw · aw", label: L("The word")),
        .init(key: "is · as", label: L("The sentence")), .init(key: "ip · ap", label: L("The paragraph")),
        .init(key: "$ · 0", label: L("To the end, the start of the line")),
    ]

    private func viKey(_ key: String, _ flags: NSEvent.ModifierFlags, esc: Bool, _ tv: ZenTextView) -> Bool {
        if vi == .insert {
            guard esc else { return false }
            vi = .normal
            let s = tv.string as NSString, at = caret(tv)
            if at > 0, s.character(at: at - 1) != 10 { move(tv, to: at - 1) }
            tv.needsDisplay = true
            status()
            return true
        }
        if esc {
            if vi == .visual || vi == .visualLine { tv.setSelectedRange(NSRange(location: caret(tv), length: 0)) }
            vi = .normal; count = ""; op = nil; objectKind = nil; pendingG = false
            endPrefix(); tv.needsDisplay = true; status()
            return true
        }
        if flags.contains(.control) {
            switch key.lowercased() {
            case "r": tv.undoManager?.redo()
            case "d", "f": run(tv, #selector(NSResponder.pageDown(_:)))
            case "u", "b": run(tv, #selector(NSResponder.pageUp(_:)))
            default: return false
            }
            return true
        }
        guard flags.subtracting(.shift).isEmpty, let c = key.first else { return true }
        viNormal(c, tv)
        status()
        return true
    }

    private var times: Int { max(1, Int(count) ?? 1) }

    private func viNormal(_ c: Character, _ tv: ZenTextView) {
        let s = tv.string as NSString
        let at = visualHead(tv)

        // Counts, then pending pieces.
        if c.isNumber, c != "0" || !count.isEmpty { count.append(c); return }
        if pendingG {
            pendingG = false
            if c == "g" { motionDone(tv, to: 0, linewise: true) }
            endPrefix()
            return
        }
        if let kind = objectKind, let opc = op {
            objectKind = nil
            let around = kind == "a"
            let r: NSRange?
            switch c {
            case "w": r = Prose.word(s, at: at, around: around)
            case "s": r = Prose.sentence(s, at: at, around: around)
            case "p": r = Prose.paragraph(s, at: at)
            default: r = nil
            }
            if let r { apply(opc, to: r, lines: c == "p", tv) }
            op = nil; count = ""; endPrefix()
            return
        }
        if op != nil, c == "i" || c == "a" { objectKind = c; return }

        let n = times
        if let target = motion(c, from: at, s, n) {
            let linewise = c == "j" || c == "k" || c == "G"
            if let opc = op {
                let inclusive = c == "e" || c == "$"
                var r = NSRange(location: min(at, target), length: abs(target - at))
                if inclusive, target >= at { r.length = min(s.length, target) - at }
                if linewise {
                    let a = Prose.paragraph(s, at: min(at, target)), b = Prose.paragraph(s, at: max(at, target))
                    r = NSUnionRange(a, b)
                }
                apply(opc, to: r, lines: linewise, tv)
                op = nil; count = ""; endPrefix()
            } else {
                motionDone(tv, to: target, linewise: false)
                count = ""
            }
            return
        }

        switch c {
        case "d", "c", "y", ">", "<":
            if vi == .visual || vi == .visualLine {
                let sel = tv.selectedRange()
                apply(c, to: sel, lines: vi == .visualLine, tv)
                return
            }
            if op == c {   // dd, cc, yy: whole paragraphs
                var r = Prose.paragraph(s, at: at)
                for _ in 1..<n { r = NSUnionRange(r, Prose.paragraph(s, at: min(s.length, NSMaxRange(r)))) }
                apply(c, to: r, lines: true, tv)
                op = nil; count = ""; endPrefix()
                return
            }
            op = c; opCount = n
            beginPrefix(String(c), Self.viOperator)
        case "g": pendingG = true
        case "x":
            let r = NSRange(location: at, length: min(n, s.length - at))
            if vi == .visual || vi == .visualLine { apply("d", to: tv.selectedRange(), lines: false, tv) } else { apply("d", to: r, lines: false, tv) }
        case "X":
            let r = NSRange(location: max(0, at - n), length: min(n, at))
            apply("d", to: r, lines: false, tv)
        case "p", "P": put(tv, after: c == "p")
        case "u": for _ in 0..<n { tv.undoManager?.undo() }
        case ".": if let change = lastChange { change(tv) }
        case "i": insertMode(tv, at: at)
        case "a": insertMode(tv, at: min(s.length, at + (at < s.length && s.character(at: at) != 10 ? 1 : 0)))
        case "I": insertMode(tv, at: Prose.paragraph(s, at: at).location)
        case "A":
            let p = Prose.paragraph(s, at: at)
            insertMode(tv, at: NSMaxRange(p) - (NSMaxRange(p) > p.location && s.character(at: NSMaxRange(p) - 1) == 10 ? 1 : 0))
        case "o", "O":
            let p = Prose.paragraph(s, at: at)
            let lineEnd = NSMaxRange(p) - (NSMaxRange(p) > p.location && s.character(at: NSMaxRange(p) - 1) == 10 ? 1 : 0)
            if c == "o" { replace(tv, NSRange(location: lineEnd, length: 0), with: "\n"); insertMode(tv, at: lineEnd + 1) }
            else { replace(tv, NSRange(location: p.location, length: 0), with: "\n"); insertMode(tv, at: p.location) }
        case "v", "V":
            let line = c == "V"
            if (vi == .visual && !line) || (vi == .visualLine && line) {
                vi = .normal; tv.setSelectedRange(NSRange(location: at, length: 0))
            } else {
                if vi == .normal { visualAnchor = at }
                vi = line ? .visualLine : .visual
                select(tv, head: at)
            }
            tv.needsDisplay = true
        case "/": bridge?.openFind()
        case "n": bridge?.findNext()
        case "N": bridge?.findNext(forward: false)
        case ":": commandBar()
        case "~":
            let r = NSRange(location: at, length: min(1, s.length - at))
            let ch = text(tv, r)
            replace(tv, r, with: ch == ch.uppercased() ? ch.lowercased() : ch.uppercased())
            move(tv, to: min(s.length, at + 1))
        default: break
        }
        if c != "g" { count = "" }
    }

    /// The caret position the motions start from: in VISUAL, the moving end of the selection.
    private var visualHeadIndex: Int?
    private func visualHead(_ tv: ZenTextView) -> Int {
        guard vi == .visual || vi == .visualLine, let h = visualHeadIndex else { return caret(tv) }
        return h
    }

    private func motion(_ c: Character, from at: Int, _ s: NSString, _ n: Int) -> Int? {
        var i = at
        for _ in 0..<n {
            switch c {
            case "h": i = max(0, i - 1)
            case "l": i = min(s.length, i + 1)
            case "w": i = Prose.nextWordStart(s, i)
            case "b": i = Prose.previousWordStart(s, i)
            case "e": i = max(i, Prose.wordEnd(s, i) - 1)
            case ")": i = Prose.nextSentenceStart(s, i)
            case "(": i = Prose.previousSentenceStart(s, i)
            case "}": i = Prose.nextParagraphStart(s, i)
            case "{": i = Prose.previousParagraphStart(s, i)
            case "0": i = Prose.paragraph(s, at: i).location
            case "$":
                let p = Prose.paragraph(s, at: i)
                i = NSMaxRange(p) - (NSMaxRange(p) > p.location && s.character(at: NSMaxRange(p) - 1) == 10 ? 1 : 0)
            case "j": i = Prose.nextParagraphStart(s, i)
            case "k": i = Prose.previousParagraphStart(s, i)
            case "G": i = s.length
            default: return nil
            }
        }
        return i
    }

    private func motionDone(_ tv: ZenTextView, to i: Int, linewise: Bool) {
        if vi == .visual || vi == .visualLine { select(tv, head: i) } else { move(tv, to: i) }
    }

    private func select(_ tv: ZenTextView, head: Int) {
        let s = tv.string as NSString
        visualHeadIndex = head
        var r = NSRange(location: min(visualAnchor, head), length: abs(head - visualAnchor) + 1)
        r.length = min(r.length, s.length - r.location)
        if vi == .visualLine { r = NSUnionRange(Prose.paragraph(s, at: r.location), Prose.paragraph(s, at: NSMaxRange(r) - (r.length > 0 ? 1 : 0))) }
        tv.setSelectedRange(r)
        tv.scrollRangeToVisible(NSRange(location: head, length: 0))
    }

    private func insertMode(_ tv: ZenTextView, at i: Int) {
        move(tv, to: i)
        vi = .insert
        tv.needsDisplay = true
    }

    /// d, c, y (and > <, kept for later) over a range; remembered for « . ».
    private func apply(_ opc: Character, to r: NSRange, lines: Bool, _ tv: ZenTextView) {
        guard r.length > 0 else { return }
        let body = text(tv, r)
        switch opc {
        case "y":
            register = (body, lines)
            toPasteboard(body)
            move(tv, to: r.location)
            vi = .normal
        case "d", "c":
            register = (body, lines)
            toPasteboard(body)
            if opc == "c", lines, body.hasSuffix("\n") {
                replace(tv, NSRange(location: r.location, length: r.length - 1), with: "")
            } else {
                replace(tv, r, with: "")
            }
            if opc == "c" { insertMode(tv, at: r.location) } else { vi = .normal; move(tv, to: min(r.location, (tv.string as NSString).length)) }
            if opc == "d" {
                let len = r.length, kindLines = lines
                lastChange = { [weak self] tv in
                    guard let self else { return }
                    let s = tv.string as NSString, at = self.caret(tv)
                    let again = kindLines ? Prose.paragraph(s, at: at) : NSRange(location: at, length: min(len, s.length - at))
                    self.apply("d", to: again, lines: kindLines, tv)
                }
            }
        default: break
        }
        tv.needsDisplay = true
    }

    private func put(_ tv: ZenTextView, after: Bool) {
        guard !register.text.isEmpty else { return }
        let s = tv.string as NSString, at = caret(tv)
        let where_: Int
        if register.lines {
            let p = Prose.paragraph(s, at: at)
            where_ = after ? NSMaxRange(p) : p.location
            var body = register.text
            if after, NSMaxRange(p) == s.length, !(s.hasSuffix("\n")) { body = "\n" + body.trimmingCharacters(in: .newlines) }
            replace(tv, NSRange(location: where_, length: 0), with: body)
            move(tv, to: where_ + (body.hasPrefix("\n") ? 1 : 0))
        } else {
            where_ = after ? min(s.length, at + 1) : at
            replace(tv, NSRange(location: where_, length: 0), with: register.text)
            move(tv, to: where_ + (register.text as NSString).length - 1)
        }
        lastChange = { [weak self] tv in self?.put(tv, after: after) }
    }
}

extension Notification.Name {
    /// vi's « : », Emacs's ⌥X: the command bar.
    static let mussetCommandBar = Notification.Name("mussetCommandBar")
}
