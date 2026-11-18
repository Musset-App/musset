import SwiftUI

/// What every pane needs to draw its content.
struct PaneContext {
    let app: AppState
    let session: BookSession
    /// The window's panes.
    let workspace: Workspace
    let bridge: EditorBridge
    let proof: AutoProofreader
    let analyst: PlotAnalyst
    let planner: ScenePlanner
    let fontName: String
    let fontSize: Double
    let columnWidth: Double
}

/// The panes and what drags onto them: a tab bar takes a tab among the others, a pane's side makes a new pane
/// there, its middle a new tab in it.
struct PaneArea: View {
    let ctx: PaneContext
    @State private var origin: CGPoint = .zero

    var body: some View {
        let session = ctx.session
        PaneTreeView(ctx: ctx, node: ctx.workspace.root)
            .onGeometryChange(for: CGPoint.self) { $0.frame(in: .global).origin } action: { origin = $0 }
            .onDrop(of: [.text], delegate: PaneDropDelegate(session: session, drops: ctx.workspace.drops, origin: origin))
    }
}

struct PaneDropDelegate: DropDelegate {
    let session: BookSession
    let drops: PaneDrops
    let origin: CGPoint

    private func point(_ info: DropInfo) -> CGPoint { CGPoint(x: info.location.x + origin.x, y: info.location.y + origin.y) }

    func validateDrop(info: DropInfo) -> Bool { PaneDrops.dragged?.paneTab != nil || isTab }
    private var isTab: Bool { if case .tab? = PaneDrops.dragged { true } else { false } }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard validateDrop(info: info) else { return nil }
        let t = drops.target(at: point(info))
        if drops.hover != t { drops.hover = t }
        // A copy: what SwiftUI's drags allow (a move would be refused).
        return DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) { drops.hover = nil }

    func performDrop(info: DropInfo) -> Bool {
        guard let drag = PaneDrops.dragged, let t = drops.target(at: point(info)) else { drops.hover = nil; return false }
        return session.dropOnPanes(drag.wire, at: t)
    }
}

/// The part of a pane that takes drags for the panes: all of it, or its tab bar and sides.
private struct PaneDropLayer: View {
    let keepsMiddle: Bool
    let bar: CGFloat

    var body: some View {
        GeometryReader { g in
            Path { p in
                let all = CGRect(origin: .zero, size: g.size)
                guard keepsMiddle else { p.addRect(all); return }
                let body = CGRect(x: 0, y: bar, width: g.size.width, height: max(0, g.size.height - bar))
                let w = body.width * PaneDrops.edgeShare, h = body.height * PaneDrops.edgeShare
                p.addRect(CGRect(x: 0, y: 0, width: g.size.width, height: bar))
                p.addRect(CGRect(x: body.minX, y: body.minY, width: w, height: body.height))
                p.addRect(CGRect(x: body.maxX - w, y: body.minY, width: w, height: body.height))
                p.addRect(CGRect(x: body.minX, y: body.minY, width: body.width, height: h))
                p.addRect(CGRect(x: body.minX, y: body.maxY - h, width: body.width, height: h))
            }
            .fill(Color.white.opacity(0.001))
        }
    }
}

/// Where a drop would land, drawn over the pane: the side that becomes a pane, or the whole pane for a new tab.
private struct DropHint: View {
    let zone: PaneDropTarget.Zone
    let bar: CGFloat

    var body: some View {
        GeometryReader { g in
            let r = rect(in: g.size)
            RoundedRectangle(cornerRadius: Radius.row)
                .fill(Ink.accent.opacity(0.10))
                .overlay(RoundedRectangle(cornerRadius: Radius.row).strokeBorder(Ink.accent.opacity(0.6), lineWidth: 1.5))
                .frame(width: r.width, height: r.height)
                .offset(x: r.minX, y: r.minY)
        }
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.1), value: zone)
    }

    private func rect(in size: CGSize) -> CGRect {
        let body = CGRect(x: 0, y: bar, width: size.width, height: max(0, size.height - bar)).insetBy(dx: 4, dy: 4)
        switch zone {
        case .tabs: return CGRect(x: 2, y: 2, width: size.width - 4, height: max(bar - 4, 0))
        case .center: return body
        case .edge(.left): return CGRect(x: body.minX, y: body.minY, width: body.width / 2, height: body.height)
        case .edge(.right): return CGRect(x: body.midX, y: body.minY, width: body.width / 2, height: body.height)
        case .edge(.top): return CGRect(x: body.minX, y: body.minY, width: body.width, height: body.height / 2)
        case .edge(.bottom): return CGRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2)
        }
    }
}

/// The window's panes: side by side or stacked, as the layout says, each with a handle to share the room.
struct PaneTreeView: View {
    let ctx: PaneContext
    let node: PaneNode
    /// Where this node is in the tree, to resize it.
    var path: [Int] = []

    var body: some View {
        switch node {
        case .pane(let pane):
            PaneView(ctx: ctx, pane: pane)
        case .split(let vertical, let children, let fractions):
            GeometryReader { geo in
                let total = vertical ? geo.size.height : geo.size.width
                let layout = AnyLayout(vertical ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(spacing: 0)))
                layout {
                    ForEach(Array(children.enumerated()), id: \.offset) { i, child in
                        let share = CGFloat(fractions.indices.contains(i) ? fractions[i] : 1.0 / Double(children.count))
                        PaneTreeView(ctx: ctx, node: child, path: path + [i])
                            .frame(width: vertical ? nil : max(120, total * share - (i < children.count - 1 ? ResizeGrip.thickness : 0)),
                                   height: vertical ? max(80, total * share - (i < children.count - 1 ? ResizeGrip.thickness : 0)) : nil)
                        if i < children.count - 1 {
                            PaneHandle(vertical: vertical) { delta in
                                guard total > 0 else { return }
                                var fr = fractions
                                let d = Double(delta / total)
                                let a = max(0.1, fr[i] + d), b = max(0.1, fr[i + 1] - d)
                                guard a + b <= fr[i] + fr[i + 1] + 0.0001 else { return }
                                fr[i] = a; fr[i + 1] = b
                                ctx.workspace.resize(path, fractions: fr)
                            }
                        }
                    }
                }
            }
        }
    }
}

/// The line between two panes; dragging it moves the share between them.
private struct PaneHandle: View {
    let vertical: Bool
    let moved: (CGFloat) -> Void
    @State private var last: CGFloat = 0

    var body: some View {
        // A fine line in the middle of a strip wide enough to grab.
        ZStack {
            Color(nsColor: .textBackgroundColor)
            Rectangle().fill(Ink.hairline).frame(width: vertical ? nil : 1, height: vertical ? 1 : nil)
        }
        .resizeGrip(vertical: vertical)
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { g in
                    let now = vertical ? g.translation.height : g.translation.width
                    moved(now - last)
                    last = now
                }
                .onEnded { _ in last = 0 })
            .accessibilityLabel(L("Resize the panes"))
    }
}

/// One pane: its tabs and what its active tab shows.
struct PaneView: View {
    let ctx: PaneContext
    let pane: Pane

    private var session: BookSession { ctx.session }
    private var app: AppState { ctx.app }
    private var workspace: Workspace { ctx.workspace }
    /// The pane one is in, in the window one is in.
    private var isFocused: Bool { pane.id == workspace.focusedPane && workspace === session.workspace }
    private var showsTabs: Bool { !app.focusMode }

    var body: some View {
        VStack(spacing: 0) {
            if showsTabs {
                PaneTabBar(app: app, session: session, workspace: workspace, pane: pane)
            }
            content
        }
        .contentShape(Rectangle())
        // The cards and pills inside are given no session: the book's words reach them this way.
        .environment(\.bookWords, session.words)
        .simultaneousGesture(TapGesture().onEnded { session.activate(workspace); workspace.focus(pane.id) })
        .overlay {
            if let t = workspace.drops.hover, t.pane == pane.id { DropHint(zone: t.zone, bar: showsTabs ? PaneTabBar.height : 0) }
        }
        // While a chapter, a sheet or a tab is dragged: a layer over the page, so its own drops (a sheet's links, a
        // place's photos) don't take it. The cast in columns keeps its middle, where a name moves between columns, and a board, where a sheet becomes a card.
        .overlay {
            if PaneDragWatch.shared.active {
                PaneDropLayer(keepsMiddle: pane.activeTab.map { tab in
                    switch tab {
                    case .folder(let f): BibleFolderView.showsCast(f)
                    // A board's middle takes a sheet as a card.
                    case .sheet(let p): p.hasSuffix(".canvas")
                    default: false
                    }
                } ?? false,
                              bar: showsTabs ? PaneTabBar.height : 0)
                    .onDrop(of: [.text], delegate: PaneDropDelegate(session: session, drops: workspace.drops,
                                                                    origin: workspace.drops.paneFrames[pane.id]?.origin ?? .zero))
            }
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { workspace.drops.paneFrames[pane.id] = $0 }
        .onDisappear { workspace.drops.forget(pane.id) }
    }

    @ViewBuilder private var content: some View {
        switch pane.activeTab {
        case .chapter(let id)?:
            if workspace.showsSceneCards(pane: pane.id, chapter: id) {
                SceneCardsView(session: session, workspace: workspace, paneID: pane.id, chapterID: id, fontName: ctx.fontName)
                    .id(pane.id + "|" + id)
            } else if let doc = session.doc(for: id) {
                EditorColumn(app: app, session: session, bridge: ctx.bridge, proof: ctx.proof,
                             fontName: ctx.fontName, fontSize: ctx.fontSize, columnWidth: ctx.columnWidth,
                             doc: doc, live: isFocused && session.selectedChapterID == id,
                             onFocus: {
                                 session.activate(workspace)
                                 workspace.focus(pane.id)
                                 if session.selectedChapterID != id { session.open(id, show: false) }
                             },
                             drops: workspace.drops, editors: workspace.editors,
                             editorKey: EditorCache.key(pane: pane.id, chapter: id))
                    .id(pane.id + "|" + id)
            }
        case .sheet(let path)?:
            if let entry = session.bible.entry(path: path) {
                if entry.kind == .board {
                    BoardView(app: app, session: session, bridge: ctx.bridge, path: path).id(path)
                } else {
                    BibleEntryView(app: app, session: session, bridge: ctx.bridge, entry: entry).id(path)
                }
            }
        case .folder(let folder)?:
            BibleFolderView(app: app, session: session, bridge: ctx.bridge, folder: folder).id(folder)
        case .sources?:
            SourcesView(app: app, session: session)
        case .overview?:
            // This pane's page of Overview, whichever pane one is in.
            OverviewView(app: app, session: session, bridge: ctx.bridge, analyst: ctx.analyst, planner: ctx.planner,
                         workspace: workspace, paneID: pane.id, fontName: ctx.fontName,
                         shown: pane.activeTab?.overview ?? .summary) { page in
                workspace.together { workspace.focus(pane.id); workspace.open(page.tab) }
            }
        case .story?:
            StoryView(app: app, session: session)
        case .debate?:
            DebatePage(session: session, openSynopsis: { workspace.together { workspace.focus(pane.id); workspace.open(OverviewTab.synopsis.tab) } })
        case .special(let raw)?:
            if let page = SpecialPage(rawValue: raw) { SpecialPageView(app: app, session: session, page: page) }
        case nil:
            Color(nsColor: .textBackgroundColor)
        }
    }
}
