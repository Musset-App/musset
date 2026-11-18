import AppKit
import SwiftUI

/// Which book and which of its windows a separate window shows.
struct WindowRef: Codable, Hashable {
    let bookPath: String
    let windowID: String
}

/// A window of the book's own beside the main one: its panes and tabs, on the same chapters and the same notes
/// (a chapter open in two windows is still one text).
struct PaneWindow: View {
    static let sceneID = "pane"

    let app: AppState
    let bridge: EditorBridge
    let proof: AutoProofreader
    let ref: WindowRef?
    @AppStorage("fontName") private var fontName = Typefaces.manuscript
    @AppStorage("fontSize") private var fontSize = 17.0
    @AppStorage("columnWidth") private var columnWidth = 640.0
    @State private var analyst = PlotAnalyst()
    @State private var planner = ScenePlanner()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let ref, let session = app.loadedSession(ref.bookPath) {
            Group {
                if let ws = session.windows[ref.windowID] {
                    PaneArea(ctx: PaneContext(app: app, session: session, workspace: ws, bridge: bridge, proof: proof, analyst: analyst,
                                              planner: planner, fontName: fontName, fontSize: fontSize, columnWidth: columnWidth))
                        .onChange(of: ws.root) { _, root in
                            session.pruneDocs()
                            // Its last tab gone (dragged to another window, closed): the window goes too.
                            if root.panes.allSatisfy(\.tabs.isEmpty) { session.closeWindow(ref.windowID); dismiss() }
                        }
                } else {
                    Color(nsColor: .textBackgroundColor)
                }
            }
            .navigationTitle(session.manifest.title)
            .onAppear { _ = session.workspace(forWindow: ref.windowID); app.shownWindows.insert(ref.windowID) }
            .background(WindowWatcher(
                origin: app.windowOrigins.removeValue(forKey: ref.windowID),
                onKey: { session.activeWindow = ref.windowID },
                onClose: {
                    app.shownWindows.remove(ref.windowID)
                    // Quitting keeps the window for next time; closing it lets it go.
                    if !app.quitting { session.closeWindow(ref.windowID) }
                }))
        } else {
            Text(L("This book is no longer open."))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .textBackgroundColor))
        }
    }
}

/// Tells when its window comes to the front or closes, and puts a new window where it was asked for.
struct WindowWatcher: NSViewRepresentable {
    var origin: CGPoint? = nil
    var onKey: () -> Void = {}
    var onClose: () -> Void = {}

    func makeNSView(context: Context) -> WatcherView { WatcherView() }

    func updateNSView(_ view: WatcherView, context: Context) {
        view.onKey = onKey
        view.onClose = onClose
        if let origin { view.origin = origin }
    }

    final class WatcherView: NSView {
        var onKey: () -> Void = {}
        var onClose: () -> Void = {}
        var origin: CGPoint? { didSet { placeWindow() } }
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            placeWindow()
            let nc = NotificationCenter.default
            observers.append(nc.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onKey() }
            })
            observers.append(nc.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onClose() }
            })
            if window.isKeyWindow { DispatchQueue.main.async { [weak self] in self?.onKey() } }
        }

        private func placeWindow() {
            guard let window, let origin else { return }
            // Its title bar under the pointer, where the tab was let go.
            window.setFrameTopLeftPoint(CGPoint(x: origin.x - 60, y: origin.y + 12))
            self.origin = nil
        }

        deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    }
}
