import AppKit
import SwiftUI
import XCTest
@testable import Musset

/// How long a tab switch and a tab close take, drawn, on a copy of a real book: MUSSET_PANE_TIMING=<copy of a book>.
@MainActor
final class PaneTimingProbe: XCTestCase {
    func testTabSwitchTimes() async throws {
        guard let path = ProcessInfo.processInfo.environment["MUSSET_PANE_TIMING"] else { throw XCTSkip("set MUSSET_PANE_TIMING") }
        let app = AppState()
        app.openBook(URL(fileURLWithPath: path))
        let s = try XCTUnwrap(app.current)
        let chapters = s.manifest.chapters.map(\.id)
        let bridge = EditorBridge(), ann = Annotator(), proof = AutoProofreader()
        bridge.annotator = ann; bridge.proof = proof
        let view = ContentView(app: app, bridge: bridge, chat: ChatModel(), pangram: PangramModel(), proof: proof, annotator: ann)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900), styleMask: [.titled, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: view.frame(width: 1440, height: 900))
        func settle() async {
            for _ in 0..<5 {
                window.contentView!.layoutSubtreeIfNeeded(); window.contentView!.displayIfNeeded()
                try? await Task.sleep(for: .milliseconds(1))
            }
        }
        func time(_ label: String, _ act: () -> Void) async {
            let t = Date()
            act()
            print(String(format: "TIMING   model %.0f ms", Date().timeIntervalSince(t) * 1000))
            window.contentView!.layoutSubtreeIfNeeded(); window.contentView!.displayIfNeeded()
            let sync = Date().timeIntervalSince(t)
            await settle()
            print(String(format: "TIMING %@: %.0f ms (sync %.0f ms)", label, Date().timeIntervalSince(t) * 1000, sync * 1000))
        }
        s.open(chapters[1])
        await settle()
        s.open(.chapter(chapters[2]), in: .newTab)
        s.open(OverviewTab.synopsis.tab, in: .newTab)
        await settle()
        let pane = try XCTUnwrap(s.workspace.focused).id
        for round in 0..<(Int(ProcessInfo.processInfo.environment["MUSSET_PANE_ROUNDS"] ?? "") ?? 3) {
            await time("\(round) chapter → chapter") { s.workspace.activate(0, in: pane); s.followFocusedPane() }
            await time("\(round) chapter → other chapter") { s.workspace.activate(1, in: pane); s.followFocusedPane() }
            await time("\(round) chapter → synopsis") { s.workspace.activate(2, in: pane); s.followFocusedPane() }
        }
        s.open(.sources, in: .newTab)
        await settle()
        await time("close sources") { s.workspace.closeActiveTab(); s.followFocusedPane() }
        await time("close synopsis") { s.workspace.closeActiveTab(); s.followFocusedPane() }
        await time("close chapter") { s.workspace.closeActiveTab(); s.followFocusedPane() }
        s.close()
    }
}
