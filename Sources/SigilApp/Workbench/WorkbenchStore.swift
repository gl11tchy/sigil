import Foundation
import Observation
import SigilKit

/// What a workbench control does: a real action, or the reason it cannot run.
/// There is no third kind, so a control can never be decorative.
enum WorkbenchAction {
    case run(() -> Void)
    case unavailable(String)

    var reason: String? {
        if case .unavailable(let reason) = self { return reason }
        return nil
    }
}

/// The actions the workbench's controls call. The debug fixture supplies one
/// set; the live app supplies another in mission M1.
@MainActor
struct WorkbenchActions {
    var addProject: () -> WorkbenchAction
    var startTask: (WorkbenchProject?) -> WorkbenchAction
    var restart: (WorkbenchTask) -> WorkbenchAction
    var close: (WorkbenchTask) -> WorkbenchAction
    var resume: (WorkbenchTask) -> WorkbenchAction
    var checkProvider: (WorkbenchTask) -> WorkbenchAction
    var finish: (WorkbenchTask) -> WorkbenchAction

    static let unavailable = WorkbenchActions(
        addProject: { .unavailable("Adding projects is not connected here.") },
        startTask: { _ in .unavailable("Starting tasks is not connected here.") },
        restart: { _ in .unavailable("Restarting is not connected here.") },
        close: { _ in .unavailable("Closing is not connected here.") },
        resume: { _ in .unavailable("Resuming is not connected here.") },
        checkProvider: { _ in .unavailable("Provider checks are not connected here.") },
        finish: { _ in .unavailable("Finishing a task is not available yet.") }
    )
}

/// The workbench's state: projects, tasks, the selection, and each task's
/// workspace changes. Views read it; actions change it.
@MainActor
@Observable
final class WorkbenchStore {
    var projects: [WorkbenchProject]
    var tasks: [WorkbenchTask]
    private(set) var selectedTaskID: String?
    var filter: WorkbenchRail.Filter = .all
    var showsRail = true
    var showsReview = true
    /// True once the user opened or closed review. Until then review shows
    /// only where it fits beside the rail.
    private(set) var reviewWasChosen = false
    /// Live terminals by task ID. A task without one shows a panel instead.
    var terminals: [String: TerminalController] = [:]
    private(set) var changes: [String: WorkspaceChangesReading] = [:]
    private(set) var readingChanges: Set<String> = []
    @ObservationIgnored var actions: WorkbenchActions = .unavailable
    @ObservationIgnored var readChanges: (URL) async -> WorkspaceChangesReading = {
        await WorkspaceChangesReader.read($0)
    }

    init(projects: [WorkbenchProject] = [], tasks: [WorkbenchTask] = [], selectedTaskID: String? = nil) {
        self.projects = projects
        self.tasks = tasks
        self.selectedTaskID = selectedTaskID
    }

    var rail: WorkbenchRail { WorkbenchRail(projects: projects, tasks: tasks, filter: filter) }

    var selectedTask: WorkbenchTask? {
        guard let selectedTaskID else { return nil }
        return tasks.first { $0.id == selectedTaskID }
    }

    func project(of task: WorkbenchTask) -> WorkbenchProject {
        projects.first { $0.id == task.projectID } ?? WorkbenchProject(path: task.projectID)
    }

    /// Selecting a task marks its finished turn as seen, as switching to a tab
    /// does. A click hands the keyboard to its terminal; arrow keys in the
    /// rail keep it there.
    func select(_ id: String?, focusingTerminal: Bool = true) {
        selectedTaskID = id
        guard let id, let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        if tasks[index].hasUnseenFinish { tasks[index].hasUnseenFinish = false }
        if focusingTerminal { terminals[id]?.focus() }
    }

    func moveSelection(by offset: Int) {
        select(rail.move(from: selectedTaskID, by: offset), focusingTerminal: false)
    }

    func selectNextNeedingAttention() {
        // Both filters show every task needing the user, so the next one is always visible.
        guard let next = rail.nextNeedingAttention(after: selectedTaskID) else { return }
        select(next)
    }

    func update(_ id: String, _ change: (inout WorkbenchTask) -> Void) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        change(&tasks[index])
    }

    /// Opening review in a window too narrow for all three columns hides the
    /// rail; showing the rail again closes review. The terminal keeps its room.
    /// `visible` is what the window shows now, which a default can differ from.
    func setReview(visible: Bool) {
        showsReview = visible
        reviewWasChosen = true
        if visible, let task = selectedTask, changes[task.id] == nil {
            Task { await refreshChanges(for: task.id) }
        }
    }

    func showRail(yieldingReview: Bool) {
        showsRail = true
        if yieldingReview { showsReview = false }
    }

    func refreshChanges(for id: String) async {
        guard let task = tasks.first(where: { $0.id == id }), !readingChanges.contains(id) else { return }
        readingChanges.insert(id)
        let reading = await readChanges(URL(fileURLWithPath: task.workspace.path))
        readingChanges.remove(id)
        changes[id] = reading
    }
}
