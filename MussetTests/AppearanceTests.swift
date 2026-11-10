import AppKit
import XCTest
@testable import Musset

/// Light, dark or as macOS is, from the command bar, kept for the next launch.
@MainActor
final class AppearanceTests: XCTestCase {
    func testChoosingAnAppearance() {
        let saved = UserDefaults.standard.string(forKey: Appearance.key)
        defer { UserDefaults.standard.set(saved, forKey: Appearance.key); Appearance.apply() }
        Appearance.dark.choose()
        XCTAssertEqual(NSApp.appearance?.name, .darkAqua)
        XCTAssertEqual(Appearance.current, .dark, "remembered")
        Appearance.light.choose()
        XCTAssertEqual(NSApp.appearance?.name, .aqua)
        Appearance.system.choose()
        XCTAssertNil(NSApp.appearance, "macOS decides")
    }
}
