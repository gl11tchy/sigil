import SigilKit
import SwiftUI

/// Chips share leftover width. Content wider than the strip scrolls.
enum TabStripSizing {
    /// `nil` means a chip is not pinned to one width.
    static let fixedChipWidth: CGFloat? = nil
    static let spacing: CGFloat = 2
    static let showsScrollIndicators = true

    static func widths(available: CGFloat, ideals: [CGFloat]) -> [CGFloat] {
        guard !ideals.isEmpty else { return [] }
        if let fixedChipWidth {
            return Array(repeating: fixedChipWidth, count: ideals.count)
        }
        let gaps = spacing * CGFloat(ideals.count - 1)
        let idealTotal = ideals.reduce(0, +) + gaps
        let extra = max(0, available - idealTotal)
        let share = extra / CGFloat(ideals.count)
        return ideals.map { $0 + share }
    }

    static func contentWidth(available: CGFloat, ideals: [CGFloat]) -> CGFloat {
        let widths = widths(available: available, ideals: ideals)
        guard !widths.isEmpty else { return 0 }
        let gaps = spacing * CGFloat(widths.count - 1)
        return widths.reduce(0, +) + gaps
    }
}

/// The tab strip in the top bar, beside the selected session's folder.
struct TabStripView: View {
    @Bindable var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var stripWidth: CGFloat = 0

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                TabChipRow(availableWidth: max(0, stripWidth - 12)) {
                    ForEach(model.tabs) { tab in
                        TabChip(
                            tab: tab,
                            label: model.title(for: tab),
                            color: model.tabColor(for: tab),
                            hasCustomName: model.hasCustomTabName(tab),
                            isSelected: tab.id == model.selectedTab?.id,
                            select: { model.select(tab.id) },
                            close: { model.requestCloseTab(tab.id) },
                            rename: { model.renameTab(tab, to: $0) },
                            resetName: { model.resetTabName(tab) },
                            setColor: { model.setTabColor(tab, to: $0) },
                            liveColor: { model.tabColor(for: tab) },
                            focusTerminal: { model.focusSelectedTerminal() }
                        )
                        .id(tab.id)
                    }
                }
                .padding(.horizontal, 6)
            }
            .scrollIndicators(TabStripSizing.showsScrollIndicators ? .visible : .hidden)
            .background {
                GeometryReader { geo in
                    Color.clear.preference(key: StripWidthKey.self, value: geo.size.width)
                }
            }
            .onPreferenceChange(StripWidthKey.self) { width in
                if width != stripWidth { stripWidth = width }
            }
            .task(id: model.selectedTabID) {
                await Task.yield()
                guard !Task.isCancelled else { return }
                if let id = model.selectedTabID {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct StripWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// Places chips with `TabStripSizing`.
private struct TabChipRow: Layout {
    var availableWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let ideals = subviews.map { $0.sizeThatFits(.unspecified).width }
        let height = subviews.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
        return CGSize(
            width: TabStripSizing.contentWidth(available: availableWidth, ideals: ideals),
            height: height
        )
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        let ideals = subviews.map { $0.sizeThatFits(.unspecified).width }
        let widths = TabStripSizing.widths(available: availableWidth, ideals: ideals)
        var x = bounds.minX
        for index in subviews.indices {
            let width = widths.indices.contains(index) ? widths[index] : 0
            subviews[index].place(
                at: CGPoint(x: x, y: bounds.midY),
                anchor: .leading,
                proposal: ProposedViewSize(width: width, height: bounds.height)
            )
            x += width
            if index != subviews.count - 1 { x += TabStripSizing.spacing }
        }
    }
}

enum TabChipAccess {
    static func value(
        isSelected: Bool,
        hasUnseenActivity: Bool,
        activity: TerminalTab.Activity,
        color: TabColor?
    ) -> String {
        var parts = [isSelected ? "selected" : "background"]
        if hasUnseenActivity { parts.append("unread") }
        switch activity {
        case .starting: parts.append("starting")
        case .working: parts.append("working")
        case .idle: parts.append("idle")
        case .exited: parts.append("exited")
        }
        if let color { parts.append(color.label.lowercased()) }
        return parts.joined(separator: ", ")
    }
}

private struct TabChip: View {
    let tab: TerminalTab
    let label: String
    let color: TabColor?
    let hasCustomName: Bool
    let isSelected: Bool
    let select: () -> Void
    let close: () -> Void
    let rename: (String) -> Void
    let resetName: () -> Void
    let setColor: (TabColor?) -> Void
    /// The color stored now. The menu must not trust the color it was built with.
    let liveColor: () -> TabColor?
    let focusTerminal: () -> Void

    @Environment(\.palette) private var palette
    @State private var isHovering = false
    @State private var isCloseHovering = false
    @State private var isRenaming = false
    @State private var draft = ""
    @State private var discardRename = false
    @FocusState private var renameFocused: Bool

    var body: some View {
        HStack(spacing: 2) {
            if isRenaming {
                TextField("Name", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5))
                    .foregroundStyle(palette.text)
                    .focused($renameFocused)
                    .onSubmit { commitRename() }
                    .onExitCommand(perform: cancelRename)
                    .onKeyPress(.escape) {
                        cancelRename()
                        return .handled
                    }
                    .onChange(of: renameFocused) { wasFocused, focused in
                        if wasFocused && !focused { commitRename() }
                    }
                    .accessibilityLabel("Tab name")
            } else {
                Button(action: select) {
                    HStack(spacing: 6) {
                        StatusDot(activity: tab.activity)
                        Text(label)
                            .font(.system(size: 11.5))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                            .foregroundStyle(isSelected ? palette.text : palette.textDim)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(label)
                .accessibilityValue(accessibilityState)
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            }

            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                    .frame(width: 16, height: 20)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(isCloseHovering ? palette.selected : Color.clear)
                    )
            }
            .buttonStyle(.plain)
            .foregroundStyle(palette.textDim)
            .opacity(isHovering || isSelected ? 1 : 0.45)
            .onHover { isCloseHovering = $0 }
            .accessibilityLabel("Close \(label)")
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, minHeight: 24, maxHeight: 24)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(
                    isSelected
                        ? palette.selected
                        : (isHovering ? palette.raised.opacity(0.5) : Color.clear)
                )
        )
        .overlay(alignment: .leading) {
            if let color {
                TabColorMark(color: color)
                    .padding(.leading, 3)
                    .padding(.vertical, 5)
            }
        }
        .overlay(alignment: .topTrailing) {
            if tab.hasUnseenActivity && !isSelected {
                Circle().fill(palette.accent).frame(width: 4, height: 4).offset(x: -3, y: 3)
            }
        }
        .onHover { isHovering = $0 }
        .help(tab.workingDirectory.path)
        .contextMenu { tabMenu }
        .task(id: isRenaming) { await focusRenameField() }
    }

    @ViewBuilder
    private var tabMenu: some View {
        Button("Rename") { beginRename() }
        if hasCustomName {
            Button("Reset Name") { resetName() }
        }
        Menu("Color") {
            Toggle(
                "None",
                isOn: Binding(
                    get: { color == nil },
                    set: { isOn in if isOn { setColor(nil) } }
                )
            )
            ForEach(TabColor.allCases) { mark in
                Toggle(
                    isOn: Binding(
                        get: { liveColor() == mark },
                        set: { isOn in
                            let next = TabColors.choosing(
                                mark, isOn: isOn, current: liveColor())
                            if next != liveColor() { setColor(next) }
                        }
                    )
                ) {
                    Label {
                        Text(mark.label)
                    } icon: {
                        Image(nsImage: TabColorSwatch.image(for: mark))
                    }
                }
            }
        }
        Divider()
        Button("Close Tab") { close() }
    }

    private var accessibilityState: String {
        TabChipAccess.value(
            isSelected: isSelected,
            hasUnseenActivity: tab.hasUnseenActivity,
            activity: tab.activity,
            color: color
        )
    }

    private func beginRename() {
        draft = label
        discardRename = false
        isRenaming = true
    }

    private func commitRename() {
        guard isRenaming, !discardRename else { return }
        let submitted = draft
        isRenaming = false
        rename(submitted)
        focusTerminal()
    }

    private func cancelRename() {
        discardRename = true
        isRenaming = false
        focusTerminal()
    }

    private func focusRenameField() async {
        guard isRenaming else { return }
        renameFocused = true
        let baseline = draft
        let started = ContinuousClock.now
        while !Task.isCancelled && isRenaming {
            let editor = NSApp.keyWindow?.fieldEditor(false, for: nil)
            let isFirstResponder = editor.map { $0.window?.firstResponder === $0 } ?? false
            let ready = AppModel.isRenameFieldEditorReady(
                fieldEditorExists: editor != nil,
                fieldEditorIsFirstResponder: isFirstResponder,
                isEditingRenameField: renameFocused && editor?.string == draft
            )
            if ready {
                if draft == baseline { editor?.selectAll(nil) }
                return
            }
            guard
                AppModel.shouldContinueRenameSelectAllRetry(
                    elapsed: ContinuousClock.now - started)
            else { return }
            try? await Task.sleep(for: AppModel.renameSelectAllRetryInterval)
        }
    }
}
