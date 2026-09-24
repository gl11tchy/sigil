import AppKit
import SigilKit
import SwiftUI

/// How Kimi Code tabs sign in: the Kimi account `kimi login` stores, or a
/// Kimi Platform API key kept in the Keychain.
struct KimiSettingsSection: View {
    @Bindable var model: AppModel
    @Environment(\.palette) private var palette
    @State private var login = KimiLogin()
    @State private var keyDraft = ""
    @State private var isReplacingKey = false
    @State private var keyError: String?
    @FocusState private var focusedField: Field?

    private enum Field {
        case key
        case model
    }

    var body: some View {
        SettingsSection(
            title: "Kimi Code",
            footer:
                "A Kimi account uses your Kimi Code plan. An API key comes from platform.kimi.ai and stays in the Keychain. Applies to Kimi tabs opened after this change."
        ) {
            SettingsRow(label: "Sign in with") {
                Picker("Sign in with", selection: Bindable(model.settings).kimiSignIn) {
                    ForEach(KimiSignIn.allCases) { method in
                        Text(method.label).tag(method)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
            }
            SettingsDivider()
            switch model.settings.kimiSignIn {
            case .kimiAccount:
                accountRow
            case .apiKey:
                keyRow
                SettingsDivider()
                modelRow
            }
        }
        .onAppear { login.refresh() }
        // Its Cancel button leaves with the account row.
        .onChange(of: model.settings.kimiSignIn) { _, method in
            if method != .kimiAccount { login.cancel() }
        }
    }

    // MARK: Kimi account

    private var accountRow: some View {
        SettingsRow(label: "Account") {
            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 8) {
                    if case .waiting(let code, let page) = login.state {
                        ProgressView().controlSize(.small)
                        Text(code.map { "Code \($0)" } ?? "Opening browser…")
                            .mono(12)
                            .foregroundStyle(palette.ink)
                            .textSelection(.enabled)
                        if let page {
                            Button("Open Page") { NSWorkspace.shared.open(page) }
                                .buttonStyle(SigilButtonStyle(kind: .secondary, height: 26))
                        }
                        Button("Cancel") { login.cancel() }
                            .buttonStyle(SigilButtonStyle(kind: .secondary, height: 26))
                    } else {
                        status(
                            login.isSignedIn ? "Signed in" : "Not signed in",
                            isGood: login.isSignedIn)
                        Button(login.isSignedIn ? "Sign In Again…" : "Sign In…") { login.start() }
                            .buttonStyle(SigilButtonStyle(kind: .secondary, height: 26))
                    }
                }
                if case .failed(let message) = login.state {
                    Text(message)
                        .ui(12)
                        .foregroundStyle(palette.redInk)
                        .lineLimit(2)
                }
            }
        }
    }

    // MARK: API key

    private var keyRow: some View {
        SettingsRow(label: "API key") {
            VStack(alignment: .trailing, spacing: 4) {
                if model.hasKimiAPIKey && !isReplacingKey {
                    HStack(spacing: 8) {
                        status("Saved in Keychain", isGood: true)
                        Button("Replace…") {
                            isReplacingKey = true
                            focusedField = .key
                        }
                        .buttonStyle(SigilButtonStyle(kind: .secondary, height: 26))
                        Button("Remove") { model.removeKimiAPIKey() }
                            .buttonStyle(SigilButtonStyle(kind: .secondary, height: 26))
                    }
                } else {
                    HStack(spacing: 8) {
                        FieldFrame(isFocused: focusedField == .key, height: 28) {
                            SecureField(
                                "", text: $keyDraft,
                                prompt: Text("Paste a key").foregroundStyle(palette.ink2)
                            )
                            .textFieldStyle(.plain)
                            .mono(12)
                            .foregroundStyle(palette.ink)
                            .focused($focusedField, equals: .key)
                            .onSubmit { saveKey() }
                            .accessibilityLabel("Kimi API key")
                        }
                        .frame(width: 200)
                        Button("Save") { saveKey() }
                            .buttonStyle(SigilButtonStyle(kind: .secondary, height: 28))
                            .disabled(keyDraft.nilIfEmpty == nil)
                        if isReplacingKey {
                            Button("Cancel") {
                                keyDraft = ""
                                keyError = nil
                                isReplacingKey = false
                            }
                            .buttonStyle(SigilButtonStyle(kind: .secondary, height: 28))
                        }
                    }
                    if let keyError {
                        Text(keyError)
                            .ui(12)
                            .foregroundStyle(palette.redInk)
                    }
                }
            }
        }
    }

    private var modelRow: some View {
        SettingsRow(label: "Model") {
            FieldFrame(isFocused: focusedField == .model, height: 28) {
                TextField(
                    "", text: Bindable(model.settings).kimiModel,
                    prompt: Text(KimiCode.defaultModel).foregroundStyle(palette.ink2)
                )
                .textFieldStyle(.plain)
                .mono(12)
                .foregroundStyle(palette.ink)
                .focused($focusedField, equals: .model)
                .accessibilityLabel("Kimi model")
            }
            .frame(width: 200)
        }
    }

    private func saveKey() {
        guard keyDraft.nilIfEmpty != nil else { return }
        if model.saveKimiAPIKey(keyDraft) {
            keyDraft = ""
            keyError = nil
            isReplacingKey = false
        } else {
            keyError = "The Keychain did not save the key."
        }
    }

    private func status(_ text: String, isGood: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: isGood ? "checkmark.circle.fill" : "circle.dashed")
                .font(.system(size: 11))
            Text(text).ui(12, .medium)
        }
        .foregroundStyle(isGood ? palette.greenInk : palette.ink2)
    }
}
