import XCTest
import SwiftUI
@testable import Musset

final class ModelSettingsTests: XCTestCase {
    func testLegacySettingsCarryOver() {
        let d = UserDefaults(suiteName: "musset-models-\(UUID().uuidString)")!
        d.set("sonnet", forKey: "claudeModel")
        d.set("codex", forKey: "proofEngine")
        XCTAssertEqual(TaskModels.model(.chat, for: .claude, defaults: d), "sonnet")
        XCTAssertEqual(TaskModels.model(.annotate, for: .claude, defaults: d), "sonnet", "annotations used the chat's model")
        XCTAssertEqual(TaskModels.model(.proof, for: .claude, defaults: d), "haiku")
        XCTAssertEqual(TaskModels.model(.plot, for: .claude, defaults: d), "opus")
        XCTAssertEqual(TaskModels.model(.plot, for: .codex, defaults: d), "", "codex: its own default")
        XCTAssertEqual(TaskModels.preferredEngine(.proof, defaults: d), .codex)
        TaskModels.migrate(d)
        XCTAssertEqual(d.string(forKey: "model.chat.claude"), "sonnet")
    }

    func testChoiceIsPerTaskAndEngine() {
        let d = UserDefaults(suiteName: "musset-models-\(UUID().uuidString)")!
        TaskModels.set(.annotate, engine: .codex, model: "gpt-6-astra", defaults: d)
        XCTAssertEqual(TaskModels.preferredEngine(.annotate, defaults: d), .codex)
        XCTAssertEqual(TaskModels.model(.annotate, for: .codex, defaults: d), "gpt-6-astra")
        XCTAssertEqual(TaskModels.model(.annotate, for: .claude, defaults: d), "opus", "the other engine keeps its own")
        XCTAssertNil(TaskModels.preferredEngine(.chat, defaults: d))
    }

    /// Live: codex's app-server lists its models. MUSSET_LIVE=1.
    func testLiveCodexModels() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MUSSET_LIVE"] == "1")
        let models = ModelCatalog.codexModels()
        print("CODEX MODELS", models.map { $0.id + ($0.isDefault ? "*" : "") })
        XCTAssertFalse(models.isEmpty)
        XCTAssertEqual(models.filter(\.isDefault).count, 1)
    }

    /// Each settings pane, rendered. MUSSET_SNAPSHOT=<dir>.
    @MainActor
    func testSettingsSnapshot() throws {
        guard let dir = ProcessInfo.processInfo.environment["MUSSET_SNAPSHOT"] else { throw XCTSkip("set MUSSET_SNAPSHOT") }
        AIStatus.shared.installed = [.claude, .codex]
        for pane in SettingsView.Pane.allCases {
            let host = NSHostingView(rootView: SettingsView(pane: pane).font(.ui(13)))
            host.appearance = NSAppearance(named: .aqua)
            host.frame = NSRect(x: 0, y: 0, width: 860, height: 600)
            let w = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            w.contentView = host
            RunLoop.main.run(until: Date().addingTimeInterval(pane == .ai || pane == .advanced ? 3 : 0.4))
            let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: dir).appendingPathComponent("settings-\(pane.rawValue).png"))
        }
    }
}
