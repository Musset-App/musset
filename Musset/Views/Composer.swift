import AppKit
import SwiftUI

/// Chat input: Return sends; Shift-, Command- or Option-Return inserts a new line. Grows up to `maxLines`.
struct Composer: NSViewRepresentable {
    @Binding var text: String
    var fontSize: Double = 15
    var placeholder: String
    var maxLines = 8
    var onSend: () -> Void
    @Binding var height: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        let tv = ComposerTextView(usingTextLayoutManager: false)
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.font = .systemFont(ofSize: fontSize)
        tv.textContainerInset = NSSize(width: 0, height: 4)
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isContinuousSpellCheckingEnabled = true
        tv.autoresizingMask = [.width]
        tv.isVerticallyResizable = true
        tv.textContainer?.widthTracksTextView = true
        tv.placeholder = placeholder
        tv.onSend = { context.coordinator.parent.onSend() }
        scroll.documentView = tv
        context.coordinator.textView = tv
        DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = scroll.documentView as? ComposerTextView else { return }
        tv.placeholder = placeholder
        if tv.font?.pointSize != CGFloat(fontSize) { tv.font = .systemFont(ofSize: fontSize); context.coordinator.measure() }
        if tv.string != text { tv.string = text; context.coordinator.measure() }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: Composer
        weak var textView: ComposerTextView?
        init(_ parent: Composer) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = textView else { return }
            parent.text = tv.string
            measure()
            tv.needsDisplay = true
        }

        func measure() {
            guard let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer else { return }
            lm.ensureLayout(for: tc)
            let line = (tv.font ?? .systemFont(ofSize: 14)).boundingRectForFont.height
            let used = lm.usedRect(for: tc).height + tv.textContainerInset.height * 2
            let h = min(max(used, line + 8), line * CGFloat(parent.maxLines) + 8)
            if abs(parent.height - h) > 0.5 { DispatchQueue.main.async { self.parent.height = h } }
        }
    }
}

final class ComposerTextView: NSTextView {
    var onSend: (() -> Void)?
    var placeholder = "" { didSet { needsDisplay = true } }

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        guard isReturn else { super.keyDown(with: event); return }
        let mods = event.modifierFlags.intersection([.shift, .command, .option, .control])
        if mods.isEmpty, !hasMarkedText() {
            onSend?()
        } else {
            insertNewlineIgnoringFieldEditor(nil)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [.font: font ?? NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.placeholderTextColor]
        (placeholder as NSString).draw(at: NSPoint(x: textContainerOrigin.x + 5, y: textContainerOrigin.y), withAttributes: attrs)
    }
}

/// A thin vertical handle to drag a side panel wider or narrower; the width is remembered.
struct PanelResizeHandle: View {
    @Binding var width: Double
    var range: ClosedRange<Double>
    @State private var start: Double?

    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .textBackgroundColor))
            .frame(width: 6)
            .overlay(Divider())
            .contentShape(Rectangle())
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { g in
                        if start == nil { start = width }
                        // The panel sits on the right: dragging left makes it wider.
                        width = min(range.upperBound, max(range.lowerBound, (start ?? width) - g.translation.width))
                    }
                    .onEnded { _ in start = nil }
            )
    }
}
