import Foundation
import Observation
import SigilKit

/// Bounded, per-provider proof of executable availability. This owns check
/// generations; window state and saved-tab restoration stay in AppModel.
@MainActor
@Observable
final class ProviderChecks {
    typealias Probe = @Sendable (CLIProvider, URL?) async -> ProviderInstallation
    typealias Sleep = @Sendable (TimeInterval) async throws -> Void
    static let lifetime: TimeInterval = 5 * 60
    static let retryDelays: [TimeInterval] = [5, 15, 45]
    private(set) var installations: [CLIProvider: ProviderInstallation]
    private(set) var checking: Set<CLIProvider> = []
    private struct Receipt {
        let executable: URL?
        let checkedAt: TimeInterval
    }
    @ObservationIgnored private var receipts: [CLIProvider: Receipt] = [:]
    @ObservationIgnored private var generationsByProvider: [CLIProvider: UUID] = [:]
    private struct Waiter {
        let provider: CLIProvider
        let generation: UUID
        let continuation: CheckedContinuation<Void, Never>
    }
    @ObservationIgnored private var waiters: [UUID: Waiter] = [:]
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let probe: Probe
    @ObservationIgnored private let clock: @Sendable () -> TimeInterval
    @ObservationIgnored private let sleep: Sleep
    private struct Recovery {
        let generation: UUID
        let executable: URL?
        let attempts: Int
        var nextAttemptAt: TimeInterval?
        var usedActivation: Bool
    }
    private var recoveries: [CLIProvider: Recovery] = [:]
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var schedulerGeneration = UUID()
    @ObservationIgnored var didFinishChecks: (() -> Void)?

    init(
        settings: AppSettings, installations: [CLIProvider: ProviderInstallation],
        probe: Probe?, clock: (@Sendable () -> TimeInterval)?, sleep: Sleep? = nil
    ) {
        self.settings = settings
        self.installations = installations
        self.clock = clock ?? { ProcessInfo.processInfo.systemUptime }
        self.sleep = sleep ?? { delay in try await Task.sleep(for: .seconds(delay)) }
        self.probe =
            probe ?? { provider, executable in
                await ProviderInstallation.detectAsync(provider: provider, configuredExecutable: executable)
            }
        for (provider, installation) in installations where installation.isAvailable {
            receipts[provider] = .init(executable: configuredExecutable(for: provider), checkedAt: self.clock())
        }
        observeExecutableConfiguration()
    }

    deinit { retryTask?.cancel() }

    private func configuredExecutable(for provider: CLIProvider) -> URL? {
        provider == .grokBuild && !settings.usesInstalledGrok ? settings.executableURL : nil
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
            || (installations[provider]?.timedOut == true && !isRecovering(provider))
    }

    func isRecovering(_ provider: CLIProvider) -> Bool {
        recoveries[provider]?.nextAttemptAt != nil
    }

    /// An exhausted timeout may defer individually. It still offers a manual
    /// Check Again, whereas unknown/stale results must hold restoration.
    func requiresRestorationCheck(_ provider: CLIProvider) -> Bool {
        requiresCheck(provider) && installations[provider]?.timedOut != true
    }

    /// Observation fires before the setting changes. Invalidate synchronously
    /// so even A → B → A cannot resurrect an old result or in-flight callback.
    private func observeExecutableConfiguration() {
        withObservationTracking {
            _ = settings.executablePath
        } onChange: { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let generation = self.generationsByProvider[.grokBuild] {
                    self.finishWaiters(provider: .grokBuild, generation: generation)
                }
                self.generationsByProvider[.grokBuild] = UUID()
                self.receipts[.grokBuild] = nil
                self.installations[.grokBuild] = nil
                self.checking.remove(.grokBuild)
                self.recoveries[.grokBuild] = nil
                self.scheduleNextRetry()
            }
            Task { @MainActor [weak self] in self?.observeExecutableConfiguration() }
        }
    }

    /// CLI lookup and version checks never block window drawing or input.
    /// Explicit refresh replaces all results; routine entry reuses successful
    /// checks for five minutes and coalesces checks already in progress.
    /// An exhausted recovery stays exhausted until an explicit provider check.
    func refresh(force: Bool, only requested: Set<CLIProvider>? = nil) async {
        let providers = CLIProvider.allCases.filter {
            (requested?.contains($0) ?? true)
                && (force || (!checking.contains($0) && recoveries[$0] == nil && !hasFreshProviderCheck($0)))
        }
        await check(providers, retry: false)
    }

    private func check(_ providers: [CLIProvider], retry: Bool) async {
        guard !providers.isEmpty else { return }
        let generations = Dictionary(uniqueKeysWithValues: providers.map { ($0, UUID()) })
        let executables = Dictionary(uniqueKeysWithValues: providers.map { ($0, configuredExecutable(for: $0)) })
        let probe = self.probe
        // A prior result does not authorize launches while its replacement is pending.
        for provider in providers {
            if let previous = generationsByProvider[provider] {
                finishWaiters(provider: provider, generation: previous)
            }
            generationsByProvider[provider] = generations[provider]
            if retry, let previous = recoveries[provider], let generation = generations[provider] {
                recoveries[provider] = .init(
                    generation: generation, executable: executables[provider] ?? nil,
                    attempts: previous.attempts + 1, nextAttemptAt: nil, usedActivation: previous.usedActivation)
            } else {
                recoveries[provider] = nil
            }
            checking.insert(provider)
            installations[provider] = nil
            receipts[provider] = nil
        }
        scheduleNextRetry()
        defer {
            for provider in providers {
                if generationsByProvider[provider] == generations[provider] { checking.remove(provider) }
                if let generation = generations[provider] {
                    finishWaiters(provider: provider, generation: generation)
                }
            }
            scheduleNextRetry()
            didFinishChecks?()
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
            if found[provider]?.timedOut == true, let generation = generations[provider] {
                let previous = recoveries[provider]
                let attempts = previous?.attempts ?? 0
                recoveries[provider] = .init(
                    generation: generation, executable: executables[provider] ?? nil, attempts: attempts,
                    nextAttemptAt: attempts < Self.retryDelays.count ? clock() + Self.retryDelays[attempts] : nil,
                    usedActivation: previous?.usedActivation ?? false)
            } else {
                recoveries[provider] = nil
            }
            checking.remove(provider)
        }
    }

    /// One cancellable wake-up serves all providers. Probes use the same batch
    /// path and generation fences as entry/Settings checks. Cancellation of a
    /// timer never cancels a probe already owned by a different generation.
    private func scheduleNextRetry() {
        retryTask?.cancel()
        retryTask = nil
        schedulerGeneration = UUID()
        guard let deadline = recoveries.values.compactMap(\.nextAttemptAt).min() else { return }
        let token = schedulerGeneration
        let delay = max(0, deadline - clock())
        let sleep = self.sleep
        retryTask = Task { @MainActor [weak self] in
            do { try await sleep(delay) } catch { return }
            guard let self, !Task.isCancelled, self.schedulerGeneration == token else { return }
            self.retryTask = nil
            let providers = CLIProvider.allCases.filter { provider in
                guard let recovery = self.recoveries[provider], let due = recovery.nextAttemptAt else { return false }
                return due <= self.clock() && recovery.generation == self.generationsByProvider[provider]
                    && recovery.executable == self.configuredExecutable(for: provider)
                    && !self.checking.contains(provider)
            }
            if providers.isEmpty {
                self.scheduleNextRetry()
            } else {
                await self.check(providers, retry: true)
            }
        }
    }

    /// The next activation may expedite one pending retry in each bounded
    /// sequence. Bursts never replenish the budget or retry missing/exhausted CLIs.
    func applicationDidBecomeActive() {
        var changed = false
        for provider in CLIProvider.allCases {
            guard var recovery = recoveries[provider], recovery.nextAttemptAt != nil,
                !recovery.usedActivation, !checking.contains(provider)
            else { continue }
            recovery.usedActivation = true
            recovery.nextAttemptAt = clock()
            recoveries[provider] = recovery
            changed = true
        }
        if changed { scheduleNextRetry() }
    }

    /// Join only the generations already pending when this call begins. A
    /// replacement generation remains blocked and needs another launch attempt.
    /// Cancelling a waiter never cancels a check owned by another request.
    func waitForPendingChecks() async {
        let pending = checking.compactMap { provider in
            generationsByProvider[provider].map { (provider, $0) }
        }
        for (provider, generation) in pending {
            guard !Task.isCancelled else { return }
            let id = UUID()
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    guard !Task.isCancelled, checking.contains(provider),
                        generationsByProvider[provider] == generation
                    else {
                        continuation.resume()
                        return
                    }
                    waiters[id] = .init(provider: provider, generation: generation, continuation: continuation)
                }
            } onCancel: {
                Task { @MainActor [weak self] in self?.waiters.removeValue(forKey: id)?.continuation.resume() }
            }
        }
    }

    private func finishWaiters(provider: CLIProvider, generation: UUID) {
        let ids = waiters.filter { $0.value.provider == provider && $0.value.generation == generation }.map(\.key)
        for id in ids { waiters.removeValue(forKey: id)?.continuation.resume() }
    }

    /// Shared by desktop, phone, and restoration. An absent result is unknown,
    /// never permission to launch. Existing open tabs remain usable during checks.
    func problem(_ provider: CLIProvider) -> String? {
        if provider == .grokBuild, !settings.usesInstalledGrok, !settings.executableExists {
            return "The selected Grok executable is unavailable. Choose another path or Use Installed Grok in Settings."
        }
        if checking.contains(provider) { return "Checking \(provider.name)… Try again shortly." }
        if isRecovering(provider) { return "\(provider.name) is still being checked. Try again shortly." }
        guard let installation = installations[provider] else { return "Check \(provider.name) before starting." }
        if installation.timedOut { return "Version check timed out for \(provider.name). Check Again." }
        guard installation.isAvailable else {
            return installation.problem ?? "\(provider.name) is unavailable."
        }
        guard hasFreshProviderCheck(provider) else { return "Check \(provider.name) before starting." }
        return nil
    }

}
