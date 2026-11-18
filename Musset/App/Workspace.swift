import Foundation
import Observation

/// What a tab shows: a chapter to write in, or one of the book's pages.
enum PaneTab: Hashable {
    case chapter(String)
    /// A Bible sheet, or a board (a `.canvas` in the Bible).
    case sheet(String)
    case folder(String)
    case sources
    /// The book's Overview, on one of its pages (`OverviewTab`): the book in numbers over its scenes, Synopsis, Grid.
    case overview(String)
    case special(String)
    /// The book's history: the manuscript, its tracks and milestones.
    case story
    /// The debate: the AI reader's wide view.
    case debate

    var chapterID: String? { if case .chapter(let id) = self { id } else { nil } }
    var isChapter: Bool { chapterID != nil }
    /// The Overview page it shows, the special page, the sheet or folder of the Bible.
    var overview: OverviewTab? { if case .overview(let r) = self { OverviewTab(rawValue: r) ?? .summary } else { nil } }
    var special: SpecialPage? { if case .special(let r) = self { SpecialPage(rawValue: r) } else { nil } }
    var biblePath: String? {
        switch self {
        case .sheet(let p), .folder(let p): p
        default: nil
        }
    }

    /// The same tab once its sheet or folder has moved in the Bible (`move`: where a path went).
    func retargeted(_ move: (String) -> String) -> PaneTab {
        switch self {
        case .sheet(let p): .sheet(move(p))
        case .folder(let p): .folder(move(p))
        default: self
        }
    }
}

/// Kept in the book's saved layouts. The Synopsis and the plot grid were tabs of their own, the debate, the book's
/// settings and the scenes were pages of Overview: layouts kept then still open, each on the place that took it over
/// (the scenes are on Overview's first page).
extension PaneTab: Codable {
    private enum Stored: Codable {
        case chapter(String), sheet(String), folder(String), synopsis, sources, overview(String), plotGrid, special(String), story, debate
    }

    init(from decoder: Decoder) throws {
        switch try Stored(from: decoder) {
        case .chapter(let id): self = .chapter(id)
        case .sheet(let p): self = .sheet(p)
        case .folder(let p): self = .folder(p)
        case .synopsis: self = OverviewTab.synopsis.tab
        case .plotGrid: self = OverviewTab.grid.tab
        case .sources: self = .sources
        case .overview("debate"): self = .debate
        case .overview(let r): self = (OverviewTab(rawValue: r) ?? .summary).tab
        case .special(let r): self = .special(r)
        case .story: self = .story
        case .debate: self = .debate
        }
    }

    func encode(to encoder: Encoder) throws {
        let stored: Stored = switch self {
        case .chapter(let id): .chapter(id)
        case .sheet(let p): .sheet(p)
        case .folder(let p): .folder(p)
        case .sources: .sources
        case .overview(let r): .overview(r)
        case .special(let r): .special(r)
        case .story: .story
        case .debate: .debate
        }
        try stored.encode(to: encoder)
    }
}

/// One pane: its tabs, the one shown, and its preview tabs (opened by a click, replaced by the next one until worked
/// in): one for chapters, one for the book's pages, so browsing the Bible never takes the chapter's place.
struct Pane: Codable, Equatable, Identifiable {
    var id = UUID().uuidString
    var tabs: [PaneTab] = []
    var active = 0
    var preview: Int?
    var chapterPreview: Int?

    var activeTab: PaneTab? { tabs.indices.contains(active) ? tabs[active] : nil }

    func isPreview(_ i: Int) -> Bool { preview == i || chapterPreview == i }

    /// Where `tab` already is among the tabs. Overview is one tab whatever page it shows: opening it on another
    /// page turns that tab to the page.
    func index(of tab: PaneTab) -> Int? {
        tab.overview != nil ? tabs.firstIndex { $0.overview != nil } : tabs.firstIndex(of: tab)
    }

    /// Shows the tab at `i`, turned to `tab` (the same tab, or Overview on another page).
    mutating func show(_ tab: PaneTab, at i: Int) { tabs[i] = tab; active = i }

    /// The preview slot for a tab of this kind.
    func previewSlot(for tab: PaneTab) -> Int? { tab.isChapter ? chapterPreview : preview }
    mutating func setPreview(_ i: Int?, for tab: PaneTab) { if tab.isChapter { chapterPreview = i } else { preview = i } }

    /// After a tab was inserted at `at` (or removed there, `by: -1`), the slots after it move.
    mutating func shift(from at: Int, by delta: Int) {
        if let pv = preview, pv >= at { preview = pv + delta }
        if let pv = chapterPreview, pv >= at { chapterPreview = pv + delta }
    }

    mutating func unpreview(_ i: Int) {
        if preview == i { preview = nil }
        if chapterPreview == i { chapterPreview = nil }
    }
}

/// The window's layout: a pane, or panes side by side (`.horizontal`) or stacked (`.vertical`), each with its share.
indirect enum PaneNode: Codable, Equatable {
    case pane(Pane)
    case split(vertical: Bool, children: [PaneNode], fractions: [Double])

    var panes: [Pane] {
        switch self {
        case .pane(let p): [p]
        case .split(_, let children, _): children.flatMap(\.panes)
        }
    }

    /// The same layout, its sheet and folder tabs following what moved in the Bible.
    func retargeted(_ move: (String) -> String) -> PaneNode {
        switch self {
        case .pane(var p):
            p.tabs = p.tabs.map { $0.retargeted(move) }
            return .pane(p)
        case .split(let v, let children, let fr):
            return .split(vertical: v, children: children.map { $0.retargeted(move) }, fractions: fr)
        }
    }
}

/// The levels the scenes are looked at from, like a zoom: the whole book as its chapters, one part as its chapters'
/// scenes, one chapter as its scenes' cards. The first two are the board of Overview's first page; the last is a
/// chapter's tab.
enum ScenesLevel: Hashable {
    case book, part, chapter
}

/// Where Overview's first page is asked to scroll to: its board of scenes, which lies under the book's numbers.
struct ScenesJump: Equatable {
    /// The chapter to bring into view on it; nil for the board's top.
    var chapter: String?
    /// The board as cards, even if it was last left as a list: one comes from a chapter's cards.
    var cards = false
}

/// Where to put what is opened.
enum OpenPlace: Equatable {
    /// In the pane one is in: the tab if it is already there, else in place of the preview tab, else a new preview tab.
    case current
    /// A new tab of its own (kept), in the pane one is in.
    case newTab
    /// In the next pane (made on the right if there is only one).
    case nextPane
    /// A new pane on one side of the pane one is in.
    case split(Edge)
    /// In place of the tab shown.
    case replace

    enum Edge: String, Codable { case left, right, top, bottom }
}

/// A window's panes and tabs. Everything that opens something goes through `open`.
@MainActor
@Observable
final class Workspace {
    private(set) var root: PaneNode {
        // A pane left without tabs goes, while others remain: its room goes to its neighbours.
        didSet {
            let chapters = Set(root.panes.flatMap { p in p.tabs.compactMap { $0.chapterID.map { EditorCache.key(pane: p.id, chapter: $0) } } })
            editors.keep(only: chapters)
            if !sceneCards.isSubset(of: chapters) { sceneCards.formIntersection(chapters) }
            if sceneCardSelection.keys.contains(where: { !chapters.contains($0) }) { sceneCardSelection = sceneCardSelection.filter { chapters.contains($0.key) } }
            let empty = root.panes.filter(\.tabs.isEmpty)
            guard !empty.isEmpty, root.panes.count > 1 else { return }
            var tree = root
            for p in empty where tree.panes.count > 1 { tree = Self.removing(p.id, from: tree) ?? tree }
            root = tree
            if !root.panes.contains(where: { $0.id == focusedPane }) { focusedPane = root.panes.first?.id ?? "" }
        }
    }
    private(set) var focusedPane: String
    /// Called once after each change, however many steps it took (a tab moved to another pane leaves one and joins
    /// the other): the layout is kept with the book, and the chapter written in follows the tab shown.
    @ObservationIgnored var changed: () -> Void = {}
    @ObservationIgnored private var steps = 0
    @ObservationIgnored private var touched = false

    /// Several changes told as one.
    func together(_ change: () -> Void) {
        steps += 1
        change()
        steps -= 1
        if steps == 0, touched { touched = false; changed() }
    }

    private func didChange() {
        if steps > 0 { touched = true } else { changed() }
    }
    /// Where the panes are on screen, for drags.
    let drops = PaneDrops()
    /// Each pane's editors, kept while their tabs are.
    @ObservationIgnored let editors = EditorCache()

    init(root: PaneNode? = nil) {
        let r = root ?? .pane(Pane())
        self.root = r
        self.focusedPane = r.panes.first?.id ?? ""
    }

    var panes: [Pane] { root.panes }
    var focused: Pane? { panes.first { $0.id == focusedPane } ?? panes.first }
    var activeTab: PaneTab? { focused?.activeTab }

    func focus(_ paneID: String) {
        guard focusedPane != paneID, panes.contains(where: { $0.id == paneID }) else { return }
        focusedPane = paneID
        didChange()
    }

    // MARK: Opening

    func open(_ tab: PaneTab, in place: OpenPlace = .current) {
        guard let pane = focused else { return }
        switch place {
        case .current:
            update(pane.id) { p in
                if let i = p.index(of: tab) { p.show(tab, at: i); return }
                if let pv = p.previewSlot(for: tab), p.tabs.indices.contains(pv) {
                    p.tabs[pv] = tab
                    p.active = pv
                } else {
                    let at = p.tabs.isEmpty ? 0 : p.active + 1
                    p.shift(from: at, by: 1)
                    p.tabs.insert(tab, at: at)
                    p.active = at
                    p.setPreview(at, for: tab)
                }
            }
        case .newTab:
            update(pane.id) { p in
                if let i = p.index(of: tab) { p.show(tab, at: i); p.unpreview(i); return }
                let at = p.tabs.isEmpty ? 0 : p.active + 1
                p.shift(from: at, by: 1)
                p.tabs.insert(tab, at: at)
                p.active = at
            }
        case .replace:
            update(pane.id) { p in
                if p.tabs.isEmpty { p.tabs = [tab]; p.active = 0 } else { p.unpreview(p.active); p.tabs[p.active] = tab }
            }
        case .nextPane:
            let all = panes
            if all.count > 1, let i = all.firstIndex(where: { $0.id == pane.id }) {
                let next = all[(i + 1) % all.count]
                together {
                    moveFocus(to: next.id)
                    open(tab, in: .newTab)
                }
            } else {
                open(tab, in: .split(.right))
            }
        case .split(let edge):
            let fresh = Pane(tabs: [tab], active: 0)
            root = Self.inserting(fresh, beside: pane.id, edge: edge, in: root)
            focusedPane = fresh.id
            didChange()
        }
    }

    /// A tab put at a place among a pane's tabs (dropped on its tab bar), kept.
    func place(_ tab: PaneTab, in paneID: String, at index: Int) {
        together {
            moveFocus(to: paneID)
            update(paneID) { p in
                if let i = p.index(of: tab) { p.show(tab, at: i); p.unpreview(i); return }
                let at = min(max(0, index), p.tabs.count)
                p.shift(from: at, by: 1)
                p.tabs.insert(tab, at: at)
                p.active = at
            }
        }
    }

    /// The tab shown, opened again in a new pane on that side.
    func splitActive(_ edge: OpenPlace.Edge) {
        guard let tab = activeTab else { return }
        open(tab, in: .split(edge))
    }

    /// The next (or previous) tab of the pane one is in.
    func cycleTab(by step: Int) {
        guard let p = focused, p.tabs.count > 1 else { return }
        activate((p.active + step + p.tabs.count) % p.tabs.count, in: p.id)
    }

    /// The next (or previous) pane, in reading order.
    func cyclePane(by step: Int) {
        let all = panes
        guard all.count > 1, let i = all.firstIndex(where: { $0.id == focusedPane }) else { return }
        focus(all[(i + step + all.count) % all.count].id)
    }

    /// ⌘W: the tab shown in the pane one is in, unless it is the window's last.
    var canCloseTab: Bool { (focused?.tabs.count ?? 0) > 1 || panes.count > 1 }
    func closeActiveTab() {
        guard canCloseTab, let p = focused else { return }
        close(p.active, in: p.id)
    }

    /// The tab one is working in stays: it is no longer the preview tab.
    func pin(_ paneID: String? = nil) {
        let id = paneID ?? focusedPane
        // Called on every keystroke: nothing to do unless the tab shown is a preview.
        guard let p = panes.first(where: { $0.id == id }), p.isPreview(p.active) else { return }
        update(id) { p in p.unpreview(p.active) }
    }

    func activate(_ index: Int, in paneID: String) {
        together {
            moveFocus(to: paneID)
            update(paneID) { p in if p.tabs.indices.contains(index) { p.active = index } }
        }
    }

    /// Closes a tab; a pane left empty goes, and its share goes to its neighbours.
    func close(_ index: Int, in paneID: String) {
        guard let pane = panes.first(where: { $0.id == paneID }), pane.tabs.indices.contains(index) else { return }
        if pane.tabs.count == 1, panes.count > 1 {
            root = Self.removing(paneID, from: root) ?? .pane(Pane())
            if focusedPane == paneID { focusedPane = panes.first?.id ?? "" }
            didChange()
            return
        }
        update(paneID) { p in
            p.unpreview(index)
            p.tabs.remove(at: index)
            p.shift(from: index + 1, by: -1)
            if p.active >= p.tabs.count || p.active > index { p.active = max(0, p.active - 1) }
        }
    }

    /// Closes every tab, in every pane, that shows `tab` (a sheet deleted, a chapter gone).
    func closeAll(_ tab: PaneTab) {
        together {
            for pane in panes {
                while let i = panes.first(where: { $0.id == pane.id })?.tabs.firstIndex(of: tab) { close(i, in: pane.id) }
            }
        }
    }

    /// A tab dragged to another pane (or another place in its own); `edge` makes a new pane beside the target.
    func move(_ index: Int, from source: String, to target: String, at position: Int? = nil, edge: OpenPlace.Edge? = nil) {
        together { moveSteps(index, from: source, to: target, at: position, edge: edge) }
    }

    private func moveSteps(_ index: Int, from source: String, to target: String, at position: Int?, edge: OpenPlace.Edge?) {
        guard let from = panes.first(where: { $0.id == source }), from.tabs.indices.contains(index) else { return }
        let tab = from.tabs[index]
        if let edge {
            if source == target, from.tabs.count == 1 { return }
            close(index, in: source)
            guard panes.contains(where: { $0.id == target }) else { return }
            focusedPane = target
            open(tab, in: .split(edge))
            return
        }
        if source == target {
            update(source) { p in
                p.tabs.remove(at: index)
                let at = min(max(0, (position ?? p.tabs.count) - (position.map { $0 > index ? 1 : 0 } ?? 0)), p.tabs.count)
                p.tabs.insert(tab, at: at)
                p.active = at
                p.preview = nil
                p.chapterPreview = nil
            }
            return
        }
        close(index, in: source)
        guard panes.contains(where: { $0.id == target }) else { return }
        moveFocus(to: target)
        update(target) { p in
            if let i = p.tabs.firstIndex(of: tab) { p.active = i; return }
            let at = min(position ?? p.tabs.count, p.tabs.count)
            p.shift(from: at, by: 1)
            p.tabs.insert(tab, at: at)
            p.active = at
        }
    }

    /// A pane's share of its row or column, after its handle was dragged.
    func resize(_ path: [Int], fractions: [Double]) {
        root = Self.setting(fractions, at: path, in: root)
        didChange()
    }

    // MARK: Scene cards

    /// The chapter tabs shown as their scenes' cards rather than as text, keyed like the editors (`EditorCache.key`).
    /// A way of looking at a chapter in a pane: in memory only, never kept with the layout, gone with its tab.
    private(set) var sceneCards: Set<String> = []
    /// The card chosen in each: its scene's place in the chapter.
    private(set) var sceneCardSelection: [String: Int] = [:]

    func showsSceneCards(pane: String, chapter: String) -> Bool { sceneCards.contains(EditorCache.key(pane: pane, chapter: chapter)) }

    func setSceneCards(_ on: Bool, pane: String, chapter: String) {
        let key = EditorCache.key(pane: pane, chapter: chapter)
        guard on != sceneCards.contains(key) else { return }
        if on {
            guard panes.contains(where: { $0.id == pane && $0.tabs.contains(.chapter(chapter)) }) else { return }
            sceneCards.insert(key)
        } else {
            sceneCards.remove(key)
        }
    }

    /// The chapter shown as cards in the pane one is in, if it is.
    var focusedSceneCards: String? {
        guard let p = focused, let id = p.activeTab?.chapterID, showsSceneCards(pane: p.id, chapter: id) else { return nil }
        return id
    }

    /// The chapter of the pane one is in, as cards or back as text.
    func toggleSceneCards() {
        guard let p = focused, let id = p.activeTab?.chapterID else { return }
        setSceneCards(!showsSceneCards(pane: p.id, chapter: id), pane: p.id, chapter: id)
    }

    func selectedSceneCard(pane: String, chapter: String) -> Int? { sceneCardSelection[EditorCache.key(pane: pane, chapter: chapter)] }

    func selectSceneCard(_ index: Int?, pane: String, chapter: String) {
        let key = EditorCache.key(pane: pane, chapter: chapter)
        if sceneCardSelection[key] != index { sceneCardSelection[key] = index }
    }

    /// A chapter opened as cards: in the next pane, to keep its text beside them.
    func openSceneCards(_ chapter: String, in place: OpenPlace) {
        together {
            open(.chapter(chapter), in: place)
            setSceneCards(true, pane: focusedPane, chapter: chapter)
        }
    }

    // MARK: The board of scenes

    /// How far the board of scenes (Overview's first page) is zoomed out, the part it shows at the part level, the
    /// chapter chosen on it and the parts folded at the book level. Like the scene cards: in memory only, never
    /// kept with the layout.
    private(set) var scenesLevel = ScenesLevel.book
    private(set) var scenesPart: String?
    private(set) var scenesChapter: String?
    private(set) var scenesFolded: Set<String> = []
    /// The strand the board is read along: only the chapters that follow it show. Nil is the whole book.
    private(set) var scenesStrand: String?
    /// A scroll the page owes: asked for from outside it (a chapter's cards, the bars above the board), taken by
    /// the page when it shows.
    private(set) var scenesJump: ScenesJump?

    func jumpToScenes(_ jump: ScenesJump) { scenesJump = jump }

    func takeScenesJump() -> ScenesJump? {
        defer { if scenesJump != nil { scenesJump = nil } }
        return scenesJump
    }

    /// The page at the book level, or at one part's.
    func zoomScenes(toPart part: String?) {
        scenesLevel = part == nil ? .book : .part
        if let part { scenesPart = part }
    }

    func chooseScenesChapter(_ chapter: String?) {
        if scenesChapter != chapter { scenesChapter = chapter }
    }

    func readScenes(alongStrand strand: String?) {
        if scenesStrand != strand { scenesStrand = strand }
    }

    func foldScenes(_ part: String, _ folded: Bool) {
        if folded { scenesFolded.insert(part) } else { scenesFolded.remove(part) }
    }

    // MARK: The tree

    /// Nothing moved: the tree is not assigned again (everything that shows it would redraw) and nothing is saved.
    private func update(_ paneID: String, _ edit: (inout Pane) -> Void) {
        let next = Self.mapping(root) { p in
            guard p.id == paneID else { return p }
            var p = p
            edit(&p)
            return p
        }
        guard next != root else { return }
        root = next
        didChange()
    }

    /// The pane one is in changes: kept with the layout, even when its tabs stay as they are.
    private func moveFocus(to paneID: String) {
        guard focusedPane != paneID else { return }
        focusedPane = paneID
        didChange()
    }

    static func mapping(_ node: PaneNode, _ f: (Pane) -> Pane) -> PaneNode {
        switch node {
        case .pane(let p): .pane(f(p))
        case .split(let v, let children, let fr): .split(vertical: v, children: children.map { mapping($0, f) }, fractions: fr)
        }
    }

    static func inserting(_ fresh: Pane, beside target: String, edge: OpenPlace.Edge, in node: PaneNode) -> PaneNode {
        let vertical = edge == .top || edge == .bottom
        let before = edge == .left || edge == .top
        switch node {
        case .pane(let p) where p.id == target:
            return .split(vertical: vertical, children: before ? [.pane(fresh), node] : [node, .pane(fresh)], fractions: [0.5, 0.5])
        case .pane:
            return node
        case .split(let v, let children, let fr):
            // Beside a pane of a row going the same way: one more in the row, its neighbour's share halved.
            if v == vertical, let i = children.firstIndex(where: { if case .pane(let p) = $0 { p.id == target } else { false } }) {
                var kids = children, shares = fr
                let half = shares[i] / 2
                shares[i] = half
                let at = before ? i : i + 1
                kids.insert(.pane(fresh), at: at)
                shares.insert(half, at: at)
                return .split(vertical: v, children: kids, fractions: shares)
            }
            return .split(vertical: v, children: children.map { inserting(fresh, beside: target, edge: edge, in: $0) }, fractions: fr)
        }
    }

    static func removing(_ id: String, from node: PaneNode) -> PaneNode? {
        switch node {
        case .pane(let p): return p.id == id ? nil : node
        case .split(let v, let children, let fr):
            var kids: [PaneNode] = [], shares: [Double] = []
            for (child, share) in zip(children, fr) {
                if let kept = removing(id, from: child) { kids.append(kept); shares.append(share) }
            }
            if kids.isEmpty { return nil }
            if kids.count == 1 { return kids[0] }
            let total = shares.reduce(0, +)
            return .split(vertical: v, children: kids, fractions: shares.map { $0 / max(total, 0.0001) })
        }
    }

    static func setting(_ fractions: [Double], at path: [Int], in node: PaneNode) -> PaneNode {
        guard case .split(let v, let children, let fr) = node else { return node }
        guard let head = path.first else {
            return .split(vertical: v, children: children, fractions: fractions.count == children.count ? fractions : fr)
        }
        var kids = children
        if kids.indices.contains(head) { kids[head] = setting(fractions, at: Array(path.dropFirst()), in: kids[head]) }
        return .split(vertical: v, children: kids, fractions: fr)
    }

    // MARK: Keeping it

    struct Saved: Codable, Equatable {
        var root: PaneNode
        var focusedPane: String

        func retargeted(_ move: (String) -> String) -> Saved { Saved(root: root.retargeted(move), focusedPane: focusedPane) }

        /// The chapter one was in when this was kept: the one shown in the pane one was in, else another of its
        /// tabs, else another pane's.
        var lastChapter: String? {
            let panes = root.panes.filter { $0.id == focusedPane } + root.panes.filter { $0.id != focusedPane }
            return panes.lazy.compactMap { $0.activeTab?.chapterID ?? $0.tabs.lazy.compactMap(\.chapterID).first }.first
        }
    }

    /// Open tabs follow a sheet or a folder that moved in the Bible.
    func retarget(_ move: (String) -> String) {
        let next = root.retargeted(move)
        guard next != root else { return }
        root = next
        didChange()
    }

    var saved: Saved { Saved(root: root, focusedPane: focusedPane) }

    /// A named layout put back in this window: its panes are new ones, so two windows can wear the same layout.
    func restore(_ saved: Saved, keep: (PaneTab) -> Bool) {
        let other = Workspace(saved: saved, keep: keep)
        var ids: [String: String] = [:]
        root = Self.mapping(other.root) { p in
            var p = p
            let fresh = UUID().uuidString
            ids[p.id] = fresh
            p.id = fresh
            return p
        }
        focusedPane = ids[other.focusedPane] ?? panes.first?.id ?? ""
        didChange()
    }

    /// A saved layout, with the tabs whose chapter or sheet no longer exists taken out.
    convenience init(saved: Saved, keep: (PaneTab) -> Bool) {
        let cleaned = Self.mapping(saved.root) { p in
            var p = p
            // Overview is one tab: of several kept by an older layout (Synopsis and the grid were tabs of their own),
            // the one shown stays, else the first.
            let overviews = p.tabs.indices.filter { p.tabs[$0].overview != nil }
            let overview = overviews.contains(p.active) ? p.active : overviews.first
            let kept = p.tabs.enumerated().filter { keep($0.element) && ($0.element.overview == nil || $0.offset == overview) }
            p.tabs = kept.map(\.element)
            p.active = kept.firstIndex { $0.offset == p.active } ?? 0
            p.preview = p.preview.flatMap { pv in kept.firstIndex { $0.offset == pv } }
            p.chapterPreview = p.chapterPreview.flatMap { pv in kept.firstIndex { $0.offset == pv } }
            return p
        }
        // Panes left with nothing go.
        var tree: PaneNode? = cleaned
        for p in cleaned.panes where p.tabs.isEmpty && cleaned.panes.count > 1 { tree = tree.flatMap { Self.removing(p.id, from: $0) } }
        self.init(root: tree ?? .pane(Pane()))
        if panes.contains(where: { $0.id == saved.focusedPane }) { focusedPane = saved.focusedPane }
    }
}
