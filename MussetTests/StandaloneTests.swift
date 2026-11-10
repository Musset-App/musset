import XCTest
@testable import Musset

/// Musset with nothing installed: bundled tools, and AI that can be absent or switched off.
final class StandaloneTests: XCTestCase {
    func testBundledToolWinsOverPath() throws {
        let res = FileManager.default.temporaryDirectory.appendingPathComponent("musset-res-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: res) }
        let bin = res.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let tool = bin.appendingPathComponent("pandoc")
        try "#!/bin/sh\n".write(to: tool, atomically: true, encoding: .utf8)
        // Not executable: not used.
        XCTAssertNotEqual(Shell.bundledOrPath("pandoc", resources: res), tool.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        XCTAssertEqual(Shell.bundledOrPath("pandoc", resources: res), tool.path)
        // Nothing bundled: the PATH, then nothing.
        XCTAssertEqual(Shell.bundledOrPath("ls", resources: res), Shell.which("ls"))
        XCTAssertNil(Shell.bundledOrPath("musset-no-such-tool", resources: res))
    }

    func testAppShipsPandocAndTypst() throws {
        let resources = try XCTUnwrap(Bundle.main.resourceURL)
        for tool in ["pandoc", "typst"] {
            let path = resources.appendingPathComponent("bin/\(tool)").path
            guard FileManager.default.isExecutableFile(atPath: path) else {
                throw XCTSkip("\(tool) was not bundled in this build (offline build?)")
            }
        }
        XCTAssertEqual(ExportService.pandoc, resources.appendingPathComponent("bin/pandoc").path)
        XCTAssertEqual(TypstRunner.binary, resources.appendingPathComponent("bin/typst").path)
    }

    private func defaults() -> UserDefaults {
        let name = "musset-ai-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    func testNoCLIMeansNoAI() {
        XCTAssertEqual(AIStatus.detect { _ in nil }, [])
        XCTAssertEqual(AIStatus.detect { $0 == "codex" ? "/usr/local/bin/codex" : nil }, [.codex])
        let ai = AIStatus(installed: [], defaults: defaults())
        XCTAssertTrue(ai.enabled)
        XCTAssertFalse(ai.isOn)
        XCTAssertEqual(ai.engines, [])
        XCTAssertNil(ai.engine(preferring: .claude))
    }

    func testOnlyOneCLI() {
        let ai = AIStatus(installed: [.codex], defaults: defaults())
        XCTAssertTrue(ai.isOn)
        XCTAssertEqual(ai.engine(preferring: .claude), .codex)
        XCTAssertEqual(ai.engine(preferring: nil), .codex)
    }

    func testAIOffSwitch() {
        let d = defaults()
        let ai = AIStatus(installed: [.claude, .codex], defaults: d)
        XCTAssertEqual(ai.engine(preferring: .codex), .codex)
        ai.enabled = false
        XCTAssertFalse(ai.isOn)
        XCTAssertEqual(ai.engines, [])
        XCTAssertNil(ai.engine(preferring: .claude))
        // Remembered.
        XCTAssertFalse(AIStatus(installed: [.claude], defaults: d).isOn)
    }
}
