import AppKit
import SigilKit
import SwiftUI

/// The right-hand utility column: a second screen beside the first, with a
/// segmented control over one tool.
struct RightPanelView: View {
    @Bindable var model: AppModel
    var availableWidth: Double = 380
    @Environment(\.palette) private var palette

    private var panel: RightPanel { model.panel }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.window, style: .continuous)
        VStack(spacing: 0) {
            header
            Rectangle().fill(palette.line).frame(height: 1)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(shape.fill(palette.page))
        .clipShape(shape)
        .overlay(shape.strokeBorder(palette.line, lineWidth: 1).allowsHitTesting(false))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Utility panel")
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 4) {
            SegmentedPill(
                items: RightPanelMode.allCases,
                selection: Binding(get: { panel.mode }, set: { model.showPanel($0) }),
                title: \.title,
                systemImage: \.systemImage,
                showsTitle: { availableWidth >= 320 || panel.mode == $0 }
            )
            Spacer(minLength: 6)
            trailingControls
        }
        .padding(.horizontal, 8)
        .frame(height: 44)
    }

    @ViewBuilder
    private var trailingControls: some View {
        switch panel.mode {
        case .shell:
            IconButton(systemImage: "arrow.clockwise", help: "Restart Shell") {
                model.restartPanelShell()
            }
        case .notes:
            EmptyView()
        }
        IconButton(systemImage: "xmark", help: "Close Panel (⌥⌘B)", label: "Close Panel") {
            model.togglePanel()
        }
    }

    // MARK: - Tools

    @ViewBuilder
    private var content: some View {
        switch panel.mode {
        case .shell:
            if let shell = panel.shell {
                VStack(spacing: 0) {
                    TerminalPane(
                        controller: shell,
                        background: Palette.nsColor(model.settings.theme.backgroundHex),
                        cornerRadius: Radius.window - 1,
                        roundsTopCorners: false
                    )
                    if panel.shellExited {
                        ShellEndedRow(restart: { model.restartPanelShell() })
                    }
                }
                .padding([.leading, .trailing, .bottom], 1)
                .task(id: ObjectIdentifier(shell)) {
                    await Task.yield()
                    model.focusPanelShell()
                }
            } else {
                PanelPlaceholder(text: "Starting a shell…")
            }
        case .notes:
            if let tab = model.selectedTab, let sessionID = tab.sessionID {
                let cwd = tab.workingDirectory.path
                NotesPane(
                    title: model.title(for: tab),
                    subtitle: tab.workingDirectory.abbreviatedPath,
                    notice: panel.notesNotice(forSessionID: sessionID, cwd: cwd),
                    retry: { panel.retryNotesSave() },
                    text: Binding(
                        get: { panel.notes(forSessionID: sessionID, cwd: cwd) },
                        set: { panel.setNotes($0, forSessionID: sessionID, cwd: cwd) }
                    )
                )
                .id("\(cwd)/\(sessionID)")
            } else {
                PanelPlaceholder(text: Self.notesPlaceholder(for: model.selectedTab))
            }
        }
    }

    /// A supported provider still needs a conversation identity before notes can open.
    static func notesPlaceholder(for tab: TerminalTab?) -> String {
        guard let provider = tab?.spec.provider else {
            return "Open a conversation to keep notes on it."
        }
        if provider.capabilities.notes {
            return "Notes need a verified conversation identity from \(provider.name)."
        }
        return "\(provider.name) does not report a conversation Sigil can keep notes on."
    }
}

/// A plain scratch pad, saved per conversation as the user types.
private struct NotesPane: View {
    let title: String
    let subtitle: String
    let notice: ConversationNotesStore.Notice?
    let retry: () -> Void
    @Binding var text: String
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(title)
                    .ui(12.5, .medium)
                    .foregroundStyle(palette.ink)
                    .lineLimit(1)
                Text(subtitle)
                    .mono(11)
                    .foregroundStyle(palette.ink2)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 4)
            .help("\(title) — \(subtitle)")
            if let notice {
                HStack(spacing: 6) {
                    Text(noticeText(notice))
                        .ui(12)
                        .foregroundStyle(palette.orangeInk)
                    if case .conflictPreserved(let file) = notice {
                        Button("Show file") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                            .buttonStyle(SigilButtonStyle(kind: .secondary, height: 24))
                    } else if notice == .conflictUnsaved || notice == .saveFailed {
                        Button("Retry", action: retry)
                            .buttonStyle(SigilButtonStyle(kind: .secondary, height: 24))
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 4)
                .accessibilityIdentifier("notes-save-notice")
            }
            TextEditor(text: $text)
                .mono(12.5)
                .foregroundStyle(palette.ink)
                .lineSpacing(3)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 9)
                .padding(.bottom, 8)
                .accessibilityLabel("Notes for \(title)")
        }
        .background(palette.page)
    }

    private func noticeText(_ notice: ConversationNotesStore.Notice) -> String {
        switch notice {
        case .conflictPreserved: "Outside edits saved in a separate file."
        case .conflictUnsaved: "Conflict: notes not saved. Both versions are kept."
        case .outsideDeletion: "Outside deletion detected. Your notes were kept."
        case .saveFailed: "Notes not saved."
        }
    }
}

private struct PanelPlaceholder: View {
    let text: String
    @Environment(\.palette) private var palette

    var body: some View {
        Text(text)
            .ui(13)
            .foregroundStyle(palette.ink2)
            .multilineTextAlignment(.center)
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Shown under a panel shell that has exited, like a tab's ended banner.
private struct ShellEndedRow: View {
    let restart: () -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(palette.ink3)
                .frame(width: 6, height: 6)
            Text("Shell ended.")
                .ui(12)
                .foregroundStyle(palette.ink2)
            Spacer()
            Button("Restart", action: restart)
                .buttonStyle(SigilButtonStyle(kind: .secondary, height: 24))
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(palette.surface)
        .overlay(alignment: .top) { Rectangle().fill(palette.line).frame(height: 1) }
    }
}

/// The draggable seam between the screen and the panel. It draws nothing;
/// focus shows an accent bar.
struct PanelDivider: View {
    @Binding var width: Double
    var maximumWidth: Double = RightPanel.maxWidth
    @Environment(\.palette) private var palette
    @FocusState private var isFocused: Bool

    private var limits: ClosedRange<Double> { min(RightPanel.minWidth, maximumWidth)...maximumWidth }

    private func clamp(_ value: Double) -> Double {
        min(limits.upperBound, max(limits.lowerBound, value))
    }

    var body: some View {
        Color.clear
            .frame(width: 1)
            .overlay {
                if isFocused {
                    Capsule().fill(palette.accent).frame(width: 2)
                        .padding(.vertical, WindowContent.inset + Radius.window)
                        .allowsHitTesting(false)
                }
            }
            .overlay {
                DividerDragHandle(width: $width, limits: limits, direction: .left) { isFocused = true }
                    .frame(width: 9)
                    .accessibilityHidden(true)
            }
            .focusable(interactions: .edit)
            .focused($isFocused)
            .onKeyPress(.leftArrow) {
                width = clamp(width + 20)
                return .handled
            }
            .onKeyPress(.rightArrow) {
                width = clamp(width - 20)
                return .handled
            }
            .accessibilityElement()
            .accessibilityLabel("Panel width")
            .accessibilityValue("\(Int(width)) points")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: width = clamp(width + 20)
                case .decrement: width = clamp(width - 20)
                @unknown default: break
                }
            }
    }
}
