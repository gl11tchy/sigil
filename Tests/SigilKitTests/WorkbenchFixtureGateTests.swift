import Foundation
import Testing

/// Fixture-only workbench code must never reach a release build. These read
/// the app's sources, since the app target cannot be tested without windows.
struct WorkbenchFixtureGateTests {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private static func sources() throws -> [(name: String, text: String)] {
        let folder = root.appendingPathComponent("Sources/SigilApp")
        let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        return try files.map { ($0.lastPathComponent, try String(contentsOf: $0, encoding: .utf8)) }
    }

    @Test func fixtureFilesAreDebugOnlyFromTopToBottom() throws {
        for name in ["WorkbenchFixture.swift", "WorkbenchReferenceRoot.swift"] {
            let file = try #require(try Self.sources().first { $0.name == name }, "\(name) is missing")
            let lines = file.text.split(separator: "\n", omittingEmptySubsequences: true)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            #expect(lines.first == "#if DEBUG", "\(name) must open with #if DEBUG")
            #expect(lines.last == "#endif", "\(name) must close its #if DEBUG")
        }
    }

    @Test func onlyDebugCodeNamesTheFixtures() throws {
        let fixtureNames = ["WorkbenchFixture", "WorkbenchReferenceRoot", "SIGIL_WORKBENCH_"]
        for file in try Self.sources()
        where !["WorkbenchFixture.swift", "WorkbenchReferenceRoot.swift"].contains(file.name) {
            var depth = 0
            for line in file.text.split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces) }) {
                if line.hasPrefix("#if DEBUG") { depth += 1 }
                if line.hasPrefix("#else"), depth > 0 { depth -= 1 }
                if line.hasPrefix("#endif"), depth > 0 { depth -= 1 }
                if depth == 0, !line.hasPrefix("//"), let name = fixtureNames.first(where: { line.contains($0) }) {
                    Issue.record("\(file.name) names \(name) outside #if DEBUG: \(line)")
                }
            }
        }
    }
}
