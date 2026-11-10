import AppKit
import XCTest
@testable import Musset

@MainActor
final class ChatTests: XCTestCase {
    private func key(_ tv: NSTextView, _ mods: NSEvent.ModifierFlags) {
        let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0, windowNumber: tv.window?.windowNumber ?? 0,
                                 context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
        tv.keyDown(with: e)
    }

    func testComposerReturnSendsAndModifiedReturnBreaksLine() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        let tv = ComposerTextView(usingTextLayoutManager: false)
        tv.frame = window.contentView!.bounds
        window.contentView!.addSubview(tv)
        var sent = 0
        tv.onSend = { sent += 1 }
        tv.string = "Bonjour"
        tv.setSelectedRange(NSRange(location: 7, length: 0))
        key(tv, .shift)
        key(tv, .command)
        key(tv, .option)
        XCTAssertEqual(tv.string, "Bonjour\n\n\n")
        XCTAssertEqual(sent, 0)
        key(tv, [])
        XCTAssertEqual(sent, 1)
    }

    /// Live: two messages in a row with Claude Haiku; both are answered, in order. Opt in with MUSSET_LIVE=1.
    func testLiveQueuedMessages() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MUSSET_LIVE"] == "1")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("musset-chat-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "# Un\n\nLa mer était grise.\n".write(to: root.appendingPathComponent("01.md"), atomically: true, encoding: .utf8)
        let session = BookSession(root: root, manifest: BookManifest(title: "T", chapters: [ChapterEntry(id: "01", file: "01.md", title: "Un")]))
        let chat = ChatModel()
        chat.attach(root)
        let start = Date()
        chat.input = "Quelle est la couleur de la mer dans le chapitre ? Un mot."
        chat.send(session: session, selection: "", model: "haiku")
        chat.input = "Et en anglais ? Un mot."
        chat.send(session: session, selection: "", model: "haiku")
        XCTAssertEqual(chat.messages.last?.queued, true)
        var firstWord: TimeInterval?
        while Date().timeIntervalSince(start) < 120 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            if firstWord == nil, chat.messages.contains(where: { $0.role == .assistant && !$0.text.isEmpty }) { firstWord = Date().timeIntervalSince(start) }
            if !chat.running && chat.messages.filter({ $0.role == .assistant }).count == 2 { break }
        }
        for m in chat.messages { print("CHAT \(m.role) \(m.text.prefix(80))") }
        print("CHAT first word after \(firstWord ?? -1)s, both answered after \(Date().timeIntervalSince(start))s")
        let answers = chat.messages.filter { $0.role == .assistant }.map { $0.text.lowercased() }
        XCTAssertEqual(answers.count, 2)
        XCTAssertTrue(answers[0].contains("gris"))
        XCTAssertTrue(answers[1].contains("grey") || answers[1].contains("gray"))
    }
}
