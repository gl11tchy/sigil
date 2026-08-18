import SwiftUI

/// The slim tab strip above the terminal. Hidden while only one session is open.
struct TabStripView: View {
    @Bindable var model: AppModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 1) {
                ForEach(model.tabs) { tab in
                    TabChip(
                        tab: tab,
                        isSelected: tab.id == model.selectedTab?.id,
                        select: { model.select(tab.id) },
                        close: { model.closeTab(tab.id) }
                    )
                }
            }
            .padding(.horizontal, 8)
        }
        .frame(height: 30)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}

private struct TabChip: View {
    let tab: TerminalTab
    let isSelected: Bool
    let select: () -> Void
    let close: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            StatusDot(activity: tab.activity)
            Text(tab.title)
                .font(.system(size: 11.5))
                .lineLimit(1)
                .foregroundStyle(isSelected ? .primary : .secondary)
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
            .opacity(isHovering ? 0.7 : 0)
            .accessibilityLabel("Close \(tab.title)")
        }
        .padding(.horizontal, 9)
        .frame(height: 22)
        .frame(maxWidth: 180)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isSelected ? AnyShapeStyle(.selection.opacity(0.5)) : AnyShapeStyle(.clear))
        )
        .overlay(alignment: .topTrailing) {
            if tab.hasUnseenActivity && !isSelected {
                Circle().fill(.tint).frame(width: 5, height: 5).offset(x: -2, y: 2)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { isHovering = $0 }
        .help(tab.workingDirectory.path)
    }
}
