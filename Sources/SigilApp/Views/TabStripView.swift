import SwiftUI

/// The tab strip, which lives inside the top bar and replaces the session label
/// once a second session is open.
struct TabStripView: View {
    @Bindable var model: AppModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(model.tabs) { tab in
                    TabChip(
                        tab: tab,
                        label: model.title(for: tab),
                        isSelected: tab.id == model.selectedTab?.id,
                        select: { model.select(tab.id) },
                        close: { model.closeTab(tab.id) }
                    )
                }
            }
            .padding(.horizontal, 6)
        }
        .scrollContentBackground(.hidden)
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

    var body: some View {
        HStack(spacing: 6) {
            StatusDot(activity: tab.activity)
            Text(label)
                .font(.system(size: 11.5))
                .lineLimit(1)
                .foregroundStyle(isSelected ? palette.text : palette.textDim)
            if isHovering {
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(palette.textDim)
                .accessibilityLabel("Close \(label)")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .frame(maxWidth: 170)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? palette.raised : (isHovering ? palette.raised.opacity(0.5) : Color.clear))
        )
        .overlay(alignment: .topTrailing) {
            if tab.hasUnseenActivity && !isSelected {
                Circle().fill(palette.accent).frame(width: 4, height: 4).offset(x: -3, y: 3)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { isHovering = $0 }
        .help(tab.workingDirectory.path)
    }
}
