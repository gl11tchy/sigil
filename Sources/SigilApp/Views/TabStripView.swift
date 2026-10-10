import SigilKit
import SwiftUI

/// Chips take their title's width, up to `maximumChipWidth`, as Beautiful
/// UI's tabs do; they never stretch to fill the bar. When the titles want more
/// than the strip has, the widest chips give way first so every open session
/// stays on screen with its title, mark, and close button. Only past
/// `minimumChipWidth` does the strip scroll.
enum TabStripSizing {
    /// `nil` means a chip is not pinned to one width.
    static let fixedChipWidth: CGFloat? = nil
    static let spacing: CGFloat = 4
    static let showsScrollIndicators = true
    /// Narrower than this and a chip cannot hold a mark, a few words, and its close button.
    static let minimumChipWidth: CGFloat = 96
    /// Wider than this and a chip reads as a title bar, not a tab.
    static let maximumChipWidth: CGFloat = 200

    static func widths(available: CGFloat, ideals: [CGFloat]) -> [CGFloat] {
        guard !ideals.isEmpty else { return [] }
        if let fixedChipWidth {
            return Array(repeating: fixedChipWidth, count: ideals.count)
        }
        let capped = ideals.map { min($0, maximumChipWidth) }
        let gaps = spacing * CGFloat(capped.count - 1)
        if capped.reduce(0, +) + gaps <= available {
            return capped
        }
        return capped.map { min($0, max(minimumChipWidth, cap(room: max(0, available - gaps), ideals: capped))) }
    }

    /// The width that, applied as a ceiling to every chip, makes the row fit
    /// `room`: chips already narrower than the ceiling keep their size and hand
    /// the difference to the wider ones.
    private static func cap(room: CGFloat, ideals: [CGFloat]) -> CGFloat {
        var cap = room / CGFloat(ideals.count)
        for _ in ideals.indices {
            let fixed = ideals.filter { $0 <= cap }
            let flexible = ideals.count - fixed.count
            guard flexible > 0 else { return cap }
            let next = (room - fixed.reduce(0, +)) / CGFloat(flexible)
            if abs(next - cap) < 0.5 { return next }
            cap = next
        }
        return cap
    }

    static func contentWidth(available: CGFloat, ideals: [CGFloat]) -> CGFloat {
        let widths = widths(available: available, ideals: ideals)
        guard !widths.isEmpty else { return 0 }
        let gaps = spacing * CGFloat(widths.count - 1)
        return widths.reduce(0, +) + gaps
    }
}

/// The tab strip in the top bar, beside the selected session's folder.
///
/// The strip claims whatever width the bar has left (a `GeometryReader` is
/// greedy), so its width never follows the chips' own size. The chips then
/// share that width; see `TabStripSizing`.
struct TabStripView: View {
    @Bindable var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: TabStripSizing.spacing) {
                        TabChipRow(availableWidth: max(0, geo.size.width - 40)) {
                            ForEach(model.tabs) { tab in
                                TabChip(
                                    tab: tab,
                                    label: model.title(for: tab),
                                    color: model.tabColor(for: tab),
                                    hasCustomName: model.hasCustomTabName(tab),
                                    isSelected: !model.showsNewSessionSurface && tab.id == model.selectedTab?.id,
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
                        IconButton(
                            systemImage: "plus",
                            help: "New Session… (⌘T)",
                            label: "New Session"
                        ) {
                            model.requestNewSession()
                        }
                    }
                    .padding(.horizontal, 2)
                    .frame(minHeight: geo.size.height)
                }
                .scrollIndicators(TabStripSizing.showsScrollIndicators ? .visible : .hidden)
                .task(id: model.selectedTabID) {
                    await Task.yield()
                    guard !Task.isCancelled else { return }
                    if let id = model.selectedTabID {
                        withAnimation(reduceMotion ? nil : Motion.fade) {
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
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
        parts.append(activity.statusName)
        if let color { parts.append(color.label.lowercased()) }
        return parts.joined(separator: ", ")
    }
}

/// One tab, as Beautiful UI's tab chip: 28pt, a 6pt radius, the title in
/// Inter, and a fill only when selected or under the pointer.
/// A right-click renames it or sets a color bar. The bar is not the state mark.
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
    /// The label the rename field opened with.
    @State private var renameBaseline: String?
    @State private var discardRename = false
    @FocusState private var renameFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            if isRenaming {
                TextField("Name", text: $draft)
                    .textFieldStyle(.plain)
                    .ui(12.5, .medium)
                    .foregroundStyle(palette.ink)
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
                    .padding(.leading, 10)
                    .padding(.trailing, 2)
                    .frame(maxHeight: .infinity)
                    .accessibilityLabel("Tab name")
            } else {
                Button(action: select) {
                    HStack(spacing: 7) {
                        if showsMark {
                            ActivityMark(
                                activity: tab.activity,
                                hasUnseenActivity: tab.hasUnseenActivity && !isSelected,
                                lastSubmittedAt: tab.lastSubmittedAt)
                        }
                        Text(label)
                            .ui(12.5, .medium)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                            .foregroundStyle(isSelected ? palette.ink : palette.ink2)
                    }
                    .padding(.leading, 10)
                    .padding(.trailing, 2)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(label)
                .accessibilityValue(accessibilityState)
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            }

            // Visible at rest in `ink3` (3:1), with a 20×24 target, so a
            // background tab can be closed without hunting for it.
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 8.5, weight: .bold))
                    .frame(width: 18, height: 18)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(isCloseHovering ? palette.hover2 : Color.clear)
                    )
                    .frame(width: 20, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(isCloseHovering ? palette.ink : palette.ink3)
            .onHover { isCloseHovering = $0 }
            .accessibilityLabel("Close \(label)")
        }
        .padding(.trailing, 4)
        .frame(maxWidth: .infinity, minHeight: 28, maxHeight: 28)
        .background(
            RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                .fill(fill)
        )
        .overlay(alignment: .leading) {
            if let color {
                TabColorMark(color: color)
                    .padding(.leading, 3)
                    .padding(.vertical, 6)
            }
        }
        .animation(Motion.fade, value: isHovering)
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
                    get: { liveColor() == nil },
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

    /// Idle tabs carry no mark, so their titles line up with the chip edge.
    private var showsMark: Bool {
        switch tab.activity {
        case .idle: return tab.hasUnseenActivity && !isSelected
        case .starting, .working, .exited, .waitingForApproval, .interrupted, .failed, .disconnected, .unknown:
            return true
        }
    }

    /// Dark: the selected chip is `hover`, as measured in Beautiful UI's harness.
    /// Light: `hover` is nearly the page itself, so the chip steps to `hover2`.
    private var fill: Color {
        if isSelected { return palette.isDark ? palette.hover : palette.hover2 }
        guard isHovering else { return .clear }
        return palette.isDark ? palette.hover.opacity(0.5) : palette.hover
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
        renameBaseline = label
        discardRename = false
        isRenaming = true
    }

    /// Return or a blur with the label unchanged saves nothing: a chat with no
    /// summary yet shows its folder, and that would stay as its name.
    private func commitRename() {
        guard isRenaming, !discardRename else { return }
        let submitted = draft
        isRenaming = false
        if !AppModel.shouldNoOpRenameCommit(draft: submitted, baseline: renameBaseline) {
            rename(submitted)
        }
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
