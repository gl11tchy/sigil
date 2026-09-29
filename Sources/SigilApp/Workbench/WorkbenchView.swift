import SigilKit
import SwiftUI

/// The workbench: the task rail, the screen with the context header over the
/// provider's real terminal, and the review region. Columns come from
/// `WorkbenchColumns`, so the terminal always keeps its room.
struct WorkbenchView: View {
    @Bindable var store: WorkbenchStore
    let theme: TerminalTheme

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var palette: Palette { Palette(theme: theme) }
    private static let inset = WorkbenchColumns.inset

    var body: some View {
        GeometryReader { geometry in
            let columns = WorkbenchColumns(
                width: geometry.size.width, showsRail: store.showsRail,
                showsReview: store.showsReview && store.selectedTask != nil,
                reviewOverridesRail: store.reviewWasChosen)
            HStack(spacing: 0) {
                if let rail = columns.rail {
                    TaskRail(store: store)
                        .frame(width: rail)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
                screen(columns)
                    .padding(.leading, columns.rail == nil ? Self.inset : 0)
                    .padding(.trailing, columns.review == nil ? Self.inset : Self.inset / 2)
                    .padding(.vertical, Self.inset)
                if let review = columns.review, let task = store.selectedTask {
                    ReviewRegion(
                        task: task,
                        changes: store.changes[task.id],
                        isReading: store.readingChanges.contains(task.id),
                        refresh: { Task { await store.refreshChanges(for: task.id) } },
                        close: { store.setReview(visible: false) },
                        finish: store.actions.finish(task)
                    )
                    .padding(.leading, Self.inset / 2)
                    .padding(.trailing, Self.inset)
                    .padding(.vertical, Self.inset)
                    .frame(width: review + Self.inset * 1.5)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(reduceMotion ? nil : Motion.slide, value: columns)
        }
        .background(palette.canvas)
        .environment(\.palette, palette)
        .tint(palette.accent)
        .task(id: store.selectedTaskID) {
            guard let id = store.selectedTaskID, store.showsReview, store.changes[id] == nil else { return }
            await store.refreshChanges(for: id)
        }
    }

    private func screen(_ columns: WorkbenchColumns) -> some View {
        let shape = RoundedRectangle(cornerRadius: Radius.window, style: .continuous)
        return VStack(spacing: 0) {
            if let task = store.selectedTask {
                ContextHeader(
                    task: task,
                    project: store.project(of: task),
                    changes: store.changes[task.id],
                    showsReview: columns.review != nil,
                    railHidden: columns.rail == nil,
                    showRail: { store.showRail(yieldingReview: columns.railYieldedToReview) },
                    toggleReview: { store.setReview(visible: columns.review == nil) }
                )
                Rectangle().fill(palette.line).frame(height: 1)
            } else if columns.rail == nil {
                // Keep a way back to the rail when nothing is selected.
                HStack {
                    Color.clear.frame(width: 58)
                    IconButton(systemImage: "sidebar.leading", help: "Show Tasks") {
                        store.showRail(yieldingReview: false)
                    }
                    Spacer()
                }
                .padding(.horizontal, 12)
                .frame(height: 44)
            }
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(shape.fill(palette.page))
        .clipShape(shape)
        .overlay(shape.strokeBorder(palette.line, lineWidth: 1).allowsHitTesting(false))
    }

    @ViewBuilder
    private var content: some View {
        let selected = store.selectedTask
        VStack(spacing: 0) {
            ZStack {
                // Every live terminal stays mounted, so switching tasks never
                // restarts a process; only the selected one shows.
                ForEach(store.tasks.filter { store.terminals[$0.id] != nil }) { task in
                    let isSelected = task.id == selected?.id
                    if let terminal = store.terminals[task.id] {
                        TerminalPane(
                            controller: terminal,
                            background: Palette.nsColor(theme.backgroundHex),
                            cornerRadius: Radius.window - 1,
                            roundsTopCorners: false
                        )
                        .padding([.leading, .trailing, .bottom], 1)
                        .opacity(isSelected ? 1 : 0)
                        .allowsHitTesting(isSelected)
                        .accessibilityHidden(!isSelected)
                    }
                }
                if let selected {
                    if store.terminals[selected.id] == nil {
                        TaskStatePanel(task: selected, actions: store.actions)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(palette.page)
                    }
                } else {
                    NoTaskPanel(store: store)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            // Docked below the terminal, never over it, as in the tab window.
            if let selected, store.terminals[selected.id] != nil, case .live(let state) = selected.process,
                case .exited = state
            {
                // Dismiss clears the ended process; the task stays, not running.
                ExitedCapsule(
                    activity: state,
                    closeTitle: "Dismiss",
                    close: { run(store.actions.close(selected)) },
                    restart: { run(store.actions.restart(selected)) }
                )
                .padding(10)
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 8)))
            }
        }
        .animation(reduceMotion ? nil : Motion.slide, value: selected.map(TaskStateText.label))
    }

    private func run(_ action: WorkbenchAction) {
        if case .run(let perform) = action { perform() }
    }
}

/// What the screen shows for a task without a live terminal. Nothing here
/// pretends to be a terminal.
private struct TaskStatePanel: View {
    let task: WorkbenchTask
    let actions: WorkbenchActions
    @Environment(\.palette) private var palette

    var body: some View {
        switch task.process {
        case .providerUnavailable(let problem):
            StatePanel(
                systemImage: "exclamationmark.triangle",
                title: "\(task.provider.name) is unavailable",
                message: problem + " " + keptReference
            ) {
                ActionButton(title: "Check Again", action: actions.checkProvider(task), kind: .primary)
                SettingsLink { Text("Settings…") }
                    .buttonStyle(.secondary)
            }
        case .workspaceMissing:
            StatePanel(
                systemImage: "folder.badge.questionmark",
                title: "Workspace folder is missing",
                message: "\(URL(fileURLWithPath: task.workspace.path).abbreviatedPath) no longer exists. "
                    + "Sigil keeps the task and its conversation reference. Restore the folder to continue."
            ) {
                EmptyView()
            }
        case .notRunning, .live:
            StatePanel(
                systemImage: "pause.circle",
                title: "Not running",
                message: task.provider.capabilities.resume
                    ? "No process runs for this task. Resume reopens its conversation in \(task.provider.name)."
                    : "No process runs for this task. \(task.provider.name) cannot resume a conversation."
            ) {
                ActionButton(title: "Resume", action: actions.resume(task), kind: .primary)
            }
        }
    }

    private var keptReference: String {
        switch task.conversation {
        case .verified: return "Its saved conversation stays and can resume once \(task.provider.name) runs again."
        case .pending, .none: return "The task stays in the list."
        }
    }
}

/// No task selected: teach the next step for the state the rail is in.
private struct NoTaskPanel: View {
    @Bindable var store: WorkbenchStore

    var body: some View {
        if store.projects.isEmpty && store.tasks.isEmpty {
            StatePanel(
                systemImage: "folder",
                title: "Add a project to start",
                message: "A project is a folder or repository you work in. Tasks run inside it."
            ) {
                ActionButton(title: "Add Project…", action: store.actions.addProject(), kind: .primary)
            }
        } else if store.tasks.isEmpty, let first = store.projects.first {
            StatePanel(
                systemImage: "terminal",
                title: "No tasks yet",
                message: "Start a task in \(first.name), or use the plus beside another project."
            ) {
                ActionButton(
                    title: "Start Task in \(first.name)", action: store.actions.startTask(first), kind: .primary)
            }
        } else {
            StatePanel(
                systemImage: "sidebar.leading",
                title: "Choose a task",
                message: "Select a task in the list. ↑ and ↓ move through it."
            ) {
                EmptyView()
            }
        }
    }
}

/// The empty-state shape the tab window uses: a mark, a title, one or two
/// sentences, and the actions that move on.
private struct StatePanel<Actions: View>: View {
    let systemImage: String
    let title: String
    let message: String
    @ViewBuilder var actions: Actions
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(palette.ink3)
                .frame(width: 40, height: 40)
                .surface(palette.surface, radius: Radius.card, elevation: .card)
                .accessibilityHidden(true)
            VStack(spacing: 4) {
                Text(title)
                    .ui(15, .semibold)
                    .foregroundStyle(palette.ink)
                    .multilineTextAlignment(.center)
                Text(message)
                    .ui(13)
                    .foregroundStyle(palette.ink2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) { actions }
                .padding(.top, 4)
        }
        .padding(24)
        .accessibilityElement(children: .contain)
    }
}
