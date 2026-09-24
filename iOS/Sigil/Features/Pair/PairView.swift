import SwiftUI

struct PairView: View {
    @Environment(RemoteStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    /// Shown as a sheet from a paired phone to add another Mac.
    var embedded = false
    @State private var scanning = false
    @State private var pasting = false
    @State private var link = ""
    @State private var problem: String?
    @FocusState private var linkFocused: Bool

    private var waiting: Bool { store.phase == .connecting }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.large) {
                    header
                    steps
                    if waiting {
                        HStack(spacing: Theme.Space.smallText) {
                            ProgressView()
                            Text("Connecting to your Mac…")
                                .foregroundStyle(Theme.secondaryText)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentCard()
                        .accessibilityElement(children: .combine)
                    }
                    if let message = problem ?? store.errorMessage {
                        Label(message, systemImage: Theme.cautionSymbol)
                            .foregroundStyle(Theme.primaryText)
                            .symbolRenderingMode(.multicolor)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentCard()
                    }
                    if pasting { pasteField }
                }
                .padding(Theme.Space.large)
            }
            .flowsUnderChrome()
            .background(Theme.groupedBackground)
            .safeAreaInset(edge: .bottom) { actions }
            .navigationTitle(embedded ? "Pair another Mac" : AppInfo.displayName)
            .toolbar {
                if embedded {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            store.cancelPairing()
                            dismiss()
                        }
                    }
                }
            }
            .onChange(of: store.activeMacID) { _, id in
                // The new Mac accepted the phone: the sheet's job is done.
                if embedded, id != nil, store.isConnected || store.hasPairing { dismiss() }
            }
            .onDisappear {
                // A swipe down is a cancel too; the Mac that was on screen comes back.
                if embedded, store.isPairingAnother { store.cancelPairing() }
            }
            .sheet(isPresented: $scanning) {
                ScannerSheet { code in
                    scanning = false
                    submit(code)
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Space.smallText) {
            Text("Pick up where you left off.")
                .font(Theme.display(30))
                .foregroundStyle(Theme.primaryText)
            Text("Your Mac sessions, on your phone. Read the output, reply, and send photos.")
                .foregroundStyle(Theme.secondaryText)
        }
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: Theme.Space.mediumText) {
            step(1, "On your Mac, open Sigil → Settings → Remote.")
            step(2, "Select Connect Phone.")
            step(3, "Scan the code here. It expires in five minutes.")
            Divider()
            Label("Keep Sigil open and your Mac awake.", systemImage: "desktopcomputer")
                .font(.subheadline)
                .foregroundStyle(Theme.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentCard()
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.smallText) {
            Text("\(number)")
                .font(Theme.numeric)
                .foregroundStyle(Theme.accent)
                .frame(minWidth: 18, alignment: .leading)
            Text(text)
                .foregroundStyle(Theme.primaryText)
        }
        .accessibilityElement(children: .combine)
    }

    private var pasteField: some View {
        VStack(alignment: .leading, spacing: Theme.Space.smallText) {
            Text("Pairing link")
                .sectionLabelStyle()
            TextField("https://…#room=…", text: $link, axis: .vertical)
                .font(Theme.mono)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .submitLabel(.go)
                .focused($linkFocused)
                .padding(Theme.Space.small)
                .background(Theme.controlBackground, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
                .onSubmit { submit(link) }
                .privacySensitive()
            Button("Pair") { submit(link) }
                .buttonStyle(.borderedProminent)
                .disabled(link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || waiting)
        }
        .contentCard()
    }

    private var actions: some View {
        HStack(spacing: Theme.Space.small) {
            Button {
                problem = nil
                scanning = true
            } label: {
                Label("Scan code", systemImage: "qrcode.viewfinder")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.floatingGlass(tint: Theme.accentDeep, prominent: true))
            .disabled(waiting)

            // Pasting into the field below never triggers the clipboard permission prompt.
            Button {
                problem = nil
                pasting = true
                linkFocused = true
            } label: {
                Label("Paste link", systemImage: "doc.on.clipboard")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.floatingGlass())
            .disabled(waiting)
        }
        .padding(.horizontal, Theme.Space.large)
        .padding(.bottom, Theme.Space.small)
    }

    private func submit(_ text: String) {
        problem = store.pair(with: text)
        if problem == nil {
            link = ""
            linkFocused = false
        }
    }
}
