import AppKit
import Foundation
import SwiftUI
import Testing

@testable import SigilApp
@testable import SigilKit

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
        #expect(AppSettings.effortLabel("extra-high") == "Extra high")
        #expect(AppSettings.effortLabel("max") == "Max")
        #expect(AppSettings.effortLabel("none") == "None")
    }

    @MainActor
    @Test func everyCLIButKimiHasModelAndEffortMenus() throws {
        func menu(_ provider: CLIProvider) -> ProviderModelMenu? {
            NewSessionLaunch.menu(for: provider, grokModels: ["grok-4.7"], grokModel: "grok-old", loaded: nil)
        }
        #expect(menu(.kimi) == nil)
        let grok = try #require(menu(.grokBuild))
        #expect(grok.models.map(\.id) == ["", "grok-4.7", "grok-old"])
        #expect(grok.hasEffort && !grok.hasFastMode)
        #expect(
            grok.launch(.init(model: "grok-4.7", effort: "xhigh", fast: true))
                == (model: "grok-4.7", effort: "xhigh", fastMode: false))
        let claude = try #require(menu(.claudeCode))
        #expect(claude.hasEffort && claude.hasFastMode)
        #expect(
            claude.launch(.init(model: "opus", effort: "max", fast: true))
                == (model: "opus", effort: "max", fastMode: true))
        // Fast mode runs Opus, so another alias drops it.
        #expect(
            claude.launch(.init(model: "sonnet", effort: "", fast: true))
                == (model: "sonnet", effort: "", fastMode: false))
        // Until Codex lists its models, its default may be one without a fast tier.
        #expect(try !#require(menu(.codex)).hasFastMode)
        // Before its list loads, Cursor offers only its own default.
        #expect(try #require(menu(.cursor)).models.map(\.id) == [""])
        let loaded = ProviderModelMenu(models: [.init(id: "", efforts: [""], hasFastMode: false)])
        #expect(NewSessionLaunch.menu(for: .devin, grokModels: [], grokModel: "", loaded: loaded) == loaded)
    }

    @Test func codexListsItsModelsEffortsAndFastTier() throws {
        let output = """
            {"models":[
              {"slug":"gpt-6-astra","visibility":"list","supported_reasoning_levels":[{"effort":"low"},{"effort":"medium"},{"effort":"max"}],"additional_speed_tiers":["fast"]},
              {"slug":"gpt-5.5","visibility":"list","supported_reasoning_levels":[{"effort":"low"},{"effort":"medium"}],"additional_speed_tiers":[]},
              {"slug":"codex-auto-review","visibility":"hide","supported_reasoning_levels":[{"effort":"low"}]}
            ]}
            """
        let menu = try #require(ProviderModelCatalog.codexMenu("[oh-my-zsh] Update available\n" + output))
        #expect(menu.models.map(\.id) == ["", "gpt-6-astra", "gpt-5.5"])
        #expect(menu.model("")?.efforts == ["", "low", "medium"])
        // The CLI default may be gpt-5.5, which has no fast tier.
        #expect(menu.model("")?.hasFastMode == false)
        #expect(menu.model("gpt-6-astra")?.efforts == ["", "low", "medium", "max"])
        #expect(menu.model("gpt-5.5")?.hasFastMode == false)
        // An effort the new model lacks falls back to the CLI default, and fast turns off.
        #expect(
            menu.normalized(.init(model: "gpt-5.5", effort: "max", fast: true))
                == .init(model: "gpt-5.5", effort: "", fast: false))
        #expect(ProviderModelCatalog.codexMenu("not json") == nil)
    }

    @Test func cursorFoldsEffortAndSpeedIdsIntoOneModel() throws {
        let output = """
            Available models

            auto - Auto (default)
            gpt-5.3-codex-low - Codex 5.3 Low
            gpt-5.3-codex - Codex 5.3
            gpt-5.3-codex-fast - Codex 5.3 Fast
            gpt-5.3-codex-xhigh - Codex 5.3 Extra High
            claude-opus-5-5-medium - Claude Opus 5.5 1M
            claude-opus-5-5-medium-fast - Claude Opus 5.5 1M Fast
            claude-opus-5-5-high - Claude Opus 5.5 1M High
            gpt-5.6-luna-high-fast - GPT-5.6 Luna 1M High Fast

            Tip: use --model <id> (or /model <id> in interactive mode) to switch.
            """
        let menu = try #require(ProviderModelCatalog.cursorMenu(output))
        #expect(menu.models.map(\.id) == ["", "auto", "gpt-5.3-codex", "claude-opus-5-5", "gpt-5.6-luna"])
        #expect(menu.model("gpt-5.3-codex")?.efforts == ["", "low", "xhigh"])
        #expect(menu.model("claude-opus-5-5")?.efforts == ["medium", "high"])
        #expect(menu.model("gpt-5.6-luna")?.hasFastMode == false)
        #expect(menu.launch(.init(model: "gpt-5.3-codex", effort: "", fast: true)).model == "gpt-5.3-codex-fast")
        #expect(menu.launch(.init(model: "gpt-5.3-codex", effort: "xhigh", fast: false)).model == "gpt-5.3-codex-xhigh")
        // No bare id: the choice moves to medium. A missing fast twin keeps the listed speed.
        #expect(
            menu.launch(.init(model: "claude-opus-5-5", effort: "", fast: true))
                == (model: "claude-opus-5-5-medium-fast", effort: "", fastMode: false))
        #expect(
            menu.normalized(.init(model: "claude-opus-5-5", effort: "high", fast: true))
                == .init(model: "claude-opus-5-5", effort: "high", fast: false))
        #expect(menu.model("claude-opus-5-5")?.offersFastMode(effort: "medium") == true)
        #expect(menu.model("claude-opus-5-5")?.offersFastMode(effort: "high") == false)
        #expect(
            menu.launch(.init(model: "gpt-5.6-luna", effort: "", fast: false)).model == "gpt-5.6-luna-high-fast")
        #expect(menu.launch(.init()) == (model: "", effort: "", fastMode: false))
        #expect(ProviderModelCatalog.cursorMenu("No models available") == nil)
    }

    @Test func devinUsesFamilySlugsAndTheirVariantIds() throws {
        let output = """
            {"families":[
              {"slug":"claude-opus-5.5","variants":[{"model_uid":"claude-opus-5-5-medium"},{"model_uid":"claude-opus-5-5-high"},{"model_uid":"claude-opus-5-5-medium-fast"},{"model_uid":"claude-opus-5-5-high-fast"}]},
              {"slug":"gpt-5.5","variants":[{"model_uid":"gpt-5-5-none"},{"model_uid":"gpt-5-5-high"},{"model_uid":"gpt-5-5-high-priority"}]},
              {"slug":"claude-fable-5","variants":[{"model_uid":"claude-5-fable-low"},{"model_uid":"claude-5-fable-high"}]},
              {"slug":"fusion","variants":[{"model_uid":"fusion-a-high-sidekick-b-medium"},{"model_uid":"fusion-c-high-sidekick-d-medium"},{"model_uid":"fusion-e-low-sidekick-f-high"}]},
              {"slug":"gpt-5.2","variants":[{"model_uid":"MODEL_GPT_5_2_LOW"},{"model_uid":"MODEL_GPT_5_2_HIGH"}]}
            ]}
            """
        let menu = try #require(ProviderModelCatalog.devinMenu("[1] 4242\n" + output))
        #expect(menu.models.map(\.id) == ["", "claude-opus-5.5", "gpt-5.5", "claude-fable-5", "fusion", "gpt-5.2"])
        #expect(menu.model("claude-opus-5.5")?.efforts == ["", "medium", "high"])
        #expect(menu.model("claude-opus-5.5")?.hasFastMode == true)
        #expect(menu.model("gpt-5.5")?.efforts == ["", "none", "high"])
        #expect(menu.model("claude-fable-5")?.efforts == ["", "low", "high"])
        #expect(menu.model("fusion")?.efforts == [""])
        #expect(menu.model("gpt-5.2")?.efforts == [""])
        #expect(menu.launch(.init(model: "claude-opus-5.5", effort: "", fast: false)).model == "claude-opus-5.5")
        // Fast with the default effort takes the fast twin of the first listed variant.
        #expect(
            menu.launch(.init(model: "claude-opus-5.5", effort: "", fast: true)).model == "claude-opus-5-5-medium-fast")
        #expect(menu.launch(.init(model: "gpt-5.5", effort: "high", fast: true)).model == "gpt-5-5-high-priority")
        #expect(menu.launch(.init(model: "gpt-5.5", effort: "none", fast: true)).model == "gpt-5-5-none")
        #expect(menu.launch(.init(model: "fusion", effort: "", fast: false)).model == "fusion")
    }

    @Test func effortAndSpeedSuffixesSplitOffTheBase() {
        #expect(ProviderModelCatalog.split("gpt-5.5-extra-high").base == "gpt-5.5")
        #expect(ProviderModelCatalog.split("gpt-5.5-extra-high").variant == .init(effort: "extra-high", fast: false))
        #expect(ProviderModelCatalog.split("gpt-5-5-xhigh-priority").variant == .init(effort: "xhigh", fast: true))
        #expect(ProviderModelCatalog.split("swe-1-6-fast").base == "swe-1-6")
        #expect(ProviderModelCatalog.split("claude-opus-4-6-thinking").variant == .init(effort: "", fast: false))
    }

    @Test func aSecondPressOnTheSelectedProviderStartsIt() {
        #expect(NewSessionLaunch.action(selected: .grokBuild, tapped: .cursor) == .select(.cursor))
        #expect(NewSessionLaunch.action(selected: .cursor, tapped: .cursor) == .start(.cursor))
    }

    @Test func arrowKeysMoveAlongTheProviderRowAndStopAtItsEnds() {
        #expect(NewSessionLaunch.provider(after: .claudeCode, movingBy: 1) == .codex)
        #expect(NewSessionLaunch.provider(after: .grokBuild, movingBy: -1) == .kimi)
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

    @Test(arguments: [CLIProvider.claudeCode, .codex, .devin, .cursor, .kimi])
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
    func newerInstalledCodexShowsBothVersionsWithoutBlockingStart() throws {
        _ = NSApplication.shared
        NSApp.appearance = NSAppearance(named: .darkAqua)
        let name = "SigilNewSessionVersion.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(
            settings: AppSettings(defaults: defaults),
            store: SessionStore(root: root.appendingPathComponent("sessions")),
            trashConversation: { _ in }, presentError: { _ in },
            providerInstallations: [
                .codex: .init(executable: URL(fileURLWithPath: "/bin/sh"), version: "codex-cli 0.160.0", problem: nil)
            ])
        let sheet = NewSessionSheet(model: model, provider: .codex)
        #expect(
            sheet.providerVersionNotice
                == "Codex 0.160.0 is newer than Sigil checked (0.157.1). History and turn state are best effort.")
        #expect(model.providerLaunchProblem(.codex) == nil)
        #expect(NewSessionSheet(model: model, provider: .claudeCode).providerVersionNotice == nil)
        #expect(try png(of: sheet).count > 1000)
    }

    @Test @MainActor
    func sheetRendersLogosAndGrokOptionsOnlyForGrok() throws {
        _ = NSApplication.shared
        NSApp.appearance = NSAppearance(named: .darkAqua)
        let name = "SigilNewSession.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        // These tests list chats from the history files directly.
        settings.showOtherAppSessions = true
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
        #expect(!model.isShowingNewSessionSheet)
        model.showNewSessionOptions()
        #expect(model.isShowingNewSessionSheet)

        let inline = try png(of: NewSessionSurface(model: model).frame(width: 650, height: 450))
        let grok = try png(of: NewSessionSheet(model: model))
        let cursor = try png(of: NewSessionSheet(model: model, provider: .cursor))
        #expect(grok.count > 1000)
        #expect(cursor.count > 1000)
        #expect(inline.count > 1000)
    }

    @Test @MainActor
    func sheetAndSettingsRenderSixProviderInventoryWithKnownProblems() throws {
        _ = NSApplication.shared
        let name = "SigilProviderInventory.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = AppSettings(defaults: defaults)
        settings.kimiSignIn = .apiKey
        let ready = ProviderInstallation(executable: URL(fileURLWithPath: "/bin/sh"), version: "fixture", problem: nil)
        let model = AppModel(
            settings: settings, store: SessionStore(root: root.appendingPathComponent("sessions")),
            kimiKeyStore: InMemoryKimiKeyStore(),
            providerInstallations: [
                .claudeCode: ready,
                .codex: .init(executable: nil, version: nil, problem: "Install Codex", failure: .notInstalled),
                .devin: .init(executable: nil, version: nil, problem: "Version check timed out", timedOut: true),
                .cursor: .init(
                    executable: ready.executable, version: nil, problem: "Version check failed", failure: .probeFailed),
                .kimi: ready, .grokBuild: ready,
            ])
        #expect(model.providerTileStatus(.codex).caption == "Not installed")
        #expect(model.providerTileStatus(.devin) == .timedOut)
        #expect(model.providerTileStatus(.cursor) == .checkFailed)
        #expect(model.providerTileStatus(.kimi) == .needsSignIn)
        #expect(model.settings.defaultProvider == .claudeCode)
        #expect(try png(of: NewSessionSheet(model: model)).count > 1000)
        #expect(try png(of: NewSessionSurface(model: model).frame(width: 540, height: 450)).count > 1000)
        #expect(try png(of: SettingsView(model: model, initialTab: .general).frame(height: 620)).count > 1000)
    }

    @Test func providerLogosUseTheInstalledApps() {
        #expect(CLIProvider.claudeCode.applicationBundleID == "com.anthropic.claudefordesktop")
        #expect(CLIProvider.codex.applicationBundleID == "com.openai.codex")
        #expect(CLIProvider.devin.applicationBundleID == "com.exafunction.windsurf")
        #expect(CLIProvider.cursor.applicationBundleID == "com.todesktop.230313mzl4w4u92")
        #expect(CLIProvider.kimi.applicationBundleID == "com.kimi.code.desktop")
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
