import SigilKit
import SwiftUI

/// The selected task, compactly: its mark and title, one mono line naming the
/// project, the workspace and the provider, its state, and the Review control.
/// It replaces the tab bar; it never grows past the 44pt the tab bar had.
struct ContextHeader: View {
    let task: WorkbenchTask
    let project: WorkbenchProject
    let changes: WorkspaceChangesReading?
    let showsReview: Bool
    /// True when the rail is hidden, so the header needs a way back to it and
    /// room for the traffic lights.
    let railHidden: Bool
    let showRail: () -> Void
    let toggleReview: () -> Void

    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 8) {
            if railHidden {
                Color.clear.frame(width: 58)
                IconButton(systemImage: "sidebar.leading", help: "Show Tasks", action: showRail)
            }
            TaskMark(task: task)
            VStack(alignment: .leading, spacing: 1) {
                Text(task.title)
                    .ui(13, .semibold)
                    .foregroundStyle(palette.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(crumb)
                    .mono(11)
                    .foregroundStyle(palette.ink2)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(task.workspace.path)
            }
            .layoutPriority(1)
            Spacer(minLength: 8)
            state
            reviewToggle
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .frame(height: 44)
        .animation(reduceMotion ? nil : Motion.fade, value: TaskStateText.label(task))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Task")
    }

    /// `acme-api › sigil/7f3a2c1 · Claude Code`.
    private var crumb: String {
        "\(project.name) › \(task.workspace.label) · \(task.provider.name)"
    }

    @ViewBuilder
    private var state: some View {
        if case .live(.working) = task.process {
            WorkingLabel(since: task.workingSince)
        } else {
            StatusPill(text: TaskStateText.label(task), tone: TaskStateText.tone(task))
                .fixedSize()
        }
    }

    private var totals: (files: Int, added: Int, removed: Int)? {
        guard case .changes(let changes) = changes else { return nil }
        return (changes.files.count, changes.added, changes.removed)
    }

    private var reviewToggle: some View {
        Button(action: toggleReview) {
            HStack(spacing: 6) {
                Text("Review").ui(12.5, .medium)
                if let totals, totals.files > 0 {
                    HStack(spacing: 3) {
                        Text("+\(totals.added)").foregroundStyle(palette.greenInk)
                        Text("−\(totals.removed)").foregroundStyle(palette.redInk)
                    }
                    .mono(11.5)
                }
            }
            .foregroundStyle(showsReview ? palette.ink : palette.ink2)
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                    .fill(showsReview ? palette.hover2 : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help(showsReview ? "Hide Review" : "Show Review")
        .accessibilityLabel(reviewLabel)
        .accessibilityAddTraits(showsReview ? .isSelected : [])
    }

    private var reviewLabel: String {
        guard let totals else { return "Review" }
        return "Review, \(totals.files) files changed, \(totals.added) added, \(totals.removed) removed lines"
    }
}
