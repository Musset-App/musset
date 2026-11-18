import SwiftUI

/// A pane's tabs: what is open in it, the one shown, the preview tab in italics (replaced by the next thing opened
/// until one works in it, or double-clicks it).
struct PaneTabBar: View {
    let app: AppState
    @Bindable var session: BookSession
    let workspace: Workspace
    let pane: Pane
    static let height: CGFloat = 32

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(Array(pane.tabs.enumerated()), id: \.offset) { i, tab in
                        tabView(tab, index: i)
                    }
                }
            }
            Spacer(minLength: 0)
            if let id = pane.activeTab?.chapterID { sceneCardsButton(id) }
            // A second pane: the active tab beside (or under) this one.
            Menu {
                Button(L("Split Right")) { split(.right) }
                Button(L("Split Down")) { split(.bottom) }
                if workspace.panes.count > 1 {
                    Divider()
                    Button(L("Close the pane")) { for i in pane.tabs.indices.reversed() { workspace.close(i, in: pane.id) } }
                }
            } label: {
                Image(systemName: "rectangle.split.2x1").font(.ui(11))
            } primaryAction: {
                split(.right)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .padding(.horizontal, 10)
            .help(L("Split right; hold for more"))
            .accessibilityLabel(L("Split Right"))
        }
        .frame(height: Self.height)
        .background(Ink.side)
        .overlay(alignment: .bottom) { Divider() }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { workspace.drops.barFrames[pane.id] = $0 }
        .onDisappear { workspace.drops.barFrames[pane.id] = nil }
    }

    /// The chapter shown as its scenes' cards, or back as text: there once the chapter has two scenes, and while the
    /// cards are shown, to leave them.
    @ViewBuilder private func sceneCardsButton(_ chapter: String) -> some View {
        let on = workspace.showsSceneCards(pane: pane.id, chapter: chapter)
        if on || (session.scenes[chapter]?.count ?? 0) > 1 {
            Button { workspace.setSceneCards(!on, pane: pane.id, chapter: chapter) } label: {
                Image(systemName: "square.grid.2x2").font(.ui(11))
                    .foregroundStyle(on ? Ink.accent : .secondary)
                    .frame(width: 24, height: 22)
                    .background(on ? Ink.accent.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: Radius.row))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(AppCommand.hint(session.words.sceneCards, "view.sceneCards"))
            .accessibilityLabel(session.words.sceneCards)
            .accessibilityAddTraits(on ? .isSelected : [])
        }
    }

    /// The tab shown, opened again in a new pane on that side.
    private func split(_ edge: OpenPlace.Edge) {
        workspace.focus(pane.id)
        workspace.splitActive(edge)
    }

    private func tabView(_ tab: PaneTab, index: Int) -> some View {
        let on = index == pane.active
        let writing = on && pane.id == workspace.focusedPane
        return HStack(spacing: 6) {
            Image(systemName: Self.icon(tab, session: session)).font(.ui(10)).foregroundStyle(.tertiary)
            Text(Self.title(tab, session: session))
                .font(.ui(12))
                .italic(pane.isPreview(index))
                .foregroundStyle(on ? .primary : .secondary)
                .lineLimit(1)
            // A pane's only tab closes too (and its pane with it), unless it is the window's last.
            if workspace.canCloseTab {
                Button { workspace.close(index, in: pane.id) } label: { Image(systemName: "xmark").font(.ui(8, .semibold)) }
                    .buttonStyle(.plain).foregroundStyle(.tertiary)
                    .accessibilityLabel(L("Close Tab"))
            }
        }
        .padding(.horizontal, 12)
        .frame(maxHeight: .infinity)
        .background(on ? Color(nsColor: .textBackgroundColor) : .clear)
        .overlay(alignment: .top) { if on { Rectangle().fill(writing ? Ink.accent : Ink.hairline).frame(height: 2) } }
        .overlay(alignment: .trailing) { Rectangle().fill(Ink.hairline).frame(width: 1) }
        .contentShape(Rectangle())
        // One gesture, not a single and a double one: SwiftUI holds a single click until a double one can't come.
        .onTapGesture {
            workspace.activate(index, in: pane.id)
            if NSApp.currentEvent?.clickCount == 2 { workspace.pin(pane.id) }
        }
        // Dragged to another place among the tabs, to another pane, a pane's side, another window, or out of them all.
        .onDrag {
            PaneDragWatch.shared.began()
            TearOff.shared.begin { [app, session, pane] point in app.tearOff(pane: pane.id, index: index, of: session, at: point) }
            return NSItemProvider(object: ShelfDrag.tab(pane: pane.id, index: index).wire as NSString)
        } preview: {
            Text(Self.title(tab, session: session)).font(.ui(12)).lineLimit(1)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Ink.panel, in: RoundedRectangle(cornerRadius: Radius.row))
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { workspace.drops.tabFrames[pane.id, default: [:]][index] = $0 }
        .onDisappear { workspace.drops.tabFrames[pane.id]?[index] = nil }
        .contextMenu {
            if pane.isPreview(index) { Button(L("Keep the tab")) { workspace.activate(index, in: pane.id); workspace.pin(pane.id) } }
            Button(L("Split Right")) { workspace.activate(index, in: pane.id); split(.right) }
            Button(L("Split Down")) { workspace.activate(index, in: pane.id); split(.bottom) }
            if workspace.canCloseTab {
                Button(L("Open in New Window")) {
                    app.openInNewWindow(tab, of: session)
                    workspace.close(index, in: pane.id)
                        }
            }
            if workspace.panes.count > 1, let other = workspace.panes.first(where: { $0.id != pane.id }) {
                Button(L("Move to the other pane")) { workspace.move(index, from: pane.id, to: other.id) }
            }
            if let id = tab.chapterID {
                let cards = workspace.showsSceneCards(pane: pane.id, chapter: id)
                Divider()
                Button(cards ? L("Show as Text") : session.words.showAsCards) {
                    workspace.activate(index, in: pane.id)
                    workspace.setSceneCards(!cards, pane: pane.id, chapter: id)
                }
                Button(session.words.openCardsBeside) {
                    workspace.activate(index, in: pane.id)
                    session.open(id, show: false)
                    workspace.openSceneCards(id, in: .nextPane)
                }
            }
            Divider()
            if workspace.canCloseTab {
                Button(L("Close Tab")) { workspace.close(index, in: pane.id) }
            }
            if pane.tabs.count > 1 {
                Button(L("Close the other tabs")) {
                    for j in pane.tabs.indices.reversed() where j != index { workspace.close(j, in: pane.id) }
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }

    static func title(_ tab: PaneTab, session: BookSession) -> String {
        switch tab {
        case .chapter(let id):
            if let ch = session.manifest.chapters.first(where: { $0.id == id }) { return session.manifest.numberedTitle(of: ch) }
            return session.anyChapter(id)?.title ?? id
        case .sheet(let p), .folder(let p):
            if case .folder = tab { return BibleStore.folderLabel(p) }
            return session.bible.entry(path: p)?.title ?? (p as NSString).lastPathComponent
        case .sources: return L("Sources")
        // The first page is Overview itself; the others say which they are.
        case .overview(let r): return OverviewTab(rawValue: r).flatMap { $0 == .summary ? nil : L("Overview") + " · " + $0.label } ?? L("Overview")
        case .story: return L("The Book’s History")
        case .debate: return L("Debate")
        case .special(let r): return SpecialPage(rawValue: r)?.label ?? r
        }
    }

    static func icon(_ tab: PaneTab, session: BookSession) -> String {
        switch tab {
        case .chapter: "doc.text"
        case .sheet(let p): session.bible.entry(path: p)?.kind.icon ?? "doc"
        case .folder: "folder"
        case .sources: "books.vertical"
        case .overview: "square.grid.2x2"
        case .story: "point.topleft.down.to.point.bottomright.curvepath"
        case .debate: "person.3"
        case .special: "book.closed"
        }
    }
}
