import Foundation
import Observation

/// Whether Musset shows its AI features: the claude / codex CLIs found on this Mac,
/// and the author's "AI: off" switch in Settings. With neither CLI, or AI off, the chat panel,
/// Annotate, the plot grid's update, scene proposals and AI proofreading disappear;
/// everything else works the same.
@Observable
final class AIStatus {
    static let shared = AIStatus()
    static let enabledKey = "aiEnabled"

    /// The CLIs found on this Mac; empty until `detect()` has run.
    var installed: [AgentKind]
    var enabled: Bool {
        didSet { defaults.set(enabled, forKey: Self.enabledKey) }
    }
    @ObservationIgnored private let defaults: UserDefaults

    init(installed: [AgentKind] = [], defaults: UserDefaults = .standard) {
        self.installed = installed
        self.defaults = defaults
        enabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    /// The engines the interface offers.
    var engines: [AgentKind] { enabled ? installed : [] }
    var isOn: Bool { !engines.isEmpty }

    /// The author's choice when it is available, else the first engine there is.
    func engine(preferring kind: AgentKind?) -> AgentKind? {
        if let kind, engines.contains(kind) { return kind }
        return engines.first
    }

    /// Looks for the CLIs on the login PATH, off the main thread (the PATH comes from a login shell).
    func detect() async {
        let found = await Task.detached { Self.detect(Shell.which) }.value
        await MainActor.run { installed = found }
    }

    static func detect(_ which: (String) -> String?) -> [AgentKind] {
        AgentKind.allCases.filter { which($0.rawValue) != nil }
    }
}
