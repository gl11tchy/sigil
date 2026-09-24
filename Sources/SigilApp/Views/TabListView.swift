import SwiftUI

struct TabListEntry: Equatable, Identifiable {
    let id: UUID
    let title: String
    let folder: String
    let workingState: String

    /// Title, folder, and working state in one string for the row and for VoiceOver.
    var label: String { "\(title), \(folder), \(workingState)" }
}

@MainActor
enum TabListRows {
    static func isShown(tabCount: Int) -> Bool { tabCount > 1 }

    static func folder(of directory: URL) -> String { directory.abbreviatedPath }

    static func workingState(for activity: TerminalTab.Activity) -> String {
        switch activity {
        case .starting: "Starting"
        case .working: "Working"
        case .idle: "Idle"
        case .exited(let code): "Exited with code \(code.map(String.init) ?? "unknown")"
        }
    }

    static func entries(
        _ rows: [(id: UUID, title: String, folder: String, activity: TerminalTab.Activity)]
    ) -> [TabListEntry] {
        rows.map { row in
            TabListEntry(
                id: row.id,
                title: row.title,
                folder: row.folder,
                workingState: workingState(for: row.activity)
            )
        }
    }

    static func selectedID(afterChoosing id: UUID, in entries: [TabListEntry]) -> UUID? {
        entries.contains { $0.id == id } ? id : nil
    }

    static func index(afterMovingBy offset: Int, from current: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return min(max(current + offset, 0), count - 1)
    }

    static func highlightedID(
        current: UUID?, selected: UUID?, entries: [TabListEntry]
    ) -> UUID? {
        if let current, entries.contains(where: { $0.id == current }) { return current }
        if let selected, entries.contains(where: { $0.id == selected }) { return selected }
        return entries.first?.id
    }
}

/// Keyboard list of open tabs. Control-Command-T opens it while the terminal has focus.
struct TabListView: View {
    @Bindable var model: AppModel
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false
    @State private var highlighted: UUID?
    @FocusState private var listFocused: Bool

    private var entries: [TabListEntry] {
        TabListRows.entries(
            model.tabs.map { tab in
                (
                    id: tab.id,
                    title: model.title(for: tab),
                    folder: TabListRows.folder(of: tab.workingDirectory),
                    activity: tab.activity
                )
            }
        )
    }

    var body: some View {
        Button(action: toggle) {
            Image(systemName: "list.bullet")
                .font(.system(size: 11, weight: .medium))
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(isHovering ? palette.raised : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isHovering ? palette.text : palette.textDim)
        .onHover { isHovering = $0 }
        .help("Tabs (⌃⌘T)")
        .accessibilityLabel("Tabs (⌃⌘T)")
        .popover(isPresented: $model.isShowingTabList, arrowEdge: .top) {
            tabList
                .frame(width: 360)
                .frame(height: listHeight)
        }
        .onDisappear { model.isShowingTabList = false }
    }

    private var listHeight: CGFloat {
        min(CGFloat(max(entries.count, 1)) * 44 + 8, 360)
    }

    private var tabList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(entries) { entry in
                        TabListRow(
                            entry: entry,
                            isSelected: entry.id == model.selectedTabID,
                            isHighlighted: entry.id == highlighted,
                            choose: { choose(entry.id) }
                        )
                        .id(entry.id)
                    }
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 6)
            }
            .background(palette.ground)
            .focusable()
            .focused($listFocused)
            .defaultFocus($listFocused, true)
            .onAppear {
                focusList()
                if let highlighted { proxy.scrollTo(highlighted, anchor: .center) }
            }
            .onKeyPress(.upArrow) {
                move(-1)
                return .handled
            }
            .onKeyPress(.downArrow) {
                move(1)
                return .handled
            }
            .onKeyPress(.return) {
                activateHighlighted()
                return .handled
            }
            .onKeyPress(.space) {
                activateHighlighted()
                return .handled
            }
            .onChange(of: entries) { _, _ in
                highlighted = TabListRows.highlightedID(
                    current: highlighted, selected: model.selectedTabID, entries: entries)
            }
            .onChange(of: highlighted) { _, id in
                guard let id else { return }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Tabs")
        }
    }

    private func toggle() {
        model.isShowingTabList.toggle()
    }

    /// The list opens on the selected tab, whether the button or the menu opened it.
    private func focusList() {
        highlighted = TabListRows.highlightedID(
            current: nil, selected: model.selectedTabID, entries: entries)
        listFocused = true
    }

    private func move(_ offset: Int) {
        let currentID = TabListRows.highlightedID(
            current: highlighted, selected: model.selectedTabID, entries: entries)
        let current = entries.firstIndex { $0.id == currentID } ?? 0
        let next = TabListRows.index(afterMovingBy: offset, from: current, count: entries.count)
        guard entries.indices.contains(next) else { return }
        highlighted = entries[next].id
    }

    private func activateHighlighted() {
        guard
            let id = TabListRows.highlightedID(
                current: highlighted, selected: model.selectedTabID, entries: entries)
        else { return }
        choose(id)
    }

    private func choose(_ id: UUID) {
        guard let chosen = TabListRows.selectedID(afterChoosing: id, in: entries) else { return }
        model.select(chosen)
        model.isShowingTabList = false
    }
}

private struct TabListRow: View {
    let entry: TabListEntry
    let isSelected: Bool
    let isHighlighted: Bool
    let choose: () -> Void

    @Environment(\.palette) private var palette
    @State private var isHovering = false

    var body: some View {
        Button(action: choose) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
                    .font(.system(size: 12, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(palette.text)
                    .lineLimit(1)
                Text("\(entry.folder) · \(entry.workingState)")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(palette.textFaint)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(fill)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel(entry.label)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private var fill: Color {
        if isSelected { return palette.selected }
        if isHovering || isHighlighted { return palette.raised }
        return .clear
    }
}
