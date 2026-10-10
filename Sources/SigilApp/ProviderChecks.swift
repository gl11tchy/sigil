import Foundation
import Observation
import SigilKit

/// Bounded, per-provider proof of executable availability. This owns check
/// generations; window state and saved-tab restoration stay in AppModel.
@MainActor
@Observable
final class ProviderChecks {
    typealias Probe = @Sendable (CLIProvider, URL?) async -> ProviderInstallation
    static let lifetime: TimeInterval = 5 * 60
    private(set) var installations: [CLIProvider: ProviderInstallation]
    private(set) var checking: Set<CLIProvider> = []
    private struct Receipt {
        let executable: URL?
        let checkedAt: TimeInterval
    }
    @ObservationIgnored private var receipts: [CLIProvider: Receipt] = [:]
    @ObservationIgnored private var generationsByProvider: [CLIProvider: UUID] = [:]
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let probe: Probe
    @ObservationIgnored private let clock: @Sendable () -> TimeInterval

    init(
        settings: AppSettings, installations: [CLIProvider: ProviderInstallation],
        probe: Probe?, clock: (@Sendable () -> TimeInterval)?
    ) {
        self.settings = settings
        self.installations = installations
        self.clock = clock ?? { ProcessInfo.processInfo.systemUptime }
        self.probe =
            probe ?? { provider, executable in
                await ProviderInstallation.detectAsync(provider: provider, configuredExecutable: executable)
            }
        for (provider, installation) in installations where installation.isAvailable {
            receipts[provider] = .init(executable: configuredExecutable(for: provider), checkedAt: self.clock())
        }
        observeExecutableConfiguration()
    }

    private func configuredExecutable(for provider: CLIProvider) -> URL? {
        provider == .grokBuild ? settings.executableURL : nil
    }

    private func hasFreshProviderCheck(_ provider: CLIProvider) -> Bool {
        guard let installation = installations[provider], installation.isAvailable,
            let executable = installation.executable,
            FileManager.default.isExecutableFile(atPath: executable.path),
            let receipt = receipts[provider],
            receipt.executable == configuredExecutable(for: provider)
        else { return false }
        let age = clock() - receipt.checkedAt
        return age >= 0 && age < Self.lifetime
    }

    /// Unknown or stale successes still need a check before restoration can
    /// skip them. A completed failure may defer individually, as before.
    func requiresCheck(_ provider: CLIProvider) -> Bool {
        installations[provider] == nil
            || (installations[provider]?.isAvailable == true && !hasFreshProviderCheck(provider))
    }

    /// Observation fires before the setting changes. Invalidate synchronously
    /// so even A → B → A cannot resurrect an old result or in-flight callback.
    private func observeExecutableConfiguration() {
        withObservationTracking {
            _ = settings.executablePath
        } onChange: { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.generationsByProvider[.grokBuild] = UUID()
                self.receipts[.grokBuild] = nil
                self.installations[.grokBuild] = nil
                self.checking.remove(.grokBuild)
            }
            Task { @MainActor [weak self] in self?.observeExecutableConfiguration() }
        }
    }

    /// CLI lookup and version checks never block window drawing or input.
    /// Explicit refresh replaces all results; routine entry reuses successful
    /// checks for five minutes and coalesces checks already in progress.
    func refresh(force: Bool) async {
        let providers = CLIProvider.allCases.filter {
            force || (!checking.contains($0) && !hasFreshProviderCheck($0))
        }
        guard !providers.isEmpty else { return }
        let generations = Dictionary(uniqueKeysWithValues: providers.map { ($0, UUID()) })
        let executables = Dictionary(uniqueKeysWithValues: providers.map { ($0, configuredExecutable(for: $0)) })
        let probe = self.probe
        // A prior result does not authorize launches while its replacement is pending.
        for provider in providers {
            generationsByProvider[provider] = generations[provider]
            checking.insert(provider)
            installations[provider] = nil
            receipts[provider] = nil
        }
        defer {
            for provider in providers where generationsByProvider[provider] == generations[provider] {
                checking.remove(provider)
            }
        }
        let found = await withTaskGroup(of: (CLIProvider, ProviderInstallation).self) { group in
            for provider in providers {
                let executable = executables[provider] ?? nil
                group.addTask {
                    let result = await probe(provider, executable)
                    return (provider, result)
                }
            }
            var result: [CLIProvider: ProviderInstallation] = [:]
            for await (provider, installation) in group { result[provider] = installation }
            return result
        }
        guard !Task.isCancelled else { return }
        // Publish together: restoration must keep saved order, not probe completion
        // order, including when a history scan finishes while checks are in flight.
        for provider in providers
        where generationsByProvider[provider] == generations[provider]
            && configuredExecutable(for: provider) == (executables[provider] ?? nil)
        {
            installations[provider] = found[provider]
            if found[provider]?.isAvailable == true {
                receipts[provider] = .init(
                    executable: executables[provider] ?? nil, checkedAt: clock())
            }
            checking.remove(provider)
        }
    }

    /// Shared by desktop, phone, and restoration. An absent result is unknown,
    /// never permission to launch. Existing open tabs remain usable during checks.
    func problem(_ provider: CLIProvider) -> String? {
        if provider == .grokBuild, !settings.executableExists {
            return "Restore the Grok CLI on your Mac, then try again."
        }
        guard !checking.contains(provider), let installation = installations[provider] else {
            return "Checking \(provider.name)… Try again shortly."
        }
        guard installation.isAvailable else {
            return installation.problem ?? "\(provider.name) is unavailable."
        }
        guard hasFreshProviderCheck(provider) else { return "Checking \(provider.name)… Try again shortly." }
        return nil
    }

}
