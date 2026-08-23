import SwiftUI

/// The tab strip, which lives inside the top bar and replaces the session label
/// once a second session is open.
struct TabStripView: View {
    @Bindable var model: AppModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 2) {
                    ForEach(model.tabs) { tab in
                        TabChip(
                            tab: tab,
                            label: model.title(for: tab),
                            isSelected: tab.id == model.selectedTab?.id,
                            select: { model.select(tab.id) },
                            close: { model.requestCloseTab(tab.id) }
                        )
                        .frame(width: 150)
                        .id(tab.id)
                    }
                }
                .padding(.horizontal, 6)
            }
            .scrollIndicators(.hidden)
            .task(id: model.selectedTabID) {
                await Task.yield()
                if let id = model.selectedTabID {
                    withAnimation(.easeOut(duration: 0.12)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
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
        HStack(spacing: 2) {
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

            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                    .frame(width: 16, height: 20)
            }
            .buttonStyle(.plain)
            .foregroundStyle(palette.textDim)
            .opacity(isHovering || isSelected ? 1 : 0.45)
            .accessibilityLabel("Close \(label)")
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, minHeight: 24, maxHeight: 24)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? palette.raised : (isHovering ? palette.raised.opacity(0.5) : Color.clear))
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
