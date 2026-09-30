import SigilKit
import SwiftUI

/// The workbench's one list: projects and their tasks, in a stable order.
/// ↑ and ↓ move the selection while the rail has focus; Return hands focus
/// to the task's terminal.
struct TaskRail: View {
    @Bindable var store: WorkbenchStore
    @Environment(\.palette) private var palette
    @FocusState private var isFocused: Bool

    var body: some View {
        let rail = store.rail
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Spacer(minLength: 0)
                ActionIconButton(systemImage: "plus", help: "New Task", action: store.actions.startTask(nil))
            }
            // Room for the traffic lights, which sit over the rail.
            .padding(.leading, 78)
            .padding(.trailing, 8)
            .frame(height: 44)

            if !store.projects.isEmpty || !store.tasks.isEmpty {
                SegmentedPill(
                    items: WorkbenchRail.Filter.allCases,
                    selection: $store.filter,
                    title: { filter in
                        switch filter {
                        case .all: return "All"
                        case .needsYou:
                            return rail.attentionCount > 0 ? "Needs you · \(rail.attentionCount)" : "Needs you"
                        }
                    }
                )
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if store.projects.isEmpty && store.tasks.isEmpty {
                        noProjects
                    } else if rail.isEmpty && store.filter == .needsYou {
                        Text("Nothing needs you right now.")
                            .ui(12.5)
                            .foregroundStyle(palette.ink2)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                    }
                    ForEach(rail.sections) { section in
                        sectionHeader(section)
                        ForEach(section.tasks) { task in
                            TaskRow(
                                task: task,
                                isSelected: task.id == store.selectedTaskID,
                                showsKeyboardFocus: isFocused
                            ) {
                                store.select(task.id)
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
            }
            .scrollIndicators(.never)
        }
        .background(palette.canvas)
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onMoveCommand { direction in
            switch direction {
            case .up: store.moveSelection(by: -1)
            case .down: store.moveSelection(by: 1)
            default: break
            }
        }
        .onKeyPress(.return) {
            guard let id = store.selectedTaskID, let terminal = store.terminals[id] else { return .ignored }
            terminal.focus()
            return .handled
        }
        .onAppear {
            store.focusRail = { [focus = $isFocused] in focus.wrappedValue = true }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tasks")
    }

    private func sectionHeader(_ section: WorkbenchRail.Section) -> some View {
        HStack(spacing: 6) {
            HStack(spacing: 6) {
                Text(section.project.name)
                    .ui(12.5, .medium)
                    .foregroundStyle(palette.ink2)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(section.total)")
                    .mono(11.5)
                    .foregroundStyle(palette.ink2)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(section.project.name), \(section.total == 1 ? "1 task" : "\(section.total) tasks")")
            .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 4)
            ActionIconButton(
                systemImage: "plus", help: "New Task in \(section.project.name)",
                action: store.actions.startTask(section.project))
        }
        .padding(.leading, 8)
        .padding(.trailing, 2)
        .frame(height: 28)
        .padding(.top, 8)
        .help(section.project.path)
    }

    private var noProjects: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No projects yet")
                .ui(13, .medium)
                .foregroundStyle(palette.ink)
            // The screen beside the rail carries the one Add Project control.
            Text("Projects you add appear here, with their tasks.")
                .ui(12.5)
                .foregroundStyle(palette.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
    }
}

/// One task: its mark, its title, and the provider in mono.
private struct TaskRow: View {
    let task: WorkbenchTask
    let isSelected: Bool
    let showsKeyboardFocus: Bool
    let select: () -> Void

    @Environment(\.palette) private var palette
    @State private var isHovering = false

    var body: some View {
        Button(action: select) {
            HStack(spacing: 8) {
                TaskMark(task: task)
                Text(task.title)
                    .ui(13.5, isSelected ? .medium : .regular)
                    .foregroundStyle(palette.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Text(task.provider.command)
                    .mono(11.5)
                    .foregroundStyle(palette.ink2)
            }
            .padding(.horizontal, 8)
            .frame(height: 32)
            .background(background)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(Motion.fade, value: isHovering)
        .help(task.workspace.path)
        // The label replaces the button's content for VoiceOver and keeps its press action.
        .accessibilityLabel(
            "\(task.title), \(TaskStateText.label(task)), \(task.provider.name), \(task.workspace.label)"
        )
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private var background: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
        if isSelected {
            if palette.isDark {
                shape.fill(palette.hover2)
                    .overlay(shape.strokeBorder(showsKeyboardFocus ? palette.lineStrong : .clear, lineWidth: 1))
            } else {
                shape.fill(palette.surface)
                    .overlay(shape.strokeBorder(showsKeyboardFocus ? palette.accent : palette.ringButton, lineWidth: 1))
            }
        } else if isHovering {
            shape.fill(palette.isDark ? palette.hover : palette.hover2)
        } else {
            Color.clear
        }
    }
}
