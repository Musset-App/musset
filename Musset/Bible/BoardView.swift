import ImageIO
import MapKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// A board of the Bible, as on a cork board: notes, images, PDFs, archived pages, maps, passages of the book, sheets,
/// columns and arrows, placed freely.
///
/// Two fingers pan, a pinch (or ⌘ and the wheel) zooms around the pointer, Space and a drag pan too. A drag on the
/// background draws a box that selects; ⇧ adds to the selection. Double-click the background for a note, a note
/// to write in it. Cards come to rest on the grid; a column carries its cards. ⌘D duplicates, ⌫ removes, the
/// arrows nudge. The board itself only redraws when its cards change: moving, panning and zooming touch only
/// what moves.
struct BoardView: View {
    let app: AppState
    @Bindable var session: BookSession
    let bridge: EditorBridge
    let path: String
    @State private var board = JSONCanvas()
    @State private var camera = BoardCamera()
    @State private var motion = BoardMotion()
    @State private var selection: Set<String> = []
    /// The arrow picked, when one is: cards and arrows are not selected together.
    @State private var selectedEdge: String?
    @State private var editing: String?
    /// The board's name being typed, in its title.
    @State private var renaming: String?
    @FocusState private var namingBoard: Bool
    @State private var linking: String?
    @State private var tool: BoardTool = .select
    /// The marker's colour (empty: the ink of the page) and width, the next sticky note's colour, the next shape.
    @AppStorage("boardInk") private var inkColor = ""
    @AppStorage("boardInkWidth") private var inkWidth = 3.0
    @AppStorage("boardSticky") private var stickyColor = "3"
    @AppStorage("boardShape") private var shapeKind = "rect"
    @State private var askingURL = false
    @State private var webAddress = ""
    @State private var working: String?
    @State private var saveTask: Task<Void, Never>?
    @State private var size: CGSize = .zero
    @FocusState private var focused: Bool
    /// The cards of the people and places in the paragraph being written light up.
    @AppStorage("boardFollowsText") private var follows = false

    private var bible: BibleModel { session.bible }
    private var fileURL: URL { bible.store.url(path) }
    private var title: String { bible.entry(path: path)?.title ?? (path as NSString).lastPathComponent }
    /// Where the chrome leaves room for the cards: the toolbar on the left, the title on top.
    private static let room = EdgeInsets(top: 96, leading: 40, bottom: 96, trailing: 40)

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                BoardBackground(camera: camera)
                    .contentShape(Rectangle())
                    .gesture(backgroundDrag)
                    .onTapGesture(count: 1, coordinateSpace: .local) { p in backgroundClick(at: p) }
                BoardViewport(camera: camera) { cards }
                MarqueeView(motion: motion, dashed: tool.places)
                // Drawing, erasing, placing or panning: the whole board takes the pointer, not the cards.
                if tool.takesTheBoard {
                    BoardToolLayer(tool: tool, changed: { toolDrag($0) }, ended: { toolEnd($0) })
                }
                header
                if let id = selectedEdge, let e = board.edges.first(where: { $0.id == id }), let route = board.route(of: e) {
                    EdgeBar(camera: camera, middle: route.middle, edge: e,
                            edit: { edit in change { b in if let i = b.edges.firstIndex(where: { $0.id == id }) { edit(&b.edges[i]) } } },
                            remove: { removeSelection() })
                }
                toolbar.padding(.bottom, 16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                linkedFrom.padding(16).frame(maxWidth: .infinity, alignment: .topTrailing)
                BoardZoomControls(camera: camera, center: CGPoint(x: geo.size.width / 2, y: geo.size.height / 2), fit: { fit(animated: true) })
                    .padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                if let working {
                    Text(working).font(.ui(12)).padding(.horizontal, 12).padding(.vertical, 7)
                        .background(Ink.side, in: Capsule()).overlay(Capsule().strokeBorder(Ink.hairline))
                        .padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                }
            }
            .coordinateSpace(name: BoardSpace.screen)
            .background(BoardEvents(camera: camera, passesThrough: { p in [editingRect, selectedMapRect].contains { $0?.contains(p) == true } }))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            // Cards scrolled out of the board are hidden; they must not catch clicks beyond it either.
            .contentShape(Rectangle())
            .onAppear {
                size = geo.size
                board = JSONCanvas.read(fileURL)
                if let kept = BoardCamera.kept[path] { camera.pan = kept.pan; camera.zoom = kept.zoom } else { fit(animated: false) }
            }
            .onChange(of: geo.size) { _, s in size = s }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onDeleteCommand { removeSelection() }
        .onChange(of: selection) { _, now in if !now.isEmpty { selectedEdge = nil } }
        .onKeyPress(phases: .down) { press in key(press) }
        .onChange(of: tool) { _, t in if t != .connector { linking = nil }; if t != .select { endEditing() } }
        .onDrop(of: [.fileURL, .url, .text], isTargeted: nil) { providers, location in
            receive(providers, at: location)
        }
        .onDisappear {
            BoardCamera.kept[path] = (camera.pan, camera.zoom)
            save(now: true)
        }
        .onChange(of: session.boardsRewritten) {
            saveTask?.cancel()
            board = JSONCanvas.read(fileURL)
        }
        .alert(L("A web page"), isPresented: $askingURL) {
            TextField("https://…", text: $webAddress)
            Button(L("Add")) { addWeb(webAddress) }
            Button(L("Cancel"), role: .cancel) {}
        } message: {
            Text(L("Musset keeps the page, so it stays here if the site goes."))
        }
    }

    // MARK: The cards

    private var cards: some View {
        let lit = lit
        let one = selection.count == 1 ? selection.first : nil
        return ZStack(alignment: .topLeading) {
            ForEach(board.nodes.filter { $0.type == .group }) { item($0, lit: false, handles: one == $0.id) }
            ForEach(board.nodes.filter { $0.type != .group }) { item($0, lit: $0.file.map(lit.contains) ?? false, handles: one == $0.id) }
            // Over the cards, as in FigJam: an arrow is never cut by a card it passes.
            BoardEdges(board: board, motion: motion, selected: selectedEdge).allowsHitTesting(false).zIndex(3)
            SelectionBox(board: board, selection: selection, motion: motion)
            InkPreview(motion: motion, color: BoardPalette.ink(inkColor.isEmpty ? nil : inkColor),
                       width: tool == .highlighter ? inkWidth * 5 : inkWidth, highlighter: tool == .highlighter)
        }
    }

    private func item(_ node: JSONCanvas.Node, lit: Bool, handles: Bool) -> some View {
        BoardItem(node: node, session: session, motion: motion, camera: camera, connecting: tool == .connector,
                  selected: selection.contains(node.id) || linking == node.id, lit: lit, editing: editing == node.id, handles: handles,
                  actions: actions)
    }

    /// What a card asks of the board.
    private var actions: BoardActions {
        BoardActions(
            click: { id in click(id) },
            beginMove: { id in
                if !selection.contains(id) { selection = NSEvent.modifierFlags.contains(.shift) ? selection.union([id]) : [id] }
                editing = nil
                motion.ids = board.carried(selection)
            },
            endMove: { delta in
                let ids = motion.ids
                change { $0.move(ids, by: delta.width, delta.height, snap: !NSEvent.modifierFlags.contains(.command)) }
                motion.ids = []
                motion.delta = .zero
            },
            endResize: { id, frame in
                change { b in
                    guard let i = b.nodes.firstIndex(where: { $0.id == id }) else { return }
                    // On the grid, unless it is a stroke, which keeps the shape it was given.
                    let g = b.nodes[i].mussetKind == "ink" ? 1.0 : CGFloat(JSONCanvas.snap)
                    let x0 = (frame.minX / g).rounded() * g, y0 = (frame.minY / g).rounded() * g
                    let x1 = (frame.maxX / g).rounded() * g, y1 = (frame.maxY / g).rounded() * g
                    b.nodes[i].x = Int(x0); b.nodes[i].y = Int(y0)
                    b.nodes[i].width = max(1, Int(x1 - x0)); b.nodes[i].height = max(1, Int(y1 - y0))
                }
                motion.resizing = nil
            },
            endLink: {
                defer { motion.linkFrom = nil; motion.linkTarget = nil }
                guard let from = motion.linkFrom, let to = motion.linkTarget, to.id != from else { return }
                let side = motion.linkFromSide
                change { $0.edges.append(.init(fromNode: from, toNode: to.id, fromSide: side.rawValue, toSide: to.side.rawValue)) }
                // Once the gesture is over: changing tool swaps the views it runs in.
                if tool == .connector { DispatchQueue.main.async { tool = .select } }
            },
            magnet: { p, from in
                // A little around each card too, so the magnets outside its edge catch the pointer.
                let reach = 18 / camera.zoom
                guard let n = board.nodes.last(where: { $0.id != from && $0.mussetKind != "ink" && board.rect(of: $0).insetBy(dx: -reach, dy: -reach).contains(p) && $0.type != .group })
                        ?? board.nodes.last(where: { $0.id != from && $0.type == .group && board.rect(of: $0).contains(p) }) else { return nil }
                let r = board.rect(of: n)
                return (n.id, BoardSide.nearest(r, to: p), r)
            },
            text: { id, text in
                change { b in
                    guard let i = b.nodes.firstIndex(where: { $0.id == id }) else { return }
                    if b.nodes[i].type == .group { b.nodes[i].label = text } else { b.nodes[i].text = text }
                }
            },
            musset: { id, keys in
                change { b in
                    guard let i = b.nodes.firstIndex(where: { $0.id == id }) else { return }
                    b.nodes[i].musset = keys
                    b.nodes[i].text = keys["address"] ?? b.nodes[i].text
                }
            },
            endEditing: { endEditing() },
            open: { node in open(node) },
            color: { id, color in
                let ids = selection.contains(id) ? selection : [id]
                change { b in for i in b.nodes.indices where ids.contains(b.nodes[i].id) { b.nodes[i].color = color } }
            },
            duplicate: { id in duplicate(selection.contains(id) ? selection : [id]) },
            group: { id in group(selection.contains(id) ? selection : [id]) },
            severalSelected: { id in selection.count > 1 && selection.contains(id) },
            toFront: { id in change { $0.bringToFront(selection.contains(id) ? selection : [id]) } },
            unlink: { id in change { $0.edges.removeAll { $0.fromNode == id || $0.toNode == id } } },
            remove: { id in
                let ids = selection.contains(id) ? selection : [id]
                change { b in for i in ids { b.remove(i) } }
                selection.subtract(ids)
            },
            hasEdges: { id in board.edges.contains { $0.fromNode == id || $0.toNode == id } },
            edit: { id, f in change { b in if let i = b.nodes.firstIndex(where: { $0.id == id }) { f(&b.nodes[i]) } } }
        )
    }

    /// The sheets named in the paragraph the caret is in, in the chapter being written.
    private var lit: Set<String> {
        guard follows, session.selectedChapterID != nil else { return [] }
        let text = session.text
        let ns = text as NSString
        guard ns.length > 0 else { return [] }
        let para = ns.paragraphRange(for: NSRange(location: min(bridge.selectedRange.location, ns.length - 1), length: 0))
        return Set(bible.matcher.matches(in: text, range: para).map(\.path))
    }

    /// The note being written in, on screen: the wheel scrolls its text there, not the board.
    private var editingRect: CGRect? {
        guard let editing, let n = board.node(editing) else { return nil }
        return camera.toScreen(board.rect(of: n))
    }

    /// The one map selected, on screen: the wheel and the pinch change its scale there, not the board's.
    private var selectedMapRect: CGRect? {
        guard selection.count == 1, let id = selection.first, let n = board.node(id), n.mussetKind == "pin" || n.mussetKind == "map" else { return nil }
        return camera.toScreen(board.rect(of: n))
    }

    // MARK: Clicks and keys

    private func click(_ id: String) {
        focused = true
        let double = NSApp.currentEvent?.clickCount == 2
        if tool == .connector {
            if let from = linking, from != id {
                change { $0.edges.append(.init(fromNode: from, toNode: id)) }
                linking = nil
                tool = .select
            } else {
                linking = id
            }
            return
        }
        guard let node = board.node(id) else { return }
        if double {
            selection = [id]
            if Self.writable(node) { editing = id } else if node.mussetKind != "ink" { open(node) }
            return
        }
        if editing != id { endEditing() }
        if NSEvent.modifierFlags.contains(.shift) {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
        } else {
            selection = [id]
        }
    }

    private func backgroundClick(at p: CGPoint) {
        focused = true
        endEditing()
        linking = nil
        if NSApp.currentEvent?.clickCount == 2 {
            // A note where one double-clicks, ready to write.
            let at = camera.toBoard(p)
            add(.init(type: .text, x: Int(at.x) - 120, y: Int(at.y) - 30, width: 240, height: 126, text: ""), snap: true) { editing = $0 }
        } else if let arrow = board.edge(at: camera.toBoard(p), within: 8 / max(camera.zoom, 0.1)) {
            // An arrow is picked where it runs between the cards.
            selection = []
            selectedEdge = arrow.id
        } else if !NSEvent.modifierFlags.contains(.shift) {
            selection = []
            selectedEdge = nil
        }
    }

    private var backgroundDrag: some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named(BoardSpace.screen))
            .onChanged { v in
                if motion.panStart == nil && motion.marqueeStart == nil {
                    endEditing()
                    if BoardEvents.spaceDown || NSEvent.pressedMouseButtons & 0b100 != 0 {
                        motion.panStart = camera.pan
                        NSCursor.closedHand.push()
                    } else {
                        motion.marqueeStart = v.startLocation
                        motion.marqueeBase = NSEvent.modifierFlags.contains(.shift) ? selection : []
                    }
                }
                if let start = motion.panStart {
                    camera.pan = CGSize(width: start.width + v.translation.width, height: start.height + v.translation.height)
                } else {
                    motion.marquee = CGRect(x: min(v.startLocation.x, v.location.x), y: min(v.startLocation.y, v.location.y),
                                            width: abs(v.location.x - v.startLocation.x), height: abs(v.location.y - v.startLocation.y))
                    if let box = motion.marquee { selection = motion.marqueeBase.union(board.ids(in: camera.toBoard(box))) }
                }
            }
            .onEnded { _ in
                if motion.panStart != nil { NSCursor.pop() }
                motion.panStart = nil
                motion.marqueeStart = nil
                motion.marquee = nil
            }
    }

    private func key(_ press: KeyPress) -> KeyPress.Result {
        guard editing == nil else {
            if press.key == .escape { endEditing(); return .handled }
            return .ignored
        }
        // A field on a card (a place's search, a caption) keeps its keys: the letters are tools only outside any text.
        if NSApp.keyWindow?.firstResponder is NSTextView { return .ignored }
        let cmd = press.modifiers.contains(.command)
        switch press.key {
        case .escape:
            if tool != .select { tool = .select } else { selection = []; selectedEdge = nil }
            linking = nil
            return .handled
        case .return where selection.count == 1:
            if let id = selection.first, let n = board.node(id), Self.writable(n) { editing = id }
            return .handled
        case .leftArrow, .rightArrow, .upArrow, .downArrow:
            guard !selection.isEmpty else { return .ignored }
            let step: CGFloat = press.modifiers.contains(.shift) ? CGFloat(JSONCanvas.snap * 2) : 1
            let d: (CGFloat, CGFloat) = switch press.key {
            case .leftArrow: (-step, 0)
            case .rightArrow: (step, 0)
            case .upArrow: (0, -step)
            default: (0, step)
            }
            let ids = board.carried(selection)
            change { $0.move(ids, by: d.0, d.1, snap: false) }
            return .handled
        default:
            break
        }
        // The tools by their letters, as in FigJam.
        guard cmd else {
            guard press.modifiers.subtracting(.shift).isEmpty, let t = BoardTool(key: press.characters) else { return .ignored }
            tool = t
            return .handled
        }
        switch press.characters {
        case "d":
            duplicate(selection)
            return .handled
        case "g":
            group(selection)
            return .handled
        case "=", "+":
            camera.zoom(to: camera.zoom * 1.25, around: CGPoint(x: size.width / 2, y: size.height / 2), animated: true)
            return .handled
        case "-":
            camera.zoom(to: camera.zoom / 1.25, around: CGPoint(x: size.width / 2, y: size.height / 2), animated: true)
            return .handled
        case "0":
            fit(animated: true)
            return .handled
        default:
            return .ignored
        }
    }

    private func endEditing() {
        guard let id = editing else { return }
        editing = nil
        // A note or a text left empty goes.
        if let n = board.node(id), n.type == .text, n.mussetKind == nil || n.mussetKind == "label",
           (n.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            change { $0.remove(id) }
            selection.remove(id)
        }
    }

    private func removeSelection() {
        if editing == nil, let arrow = selectedEdge {
            change { $0.edges.removeAll { $0.id == arrow } }
            selectedEdge = nil
            return
        }
        guard editing == nil, !selection.isEmpty else { return }
        let ids = selection
        change { b in for id in ids { b.remove(id) } }
        selection = []
    }

    private func duplicate(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        var copies: Set<String> = []
        change { copies = $0.duplicate(ids) }
        selection = copies
    }

    /// The selected cards in a container of their own, its name asked at once.
    private func group(_ ids: Set<String>) {
        var made: String?
        change { made = $0.group(ids) }
        guard let made else { return }
        selection = [made]
        editing = made
    }

    /// The whole board in view (or its start, when it is empty).
    private func fit(animated: Bool) {
        guard size.width > 0 else { return }
        let r = Self.room
        let avail = CGRect(x: r.leading, y: r.top, width: max(100, size.width - r.leading - r.trailing),
                           height: max(100, size.height - r.top - r.bottom))
        guard let b = board.bounds, b.width > 0, b.height > 0 else {
            camera.set(pan: CGSize(width: avail.minX, height: avail.minY), zoom: 1, animated: animated)
            return
        }
        let z = min(max(min(avail.width / b.width, avail.height / b.height), BoardCamera.minZoom), 1)
        // Centred across, from the top: a board reads downwards.
        camera.set(pan: CGSize(width: avail.midX - b.midX * z, height: avail.minY - b.minY * z), zoom: z, animated: animated)
    }

    // MARK: The chrome

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let draft = renaming {
                TextField(L("Name"), text: Binding(get: { draft }, set: { renaming = $0 }))
                    .textFieldStyle(.plain).font(.system(size: 28, design: .serif)).focused($namingBoard)
                    .frame(maxWidth: 520)
                    .onSubmit { rename() }
                    .onExitCommand { renaming = nil }
                    .onChange(of: namingBoard) { _, on in if !on { rename() } }
            } else {
                Text(title).font(.system(size: 28, design: .serif))
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { renaming = title; namingBoard = true }
                    .help(L("Double-click to rename"))
            }
            Text(tool.hint)
                .font(.ui(12)).foregroundStyle(.secondary).allowsHitTesting(false)
        }
        .padding(.leading, 40).padding(.top, 18).padding(.bottom, 24)
        .frame(maxWidth: .infinity, alignment: .leading)
        // The cards slide under the title, not over it.
        .background(LinearGradient(colors: [Ink.panel, Ink.panel.opacity(0.92), Ink.panel.opacity(0)], startPoint: .top, endPoint: .bottom).allowsHitTesting(false))
    }

    /// The name typed becomes the board's: what is drawn is written first, the file then moves.
    private func rename() {
        guard let name = renaming else { return }
        renaming = nil
        guard name.trimmingCharacters(in: .whitespaces) != title else { return }
        save(now: true)
        session.renameBoard(path, to: name)
    }

    // MARK: The tools

    private var toolbar: some View {
        VStack(spacing: 8) {
            options
            HStack(spacing: 2) {
                pick(.select); pick(.hand)
                bar
                pick(.marker); pick(.highlighter); pick(.eraser)
                bar
                pick(.sticky); pick(.text); pick(.shape, icon: BoardShape(rawValue: shapeKind)?.icon); pick(.connector); pick(.column)
                bar
                insert
                tool("text.viewfinder", L("Follows the text: the cards of the paragraph being written light up"), on: follows) { follows.toggle() }
            }
            .padding(4)
            .background(Capsule().fill(Color(nsColor: .textBackgroundColor)))
            .overlay(Capsule().strokeBorder(Ink.hairline))
            .shadow(color: .black.opacity(0.12), radius: 12, y: 3)
        }
        .fixedSize()
    }

    private var bar: some View { Divider().frame(height: 22).padding(.horizontal, 4) }

    private func pick(_ t: BoardTool, icon: String? = nil) -> some View {
        Button { tool = t; focused = true } label: {
            Image(systemName: icon ?? t.icon).font(.system(size: 14))
                .frame(width: 36, height: 36)
                .foregroundStyle(tool == t ? Ink.onAccent : Color.primary)
                .background(Circle().fill(tool == t ? Ink.accent : .clear))
                .contentShape(Circle())
        }
        .buttonStyle(.plain).help(t.label).accessibilityLabel(t.label)
        .accessibilityAddTraits(tool == t ? .isSelected : [])
    }

    /// The chosen tool's options, above the bar: the marker's colour and width, the note's colour, the shape.
    @ViewBuilder private var options: some View {
        let row: AnyView? = switch tool {
        case .marker, .highlighter:
            AnyView(HStack(spacing: 6) {
                swatch(nil, fill: BoardPalette.ink(nil), on: inkColor.isEmpty) { inkColor = "" }
                ForEach(BoardPalette.presets, id: \.self) { c in swatch(c, fill: BoardPalette.ink(c), on: inkColor == c) { inkColor = c } }
                bar
                ForEach([1.5, 3.0, 6.0], id: \.self) { w in
                    Button { inkWidth = w } label: {
                        Circle().fill(Color.primary).frame(width: 4 + w * 1.6, height: 4 + w * 1.6)
                            .frame(width: 26, height: 26)
                            .background(Circle().fill(inkWidth == w ? Ink.accent.opacity(0.18) : .clear))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain).accessibilityLabel(L("Width"))
                }
            })
        case .sticky:
            AnyView(HStack(spacing: 6) {
                ForEach(BoardPalette.presets, id: \.self) { c in swatch(c, fill: BoardPalette.paper(c), on: stickyColor == c) { stickyColor = c } }
            })
        case .shape:
            AnyView(HStack(spacing: 2) {
                ForEach(BoardShape.allCases, id: \.self) { k in
                    Button { shapeKind = k.rawValue } label: {
                        Image(systemName: k.icon).frame(width: 30, height: 26)
                            .background(RoundedRectangle(cornerRadius: Radius.row).fill(shapeKind == k.rawValue ? Ink.accent.opacity(0.18) : .clear))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).help(k.label).accessibilityLabel(k.label)
                }
            })
        default: nil
        }
        if let row {
            row.padding(.horizontal, 10).padding(.vertical, 6)
                .background(Capsule().fill(Color(nsColor: .textBackgroundColor)))
                .overlay(Capsule().strokeBorder(Ink.hairline))
                .shadow(color: .black.opacity(0.1), radius: 8, y: 2)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }

    private func swatch(_ c: String?, fill: Color, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Circle().fill(fill).frame(width: 18, height: 18)
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.15)))
                .padding(3)
                .overlay(Circle().strokeBorder(on ? Ink.accent : .clear, lineWidth: 2))
                .contentShape(Circle())
        }
        .buttonStyle(.plain).accessibilityLabel(c.map(BoardPalette.name) ?? L("Ink"))
    }

    /// What comes from elsewhere: files, pages, maps, the book, the Bible.
    private var insert: some View {
        Menu {
            Button(L("Image…")) { pick([.image]) }
            Button(L("PDF…")) { pick([.pdf]) }
            Button(L("Web page…")) { webAddress = ""; askingURL = true }
            Menu(L("Map")) {
                Button(L("A pin or an address")) {
                    add(.init(type: .text, x: 0, y: 0, width: 324, height: 333, text: L("Map"), musset: ["kind": "pin"]))
                }
                Button(L("All the places")) {
                    add(.init(type: .text, x: 0, y: 0, width: 324, height: 225, text: L("Map") + ": " + L("Places"), musset: ["kind": "map"]))
                }
                Divider()
                ForEach(bible.entries.filter { $0.kind == .place }) { e in
                    Button(e.title) { add(.init(type: .file, x: 0, y: 0, width: 297, height: 225, file: e.path, musset: ["kind": "map"])) }
                }
            }
            Button(L("Passage from the book")) { addPassage() }
                .disabled(bridge.selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Menu(L("Sheet")) {
                ForEach(bible.entries.filter { !$0.isFile && $0.kind != .draft && $0.kind != .cut }) { e in
                    Button(e.title) { add(.init(type: .file, x: 0, y: 0, width: 243, height: 90, file: e.path)) }
                }
            }
        } label: { Image(systemName: "plus").font(.system(size: 14)).frame(width: 36, height: 36) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help(L("Insert")).accessibilityLabel(L("Insert"))
    }

    // MARK: Drawing and placing

    private func toolDrag(_ v: DragGesture.Value) {
        focused = true
        switch tool {
        case .hand:
            if motion.panStart == nil { motion.panStart = camera.pan; NSCursor.closedHand.push() }
            if let start = motion.panStart {
                camera.pan = CGSize(width: start.width + v.translation.width, height: start.height + v.translation.height)
            }
        case .marker, .highlighter:
            let p = camera.toBoard(v.location)
            if let last = motion.stroke.last, hypot(p.x - last.x, p.y - last.y) < 1.2 / camera.zoom { return }
            motion.stroke.append(p)
        case .eraser:
            erase(at: camera.toBoard(v.location))
        default:
            motion.marquee = CGRect(x: min(v.startLocation.x, v.location.x), y: min(v.startLocation.y, v.location.y),
                                    width: abs(v.location.x - v.startLocation.x), height: abs(v.location.y - v.startLocation.y))
        }
    }

    private func toolEnd(_ v: DragGesture.Value) {
        switch tool {
        case .hand:
            if motion.panStart != nil { NSCursor.pop() }
            motion.panStart = nil
        case .marker, .highlighter:
            let points = motion.stroke
            motion.stroke = []
            let hl = tool == .highlighter
            if let n = BoardInk.make(points, width: hl ? inkWidth * 5 : inkWidth, color: inkColor.isEmpty ? nil : inkColor, highlighter: hl) {
                change { $0.nodes.append(n) }
            }
        case .eraser:
            erase(at: camera.toBoard(v.location))
        default:
            let box = motion.marquee
            motion.marquee = nil
            place(at: v.location, box: box)
        }
    }

    /// A sticky note, a text, a shape or a column, where one clicked, or the size one drew; then back to selecting.
    private func place(at point: CGPoint, box: CGRect?) {
        var n: JSONCanvas.Node
        switch tool {
        case .sticky: n = .init(type: .text, x: 0, y: 0, width: 216, height: 216, color: stickyColor, text: "")
        case .text: n = .init(type: .text, x: 0, y: 0, width: 288, height: 54, text: "", musset: ["kind": "label"])
        case .shape: n = .init(type: .text, x: 0, y: 0, width: 180, height: 126, color: "5", text: "", musset: ["kind": "shape", "shape": shapeKind])
        case .column: n = .init(type: .group, x: 0, y: 0, width: 279, height: 423, label: "")
        default: return
        }
        if let box, box.width > 12, box.height > 12 {
            let r = camera.toBoard(box)
            n.x = Int(r.minX); n.y = Int(r.minY); n.width = Int(r.width); n.height = Int(r.height)
        } else {
            let at = camera.toBoard(point)
            n.x = Int(at.x) - n.width / 2; n.y = Int(at.y) - n.height / 2
        }
        let g = JSONCanvas.snap
        n.x = Int((Double(n.x) / Double(g)).rounded()) * g; n.y = Int((Double(n.y) / Double(g)).rounded()) * g
        change { $0.nodes.append(n) }
        selection = [n.id]
        // After the gesture ends: going back to selecting takes away the layer that is running it.
        DispatchQueue.main.async {
            tool = .select
            editing = n.id
        }
    }

    private func erase(at p: CGPoint) {
        let hit = board.nodes.filter { $0.mussetKind == "ink" && BoardInk.touches($0, p, radius: 8 / camera.zoom) }.map(\.id)
        guard !hit.isEmpty else { return }
        change { b in for id in hit { b.remove(id) } }
        selection.subtract(hit)
    }

    /// Cards one writes in: notes, texts, shapes, columns' names.
    static func writable(_ n: JSONCanvas.Node) -> Bool {
        n.type == .group || (n.type == .text && (n.mussetKind == nil || n.mussetKind == "label" || n.mussetKind == "shape"))
    }

    private func tool(_ icon: String, _ label: String, on: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).frame(width: 36, height: 36)
                .background(on ? Ink.accent.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: Radius.control))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(label).accessibilityLabel(label)
    }

    @ViewBuilder private var linkedFrom: some View {
        if let entry = bible.entry(path: path) {
            let links = bible.backlinks(to: entry)
            if !links.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("Linked from")).font(.ui(11, .medium)).foregroundStyle(.secondary)
                    ForEach(links) { e in Button(e.title) { app.open(.sheet(e.path)) }.buttonStyle(.link).font(.ui(12)) }
                }
                .padding(12).frame(width: 220, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Radius.card).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: Radius.card).strokeBorder(Ink.hairline))
            }
        }
    }

    // MARK: Adding

    /// A card at a point of the view (a drop, a double-click), or in the middle of what is shown.
    private func add(_ node: JSONCanvas.Node, at point: CGPoint? = nil, snap: Bool = false, then: ((String) -> Void)? = nil) {
        var n = node
        if let point {
            let at = camera.toBoard(point)
            n.x = Int(at.x); n.y = Int(at.y)
        } else if !snap {
            // In the middle of the view, a little lower each time so cards don't pile up exactly.
            let mid = camera.toBoard(CGPoint(x: (size.width + Self.room.leading) / 2, y: (size.height + Self.room.top) / 2))
            let spread = (board.nodes.count % 5) * 2 * JSONCanvas.snap
            n.x = Int(mid.x) - n.width / 2 + spread; n.y = Int(mid.y) - n.height / 2 + spread
        }
        let g = JSONCanvas.snap
        n.x = Int((Double(n.x) / Double(g)).rounded()) * g; n.y = Int((Double(n.y) / Double(g)).rounded()) * g
        change { $0.nodes.append(n) }
        selection = [n.id]
        focused = true
        then?(n.id)
    }

    private func addPassage() {
        let quote = bridge.selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !quote.isEmpty, let id = session.selectedChapterID, let ch = session.manifest.chapters.first(where: { $0.id == id }) else { return }
        add(.init(type: .text, x: 0, y: 0, width: 270, height: 135, text: "> \(quote)\n\n@[\(ch.title)]",
                  musset: ["kind": "passage", "chapter": id, "quote": quote]))
    }

    private func pick(_ types: [UTType]) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { addFile(url, at: nil) }
    }

    private func addFile(_ url: URL, at point: CGPoint?) {
        guard let path = try? bible.bring(url) else { return }
        let image = UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
        add(.init(type: .file, x: 0, y: 0, width: image ? 279 : 261, height: image ? 198 : 144, file: path), at: point)
        session.pendingCommit = true
    }

    private func addWeb(_ address: String, at point: CGPoint? = nil) {
        guard let url = URL(string: address.trimmingCharacters(in: .whitespaces)), url.scheme?.hasPrefix("http") == true else { return }
        working = L("Keeping the page…")
        Task {
            defer { working = nil }
            if let entry = try? await BibleImporter.importWeb(url, session: session) {
                add(.init(type: .file, x: 0, y: 0, width: 279, height: 153, file: entry.path, musset: ["kind": "web", "url": url.absoluteString]), at: point)
            } else {
                add(.init(type: .link, x: 0, y: 0, width: 279, height: 90, url: url.absoluteString), at: point)
            }
        }
    }

    /// Files and links from elsewhere; a sheet (or a sheet's tab) from Musset becomes its card.
    private func receive(_ providers: [NSItemProvider], at location: CGPoint) -> Bool {
        if let wire = PaneDrops.dragged {
            let sheet: String? = switch wire {
            case .sheet(let p): p
            case .tab(let pane, let index):
                session.owner(ofPane: pane)?.panes.first { $0.id == pane }?.tabs[safe: index].flatMap { if case .sheet(let p) = $0 { p } else { nil } }
            default: nil
            }
            guard let sheet, sheet != path else { return false }
            add(.init(type: .file, x: 0, y: 0, width: 243, height: 90, file: sheet), at: CGPoint(x: location.x - 40, y: location.y - 20))
            return true
        }
        for p in providers where p.canLoadObject(ofClass: URL.self) {
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in
                    if url.isFileURL { addFile(url, at: location) } else { addWeb(url.absoluteString, at: location) }
                }
            }
        }
        return true
    }

    // MARK: Opening and saving

    private func open(_ node: JSONCanvas.Node) {
        if node.mussetKind == "passage", let ch = node.musset?["chapter"] {
            session.open(.chapter(ch), in: .nextPane)
            session.pendingSelection = node.musset?["quote"].flatMap { ReadingCheck.locate($0, in: session.text) }
        } else if let file = node.file, bible.entry(path: file) != nil {
            // Beside the board, so it stays in view.
            session.open(.sheet(file), in: .nextPane)
        } else if let u = node.url ?? node.musset?["url"], let url = URL(string: u) {
            NSWorkspace.shared.open(url)
        }
    }

    private func change(_ edit: (inout JSONCanvas) -> Void) {
        edit(&board)
        save()
    }

    private func save(now: Bool = false) {
        saveTask?.cancel()
        let snapshot = board, url = fileURL
        let write = { [session] in
            // A board moved or put in the Trash while open is not written back where it was.
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            try? snapshot.write(url)
            session.pendingCommit = true
        }
        if now { write(); return }
        saveTask = Task { try? await Task.sleep(for: .milliseconds(500)); if !Task.isCancelled { write() } }
    }
}

enum BoardSpace { static let screen = "board.screen" }

/// The board's tools, as in FigJam, each with its letter.
enum BoardTool: String, CaseIterable {
    case select, hand, marker, highlighter, eraser, sticky, text, shape, connector, column

    init?(key: String) {
        switch key {
        case "v": self = .select
        case "h": self = .hand
        case "m": self = .marker
        case "M": self = .highlighter
        case "e": self = .eraser
        case "s": self = .sticky
        case "S": self = .column
        case "t": self = .text
        case "r": self = .shape
        case "x": self = .connector
        default: return nil
        }
    }

    /// The board takes the pointer for itself: the cards don't.
    var takesTheBoard: Bool { self != .select && self != .connector }
    /// Placed with a click, or drawn to a size.
    var places: Bool { [.sticky, .text, .shape, .column].contains(self) }

    var icon: String {
        switch self {
        case .select: "cursorarrow"
        case .hand: "hand.raised"
        case .marker: "pencil.tip"
        case .highlighter: "highlighter"
        case .eraser: "eraser"
        case .sticky: "note.text"
        case .text: "textformat"
        case .shape: "square"
        case .connector: "arrow.up.right"
        case .column: "rectangle.split.2x1"
        }
    }

    var label: String {
        switch self {
        case .select: L("Select (V)")
        case .hand: L("Hand (H, or hold Space)")
        case .marker: L("Marker (M)")
        case .highlighter: L("Highlighter (⇧M)")
        case .eraser: L("Eraser (E)")
        case .sticky: L("Sticky note (S)")
        case .text: L("Text (T)")
        case .shape: L("Shape (R)")
        case .connector: L("Arrow (X)")
        case .column: L("Column (⇧S)")
        }
    }

    var hint: String {
        switch self {
        case .select: L("Drop anything here: a file, a link, a place.")
        case .hand: L("Drag to move around the board.")
        case .marker, .highlighter: L("Draw on the board. Esc to stop.")
        case .eraser: L("Go over a stroke to rub it out.")
        case .sticky, .text, .shape, .column: L("Click to place it, or drag to give it a size.")
        case .connector: L("Click a card, then another, to join them.")
        }
    }

    var cursor: NSCursor {
        switch self {
        case .hand: .openHand
        case .select, .connector: .arrow
        default: .crosshair
        }
    }
}

/// The shapes of the shape tool.
enum BoardShape: String, CaseIterable {
    case rect, ellipse, diamond

    var icon: String {
        switch self {
        case .rect: "square"
        case .ellipse: "circle"
        case .diamond: "diamond"
        }
    }

    var label: String {
        switch self {
        case .rect: L("Rectangle")
        case .ellipse: L("Ellipse")
        case .diamond: L("Diamond")
        }
    }

    var shape: AnyShape {
        switch self {
        case .rect: AnyShape(RoundedRectangle(cornerRadius: Radius.control))
        case .ellipse: AnyShape(Ellipse())
        case .diamond: AnyShape(Diamond())
        }
    }
}

struct Diamond: Shape {
    func path(in r: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: r.midX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.midY))
            p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX, y: r.midY))
            p.closeSubpath()
        }
    }
}

/// A stroke, smoothed: through the middles of its segments. Scaled from the size it was drawn at to its card's.
struct BoardInkShape: Shape {
    let points: [CGPoint]
    /// The size the points were drawn in; nil for points already on the board.
    var natural: CGSize? = nil

    func path(in rect: CGRect) -> Path {
        let sx = natural.map { rect.width / max($0.width, 1) } ?? 1, sy = natural.map { rect.height / max($0.height, 1) } ?? 1
        let pts = points.map { CGPoint(x: rect.minX * (natural == nil ? 0 : 1) + $0.x * sx, y: rect.minY * (natural == nil ? 0 : 1) + $0.y * sy) }
        var p = Path()
        guard let first = pts.first else { return p }
        p.move(to: first)
        guard pts.count > 2 else {
            p.addLine(to: pts.count == 2 ? pts[1] : CGPoint(x: first.x + 0.01, y: first.y))
            return p
        }
        for i in 1..<pts.count - 1 {
            let mid = CGPoint(x: (pts[i].x + pts[i + 1].x) / 2, y: (pts[i].y + pts[i + 1].y) / 2)
            p.addQuadCurve(to: mid, control: pts[i])
        }
        p.addLine(to: pts[pts.count - 1])
        return p
    }
}

/// The board under a tool that isn't selecting: it takes the pointer, draws, places, pans.
private struct BoardToolLayer: View {
    let tool: BoardTool
    let changed: (DragGesture.Value) -> Void
    let ended: (DragGesture.Value) -> Void

    var body: some View {
        Color.white.opacity(0.001)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named(BoardSpace.screen)).onChanged(changed).onEnded(ended))
            .onContinuousHover { phase in
                if case .active = phase { tool.cursor.set() } else { NSCursor.arrow.set() }
            }
    }
}

/// The stroke being drawn.
private struct InkPreview: View {
    let motion: BoardMotion
    let color: Color
    let width: CGFloat
    let highlighter: Bool

    var body: some View {
        if !motion.stroke.isEmpty {
            BoardInkShape(points: motion.stroke)
                .stroke(color.opacity(highlighter ? 0.4 : 1), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
                .frame(width: 1, height: 1, alignment: .topLeading)
                .allowsHitTesting(false)
        }
    }
}

/// Around several cards selected, one frame.
private struct SelectionBox: View {
    let board: JSONCanvas
    let selection: Set<String>
    let motion: BoardMotion

    var body: some View {
        if selection.count > 1,
           let r = board.nodes.filter({ selection.contains($0.id) }).map(board.rect(of:)).reduce(nil, { $0?.union($1) ?? $1 }) {
            let d = motion.ids.isEmpty ? .zero : motion.delta
            Rectangle().strokeBorder(Ink.accent.opacity(0.8), style: StrokeStyle(lineWidth: 1, dash: [5, 3]))
                .frame(width: r.width + 16, height: r.height + 16)
                .offset(x: r.minX - 8 + d.width, y: r.minY - 8 + d.height)
                .allowsHitTesting(false)
        }
    }
}

// MARK: The camera and what moves

/// Where the board is looked at from: its offset and its zoom. Its own object, so panning and zooming redraw only
/// the background and the cards' transform, not the cards.
@MainActor
@Observable
final class BoardCamera {
    static let minZoom: CGFloat = 0.2, maxZoom: CGFloat = 3
    var pan = CGSize(width: 92, height: 96)
    var zoom: CGFloat = 1
    /// Each board's view while Musset runs, so going back to its tab finds it as it was left.
    static var kept: [String: (pan: CGSize, zoom: CGFloat)] = [:]

    func toBoard(_ p: CGPoint) -> CGPoint { CGPoint(x: (p.x - pan.width) / zoom, y: (p.y - pan.height) / zoom) }
    func toBoard(_ r: CGRect) -> CGRect {
        let a = toBoard(r.origin)
        return CGRect(x: a.x, y: a.y, width: r.width / zoom, height: r.height / zoom)
    }
    func toScreen(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX * zoom + pan.width, y: r.minY * zoom + pan.height, width: r.width * zoom, height: r.height * zoom)
    }

    /// Zooms keeping the point under the pointer where it is.
    func zoom(to z: CGFloat, around p: CGPoint, animated: Bool = false) {
        let nz = min(max(z, Self.minZoom), Self.maxZoom)
        let pan = CGSize(width: p.x - (p.x - self.pan.width) * nz / zoom, height: p.y - (p.y - self.pan.height) * nz / zoom)
        set(pan: pan, zoom: nz, animated: animated)
    }

    func set(pan: CGSize, zoom: CGFloat, animated: Bool) {
        if animated {
            withAnimation(.spring(duration: 0.3)) { self.pan = pan; self.zoom = zoom }
        } else {
            self.pan = pan; self.zoom = zoom
        }
    }
}

/// What is being moved, resized, linked or boxed right now: only the cards concerned read it.
@MainActor
@Observable
final class BoardMotion {
    /// The cards being dragged (with a column, its cards), and how far.
    var ids: Set<String> = []
    var delta: CGSize = .zero
    var resizing: String?
    /// The card being resized, where it is now.
    var frame: CGRect = .zero
    /// The stroke being drawn, on the board.
    var stroke: [CGPoint] = []
    /// An arrow being drawn from a card, to a point of the board.
    var linkFrom: String?
    var linkFromSide: BoardSide = .right
    var linkTo: CGPoint = .zero
    /// The card and magnet the arrow being drawn has snapped to.
    var linkTarget: (id: String, side: BoardSide)?
    /// The selection box, on screen.
    var marquee: CGRect?
    @ObservationIgnored var marqueeStart: CGPoint?
    @ObservationIgnored var marqueeBase: Set<String> = []
    @ObservationIgnored var panStart: CGSize?
}

/// What a card can ask of its board.
struct BoardActions {
    let click: (String) -> Void
    let beginMove: (String) -> Void
    let endMove: (CGSize) -> Void
    let endResize: (String, CGRect) -> Void
    let endLink: () -> Void
    /// The card under a point of the board, and its nearest magnet, for an arrow from another card.
    let magnet: (CGPoint, String) -> (id: String, side: BoardSide, rect: CGRect)?
    let text: (String, String) -> Void
    let musset: (String, [String: String]) -> Void
    let endEditing: () -> Void
    let open: (JSONCanvas.Node) -> Void
    let color: (String, String?) -> Void
    let duplicate: (String) -> Void
    /// The selection this card is part of, put in a container.
    let group: (String) -> Void
    let severalSelected: (String) -> Bool
    let toFront: (String) -> Void
    let unlink: (String) -> Void
    let remove: (String) -> Void
    let hasEdges: (String) -> Bool
    /// Changes a card in place (a map shown for another place).
    let edit: (String, (inout JSONCanvas.Node) -> Void) -> Void
}

/// The cards, moved and scaled by the camera. Only this view reads the camera: the cards inside are built once.
private struct BoardViewport<Content: View>: View {
    let camera: BoardCamera
    @ViewBuilder let content: Content

    var body: some View {
        Color.clear.overlay(alignment: .topLeading) {
            content
                .scaleEffect(camera.zoom, anchor: .topLeading)
                .offset(camera.pan)
        }
    }
}

/// The board's ground: a faint grid of dots that moves and scales with it.
private struct BoardBackground: View {
    let camera: BoardCamera

    var body: some View {
        DotGround(zoom: camera.zoom, pan: camera.pan)
    }
}

/// The cork-board ground: the panel's colour under a faint grid of dots. A board moves and scales it with its
/// camera; a chapter's scene cards lie on it as it is.
struct DotGround: View {
    var zoom: CGFloat = 1
    var pan: CGSize = .zero

    var body: some View {
        Canvas { ctx, size in
            var spacing = 18 * zoom
            while spacing < 9 { spacing *= 2 }
            let dot = max(1, 1.6 * min(zoom, 1.4))
            let ox = pan.width.truncatingRemainder(dividingBy: spacing), oy = pan.height.truncatingRemainder(dividingBy: spacing)
            var dots = Path()
            var y = oy - spacing
            while y < size.height {
                var x = ox - spacing
                while x < size.width {
                    dots.addEllipse(in: CGRect(x: x, y: y, width: dot, height: dot))
                    x += spacing
                }
                y += spacing
            }
            ctx.fill(dots, with: .color(.primary.opacity(0.13)))
        }
        .background(Ink.panel)
    }
}

/// The selection box.
private struct MarqueeView: View {
    let motion: BoardMotion
    /// The size of a card being placed, rather than a selection.
    var dashed = false

    var body: some View {
        if let r = motion.marquee {
            Rectangle().fill(Ink.accent.opacity(dashed ? 0.04 : 0.08))
                .overlay(Rectangle().strokeBorder(Ink.accent.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: dashed ? [5, 3] : [])))
                .frame(width: r.width, height: r.height)
                .offset(x: r.minX, y: r.minY)
                .allowsHitTesting(false)
        }
    }
}

/// − 100 % + and « fit », bottom right.
private struct BoardZoomControls: View {
    let camera: BoardCamera
    /// The middle of the board on screen: the buttons zoom around it.
    let center: CGPoint
    let fit: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            button("minus", L("Zoom out")) { camera.zoom(to: camera.zoom / 1.25, around: center, animated: true) }
            Button { camera.zoom(to: 1, around: center, animated: true) } label: {
                Text("\(Int((camera.zoom * 100).rounded())) %").font(.ui(11).monospacedDigit()).frame(width: 52, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain).help(L("Actual size"))
            button("plus", L("Zoom in")) { camera.zoom(to: camera.zoom * 1.25, around: center, animated: true) }
            Divider().frame(height: 16)
            button("arrow.up.left.and.down.right.magnifyingglass", L("Show the whole board (⌘0)"), action: fit)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
        .background(Capsule().fill(Color(nsColor: .textBackgroundColor)))
        .overlay(Capsule().strokeBorder(Ink.hairline))
        .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
    }

    private func button(_ icon: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).font(.ui(11)).frame(width: 30, height: 28).contentShape(Rectangle()) }
            .buttonStyle(.plain).help(label).accessibilityLabel(label)
    }
}

/// The trackpad and the wheel over the board: two fingers pan, a pinch or ⌘ and the wheel zoom around the pointer.
/// Space held over it pans with a drag. Events over the note being written are left to it.
private struct BoardEvents: NSViewRepresentable {
    let camera: BoardCamera
    let passesThrough: (CGPoint) -> Bool
    /// Space is held over the board, outside any text.
    @MainActor static var spaceDown = false

    func makeNSView(context: Context) -> Catcher { Catcher() }

    func updateNSView(_ view: Catcher, context: Context) {
        view.camera = camera
        view.passesThrough = passesThrough
    }

    final class Catcher: NSView {
        var camera: BoardCamera?
        var passesThrough: (CGPoint) -> Bool = { _ in false }
        private var monitor: Any?
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify, .keyDown, .keyUp]) { [weak self] e in
                MainActor.assumeIsolated { self?.handle(e) ?? e }
            }
        }

        private func handle(_ e: NSEvent) -> NSEvent? {
            guard let window, e.window === window, let camera, !isHiddenOrHasHiddenAncestor else { return e }
            let p = convert(e.locationInWindow, from: nil)
            switch e.type {
            case .keyDown, .keyUp:
                // Space over the board, outside any text: the hand that pans.
                guard e.keyCode == 49, !(window.firstResponder is NSTextView) else { return e }
                let inside = bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
                guard inside || BoardEvents.spaceDown else { return e }
                let down = e.type == .keyDown
                if down != BoardEvents.spaceDown {
                    BoardEvents.spaceDown = down
                    if down { NSCursor.openHand.push() } else { NSCursor.pop() }
                }
                return nil
            case .scrollWheel:
                guard bounds.contains(p), !passesThrough(p) else { return e }
                if e.modifierFlags.contains(.command) {
                    let dy = e.hasPreciseScrollingDeltas ? e.scrollingDeltaY : e.scrollingDeltaY * 8
                    camera.zoom(to: camera.zoom * exp(dy * 0.01), around: p)
                } else {
                    let k: CGFloat = e.hasPreciseScrollingDeltas ? 1 : 10
                    camera.pan = CGSize(width: camera.pan.width + e.scrollingDeltaX * k, height: camera.pan.height + e.scrollingDeltaY * k)
                }
                return nil
            case .magnify:
                guard bounds.contains(p), !passesThrough(p) else { return e }
                camera.zoom(to: camera.zoom * (1 + e.magnification), around: p)
                return nil
            default:
                return e
            }
        }

        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}

// MARK: A card on the board

/// One card in place: where it is, its selection, its handles, its gestures. Reads what moves only when it moves.
private struct BoardItem: View {
    let node: JSONCanvas.Node
    let session: BookSession
    let motion: BoardMotion
    let camera: BoardCamera
    /// The arrow tool: a drag from the card draws an arrow instead of moving it.
    let connecting: Bool
    let selected: Bool
    let lit: Bool
    let editing: Bool
    /// The only card selected: it shows its handles.
    let handles: Bool
    let actions: BoardActions
    @State private var hovered = false
    @State private var dragKind: DragKind?
    private enum DragKind { case move, link }

    /// Drawn straight on the board, without a card around it: a stroke, a text.
    private var bare: Bool { node.mussetKind == "ink" || node.mussetKind == "label" }
    /// Its inside takes the pointer (a map): it moves by its grip.
    private var interactive: Bool { node.mussetKind == "pin" || node.mussetKind == "map" }

    var body: some View {
        let moving = motion.ids.contains(node.id)
        let d = moving ? motion.delta : .zero
        let r = motion.resizing == node.id ? motion.frame
            : CGRect(x: CGFloat(node.x) + d.width, y: CGFloat(node.y) + d.height, width: CGFloat(node.width), height: CGFloat(node.height))
        BoardCard(node: node, session: session, editing: editing, actions: actions)
            .frame(width: r.width, height: r.height, alignment: .topLeading)
            .contentShape(hitShape)
            .overlay { selectionMark }
            .shadow(color: .black.opacity(bare ? 0 : (moving ? 0.22 : (hovered ? 0.1 : 0.05))), radius: moving ? 16 : (hovered ? 6 : 2), y: moving ? 8 : 1)
            .shadow(color: lit ? Ink.accent.opacity(0.4) : .clear, radius: lit ? 12 : 0)
            .animation(.easeOut(duration: 0.15), value: moving)
            .animation(.easeOut(duration: 0.25), value: lit)
            .overlay { if handles && !editing { grips(r) } }
            .overlay { if (handles || (connecting && hovered) || motion.linkFrom == node.id) && !editing && node.mussetKind != "ink" { magnets } }
            .overlay(alignment: .top) { if interactive && (hovered || selected) { grip } }
            .onHover { hovered = $0 }
            .offset(x: r.minX, y: r.minY)
            .zIndex(moving ? 2 : (selected ? 1 : 0))
            .onTapGesture { actions.click(node.id) }
            .gesture(pointer, including: editing || (interactive && !connecting) ? .subviews : .all)
            .contextMenu { menu }
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// A stroke is picked by its line, not its box: what lies under it stays in reach.
    private var hitShape: AnyShape {
        guard node.mussetKind == "ink" else { return AnyShape(Rectangle()) }
        let w = BoardInk.width(node)
        return AnyShape(BoardInkShape(points: BoardInk.points(node), natural: BoardInk.natural(node))
            .stroke(style: StrokeStyle(lineWidth: max(w, 12), lineCap: .round, lineJoin: .round)))
    }

    @ViewBuilder private var selectionMark: some View {
        if bare {
            Rectangle().strokeBorder(selected ? Ink.accent : .clear, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])).padding(-4)
        } else {
            RoundedRectangle(cornerRadius: Radius.card).strokeBorder(selected || lit ? Ink.accent : .clear, lineWidth: 2).padding(-1)
        }
    }

    /// What a drag on the card does, decided when it starts (moving it, or with the arrow tool drawing an arrow), so
    /// the gesture stays the same one whatever changes while it runs.
    private var pointer: some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named(BoardSpace.screen))
            .onChanged { v in
                if dragKind == nil { dragKind = connecting ? .link : .move }
                if dragKind == .link { linkChanged(v, side: nil) } else { moveChanged(v) }
            }
            .onEnded { v in
                let kind = dragKind
                dragKind = nil
                if kind == .link { actions.endLink() } else { moveEnded(v) }
            }
    }

    private func moveChanged(_ v: DragGesture.Value) {
        if !motion.ids.contains(node.id) { actions.beginMove(node.id) }
        motion.delta = CGSize(width: v.translation.width / camera.zoom, height: v.translation.height / camera.zoom)
    }

    private func moveEnded(_ v: DragGesture.Value) {
        guard motion.ids.contains(node.id) else { return }
        actions.endMove(CGSize(width: v.translation.width / camera.zoom, height: v.translation.height / camera.zoom))
    }

    private var move: some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .onChanged { v in
                if !motion.ids.contains(node.id) { actions.beginMove(node.id) }
                motion.delta = CGSize(width: v.translation.width / camera.zoom, height: v.translation.height / camera.zoom)
            }
            .onEnded { v in
                actions.endMove(CGSize(width: v.translation.width / camera.zoom, height: v.translation.height / camera.zoom))
            }
    }

    /// The eight handles: corners and sides. ⇧ keeps the proportions; images keep theirs anyway.
    private func grips(_ r: CGRect) -> some View {
        ZStack {
            ForEach(BoardGrip.allCases, id: \.self) { g in
                if g.corner || (g.ux == 0 ? r.width > 80 : r.height > 60) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color(nsColor: .textBackgroundColor))
                        .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Ink.accent, lineWidth: 1.5))
                        .frame(width: 9, height: 9)
                        .contentShape(Rectangle().inset(by: -5))
                        .offset(x: g.ux * (bare ? 8.5 : 4.5), y: g.uy * (bare ? 8.5 : 4.5))
                        .onHover { inside in if inside { g.cursor.push() } else { NSCursor.pop() } }
                        .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { v in
                                let start = CGRect(x: node.x, y: node.y, width: node.width, height: node.height)
                                let keep = NSEvent.modifierFlags.contains(.shift) || node.mussetKind == "ink" || isImage
                                motion.frame = g.resized(start, by: CGSize(width: v.translation.width / camera.zoom, height: v.translation.height / camera.zoom),
                                                         minimum: Self.minimum(node), keepRatio: keep)
                                motion.resizing = node.id
                            }
                            .onEnded { _ in actions.endResize(node.id, motion.frame) })
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: g.alignment)
                        .accessibilityLabel(L("Resize"))
                }
            }
        }
    }

    private var isImage: Bool {
        guard node.type == .file, let f = node.file else { return false }
        return UTType(filenameExtension: (f as NSString).pathExtension)?.conforms(to: .image) == true
    }

    /// The four magnets, just outside the sides: a drag from one draws an arrow from that side.
    private var magnets: some View {
        ZStack {
            ForEach(BoardSide.allCases, id: \.self) { side in
                Circle().fill(Ink.accent)
                    .overlay(Circle().strokeBorder(Color(nsColor: .textBackgroundColor), lineWidth: 2))
                    .frame(width: 12, height: 12)
                    .offset(x: side.normal.dx * 20, y: side.normal.dy * 20)
                    .contentShape(Circle().inset(by: -6))
                    .onHover { inside in if inside { NSCursor.crosshair.push() } else { NSCursor.pop() } }
                    .gesture(link(from: side))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: side.alignment)
                    .help(L("Drag to another card to join them"))
                    .accessibilityLabel(L("Arrow"))
            }
        }
    }

    /// Draws an arrow from a magnet (or, with the arrow tool, the one nearest where the drag starts); it snaps to the
    /// nearest magnet of the card it reaches.
    private func link(from side: BoardSide?) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named(BoardSpace.screen))
            .onChanged { v in linkChanged(v, side: side) }
            .onEnded { _ in actions.endLink() }
    }

    private func linkChanged(_ v: DragGesture.Value, side: BoardSide?) {
        let me = CGRect(x: node.x, y: node.y, width: node.width, height: node.height)
        if motion.linkFrom != node.id {
            motion.linkFrom = node.id
            motion.linkFromSide = side ?? BoardSide.nearest(me, to: camera.toBoard(v.startLocation))
        }
        let p = camera.toBoard(v.location)
        if let m = actions.magnet(p, node.id) {
            motion.linkTarget = (m.id, m.side)
            motion.linkTo = m.side.anchor(m.rect)
        } else {
            motion.linkTarget = nil
            motion.linkTo = p
        }
    }

    /// What moves a card whose inside takes the pointer.
    private var grip: some View {
        Capsule().fill(Color(nsColor: .textBackgroundColor))
            .overlay(Capsule().strokeBorder(Ink.hairline))
            .overlay(Image(systemName: "line.3.horizontal").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary))
            .frame(width: 40, height: 14)
            .offset(y: -18)
            .contentShape(Capsule().inset(by: -4))
            .onHover { inside in if inside { NSCursor.openHand.push() } else { NSCursor.pop() } }
            .gesture(move)
            .help(L("Move"))
            .accessibilityLabel(L("Move"))
    }

    static func minimum(_ node: JSONCanvas.Node) -> CGSize {
        switch node.type {
        case .group: CGSize(width: 160, height: 120)
        case .file where node.mussetKind == "map": CGSize(width: 200, height: 160)
        default:
            switch node.mussetKind {
            case "pin": CGSize(width: 240, height: 240)
            case "ink": CGSize(width: 8, height: 8)
            case "label", "shape": CGSize(width: 40, height: 30)
            default: CGSize(width: 120, height: 54)
            }
        }
    }

    @ViewBuilder private var menu: some View {
        if node.type == .file || node.type == .link || node.mussetKind == "passage" { Button(L("Open")) { actions.open(node) } }
        if node.mussetKind == "map" || node.mussetKind == "pin" {
            Menu(L("Change the place")) { MapPlaceMenu.items(session: session, node: node, actions: actions) }
        }
        if node.type == .group || node.type == .text && [nil, "shape", "ink", "label"].contains(node.mussetKind) {
            Menu(L("Colour")) {
                Button(L("None")) { actions.color(node.id, nil) }
                ForEach(BoardPalette.presets, id: \.self) { c in
                    Button(BoardPalette.name(c)) { actions.color(node.id, c) }
                }
            }
        }
        Button(L("Duplicate")) { actions.duplicate(node.id) }
        if actions.severalSelected(node.id) { Button(L("Group")) { actions.group(node.id) } }
        Button(L("Bring to Front")) { actions.toFront(node.id) }
        if actions.hasEdges(node.id) { Button(L("Remove Its Arrows")) { actions.unlink(node.id) } }
        Divider()
        Button(L("Remove from the board"), role: .destructive) { actions.remove(node.id) }
    }
}

extension BoardSide {
    var alignment: Alignment {
        switch self {
        case .top: .top
        case .right: .trailing
        case .bottom: .bottom
        case .left: .leading
        }
    }
}

/// A resize handle: a corner or the middle of a side.
enum BoardGrip: CaseIterable {
    case topLeading, top, topTrailing, trailing, bottomTrailing, bottom, bottomLeading, leading

    /// Which way it pulls: -1 the left (or top) side, 1 the right (or bottom), 0 neither.
    var ux: CGFloat { [.topLeading, .leading, .bottomLeading].contains(self) ? -1 : ([.topTrailing, .trailing, .bottomTrailing].contains(self) ? 1 : 0) }
    var uy: CGFloat { [.topLeading, .top, .topTrailing].contains(self) ? -1 : ([.bottomLeading, .bottom, .bottomTrailing].contains(self) ? 1 : 0) }
    var corner: Bool { ux != 0 && uy != 0 }

    var alignment: Alignment {
        switch self {
        case .topLeading: .topLeading
        case .top: .top
        case .topTrailing: .topTrailing
        case .trailing: .trailing
        case .bottomTrailing: .bottomTrailing
        case .bottom: .bottom
        case .bottomLeading: .bottomLeading
        case .leading: .leading
        }
    }

    var cursor: NSCursor {
        if ux == 0 { return .resizeUpDown }
        if uy == 0 { return .resizeLeftRight }
        return .crosshair
    }

    /// The card's frame with this handle pulled; the opposite side stays where it is.
    func resized(_ r: CGRect, by t: CGSize, minimum: CGSize, keepRatio: Bool) -> CGRect {
        var x0 = r.minX, x1 = r.maxX, y0 = r.minY, y1 = r.maxY
        if ux < 0 { x0 = min(x0 + t.width, x1 - minimum.width) }
        if ux > 0 { x1 = max(x1 + t.width, x0 + minimum.width) }
        if uy < 0 { y0 = min(y0 + t.height, y1 - minimum.height) }
        if uy > 0 { y1 = max(y1 + t.height, y0 + minimum.height) }
        if keepRatio, corner, r.height > 0 {
            let h = (x1 - x0) * r.height / r.width
            if uy < 0 { y0 = y1 - h } else { y1 = y0 + h }
        }
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
}

/// Note and column colours: JSON Canvas's six, each with a light and a dark version, the text readable on both.
enum BoardPalette {
    static let presets = ["1", "2", "3", "4", "5", "6"]

    static func name(_ c: String) -> String {
        switch c {
        case "1": L("Red")
        case "2": L("Orange")
        case "3": L("Yellow")
        case "4": L("Green")
        case "5": L("Blue")
        default: L("Purple")
        }
    }

    /// A stroke's ink: the page's ink by default, else the colour itself, strong.
    static func ink(_ c: String?) -> Color {
        switch c {
        case "1"?: Color(nsColor: .systemRed)
        case "2"?: Color(nsColor: .systemOrange)
        case "3"?: Color(nsColor: .systemYellow)
        case "4"?: Color(nsColor: .systemGreen)
        case "5"?: Color(nsColor: .systemBlue)
        case "6"?: Color(nsColor: .systemPurple)
        default: c.flatMap(hexColor) ?? .primary
        }
    }

    /// A note's paper: cream by default.
    static func paper(_ c: String?) -> Color {
        let (light, dark): ((Double, Double, Double), (Double, Double, Double)) = switch c {
        case "1"?: ((0.99, 0.89, 0.88), (0.34, 0.20, 0.20))
        case "2"?: ((1.00, 0.91, 0.82), (0.35, 0.25, 0.16))
        case "3"?: ((1.00, 0.95, 0.74), (0.32, 0.29, 0.14))
        case "4"?: ((0.88, 0.96, 0.88), (0.17, 0.28, 0.20))
        case "5"?: ((0.87, 0.94, 0.99), (0.15, 0.24, 0.31))
        case "6"?: ((0.93, 0.89, 0.99), (0.25, 0.20, 0.34))
        default: ((0.99, 0.97, 0.89), (0.24, 0.23, 0.19))
        }
        if let c, c.hasPrefix("#"), let hex = hexColor(c) { return hex.opacity(0.25) }
        return dynamic(light, dark)
    }

    /// A column's tint, faint.
    static func tint(_ c: String?) -> Color {
        guard let c else { return Color.primary.opacity(0.035) }
        return paper(c).opacity(0.6)
    }

    static func dynamic(_ light: (Double, Double, Double), _ dark: (Double, Double, Double)) -> Color {
        Color(nsColor: NSColor(name: nil) { a in
            let v = a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: v.0, green: v.1, blue: v.2, alpha: 1)
        })
    }

    private static func hexColor(_ s: String) -> Color? {
        let h = s.dropFirst()
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
        return Color(red: Double((v >> 16) & 0xff) / 255, green: Double((v >> 8) & 0xff) / 255, blue: Double(v & 0xff) / 255)
    }
}

/// One card, by what it holds.
private struct BoardCard: View {
    let node: JSONCanvas.Node
    let session: BookSession
    let editing: Bool
    let actions: BoardActions
    @State private var draft = ""
    @FocusState private var typing: Bool

    var body: some View {
        Group {
            switch node.type {
            case .group:
                VStack(alignment: .leading) {
                    if editing {
                        TextField(L("Column"), text: $draft).textFieldStyle(.plain).font(.ui(13, .semibold)).focused($typing)
                            .onSubmit { actions.endEditing() }
                    } else {
                        Text(node.label?.isEmpty == false ? node.label! : L("Column")).font(.ui(13, .semibold)).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(RoundedRectangle(cornerRadius: 12).fill(BoardPalette.tint(node.color)))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Ink.hairline))
            case .text where node.mussetKind == "map":
                MapCard(session: session, node: node, actions: actions)
            case .text where node.mussetKind == "pin":
                // A pin of its own, found by an address or moved by a click; kept in the card's « musset » keys.
                VStack(alignment: .leading, spacing: 4) {
                    PlaceMapSection(meta: Binding(get: { node.musset ?? [:] }, set: { actions.musset(node.id, $0) }),
                                    title: node.musset?["address"] ?? L("Map"), height: CGFloat(node.height) - 130, save: {})
                    HStack { Spacer(); MapPlaceMenu(session: session, node: node, actions: actions) }
                }
                .padding(10).cardBackground()
            case .text where node.mussetKind == "passage":
                HStack(alignment: .top, spacing: 10) {
                    RoundedRectangle(cornerRadius: 1).fill(Ink.accent.opacity(0.6)).frame(width: 3)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(node.musset?["quote"] ?? "").font(.system(size: 14, design: .serif)).italic().lineSpacing(2)
                        Spacer(minLength: 0)
                        Button(chapterTitle) { actions.open(node) }.buttonStyle(.link).font(.ui(11))
                    }
                }
                .padding(12).cardBackground()
            case .text where node.mussetKind == "ink":
                BoardInkShape(points: BoardInk.points(node), natural: BoardInk.natural(node))
                    .stroke(BoardPalette.ink(node.color).opacity(BoardInk.isHighlighter(node) ? 0.4 : 1),
                            style: StrokeStyle(lineWidth: BoardInk.width(node), lineCap: .round, lineJoin: .round))
            case .text where node.mussetKind == "label":
                // Words straight on the board, large.
                Group {
                    if editing {
                        TextEditor(text: $draft).font(.ui(22, .semibold)).scrollContentBackground(.hidden).focused($typing)
                            .onChange(of: draft) { _, t in actions.text(node.id, t) }
                            .onExitCommand { actions.endEditing() }
                    } else {
                        Text(Self.markdown(node.text ?? "")).font(.ui(22, .semibold))
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                }
                .foregroundStyle(node.color == nil ? Color.primary : BoardPalette.ink(node.color))
            case .text where node.mussetKind == "shape":
                let shape = (BoardShape(rawValue: node.musset?["shape"] ?? "") ?? .rect).shape
                ZStack {
                    shape.fill(BoardPalette.paper(node.color))
                    shape.stroke(BoardPalette.ink(node.color).opacity(0.55), lineWidth: 1.5)
                    Group {
                        if editing {
                            TextField("", text: $draft, axis: .vertical).textFieldStyle(.plain).focused($typing)
                                .onChange(of: draft) { _, t in actions.text(node.id, t) }
                                .onSubmit { actions.endEditing() }
                                .onExitCommand { actions.endEditing() }
                        } else {
                            Text(Self.markdown(node.text ?? ""))
                        }
                    }
                    .font(.ui(14, .medium)).multilineTextAlignment(.center).padding(14)
                }
            case .text:
                Group {
                    if editing {
                        TextEditor(text: $draft).font(.ui(14)).scrollContentBackground(.hidden).focused($typing)
                            .onChange(of: draft) { _, t in actions.text(node.id, t) }
                            .onExitCommand { actions.endEditing() }
                    } else if let text = node.text, !text.isEmpty {
                        Text(Self.markdown(text)).font(.ui(14)).lineSpacing(2)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    } else {
                        Text(L("Double-click to write")).font(.ui(14)).foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                }
                .foregroundStyle(.primary)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: Radius.card).fill(BoardPalette.paper(node.color)))
                .overlay(RoundedRectangle(cornerRadius: Radius.card).strokeBorder(Color.primary.opacity(0.08)))
                .clipShape(RoundedRectangle(cornerRadius: Radius.card))
            case .link:
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "link").font(.ui(11)).foregroundStyle(.secondary)
                        Text(URL(string: node.url ?? "")?.host ?? node.url ?? "").font(.ui(13, .medium)).lineLimit(1)
                    }
                    Text(node.url ?? "").font(.ui(11)).foregroundStyle(.secondary).lineLimit(2)
                }
                .padding(12).cardBackground()
            case .file where node.mussetKind == "map":
                MapCard(session: session, node: node, actions: actions, place: node.file)
            case .file:
                FileCard(node: node, session: session)
            }
        }
        .onAppear { draft = node.type == .group ? (node.label ?? "") : (node.text ?? "") }
        .onChange(of: editing) { _, on in
            if on {
                draft = node.type == .group ? (node.label ?? "") : (node.text ?? "")
                DispatchQueue.main.async { typing = true }
            }
        }
        .onAppear { if editing { DispatchQueue.main.async { typing = true } } }
    }

    private var chapterTitle: String {
        session.manifest.chapters.first { $0.id == node.musset?["chapter"] }?.title ?? L("The book")
    }

    /// **Bold**, *italic*, `code` and links, as written in the note.
    static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}

/// Images and PDF covers read once, small: a board redraws often and its files don't change.
@MainActor
enum BoardThumbs {
    private static var images: [String: NSImage] = [:]
    private static var pdfs: [String: (cover: NSImage?, pages: Int)] = [:]

    private static func key(_ url: URL) -> String {
        let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970 ?? 0
        return url.path + "|\(date)"
    }

    static func image(_ url: URL) -> NSImage? {
        let k = key(url)
        if let i = images[k] { return i }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1400,
              ] as CFDictionary) else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        images[k] = image
        return image
    }

    static func pdf(_ url: URL) -> (cover: NSImage?, pages: Int) {
        let k = key(url)
        if let p = pdfs[k] { return p }
        let doc = PDFDocument(url: url)
        let out = (doc?.page(at: 0)?.thumbnail(of: CGSize(width: 180, height: 240), for: .mediaBox), doc?.pageCount ?? 0)
        pdfs[k] = out
        return out
    }
}

/// A file on the board: a sheet, an image, a PDF, a kept web page.
private struct FileCard: View {
    let node: JSONCanvas.Node
    let session: BookSession

    var body: some View {
        let path = node.file ?? ""
        let url = session.bible.store.url(path)
        let ext = (path as NSString).pathExtension.lowercased()
        let isImage = UTType(filenameExtension: ext)?.conforms(to: .image) == true
        Group {
            if isImage, let image = BoardThumbs.image(url) {
                Image(nsImage: image).resizable().scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
                    .clipShape(RoundedRectangle(cornerRadius: Radius.card))
            } else if ext == "pdf", FileManager.default.fileExists(atPath: url.path) {
                let pdf = BoardThumbs.pdf(url)
                HStack(alignment: .top, spacing: 12) {
                    if let cover = pdf.cover {
                        Image(nsImage: cover).resizable().scaledToFit().frame(width: 70)
                            .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text((path as NSString).deletingPathExtension.components(separatedBy: "/").last ?? path).font(.ui(13, .medium)).lineLimit(3)
                        Text(L("\(pdf.pages) pages")).font(.ui(11)).foregroundStyle(.secondary)
                        Text("PDF").font(.ui(10, .semibold)).foregroundStyle(.tertiary)
                    }
                }
                .padding(12).cardBackground()
            } else if let entry = session.bible.entry(path: path) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: entry.kind.icon).font(.ui(11)).foregroundStyle(Ink.accent)
                        Text(entry.title).font(.system(size: 16, design: .serif)).lineLimit(2)
                    }
                    if node.mussetKind == "web" {
                        Text(URL(string: node.musset?["url"] ?? "")?.host ?? "").font(.ui(11)).foregroundStyle(.secondary)
                        Text(L("Web page…").titled).font(.ui(10, .semibold)).foregroundStyle(.tertiary)
                    } else {
                        Text(entry.kind.label + (BibleModel.trackedKinds.contains(entry.kind) ? " · " + session.bible.tier(of: entry).label : ""))
                            .font(.ui(11)).foregroundStyle(.secondary)
                        if let line = NameCard.summary(of: entry) { Text(line).font(.ui(12)).lineLimit(3).padding(.top, 2) }
                    }
                }
                .padding(12).cardBackground()
            } else if !FileManager.default.fileExists(atPath: url.path) {
                VStack(alignment: .leading, spacing: 4) {
                    Text((path as NSString).lastPathComponent).font(.ui(12, .medium))
                    Text(L("Only on the Mac it was added from.")).font(.ui(11)).foregroundStyle(.secondary)
                }
                .padding(12).cardBackground()
            } else {
                Text((path as NSString).lastPathComponent).font(.ui(12)).padding(12).cardBackground()
            }
        }
    }
}

/// The places of the Bible that have a position, on a map (Apple's, no key needed).
private struct MapCard: View {
    let session: BookSession
    let node: JSONCanvas.Node
    let actions: BoardActions
    /// One place's map (its sheet's path), or every located place.
    var place: String? = nil

    var body: some View {
        let places = session.bible.entries.filter { $0.kind == .place && (place == nil || $0.path == place) }.compactMap { e -> (String, CLLocationCoordinate2D)? in
            PlaceMapSection.coordinate(of: e).map { (e.title, $0) }
        }
        let one = place.flatMap { session.bible.entry(path: $0) }
        VStack(spacing: 0) {
            if places.isEmpty, let one, !one.isFile {
                // A place not found yet: found here, and kept in its sheet.
                PlaceMapSection(meta: Binding(get: { session.bible.entry(path: one.path)?.meta ?? one.meta }, set: { meta in
                    var sheet = session.bible.entry(path: one.path) ?? one
                    sheet.meta = meta
                    try? session.bible.save(sheet)
                    session.pendingCommit = true
                }), title: one.title, height: CGFloat(node.height) - 130, save: {})
                    .padding(10).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else if places.isEmpty {
                Text(L("Places get on the map once found in their sheet: an address, a place, a landmark."))
                    .font(.ui(12)).foregroundStyle(.secondary).padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Map(initialPosition: one.flatMap(PlaceMapSection.region(of:)).map { .region($0) } ?? .automatic, interactionModes: [.zoom]) {
                    ForEach(places, id: \.0) { name, at in Marker(name, coordinate: at).tint(Ink.accent) }
                }
            }
            HStack {
                Text(one?.title ?? L("Map")).font(.ui(11, .medium)).foregroundStyle(one == nil ? .tertiary : .primary)
                Spacer()
                if let address = one?.meta["address"] { Text(address).font(.ui(11)).foregroundStyle(.secondary).lineLimit(1) }
                else if one == nil { Text(L("\(places.count) places")).font(.ui(11)).foregroundStyle(.secondary) }
                MapPlaceMenu(session: session, node: node, actions: actions)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
        }
        .cardBackground()
    }
}

/// What a map card shows: one of the Bible's places, all of them, or an address of its own (which one then types).
private struct MapPlaceMenu: View {
    let session: BookSession
    let node: JSONCanvas.Node
    let actions: BoardActions

    var body: some View {
        Menu {
            Self.items(session: session, node: node, actions: actions)
        } label: {
            Image(systemName: "mappin.and.ellipse").font(.ui(11)).foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help(L("Change the place"))
        .accessibilityLabel(L("Change the place"))
    }

    @ViewBuilder static func items(session: BookSession, node: JSONCanvas.Node, actions: BoardActions) -> some View {
        let places = session.bible.entries.filter { $0.kind == .place }
        ForEach(places) { e in
            Button(e.title) {
                actions.edit(node.id) { n in
                    n.type = .file; n.file = e.path; n.text = nil; n.musset = ["kind": "map"]
                }
            }
            .disabled(node.file == e.path)
        }
        if !places.isEmpty { Divider() }
        Button(L("All the places")) {
            actions.edit(node.id) { n in
                n.type = .text; n.file = nil; n.text = L("Map") + ": " + L("Places"); n.musset = ["kind": "map"]
            }
        }
        .disabled(node.mussetKind == "map" && node.file == nil)
        Button(L("An address of its own…")) {
            // From where it is now: the place's position and address, to be changed.
            let from = node.file.flatMap { session.bible.entry(path: $0) }?.meta ?? [:]
            actions.edit(node.id) { n in
                var keys = ["kind": "pin"]
                for k in ["lat", "lon", "span", "address"] { if let v = from[k] ?? n.musset?[k] { keys[k] = v } }
                n.type = .text; n.file = nil; n.text = keys["address"] ?? L("Map"); n.musset = keys
                n.width = max(n.width, 324); n.height = max(n.height, 360)
            }
        }
        .disabled(node.mussetKind == "pin")
    }
}

/// The arrows between cards, and the one being drawn.
private struct BoardEdges: View {
    let board: JSONCanvas
    let motion: BoardMotion
    var selected: String? = nil

    var body: some View {
        let moving = motion.ids.isEmpty ? [] : motion.ids
        let delta = moving.isEmpty ? CGSize.zero : motion.delta
        let resizing = motion.resizing
        let frame = resizing == nil ? .zero : motion.frame
        let link = motion.linkFrom.map { ($0, motion.linkFromSide, motion.linkTo) }
        let target = motion.linkTarget
        let area = (board.bounds ?? .zero).insetBy(dx: -400, dy: -400)
        Canvas { ctx, _ in
            ctx.translateBy(x: -area.minX, y: -area.minY)
            func rect(_ id: String) -> CGRect? {
                guard let n = board.node(id) else { return nil }
                if resizing == id { return frame }
                let d = moving.contains(id) ? delta : .zero
                return CGRect(x: CGFloat(n.x) + d.width, y: CGFloat(n.y) + d.height, width: CGFloat(n.width), height: CGFloat(n.height))
            }
            let ink = GraphicsContext.Shading.color(.primary.opacity(0.45))
            for e in board.edges {
                guard let ra = rect(e.fromNode), let rb = rect(e.toNode) else { continue }
                let route = BoardRoute.between(ra, e.fromSide.flatMap(BoardSide.init(rawValue:)), rb, e.toSide.flatMap(BoardSide.init(rawValue:)))
                if e.id == selected {
                    var halo = Path()
                    halo.move(to: route.start)
                    halo.addCurve(to: route.end, control1: route.c1, control2: route.c2)
                    ctx.stroke(halo, with: .color(Ink.accent.opacity(0.35)), style: StrokeStyle(lineWidth: 7, lineCap: .round))
                }
                Self.arrow(&ctx, route, ink: e.color == nil ? ink : .color(BoardPalette.ink(e.color)), dashed: e.dashed == true,
                           head: e.toEnd != "none", tail: e.fromEnd == "arrow")
            }
            if let (from, side, to) = link, let ra = rect(from) {
                let accent = GraphicsContext.Shading.color(Ink.accent)
                // The card reached shows its magnets, the one snapped to filled.
                if let target, let rb = rect(target.id) {
                    for s in BoardSide.allCases {
                        let p = s.anchor(rb), r: CGFloat = s == target.side ? 6 : 4
                        let dot = Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
                        if s == target.side { ctx.fill(dot, with: accent) } else { ctx.stroke(dot, with: accent, lineWidth: 1.5) }
                    }
                    Self.arrow(&ctx, BoardRoute.between(ra, side, rb, target.side), ink: accent)
                } else {
                    Self.arrow(&ctx, BoardRoute.toPoint(ra, side, to), ink: accent)
                }
            }
        }
        .frame(width: area.width, height: area.height)
        .offset(x: area.minX, y: area.minY)
    }

    static func arrow(_ ctx: inout GraphicsContext, _ r: BoardRoute, ink: GraphicsContext.Shading, dashed: Bool = false,
                      head: Bool = true, tail: Bool = false) {
        var line = Path()
        line.move(to: r.start)
        line.addCurve(to: r.end, control1: r.c1, control2: r.c2)
        ctx.stroke(line, with: ink, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, dash: dashed ? [6, 5] : []))
        // A head points the way the curve arrives.
        func point(_ b: CGPoint, from c: CGPoint) {
            let angle = atan2(b.y - c.y, b.x - c.x)
            var head = Path()
            head.move(to: b)
            head.addLine(to: CGPoint(x: b.x - 10 * cos(angle - 0.42), y: b.y - 10 * sin(angle - 0.42)))
            head.addLine(to: CGPoint(x: b.x - 10 * cos(angle + 0.42), y: b.y - 10 * sin(angle + 0.42)))
            head.closeSubpath()
            ctx.fill(head, with: ink)
        }
        if head { point(r.end, from: r.c2) }
        if tail { point(r.start, from: r.c1) }
    }
}

/// What one does to the arrow picked: its colour, its line, its heads, its direction; or remove it. Shown above its
/// middle. Only this view reads the camera, so the board is not redrawn as one pans.
private struct EdgeBar: View {
    let camera: BoardCamera
    let middle: CGPoint
    let edge: JSONCanvas.Edge
    let edit: ((inout JSONCanvas.Edge) -> Void) -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            Menu {
                Button(L("None")) { edit { $0.color = nil } }
                ForEach(BoardPalette.presets, id: \.self) { c in Button(BoardPalette.name(c)) { edit { $0.color = c } } }
            } label: {
                Image(systemName: "circle.fill").foregroundStyle(edge.color == nil ? Color.secondary : BoardPalette.ink(edge.color))
            }
            .help(L("Colour")).accessibilityLabel(L("Colour"))
            Menu {
                Toggle(L("Solid line"), isOn: Binding(get: { edge.dashed != true }, set: { _ in edit { $0.dashed = nil } }))
                Toggle(L("Dashed line"), isOn: Binding(get: { edge.dashed == true }, set: { _ in edit { $0.dashed = true } }))
                Divider()
                Toggle(L("One arrowhead"), isOn: Binding(get: { edge.toEnd != "none" && edge.fromEnd != "arrow" },
                                                         set: { _ in edit { $0.toEnd = "arrow"; $0.fromEnd = nil } }))
                Toggle(L("Two arrowheads"), isOn: Binding(get: { edge.toEnd != "none" && edge.fromEnd == "arrow" },
                                                          set: { _ in edit { $0.toEnd = "arrow"; $0.fromEnd = "arrow" } }))
                Toggle(L("No arrowhead"), isOn: Binding(get: { edge.toEnd == "none" }, set: { _ in edit { $0.toEnd = "none"; $0.fromEnd = nil } }))
            } label: {
                Image(systemName: "line.diagonal.arrow")
            }
            .help(L("Line and arrowheads")).accessibilityLabel(L("Line and arrowheads"))
            Button {
                edit { e in
                    (e.fromNode, e.toNode) = (e.toNode, e.fromNode)
                    (e.fromSide, e.toSide) = (e.toSide, e.fromSide)
                }
            } label: { Image(systemName: "arrow.left.arrow.right") }
                .help(L("Reverse the arrow")).accessibilityLabel(L("Reverse the arrow"))
            Button(action: remove) { Image(systemName: "trash") }
                .help(L("Remove the arrow")).accessibilityLabel(L("Remove the arrow"))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).buttonStyle(.borderless).fixedSize()
        .font(.ui(12))
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(Ink.side, in: Capsule()).overlay(Capsule().strokeBorder(Ink.hairline))
        .position(x: middle.x * camera.zoom + camera.pan.width, y: middle.y * camera.zoom + camera.pan.height - 26)
    }
}

private extension View {
    func cardBackground() -> some View {
        frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: Radius.card).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: Radius.card).strokeBorder(Ink.hairline))
            .clipShape(RoundedRectangle(cornerRadius: Radius.card))
    }
}

/// Characters (or places) on a board, in three columns by how much they're in the book. Arranged by Musset;
/// dropping a card in another column pins it there.
struct CastBoard: View {
    let app: AppState
    @Bindable var session: BookSession
    let folder: String
    @State private var target: NameTier?

    private var bible: BibleModel { session.bible }

    var body: some View {
        let sheets = bible.entries(in: folder).filter { BibleModel.trackedKinds.contains($0.kind) }
        let tags = folder == "personnages" ? bible.tagsWithoutSheet(session.plot) : []
        ScrollView {
            HStack(alignment: .top, spacing: 18) {
                ForEach(NameTier.allCases.filter { t in t != .absent || sheets.contains { bible.tier(of: $0) == .absent } || tags.contains { bible.tier(of: $0) == .absent } }) { tier in
                    let members = sheets.filter { bible.tier(of: $0) == tier }
                        .sorted { bible.presence($0.path) != bible.presence($1.path) ? bible.presence($0.path) > bible.presence($1.path) : $0.title < $1.title }
                    let gridOnly = tags.filter { bible.tier(of: $0) == tier }
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(tier.label).font(.ui(12, .semibold)).foregroundStyle(.secondary)
                            Spacer()
                            Text(caption(tier)).font(.ui(11)).foregroundStyle(.tertiary)
                        }
                        if tier == .extra || tier == .absent {
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(members) { e in
                                    HStack {
                                        if e.meta["origin"] == "musset" && bible.presence(e.path) <= 1 { Circle().fill(Ink.accent).frame(width: 5, height: 5) }
                                        Text(e.title).font(.ui(13))
                                        Spacer()
                                        Text(chapterNumbers(e)).font(.ui(11)).foregroundStyle(.tertiary).lineLimit(1)
                                    }
                                    .padding(.vertical, 6)
                                    .contentShape(Rectangle())
                                    .onTapGesture { app.open(.sheet(e.path)) }
                                    .draggable(e.path)
                                    .overlay(alignment: .bottom) { Divider().opacity(0.5) }
                                }
                            }
                            .padding(.horizontal, 12).padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: Radius.control).fill(Color(nsColor: .textBackgroundColor)))
                            .overlay(RoundedRectangle(cornerRadius: Radius.control).strokeBorder(Ink.hairline))
                            if tier == .extra {
                                Text(L("In one chapter only. They move up on their own the day they appear in a second.")).font(.ui(11)).foregroundStyle(.secondary)
                            }
                        } else {
                            ForEach(members) { e in card(e, big: tier == .main) }
                        }
                        // Characters of the plot grid with no sheet yet: a click gives them one.
                        ForEach(gridOnly) { tag in
                            HStack {
                                Text(tag.name).font(.ui(13)).foregroundStyle(.secondary)
                                Spacer()
                                Text(L("no sheet yet")).font(.ui(11)).foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .contentShape(Rectangle())
                            .onTapGesture { if let e = try? bible.sheet(for: tag) { app.open(.sheet(e.path)) } }
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .background(RoundedRectangle(cornerRadius: Radius.card).fill(Color(nsColor: .textBackgroundColor).opacity(target == tier ? 0.9 : 0.55)))
                    .overlay(RoundedRectangle(cornerRadius: Radius.card).strokeBorder(target == tier ? Ink.accent : Ink.hairline))
                    .dropDestination(for: String.self) { paths, _ in
                        for p in paths { pin(p, tier) }
                        return true
                    } isTargeted: { target = $0 ? tier : (target == tier ? nil : target) }
                }
            }
            .padding(.horizontal, 32).padding(.vertical, 20)
        }
        .onAppear { session.refreshBibleMentions() }
    }

    private func card(_ e: BibleEntry, big: Bool) -> some View {
        let open = session.keeper.entity(e.path)?.contradictions.filter { !$0.dismissed }.count ?? 0
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(e.title).font(.system(size: big ? 19 : 16, design: .serif))
                Spacer()
                if open > 0 { Text(L("\(open) continuity")).font(.ui(11)).foregroundStyle(Ink.critique) }
                if e.meta["tier"] != nil { Image(systemName: "pin.fill").font(.ui(9)).foregroundStyle(.tertiary).help(L("Kept in this column")) }
            }
            Text(session.words.count(bible.occurrences[e.path]?.count ?? 0, .piece) + " · " + L("\(bible.presence(e.path)) times")).font(.ui(11)).foregroundStyle(.secondary)
            if big, let line = NameCard.summary(of: e) ?? session.keeper.entity(e.path)?.facts.first?.text {
                Text(line).font(.uiMono(12)).lineLimit(3).padding(.top, 4)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.control).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: Radius.control).strokeBorder(Ink.hairline))
        .shadow(color: .black.opacity(0.05), radius: 1.5, y: 1)
        .contentShape(Rectangle())
        .onTapGesture { app.open(.sheet(e.path)) }
        .draggable(e.path)
    }

    private func caption(_ tier: NameTier) -> String {
        switch tier {
        case .main: L("in most chapters")
        case .secondary: L("several chapters")
        case .extra: L("one chapter")
        case .absent: L("never named")
        }
    }

    /// The chapter an extra is in, by its title.
    private func chapterNumbers(_ e: BibleEntry) -> String {
        let ids = Set((bible.occurrences[e.path] ?? [:]).keys)
        return session.manifest.chapters.filter { ids.contains($0.id) }.map(\.title).joined(separator: ", ")
    }

    /// Dropped in a column: kept there, whatever the counts say. Dropped back where the book puts it: unpinned.
    private func pin(_ path: String, _ tier: NameTier) {
        guard var e = bible.entry(path: path) else { return }
        e.meta["tier"] = nil
        let computed = bible.tier(of: e)
        e.meta["tier"] = computed == tier ? nil : tier.rawValue
        try? bible.save(e)
        session.pendingCommit = true
    }
}
