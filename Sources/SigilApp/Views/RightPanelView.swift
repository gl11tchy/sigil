import AppKit
import SigilKit
import SwiftUI
import WebKit

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
        case .web:
            IconButton(systemImage: "house", help: "Go to \(panel.homeURL)") {
                panel.goHome()
            }
            IconButton(systemImage: "arrow.clockwise", help: "Reload") {
                panel.reload()
            }
            IconButton(systemImage: "arrow.up.forward.app", help: "Open in Default Browser") {
                if let url = panel.requestedURL { NSWorkspace.shared.open(url) }
            }
        case .notes:
            EmptyView()
        }
        IconButton(systemImage: "xmark", help: "Close Panel (⌥⌘B)") {
            panel.isVisible = false
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
        case .web:
            VStack(spacing: 0) {
                AddressBar(panel: panel)
                Rectangle().fill(palette.hairline).frame(height: 1)
                ZStack {
                    if panel.requestedURL != nil {
                        WebPane(panel: panel)
                    } else {
                        PanelPlaceholder(text: "Type an address or a port number.")
                    }
                    if let error = panel.pageError {
                        pageErrorOverlay(error)
                    }
                }
            }
        case .notes:
            let directory = model.currentDirectory
            NotesPane(
                directory: directory,
                text: Binding(
                    get: { panel.notes(for: directory) },
                    set: { panel.setNotes($0, for: directory) }
                )
            )
            .id(directory.path)
        }
    }
    private func pageErrorOverlay(_ error: String) -> some View {
        VStack(spacing: 8) {
            Text("Could not load page")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(palette.text)
            Text(error)
                .font(.system(size: 11))
                .foregroundStyle(palette.textDim)
                .fixedSize(horizontal: false, vertical: true)
            Button("Retry") { panel.reload() }
                .controlSize(.small)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.ground)
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

/// The browser's address field. Return navigates; a bare port means localhost.
private struct AddressBar: View {
    @Bindable var panel: RightPanel
    @Environment(\.palette) private var palette
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                TextField("localhost:3000", text: $panel.addressField)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(palette.text)
                    .focused($isFocused)
                    .onSubmit { panel.navigate(to: panel.addressField) }
                    .accessibilityLabel("Web address")
                    .onChange(of: isFocused) { _, focused in
                        if focused {
                            panel.isEditingAddress = true
                        } else {
                            panel.finishEditingAddress()
                        }
                    }
                if panel.isLoadingPage {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.55)
                        .frame(width: 10, height: 10)
                        .accessibilityLabel("Loading")
                }
                if panel.requestedURL != nil, panel.requestedURL?.absoluteString != panel.homeURL {
                    Button("Set Home") { panel.setHomeToCurrentAddress() }
                        .buttonStyle(.plain)
                        .font(.system(size: 10))
                        .foregroundStyle(palette.textFaint)
                        .help("Open the panel on this address next time")
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            if let error = panel.addressError {
                Text(error)
                    .font(.system(size: 9.5))
                    .foregroundStyle(palette.error)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 4)
            }
        }
        .background(palette.sidebar)
        .accessibilityLabel("Address")
        .onDisappear { panel.finishEditingAddress() }
    }
}

/// A web view for a locally running dev server, or any other page.
private struct WebPane: NSViewRepresentable {
    let panel: RightPanel

    func makeNSView(context: Context) -> WKWebView {
        panel.browserView()
    }

    /// Loads only when the address or the reload counter actually changed, so a
    /// SwiftUI redraw cannot restart a page the user is using.
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

/// A plain scratch pad, saved per working folder as the user types.
private struct NotesPane: View {
    let directory: URL
    @Binding var text: String
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(directory.breadcrumbPath)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(palette.textFaint)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 10)
                .frame(height: 22, alignment: .leading)
                .help(directory.abbreviatedPath)
            TextEditor(text: $text)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(palette.text)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 6)
                .padding(.bottom, 6)
                .accessibilityLabel("Notes for \(directory.abbreviatedPath)")
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
            .focusable()
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
