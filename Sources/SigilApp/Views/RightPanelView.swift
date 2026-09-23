import AppKit
import SigilKit
import SwiftUI

/// The right-hand utility column: one header of tool buttons over one tool.
struct RightPanelView: View {
    @Bindable var model: AppModel
    var availableWidth: Double = 380
    @Environment(\.palette) private var palette

    private var panel: RightPanel { model.panel }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(palette.hairline).frame(height: 1)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(palette.ground)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Utility panel")
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 2) {
            ForEach(RightPanelMode.allCases) { mode in
                ToolButton(
                    mode: mode,
                    isSelected: panel.mode == mode,
                    showsTitle: availableWidth >= 360 || panel.mode == mode,
                    action: { model.showPanel(mode) }
                )
            }
            Spacer(minLength: 6)
            trailingControls
        }
        .padding(.horizontal, 6)
        .frame(height: 36)
        .background(palette.ground)
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
        .padding(.trailing, 2)
    }

    // MARK: - Tools

    @ViewBuilder
    private var content: some View {
        switch panel.mode {
        case .shell:
            if let shell = panel.shell {
                TerminalPane(controller: shell, background: palette.groundNSColor)
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
                PanelPlaceholder(text: "Open a conversation to keep notes on it.")
            }
        }
    }
}

/// One tool tab in the panel header.
private struct ToolButton: View {
    let mode: RightPanelMode
    let isSelected: Bool
    let showsTitle: Bool
    let action: () -> Void

    @Environment(\.palette) private var palette
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: mode.systemImage)
                    .font(.system(size: 10.5, weight: .medium))
                if showsTitle {
                    Text(mode.title)
                        .font(.system(size: 11, weight: .medium))
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isSelected ? palette.selected : (isHovering ? palette.raised : .clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? palette.text : palette.textDim)
        .onHover { isHovering = $0 }
        .help(mode.title)
        .accessibilityLabel(mode.title)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
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
            Text(title)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(palette.textFaint)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 10)
                .frame(height: 22, alignment: .leading)
                .help("\(title) — \(subtitle)")
            TextEditor(text: $text)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(palette.text)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 6)
                .padding(.bottom, 6)
                .accessibilityLabel("Notes for \(title)")
        }
        .background(palette.ground)
    }
}

private struct PanelPlaceholder: View {
    let text: String
    @Environment(\.palette) private var palette

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(palette.textFaint)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The draggable seam between the terminal and the panel.
struct PanelDivider: View {
    @Binding var width: Double
    @Environment(\.palette) private var palette
    @State private var widthAtDragStart: Double?
    @FocusState private var isFocused: Bool

    private func clamp(_ value: Double) -> Double {
        min(RightPanel.maxWidth, max(RightPanel.minWidth, value))
    }

    var body: some View {
        Rectangle()
            .fill(palette.hairline)
            .frame(width: 1)
            .overlay {
                if isFocused {
                    Rectangle().fill(palette.accent).frame(width: 2).allowsHitTesting(false)
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
