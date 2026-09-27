import Darwin
import Foundation
import Observation
import SigilKit

/// Builds the app model once `GROK_HOME` is known.
///
/// A Dock launch lacks the profile's GROK_HOME, but the CLI, started through
/// the login shell, has it. Reading it runs the user's shell profile, which
/// can take up to the probe's two-second ceiling, so the probe runs off the
/// main thread while the window shows only its background. The model, and
/// with it the session scan, restored tabs, CLI launches and remote resume,
/// exists only after the probe answers and its GROK_HOME is adopted.
@MainActor
@Observable
final class AppLaunch {
    typealias Probe = @Sendable ([String: String]) -> String?

    /// Nil while the login shell is still being read.
    private(set) var model: AppModel?
    /// True once the wait passes `slowAfter`. The window may show a spinner.
    private(set) var isSlow = false
    /// Work asked of the model before it existed, in the order it was asked.
    @ObservationIgnored private var waiting: [(AppModel) -> Void] = []
    @ObservationIgnored private let adopt: (String) -> Void
    @ObservationIgnored private let makeModel: () -> AppModel

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        slowAfter: Duration = .milliseconds(500),
        // Optional defaults, coalesced below: Swift 6.1.2 (CI) segfaults in
        // SILGen when these closures are default argument expressions.
        probe: Probe? = nil,
        adopt: ((String) -> Void)? = nil,
        makeModel: (() -> AppModel)? = nil
    ) {
        self.adopt = adopt ?? { setenv("GROK_HOME", $0, 1) }
        self.makeModel = makeModel ?? { AppModel() }
        // Already set: nothing to read, so the model exists before the window.
        guard environment["GROK_HOME"]?.isEmpty ?? true else {
            model = self.makeModel()
            return
        }
        let probe = probe ?? { GrokPaths.loginShellGrokHome(environment: $0) }
        Task { [weak self] in
            let grokHome = await Self.run(probe, environment: environment)
            self?.finish(grokHome: grokHome)
        }
        Task { [weak self] in
            try? await Task.sleep(for: slowAfter)
            guard let self, self.model == nil else { return }
            self.isSlow = true
        }
    }

    /// Runs `action` now when the model exists, else once it does.
    func whenReady(_ action: @escaping (AppModel) -> Void) {
        if let model {
            action(model)
        } else {
            waiting.append(action)
        }
    }

    private func finish(grokHome: String?) {
        if let grokHome { adopt(grokHome) }
        let model = makeModel()
        self.model = model
        let actions = waiting
        waiting = []
        for action in actions { action(model) }
    }

    /// The probe blocks its thread until the shell answers or its ceiling
    /// passes, so it gets a dispatch thread, not one from the Swift pool.
    private nonisolated static func run(
        _ probe: @escaping Probe, environment: [String: String]
    ) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: probe(environment))
            }
        }
    }
}
