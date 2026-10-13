import Foundation
import SigilKit

/// Shared by inline, Options and phone starts. A false launch return means
/// AppModel rejected the request before constructing/starting a terminal tab.
/// After a true return, even a lost or cancelled reply must retain the workspace.
@MainActor
enum SessionWorktreeStart {
    enum Result: Sendable {
        case started
        case failed(String)
        case retained(String)

        var message: String? {
            switch self {
            case .started: nil
            case .failed(let message), .retained(let message): message
            }
        }

        var needsRecovery: Bool {
            if case .retained = self { return true }
            return false
        }
    }

    static func start(
        project: URL, useWorktree: Bool, root: URL = SigilWorktree.root,
        create: @MainActor (URL, URL) async throws -> SigilWorktree.Creation? = {
            try await SigilWorktree.createAttempt(for: $0, root: $1)
        },
        validate: @MainActor () async -> String?, launch: @MainActor (URL) -> Bool
    ) async -> Result {
        guard !Task.isCancelled else { return .failed("Session launch was cancelled.") }
        let receipt: SigilWorktree.Creation?
        do {
            receipt = useWorktree ? try await create(project, root) : nil
        } catch {
            // Creation errors can include partial Git resources. Keep their
            // recovery details visible even if cancellation arrived meanwhile.
            let message = "Could not create a worktree. \(error.localizedDescription)"
            if (error as? SigilWorktree.Failure)?.recovery != nil { return .retained(message) }
            return .failed(message)
        }
        let problem = await validate()
        let reason = Task.isCancelled ? "Session launch was cancelled." : problem
        if let reason { return await failed(reason, receipt: receipt) }
        // No suspension between the final validation and dispatch. A non-nil
        // tab may start asynchronously, so it is never rolled back here.
        if launch(receipt?.workingDirectory ?? project) { return .started }
        return await failed("Could not start a session. Check Sigil on your Mac.", receipt: receipt)
    }

    private static func failed(_ reason: String, receipt: SigilWorktree.Creation?) async -> Result {
        guard let receipt else { return .failed(reason) }
        let rollback = await SigilWorktree.rollback(receipt, processMayHaveStarted: false)
        if let recovery = rollback.recoveryMessage { return .retained("\(reason) \(recovery)") }
        return .failed(reason)
    }
}
