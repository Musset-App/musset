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
    /// Opens a Bible sheet, from the card on a name.
    @ObservationIgnored var openSheet: ((String) -> Void)?
    /// Opens the rename preview for a sheet.
    @ObservationIgnored var renameEntry: ((String) -> Void)?
    /// Opens the book's sources.
    @ObservationIgnored var openSources: (() -> Void)?
    /// Names of the cast are underlined in the text (dotted, ink blue).
    var showNames = UserDefaults.standard.object(forKey: "showNames") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showNames, forKey: "showNames"); textView?.needsDisplay = true }
    }
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

/// A pane's editors, one per chapter in its tabs, kept while the tab is: going to another tab and back finds the
/// same editor, with its undo history, its caret and its place.
@MainActor
final class EditorCache {
    struct Kept {
        let scroll: NSScrollView
        let coordinator: ZenEditorView.Coordinator
    }
    private var kept: [String: Kept] = [:]

    static func key(pane: String, chapter: String) -> String { pane + "|" + chapter }
    subscript(key: String) -> Kept? {
        get { kept[key] }
        set { kept[key] = newValue }
    }
    /// The editors of tabs that are gone are let go.
    func keep(only keys: Set<String>) {
        guard kept.keys.contains(where: { !keys.contains($0) }) else { return }
        kept = kept.filter { keys.contains($0.key) }
    }
}

final class ZenTextView: NSTextView {
    /// Each editor keeps its own undo: with several panes, the window's would mix chapters and be wiped by each load.
    private let ownUndo = UndoManager()
    override var undoManager: UndoManager? { ownUndo }

    /// The Edit menu's Undo and Redo come here: left to the window, they would go to the window's own history,
    /// which holds none of this text's steps.
    @objc func undo(_ sender: Any?) { if ownUndo.canUndo { ownUndo.undo() } }
    @objc func redo(_ sender: Any?) { if ownUndo.canRedo { ownUndo.redo() } }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(undo(_:)):
            (item as? NSMenuItem)?.title = ownUndo.undoMenuItemTitle
            return ownUndo.canUndo
        case #selector(redo(_:)):
            (item as? NSMenuItem)?.title = ownUndo.redoMenuItemTitle
            return ownUndo.canRedo
        default:
            return super.validateUserInterfaceItem(item)
        }
    }
    /// Called when the author clicks or tabs into this editor: its chapter becomes the one written in.
    var onFocus: (() -> Void)?
    /// The editor the author is in: the one the app's menus, notes and proofreading speak to.
    var isLive: Bool { bridge?.textView === self }

    /// An editor that leaves the window (its tab is no longer shown) is no longer the one the menus speak to.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil, bridge?.textView === self { bridge?.textView = nil }
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok {
            onFocus?()
            bridge?.textView = self
        }
        return ok
    }

    // MARK: Drags onto the panes
    // A chapter, a sheet or a tab dragged over the text goes to the panes, not into the text as a line of code.

    /// The panes of this editor's window.
    weak var paneDrops: PaneDrops?

    private func paneTarget(_ sender: NSDraggingInfo) -> (wire: String, target: PaneDropTarget?)? {
        guard let wire = sender.draggingPasteboard.string(forType: .string), ShelfDrag(wire: wire) != nil,
              let content = window?.contentView else { return nil }
        // The window's point, in SwiftUI's global space (top left).
        var p = content.convert(sender.draggingLocation, from: nil)
        if !content.isFlipped { p.y = content.bounds.height - p.y }
        return (wire, paneDrops?.target(at: p))
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let found = paneTarget(sender) else { return super.draggingEntered(sender) }
        paneDrops?.hover = found.target
        return found.target == nil ? [] : Self.paneOperation(sender)
    }

    /// An operation the drag allows, or AppKit refuses the drop: SwiftUI's drags only allow a copy.
    private static func paneOperation(_ sender: NSDraggingInfo) -> NSDragOperation {
        let allowed = sender.draggingSourceOperationMask
        for op: NSDragOperation in [.move, .copy, .generic] where allowed.contains(op) { return op }
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let found = paneTarget(sender) else { return super.draggingUpdated(sender) }
        if paneDrops?.hover != found.target { paneDrops?.hover = found.target }
        return found.target == nil ? [] : Self.paneOperation(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        paneDrops?.hover = nil
        super.draggingExited(sender)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        paneTarget(sender) != nil || super.prepareForDragOperation(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let found = paneTarget(sender) else { return super.performDragOperation(sender) }
        paneDrops?.hover = nil
        TearOff.shared.handled = true
        guard let target = found.target, let session = bridge?.session else { return false }
        // After the drag is done: the drop may take this editor away.
        DispatchQueue.main.async { session.dropOnPanes(found.wire, at: target) }
        return true
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        if let sender, paneTarget(sender) != nil { return }
        super.concludeDragOperation(sender)
    }

    /// Set while the app itself edits the text, so revision mode does not record it.
    var untracked = false

    /// The caret never stops inside hidden correction syntax: it jumps over it in the direction it was going.
    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        // Asked at every move of the caret: the marks found at the last edit, not a new search of the chapter.
        guard !untracked, case let hidden = currentMarks().hidden, !hidden.isEmpty else {
            return super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        }
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

    var theme = EditorTheme(fontName: "", fontSize: 18) { didSet { styled = nil } }
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
    private(set) var drawnIssues: [AutoProofreader.Issue] = []
    /// The cast's names drawn at the last draw, for the hover card.
    private var drawnNames: [(range: NSRange, path: String)] = []
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
    /// Start offset of every line, for line numbers: found when a number is asked for, forgotten at each edit.
    private var lineStartsKept: [Int]?
    private var lineStarts: [Int] {
        watchStorage()
        if let lineStartsKept { return lineStartsKept }
        let ns: NSString = textStorage?.mutableString ?? ""
        var starts = [0]
        var i = 0
        while i < ns.length {
            // Paragraphs, not visual lines: a ⇧↩ line break (U+2028) stays in the same numbered paragraph.
            let r = ns.paragraphRange(for: NSRange(location: i, length: 0))
            i = NSMaxRange(r)
            if i < ns.length || ns.hasSuffix("\n") { starts.append(i) }
        }
        lineStartsKept = starts
        return starts
    }

    // MARK: What the last styling pass left

    /// Goes up at every change of the characters: what is computed from the text is kept until it moves.
    private(set) var textVersion = 0
    private var storageWatch: NSObjectProtocol?
    /// The one edit made since the last styling pass, and whether there were more.
    private var lastEdit: (range: NSRange, delta: Int)?
    private var severalEdits = false
    /// How the text stood when it was last styled: enough to restyle only the paragraphs an edit or the caret touches.
    private struct Styled {
        var length: Int
        /// The paragraph whose markup was shown (the caret's).
        var caretParagraph: NSRange
        /// Notes and corrections running over several paragraphs.
        var spans: [NSRange]
        var live: Bool
    }
    private var styled: Styled?
    /// Whole-chapter passes so far: the tests check that typing in a paragraph does not make one.
    private(set) var wholePasses = 0
    private var marksKept: (version: Int, marks: [Revisions.Mark], hidden: [NSRange])?
    private var namesKept: (version: Int, visible: NSRange, matcher: AnyObject?, found: [(range: NSRange, path: String)])?
    private var repetitionTask: Task<Void, Never>?

    deinit { if let storageWatch { NotificationCenter.default.removeObserver(storageWatch) } }

    /// Every change of the characters is counted from here on (typing, undo, a text loaded, the app's own fixes).
    private func watchStorage() {
        guard storageWatch == nil, let storage = textStorage else { return }
        // Nothing kept from before the text was watched.
        textVersion += 1
        lineStartsKept = nil
        storageWatch = NotificationCenter.default.addObserver(forName: NSTextStorage.didProcessEditingNotification, object: storage, queue: nil) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let storage = note.object as? NSTextStorage, storage.editedMask.contains(.editedCharacters) else { return }
                self.textVersion += 1
                self.lineStartsKept = nil
                if self.lastEdit != nil { self.severalEdits = true }
                self.lastEdit = (storage.editedRange, storage.changeInLength)
            }
        }
    }

    /// The corrections in the text and their hidden syntax, found once per state of the text.
    private func currentMarks() -> (marks: [Revisions.Mark], hidden: [NSRange]) {
        watchStorage()
        guard let storage = textStorage else { return ([], []) }
        if let k = marksKept, k.version == textVersion, storage.editedMask.isEmpty { return (k.marks, k.hidden) }
        guard storage.mutableString.range(of: "{").location != NSNotFound else {
            if storage.editedMask.isEmpty { marksKept = (textVersion, [], []) }
            return ([], [])
        }
        let marks = Revisions.marks(in: string)
        let hidden = Revisions.hidden(of: marks)
        // In the middle of an edit the text may still move under the same count: not kept.
        if storage.editedMask.isEmpty { marksKept = (textVersion, marks, hidden) }
        return (marks, hidden)
    }

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

    /// Styles the whole chapter: when it loads, when the theme or the proofreader's findings change, and whenever
    /// restyling a paragraph alone can't be trusted.
    func restyle() { restyleWhole(after: nil) }

    /// `edit`: the one edit this pass follows, when it stands in for a paragraph's restyle.
    private func restyleWhole(after edit: (range: NSRange, delta: Int)?) {
        guard let storage = textStorage else { return }
        // Called in the middle of an edit (from a notification or an observer): restyle once it is done.
        guard storage.editedMask.isEmpty else {
            DispatchQueue.main.async { [weak self] in self?.restyle() }
            return
        }
        watchStorage()
        wholePasses += 1
        let text = string
        let caret = selectedRange().location
        let marks = currentMarks().marks
        MarkdownStyler.style(storage, theme: theme, caret: caret, marks: marks)
        let issues = liveIssues(in: text)
        if let issues {
            storage.beginEditing()
            for issue in issues { underline(issue, in: storage) }
            storage.endEditing()
        }
        styleDone(text, caret: caret, marks: marks, spans: MarkdownStyler.spans(in: text, marks: marks), issues: issues)
        refreshSearchHighlights(after: edit)
    }

    /// After typing: only the paragraphs the edit and the caret touch are restyled, as a whole pass would leave them.
    /// Anything unsure (several edits at once, a note or a correction running over paragraphs nearby) is a whole pass.
    func restyleAfterEdit() {
        guard let storage = textStorage, storage.editedMask.isEmpty, let last = styled, let edit = lastEdit, !severalEdits,
              last.live == isLive, storage.length == last.length + edit.delta else {
            return restyleWhole(after: severalEdits ? nil : lastEdit)
        }
        let text = string
        let ns = text as NSString
        let caret = selectedRange().location
        let marks = currentMarks().marks
        let spans = MarkdownStyler.spans(in: text, marks: marks)
        // The edit, and a character on each side: a paragraph split or joined changes its neighbour too.
        let lo = max(0, edit.range.location - 1), hi = min(ns.length, NSMaxRange(edit.range) + 1)
        guard let dirty = MarkdownStyler.reach(of: NSRange(location: lo, length: hi - lo), in: ns, lists: theme.lists) else { return restyleWhole(after: edit) }
        // Where the edit was, in the text as it stood.
        let oldEnd = NSMaxRange(edit.range) - edit.delta
        func moved(_ r: NSRange) -> NSRange? {
            if NSMaxRange(r) < edit.range.location { return r }
            if r.location > oldEnd { return NSRange(location: r.location + edit.delta, length: r.length) }
            return nil
        }
        for span in last.spans {
            guard let now = moved(span), NSIntersectionRange(now, dirty).length == 0 else { return restyleWhole(after: edit) }
        }
        var ranges = [dirty]
        // The paragraph whose markup was shown, and the one the caret is in now.
        if let was = moved(last.caretParagraph) {
            guard let r = MarkdownStyler.reach(of: NSRange(location: min(was.location, ns.length), length: 0), in: ns, lists: theme.lists) else { return restyleWhole(after: edit) }
            ranges.append(r)
        }
        guard let here = MarkdownStyler.reach(of: NSRange(location: min(caret, ns.length), length: 0), in: ns, lists: theme.lists) else { return restyleWhole(after: edit) }
        ranges.append(here)
        ranges = Self.merged(ranges)
        guard !spans.contains(where: { span in ranges.contains { NSIntersectionRange(span, $0).length > 0 } }) else { return restyleWhole(after: edit) }

        // The underlines outside these paragraphs must be the ones already there.
        let issues = liveIssues(in: text)
        if let issues {
            func inside(_ r: NSRange) -> Bool { ranges.contains { $0.location <= r.location && NSMaxRange(r) <= NSMaxRange($0) } }
            func outside(_ r: NSRange) -> Bool { !ranges.contains { NSIntersectionRange($0, r).length > 0 } }
            var before: [String] = []
            for old in drawnIssues {
                guard let now = moved(old.range) else {
                    // Under the edit: what is left of it must lie in the paragraphs restyled.
                    let start = min(old.range.location, edit.range.location)
                    let end = min(ns.length, max(NSMaxRange(old.range) + edit.delta, NSMaxRange(edit.range)))
                    guard inside(NSRange(location: start, length: max(0, end - start))) else { return restyleWhole(after: edit) }
                    continue
                }
                if inside(now) { continue }
                guard outside(now) else { return restyleWhole(after: edit) }
                before.append(Self.underlineKey(now, old.fix))
            }
            var after: [String] = []
            for issue in issues where !inside(issue.range) {
                guard outside(issue.range) else { return restyleWhole(after: edit) }
                after.append(Self.underlineKey(issue.range, issue.fix))
            }
            guard before.sorted() == after.sorted() else { return restyleWhole(after: edit) }
        }

        MarkdownStyler.style(storage, theme: theme, caret: caret, in: ranges)
        if let issues {
            storage.beginEditing()
            for issue in issues where ranges.contains(where: { NSIntersectionRange($0, issue.range).length > 0 }) { underline(issue, in: storage) }
            storage.endEditing()
        }
        styleDone(text, caret: caret, marks: marks, spans: spans, issues: issues)
        refreshSearchHighlights(after: edit)
    }

    /// The caret went to another paragraph: the markup of the one it left folds, the one it entered unfolds.
    func restyleCaret() {
        guard let storage = textStorage, storage.editedMask.isEmpty, let last = styled, lastEdit == nil, !severalEdits,
              last.live == isLive, storage.length == last.length else { return restyle() }
        let text = string
        let ns = text as NSString
        let caret = selectedRange().location
        guard let here = MarkdownStyler.reach(of: NSRange(location: min(caret, ns.length), length: 0), in: ns, lists: theme.lists),
              let was = MarkdownStyler.reach(of: NSRange(location: min(last.caretParagraph.location, ns.length), length: 0), in: ns, lists: theme.lists) else { return restyle() }
        let ranges = Self.merged([here, was])
        guard !last.spans.contains(where: { span in ranges.contains { NSIntersectionRange(span, $0).length > 0 } }) else { return restyle() }
        let issues = liveIssues(in: text)
        if let issues {
            guard issues.map({ Self.underlineKey($0.range, $0.fix) }) == drawnIssues.map({ Self.underlineKey($0.range, $0.fix) }) else { return restyle() }
            // An underline that runs out of these paragraphs would be cut.
            for issue in issues where ranges.contains(where: { NSIntersectionRange($0, issue.range).length > 0 }) {
                guard ranges.contains(where: { $0.location <= issue.range.location && NSMaxRange(issue.range) <= NSMaxRange($0) }) else { return restyle() }
            }
        }
        MarkdownStyler.style(storage, theme: theme, caret: caret, in: ranges)
        if let issues {
            storage.beginEditing()
            for issue in issues where ranges.contains(where: { NSIntersectionRange($0, issue.range).length > 0 }) { underline(issue, in: storage) }
            storage.endEditing()
        }
        styleDone(text, caret: caret, marks: currentMarks().marks, spans: last.spans, issues: issues)
        showWhatChanged()
    }

    /// The proofreader's findings, for the editor one is in; nil elsewhere (another pane's chapter shows none).
    private func liveIssues(in text: String) -> [AutoProofreader.Issue]? {
        guard isLive, let proof = bridge?.proof else { return nil }
        return proof.issues(in: text)
    }

    private func underline(_ issue: AutoProofreader.Issue, in storage: NSTextStorage) {
        // AI suggestions purple, LanguageTool blue, pending obvious fixes red; all distinct from the system's spelling dots.
        let color: NSColor = issue.fix.isObvious ? .systemRed : (issue.fix.isLanguageTool ? .systemBlue : .systemPurple)
        storage.addAttributes([.underlineStyle: NSUnderlineStyle.thick.rawValue | NSUnderlineStyle.patternDot.rawValue,
                               .underlineColor: color], range: issue.range)
    }

    /// An underline as it is drawn: where, and in which colour.
    private static func underlineKey(_ r: NSRange, _ fix: ProofFix) -> String {
        "\(r.location):\(r.length):\(fix.isObvious ? "o" : (fix.isLanguageTool ? "l" : "a"))"
    }

    /// Ranges in order, those that overlap or meet made one.
    private static func merged(_ ranges: [NSRange]) -> [NSRange] {
        var out: [NSRange] = []
        for r in ranges.sorted(by: { $0.location < $1.location }) {
            if let last = out.last, r.location <= NSMaxRange(last) { out[out.count - 1] = NSUnionRange(last, r) } else { out.append(r) }
        }
        return out
    }

    /// What every styling pass ends with: the counts shown elsewhere, and what the next pass starts from.
    private func styleDone(_ text: String, caret: Int, marks: [Revisions.Mark], spans: [NSRange], issues: [AutoProofreader.Issue]?) {
        if bridge?.pendingRevisions != marks.count { bridge?.pendingRevisions = marks.count }
        if let issues {
            drawnIssues = issues
            bridge?.proof?.updateCount(issues, text: text)
        }
        typingAttributes = theme.typingAttributes
        styled = Styled(length: (text as NSString).length, caretParagraph: MarkdownStyler.paragraphRange(in: text as NSString, at: caret), spans: spans, live: isLive)
        lastEdit = nil
        severalEdits = false
    }

    /// The search term, the repetitions mode or its window changed: found again in the whole chapter.
    func refreshSearchHighlights() { refreshSearchHighlights(after: nil) }

    /// After an edit the repetitions follow the text at once (what comes after the edit moves with it) and are
    /// counted again when the hand stops: counting a whole chapter at each letter was the cost.
    private func refreshSearchHighlights(after edit: (range: NSRange, delta: Int)?) {
        searchRanges = BookSearch.ranges(of: bridge?.searchQuery ?? "", in: string)
        repetitionTask?.cancel()
        if showRepetitions, let edit, let kept = repetitions {
            repetitions = kept.moved(by: edit)
            repetitionTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled, let self, self.showRepetitions else { return }
                self.repetitions = Repetitions.analyze(self.string, lang: self.lang, window: self.repetitionWindow)
                self.bridge?.publish(self.repetitions)
                self.needsDisplay = true
                self.bridge?.minimap?.needsDisplay = true
            }
        } else {
            repetitions = showRepetitions ? Repetitions.analyze(string, lang: lang, window: repetitionWindow) : nil
            bridge?.publish(repetitions)
        }
        if hoverStem != nil && repetitions == nil { hoverStem = nil }
        if edit != nil { showWhatChanged() } else { needsDisplay = true }
        bridge?.minimap?.needsDisplay = true
    }

    /// After typing or a move of the caret: lays out what is on screen, a screen below it and the caret's paragraph,
    /// and redraws what shows. `needsDisplay = true` on a text view lays out its whole height first, and TextKit lays
    /// out again everything that follows an edit: on a long chapter that was most of the cost of a letter. The rest
    /// of the chapter is laid out by TextKit in the background, as it does when a chapter loads.
    private func showWhatChanged() {
        guard let lm = layoutManager, let tc = textContainer, let storage = textStorage else { return }
        let origin = textContainerOrigin
        var shown = visibleRect.offsetBy(dx: -origin.x, dy: -origin.y)
        shown.size.height *= 2
        lm.ensureLayout(forBoundingRect: shown, in: tc)
        // Near the end, down to the end: the view has its final height before it draws (new paragraphs at the end
        // were sometimes left undrawn).
        let p = MarkdownStyler.paragraphRange(in: storage.mutableString, at: selectedRange().location)
        let end = min(storage.length, NSMaxRange(p) + 4000)
        lm.ensureLayout(forCharacterRange: NSRange(location: p.location, length: end - p.location))
        setNeedsDisplay(visibleRect, avoidAdditionalLayout: true)
        // Once the hand rests, the whole chapter: the page has its true height again, whatever TextKit got to.
        restLayout?.cancel()
        restLayout = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self, let lm = self.layoutManager, let tc = self.textContainer else { return }
            lm.ensureLayout(for: tc)
            // What was drawn over the text meanwhile (line numbers, highlights) is drawn again on a finished layout.
            self.setNeedsDisplay(self.visibleRect, avoidAdditionalLayout: true)
        }
    }
    private var restLayout: Task<Void, Never>?

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
        // The storage's own length: `string` copies the chapter at each call, and this is asked for every highlight drawn.
        guard let lm = layoutManager, let tc = textContainer, NSMaxRange(range) <= (textStorage?.length ?? 0) else { return [] }
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
        guard let lm = layoutManager, let tc = textContainer, let ns: NSString = textStorage?.mutableString, NSMaxRange(range) <= ns.length else { return [] }
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
        // Another pane's chapter: only its text and its names; what belongs to the chapter one is in stays there.
        let live = isLive
        if live, let bridge { fill(bridge.flagged, NSColor.systemOrange.withAlphaComponent(0.18)) }
        // WordStar's block, marked with ⌃K B and ⌃K K: it stays lit until it is moved, copied or hidden.
        if live, let block = bridge?.keyEngine?.visibleBlock { fill([block], NSColor.controlAccentColor.withAlphaComponent(0.2)) }
        if live, let bridge, bridge.blameOn {
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
        if live {
            drawCommentBubbles(in: rect, visible: visible)
            drawNotes(in: rect, visible: visible)
        }
        drawNames(in: rect, visible: visible)
        if live { fill(searchRanges, NSColor.systemYellow.withAlphaComponent(0.45)) }
        if showLineNumbers { drawLineNumbers(in: rect) }
    }

    var activeStem: String? { hoverStem ?? bridge?.focusedStem }

    /// A small speech bubble where each comment is (its text shows on hover).
    private func drawCommentBubbles(in rect: NSRect, visible: NSRange) {
        commentBubbles = []
        // The marks found at the last edit, and only those on screen: nothing is searched or laid out while drawing.
        let commented = currentMarks().marks.filter {
            // (A comment's bubble sits by the character before it.)
            $0.second != nil && ($0.kind == .comment || $0.kind == .highlight)
                && (visible.length == 0 || NSIntersectionRange(NSRange(location: max(0, $0.range.location - 1), length: $0.range.length + 1), visible).length > 0)
        }
        guard !commented.isEmpty, let ns: NSString = textStorage?.mutableString else { return }
        let tint = NSColor(srgbRed: 0.48, green: 0.23, blue: 0.85, alpha: 1)
        for m in commented {
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
        let text = string
        let search = visible.length > 0 ? visible : NSRange(location: 0, length: (text as NSString).length)
        let left = textContainerOrigin.x + tc.lineFragmentPadding
        let right = textContainerOrigin.x + tc.size.width - tc.lineFragmentPadding
        NSColor.separatorColor.setFill()
        for m in Scenes.pattern.matches(in: text, range: search) {
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
        var title = (bridge?.session?.manifest.lang ?? "fr").hasPrefix("fr") ? "Nouvelle scène" : "New scene"
        // A level that is not called a scene has its own name to type over.
        if let words = bridge?.session?.words, !words.usual(.scene) { title = words.name(.scene) }
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
        // The source list after « [@ » takes the arrows, Return, Tab and Escape while it is open.
        if citeList.isOpen, handleCitationKey(event) { return }
        // The chosen keyboard mode reads the key first; whatever it leaves is the text view's.
        if let bridge, bridge.keys.handle(event, in: self) { return }
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if isReturn, event.modifierFlags.contains(.shift), !hasMarkedText() {
            // A line break inside the paragraph; on disk it is a Markdown hard break (two trailing spaces).
            insertText("  \u{2028}", replacementRange: selectedRange())
            return
        }
        if isReturn, event.modifierFlags.intersection([.shift, .option, .command, .control]).isEmpty, !hasMarkedText(),
           selectedRange().length == 0, breakOnReturn() { return }
        super.keyDown(with: event)
    }

    /// Return on an empty paragraph: a new scene; Return again, just below the scene: a new chapter (see `Breaks`).
    private func breakOnReturn() -> Bool {
        let lang = bridge?.session?.manifest.lang ?? "fr"
        guard let step = Breaks.onReturn(string, caret: selectedRange().location, lang: lang, scene: bridge?.session?.manifest.level(.scene).name) else { return false }
        switch step {
        case let .scene(at, marker):
            let insert = marker + "\n"
            let r = NSRange(location: at, length: 0)
            untracked = true
            defer { untracked = false }
            guard shouldChangeText(in: r, replacementString: insert) else { return false }
            textStorage?.replaceCharacters(in: r, with: insert)
            didChangeText()
            undoManager?.setActionName(BookTerm.sceneBreak.in(lang))
            setSelectedRange(NSRange(location: at + (insert as NSString).length, length: 0))
            return true
        case let .chapter(before, after):
            // In a track, another version or Ultra Focus there is no chapter to split: Return stays a Return.
            guard let session = bridge?.session, session.canSplitChapter else { return false }
            session.textDidChange(string)
            return session.splitChapter(before: before, after: after) != nil
        }
    }

    /// Backspace just below a scene marker takes the marker away, a step back from Return.
    override func deleteBackward(_ sender: Any?) {
        if selectedRange().length == 0, !hasMarkedText(), let r = Breaks.onBackspace(string, caret: selectedRange().location) {
            untracked = true
            defer { untracked = false }
            if shouldChangeText(in: r, replacementString: "") {
                textStorage?.replaceCharacters(in: r, with: "")
                didChangeText()
                setSelectedRange(NSRange(location: r.location, length: 0))
                return
            }
        }
        keepSelectionAsCut()
        super.deleteBackward(sender)
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

    /// A passage of some length that is cut or deleted goes to the Bible's Cuts, with where it came from.
    override func cut(_ sender: Any?) {
        keepSelectionAsCut()
        super.cut(sender)
    }

    override func deleteForward(_ sender: Any?) {
        keepSelectionAsCut()
        super.deleteForward(sender)
    }

    override func delete(_ sender: Any?) {
        keepSelectionAsCut()
        super.delete(sender)
    }

    /// A sentence or more: fewer words than this are a correction, not a cut.
    static let cutWords = 6

    private func keepSelectionAsCut() {
        let r = selectedRange()
        // In revision mode a deletion stays in the text, struck through: nothing is cut yet.
        guard r.length > 0, isLive, bridge?.trackChanges != true else { return }
        let ns = string as NSString
        let cutText = ns.substring(with: r)
        guard BookStore.wordCount(cutText) >= Self.cutWords else { return }
        bridge?.session?.keepCut(cutText, before: ns.substring(to: r.location))
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
        } else if let name = name(under: point) {
            scheduleCard("name:\(name.range)") { [weak self] in self?.showNameCard(name) }
        } else if let cite = citation(at: characterIndexForInsertion(at: point)), rects(for: cite.range).contains(where: { $0.insetBy(dx: -1, dy: -2).contains(point) }) {
            scheduleCard("cite:\(cite.range)") { [weak self] in self?.showCitationCard(cite) }
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

    // MARK: Names

    /// The cast's names on screen, found at each draw in the visible text only (one pass of the Bible's matcher).
    private func drawNames(in rect: NSRect, visible: NSRange) {
        guard bridge?.showNames == true, let bible = bridge?.session?.bible, visible.length > 0 else { drawnNames = []; return }
        // Drawn again at each blink of the caret: the names are looked for once per text, per part of it on screen.
        watchStorage()
        let matcher = bible.matcher
        if let k = namesKept, k.version == textVersion, k.visible == visible, k.matcher === matcher.pattern {
            drawnNames = k.found
        } else {
            drawnNames = matcher.matches(in: string, range: visible)
            namesKept = (textVersion, visible, matcher.pattern, drawnNames)
        }
        guard !drawnNames.isEmpty else { return }
        let path = NSBezierPath()
        for m in drawnNames {
            for box in underlineRects(for: m.range) where box.intersects(rect) {
                path.move(to: NSPoint(x: box.minX, y: box.maxY - 1.5))
                path.line(to: NSPoint(x: box.maxX, y: box.maxY - 1.5))
            }
        }
        NSColor(srgbRed: 0.18, green: 0.29, blue: 0.78, alpha: 0.55).setStroke()
        path.lineWidth = 1
        path.setLineDash([1.5, 2], count: 2, phase: 0)
        path.stroke()
    }

    private func name(under point: NSPoint) -> (range: NSRange, path: String)? {
        let index = characterIndexForInsertion(at: point)
        return drawnNames.first { candidates($0.range, index) && rects(for: $0.range).contains { $0.insetBy(dx: -1, dy: -2).contains(point) } }
    }

    func showNameCard(_ name: (range: NSRange, path: String)) {
        guard let session = bridge?.session, let anchor = rects(for: name.range).first else { return }
        let card = NameCard(path: name.path, session: session, open: { [weak self] in
            self?.closeIssueCard()
            self?.bridge?.openSheet?(name.path)
        }, rename: { [weak self] in
            self?.closeIssueCard()
            self?.bridge?.renameEntry?(name.path)
        })
        presentCard(card, at: anchor, key: "name:\(name.range)")
    }

    // MARK: Citations

    /// The list of sources shown after « [@ », and what is typed after it.
    let citeList = CitationList()
    private var citePopover: NSPopover?

    /// After each change: a « [@… » just before the caret opens the list of sources; anything else closes it.
    func updateCitationCompletion() {
        guard let session = bridge?.session else { return }
        let caret = selectedRange()
        let ns = string as NSString
        guard caret.length == 0, caret.location <= ns.length else { closeCitationList(); return }
        let lo = max(0, caret.location - 60)
        let before = ns.substring(with: NSRange(location: lo, length: caret.location - lo))
        guard let r = before.range(of: "\\[@([\\p{L}\\p{N}_:.-]*)$", options: .regularExpression) else { closeCitationList(); return }
        let query = String(before[r].dropFirst(2))
        let refs = References.entries(session)
        let f = Fold.name(query)
        citeList.items = refs.filter { e in
            query.isEmpty || [e.meta["citekey"] ?? "", e.meta["author"] ?? "", e.title].contains { Fold.name($0).contains(f) }
        }
        .sorted { References.citeCount(of: $0, in: session) > References.citeCount(of: $1, in: session) }
        .prefix(8).map { $0 }
        citeList.index = min(citeList.index, max(0, citeList.items.count - 1))
        citeList.queryRange = NSRange(location: caret.location - (query as NSString).length, length: (query as NSString).length)
        citeList.session = session
        citeList.pick = { [weak self] e in self?.insertCitation(e) }
        citeList.newSource = { [weak self] in self?.closeCitationList(); self?.bridge?.openSources?() }
        guard citePopover?.isShown != true else { return }
        let anchor = firstRect(forCharacterRange: caret, actualRange: nil)
        let local = convert(window?.convertFromScreen(anchor) ?? .zero, from: nil)
        let host = NSHostingController(rootView: CitationListView(list: citeList))
        host.sizingOptions = .preferredContentSize
        let pop = NSPopover()
        pop.behavior = .semitransient
        pop.animates = false
        pop.contentViewController = host
        pop.show(relativeTo: NSRect(x: local.minX, y: local.minY, width: 2, height: max(local.height, 16)), of: self, preferredEdge: .maxY)
        citePopover = pop
        citeList.isOpen = true
    }

    func closeCitationList() {
        citePopover?.close()
        citePopover = nil
        citeList.isOpen = false
        citeList.index = 0
    }

    private func handleCitationKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 125: citeList.index = min(citeList.index + 1, max(0, citeList.items.count - 1)); return true
        case 126: citeList.index = max(citeList.index - 1, 0); return true
        case 36, 76, 48:
            guard let e = citeList.items[safe: citeList.index] else { closeCitationList(); return false }
            insertCitation(e); return true
        case 53: closeCitationList(); return true
        default: return false
        }
    }

    /// The source's key in place of what was typed, the bracket closed, the caret before it for « , p. 12 ».
    private func insertCitation(_ e: BibleEntry) {
        guard let key = e.meta["citekey"] else { return }
        let ns = string as NSString
        let r = citeList.queryRange
        let closes = NSMaxRange(r) < ns.length && ns.character(at: NSMaxRange(r)) == 0x5D
        closeCitationList()
        insertText(key + (closes ? "" : "]"), replacementRange: r)
        setSelectedRange(NSRange(location: r.location + (key as NSString).length, length: 0))
    }

    /// The citation `[@key, p. 12]` the index is in, if any.
    private func citation(at index: Int) -> (range: NSRange, key: String, page: Int?)? {
        let ns = string as NSString
        guard index <= ns.length else { return nil }
        let lo = max(0, index - 80), hi = min(ns.length, index + 80)
        let window = NSRange(location: lo, length: hi - lo)
        guard let re = try? NSRegularExpression(pattern: "\\[[^\\]\\n@]*@([\\p{L}\\p{N}_:.#$%&+?<>~/-]+)([^\\]\\n]*)\\]") else { return nil }
        for m in re.matches(in: string, range: window) where NSLocationInRange(index, m.range) {
            let rest = ns.substring(with: m.range(at: 2))
            let page = rest.range(of: "[0-9]+", options: .regularExpression).map { Int(rest[$0]) } ?? nil
            return (m.range, ns.substring(with: m.range(at: 1)), page)
        }
        return nil
    }

    func showCitationCard(_ cite: (range: NSRange, key: String, page: Int?)) {
        guard let session = bridge?.session, let anchor = rects(for: cite.range).first else { return }
        let card = CitationCard(key: cite.key, page: cite.page, session: session, open: { [weak self] path in
            self?.closeIssueCard()
            self?.bridge?.openSheet?(path)
        }, sources: { [weak self] in
            self?.closeIssueCard()
            self?.bridge?.openSources?()
        })
        presentCard(card, at: anchor, key: "cite:\(cite.range)")
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
        add(bridge?.session?.words.wholePiece ?? L("Whole Chapter"), whole)
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
        guard let lm = layoutManager, let tc = textContainer, let ns: NSString = textStorage?.mutableString else { return }
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
            noteItems.append(ClosureMenuItem(title: L("Open Thread")) { [weak self] in self?.bridge?.openThread(id) })
        }
        noteItems.append(ClosureMenuItem(title: bridge?.session?.words.newSceneHere ?? L("New Scene Here")) { [weak self] in self?.beginScene() })
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
    /// The chapter this editor shows; nil: the one the author is in.
    var doc: ChapterDoc? = nil
    /// Clicking into this editor: its pane and its chapter become the ones written in.
    var onFocus: (() -> Void)? = nil
    /// The panes of the window it is in, for drags over the text.
    var drops: PaneDrops? = nil
    /// The pane the author is in (with the same chapter open in two panes, only one is).
    var live = true
    var fontName: String
    var fontSize: Double
    var columnWidth: Double
    var focusMode: Bool
    var typewriter: Bool
    var lineNumbers: Bool
    var repetitions: Bool = false
    var repetitionWindow: Int = 50
    var paragraphSpacing: Double = 0.5

    /// The pane's kept editors and this one's place among them; nil: an editor of its own, gone with its view.
    var cache: EditorCache? = nil
    var cacheKey: String? = nil

    func makeCoordinator() -> Coordinator {
        if let cache, let cacheKey, let kept = cache[cacheKey] { return kept.coordinator }
        return Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        // The tab comes back: its editor as it was left, undo history included.
        if let cache, let cacheKey, let kept = cache[cacheKey], let tv = kept.scroll.documentView as? ZenTextView {
            context.coordinator.parent = self
            context.coordinator.wasLive = nil
            if isLive { bridge.textView = tv }
            apply(to: tv, context: context, force: false)
            return kept.scroll
        }
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
        NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak bridge, weak coord = context.coordinator, weak scroll] _ in
            MainActor.assumeIsolated {
                // Where this chapter is scrolled, once it is shown as it was.
                if let coord, let scroll, !coord.loading, !coord.restoringScroll, coord.loadedChapter != nil,
                   let doc = coord.parent.shown, doc.chapterID == coord.loadedChapter {
                    doc.scrollY = scroll.contentView.bounds.origin.y
                }
                bridge?.minimap?.needsDisplay = true
                bridge?.textView?.closeIssueCard()
            }
        }
        // Dragging the scroller reads too (the wheel and trackpad come through scrollWheel).
        NotificationCenter.default.addObserver(forName: NSScrollView.willStartLiveScrollNotification, object: scroll, queue: .main) { [weak bridge] _ in
            MainActor.assumeIsolated { bridge?.textView?.focusVeilReading() }
        }
        if isLive { bridge.textView = tv }
        context.coordinator.textView = tv
        if let cache, let cacheKey { cache[cacheKey] = .init(scroll: scroll, coordinator: context.coordinator) }
        apply(to: tv, context: context, force: true)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? ZenTextView else { return }
        context.coordinator.parent = self
        apply(to: tv, context: context, force: false)
    }

    /// The chapter shown here.
    var shown: ChapterDoc? { doc ?? session.focused }
    /// This editor shows the chapter the author is in.
    var isLive: Bool { live && (doc == nil || doc === session.focused) }

    private func apply(to tv: ZenTextView, context: Context, force: Bool) {
        let coord = context.coordinator
        bridge.session = session
        tv.onFocus = onFocus
        tv.paneDrops = drops
        // The pane one is in has the app's editor; another pane's editor keeps its chapter, quietly.
        if isLive, bridge.textView !== tv { bridge.textView = tv }
        // The keys follow the pane one is in: ⌘Z, typing and the menus go to its editor, not to the one just left.
        if coord.wasLive != isLive {
            coord.wasLive = isLive
            coord.followFocus(tv)
        }
        var needsStyle = force
        var theme = EditorTheme(fontName: fontName, fontSize: CGFloat(fontSize))
        theme.paragraphGap = CGFloat(paragraphSpacing)
        // What the book reads as a list (Book Settings › Structure): the items are styled again when it changes.
        theme.lists = session.manifest.listOptions
        if tv.theme.fontName != theme.fontName || tv.theme.fontSize != theme.fontSize || tv.theme.paragraphGap != theme.paragraphGap
            || tv.theme.lists != theme.lists {
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

        // Another pane's chapter: its text, kept up to date, nothing of the chapter one is in.
        if !isLive, let shown {
            if coord.loadedChapter != shown.chapterID || (tv.string != shown.text && !coord.isEditing) {
                let fresh = coord.loadedChapter != shown.chapterID
                coord.loadedChapter = shown.chapterID
                coord.loading = true
                let keep = tv.selectedRange()
                tv.string = shown.text
                coord.loading = false
                let loc = fresh ? min(session.state.selections[shown.chapterID] ?? 0, (tv.string as NSString).length) : min(keep.location, (tv.string as NSString).length)
                tv.setSelectedRange(NSRange(location: loc, length: 0))
                // Its undo steps were for the text it had: written in another pane since, they no longer fit.
                tv.undoManager?.removeAllActions()
                if fresh { coord.restoreScroll(shown.scrollY, in: tv) }
                needsStyle = true
            }
            if needsStyle { tv.restyle() }
            return
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
                // A chapter just split by Return: ⌘Z puts it back together.
                if let split = session.pendingSplitUndo, split.created == session.selectedChapterID {
                    session.pendingSplitUndo = nil
                    tv.undoManager?.registerUndo(withTarget: session) { $0.undoSplit(split) }
                    tv.undoManager?.setActionName(session.words.newPiece)
                }
                let loc = min(saved, (tv.string as NSString).length)
                tv.setSelectedRange(NSRange(location: loc, length: 0))
                let scrolled = shown?.scrollY
                if scrolled != nil { coord.restoreScroll(scrolled, in: tv) }
                DispatchQueue.main.async {
                    // Back where the page was (a tab gone back to), else where the author left off, mid-window.
                    if scrolled == nil { tv.scrollToCenter(offset: loc) }
                    if tv.window?.firstResponder is ZenTextView == false || tv.isLive { tv.window?.makeFirstResponder(tv) }
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
        /// While the page goes back to where it was scrolled: the moves on the way are not where it was.
        var restoringScroll = false
        /// Whether this editor was the one written in at the last pass; nil: just shown.
        var wasLive: Bool?

        /// The editor of the pane one is in takes the keys from another editor (or from no one); the one just left
        /// gives them up, so that ⌘Z on a board or a sheet no longer undoes a chapter elsewhere.
        func followFocus(_ tv: ZenTextView) {
            DispatchQueue.main.async { [weak self, weak tv] in
                guard let self, let tv, let window = tv.window else { return }
                let first = window.firstResponder
                if self.parent.isLive {
                    if first !== tv, first is ZenTextView || first === window { window.makeFirstResponder(tv) }
                } else if first === tv {
                    window.makeFirstResponder(nil)
                }
            }
        }

        /// Scrolls back to where the page was, once its text is laid out.
        func restoreScroll(_ y: CGFloat?, in tv: ZenTextView) {
            guard let y else { return }
            restoringScroll = true
            DispatchQueue.main.async { [weak self, weak tv] in
                defer { self?.restoringScroll = false }
                guard let tv, let scroll = tv.enclosingScrollView else { return }
                if let lm = tv.layoutManager, let tc = tv.textContainer {
                    // Laid out down to that point, so the page is tall enough to be there.
                    lm.ensureLayout(forBoundingRect: NSRect(x: 0, y: 0, width: tc.size.width, height: y + scroll.contentView.bounds.height), in: tc)
                }
                let maxY = max(0, tv.frame.height - scroll.contentView.bounds.height)
                scroll.contentView.scroll(to: NSPoint(x: 0, y: min(y, maxY)))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
        }

        /// Every change to the characters (typing, auto-correct, undo) moves the notes with it.
        func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                         range editedRange: NSRange, changeInLength delta: Int) {
            guard editedMask.contains(.editedCharacters), !loading, parent.isLive else { return }
            parent.session.notes.applyEdit(edited: editedRange, delta: delta)
            parent.bridge.keyEngine?.applyEdit(edited: editedRange, delta: delta)
        }
        private var lastFocusParagraph = NSRange(location: NSNotFound, length: 0)

        init(_ parent: ZenEditorView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = textView else { return }
            // Typing goes to the chapter of the editor typed in.
            if !parent.isLive { parent.onFocus?() }
            isEditing = true
            tv.closeIssueCard()
            parent.session.textDidChange(tv.string)
            isEditing = false
            parent.bridge.proof?.textChanged()
            parent.session.spotter.textChanged()
            parent.session.keeper.textChanged()
            tv.updateCitationCompletion()
            // Restyles the paragraphs touched, lays out what shows and redraws it (see `showWhatChanged`).
            tv.restyleAfterEdit()
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
                // Typography and obvious fixes wait for the caret to leave its paragraph: not at every letter.
                let start = MarkdownStyler.paragraphRange(in: tv.textStorage?.mutableString ?? NSMutableString(), at: tv.selectedRange().location).location
                if start != self.lastFixParagraph {
                    self.lastFixParagraph = start
                    self.parent.bridge.proof?.selectionChanged()
                }
                self.restyleParagraphs(tv)
            }
            tv.centerCaret()
        }
        private var selectionWorkPending = false
        /// Where the caret's paragraph started when the automatic fixes last ran.
        private var lastFixParagraph = NSNotFound

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
            if restyle { tv.restyleCaret() }
        }
    }
}
