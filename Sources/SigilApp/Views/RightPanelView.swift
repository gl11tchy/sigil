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
        IconButton(systemImage: "xmark", help: "Close Panel (⌥⌘B)") {
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

    /// Notes are keyed by a Grok session, which other providers never have.
    static func notesPlaceholder(for tab: TerminalTab?) -> String {
        if let tab, tab.spec.provider != .grokBuild {
            return "Notes are available for Grok Build sessions."
        }
        return "Open a conversation to keep notes on it."
    }
}

/// A plain scratch pad, saved per conversation as the user types.
private struct NotesPane: View {
    let title: String
    let subtitle: String
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
    @Environment(\.palette) private var palette
    @State private var widthAtDragStart: Double?
    @FocusState private var isFocused: Bool

    private func clamp(_ value: Double) -> Double {
        min(RightPanel.maxWidth, max(RightPanel.minWidth, value))
    }

    var body: some View {
        Color.clear
            .frame(width: 1)
            .overlay {
                if isFocused {
                    Capsule().fill(palette.accent).frame(width: 2)
                        .padding(.vertical, RootView.inset + Radius.window)
                        .allowsHitTesting(false)
                }
            }
            .overlay {
                Color.clear
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.resizeLeftRight.set() } else { NSCursor.arrow.set() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                let base = widthAtDragStart ?? width
                                widthAtDragStart = base
                                width = clamp(base - value.translation.width)
                            }
                            .onEnded { _ in widthAtDragStart = nil }
                    )
            }
            .focusable(interactions: .activate)
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
