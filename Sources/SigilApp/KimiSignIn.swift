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

    /// Delete and add, so the new item's access list trusts this build. A
    /// failed add puts the previous key back.
    @discardableResult func save(_ key: String) -> Bool {
        let previous = load()
        guard clear() else { return false }
        if add(key) { return true }
        if let previous { add(previous) }
        return false
    }

    @discardableResult private func add(_ key: String) -> Bool {
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
    @ObservationIgnored private var run = 0
    @ObservationIgnored private var exitStatus: Int32?
    @ObservationIgnored private var outputEnded = false
    @ObservationIgnored private var isCancelled = false
    @ObservationIgnored private let command: () -> GrokLaunchSpec.HostCommand

    init(command: @escaping () -> GrokLaunchSpec.HostCommand = KimiLogin.loginCommand) {
        self.command = command
    }

    /// `kimi login` through the login shell a Kimi tab uses.
    nonisolated static func loginCommand() -> GrokLaunchSpec.HostCommand {
        GrokLaunchSpec(
            workingDirectory: FileManager.default.homeDirectoryForCurrentUser, mode: .continueLatest,
            extraArguments: ["login"], provider: .kimi
        ).hostCommand()
    }

    func refresh() {
        isSignedIn = KimiCode.isSignedIn
    }

    func start() {
        guard process == nil else { return }
        let command = command()
        let process = Process()
        process.executableURL = command.executable
        process.arguments = command.arguments
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        run += 1
        let current = run
        // The main queue keeps output, its end, and the exit in arrival order.
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            let text = String(decoding: data, as: UTF8.self)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if text.isEmpty { self?.endOutput(run: current) } else { self?.append(text, run: current) }
                }
            }
        }
        process.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.exited(status: status, run: current) }
            }
        }
        output = ""
        exitStatus = nil
        outputEnded = false
        isCancelled = false
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
        isCancelled = true
        process?.interrupt()
    }

    private func append(_ text: String, run: Int) {
        guard run == self.run, case .waiting = state else { return }
        output += text
        let parsed = Self.prompt(in: output)
        state = .waiting(code: parsed.code, page: parsed.page)
    }

    private func endOutput(run: Int) {
        guard run == self.run else { return }
        outputEnded = true
        finish()
    }

    private func exited(status: Int32, run: Int) {
        guard run == self.run else { return }
        exitStatus = status
        if outputEnded {
            finish()
            return
        }
        // A helper that inherited the pipe must not keep Settings waiting.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, run == self.run else { return }
                self.finish()
            }
        }
    }

    private func finish() {
        guard process != nil, let status = exitStatus else { return }
        process = nil
        refresh()
        if status == 0 || isCancelled {
            state = .idle
        } else {
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
