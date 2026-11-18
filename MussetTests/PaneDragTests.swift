import AppKit
import SwiftUI
import XCTest
@testable import Musset

/// A drag replayed on the real window: over a chapter's text, the editor hands it to the panes.
@MainActor
final class PaneDragTests: XCTestCase {
    final class FakeDrag: NSObject, NSDraggingInfo {
        let pasteboard: NSPasteboard
        let point: NSPoint
        weak var target: NSWindow?
        init(wire: String, at point: NSPoint, in window: NSWindow) {
            pasteboard = NSPasteboard(name: NSPasteboard.Name("musset-test-\(UUID())"))
            pasteboard.clearContents()
            pasteboard.setString(wire, forType: .string)
            self.point = point
            target = window
        }
        var draggingDestinationWindow: NSWindow? { target }
        /// What SwiftUI's `draggable` allows: a copy, never a move.
        var draggingSourceOperationMask: NSDragOperation { .copy }
        var draggingLocation: NSPoint { point }
        var draggedImageLocation: NSPoint { point }
        var draggedImage: NSImage? { nil }
        var draggingPasteboard: NSPasteboard { pasteboard }
        var draggingSource: Any? { nil }
        var draggingSequenceNumber: Int { 1 }
        func slideDraggedImage(to screenPoint: NSPoint) {}
        var draggingFormation: NSDraggingFormation = .default
        var animatesToDestination = false
        var numberOfValidItemsForDrop = 1
        func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes classArray: [AnyClass],
                                    searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                    using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
        var springLoadingHighlight: NSSpringLoadingHighlight { .none }
        func resetSpringLoading() {}
    }

    private func textViews(in view: NSView) -> [ZenTextView] {
        (view as? ZenTextView).map { [$0] } ?? view.subviews.flatMap(textViews)
    }

    func testASheetDraggedOverTheTextOfTheOnlyPane() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("musset-drag-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "Tom crossed at six.\n\nThe gate was open.".write(to: root.appendingPathComponent("01.md"), atomically: true, encoding: .utf8)
        var m = BookManifest(title: "T", chapters: [ChapterEntry(id: "01", file: "01.md", title: "One")])
        m.lang = "en"
        try BookStore(root: root).saveManifest(m)
        try GitService(root: root).initRepo()
        let app = AppState()
        app.openBook(root)
        let s = try XCTUnwrap(app.current)
        try s.bible.create(title: "Tom", kind: .character)
        let tom = try XCTUnwrap(s.bible.entry(named: "Tom"))
        s.open("01")

        let bridge = EditorBridge(), ann = Annotator(), proof = AutoProofreader()
        bridge.annotator = ann; bridge.proof = proof
        let view = ContentView(app: app, bridge: bridge, chat: ChatModel(), pangram: PangramModel(), proof: proof, annotator: ann)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900), styleMask: [.titled, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: view.frame(width: 1400, height: 900))
        for _ in 0..<10 { window.contentView!.layoutSubtreeIfNeeded(); window.contentView!.displayIfNeeded(); try await Task.sleep(for: .milliseconds(30)) }

        let tv = try XCTUnwrap(textViews(in: window.contentView!).first { $0.window != nil && $0.visibleRect.width > 0 })
        let scroll = try XCTUnwrap(tv.enclosingScrollView)
        // The right edge of the editor, in the window.
        let r = scroll.convert(scroll.bounds, to: nil)
        let drag = FakeDrag(wire: ShelfDrag.sheet(tom.path).wire, at: NSPoint(x: r.maxX - 20, y: r.midY), in: window)
        let pane = try XCTUnwrap(s.workspace.focused).id
        let op = tv.draggingEntered(drag)
        XCTAssertFalse(op.intersection(drag.draggingSourceOperationMask).isEmpty, "an operation the drag allows, or AppKit refuses the drop")
        XCTAssertEqual(s.workspace.drops.hover, PaneDropTarget(pane: pane, zone: .edge(.right)))
        XCTAssertTrue(tv.prepareForDragOperation(drag))
        XCTAssertTrue(tv.performDragOperation(drag))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(s.workspace.panes.map(\.activeTab), [.chapter("01"), .sheet(tom.path)])
        s.close()
    }

    func testGoingBackToATabShowsThePageWhereItWasScrolled() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("musset-scroll-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let long = (1...300).map { "Paragraph \($0) of a long chapter, long enough to scroll a good way down the page." }.joined(separator: "\n\n")
        try long.write(to: root.appendingPathComponent("01.md"), atomically: true, encoding: .utf8)
        try long.write(to: root.appendingPathComponent("02.md"), atomically: true, encoding: .utf8)
        var m = BookManifest(title: "T", chapters: [ChapterEntry(id: "01", file: "01.md", title: "One"), ChapterEntry(id: "02", file: "02.md", title: "Two")])
        m.lang = "en"
        try BookStore(root: root).saveManifest(m)
        try GitService(root: root).initRepo()
        let app = AppState()
        app.openBook(root)
        let s = try XCTUnwrap(app.current)
        s.open("01")
        s.open(.chapter("02"), in: .newTab)
        let bridge = EditorBridge(), ann = Annotator(), proof = AutoProofreader()
        bridge.annotator = ann; bridge.proof = proof
        let view = ContentView(app: app, bridge: bridge, chat: ChatModel(), pangram: PangramModel(), proof: proof, annotator: ann)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900), styleMask: [.titled, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: view.frame(width: 1400, height: 900))
        func settle() async throws {
            for _ in 0..<10 { window.contentView!.layoutSubtreeIfNeeded(); window.contentView!.displayIfNeeded(); try await Task.sleep(for: .milliseconds(30)) }
        }
        func editor() throws -> NSScrollView {
            try XCTUnwrap(textViews(in: window.contentView!).first { $0.window != nil && $0.visibleRect.width > 0 }?.enclosingScrollView)
        }
        let pane = try XCTUnwrap(s.workspace.focused).id
        s.workspace.activate(0, in: pane); s.followFocusedPane()
        try await settle()
        // Scrolled far from the caret, which stays at the top.
        var scroll = try editor()
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 4000))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await settle()
        XCTAssertEqual(s.docs["01"]?.scrollY ?? 0, 4000, accuracy: 1)
        s.workspace.activate(1, in: pane); s.followFocusedPane()
        try await settle()
        s.workspace.activate(0, in: pane); s.followFocusedPane()
        try await settle()
        scroll = try editor()
        XCTAssertEqual(scroll.contentView.bounds.origin.y, 4000, accuracy: 1, "back where it was scrolled, not at the caret")
        s.close()
    }

    /// A book of two short chapters in a window, the first one shown.
    private func twoChapters(_ name: String) throws -> (root: URL, app: AppState, session: BookSession, window: NSWindow) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("musset-\(name)-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "The first chapter opens on a long sentence of its own.\n\nAnd a second paragraph.".write(to: root.appendingPathComponent("01.md"), atomically: true, encoding: .utf8)
        try "The second chapter says something else entirely.".write(to: root.appendingPathComponent("02.md"), atomically: true, encoding: .utf8)
        var m = BookManifest(title: "T", chapters: [ChapterEntry(id: "01", file: "01.md", title: "One"), ChapterEntry(id: "02", file: "02.md", title: "Two")])
        m.lang = "en"
        try BookStore(root: root).saveManifest(m)
        try GitService(root: root).initRepo()
        let app = AppState()
        app.openBook(root)
        let s = try XCTUnwrap(app.current)
        s.open("01")
        let bridge = EditorBridge(), ann = Annotator(), proof = AutoProofreader()
        bridge.annotator = ann; bridge.proof = proof
        let view = ContentView(app: app, bridge: bridge, chat: ChatModel(), pangram: PangramModel(), proof: proof, annotator: ann)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900), styleMask: [.titled, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: view.frame(width: 1400, height: 900))
        return (root, app, s, window)
    }

    private func settle(_ window: NSWindow) async throws {
        for _ in 0..<10 { window.contentView!.layoutSubtreeIfNeeded(); window.contentView!.displayIfNeeded(); try await Task.sleep(for: .milliseconds(30)) }
    }

    /// A tab left and come back to keeps its undo history; ⌘Z goes to the editor of the pane one is in, and to no
    /// editor when that pane shows a page.
    func testUndoStaysWithItsTabAndFollowsThePane() async throws {
        let (root, _, s, window) = try twoChapters("undo")
        defer { try? FileManager.default.removeItem(at: root) }
        s.open(.chapter("02"), in: .newTab)
        let left = try XCTUnwrap(s.workspace.focused).id
        s.workspace.activate(0, in: left); s.followFocusedPane()
        try await settle(window)
        func shown() -> [ZenTextView] { textViews(in: window.contentView!).filter { $0.window != nil } }
        let first = try XCTUnwrap(shown().first)
        let before = first.string
        first.insertText("Typed. ", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(first.undoManager?.canUndo, true)
        s.workspace.activate(1, in: left); s.followFocusedPane()
        try await settle(window)
        s.workspace.activate(0, in: left); s.followFocusedPane()
        try await settle(window)
        let back = try XCTUnwrap(shown().first)
        XCTAssertTrue(back === first, "the tab's own editor comes back")
        XCTAssertEqual(back.string, "Typed. " + before)
        XCTAssertEqual(back.undoManager?.canUndo, true, "its undo history came back with it")
        back.undoManager?.undo()
        XCTAssertEqual(back.string, before)

        // Two panes: the keys are with the pane one is in.
        s.open(.chapter("02"), in: .split(.right))
        try await settle(window)
        let right = try XCTUnwrap(s.workspace.focused).id
        XCTAssertNotEqual(right, left)
        XCTAssertEqual((window.firstResponder as? ZenTextView)?.string, s.docs["02"]?.text)
        s.workspace.focus(left); s.followFocusedPane()
        try await settle(window)
        XCTAssertEqual((window.firstResponder as? ZenTextView)?.string, s.docs["01"]?.text, "⌘Z would now undo in the left pane")
        
        // A page in the pane one is in: no chapter elsewhere takes ⌘Z.
        s.workspace.focus(right); s.followFocusedPane()
        s.open(OverviewTab.synopsis.tab, in: .newTab)
        try await settle(window)
        XCTAssertFalse(window.firstResponder is ZenTextView)
        s.close()
    }

    /// Typed, deleted by mistake, ⌘Z: the words come back, by the path the Edit menu takes.
    func testADeletionIsUndoneFromTheMenu() async throws {
        let (root, _, s, window) = try twoChapters("undo-delete")
        defer { try? FileManager.default.removeItem(at: root) }
        try await settle(window)
        let tv = try XCTUnwrap(textViews(in: window.contentView!).first { $0.window != nil })
        window.makeFirstResponder(tv)
        tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
        for word in [" Then", " she", " left."] { tv.insertText(word, replacementRange: tv.selectedRange()) }
        try await settle(window)
        let typed = tv.string
        XCTAssertTrue(typed.hasSuffix("Then she left."))
        tv.setSelectedRange((tv.string as NSString).range(of: "second paragraph"))
        tv.deleteBackward(nil)
        try await settle(window)
        XCTAssertFalse(tv.string.contains("second paragraph"))
        XCTAssertTrue(window.firstResponder === tv, "the editor still has the keys")
        XCTAssertEqual(tv.undoManager?.canUndo, true, "the deletion is still there to undo")
        XCTAssertTrue(window.firstResponder?.tryToPerform(Selector(("undo:")), with: nil) ?? false)
        try await settle(window)
        // Without events the typing and the deletion are one step here: both are taken back.
        XCTAssertTrue(tv.string.contains("second paragraph"), "the deleted words are back")
        XCTAssertEqual(s.docs["01"]?.text, tv.string)
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "")
        XCTAssertTrue(tv.validateUserInterfaceItem(redo), "and Redo is offered")
        XCTAssertTrue(window.firstResponder?.tryToPerform(Selector(("redo:")), with: nil) ?? false)
        XCTAssertFalse(tv.string.contains("second paragraph"))
        s.close()
    }

    /// A sentence deleted with Backspace goes to the Cuts, as one cut with ⌘X does; a couple of words do not.
    func testADeletedSentenceGoesToTheCuts() async throws {
        let (root, _, s, window) = try twoChapters("cuts")
        defer { try? FileManager.default.removeItem(at: root) }
        try await settle(window)
        let tv = try XCTUnwrap(textViews(in: window.contentView!).first { $0.window != nil })
        let sentence = (tv.string as NSString).range(of: "The first chapter opens on a long sentence of its own.")
        tv.setSelectedRange(sentence)
        tv.deleteBackward(nil)
        let cuts = s.bible.entries.filter { $0.kind == .cut }
        XCTAssertEqual(cuts.count, 1)
        XCTAssertEqual(cuts.first?.meta["from"], "01")
        tv.setSelectedRange((tv.string as NSString).range(of: "And a"))
        tv.deleteBackward(nil)
        XCTAssertEqual(s.bible.entries.filter { $0.kind == .cut }.count, 1, "a correction is not a cut")
        s.close()
    }

    /// A page over the editor (a board, a sheet) gets the clicks: no editor kept hidden under it catches them.
    func testClicksOnABoardReachTheBoardNotAnEditorUnderIt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("musset-hit-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "Tom crossed at six.".write(to: root.appendingPathComponent("01.md"), atomically: true, encoding: .utf8)
        var m = BookManifest(title: "T", chapters: [ChapterEntry(id: "01", file: "01.md", title: "One")])
        m.lang = "en"
        try BookStore(root: root).saveManifest(m)
        try GitService(root: root).initRepo()
        let app = AppState()
        app.openBook(root)
        let s = try XCTUnwrap(app.current)
        s.open("01")
        let board = try s.bible.createBoard("Deed")
        s.open(.sheet(board.path), in: .newTab)
        XCTAssertEqual(s.selectedChapterID, "01", "the chapter stays the one written in")
        let bridge = EditorBridge(), ann = Annotator(), proof = AutoProofreader()
        bridge.annotator = ann; bridge.proof = proof
        let view = ContentView(app: app, bridge: bridge, chat: ChatModel(), pangram: PangramModel(), proof: proof, annotator: ann)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900), styleMask: [.titled, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: view.frame(width: 1400, height: 900))
        for _ in 0..<10 { window.contentView!.layoutSubtreeIfNeeded(); window.contentView!.displayIfNeeded(); try await Task.sleep(for: .milliseconds(30)) }
        let content = window.contentView!
        let pane = try XCTUnwrap(s.workspace.drops.paneFrames.values.first)
        // The middle of the board, in the content view's own coordinates.
        var p = CGPoint(x: pane.midX, y: pane.midY)
        if !content.isFlipped { p.y = content.bounds.height - p.y }
        let hit = content.hitTest(p)
        var v: NSView? = hit, chain: [String] = []
        while let x = v { chain.append(String(describing: type(of: x))); v = x.superview }
        XCTAssertFalse(chain.contains { $0.contains("ZenTextView") || $0 == "NSScrollView" }, "a click on the board reached \(chain.prefix(4))")
        // Its tab closes, and stays closed.
        let id = try XCTUnwrap(s.workspace.focused).id
        let i = try XCTUnwrap(s.workspace.focused?.tabs.firstIndex(of: .sheet(board.path)))
        s.workspace.close(i, in: id); s.followFocusedPane()
        for _ in 0..<10 { window.contentView!.layoutSubtreeIfNeeded(); window.contentView!.displayIfNeeded(); try await Task.sleep(for: .milliseconds(30)) }
        XCTAssertEqual(s.workspace.focused?.tabs, [.chapter("01")])
        s.close()
    }
}
