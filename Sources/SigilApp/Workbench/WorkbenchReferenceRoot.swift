#if DEBUG
    import AppKit
    import Observation
    import SigilKit
    import SwiftUI

    /// Launch options for the reference slice, from the environment:
    /// `SIGIL_WORKBENCH_APPEARANCE=dark|light`, `SIGIL_WORKBENCH_WINDOW=1680x1020`,
    /// `SIGIL_WORKBENCH_REVIEW=open|closed`.
    struct WorkbenchReferenceOptions {
        var theme: TerminalTheme = .sigilDark
        var windowSize: CGSize?
        var showsReview = true

        static func from(_ environment: [String: String]) -> WorkbenchReferenceOptions {
            var options = WorkbenchReferenceOptions()
            if environment["SIGIL_WORKBENCH_APPEARANCE"] == "light" { options.theme = .sigilLight }
            if let size = environment["SIGIL_WORKBENCH_WINDOW"] {
                let parts = size.lowercased().split(separator: "x").compactMap { Double($0) }
                if parts.count == 2, parts.allSatisfy({ $0 >= 200 && $0 <= 8000 }) {
                    options.windowSize = CGSize(width: parts[0], height: parts[1])
                }
            }
            if environment["SIGIL_WORKBENCH_REVIEW"] == "closed" { options.showsReview = false }
            return options
        }
    }

    /// Owns a fixture world: its temporary folders, its fake CLI processes,
    /// and the store the workbench shows. Every action it offers really runs.
    @MainActor
    @Observable
    final class WorkbenchFixtureHost {
        let fixture: WorkbenchFixture
        let options: WorkbenchReferenceOptions
        let store = WorkbenchStore()
        private(set) var isReady = false
        private(set) var setupError: String?
        @ObservationIgnored private var world: WorkbenchFixtureWorld?
        @ObservationIgnored private var launches: [String: WorkbenchFixtureWorld.Launch] = [:]
        @ObservationIgnored private var didStart = false
        @ObservationIgnored private var termination: NSObjectProtocol?

        init(fixture: WorkbenchFixture, options: WorkbenchReferenceOptions) {
            self.fixture = fixture
            self.options = options
            store.showsReview = options.showsReview
            store.actions = actions()
        }

        var theme: TerminalTheme { options.theme }

        func start() async {
            guard !didStart else { return }
            didStart = true
            NSApp.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
            let fixture = fixture
            do {
                let world = try await Task.detached(priority: .userInitiated) {
                    try WorkbenchFixtureBuilder.build(fixture)
                }.value
                self.world = world
                launches = world.launches
                store.projects = world.projects
                store.tasks = world.tasks
                for task in world.tasks {
                    if case .live = task.process { startProcess(for: task.id) }
                }
                store.select(world.selectedTaskID)
                isReady = true
                termination = NotificationCenter.default.addObserver(
                    forName: NSApplication.willTerminateNotification, object: nil, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.tearDown() }
                }
            } catch {
                setupError = error.localizedDescription
            }
        }

        /// Stops every fake CLI and removes the fixture's temporary folders.
        func tearDown() {
            for controller in store.terminals.values { controller.terminateAndWait() }
            store.terminals = [:]
            if let root = world?.root { try? FileManager.default.removeItem(at: root) }
        }

        // MARK: - Processes

        private func startProcess(for id: String) {
            guard let task = store.tasks.first(where: { $0.id == id }), let launch = launches[id] else { return }
            store.terminals[id]?.terminate()
            let controller = TerminalController(theme: theme, fontSize: 13)
            controller.onTerminate = { [weak self] code in
                self?.store.update(id) { $0.process = .live(.exited(code: code)) }
            }
            store.terminals[id] = controller
            let spec = GrokLaunchSpec(
                executable: launch.script,
                workingDirectory: URL(fileURLWithPath: task.workspace.path),
                mode: .new(sessionID: UUID()),
                provider: task.provider)
            controller.start(spec)
        }

        // MARK: - Actions

        private func actions() -> WorkbenchActions {
            WorkbenchActions(
                addProject: { [weak self] in .run { self?.addProject() } },
                startTask: { [weak self] project in
                    guard let self, let project = project ?? self.store.selectedTask.map(self.store.project(of:))
                        ?? self.store.projects.first
                    else { return .unavailable("Add a project first.") }
                    return .run { self.startTask(in: project) }
                },
                restart: { [weak self] task in
                    guard self?.launches[task.id] != nil else { return .unavailable("This task has no CLI to start.") }
                    return .run { self?.restart(task.id) }
                },
                close: { [weak self] task in .run { self?.close(task.id) } },
                resume: { [weak self] task in
                    guard task.provider.capabilities.resume else {
                        return .unavailable("\(task.provider.name) cannot resume a conversation.")
                    }
                    guard self?.launches[task.id] != nil else { return .unavailable("This task has no CLI to start.") }
                    return .run { self?.restart(task.id) }
                },
                checkProvider: { [weak self] task in .run { self?.checkProvider(task) } },
                finish: { _ in .unavailable("Finishing a task is not available yet.") }
            )
        }

        private func addProject() {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.prompt = "Add Project"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            let path = GrokPaths.canonicalPath(url.path)
            guard !store.projects.contains(where: { $0.id == path }) else { return }
            store.projects.append(WorkbenchProject(path: path))
        }

        private func startTask(in project: WorkbenchProject) {
            guard let root = world?.root else { return }
            let id = "task-\(UUID().uuidString.prefix(6).lowercased())"
            do {
                launches[id] = try WorkbenchFixtureBuilder.blankLaunch(in: root, id: id, title: "New task")
            } catch {
                setupError = error.localizedDescription
                return
            }
            store.tasks.append(
                WorkbenchTask(
                    id: id, projectID: project.id, title: "New task", provider: .grokBuild,
                    workspace: WorkbenchWorkspace(path: project.path, kind: .projectFolder),
                    process: .live(.unknown), conversation: .verified(sessionID: UUID().uuidString.lowercased()),
                    createdAt: Date()))
            startProcess(for: id)
            store.select(id)
        }

        private func restart(_ id: String) {
            store.update(id) {
                $0.process = .live(.unknown)
                $0.workingSince = nil
            }
            startProcess(for: id)
            store.select(id)
        }

        private func close(_ id: String) {
            store.terminals[id]?.terminate()
            store.terminals[id] = nil
            store.update(id) { $0.process = .notRunning }
        }

        /// Looks for the provider in the fixture's own `bin` folder only, so a
        /// fixture never runs a CLI installed on this Mac. Putting an executable
        /// named after the provider's command there makes the task available.
        private func checkProvider(_ task: WorkbenchTask) {
            guard let root = world?.root else { return }
            let executable = root.appendingPathComponent("bin/\(task.provider.command)")
            let found = FileManager.default.isExecutableFile(atPath: executable.path)
            store.update(task.id) {
                $0.process = found ? .notRunning : .providerUnavailable(problem: WorkbenchFixtureWorld.problemText)
            }
        }
    }

    /// The window's content when a workbench fixture is requested.
    struct WorkbenchReferenceRoot: View {
        @State private var host: WorkbenchFixtureHost

        init(fixture: WorkbenchFixture) {
            _host = State(
                initialValue: WorkbenchFixtureHost(
                    fixture: fixture, options: .from(ProcessInfo.processInfo.environment)))
        }

        var body: some View {
            let palette = Palette(theme: host.theme)
            Group {
                if let error = host.setupError {
                    Text("The \(host.fixture.rawValue) fixture could not be built: \(error)")
                        .ui(13)
                        .foregroundStyle(palette.redInk)
                        .padding(24)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if host.isReady {
                    WorkbenchView(store: host.store, theme: host.theme)
                } else {
                    palette.canvas
                }
            }
            .background(palette.canvas)
            .background(WindowChrome(background: palette.canvasNSColor))
            .background(WindowSizer(size: host.options.windowSize))
            .ignoresSafeArea(.container, edges: .top)
            .task { await host.start() }
        }
    }

    /// Sets the window's content size once, for repeatable screenshots.
    private struct WindowSizer: NSViewRepresentable {
        let size: CGSize?

        func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

        func updateNSView(_ nsView: NSView, context: Context) {
            guard let size, !context.coordinator.didSize else { return }
            DispatchQueue.main.async {
                guard let window = nsView.window else { return }
                context.coordinator.didSize = true
                window.setContentSize(size)
                window.center()
            }
        }

        func makeCoordinator() -> Coordinator { Coordinator() }

        final class Coordinator {
            var didSize = false
        }
    }
#endif
