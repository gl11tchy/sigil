import Foundation

/// The workbench's one navigation list: projects, each with its tasks.
///
/// Order is stable. Projects keep the user's order and tasks keep creation
/// order, so activity never moves a row. The filter hides rows; it does not
/// reorder them.
public struct WorkbenchRail: Equatable, Sendable {
    public enum Filter: String, CaseIterable, Identifiable, Sendable {
        case all
        case needsYou

        public var id: String { rawValue }
    }

    public struct Section: Identifiable, Equatable, Sendable {
        public let project: WorkbenchProject
        /// The rows shown under the current filter.
        public let tasks: [WorkbenchTask]
        /// Every task in the project, filtered or not.
        public let total: Int
        public let attentionCount: Int

        public var id: String { project.id }
    }

    public let filter: Filter
    public let sections: [Section]
    /// Tasks needing the user across every project, whatever the filter.
    public let attentionCount: Int
    /// Every task in rail order, whatever the filter.
    private let ordered: [WorkbenchTask]

    public init(projects: [WorkbenchProject], tasks: [WorkbenchTask], filter: Filter) {
        self.filter = filter
        var order = projects
        var known = Set(projects.map(\.id))
        // A task whose project is not listed still gets a section, after the
        // listed ones, so no task is ever unreachable.
        for task in Self.stableOrder(tasks) where !known.contains(task.projectID) {
            order.append(WorkbenchProject(path: task.projectID))
            known.insert(task.projectID)
        }
        let grouped = Dictionary(grouping: tasks, by: \.projectID)
        var sections: [Section] = []
        var ordered: [WorkbenchTask] = []
        for project in order {
            let all = Self.stableOrder(grouped[project.id] ?? [])
            ordered += all
            let needing = all.filter { $0.attention.needsUser }
            let shown = filter == .all ? all : needing
            if filter == .needsYou && shown.isEmpty { continue }
            sections.append(
                Section(project: project, tasks: shown, total: all.count, attentionCount: needing.count))
        }
        self.sections = sections
        self.ordered = ordered
        attentionCount = tasks.filter { $0.attention.needsUser }.count
    }

    /// The rows in the order the rail shows them.
    public var taskIDs: [String] { sections.flatMap { $0.tasks.map(\.id) } }

    public var isEmpty: Bool { sections.allSatisfy { $0.tasks.isEmpty } }

    /// The row `offset` steps from `selected`, clamped to the ends. With no
    /// visible selection, a step down picks the first row and a step up the last.
    public func move(from selected: String?, by offset: Int) -> String? {
        let ids = taskIDs
        guard !ids.isEmpty else { return nil }
        guard let selected, let index = ids.firstIndex(of: selected) else {
            return offset >= 0 ? ids.first : ids.last
        }
        return ids[min(max(index + offset, 0), ids.count - 1)]
    }

    /// The next task needing the user after `selected`, in rail order,
    /// wrapping around. Nil when nothing needs the user.
    public func nextNeedingAttention(after selected: String?) -> String? {
        let needing = ordered.filter { $0.attention.needsUser }.map(\.id)
        guard !needing.isEmpty else { return nil }
        let all = ordered.map(\.id)
        guard let selected, let start = all.firstIndex(of: selected) else { return needing.first }
        let after = all[(start + 1)...] + all[...start]
        return after.first { needing.contains($0) }
    }

    static func stableOrder(_ tasks: [WorkbenchTask]) -> [WorkbenchTask] {
        tasks.sorted { lhs, rhs in
            lhs.createdAt == rhs.createdAt ? lhs.id < rhs.id : lhs.createdAt < rhs.createdAt
        }
    }
}
