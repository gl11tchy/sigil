import Foundation
import SigilKit
import Testing

@testable import SigilApp

@Suite(.serialized)
struct SettingsViewTests {
    @Test func themeGridRowsCoverEveryThemeInOrder() {
        let rows = ThemeGrid.rows(TerminalTheme.all)
        #expect(rows.allSatisfy { $0.themes.count <= ThemeGrid.columns })
        #expect(rows.contains { $0.themes.count == ThemeGrid.columns })
        #expect(rows.flatMap(\.themes) == TerminalTheme.all)
        #expect(rows.count >= 5)
    }

    @Test @MainActor
    func typingATransientValidPathDoesNotCommitUntilSubmit() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let grok = try makeExecutable(in: root, name: "grok")
        let grokNew = try makeExecutable(in: root, name: "grok-new")
        #expect(grokNew.path.hasPrefix(grok.path))

        var session = PathFieldSession(stored: grokNew.path)
        var current = grokNew.path
        while current != grok.path {
            current.removeLast()
            session.type(current)
            #expect(session.stored == grokNew.path)
            #expect(session.configurationChangeCount == 0)
        }
        #expect(AppSettings.isExecutableFile(at: URL(fileURLWithPath: session.draft.text)))

        session.pressReturn()
        #expect(session.stored == grok.path)
        #expect(session.configurationChangeCount == 1)
        #expect(session.lastError == nil)
    }

    @Test @MainActor
    func focusLossCommitsAValidPathTheSameAsReturn() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let grok = try makeExecutable(in: root, name: "grok")
        let grokNew = try makeExecutable(in: root, name: "grok-new")

        var session = PathFieldSession(stored: grok.path)
        session.type(grokNew.path)
        #expect(session.configurationChangeCount == 0)

        session.resignFocus()
        #expect(session.stored == grokNew.path)
        #expect(session.configurationChangeCount == 1)
    }

    @Test @MainActor
    func invalidOrEmptyCommitLeavesStoredPathUnchanged() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let grok = try makeExecutable(in: root, name: "grok")
        var session = PathFieldSession(stored: grok.path)

        session.type("")
        session.pressReturn()
        #expect(session.stored == grok.path)
        #expect(session.configurationChangeCount == 0)
        #expect(session.lastError == "Choose an executable file.")

        session.type(root.path)
        session.resignFocus()
        #expect(session.stored == grok.path)
        #expect(session.configurationChangeCount == 0)
        #expect(session.lastError == "Choose an executable file.")

        session.type(root.appendingPathComponent("missing").path)
        session.pressReturn()
        #expect(session.stored == grok.path)
        #expect(session.configurationChangeCount == 0)
        #expect(session.lastError == "Choose an executable file.")
    }

    @Test @MainActor
    func submittingTheAlreadyStoredPathDoesNotReapply() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let grok = try makeExecutable(in: root, name: "grok")
        var session = PathFieldSession(stored: grok.path)
        session.pressReturn()
        #expect(session.configurationChangeCount == 0)
        #expect(session.lastError == nil)
    }

    @Test @MainActor
    func leavingAnUntouchedMissingPathRaisesNoError() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        // A user without Grok keeps the default path, which does not exist.
        let missing = root.appendingPathComponent("bin/grok").path
        var session = PathFieldSession(stored: missing)
        session.pressReturn()
        #expect(session.lastError == nil)
        session.resignFocus()
        #expect(session.lastError == nil)
        #expect(session.stored == missing)
        #expect(session.configurationChangeCount == 0)
    }

    @Test @MainActor
    func paddedValidPathCommitsTheNormalizedString() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let grok = try makeExecutable(in: root, name: "grok")
        var session = PathFieldSession(stored: "/bin/echo")
        session.type("  \(grok.path)  ")
        session.pressReturn()
        #expect(session.stored == grok.path)
        #expect(session.configurationChangeCount == 1)
        #expect(session.lastError == nil)
    }
}

/// Mirrors SettingsView: keystrokes mutate the draft; Return/focus-loss call `commit`.
@MainActor
private struct PathFieldSession {
    var draft: ExecutablePathDraft
    private(set) var stored: String
    private(set) var configurationChangeCount = 0
    private(set) var lastError: String?

    init(stored: String) {
        self.stored = stored
        self.draft = ExecutablePathDraft(text: stored)
    }

    mutating func type(_ text: String) {
        draft.text = text
    }

    mutating func pressReturn() {
        applyCommit()
    }

    mutating func resignFocus() {
        applyCommit()
    }

    private mutating func applyCommit() {
        lastError = nil
        switch draft.commit(stored: stored) {
        case .applied(let path):
            stored = path
            configurationChangeCount += 1
        case .unchanged:
            break
        case .rejected:
            lastError = "Choose an executable file."
        }
    }
}

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func makeExecutable(in root: URL, name: String) throws -> URL {
    let url = root.appendingPathComponent(name)
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: Int16(0o700))],
        ofItemAtPath: url.path
    )
    return url
}
