import CoreGraphics
import Foundation

/// A board of the Bible: cards laid out freely, like a cork board. Saved as JSON Canvas 1.0 (`bible/tableaux/*.canvas`),
/// the open format Obsidian reads: the `bible/` folder opens there as a vault, boards included.
/// File paths are relative to `bible/`. What JSON Canvas has no word for (a passage of the book, a map) is a text
/// node carrying a `musset` key, which other readers ignore.
struct JSONCanvas: Codable, Equatable {
    struct Node: Codable, Equatable, Identifiable {
        enum Kind: String, Codable { case text, file, link, group }
        var id: String = Self.newID()
        var type: Kind
        var x: Int
        var y: Int
        var width: Int
        var height: Int
        var color: String?
        var text: String?
        var file: String?
        var url: String?
        var label: String?
        /// Musset's own: `kind` (passage, map, web), `chapter`, `quote`, `url`.
        var musset: [String: String]?

        var mussetKind: String? { musset?["kind"] }

        /// JSON Canvas ids are 16 hex characters.
        static func newID() -> String { String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16)).lowercased() }
    }

    struct Edge: Codable, Equatable, Identifiable {
        var id: String = Node.newID()
        var fromNode: String
        var toNode: String
        var fromSide: String?
        var toSide: String?
        var toEnd: String? = "arrow"
        /// JSON Canvas: no head at the start unless « arrow ».
        var fromEnd: String?
        /// One of JSON Canvas's six colours, or none: the page's ink.
        var color: String?
        var label: String?
        /// Musset's own: a dashed line.
        var dashed: Bool?
    }

    var nodes: [Node] = []
    var edges: [Edge] = []

    static func read(_ url: URL) -> JSONCanvas {
        JSONFile.read(at: url) ?? JSONCanvas()
    }

    func write(_ url: URL) throws {
        try JSONFile.write(self, to: url)
    }

    /// Cards follow the sheets and files that moved in the Bible (`move`: where a path went). Returns whether any did.
    mutating func retarget(_ move: (String) -> String) -> Bool {
        var changed = false
        for i in nodes.indices {
            guard let file = nodes[i].file, move(file) != file else { continue }
            nodes[i].file = move(file)
            changed = true
        }
        return changed
    }

    mutating func remove(_ id: String) {
        nodes.removeAll { $0.id == id }
        edges.removeAll { $0.fromNode == id || $0.toNode == id }
    }

    /// A free spot for a new card: right of the last one, or at the start.
    func nextSpot(width: Int) -> (x: Int, y: Int) {
        guard let last = nodes.filter({ $0.type != .group }).max(by: { ($0.y, $0.x) < ($1.y, $1.x) }) else { return (40, 40) }
        return last.x + last.width + 40 > 1600 ? (40, last.y + last.height + 40) : (last.x + last.width + 40, last.y)
    }
}

// MARK: Laying cards out

extension JSONCanvas {
    /// Cards come to rest on this grid (half the dots' spacing), so they line up without trying.
    static let snap = 9

    func node(_ id: String) -> Node? { nodes.first { $0.id == id } }

    func rect(of n: Node) -> CGRect { CGRect(x: n.x, y: n.y, width: n.width, height: n.height) }

    /// Everything on the board, or nil when it is empty.
    var bounds: CGRect? {
        nodes.map(rect(of:)).reduce(nil) { $0?.union($1) ?? $1 }
    }

    /// The cards a box touches (columns only when the box takes them whole, so a box drawn inside one picks its cards).
    func ids(in box: CGRect) -> Set<String> {
        Set(nodes.filter { n in n.type == .group ? box.contains(rect(of: n)) : box.intersects(rect(of: n)) }.map(\.id))
    }

    /// The curve an arrow follows between its two cards.
    func route(of e: Edge) -> BoardRoute? {
        guard let a = node(e.fromNode), let b = node(e.toNode) else { return nil }
        return .between(rect(of: a), e.fromSide.flatMap(BoardSide.init(rawValue:)), rect(of: b), e.toSide.flatMap(BoardSide.init(rawValue:)))
    }

    /// The arrow passing within reach of a point, the last drawn first.
    func edge(at p: CGPoint, within reach: CGFloat) -> Edge? {
        edges.last { e in
            guard let r = route(of: e) else { return false }
            let line = CGMutablePath()
            line.move(to: r.start)
            line.addCurve(to: r.end, control1: r.c1, control2: r.c2)
            return line.copy(strokingWithWidth: reach * 2, lineCap: .round, lineJoin: .round, miterLimit: 1).contains(p)
        }
    }

    /// A container drawn around these cards (and what they carry), with room for its name: they then move with it.
    @discardableResult mutating func group(_ ids: Set<String>) -> String? {
        let inside = nodes.filter { carried(ids).contains($0.id) }
        guard inside.count > 1, let box = inside.map(rect(of:)).reduce(nil, { $0?.union($1) ?? $1 }) else { return nil }
        let pad = 24.0, top = 48.0
        let g = Node(type: .group, x: Int(box.minX - pad), y: Int(box.minY - top), width: Int(box.width + pad * 2),
                     height: Int(box.height + top + pad), label: "")
        nodes.insert(g, at: 0)
        return g.id
    }

    /// The cards that move with these: a column carries the cards inside it.
    func carried(_ ids: Set<String>) -> Set<String> {
        var out = ids
        for g in nodes where g.type == .group && ids.contains(g.id) {
            for n in nodes where n.id != g.id && rect(of: g).contains(rect(of: n)) { out.insert(n.id) }
        }
        return out
    }

    /// The topmost card at a point: a card before the column it sits in.
    func node(at p: CGPoint) -> Node? {
        nodes.last { $0.type != .group && rect(of: $0).contains(p) } ?? nodes.last { rect(of: $0).contains(p) }
    }

    /// Moves cards together; with `snap`, the first of them comes to rest on the grid and the others keep their places to it.
    mutating func move(_ ids: Set<String>, by dx: CGFloat, _ dy: CGFloat, snap: Bool = true) {
        guard let lead = nodes.first(where: { ids.contains($0.id) }) else { return }
        var mx = Int(dx.rounded()), my = Int(dy.rounded())
        if snap {
            let g = Self.snap
            mx = Int((Double(lead.x + mx) / Double(g)).rounded()) * g - lead.x
            my = Int((Double(lead.y + my) / Double(g)).rounded()) * g - lead.y
        }
        for i in nodes.indices where ids.contains(nodes[i].id) { nodes[i].x += mx; nodes[i].y += my }
    }

    /// Copies of cards, a little lower and to the right, with the arrows between them; returns the copies' ids.
    mutating func duplicate(_ ids: Set<String>) -> Set<String> {
        var map: [String: String] = [:]
        for n in nodes where ids.contains(n.id) {
            var copy = n
            copy.id = Node.newID()
            copy.x += 2 * Self.snap; copy.y += 2 * Self.snap
            map[n.id] = copy.id
            nodes.append(copy)
        }
        for e in edges where map[e.fromNode] != nil && map[e.toNode] != nil {
            var copy = e
            copy.id = Node.newID()
            copy.fromNode = map[e.fromNode]!; copy.toNode = map[e.toNode]!
            edges.append(copy)
        }
        return Set(map.values)
    }

    /// The cards brought to the top of the pile, in their order.
    mutating func bringToFront(_ ids: Set<String>) {
        let up = nodes.filter { ids.contains($0.id) }
        nodes.removeAll { ids.contains($0.id) }
        nodes += up
    }
}

// MARK: Magnets and arrows

/// The four magnets of a card, where arrows meet it: the middles of its sides (JSON Canvas's `fromSide`, `toSide`).
enum BoardSide: String, CaseIterable {
    case top, right, bottom, left

    func anchor(_ r: CGRect) -> CGPoint {
        switch self {
        case .top: CGPoint(x: r.midX, y: r.minY)
        case .right: CGPoint(x: r.maxX, y: r.midY)
        case .bottom: CGPoint(x: r.midX, y: r.maxY)
        case .left: CGPoint(x: r.minX, y: r.midY)
        }
    }

    /// The way out of the card from this side.
    var normal: CGVector {
        switch self {
        case .top: CGVector(dx: 0, dy: -1)
        case .right: CGVector(dx: 1, dy: 0)
        case .bottom: CGVector(dx: 0, dy: 1)
        case .left: CGVector(dx: -1, dy: 0)
        }
    }

    /// The magnet nearest a point.
    static func nearest(_ r: CGRect, to p: CGPoint) -> BoardSide {
        allCases.min { hypot($0.anchor(r).x - p.x, $0.anchor(r).y - p.y) < hypot($1.anchor(r).x - p.x, $1.anchor(r).y - p.y) }!
    }

    /// The side of `r` that faces a point: how an arrow without magnets leaves.
    static func facing(_ r: CGRect, toward p: CGPoint) -> BoardSide {
        let dx = (p.x - r.midX) / max(r.width, 1), dy = (p.y - r.midY) / max(r.height, 1)
        return abs(dx) > abs(dy) ? (dx > 0 ? .right : .left) : (dy > 0 ? .bottom : .top)
    }
}

/// An arrow's course: from a magnet, square to its side, curving to the other end.
struct BoardRoute: Equatable {
    var start: CGPoint, c1: CGPoint, c2: CGPoint, end: CGPoint

    /// Halfway along the curve.
    var middle: CGPoint {
        CGPoint(x: (start.x + 3 * c1.x + 3 * c2.x + end.x) / 8, y: (start.y + 3 * c1.y + 3 * c2.y + end.y) / 8)
    }

    /// Between two cards, at the magnets given, or else the sides that face each other.
    static func between(_ a: CGRect, _ fromSide: BoardSide?, _ b: CGRect, _ toSide: BoardSide?) -> BoardRoute {
        let fs = fromSide ?? BoardSide.facing(a, toward: CGPoint(x: b.midX, y: b.midY))
        let ts = toSide ?? BoardSide.facing(b, toward: CGPoint(x: a.midX, y: a.midY))
        return make(fs.anchor(a), fs.normal, ts.anchor(b), ts.normal)
    }

    /// From a card's magnet to a free point (an arrow being drawn).
    static func toPoint(_ a: CGRect, _ fromSide: BoardSide, _ p: CGPoint) -> BoardRoute {
        let s = fromSide.anchor(a)
        let dx = s.x - p.x, dy = s.y - p.y, len = max(hypot(dx, dy), 1)
        return make(s, fromSide.normal, p, CGVector(dx: dx / len, dy: dy / len))
    }

    private static func make(_ s: CGPoint, _ ns: CGVector, _ e: CGPoint, _ ne: CGVector) -> BoardRoute {
        let k = min(max(hypot(e.x - s.x, e.y - s.y) * 0.4, 24), 140)
        return BoardRoute(start: s, c1: CGPoint(x: s.x + ns.dx * k, y: s.y + ns.dy * k),
                          c2: CGPoint(x: e.x + ne.dx * k, y: e.y + ne.dy * k), end: e)
    }
}

// MARK: Freehand

/// A stroke of the marker: a text card with no text whose `musset` keys hold its points (relative to the card, at
/// the size it was drawn), its width and its pen. Other readers of JSON Canvas see an empty card.
enum BoardInk {
    static func make(_ points: [CGPoint], width: CGFloat, color: String?, highlighter: Bool) -> JSONCanvas.Node? {
        guard let first = points.first else { return nil }
        var minX = first.x, minY = first.y, maxX = first.x, maxY = first.y
        for p in points { minX = min(minX, p.x); minY = min(minY, p.y); maxX = max(maxX, p.x); maxY = max(maxY, p.y) }
        let pad = width / 2 + 2
        let ox = (minX - pad).rounded(.down), oy = (minY - pad).rounded(.down)
        let w = max(1, (maxX + pad - ox).rounded(.up)), h = max(1, (maxY + pad - oy).rounded(.up))
        var keys = ["kind": "ink", "width": String(format: "%.1f", width), "w0": "\(Int(w))", "h0": "\(Int(h))",
                    "points": points.map { String(format: "%.1f,%.1f", $0.x - ox, $0.y - oy) }.joined(separator: " ")]
        if highlighter { keys["pen"] = "highlighter" }
        return JSONCanvas.Node(type: .text, x: Int(ox), y: Int(oy), width: Int(w), height: Int(h), color: color, text: "", musset: keys)
    }

    /// The points as drawn, relative to the card at its first size.
    static func points(_ n: JSONCanvas.Node) -> [CGPoint] {
        (n.musset?["points"] ?? "").split(separator: " ").compactMap { pair in
            let xy = pair.split(separator: ",").compactMap { Double($0) }
            return xy.count == 2 ? CGPoint(x: xy[0], y: xy[1]) : nil
        }
    }

    /// The size it was drawn at: resizing the card scales the stroke.
    static func natural(_ n: JSONCanvas.Node) -> CGSize {
        CGSize(width: Double(n.musset?["w0"] ?? "") ?? Double(n.width), height: Double(n.musset?["h0"] ?? "") ?? Double(n.height))
    }

    static func width(_ n: JSONCanvas.Node) -> CGFloat { CGFloat(Double(n.musset?["width"] ?? "") ?? 3) }
    static func isHighlighter(_ n: JSONCanvas.Node) -> Bool { n.musset?["pen"] == "highlighter" }

    /// The stroke on the board, at the card's place and size.
    static func placed(_ n: JSONCanvas.Node) -> [CGPoint] {
        let nat = natural(n)
        let sx = CGFloat(n.width) / max(nat.width, 1), sy = CGFloat(n.height) / max(nat.height, 1)
        return points(n).map { CGPoint(x: CGFloat(n.x) + $0.x * sx, y: CGFloat(n.y) + $0.y * sy) }
    }

    /// The stroke passes within `radius` of a point (the eraser, a click).
    static func touches(_ n: JSONCanvas.Node, _ p: CGPoint, radius: CGFloat) -> Bool {
        let pts = placed(n), reach = radius + width(n) / 2
        guard let first = pts.first else { return false }
        if pts.count == 1 { return hypot(first.x - p.x, first.y - p.y) <= reach }
        for (a, b) in zip(pts, pts.dropFirst()) where distance(p, a, b) <= reach { return true }
        return false
    }

    private static func distance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y, len = dx * dx + dy * dy
        let t = len == 0 ? 0 : max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }
}

extension BibleModel {
    /// A new empty board, named by the author.
    func createBoard(_ title: String) throws -> BibleEntry {
        let name = title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-").trimmingCharacters(in: .whitespaces)
        var path = "\(BibleKind.board.folder)/\(name.isEmpty ? L("Board") : name).canvas"
        var n = 2
        while FileManager.default.fileExists(atPath: store.url(path).path) {
            path = "\(BibleKind.board.folder)/\(name) \(n).canvas"
            n += 1
        }
        try JSONCanvas().write(store.url(path))
        reload()
        return entry(path: path) ?? BibleEntry(path: path, kind: .board, title: name, isFile: true)
    }

    /// A board under another name (its file's name); returns its new path, or nil when nothing changes.
    func renameBoard(_ path: String, to title: String) throws -> String? {
        let name = title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-").trimmingCharacters(in: .whitespaces)
        let folder = (path as NSString).deletingLastPathComponent
        var target = "\(folder)/\(name).canvas"
        guard !name.isEmpty, target != path else { return nil }
        var n = 2
        // The same name in another case is the same file on most Macs: that one is a plain rename.
        while FileManager.default.fileExists(atPath: store.url(target).path), target.lowercased() != path.lowercased() {
            target = "\(folder)/\(name) \(n).canvas"
            n += 1
        }
        try FileManager.default.moveItem(at: store.url(path), to: store.url(target))
        reload()
        return target
    }

    /// A file brought onto a board goes to the documents, as the Bible keeps them; returns its path in `bible/`.
    func bring(_ file: URL) throws -> String {
        let ext = file.pathExtension.lowercased()
        let path = store.freePath(title: file.deletingPathExtension().lastPathComponent, folder: BibleStore.documents, ext: ext.isEmpty ? "bin" : ext)
        try FileManager.default.createDirectory(at: store.url(path).deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: file, to: store.url(path))
        reload()
        return path
    }

}
