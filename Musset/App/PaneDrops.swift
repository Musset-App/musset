import AppKit
import Observation

/// Where something dragged over the panes would land: among a pane's tabs, in a new pane on one of its sides, or
/// in a new tab of its own.
struct PaneDropTarget: Equatable {
    enum Zone: Equatable {
        case tabs(Int)
        case edge(OpenPlace.Edge)
        case center
    }
    let pane: String
    let zone: Zone
}

/// The panes' places on screen, so a drag (over a page, a tab bar, or a chapter's text) knows where it is.
/// Frames are in the window's SwiftUI global space.
@MainActor
@Observable
final class PaneDrops {
    /// The place shown under the drag. It goes once the drag is over, wherever it ended (another view's drop,
    /// outside the window, cancelled), since no one tells the panes then.
    var hover: PaneDropTarget? {
        didSet { if hover != nil, sweeper == nil { sweepWhenDragEnds() } }
    }
    @ObservationIgnored private var sweeper: Timer?

    private func sweepWhenDragEnds() {
        // The drag runs its own loop: this fires once it is over and the button is up.
        sweeper = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] t in
            MainActor.assumeIsolated {
                guard NSEvent.pressedMouseButtons & 1 == 0 else { return }
                t.invalidate()
                self?.sweeper = nil
                if self?.hover != nil { self?.hover = nil }
            }
        }
    }
    @ObservationIgnored var paneFrames: [String: CGRect] = [:]
    @ObservationIgnored var barFrames: [String: CGRect] = [:]
    @ObservationIgnored var tabFrames: [String: [Int: CGRect]] = [:]

    /// How close to a side, as a share of the pane, a drop makes a new pane there.
    static let edgeShare: CGFloat = 0.25

    func target(at p: CGPoint) -> PaneDropTarget? {
        if let (id, _) = barFrames.first(where: { $0.value.contains(p) }) {
            let before = (tabFrames[id] ?? [:]).values.filter { $0.midX < p.x }.count
            return PaneDropTarget(pane: id, zone: .tabs(before))
        }
        guard let (id, f) = paneFrames.first(where: { $0.value.contains(p) }) else { return nil }
        let top = barFrames[id].map { max(f.minY, $0.maxY) } ?? f.minY
        let w = max(f.width, 1), h = max(f.maxY - top, 1)
        let dx = (p.x - f.minX) / w, dy = (p.y - top) / h
        let sides: [(CGFloat, OpenPlace.Edge)] = [(dx, .left), (1 - dx, .right), (dy, .top), (1 - dy, .bottom)]
        if let near = sides.min(by: { $0.0 < $1.0 }), near.0 < Self.edgeShare {
            return PaneDropTarget(pane: id, zone: .edge(near.1))
        }
        return PaneDropTarget(pane: id, zone: .center)
    }

    func forget(_ paneID: String) {
        paneFrames[paneID] = nil
        barFrames[paneID] = nil
        tabFrames[paneID] = nil
    }

    /// What the drag pasteboard carries, if it is one of ours: readable while the drag is still moving.
    static var dragged: ShelfDrag? {
        NSPasteboard(name: .drag).string(forType: .string).flatMap(ShelfDrag.init(wire:))
    }
}

extension ShelfDrag {
    /// The tab it opens, dropped on the panes.
    var paneTab: PaneTab? {
        switch self {
        case .chapter(let id): .chapter(id)
        case .note(let chapter, _): .chapter(chapter)
        case .sheet(let path): .sheet(path)
        case .folder(let path): .folder(path)
        case .trashed, .tab: nil
        }
    }
}

extension OpenPlace {
    /// Where a click in the sidebar opens: ⌥ in a new tab, ⌘ in the next pane, else in the pane one is in.
    @MainActor static var click: OpenPlace {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) { return .nextPane }
        if flags.contains(.option) { return .newTab }
        return .current
    }
}

/// A tab dragged out of every window opens in a window of its own, where it was let go.
@MainActor
final class TearOff {
    static let shared = TearOff()
    /// Set by any drop on the panes, so a tab dropped in a window stays there.
    var handled = false
    private var timer: Timer?

    /// Called as a tab's drag starts; `out` runs if it ends outside Musset's windows, with the screen point.
    func begin(_ out: @escaping (CGPoint) -> Void) {
        handled = false
        timer?.invalidate()
        // The drag runs its own loop: this fires once it is over and the button is up.
        timer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] t in
            MainActor.assumeIsolated {
                guard NSEvent.pressedMouseButtons & 1 == 0 else { return }
                t.invalidate()
                guard let self else { return }
                self.timer = nil
                let p = NSEvent.mouseLocation
                guard !self.handled, !NSApp.windows.contains(where: { $0.isVisible && $0.frame.contains(p) }) else { return }
                out(p)
            }
        }
    }
}

/// Whether one of Musset's own things (a chapter, a sheet, a tab) is being dragged: the panes then lay a drop layer
/// over their pages, which otherwise take every drag for themselves (a sheet's links, a place's photos).
/// Told by the drag itself as it starts; never by reading the drag pasteboard, which, read while the button is down,
/// makes SwiftUI take a click for the start of a drag.
@MainActor
@Observable
final class PaneDragWatch {
    static let shared = PaneDragWatch()
    private(set) var active = false
    @ObservationIgnored private var timer: Timer?

    /// One of ours starts being dragged.
    func began() {
        active = true
        timer?.invalidate()
        let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] t in
            MainActor.assumeIsolated {
                guard NSEvent.pressedMouseButtons & 1 == 0 else { return }
                t.invalidate()
                self?.timer = nil
                self?.active = false
            }
        }
        // In the drag's own loop too.
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }
}
