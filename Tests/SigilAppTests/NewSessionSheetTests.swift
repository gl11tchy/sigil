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
        let direct = GrokModelCatalog.launch(executable: "/usr/local/bin/grok", shellPath: "/bin/echo")
        #expect(direct.executable == "/usr/local/bin/grok")
        #expect(direct.arguments == ["models"])
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
        content: view.environment(\.palette, Palette(theme: .sigilNeon))
    )
    renderer.scale = 2
    let image = try #require(renderer.nsImage)
    let rep = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
    return try #require(rep.representation(using: .png, properties: [:]))
}
