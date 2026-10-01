import SigilKit
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
        case .waitingForApproval: "Needs approval"
        case .interrupted: "Stopped"
        case .failed: "Failed"
        case .disconnected: "Disconnected"
        case .unknown: "Status unknown"
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
        IconButton(
            systemImage: "list.bullet", help: "Tabs (⌃⌘T)", label: "Tabs",
            isOn: model.isShowingTabList, action: toggle
        )
        .popover(isPresented: $model.isShowingTabList, arrowEdge: .top) {
            tabList
                .frame(width: 360)
                .frame(height: listHeight)
        }
        .onDisappear { model.isShowingTabList = false }
    }

    private var listHeight: CGFloat {
        min(CGFloat(max(entries.count, 1)) * 40 + 12, 360)
    }

    private var tabList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(entries) { entry in
                        TabListRow(
                            entry: entry,
                            color: color(of: entry.id),
                            isSelected: entry.id == model.selectedTabID,
                            isHighlighted: entry.id == highlighted,
                            choose: { choose(entry.id) }
                        )
                        .id(entry.id)
                    }
                }
                .padding(6)
            }
            .background(palette.surface)
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

    private func color(of id: UUID) -> TabColor? {
        guard let tab = model.tabs.first(where: { $0.id == id }) else { return nil }
        return model.tabColor(for: tab)
    }

    private func choose(_ id: UUID) {
        guard let chosen = TabListRows.selectedID(afterChoosing: id, in: entries) else { return }
        model.select(chosen)
        model.isShowingTabList = false
    }
}

/// One open tab in the list, as a Beautiful UI search result: title, then
/// the folder and state in mono on the trailing side.
private struct TabListRow: View {
    let entry: TabListEntry
    let color: TabColor?
    let isSelected: Bool
    let isHighlighted: Bool
    let choose: () -> Void

    @Environment(\.palette) private var palette
    @State private var isHovering = false

    var body: some View {
        Button(action: choose) {
            HStack(spacing: 10) {
                Text(entry.title)
                    .ui(13.5, isSelected ? .medium : .regular)
                    .foregroundStyle(palette.ink)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text("\(entry.folder) · \(entry.workingState)")
                    .mono(11)
                    .foregroundStyle(palette.ink2)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(-1)
            }
            .padding(.horizontal, 10)
            .frame(height: 36)
            .background(
                RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                    .fill(fill)
                    .overlay(
                        // The arrow-key row keeps a ring, so Return's target is
                        // clear while the pointer rests on another row.
                        RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                            .strokeBorder(
                                isHighlighted && !isSelected ? palette.lineStrong : Color.clear,
                                lineWidth: 1)
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .leading) {
            if let color {
                TabColorMark(color: color)
                    .padding(.vertical, 8)
                    .padding(.leading, 2)
            }
        }
        .onHover { isHovering = $0 }
        .accessibilityLabel(spokenLabel)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private var spokenLabel: String {
        guard let color else { return entry.label }
        return "\(entry.label), \(color.label)"
    }

    private var fill: Color {
        if isSelected { return palette.hover2 }
        if isHovering || isHighlighted { return palette.hover }
        return .clear
    }
}
