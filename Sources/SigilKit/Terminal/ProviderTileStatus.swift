import Foundation

/// Availability evidence from executable checks. Successful --version output
/// does not establish account authentication or history-format support.
public enum ProviderTileStatus: Equatable, Sendable {
    case available
    case checking
    case checkRequired
    case notInstalled
    case timedOut
    case needsSignIn
    case checkFailed
    case unavailable

    public var caption: String {
        switch self {
        case .available: ""
        case .checking: "Checking…"
        case .checkRequired: "Check required"
        case .notInstalled: "Not installed"
        case .timedOut: "Check timed out"
        case .needsSignIn: "Needs sign-in"
        case .checkFailed: "Check failed"
        case .unavailable: "Unavailable"
        }
    }

    public static func status(
        installation: ProviderInstallation?, isChecking: Bool, requiresCheck: Bool, needsSignIn: Bool
    ) -> Self {
        if isChecking { return .checking }
        guard let installation else { return .checkRequired }
        if installation.timedOut { return .timedOut }
        if installation.failure == .notInstalled { return .notInstalled }
        if installation.failure == .probeFailed { return .checkFailed }
        if !installation.isAvailable { return .unavailable }
        if requiresCheck { return .checkRequired }
        return needsSignIn ? .needsSignIn : .available
    }
}
