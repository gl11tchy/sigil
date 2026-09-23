import SwiftUI

/// Chips share leftover width. When their titles want more than the strip has,
/// the widest chips give way first so every open session stays on screen with
/// its title, dot, and close button. Only past `minimumChipWidth` does the
/// strip scroll.
enum TabStripSizing {
    /// `nil` means a chip is not pinned to one width.
    static let fixedChipWidth: CGFloat? = nil
    static let spacing: CGFloat = 2
    static let showsScrollIndicators = true
    /// Narrower than this and a chip cannot hold a dot, a few words, and its close button.
    static let minimumChipWidth: CGFloat = 96

    static func widths(available: CGFloat, ideals: [CGFloat]) -> [CGFloat] {
        guard !ideals.isEmpty else { return [] }
        if let fixedChipWidth {
            return Array(repeating: fixedChipWidth, count: ideals.count)
        }
        let gaps = spacing * CGFloat(ideals.count - 1)
        let idealTotal = ideals.reduce(0, +) + gaps
        if idealTotal <= available {
            let share = (available - idealTotal) / CGFloat(ideals.count)
            return ideals.map { $0 + share }
        }
        return ideals.map { min($0, max(minimumChipWidth, cap(room: max(0, available - gaps), ideals: ideals))) }
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
                    TabChipRow(availableWidth: max(0, geo.size.width - 12)) {
                        ForEach(model.tabs) { tab in
                            TabChip(
                                tab: tab,
                                label: model.title(for: tab),
                                isSelected: tab.id == model.selectedTab?.id,
                                select: { model.select(tab.id) },
                                close: { model.requestCloseTab(tab.id) }
                            )
                            .id(tab.id)
                        }
                    }
                    .padding(.horizontal, 6)
                    .frame(minHeight: geo.size.height)
                }
                .scrollIndicators(TabStripSizing.showsScrollIndicators ? .visible : .hidden)
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

private struct TabChip: View {
    let tab: TerminalTab
    let label: String
    let isSelected: Bool
    let select: () -> Void
    let close: () -> Void

    @Environment(\.palette) private var palette
    @State private var isHovering = false
    @State private var isCloseHovering = false

    var body: some View {
        HStack(spacing: 0) {
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
                .padding(.leading, 8)
                .padding(.trailing, 2)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(label)
            .accessibilityValue(accessibilityState)
            .accessibilityAddTraits(isSelected ? [.isSelected] : [])

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
        .padding(.trailing, 8)
        .frame(maxWidth: .infinity, minHeight: 24, maxHeight: 24)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(
                    isSelected
                        ? palette.selected
                        : (isHovering ? palette.raised.opacity(0.5) : Color.clear)
                )
        )
        .overlay(alignment: .topTrailing) {
            if tab.hasUnseenActivity && !isSelected {
                Circle().fill(palette.accent).frame(width: 4, height: 4).offset(x: -3, y: 3)
            }
        }
        .onHover { isHovering = $0 }
        .help(tab.workingDirectory.path)
    }

    private var accessibilityState: String {
        var parts = [isSelected ? "selected" : "background"]
        if tab.hasUnseenActivity { parts.append("unread") }
        switch tab.activity {
        case .starting: parts.append("starting")
        case .working: parts.append("working")
        case .idle: parts.append("idle")
        case .exited: parts.append("exited")
        }
        return parts.joined(separator: ", ")
    }
}
