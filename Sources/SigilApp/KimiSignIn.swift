import Foundation
import Observation
import Security
import SigilKit

/// How Kimi Code tabs sign in.
enum KimiSignIn: String, CaseIterable, Identifiable, Sendable {
    /// The Kimi account `kimi login` stored, on the Kimi Code plan.
    case kimiAccount
    /// A Kimi Platform API key, kept in the Keychain.
    case apiKey

    var id: String { rawValue }

    var label: String {
        switch self {
        case .kimiAccount: "Kimi account"
        case .apiKey: "API key"
        }
    }
}

enum KimiCode {
    static let defaultModel = "kimi-k3"

    /// Kimi Code reads an API key only from config.toml or `KIMI_MODEL_*`.
    /// These variables define the model in memory and leave config.toml alone.
    static func apiKeyEnvironment(key: String, model: String) -> [String: String] {
        let name = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return [
            "KIMI_MODEL_NAME": name.isEmpty ? defaultModel : name,
            "KIMI_MODEL_API_KEY": key,
        ]
    }

    /// Where `kimi login` writes the Kimi account token.
    static func accountCredentials(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        let home =
            environment["KIMI_CODE_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".kimi-code")
        return home.appendingPathComponent("credentials/kimi-code.json")
    }

    static var isSignedIn: Bool {
        FileManager.default.fileExists(atPath: accountCredentials().path)
    }
}

protocol KimiKeyStore: AnyObject {
    func load() -> String?
    /// Returns false when the key was not stored.
    @discardableResult func save(_ key: String) -> Bool
    @discardableResult func clear() -> Bool
}

final class InMemoryKimiKeyStore: KimiKeyStore {
    private var key: String?

    func load() -> String? { key }
    @discardableResult func save(_ key: String) -> Bool {
        self.key = key
        return true
    }
    @discardableResult func clear() -> Bool {
        key = nil
        return true
    }
}

final class KeychainKimiKeyStore: KimiKeyStore {
    private let service: String
    private let account = "api-key"

    init(service: String = "app.sigil.kimi") {
        self.service = service
    }

    func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
            let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)?.nilIfEmpty
    }

    /// Delete and add, so the new item's access list trusts this build.
    @discardableResult func save(_ key: String) -> Bool {
        guard clear() else { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(key.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult func clear() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

/// Runs `kimi login`, which opens the browser and waits for the device code.
@MainActor
@Observable
final class KimiLogin {
    enum State: Equatable {
        case idle
        case waiting(code: String?, page: URL?)
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var isSignedIn = KimiCode.isSignedIn
    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var output = ""

    func refresh() {
        isSignedIn = KimiCode.isSignedIn
    }

    func start() {
        guard process == nil else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let spec = GrokLaunchSpec(
            workingDirectory: home, mode: .continueLatest, extraArguments: ["login"], provider: .kimi)
        let command = spec.hostCommand()
        let process = Process()
        process.executableURL = command.executable
        process.arguments = command.arguments
        process.environment = spec.environment()
        process.currentDirectoryURL = home
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let text = String(decoding: handle.availableData, as: UTF8.self)
            guard !text.isEmpty else { return }
            Task { @MainActor in self?.append(text) }
        }
        process.terminationHandler = { [weak self] finished in
            pipe.fileHandleForReading.readabilityHandler = nil
            let status = finished.terminationStatus
            Task { @MainActor in self?.finish(status: status) }
        }
        output = ""
        do {
            try process.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            state = .failed("Could not start Kimi Code.")
            return
        }
        self.process = process
        state = .waiting(code: nil, page: nil)
    }

    func cancel() {
        process?.interrupt()
    }

    private func append(_ text: String) {
        guard case .waiting = state else { return }
        output += text
        let parsed = Self.prompt(in: output)
        state = .waiting(code: parsed.code, page: parsed.page)
    }

    private func finish(status: Int32) {
        process = nil
        refresh()
        if status == 0, isSignedIn {
            state = .idle
        } else if case .waiting = state {
            state = .failed(Self.failure(in: output, status: status))
        }
    }

    /// The code and page `kimi login` prints for the browser step.
    nonisolated static func prompt(in output: String) -> (code: String?, page: URL?) {
        var code: String?
        var page: URL?
        for line in output.split(whereSeparator: \.isNewline) {
            if let range = line.range(of: "enter code:") {
                code = line[range.upperBound...].trimmingCharacters(in: .whitespaces).nilIfEmpty
            }
            if page == nil, let start = line.range(of: "https://") {
                let link = line[start.lowerBound...].prefix { !$0.isWhitespace }
                page = URL(string: String(link))
            }
        }
        return (code, page)
    }

    /// The CLI's last line, or a plain fallback when it printed nothing.
    nonisolated static func failure(in output: String, status: Int32) -> String {
        let last = output.split(whereSeparator: \.isNewline).last.map(String.init)?.nilIfEmpty
        if status == 127 || last?.contains("command not found") == true {
            return "Kimi Code is not installed."
        }
        return last ?? "Sign-in did not finish."
    }
}
