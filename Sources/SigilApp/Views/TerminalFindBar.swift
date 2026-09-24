import AppKit
import SigilKit
import SwiftUI

/// Compact find bar that floats at the top-right of a terminal pane.
struct TerminalFindBar: View {
    @Binding var query: String
    /// One-based index of the current hit, or `0` when there are none.
    let matchIndex: Int
    let matchCount: Int
    /// Changes when Cmd-F asks an open bar to take focus again.
    let focusToken: Int
    let findNext: () -> Void
    let findPrevious: () -> Void
    let dismiss: () -> Void

    @Environment(\.palette) private var palette
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isFieldFocused ? palette.ink2 : palette.ink3)
                .padding(.leading, 12)

            TextField("", text: $query, prompt: Text("Find").foregroundStyle(palette.ink2))
                .textFieldStyle(.plain)
                .ui(13)
                .foregroundStyle(palette.ink)
                .focused($isFieldFocused)
                .frame(width: 150)
                .padding(.leading, 4)
                .onSubmit(advance)
                .accessibilityLabel("Find in terminal")

            Text(counter)
                .mono(11.5)
                .foregroundStyle(palette.ink2)
                .monospacedDigit()
                .frame(minWidth: 28, alignment: .trailing)
                .accessibilityLabel(counterLabel)

            Rectangle().fill(palette.line).frame(width: 1, height: 16).padding(.horizontal, 4)

            FindBarIconButton(
                systemName: "chevron.up", help: "Previous match (Shift+Return)", label: "Previous Match",
                action: findPrevious
            )
            .disabled(matchCount == 0)
            FindBarIconButton(
                systemName: "chevron.down", help: "Next match (Return)", label: "Next Match",
                action: findNext
            )
            .disabled(matchCount == 0)
            FindBarIconButton(
                systemName: "xmark", help: "Close find (Escape)", label: "Close Find",
                action: dismiss
            )
            .padding(.trailing, 6)
        }
        .frame(height: 38)
        .background(Capsule(style: .continuous).fill(palette.surface))
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(isFieldFocused ? palette.accent : palette.ringOverlay, lineWidth: 1)
        )
        .shadow(color: .black.opacity(palette.isDark ? 0.34 : 0.10), radius: 14, y: 8)
        .animation(Motion.fade, value: isFieldFocused)
        .onExitCommand(perform: dismiss)
        .task(id: focusToken) {
            // Focus set in the same transaction that inserts the bar loses to
            // whichever field already had it (the sidebar search). Yield once
            // so the bar exists before it asks.
            await Task.yield()
            isFieldFocused = true
            await Task.yield()
            // Select the query, as Cmd-F does in Safari and Xcode.
            guard isFieldFocused, let editor = NSApp.keyWindow?.firstResponder as? NSTextView,
                editor.isFieldEditor
            else { return }
            editor.selectAll(nil)
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
    let label: String
    let action: () -> Void

    var body: some View {
        IconButton(systemImage: systemName, help: help, label: label, action: action)
    }
}
