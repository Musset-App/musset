import Sparkle
import SwiftUI

/// Updates outside the App Store, through Sparkle: the feed at musset.app/appcast.xml, each release signed with the
/// project's EdDSA key (its public half is SUPublicEDKey in Info.plist). Debug builds and tests never look on their own.
@MainActor
final class Updates {
    static let shared = Updates()
    private let controller: SPUStandardUpdaterController

    private init() {
        #if DEBUG
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        #else
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        #endif
    }

    /// Starts the updater in a release build (called at launch): it checks once a day, asking first.
    func start() { _ = controller }

    /// Musset ▸ Check for Updates…
    func check() {
        // A debug build's updater isn't started until asked.
        if !controller.updater.canCheckForUpdates { try? controller.updater.start() }
        controller.checkForUpdates(nil)
    }
}
