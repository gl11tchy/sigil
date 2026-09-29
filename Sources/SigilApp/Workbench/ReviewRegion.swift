import SigilKit
import SwiftUI

/// The review region: a second screen beside the terminal with the task's
/// changes, its checks, the facts about its workspace, process and
/// conversation, and Finish. Each part shows real data or says why it has none.
struct ReviewRegion: View {
    let task: WorkbenchTask
    let changes: WorkspaceChangesReading?
    let isReading: Bool
    let refresh: () -> Void
    let close: () -> Void
    let finish: WorkbenchAction

    @Environment(\.palette) private var palette

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.window, style: .continuous)
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Text("Review")
                    .ui(13, .semibold)
                    .foregroundStyle(palette.ink)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 4)
                IconButton(systemImage: "arrow.clockwise", help: "Read Changes Again", action: refresh)
                    .disabled(isReading)
                IconButton(systemImage: "xmark", help: "Hide Review", action: close)
            }
            .padding(.leading, 14)
            .padding(.trailing, 8)
            .frame(height: 44)
            Rectangle().fill(palette.line).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    changesSection
                    rule
                    checksSection
                    rule
                    factsSection
                    rule
                    finishSection
                }
                .padding(.bottom, 12)
            }
            .scrollIndicators(.automatic)
        }
        .background(shape.fill(palette.page))
        .clipShape(shape)
        .overlay(shape.strokeBorder(palette.line, lineWidth: 1).allowsHitTesting(false))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Review")
    }

    private var rule: some View {
        Rectangle().fill(palette.lineSoft).frame(height: 1).padding(.horizontal, 14)
    }

    private func sectionTitle(_ title: String, trailing: some View = EmptyView()) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .ui(12.5, .medium)
                .foregroundStyle(palette.ink2)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 4)
            trailing
        }
        .frame(height: 20)
    }

    // MARK: - Changes

    private var changesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Changes", trailing: totals)
            switch changes {
            case nil:
                note(isReading ? "Reading Git…" : "Not read yet.")
            case .missingFolder:
                note("The workspace folder is missing, so there is nothing to read.", tone: palette.redInk)
            case .notRepository:
                note("This folder is not a Git repository. Sigil reads changes from Git only.")
            case .failed(let reason):
                note("Could not read changes: \(reason)", tone: palette.redInk)
            case .changes(let changes):
                if let head = changes.head {
                    Label {
                        Text(head).mono(11.5).foregroundStyle(palette.ink2).lineLimit(1).truncationMode(.middle)
                    } icon: {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(palette.ink3)
                    }
                    .accessibilityLabel("Branch \(head)")
                }
                if changes.files.isEmpty {
                    note("No changes in this workspace.")
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(changes.files) { file in
                            FileChangeRow(file: file)
                        }
                    }
                    if changes.isTruncated {
                        note("Showing the first \(WorkspaceChangesReader.fileLimit) files.")
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var totals: some View {
        if case .changes(let changes) = changes, !changes.files.isEmpty {
            HStack(spacing: 4) {
                Text("\(changes.files.count) files").foregroundStyle(palette.ink2)
                Text("+\(changes.added)").foregroundStyle(palette.greenInk)
                Text("−\(changes.removed)").foregroundStyle(palette.redInk)
            }
            .mono(11.5)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                "\(changes.files.count) files, \(changes.added) added, \(changes.removed) removed lines")
        }
    }

    // MARK: - Checks

    private var checksSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Checks", trailing: StatusPill(text: "Not connected"))
            note("Sigil has no check source for this workspace yet. Run checks in the terminal.")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    // MARK: - Facts

    private var factsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Task")
            fact("Workspace", abbreviated(task.workspace.path), help: task.workspace.path)
            fact("Provider", task.provider.name)
            fact("Conversation", conversation)
            fact("Process", TaskStateText.label(task))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var conversation: String {
        switch task.conversation {
        case .verified(let id): return "Verified · \(id.prefix(8))"
        case .pending: return "Not verified yet. \(task.provider.name) assigns its ID itself."
        case .none: return "\(task.provider.name) keeps no history Sigil can read."
        }
    }

    private func fact(_ name: String, _ value: String, help: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(name)
                .ui(12.5)
                .foregroundStyle(palette.ink2)
                .frame(width: 88, alignment: .leading)
            Text(value)
                .mono(11.5)
                .foregroundStyle(palette.ink)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .help(help ?? value)
        .accessibilityElement(children: .combine)
    }

    private func abbreviated(_ path: String) -> String {
        URL(fileURLWithPath: path).abbreviatedPath
    }

    // MARK: - Finish

    private var finishSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Finish")
            if let reason = finish.reason {
                note(reason)
            }
            ActionButton(title: "Finish Task…", action: finish)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func note(_ text: String, tone: Color? = nil) -> some View {
        Text(text)
            .ui(12.5)
            .foregroundStyle(tone ?? palette.ink2)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// One changed file: its status letter, its path, and its line counts.
private struct FileChangeRow: View {
    let file: WorkspaceChanges.File
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 8) {
            Text(file.status.rawValue)
                .mono(11.5, .medium)
                .foregroundStyle(statusTone)
                .frame(width: 12)
            Text(file.path)
                .mono(11.5)
                .foregroundStyle(palette.ink)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if let added = file.added, let removed = file.removed {
                HStack(spacing: 4) {
                    Text("+\(added)").foregroundStyle(palette.greenInk)
                    Text("−\(removed)").foregroundStyle(palette.redInk)
                }
                .mono(11.5)
            } else if file.status == .untracked {
                Text("new").mono(11.5).foregroundStyle(palette.ink2)
            }
        }
        .frame(height: 24)
        .help(file.oldPath.map { "\(file.status.name) from \($0)" } ?? "\(file.status.name): \(file.path)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var statusTone: Color {
        switch file.status {
        case .added, .untracked: return palette.greenInk
        case .deleted, .conflicted: return palette.redInk
        case .renamed, .copied: return palette.accentInk
        case .modified, .typeChanged: return palette.orangeInk
        }
    }

    private var accessibilityText: String {
        var text = "\(file.status.name), \(file.path)"
        if let added = file.added, let removed = file.removed { text += ", \(added) added, \(removed) removed" }
        return text
    }
}
