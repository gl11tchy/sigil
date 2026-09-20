import AppKit
import SigilKit
import SwiftUI

/// Compact find bar that floats at the top-right of a terminal pane.
struct TerminalFindBar: View {
    @Binding var query: String
    /// One-based index of the current hit, or `0` when there are none.
    let matchIndex: Int
    let matchCount: Int
    let findNext: () -> Void
    let findPrevious: () -> Void
    let dismiss: () -> Void

    @Environment(\.palette) private var palette
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isFieldFocused ? palette.textDim : palette.textFaint)

            TextField("Find", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(palette.text)
                .focused($isFieldFocused)
                .frame(width: 132)
                .onSubmit(advance)
                .accessibilityLabel("Find in terminal")

            Text(counter)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(palette.textFaint)
                .monospacedDigit()
                .accessibilityLabel(counterLabel)

            FindBarIconButton(systemName: "chevron.up", help: "Previous match (Shift+Return)", action: findPrevious)
                .disabled(matchCount == 0)
            FindBarIconButton(systemName: "chevron.down", help: "Next match (Return)", action: findNext)
                .disabled(matchCount == 0)
            FindBarIconButton(systemName: "xmark", help: "Close find (Escape)", action: dismiss)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(palette.raised)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(
                            isFieldFocused ? palette.accent : palette.hairline,
                            lineWidth: 1
                        )
                )
        )
        .onExitCommand(perform: dismiss)
        .task {
            // Focus set in the same transaction that inserts the bar loses to
            // whichever field already had it (the sidebar search). Yield once
            // so the bar exists before it asks.
            await Task.yield()
            isFieldFocused = true
        }
    }

    private var counter: String {
        matchCount == 0 ? "0" : "\(matchIndex)/\(matchCount)"
    }

    private var counterLabel: String {
        matchCount == 0 ? "No matches" : "Match \(matchIndex) of \(matchCount)"
    }

    /// Return advances; Shift+Return goes back. `NSEvent` is how a TextField
    /// submit reports the shift key on macOS.
    private func advance() {
        if NSEvent.modifierFlags.contains(.shift) {
            findPrevious()
        } else {
            findNext()
        }
    }
}

private struct FindBarIconButton: View {
    let systemName: String
    let help: String
    let action: () -> Void

    @Environment(\.palette) private var palette
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .medium))
                .frame(width: 20, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isHovering ? palette.selected : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(
            isEnabled
                ? (isHovering ? palette.textDim : palette.textFaint)
                : palette.textFaint.opacity(0.4)
        )
        .onHover { isHovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}
