import Foundation

/// The book's windows, their panes and tabs: which chapter is written in, what is dropped on them, the layouts kept.
extension BookSession {
    /// The one place the chapter written in follows the tabs: whenever the panes of the window one is in change, or
    /// one goes to another window, the chapter shown in the pane one is in becomes the one written in. A page that
    /// is not a chapter changes nothing: one is still « in » the chapter left.
    func followFocusedPane() {
        guard let id = workspace.activeTab?.chapterID, id != selectedChapterID else { return }
        open(id, show: false)
    }

    /// A window's panes: their layout is kept with the book, and the chapter written in follows them.
    func watch(_ ws: Workspace) {
        ws.changed = { [weak self, weak ws] in
            guard let self else { return }
            self.stateChanged()
            if ws === self.workspace { self.followFocusedPane() }
        }
    }

    /// Tabs whose sheet or chapter is gone (deleted, moved to the Trash) close, in every window.
    func pruneTabs() {
        let chapters = Set((manifest.chapters + draftChapters).map(\.id))
        for ws in allWorkspaces {
            for pane in ws.panes {
                for tab in pane.tabs {
                    switch tab {
                    case .chapter(let id) where !chapters.contains(id): ws.closeAll(tab)
                    case .sheet(let p) where bible.entry(path: p) == nil: ws.closeAll(tab)
                    default: break
                    }
                }
            }
        }
    }

    /// What a saved layout keeps: the tabs whose chapter or sheet still exists.
    static func keeper(root: URL, manifest: BookManifest) -> (PaneTab) -> Bool {
        let chapters = Set((manifest.chapters + (manifest.drafts ?? [])).map(\.id))
        let sheets = BibleStore(root: root)
        return { tab in
            switch tab {
            case .chapter(let id): chapters.contains(id)
            case .sheet(let p), .folder(let p): FileManager.default.fileExists(atPath: sheets.url(p).path)
            default: true
            }
        }
    }

    // MARK: Windows

    /// The panes of a window: the main one (nil), or another, as it was left.
    func workspace(forWindow id: String?) -> Workspace {
        guard let id else { return mainWorkspace }
        if let ws = windows[id] { return ws }
        let ws = state.windows?[id].map { Workspace(saved: $0, keep: Self.keeper(root: root, manifest: manifest)) } ?? Workspace()
        watch(ws)
        windows[id] = ws
        return ws
    }

    /// A new window for a tab; returns its id.
    func newWindow(with tab: PaneTab) -> String {
        let id = UUID().uuidString
        let ws = Workspace(root: .pane(Pane(tabs: [tab], active: 0)))
        watch(ws)
        windows[id] = ws
        stateChanged()
        return id
    }

    /// A window closed by the author: its tabs go, its chapters are saved and let go.
    func closeWindow(_ id: String) {
        windows[id] = nil
        state.windows?[id] = nil
        if activeWindow == id { activeWindow = nil }
        pruneDocs()
        stateChanged()
    }

    // MARK: Named layouts

    func saveLayout(named name: String) {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        var all = state.layouts ?? [:]
        all[name] = workspace.saved
        state.layouts = all
        layoutNames = all.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        stateChanged()
    }

    /// Puts a named layout back in the window one is in.
    func applyLayout(named name: String) {
        guard let saved = state.layouts?[name] else { return }
        flushSave()
        workspace.restore(saved, keep: Self.keeper(root: root, manifest: manifest))
    }

    func deleteLayout(named name: String) {
        state.layouts?[name] = nil
        if state.layouts?.isEmpty == true { state.layouts = nil }
        layoutNames.removeAll { $0 == name }
        stateChanged()
    }

    /// The windows left open last time, to open again with the book.
    var savedWindowIDs: [String] { (state.windows ?? [:]).keys.sorted() }

    /// The window whose panes hold this pane.
    func owner(ofPane paneID: String) -> Workspace? {
        allWorkspaces.first { $0.panes.contains { $0.id == paneID } }
    }

    /// The chapters some tab holds, in any window: they stay open, so going back to one is instant.
    var shownChapters: Set<String> {
        Set(allWorkspaces.flatMap { $0.panes.flatMap { $0.tabs.compactMap(\.chapterID) } })
    }

    func keepLayout() {
        state.layout = mainWorkspace.saved
        state.forgetOldLastChapter()
        // Windows not opened again yet keep their layout.
        var all = state.windows ?? [:]
        for (id, ws) in windows { all[id] = ws.saved }
        state.windows = all.isEmpty ? nil : all
    }

    // MARK: Opening and dropping

    /// Opens a tab where asked; a chapter also becomes the one written in.
    func open(_ tab: PaneTab, in place: OpenPlace) {
        if let id = tab.chapterID { open(id, show: false) }
        workspace.open(tab, in: place)
    }

    /// A drop on the panes, in any of the book's windows: a tab moved, or something from the sidebar opened there.
    @discardableResult
    func dropOnPanes(_ wire: String, at target: PaneDropTarget) -> Bool {
        for ws in allWorkspaces { ws.drops.hover = nil }
        TearOff.shared.handled = true
        guard let drag = ShelfDrag(wire: wire), let into = owner(ofPane: target.pane) else { return false }
        activate(into)
        if case .tab(let source, let index) = drag {
            guard let from = owner(ofPane: source) else { return false }
            guard from === into else {
                // From another window: it leaves that one and opens here.
                guard let tab = from.panes.first(where: { $0.id == source })?.tabs[safe: index] else { return false }
                from.close(index, in: source)
                return place(tab, at: target, in: into)
            }
            switch target.zone {
            case .tabs(let at): into.move(index, from: source, to: target.pane, at: at)
            case .edge(let edge): into.move(index, from: source, to: target.pane, edge: edge)
            case .center:
                guard source != target.pane else { return false }
                into.move(index, from: source, to: target.pane)
            }
            return true
        }
        guard let tab = drag.paneTab else { return false }
        return place(tab, at: target, in: into)
    }

    private func place(_ tab: PaneTab, at target: PaneDropTarget, in ws: Workspace) -> Bool {
        if let id = tab.chapterID { open(id, show: false) }
        ws.together {
            ws.focus(target.pane)
            switch target.zone {
            case .tabs(let at): ws.place(tab, in: target.pane, at: at)
            case .edge(let edge): ws.open(tab, in: .split(edge))
            case .center: ws.open(tab, in: .newTab)
            }
        }
        return true
    }

    /// The window of these panes becomes the one one is in.
    func activate(_ ws: Workspace) {
        let id = windows.first { $0.value === ws }?.key
        if activeWindow != id { activeWindow = id }
    }
}
