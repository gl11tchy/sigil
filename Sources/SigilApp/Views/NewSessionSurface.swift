import SigilKit
import SwiftUI

/// An empty terminal, ready to start with the provider's existing defaults.
/// Marks are quiet; names, availability and keyboard focus stay readable.
struct NewSessionSurface: View {
    @Bindable var model: AppModel
    @Environment(\.palette) private var palette
    @FocusState private var focusedProvider: CLIProvider?
    @FocusState private var isProviderRowFocused: Bool
    @State private var keyboardProvider: CLIProvider
    @State private var hoveredProvider: CLIProvider?
    @State private var inspectedProvider: CLIProvider?

    private var terminalBackground: Color { Color(nsColor: Palette.nsColor(model.settings.theme.backgroundHex)) }

    init(model: AppModel) {
        self.model = model
        _keyboardProvider = State(initialValue: model.settings.defaultProvider)
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 24) {
                Spacer(minLength: 20)
                LazyVGrid(
                    columns: Array(
                        repeating: GridItem(.flexible(), spacing: 12), count: geometry.size.width < 620 ? 3 : 6),
                    spacing: 24
                ) {
                    ForEach(CLIProvider.allCases) { provider in
                        providerButton(provider)
                    }
                }
                .frame(maxWidth: 680)
                .focusable()
                .focusEffectDisabled()
                .focused($isProviderRowFocused)
                .onKeyPress(.return) {
                    let provider = focusedProvider ?? keyboardProvider
                    inspectedProvider = provider
                    Task { await model.startDefaultSession(provider) }
                    return .handled
                }
                VStack(spacing: 8) {
                    if model.isStartingNewSession {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Starting session…").ui(12)
                        }
                    } else {
                        Text(feedback)
                            .ui(12)
                            .multilineTextAlignment(.center)
                    }
                    HStack(spacing: 18) {
                        Button("Options…") { model.showNewSessionOptions() }
                        if !model.tabs.isEmpty {
                            Button("Return to session") { model.cancelNewSession() }
                        }
                    }
                    .buttonStyle(.plain)
                    .ui(12)
                    .disabled(model.isStartingNewSession)
                }
                .foregroundStyle(palette.ink2)
                .frame(maxWidth: 520, minHeight: 56)
                Spacer(minLength: 20)
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(terminalBackground)
        .accessibilityIdentifier("new-session-surface")
        .defaultFocus($isProviderRowFocused, true)
        .task(id: model.newSessionFocusToken) {
            guard !model.isShowingNewSessionSheet else { return }
            keyboardProvider = model.settings.defaultProvider
            isProviderRowFocused = true
        }
        .onKeyPress(.leftArrow) { moveFocus(-1) }
        .onKeyPress(.rightArrow) { moveFocus(1) }
        .onKeyPress(.escape) {
            model.cancelNewSession()
            return .handled
        }
    }

    private var feedback: String {
        if let provider = inspectedProvider ?? focusedProvider ?? (isProviderRowFocused ? keyboardProvider : nil),
            let problem = availabilityDescription(provider)
        {
            return problem
        }
        return "Choose a CLI to start with your defaults."
    }

    private func providerButton(_ provider: CLIProvider) -> some View {
        let problem = availabilityDescription(provider)
        let needsCheck = canRequestCheck(provider)
        let isChecking = model.checkingProviders.contains(provider)
        let focused = focusedProvider == provider || (isProviderRowFocused && keyboardProvider == provider)
        let emphasized = focused || hoveredProvider == provider
        let shape = RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
        return Button {
            inspectedProvider = provider
            Task { await model.startDefaultSession(provider) }
        } label: {
            VStack(spacing: 10) {
                ImpressedProviderMark(
                    provider: provider, background: terminalBackground,
                    isDark: model.settings.theme.isDark, emphasized: emphasized
                )
                .frame(width: 52, height: 52)
                Text(provider.name)
                    .ui(12, .medium)
                    .foregroundStyle(palette.ink2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Text(
                    isChecking ? "Checking…" : needsCheck ? "Check required" : problem == nil ? "" : "Unavailable"
                )
                .ui(11)
                .foregroundStyle(palette.ink2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .contentShape(shape)
            .overlay(shape.strokeBorder(focused ? palette.accent : .clear, lineWidth: 1))
        }
        .buttonStyle(ProviderSurfaceButtonStyle())
        .focusEffectDisabled()
        .focused($focusedProvider, equals: provider)
        .disabled(model.isStartingNewSession || isChecking || (problem != nil && !needsCheck))
        .onHover { hoveredProvider = $0 ? provider : nil }
        .help(problem ?? "Start \(provider.name) with your defaults")
        .accessibilityLabel(provider.name)
        .accessibilityValue(problem ?? "Available")
        .accessibilityHint(problem ?? "Starts a new session with your defaults")
        .accessibilityIdentifier("new-session-\(provider.rawValue)")
    }

    private func canRequestCheck(_ provider: CLIProvider) -> Bool {
        model.providerRequiresCheck(provider) && !model.checkingProviders.contains(provider)
            && (provider != .grokBuild || model.settings.executableExists)
    }

    private func availabilityDescription(_ provider: CLIProvider) -> String? {
        canRequestCheck(provider) ? "Check \(provider.name) before starting." : model.providerLaunchProblem(provider)
    }

    private func moveFocus(_ offset: Int) -> KeyPress.Result {
        guard !model.isStartingNewSession else { return .handled }
        inspectedProvider = nil
        keyboardProvider = NewSessionLaunch.provider(after: focusedProvider ?? keyboardProvider, movingBy: offset)
        focusedProvider = nil
        isProviderRowFocused = true
        return .handled
    }
}

/// The mark has the terminal's own ground. A shallow dark upper edge and
/// light lower edge make an impression in it; hover clarifies the silhouette.
private struct ImpressedProviderMark: View {
    let provider: CLIProvider
    let background: Color
    let isDark: Bool
    let emphasized: Bool

    var body: some View {
        let mark = ProviderMark(data: ProviderMarks.data(for: provider))
        mark
            .fill(
                background
                    .shadow(.inner(color: .black.opacity(isDark ? 0.7 : 0.2), radius: 1.2, x: 0.8, y: 0.8))
                    .shadow(.inner(color: .white.opacity(isDark ? 0.1 : 0.8), radius: 1.2, x: -0.8, y: -0.8)),
                style: FillStyle(eoFill: true)
            )
            .shadow(color: .black.opacity(isDark ? 0.85 : 0.22), radius: 0.8, x: -0.8, y: -0.8)
            .shadow(color: .white.opacity(isDark ? 0.12 : 0.85), radius: 0.8, x: 0.8, y: 0.8)
            .overlay(
                mark.stroke(
                    isDark
                        ? Color.white.opacity(emphasized ? 0.22 : 0.065)
                        : Color.black.opacity(emphasized ? 0.24 : 0.07), lineWidth: 0.6)
            )
            .padding(3)
            .accessibilityHidden(true)
    }
}

/// A disabled CLI still needs readable status text. The plain system style
/// dims the whole label, including the explanation; only our mark is subdued.
private struct ProviderSurfaceButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.label }
}
