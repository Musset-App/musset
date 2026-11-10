import AppKit
import SwiftUI

/// Ultra Focus: the whole screen, only the text, only forward. ⌫, ⌦, the arrows, pasting, undoing and the mouse are refused.
/// One way out: « Quitter Ultra Focus » (⌃⌘U), unless a lock holds it until enough has been written.
/// What was written then goes into the chapter (a new scene, or at the end) or into the drafts.
enum UltraFocusDestination: String, CaseIterable, Identifiable {
    case newScene, end, drafts
    var id: String { rawValue }
    static let defaultsKey = "ultraDestination"
    static var current: Self { Self(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .end }
    var label: String {
        switch self {
        case .newScene: L("A new scene, at the end")
        case .end: L("At the end of the chapter")
        case .drafts: L("In the drafts")
        }
    }
}

/// How strict « forward only » is.
enum UltraFocusLevel: String, CaseIterable, Identifiable {
    case light, normal, hardcore
    var id: String { rawValue }
    static let defaultsKey = "ultraLevel"
    static var current: Self { Self(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .normal }
    var label: String {
        switch self {
        case .light: L("Light")
        case .normal: L("Normal")
        case .hardcore: L("Hardcore")
        }
    }
    var hint: String {
        switch self {
        case .light: L("⌫ and the arrows, inside the sentence being written.")
        case .normal: L("⌫ to fix what was just typed; the caret stays at the end.")
        case .hardcore: L("Nothing goes back: no ⌫, no arrows.")
        }
    }
    var refused: String {
        switch self {
        case .light: L("leaving the sentence ⌘V ⌘Z mouse")
        case .normal: L("arrows ⌦ ⌘V ⌘Z mouse")
        case .hardcore: L("⌫ ⌦ arrows ⌘V ⌘Z mouse")
        }
    }
}

enum UltraFocusLock: String, CaseIterable, Identifiable {
    case none, words, minutes
    var id: String { rawValue }
    static let defaultsKey = "ultraLock"
    static var current: Self { Self(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .none }
    static let wordGoal = 500
    static let minuteGoal = 25
    var label: String {
        switch self {
        case .none: L("None", ctx: "Aucun")
        case .words: L("\(Self.wordGoal) words")
        case .minutes: "\(Self.minuteGoal) min"
        }
    }
}

/// The small mark: a caret, then what comes next. Orange on near-black.
struct UltraFocusGlyph: View {
    var size: CGFloat = 16
    var body: some View {
        Canvas { ctx, s in
            let u = s.width / 16
            let orange = Color(red: 1, green: 0.416, blue: 0.239)
            ctx.fill(Path(roundedRect: CGRect(x: 2.5 * u, y: 3 * u, width: 2.4 * u, height: 10 * u), cornerRadius: 1.2 * u), with: .color(orange))
            var chevron = Path()
            chevron.move(to: CGPoint(x: 7.5 * u, y: 4.5 * u))
            chevron.addLine(to: CGPoint(x: 11 * u, y: 8 * u))
            chevron.addLine(to: CGPoint(x: 7.5 * u, y: 11.5 * u))
            ctx.stroke(chevron, with: .color(orange), style: StrokeStyle(lineWidth: 2.2 * u, lineCap: .round, lineJoin: .round))
        }
        .frame(width: size, height: size)
    }
}

@MainActor
@Observable
final class UltraFocusModel {
    /// What is written now, the only part that goes into the book.
    var text = ""
    /// The chapter as it was, shown above, read only: one writes after it.
    var context = ""
    var started = Date()
    var nudges = 0
    var lock = UltraFocusLock.none
    var fade = true
    var summary: (words: Int, minutes: Int, place: String)?
    var now = Date()

    var words: Int { BookStore.wordCount(text) }
    var minutes: Int { Int(now.timeIntervalSince(started) / 60) }

    var canExit: Bool {
        switch lock {
        case .none: true
        case .words: words >= UltraFocusLock.wordGoal
        case .minutes: minutes >= UltraFocusLock.minuteGoal
        }
    }

    var exitLabel: String {
        if canExit { return L("Leave Ultra Focus") }
        switch lock {
        case .words: return L("\(UltraFocusLock.wordGoal - words) more words")
        case .minutes: return L("\(UltraFocusLock.minuteGoal - minutes) more min")
        case .none: return ""
        }
    }
}

@MainActor
final class UltraFocus {
    static let shared = UltraFocus()

    let model = UltraFocusModel()
    private var window: NSWindow?
    private weak var session: BookSession?
    private var chapterID: String?
    private var destination = UltraFocusDestination.newScene
    private var savedOptions: NSApplication.PresentationOptions = []
    private var clock: Task<Void, Never>?
    private var lastSaved = ""

    var isOn: Bool { window != nil }

    func toggle(_ app: AppState) {
        if isOn { requestExit() } else { start(app) }
    }

    func start(_ app: AppState) {
        guard !isOn, let session = app.current, let ch = session.selectedChapter else { return }
        session.flushSave()
        self.session = session
        chapterID = ch.id
        destination = .current
        model.text = ""
        model.context = Self.readable(session.text)
        model.started = Date()
        model.now = Date()
        model.nudges = 0
        model.summary = nil
        model.lock = .current
        model.fade = UserDefaults.standard.object(forKey: "ultraFade") as? Bool ?? true
        lastSaved = ""

        let screen = NSApp.mainWindow?.screen ?? NSScreen.main
        let frame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let w = UltraWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.backgroundColor = NSColor(srgbRed: 0.043, green: 0.043, blue: 0.039, alpha: 1)
        w.isReleasedWhenClosed = false
        w.hasShadow = false
        w.contentView = NSHostingView(rootView: UltraFocusView(model: model) { [weak self] in self?.requestExit() })
        w.setFrame(frame, display: true)
        savedOptions = NSApp.presentationOptions
        NSApp.presentationOptions = [.hideDock, .hideMenuBar, .disableProcessSwitching, .disableHideApplication]
        w.makeKeyAndOrderFront(nil)
        window = w

        // The clock for the lock, and a copy on disk every few seconds: a forced quit loses nothing.
        clock = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard let self else { return }
                self.model.now = Date()
                self.saveRecovery()
            }
        }
    }

    /// The way out, if the lock allows it; otherwise the caret shivers.
    func requestExit() {
        guard isOn else { return }
        model.now = Date()
        guard model.canExit else { model.nudges += 1; return }
        finish(showSummary: true)
    }

    /// Puts what was written where it goes. `showSummary`: the words and the minutes, a moment, before Musset comes back.
    func finish(showSummary: Bool) {
        guard isOn, model.summary == nil else { return }
        clock?.cancel()
        let place = deposit()
        if showSummary, let place {
            model.summary = (model.words, max(1, model.minutes), place)
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(2.2))
                self?.close()
            }
        } else {
            close()
        }
    }

    private func close() {
        window?.orderOut(nil)
        window = nil
        NSApp.presentationOptions = savedOptions
        NSApp.mainWindow?.makeKeyAndOrderFront(nil)
        model.summary = nil
    }

    /// Returns where it went, in words; nil when nothing was written.
    private func deposit() -> String? {
        defer { removeRecovery() }
        guard let session, let chapterID else { return nil }
        return Self.deposit(model.text, into: session, chapter: chapterID, destination: destination, at: model.started)
    }

    /// The chapter to read above: its paragraphs, without Musset's markers and comments.
    static func readable(_ text: String) -> String {
        text.components(separatedBy: "\n")
            .filter { line in
                let t = line.trimmingCharacters(in: .whitespaces)
                return !(t.hasPrefix("<!--") && t.hasSuffix("-->"))
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func cleaned(_ text: String) -> String {
        text.replacingOccurrences(of: "\n{2,}", with: "\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func sceneTitle(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = UILang.locale
        f.setLocalizedDateFormatFromTemplate("dMMMHHmm")
        return "Ultra Focus, " + f.string(from: date)
    }

    @discardableResult
    static func deposit(_ raw: String, into session: BookSession, chapter id: String, destination: UltraFocusDestination, at date: Date) -> String? {
        let typed = cleaned(raw)
        guard !typed.isEmpty, let ch = session.anyChapter(id) else { return nil }
        switch destination {
        case .newScene, .end:
            if session.selectedChapterID != id { session.open(id) }
            let base = session.text
            let sep = base.isEmpty || base.hasSuffix("\n") ? "" : "\n"
            let marker = destination == .newScene ? Scenes.markerLine(sceneTitle(date)) + "\n" : ""
            session.replaceText(base + sep + marker + typed + "\n")
            return destination == .newScene
                ? L("In « \(ch.title) », a new scene at the end.")
                : L("At the end of « \(ch.title) ».")
        case .drafts:
            guard session.newDraft(title: sceneTitle(date), body: typed) else { return nil }
            return L("In the drafts.")
        }
    }

    // MARK: Recovery

    private struct Recovery: Codable { var chapter: String; var destination: String; var text: String; var started: Date }

    private static func recoveryURL(_ root: URL) -> URL { root.appendingPathComponent(".musset/ultrafocus.json") }

    private func saveRecovery() {
        guard let session, let chapterID, model.text != lastSaved else { return }
        lastSaved = model.text
        let r = Recovery(chapter: chapterID, destination: destination.rawValue, text: model.text, started: model.started)
        if let data = try? JSONEncoder().encode(r) { try? data.write(to: Self.recoveryURL(session.root), options: .atomic) }
    }

    private func removeRecovery() {
        guard let session else { return }
        try? FileManager.default.removeItem(at: Self.recoveryURL(session.root))
    }

    /// A book opened after Musset was stopped in Ultra Focus: what was written goes where it was meant to.
    static func recover(_ session: BookSession) {
        let url = recoveryURL(session.root)
        guard let data = try? Data(contentsOf: url), let r = try? JSONDecoder().decode(Recovery.self, from: data) else { return }
        try? FileManager.default.removeItem(at: url)
        let dest = UltraFocusDestination(rawValue: r.destination) ?? .newScene
        if deposit(r.text, into: session, chapter: r.chapter, destination: dest == .drafts ? .drafts : .newScene, at: r.started) != nil {
            session.lastError = L("Ultra Focus: what you wrote before Musset stopped is back.")
        }
    }
}

/// A window without a title bar that still takes the keyboard.
private final class UltraWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

extension BookSession {
    /// A draft chapter holding `body`, out of the book until it is dragged in.
    func newDraft(title: String, body: String) -> Bool {
        guard inManuscript() else { return false }
        let entry = newChapterEntry(title: title)
        do { try store.write("# \(title)\n\n" + ParagraphCodec.encode(body) + "\n", to: entry) } catch { lastError = error.localizedDescription; return false }
        manifest.drafts = draftChapters + [entry]
        saveManifest()
        chapterWords[entry.id] = BookStore.wordCount(body)
        shelfChanges += 1
        commitNow("musset: Ultra Focus dans les brouillons")
        return true
    }
}

// MARK: The screen

struct UltraFocusView: View {
    @Bindable var model: UltraFocusModel
    let exit: () -> Void
    @AppStorage("fontName") private var fontName = Typefaces.manuscript

    private static let ink = Color(red: 0.043, green: 0.043, blue: 0.039)

    var body: some View {
        ZStack {
            Self.ink.ignoresSafeArea()
            ForwardText(model: model, fontName: fontName)
                .modifier(Shiver(amount: CGFloat(model.nudges)))
                .animation(.easeOut(duration: 0.3), value: model.nudges)
            if model.fade {
                // What was written fades toward the top: the line being written stays clear.
                LinearGradient(stops: [.init(color: Self.ink.opacity(0.78), location: 0), .init(color: Self.ink.opacity(0.5), location: 0.16),
                                       .init(color: Self.ink.opacity(0.22), location: 0.34), .init(color: Self.ink.opacity(0.06), location: 0.46),
                                       .init(color: Self.ink.opacity(0), location: 0.54)], startPoint: .top, endPoint: .bottom)
                    .allowsHitTesting(false)
            }
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Button(action: exit) {
                        HStack(spacing: 9) {
                            UltraFocusGlyph(size: 13).opacity(0.65)
                            Text(model.exitLabel)
                            Text("⌃⌘U").font(.uiMono(10)).padding(.horizontal, 5).padding(.vertical, 1)
                                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.white.opacity(0.12)))
                        }
                        .font(.ui(12))
                        .foregroundStyle(Color(white: 0.54))
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(L("The only way out"))
                }
            }
            .padding(.trailing, 18).padding(.bottom, 16)
            if let s = model.summary { UltraSummary(words: s.words, minutes: s.minutes, place: s.place) }
        }
        .preferredColorScheme(.dark)
    }
}

private struct Shiver: GeometryEffect {
    var amount: CGFloat
    var animatableData: CGFloat { get { amount } set { amount = newValue } }
    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 4 * sin(amount * .pi * 3), y: 0))
    }
}

private struct UltraSummary: View {
    let words: Int
    let minutes: Int
    let place: String
    var body: some View {
        ZStack {
            Color(red: 0.043, green: 0.043, blue: 0.039)
            VStack(spacing: 18) {
                UltraFocusGlyph(size: 40)
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    Text("\(words.ui)").font(.ui(96, .bold)).monospacedDigit()
                    Text((words == 1 ? L("word in \(minutes) min") : L("words in \(minutes) min")))
                        .font(.ui(26)).foregroundStyle(Color(white: 0.7))
                }
                Text(place).font(.ui(16)).foregroundStyle(Color(white: 0.7))
            }
            .foregroundStyle(Color(white: 0.91))
        }
        .transition(.opacity)
    }
}

/// The page: wide margins, the caret's line held a little under the middle, the text only grows.
private struct ForwardText: NSViewRepresentable {
    let model: UltraFocusModel
    let fontName: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        let tv = ForwardOnlyTextView(frame: .zero)
        tv.autoresizingMask = [.width]
        tv.isVerticallyResizable = true
        tv.textContainer?.widthTracksTextView = true
        tv.drawsBackground = false
        tv.isRichText = false
        tv.allowsUndo = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.insertionPointColor = NSColor(srgbRed: 1, green: 0.416, blue: 0.239, alpha: 1)
        tv.textColor = NSColor(srgbRed: 0.91, green: 0.9, blue: 0.88, alpha: 1)
        let font = NSFont(name: fontName, size: 22) ?? NSFont(name: Typefaces.manuscript, size: 22) ?? .systemFont(ofSize: 22)
        tv.font = font
        let para = NSMutableParagraphStyle()
        para.lineSpacing = 22 * 0.75
        para.paragraphSpacing = 22 * 0.6
        tv.defaultParagraphStyle = para
        tv.typingAttributes = [.font: font, .foregroundColor: tv.textColor!, .paragraphStyle: para]
        // The chapter so far, dimmer, then a new paragraph: one writes after it, never in it.
        if !model.context.isEmpty {
            let before = NSAttributedString(string: model.context + "\n", attributes: [
                .font: font, .paragraphStyle: para,
                .foregroundColor: NSColor(srgbRed: 0.6, green: 0.59, blue: 0.57, alpha: 1)])
            tv.textStorage?.setAttributedString(before)
            tv.floor = before.length
        }
        tv.level = .current
        tv.changed = { [weak model] s in model?.text = s }
        tv.refused = { [weak model] in model?.nudges += 1 }
        scroll.documentView = tv
        DispatchQueue.main.async { tv.window?.makeFirstResponder(tv); tv.place() }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {}
}

final class ForwardOnlyTextView: NSTextView {
    /// Where one's own writing starts: what lies before is the chapter, shown, not written.
    var floor = 0
    var level = UltraFocusLevel.hardcore
    /// Called with what was written since `floor`.
    var changed: (String) -> Void = { _ in }
    var refused: () -> Void = {}
    private let column: CGFloat = 700

    private var end: Int { (string as NSString).length }

    /// The column in the middle; room above and below so the caret's line can sit at 56 % of the screen.
    func place() {
        guard let clip = enclosingScrollView?.contentView else { return }
        let h = clip.bounds.height
        let inset = NSSize(width: max(40, (bounds.width - column) / 2), height: h * 0.56)
        if textContainerInset != inset { textContainerInset = inset }
        guard let lm = layoutManager, let tc = textContainer else { return }
        lm.ensureLayout(for: tc)
        let glyph = lm.glyphIndexForCharacter(at: max(0, end - 1))
        var line = end == 0 ? NSRect(x: 0, y: 0, width: 1, height: 30) : lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        if string.hasSuffix("\n") { line = lm.extraLineFragmentRect.isEmpty ? line : lm.extraLineFragmentRect }
        let caretY = line.maxY + inset.height
        clip.scroll(to: NSPoint(x: 0, y: max(0, caretY - h * 0.56)))
        enclosingScrollView?.reflectScrolledClipView(clip)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        place()
    }

    /// Light: the start of the sentence being written, which the caret can't go before. Otherwise the end.
    private var lowest: Int {
        guard level == .light else { return end }
        let ns = string as NSString
        let here = min(selectedRanges.first?.rangeValue.location ?? end, end)
        let sentence = Prose.sentences(ns).last { $0.location <= max(floor, here) && ($0.location < end || $0.location == floor) }?.location ?? floor
        // A sentence that began in the chapter above starts, for this, where one's writing starts.
        return max(floor, sentence, lastParagraphStart)
    }

    private var lastParagraphStart: Int {
        let ns = string as NSString
        let r = ns.range(of: "\n", options: .backwards, range: NSRange(location: floor, length: end - floor))
        return r.location == NSNotFound ? floor : NSMaxRange(r)
    }

    private var caretAt: Int { level == .light ? min(max(selectedRange().location, floor), end) : end }

    override func insertText(_ insert: Any, replacementRange: NSRange) {
        var s = (insert as? String) ?? (insert as? NSAttributedString)?.string ?? ""
        let ns = string as NSString
        let at = hasMarkedText() ? markedRange() : NSRange(location: caretAt, length: 0)
        // l'homme → l’homme as it is typed.
        if s == "'", at.location > 0, let c = Unicode.Scalar(ns.character(at: at.location - 1)), CharacterSet.letters.contains(c) { s = "’" }
        super.insertText(s, replacementRange: at)
    }

    override func doCommand(by selector: Selector) {
        let back = [#selector(NSResponder.deleteBackward(_:)), #selector(NSResponder.deleteWordBackward(_:)),
                    #selector(NSResponder.deleteBackwardByDecomposingPreviousCharacter(_:))]
        let moves = [#selector(NSResponder.moveLeft(_:)), #selector(NSResponder.moveRight(_:)),
                     #selector(NSResponder.moveBackward(_:)), #selector(NSResponder.moveForward(_:)),
                     #selector(NSResponder.moveWordLeft(_:)), #selector(NSResponder.moveWordRight(_:)),
                     #selector(NSResponder.moveWordBackward(_:)), #selector(NSResponder.moveWordForward(_:)),
                     #selector(NSResponder.moveToEndOfLine(_:)), #selector(NSResponder.moveToEndOfParagraph(_:)),
                     #selector(NSResponder.moveToBeginningOfLine(_:)), #selector(NSResponder.moveToBeginningOfParagraph(_:))]
        switch selector {
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertLineBreak(_:)), #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            insertText("\n", replacementRange: NSRange(location: NSNotFound, length: 0))
        case NSSelectorFromString("noop:"):
            break
        case _ where back.contains(selector) && level != .hardcore:
            // Back, but never into the chapter above, nor (Light) out of the sentence.
            let at = caretAt
            let limit = level == .light ? lowest : floor
            guard at > limit else { refused(); return }
            var from = at - 1
            if selector == #selector(NSResponder.deleteWordBackward(_:)) { from = max(limit, Prose.previousWordStart(string as NSString, at)) }
            let r = (string as NSString).rangeOfComposedCharacterSequences(for: NSRange(location: from, length: at - from))
            let cut = NSRange(location: max(limit, r.location), length: at - max(limit, r.location))
            if shouldChangeText(in: cut, replacementString: "") {
                textStorage?.replaceCharacters(in: cut, with: "")
                didChangeText()
                super.setSelectedRanges([NSValue(range: NSRange(location: cut.location, length: 0))], affinity: .downstream, stillSelecting: false)
            }
        case #selector(NSResponder.deleteForward(_:)) where level == .light:
            let at = caretAt
            guard at < end else { refused(); return }
            let r = (string as NSString).rangeOfComposedCharacterSequence(at: at)
            if shouldChangeText(in: r, replacementString: "") { textStorage?.replaceCharacters(in: r, with: ""); didChangeText() }
            super.setSelectedRanges([NSValue(range: NSRange(location: at, length: 0))], affinity: .downstream, stillSelecting: false)
        case _ where moves.contains(selector) && level == .light:
            let limit = lowest, before = caretAt
            super.doCommand(by: selector)
            let now = selectedRange().location
            // Against the sentence's start or the end: the caret shivers instead.
            if now < limit || now > end || now == before { refused() }
            super.setSelectedRanges([NSValue(range: NSRange(location: min(max(now, limit), end), length: 0))], affinity: .downstream, stillSelecting: false)
        default:
            refused()   // What this level doesn't allow: forward only.
        }
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        if hasMarkedText() { return super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting) }
        guard level == .light else {
            return super.setSelectedRanges([NSValue(range: NSRange(location: end, length: 0))], affinity: affinity, stillSelecting: false)
        }
        // Light: a caret, never a selection, between the sentence's start and the end.
        let wanted = ranges.first?.rangeValue.location ?? end
        let current = min(max(selectedRanges.first?.rangeValue.location ?? end, floor), end)
        let limit = max(floor, min(lowest, current))
        super.setSelectedRanges([NSValue(range: NSRange(location: min(max(wanted, limit), end), length: 0))], affinity: affinity, stillSelecting: false)
    }

    override func didChangeText() {
        super.didChangeText()
        let ns = string as NSString
        changed(floor < ns.length ? ns.substring(from: floor) : "")
        place()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let key = event.charactersIgnoringModifiers?.lowercased()
        if flags == [.command, .control], key == "u" { UltraFocus.shared.requestExit(); return true }
        if flags == [.command], key == "q" { return false }   // quitting puts the text away first
        if flags.contains(.command) { refused(); return true }
        return super.performKeyEquivalent(with: event)
    }

    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        var r = rect
        r.size.width = 3
        if flag { color.setFill(); NSBezierPath(roundedRect: r, xRadius: 1, yRadius: 1).fill() } else { setNeedsDisplay(r, avoidAdditionalLayout: true) }
    }

    override func setNeedsDisplay(_ invalidRect: NSRect, avoidAdditionalLayout flag: Bool) {
        var r = invalidRect
        r.size.width += 3
        super.setNeedsDisplay(r, avoidAdditionalLayout: flag)
    }

    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }
    override func mouseDragged(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
    override func menu(for event: NSEvent) -> NSMenu? { nil }
    override func paste(_ sender: Any?) { refused() }
    override func pasteAsPlainText(_ sender: Any?) { refused() }
    override func cut(_ sender: Any?) { refused() }
    override func delete(_ sender: Any?) { refused() }
    override func selectAll(_ sender: Any?) { refused() }
}
