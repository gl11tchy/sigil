import Foundation

/// Model ids `grok models` prints, plus the names the menus show.
enum GrokModelCatalog: Sendable {
    /// Used when the CLI is missing or its list cannot be read.
    static let fallback = ["grok-4.7", "grok-4.7-build-fast", "grok-4.6", "grok-4.5"]

    /// Bullet rows from `grok models`. Prose and the "(default)" note are dropped.
    static func parse(_ output: String) -> [String] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let first = trimmed.first, first == "*" || first == "-" else { return nil }
            var name = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
            if let note = name.firstIndex(of: "(") {
                name = String(name[..<note]).trimmingCharacters(in: .whitespaces)
            }
            guard !name.isEmpty, name.count <= 64, !name.contains(where: \.isWhitespace) else {
                return nil
            }
            return String(name)
        }
    }

    /// Menu rows. A saved name that the CLI does not list stays selectable.
    static func choices(listed: [String], saved: String) -> [String] {
        var result = listed.isEmpty ? fallback : listed
        let saved = saved.trimmingCharacters(in: .whitespacesAndNewlines)
        if !saved.isEmpty, !result.contains(saved) {
            result.append(saved)
        }
        return result
    }

    /// Runs `grok models`. Empty when the CLI is missing, slow, or prints no rows.
    static func load(executable: URL) async -> [String] {
        let path = executable.path
        return await Task.detached(priority: .utility) {
            runModels(at: path)
        }.value
    }

    private static func runModels(at path: String) -> [String] {
        guard FileManager.default.isExecutableFile(atPath: path) else { return [] }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["models"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return []
        }
        let deadline = Date().addingTimeInterval(3)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            process.terminate()
            return []
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else { return [] }
        return parse(String(decoding: data, as: UTF8.self))
    }
}
