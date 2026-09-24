import SwiftUI
import UIKit

struct SessionScreen: View {
    @Environment(RemoteStore.self) private var store
    @State private var showingSessions = false
    @State private var showingProjects = false
    @State private var confirmingForget = false
    @State private var finding = false
    @State private var findText = ""
    @State private var atBottom = true
    @State private var scrollToEnd = 0
    @FocusState private var findFocused: Bool

    var body: some View {
        NavigationStack {
            content
                .background(Theme.background)
                .safeAreaInset(edge: .top, spacing: 0) { banners }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if store.selectedTab != nil, !store.isRevoked { ComposerBar() }
                }
                .overlay(alignment: .bottomTrailing) { latestButton }
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbar }
                .sheet(isPresented: $showingSessions) {
                    SessionsSheet(onNew: {
                        showingSessions = false
                        startNewSession()
                    })
                }
                .sheet(isPresented: $showingProjects) { NewSessionSheet() }
                .confirmationDialog(
                    "Forget this Mac?", isPresented: $confirmingForget, titleVisibility: .visible
                ) {
                    Button("Forget", role: .destructive) { store.forget() }
                } message: {
                    Text("You will need to scan a new code in Sigil to connect again.")
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        if store.isRevoked {
            ContentUnavailableView {
                Label("Pairing ended", systemImage: "link.badge.plus")
            } description: {
                Text("This Mac disconnected the phone, or the code expired. Scan a new code in Sigil.")
            } actions: {
                Button("Pair again") { store.forget() }
                    .buttonStyle(.borderedProminent)
            }
        } else if store.tabs.isEmpty {
            ContentUnavailableView {
                Label(store.isConnected ? "No open sessions" : "Reconnecting", systemImage: "terminal")
            } description: {
                Text(
                    store.isConnected
                        ? "Start a session in one of your projects."
                        : "Keep Sigil open and your Mac awake.")
            } actions: {
                if store.isConnected {
                    Button("New session") { startNewSession() }
                        .buttonStyle(.borderedProminent)
                }
            }
        } else if store.output.isEmpty {
            ContentUnavailableView {
                Label(emptyTitle, systemImage: emptySymbol)
            } description: {
                Text(emptyDetail)
            } actions: {
                if store.selectedTab?.status == .exited, store.canRestart {
                    Button("Restart") { store.restart() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!store.isConnected || store.busy)
                }
            }
        } else {
            OutputView(
                styled: store.styledOutput, palette: store.palette, revision: store.outputRevision,
                highlight: finding ? findText : "", onNearTop: { store.loadEarlier() }, atBottom: $atBottom,
                scrollToEnd: scrollToEnd
            )
            .ignoresSafeArea(.container, edges: .bottom)
            .privacySensitive()
        }
    }

    private var emptyTitle: String {
        switch store.selectedTab?.status {
        case .exited: return "Session ended"
        case .working: return "Working…"
        case .starting: return "Starting session…"
        default: return "Ready when you are."
        }
    }

    private var emptySymbol: String {
        store.selectedTab?.status == .exited ? "stop.circle" : "text.cursor"
    }

    private var emptyDetail: String {
        switch store.selectedTab?.status {
        case .exited:
            return store.canRestart
                ? "Restart resumes a Grok chat. Other providers start a new conversation."
                : "Restart this session in Sigil on your Mac."
        case .working, .starting: return "Output will appear here."
        default: return "Send a message to this session."
        }
    }

    @ViewBuilder
    private var banners: some View {
        VStack(spacing: Theme.Space.tight) {
            if finding { findBar }
            if !store.isConnected, !store.isRevoked, !store.isDemo {
                HStack(spacing: Theme.Space.tight) {
                    ProgressView().controlSize(.small)
                    Text(reconnectingText)
                        .font(.footnote)
                    Spacer(minLength: 0)
                    Button("Retry") { store.reconnect() }
                        .font(.footnote.weight(Theme.emphasis(.semibold)))
                        .buttonStyle(.icon)
                }
                .padding(.horizontal, Theme.Space.medium)
                .chromeGlass(.regular, in: Capsule())
                .accessibilityElement(children: .combine)
            }
            if let error = store.errorMessage, !store.isRevoked {
                Button {
                    store.errorMessage = nil
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Space.tight) {
                        Image(systemName: Theme.cautionSymbol)
                            .foregroundStyle(Theme.caution)
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(Theme.primaryText)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                        Image(systemName: "xmark")
                            .font(.caption2.weight(Theme.emphasis(.semibold)))
                            .foregroundStyle(Theme.secondaryText)
                    }
                    .padding(.horizontal, Theme.Space.medium)
                    .padding(.vertical, Theme.Space.small)
                    .chromeGlass(.regular, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityHint("Dismisses the message")
            }
        }
        .padding(.horizontal, Theme.Space.medium)
        .padding(.top, Theme.Space.tight)
        .themeAnimation(.snappy, value: store.errorMessage)
    }

    private var findBar: some View {
        HStack(spacing: Theme.Space.tight) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Theme.secondaryText)
                .accessibilityHidden(true)
            TextField("Find in output", text: $findText)
                .focused($findFocused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
            Button {
                finding = false
                findText = ""
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(Theme.secondaryText)
            }
            .buttonStyle(.icon)
            .accessibilityLabel("Close find")
        }
        .padding(.leading, Theme.Space.medium)
        .chromeGlass(.regular, in: Capsule())
    }

    @ViewBuilder
    private var latestButton: some View {
        if !atBottom, !store.output.isEmpty {
            Button {
                scrollToEnd += 1
            } label: {
                Image(systemName: "arrow.down")
                    .font(.body.weight(Theme.emphasis(.semibold)))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.floatingGlass())
            .accessibilityLabel("Jump to latest output")
            .padding(.trailing, Theme.Space.medium)
            .padding(.bottom, Theme.Space.small)
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                showingSessions = true
            } label: {
                Label("Sessions", systemImage: "sidebar.left")
            }
            .disabled(store.isRevoked)
        }
        ToolbarItem(placement: .principal) {
            Button {
                showingSessions = true
            } label: {
                VStack(spacing: 1) {
                    Text(store.selectedTab?.title ?? AppInfo.displayName)
                        .font(.subheadline.weight(Theme.emphasis(.semibold)))
                        .foregroundStyle(Theme.primaryText)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        Circle()
                            .fill(store.isConnected ? Theme.color(for: store.selectedTab?.status ?? .idle) : Theme.caution)
                            .frame(width: 6, height: 6)
                        Text(statusText)
                            .font(.caption2)
                            .foregroundStyle(Theme.secondaryText)
                    }
                }
                .frame(maxWidth: 240)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(store.selectedTab?.title ?? "No session"), \(statusText)")
            .accessibilityHint("Shows your sessions")
            .privacySensitive()
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button {
                    startNewSession()
                } label: {
                    Label("New session", systemImage: "plus")
                }
                .disabled(!store.isConnected || store.busy)
                Button {
                    finding = true
                    findFocused = true
                } label: {
                    Label("Find in output", systemImage: "magnifyingglass")
                }
                .disabled(store.output.isEmpty)
                Button {
                    UIPasteboard.general.setItems(
                        [[UIPasteboard.typeAutomatic: store.output]],
                        options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(600)])
                } label: {
                    Label("Copy output (clears in 10 min)", systemImage: "doc.on.doc")
                }
                .disabled(store.output.isEmpty)
                Toggle(isOn: Binding(get: { store.rawMode }, set: { store.rawMode = $0; store.refreshOutput() })) {
                    Label("Raw terminal", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                Divider()
                if !store.isConnected, !store.isRevoked {
                    Button {
                        store.reconnect()
                    } label: {
                        Label("Reconnect", systemImage: "arrow.clockwise")
                    }
                }
                Button(role: .destructive) {
                    confirmingForget = true
                } label: {
                    Label("Forget this Mac", systemImage: "trash")
                }
            } label: {
                Label("More", systemImage: "ellipsis")
            }
        }
    }

    private var statusText: String {
        if store.isRevoked { return "Disconnected" }
        if !store.isConnected { return "Reconnecting…" }
        let status = store.selectedTab?.status.label ?? "No session"
        guard let provider = store.selectedTab?.providerName else { return status }
        return "\(provider) · \(status)"
    }

    /// While the socket comes up, the screen shows what was last seen and says when.
    private var reconnectingText: String {
        if let seen = store.cachedAt {
            return "Reconnecting… Showing output from \(seen.formatted(date: .omitted, time: .shortened))."
        }
        return store.selectedTab == nil ? "Connecting…" : "Reconnecting… Your draft is kept."
    }

    private func startNewSession() {
        showingProjects = true
    }
}
