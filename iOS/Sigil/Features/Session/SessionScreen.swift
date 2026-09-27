import SwiftUI
import UIKit

struct SessionScreen: View {
    @Environment(RemoteStore.self) private var store
    @State private var showingSessions = false
    @State private var showingProjects = false
    @State private var confirmingForget = false
    @State private var addingMac = false
    @State private var finding = false
    @State private var findText = ""
    @State private var atBottom = true
    @State private var scrollToEnd = 0
    @State private var composerHeight: CGFloat = 0
    /// The composer's top in the window, so the output can inset all that lies below it.
    @State private var composerTop: CGFloat?
    /// The screen's bottom safe area; the page keeps at least 8pt clear of the edge.
    @State private var bottomInset: CGFloat = 0
    /// The page's height above the keyboard; the approval card and keys take at most 40% of it.
    @State private var pageHeight: CGFloat?
    @FocusState private var findFocused: Bool

    var body: some View {
        NavigationStack {
            content
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    CoverSlot {
                        if store.selectedTab != nil, !store.isRevoked {
                            ComposerBar(upperLimit: pageHeight.map { $0 * 0.4 } ?? .infinity)
                        }
                    } changed: {
                        composerHeight = $0?.height ?? 0
                        composerTop = $0?.minY
                    }
                }
                .page()
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { pageHeight = $0 }
                .padding(.top, Theme.Space.s8)
                .padding(.horizontal, Theme.Space.s8)
                // The web companion's `max(8px, env(safe-area-inset-bottom))`.
                .padding(.bottom, max(0, Theme.Space.s8 - bottomInset))
                .background(Theme.canvas)
                .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.bottom } action: { bottomInset = $0 }
                .safeAreaInset(edge: .top, spacing: 0) { banners }
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
                .sheet(isPresented: $addingMac) { PairView(embedded: true) }
                .confirmationDialog(
                    "Forget this Mac?", isPresented: $confirmingForget, titleVisibility: .visible
                ) {
                    Button("Forget", role: .destructive) { store.forget() }
                } message: {
                    Text(
                        store.macs.count > 1
                            ? "Your other Macs stay paired. Scan a new code to add this one back."
                            : "You will need to scan a new code in Sigil to connect again.")
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        if store.isRevoked {
            ContentUnavailableView {
                EmptyLabel(title: "Pairing ended", symbol: "link.badge.plus")
            } description: {
                EmptyDetail(text: "This Mac disconnected the phone, or the code expired. Scan a new code in Sigil.")
            } actions: {
                Button("Pair again") { store.forget() }
                    .buttonStyle(.primary)
            }
        } else if store.tabs.isEmpty {
            ContentUnavailableView {
                EmptyLabel(title: store.isConnected ? "No open sessions" : "Reconnecting", symbol: "terminal")
            } description: {
                EmptyDetail(
                    text: store.isConnected
                        ? "Start a session in one of your projects."
                        : "Keep Sigil open and your Mac awake.")
            } actions: {
                if store.isConnected {
                    Button("New session") { startNewSession() }
                        .buttonStyle(.primary)
                }
            }
        } else if store.output.isEmpty {
            ContentUnavailableView {
                EmptyLabel(title: emptyTitle, symbol: emptySymbol, status: store.selectedTab?.status)
            } description: {
                EmptyDetail(text: emptyDetail)
            } actions: {
                if store.selectedTab?.status == .exited, store.canRestart {
                    Button("Restart") { store.restart() }
                        .buttonStyle(.primary)
                        .disabled(!store.isConnected || store.busy)
                }
            }
        } else {
            OutputView(
                styled: store.styledOutput, palette: store.palette, foreground: store.themeForeground,
                background: store.themeBackground, revision: store.outputRevision, highlight: finding ? findText : "",
                onNearTop: { store.loadEarlier() }, atBottom: $atBottom, scrollToEnd: scrollToEnd,
                coverTop: composerTop
            )
            // Under the composer to the page's foot; the page clips it to its corners.
            .ignoresSafeArea(.container, edges: .bottom)
            // A new output view lands at the end; the last one's place must not hold it back.
            .onAppear { atBottom = true }
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
        VStack(spacing: Theme.Space.small) {
            if finding { findBar }
            if !store.isConnected, !store.isRevoked, !store.isDemo {
                HStack(spacing: Theme.Space.small) {
                    PixelLoader(color: Theme.ink3)
                    Text(reconnectingText)
                        .typeStep(.body)
                        .foregroundStyle(Theme.ink)
                    Spacer(minLength: 0)
                    Button {
                        store.reconnect()
                    } label: {
                        Text("Retry").foregroundStyle(Theme.accentInk)
                    }
                    .buttonStyle(.ghost)
                }
                .padding(.leading, Theme.Space.medium)
                .surface(radius: Theme.Radius.card, elevation: .raised)
                .accessibilityElement(children: .combine)
            }
            if let error = store.errorMessage, !store.isRevoked {
                Button {
                    store.errorMessage = nil
                } label: {
                    // A failure, as the web companion's page error: `redInk` on the red tint.
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Space.small) {
                        Image(systemName: Theme.dangerSymbol)
                            .font(Theme.font(.body))
                            .foregroundStyle(Theme.red)
                        Text(error)
                            .typeStep(.body)
                            .foregroundStyle(Theme.redInk)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                        Image(systemName: "xmark")
                            .font(Theme.font(.small, weight: .semibold))
                            .foregroundStyle(Theme.redInk)
                    }
                    .padding(Theme.Space.medium)
                    .background(
                        Theme.redTint, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityHint("Dismisses the message")
            }
        }
        .padding(.horizontal, Theme.Space.s8)
        .padding(.top, Theme.Space.tight)
        .themeAnimation(Theme.Motion.slide, value: store.errorMessage)
    }

    private var findBar: some View {
        HStack(spacing: Theme.Space.tight) {
            Image(systemName: "magnifyingglass")
                .font(Theme.glyph)
                .foregroundStyle(Theme.ink3)
                .accessibilityHidden(true)
            TextField("Find in output", text: $findText, prompt: Text("Find in output").foregroundStyle(Theme.ink2))
                .typeStep(.field)
                .foregroundStyle(Theme.ink)
                .focused($findFocused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
            Button {
                finding = false
                findText = ""
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(Theme.glyph)
            }
            .buttonStyle(.icon)
            .accessibilityLabel("Close find")
        }
        .padding(.leading, Theme.Space.large)
        .surface(in: Capsule(), elevation: .overlay)
        // A field's focus ring, drawn over the pill's own.
        .overlay { Capsule().strokeBorder(findFocused ? Theme.accent : .clear, lineWidth: 1) }
        .themeAnimation(Theme.Motion.fade, value: findFocused)
    }

    @ViewBuilder
    private var latestButton: some View {
        if !atBottom, !store.output.isEmpty {
            Button {
                scrollToEnd += 1
            } label: {
                Image(systemName: "arrow.down")
                    .font(Theme.glyph)
                    .foregroundStyle(Theme.ink)
                    .frame(width: 40, height: 40)
                    .surface(in: Circle(), elevation: .raised)
            }
            .buttonStyle(.icon)
            .accessibilityLabel("Jump to latest output")
            // Over the output, 12pt in from the page's corner and clear of the composer.
            .padding(.trailing, Theme.Space.s20)
            .padding(.bottom, max(0, Theme.Space.s8 - bottomInset) + composerHeight + Theme.Space.s12)
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
            .tint(Theme.ink3)
            .disabled(store.isRevoked)
        }
        .sharedBackgroundVisibility(.hidden)
        ToolbarItem(placement: .principal) {
            Button {
                showingSessions = true
            } label: {
                VStack(spacing: 0) {
                    Text(store.selectedTab?.title ?? AppInfo.displayName)
                        .typeStep(.title)
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    HStack(spacing: Theme.Space.s6) {
                        statusMark
                        Text(statusText)
                            .typeStep(.small)
                            .foregroundStyle(statusInk)
                            .lineLimit(1)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(store.selectedTab?.title ?? "No session"), \(statusText)")
            .accessibilityShowsLargeContentViewer {
                Text("\(store.selectedTab?.title ?? AppInfo.displayName), \(statusText)")
            }
            .accessibilityHint("Shows your sessions")
            .privacySensitive()
        }
        .sharedBackgroundVisibility(.hidden)
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
                Button {
                    addingMac = true
                } label: {
                    Label("Pair another Mac", systemImage: "desktopcomputer.and.arrow.down")
                }
                Button(role: .destructive) {
                    confirmingForget = true
                } label: {
                    Label(store.macs.count > 1 ? "Forget \(store.macName ?? "this Mac")" : "Forget this Mac", systemImage: "trash")
                }
            } label: {
                Label("More", systemImage: "ellipsis")
            }
            .tint(Theme.ink3)
        }
        .sharedBackgroundVisibility(.hidden)
    }

    /// The state vocabulary beside the status line: the pixel loader while
    /// starting or working, an `ink3` dot once ended, nothing when idle, and an
    /// `orange` dot while the phone cannot reach the Mac.
    @ViewBuilder
    private var statusMark: some View {
        if !store.isConnected {
            StatusDot(color: Theme.orange)
        } else if let status = store.selectedTab?.status, status != .idle {
            ActivityMark(status: status)
        }
    }

    private var statusInk: Color {
        if !store.isConnected { return Theme.orangeInk }
        return store.selectedTab?.status == .working ? Theme.ink : Theme.ink2
    }

    private var statusText: String {
        if store.isRevoked { return "Disconnected" }
        if !store.isConnected { return "Reconnecting…" }
        let status = store.selectedTab?.status.label ?? "No session"
        var parts = [status]
        if let provider = store.selectedTab?.providerName { parts.insert(provider, at: 0) }
        if store.macs.count > 1, let mac = store.macName { parts.append(mac) }
        return parts.joined(separator: " · ")
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

extension View {
    /// Sets the view on the page, as the web companion's `main`: a `page` fill
    /// in a closed `window`-radius rectangle with a 1px `line` ring. The output
    /// and the composer sit inside it, and it clips both to its corners.
    fileprivate func page() -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.window, style: .continuous)
        return frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.page, in: shape)
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(Theme.line, lineWidth: 1)
                    .allowsHitTesting(false)
            }
    }
}

/// An empty state's heading in Inter: the title in `ink` under a quiet `ink3`
/// glyph, or under the pixel loader while the session starts or works.
private struct EmptyLabel: View {
    let title: String
    let symbol: String
    var status: TabStatus?

    var body: some View {
        Label {
            if status == .working {
                ShimmerText(text: title, step: .title)
            } else {
                Text(title)
                    .typeStep(.title)
                    .foregroundStyle(Theme.ink)
            }
        } icon: {
            switch status {
            case .working?:
                PixelLoader(color: Theme.accent).scaleEffect(2).frame(width: 32, height: 32)
            case .starting?:
                PixelLoader(color: Theme.ink3).scaleEffect(2).frame(width: 32, height: 32)
            default:
                Image(systemName: symbol)
                    .font(Theme.inter(32, relativeTo: .largeTitle))
                    .foregroundStyle(Theme.ink3)
            }
        }
    }
}

/// An empty state's explanation: body text in `ink2`.
private struct EmptyDetail: View {
    let text: String

    var body: some View {
        Text(text)
            .typeStep(.body)
            .foregroundStyle(Theme.ink2)
    }
}
