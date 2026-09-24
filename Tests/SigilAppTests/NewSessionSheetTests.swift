import AppKit
import Foundation
import SigilKit
import SwiftUI
import Testing

@testable import SigilApp

struct NewSessionSheetTests {
    private let cliList = """
        You are logged in with grok.com.

        Default model: grok-4.7

        Available models:
          * grok-4.7 (default)
          - grok-4.7-build-fast
          - grok-4.6
          - grok-4.5
        """

    @Test func modelListKeepsTheCLIOrderAndDropsTheProse() {
        #expect(
            GrokModelCatalog.parse(cliList) == [
                "grok-4.7", "grok-4.7-build-fast", "grok-4.6", "grok-4.5",
            ]
        )
    }

    @Test func modelMenuUsesTheCLIListAndKeepsASavedNameThatIsNotListed() {
        let listed = GrokModelCatalog.parse(cliList)
        #expect(GrokModelCatalog.choices(listed: listed, saved: "grok-4.7") == listed)
        #expect(
            GrokModelCatalog.choices(listed: listed, saved: "  grok-custom  ")
                == listed + ["grok-custom"]
        )
    }

    @Test func modelMenuFallsBackWhenTheCLIPrintsNothing() {
        #expect(GrokModelCatalog.parse("not a model list") == [])
        #expect(GrokModelCatalog.choices(listed: [], saved: "") == GrokModelCatalog.fallback)
        #expect(GrokModelCatalog.fallback.contains("grok-4.7"))
    }

    @Test func effortNamesAreWords() {
        #expect(AppSettings.effortLabel("") == "CLI default")
        #expect(AppSettings.effortLabel("low") == "Low")
        #expect(AppSettings.effortLabel("medium") == "Medium")
        #expect(AppSettings.effortLabel("high") == "High")
        #expect(AppSettings.effortLabel("xhigh") == "Extra high")
    }

    @Test func modelAndEffortBelongToGrokOnly() {
        #expect(NewSessionLaunch.showsModelAndEffort(.grokBuild))
        #expect(!NewSessionLaunch.showsModelAndEffort(.cursor))
        #expect(!NewSessionLaunch.showsModelAndEffort(.claudeCode))
        #expect(
            NewSessionLaunch.fields(provider: .grokBuild, model: "grok-4.7", effort: "xhigh")
                == (model: "grok-4.7", effort: "xhigh")
        )
        #expect(
            NewSessionLaunch.fields(provider: .cursor, model: "grok-4.7", effort: "xhigh")
                == (model: "", effort: "")
        )
    }

    @Test func aSecondPressOnTheSelectedProviderStartsIt() {
        #expect(NewSessionLaunch.action(selected: .grokBuild, tapped: .cursor) == .select(.cursor))
        #expect(NewSessionLaunch.action(selected: .cursor, tapped: .cursor) == .start(.cursor))
    }

    @Test func arrowKeysMoveAlongTheProviderRowAndStopAtItsEnds() {
        #expect(NewSessionLaunch.provider(after: .claudeCode, movingBy: 1) == .codex)
        #expect(NewSessionLaunch.provider(after: .grokBuild, movingBy: -1) == .cursor)
        #expect(NewSessionLaunch.provider(after: .grokBuild, movingBy: 1) == .grokBuild)
        #expect(NewSessionLaunch.provider(after: .claudeCode, movingBy: -1) == .claudeCode)
    }

    @Test func pathDataKeepsImplicitCurvesAndArcs() {
        // The second cubic is relative, so it ends 10pt past the first.
        let curve = SVGPath.bounds(of: "M0 0 c0 0 0 0 10 0 0 0 0 0 10 10")
        #expect(abs(curve.width - 20) < 0.01)
        #expect(abs(curve.height - 10) < 0.01)

        let arc = SVGPath.bounds(of: "M10 0 A10 10 0 0 0 0 10")
        #expect(arc.width > 9 && arc.width < 11)
        #expect(arc.height > 9 && arc.height < 11)

        let mark = SVGPath.bounds(of: ProviderMarks.data(for: .grokBuild))
        #expect(mark.width > 20)
        #expect(mark.height > 20)
    }

    @Test(arguments: CLIProvider.allCases)
    func everyProviderHasAFallbackMark(provider: CLIProvider) {
        let box = SVGPath.bounds(of: ProviderMarks.data(for: provider))
        #expect(box.width > 8)
        #expect(box.height > 8)
    }

    @Test func modelDiscoveryUsesTheLoginShell() {
        let zsh = GrokModelCatalog.launch(executable: "/usr/local/bin/grok", shellPath: "/bin/zsh")
        #expect(zsh.executable == "/bin/zsh")
        #expect(
            zsh.arguments == [
                "-lic", "exec \"$@\"", "sigil-grok-models", "/usr/local/bin/grok", "models",
            ]
        )
        // Like a Grok tab, a shell without the -lic launch falls back to zsh.
        let other = GrokModelCatalog.launch(executable: "/usr/local/bin/grok", shellPath: "/bin/tcsh")
        #expect(other.executable == "/bin/zsh")
        #expect(other.arguments == zsh.arguments)
    }

    @Test func aModelNameKeepsNoSurroundingSpace() {
        #expect(GrokModelCatalog.normalized("  grok-4.7  ") == "grok-4.7")
    }

    @Test func stoppingAProcessThatIgnoresTermKillsIt() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "trap '' TERM; sleep 30"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        GrokModelCatalog.stop(process)
        #expect(!process.isRunning)
    }

    @Test(arguments: [CLIProvider.claudeCode, .codex, .devin, .cursor])
    func otherProvidersNeverAskGrokForModels(provider: CLIProvider) {
        #expect(NewSessionLaunch.modelListPath(provider: provider, executablePath: "/opt/grok") == nil)
        #expect(NewSessionLaunch.modelListPath(provider: .grokBuild, executablePath: "/opt/grok") == "/opt/grok")
    }

    @Test func aPathThatListsNoModelsShowsTheFallbackList() async {
        // The menu must not keep the rows of the previous path.
        let models = await GrokModelCatalog.menuModels(executable: URL(fileURLWithPath: "/opt/grok")) { _ in [] }
        #expect(models == GrokModelCatalog.fallback)
    }

    @Test func aCancelledModelLoadChangesNothing() async {
        // SwiftUI cancels the old path's load when the path changes; its late
        // result must not replace the list for the new path.
        let load = Task {
            await GrokModelCatalog.menuModels(executable: URL(fileURLWithPath: "/opt/grok")) { _ in
                try? await Task.sleep(for: .seconds(30))
                return ["grok-old"]
            }
        }
        load.cancel()
        #expect(await load.value == nil)
    }

    /// A stand-in `zsh` that runs the command without reading any profile,
    /// and a fake `grok` with the given script body.
    private func fakeModelsCLI(_ body: String) throws -> (dir: URL, shell: URL, grok: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("grok-models-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let shell = dir.appendingPathComponent("zsh")
        try "#!/bin/sh\nshift\nexec /bin/sh -c \"$@\"\n".write(to: shell, atomically: true, encoding: .utf8)
        let grok = dir.appendingPathComponent("grok")
        try body.write(to: grok, atomically: true, encoding: .utf8)
        for file in [shell, grok] {
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        }
        return (dir, shell, grok)
    }

    @Test func theModelListReturnsWhenABackgroundChildKeepsTheOutputOpen() async throws {
        // A profile helper started in the background inherits stdout and
        // outlives the CLI; the list must not wait for it.
        let cli = try fakeModelsCLI("#!/bin/sh\n/bin/sleep 8 &\necho '* grok-a'\n")
        defer { try? FileManager.default.removeItem(at: cli.dir) }
        let start = ContinuousClock.now
        let models = await GrokModelCatalog.load(executable: cli.grok, shellPath: cli.shell.path)
        #expect(models == ["grok-a"])
        #expect(ContinuousClock.now - start < .seconds(2))
    }

    @Test func cancellingTheModelListStopsTheCLI() async throws {
        let cli = try fakeModelsCLI("#!/bin/sh\necho $$ > \"$0.pid\"\nexec /bin/sleep 30\n")
        defer { try? FileManager.default.removeItem(at: cli.dir) }
        let pidFile = cli.grok.path + ".pid"
        let load = Task {
            await GrokModelCatalog.load(executable: cli.grok, shellPath: cli.shell.path)
        }
        let started = ContinuousClock.now
        while !FileManager.default.fileExists(atPath: pidFile), ContinuousClock.now - started < .seconds(5) {
            try await Task.sleep(for: .milliseconds(20))
        }
        let pid = try #require(
            Int32(try String(contentsOfFile: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        let cancelled = ContinuousClock.now
        load.cancel()
        #expect(await load.value == [])
        #expect(ContinuousClock.now - cancelled < .seconds(1.5))
        let stopDeadline = ContinuousClock.now + .seconds(3)
        while kill(pid, 0) == 0, ContinuousClock.now < stopDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(kill(pid, 0) != 0)
    }

    @Test @MainActor
    func sheetRendersLogosAndGrokOptionsOnlyForGrok() throws {
        _ = NSApplication.shared
        NSApp.appearance = NSAppearance(named: .darkAqua)
        let name = "SigilNewSession.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        settings.model = "grok-4.7"
        settings.effort = "xhigh"
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sigil-sheet-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(
            settings: settings,
            store: SessionStore(root: root.appendingPathComponent("sessions")),
            trashConversation: { _ in },
            presentError: { _ in }
        )
        model.requestNewSession(in: FileManager.default.homeDirectoryForCurrentUser)

        let grok = try png(of: NewSessionSheet(model: model))
        let cursor = try png(of: NewSessionSheet(model: model, provider: .cursor))
        #expect(grok.count > 1000)
        #expect(cursor.count > 1000)
    }

    @Test func providerLogosUseTheInstalledApps() {
        #expect(CLIProvider.claudeCode.applicationBundleID == "com.anthropic.claudefordesktop")
        #expect(CLIProvider.codex.applicationBundleID == "com.openai.codex")
        #expect(CLIProvider.devin.applicationBundleID == "com.exafunction.windsurf")
        #expect(CLIProvider.cursor.applicationBundleID == "com.todesktop.230313mzl4w4u92")
        #expect(CLIProvider.grokBuild.applicationBundleID == nil)
    }
}

@MainActor
private func png(of view: some View) throws -> Data {
    let renderer = ImageRenderer(
        content: view.environment(\.palette, Palette(theme: .sigilDark))
    )
    renderer.scale = 2
    let image = try #require(renderer.nsImage)
    let rep = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
    return try #require(rep.representation(using: .png, properties: [:]))
}
