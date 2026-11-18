import XCTest
@testable import Musset

/// Boards are JSON Canvas files in the Bible, readable by Obsidian.
@MainActor
final class BoardTests: XCTestCase {
    private func bible() throws -> BibleModel {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("musset-board-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return BibleModel(root: root)
    }

    func testABoardIsAJSONCanvasFile() throws {
        let b = try bible()
        let tom = try b.create(title: "Tom", kind: .character)
        let board = try b.createBoard("The deed")
        XCTAssertEqual(board.kind, .board)
        XCTAssertEqual(board.title, "The deed")
        XCTAssertEqual(board.path, "tableaux/The deed.canvas")

        var canvas = JSONCanvas.read(b.store.url(board.path))
        let note = JSONCanvas.Node(type: .text, x: 40, y: 40, width: 240, height: 120, text: "Behind March.")
        let sheet = JSONCanvas.Node(type: .file, x: 320, y: 40, width: 240, height: 70, file: tom.path)
        let passage = JSONCanvas.Node(type: .text, x: 40, y: 200, width: 260, height: 130, text: "> nothing to take but the salt\n\n@[The Salt Works]",
                                      musset: ["kind": "passage", "chapter": "02", "quote": "nothing to take but the salt"])
        canvas.nodes = [note, sheet, passage]
        canvas.edges = [.init(fromNode: note.id, toNode: sheet.id)]
        try canvas.write(b.store.url(board.path))

        XCTAssertEqual(JSONCanvas.read(b.store.url(board.path)), canvas, "round trip")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: b.store.url(board.path))) as? [String: Any])
        let nodes = try XCTUnwrap(json["nodes"] as? [[String: Any]])
        XCTAssertEqual(nodes.count, 3)
        for n in nodes {
            for key in ["id", "type", "x", "y", "width", "height"] { XCTAssertNotNil(n[key], "JSON Canvas requires \(key)") }
            XCTAssertTrue(["text", "file", "link", "group"].contains(n["type"] as? String ?? ""))
        }
        XCTAssertEqual((nodes.first { $0["type"] as? String == "file" })?["file"] as? String, "personnages/tom.md", "paths relative to bible/")
        let edge = try XCTUnwrap((json["edges"] as? [[String: Any]])?.first)
        XCTAssertEqual(edge["fromNode"] as? String, note.id)

    }

    func testTwoBoardsOfTheSameNameDontCollide() throws {
        let b = try bible()
        let one = try b.createBoard("Island light")
        let two = try b.createBoard("Island light")
        XCTAssertNotEqual(one.path, two.path)
        XCTAssertEqual(b.entries.filter { $0.kind == .board }.count, 2)
    }

    func testAFileBroughtOnABoardGoesToTheDocuments() throws {
        let b = try bible()
        let src = FileManager.default.temporaryDirectory.appendingPathComponent("registry-\(UUID()).pdf")
        try Data("%PDF-1.4".utf8).write(to: src)
        addTeardownBlock { try? FileManager.default.removeItem(at: src) }
        let path = try b.bring(src)
        XCTAssertTrue(path.hasPrefix("documents/"))
        XCTAssertTrue(path.hasSuffix(".pdf"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: b.store.url(path).path))
    }

    func testNewCardsGoNextToTheLast() {
        var c = JSONCanvas()
        XCTAssertEqual(c.nextSpot(width: 200).x, 40)
        c.nodes = [.init(type: .text, x: 40, y: 40, width: 200, height: 100)]
        XCTAssertEqual(c.nextSpot(width: 200).x, 280)
        c.remove(c.nodes[0].id)
        XCTAssertTrue(c.nodes.isEmpty)
    }

    func testAPlaceKeepsItsPinAndWhatIsPinnedToIt() throws {
        let b = try bible()
        var place = try b.create(title: "Crimée", kind: .place)
        place.meta = ["lat": "48.88910", "lon": "2.37780", "span": "0.0100", "address": "Rue de Crimée, Paris, France",
                      "attachments": "documents/photo.jpg|https://example.org/plan"]
        try b.save(place)
        let back = try XCTUnwrap(b.entry(path: place.path))
        XCTAssertEqual(back.meta["address"], "Rue de Crimée, Paris, France")
        XCTAssertTrue(back.fields.isEmpty || !back.fields.contains { ["lat", "span", "attachments"].contains($0.name) }, "Musset's keys aren't author fields")
        let at = try XCTUnwrap(PlaceMapSection.coordinate(of: back))
        XCTAssertEqual(at.latitude, 48.8891, accuracy: 0.0001)
        XCTAssertEqual(PlaceMapSection.region(of: back)?.span.latitudeDelta ?? 0, 0.01, accuracy: 0.0001)
        XCTAssertNil(PlaceMapSection.coordinate(["lat": "48.8"]), "half a position is none")
    }

    func testAPinCardKeepsItsAddressInTheCanvas() throws {
        let b = try bible()
        let board = try b.createBoard("Paris")
        var c = JSONCanvas()
        c.nodes = [.init(type: .text, x: 0, y: 0, width: 320, height: 330, text: "Rue de Crimée", musset: ["kind": "pin", "lat": "48.8891", "lon": "2.3778", "address": "Rue de Crimée"])]
        try c.write(b.store.url(board.path))
        XCTAssertEqual(JSONCanvas.read(b.store.url(board.path)).nodes.first?.musset?["address"], "Rue de Crimée")
    }

    // MARK: Laying out

    func testCardsComeToRestOnTheGridAndKeepTheirPlacesToEachOther() {
        var c = JSONCanvas()
        let a = JSONCanvas.Node(type: .text, x: 18, y: 18, width: 240, height: 120, text: "A")
        let b = JSONCanvas.Node(type: .text, x: 300, y: 40, width: 240, height: 120, text: "B")
        c.nodes = [a, b]
        c.move([a.id, b.id], by: 13, 4)
        XCTAssertEqual(c.node(a.id).map { [$0.x, $0.y] }, [27, 18], "on the grid")
        XCTAssertEqual(c.node(b.id).map { [$0.x, $0.y] }, [309, 40], "the same distance from the first")
        c.move([a.id], by: 1, 1, snap: false)
        XCTAssertEqual(c.node(a.id).map { [$0.x, $0.y] }, [28, 19])
    }

    func testAColumnCarriesItsCardsAndABoxPicksWhatItTouches() {
        var c = JSONCanvas()
        let col = JSONCanvas.Node(type: .group, x: 0, y: 0, width: 300, height: 400, label: "Clues")
        let inside = JSONCanvas.Node(type: .text, x: 20, y: 40, width: 200, height: 100, text: "In")
        let outside = JSONCanvas.Node(type: .text, x: 500, y: 40, width: 200, height: 100, text: "Out")
        c.nodes = [col, inside, outside]
        XCTAssertEqual(c.carried([col.id]), [col.id, inside.id])
        XCTAssertEqual(c.ids(in: CGRect(x: 10, y: 10, width: 100, height: 100)), [inside.id], "a box inside a column picks its cards, not it")
        XCTAssertEqual(c.ids(in: CGRect(x: -10, y: -10, width: 800, height: 500)), [col.id, inside.id, outside.id])
        XCTAssertEqual(c.node(at: CGPoint(x: 50, y: 60))?.id, inside.id, "the card before its column")
        XCTAssertEqual(c.node(at: CGPoint(x: 50, y: 300))?.id, col.id)
        XCTAssertEqual(c.bounds, CGRect(x: 0, y: 0, width: 700, height: 400))
    }

    func testDuplicatesKeepTheirArrows() {
        var c = JSONCanvas()
        let a = JSONCanvas.Node(type: .text, x: 0, y: 0, width: 100, height: 60, text: "A")
        let b = JSONCanvas.Node(type: .text, x: 200, y: 0, width: 100, height: 60, text: "B")
        c.nodes = [a, b]
        c.edges = [.init(fromNode: a.id, toNode: b.id)]
        let copies = c.duplicate([a.id, b.id])
        XCTAssertEqual(copies.count, 2)
        XCTAssertEqual(c.nodes.count, 4)
        XCTAssertEqual(c.edges.count, 2)
        XCTAssertTrue(c.edges.contains { copies.contains($0.fromNode) && copies.contains($0.toNode) })
        c.bringToFront([a.id])
        XCTAssertEqual(c.nodes.last?.id, a.id)
    }

    // MARK: Freehand, handles, tools

    func testAStrokeKeepsItsPointsAndScalesWithItsCard() throws {
        var n = try XCTUnwrap(BoardInk.make([CGPoint(x: 100, y: 100), CGPoint(x: 150, y: 120), CGPoint(x: 200, y: 100)],
                                            width: 4, color: "5", highlighter: false))
        XCTAssertEqual(n.mussetKind, "ink")
        XCTAssertEqual([n.x, n.y], [96, 96], "the stroke's box, with room for its width")
        XCTAssertEqual(BoardInk.placed(n).first.map { [$0.x, $0.y] }, [100, 100])
        XCTAssertTrue(BoardInk.touches(n, CGPoint(x: 150, y: 118), radius: 4))
        XCTAssertFalse(BoardInk.touches(n, CGPoint(x: 150, y: 160), radius: 4), "the eraser misses a point far from the line")
        // Twice as wide: the points spread with it.
        n.width *= 2
        XCTAssertEqual(BoardInk.placed(n).last?.x ?? 0, 96 + 2 * (200 - 96), accuracy: 0.5)
        // Through JSON Canvas and back.
        var c = JSONCanvas()
        c.nodes = [n]
        let data = try JSONEncoder().encode(c)
        XCTAssertEqual(try JSONDecoder().decode(JSONCanvas.self, from: data), c)
    }

    func testHandlesPullOneSideAndKeepTheOther() {
        let r = CGRect(x: 0, y: 0, width: 200, height: 100)
        let min = CGSize(width: 40, height: 30)
        XCTAssertEqual(BoardGrip.leading.resized(r, by: CGSize(width: 50, height: 9), minimum: min, keepRatio: false), CGRect(x: 50, y: 0, width: 150, height: 100))
        XCTAssertEqual(BoardGrip.bottom.resized(r, by: CGSize(width: 9, height: 40), minimum: min, keepRatio: false), CGRect(x: 0, y: 0, width: 200, height: 140))
        XCTAssertEqual(BoardGrip.topLeading.resized(r, by: CGSize(width: 500, height: 500), minimum: min, keepRatio: false),
                       CGRect(x: 160, y: 70, width: 40, height: 30), "no smaller than its least")
        XCTAssertEqual(BoardGrip.bottomTrailing.resized(r, by: CGSize(width: 200, height: 0), minimum: min, keepRatio: true),
                       CGRect(x: 0, y: 0, width: 400, height: 200), "⇧ keeps the proportions")
    }

    func testToolsByTheirLetters() {
        XCTAssertEqual(BoardTool(key: "m"), .marker)
        XCTAssertEqual(BoardTool(key: "M"), .highlighter)
        XCTAssertEqual(BoardTool(key: "S"), .column)
        XCTAssertNil(BoardTool(key: "q"))
        XCTAssertFalse(BoardTool.select.takesTheBoard)
        XCTAssertTrue(BoardTool.marker.takesTheBoard)
    }

    // MARK: Magnets

    func testArrowsMeetCardsAtTheirMagnets() {
        let a = CGRect(x: 0, y: 0, width: 200, height: 100), b = CGRect(x: 400, y: 300, width: 200, height: 100)
        XCTAssertEqual(BoardSide.nearest(a, to: CGPoint(x: 195, y: 40)), .right)
        XCTAssertEqual(BoardSide.nearest(a, to: CGPoint(x: 100, y: 130)), .bottom)
        XCTAssertEqual(BoardSide.facing(a, toward: CGPoint(x: 600, y: 60)), .right)
        XCTAssertEqual(BoardSide.facing(a, toward: CGPoint(x: b.midX, y: b.midY)), .bottom, "further down than across, for its size")
        // At the magnets given, leaving and arriving square to their sides.
        let r = BoardRoute.between(a, .bottom, b, .left)
        XCTAssertEqual(r.start, CGPoint(x: 100, y: 100))
        XCTAssertEqual(r.end, CGPoint(x: 400, y: 350))
        XCTAssertEqual(r.c1.x, 100, "straight down out of the bottom")
        XCTAssertGreaterThan(r.c1.y, 100)
        XCTAssertEqual(r.c2.y, 350, "straight into the left side")
        XCTAssertLessThan(r.c2.x, 400)
        // An arrow without magnets takes the sides that face each other.
        XCTAssertEqual(BoardRoute.between(a, nil, b, nil).end, BoardSide.top.anchor(b))
    }

    func testSelectedCardsGoInAContainerThatCarriesThem() {
        var b = JSONCanvas()
        b.nodes = [.init(type: .text, x: 0, y: 0, width: 100, height: 60, text: "a"),
                   .init(type: .text, x: 200, y: 100, width: 100, height: 60, text: "b"),
                   .init(type: .text, x: 900, y: 900, width: 100, height: 60, text: "far")]
        let ids = Set(b.nodes.prefix(2).map(\.id))
        let g = b.group(ids)
        XCTAssertNotNil(g)
        XCTAssertEqual(b.nodes.first?.type, .group, "the container sits under the cards")
        XCTAssertEqual(b.carried([g!]), ids.union([g!]))
        XCTAssertNil(b.group([b.nodes[3].id]), "one card alone is not a group")
    }

    func testAnArrowIsPickedAlongItsLineAndKeepsItsStyle() throws {
        var b = JSONCanvas()
        b.nodes = [.init(type: .text, x: 0, y: 0, width: 100, height: 60, text: "a"),
                   .init(type: .text, x: 400, y: 0, width: 100, height: 60, text: "b")]
        b.edges = [.init(fromNode: b.nodes[0].id, toNode: b.nodes[1].id, color: "1", dashed: true)]
        let mid = try XCTUnwrap(b.route(of: b.edges[0])).middle
        XCTAssertEqual(b.edge(at: mid, within: 8)?.id, b.edges[0].id)
        XCTAssertNil(b.edge(at: CGPoint(x: mid.x, y: mid.y + 80), within: 8))
        let back = try JSONDecoder().decode(JSONCanvas.self, from: JSONEncoder().encode(b))
        XCTAssertEqual(back.edges[0].color, "1")
        XCTAssertEqual(back.edges[0].dashed, true)
    }

    func testABoardIsRenamedInPlaceAndKeepsItsCards() throws {
        let b = try bible()
        let board = try b.createBoard("New board")
        var canvas = JSONCanvas()
        canvas.nodes = [.init(type: .text, x: 0, y: 0, width: 100, height: 60, text: "a")]
        try canvas.write(b.store.url(board.path))
        let moved = try XCTUnwrap(b.renameBoard(board.path, to: "Paris: the canal"))
        XCTAssertEqual(moved, "tableaux/Paris- the canal.canvas")
        XCTAssertEqual(b.entry(path: moved)?.title, "Paris- the canal")
        XCTAssertNil(b.entry(path: board.path))
        XCTAssertEqual(JSONCanvas.read(b.store.url(moved)).nodes.count, 1)
        XCTAssertNil(try b.renameBoard(moved, to: "Paris: the canal"), "the same name changes nothing")
    }
}
