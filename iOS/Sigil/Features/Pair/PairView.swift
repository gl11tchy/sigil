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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// The step number's key: 22pt at the default text size, as on the web companion.
    @ScaledMetric(relativeTo: .body) private var stepBadge: CGFloat = 22

    private var waiting: Bool { store.phase == .connecting }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.large) {
                    header
                    steps
                    if waiting {
                        HStack(spacing: Theme.Space.smallText) {
                            PixelLoader(color: Theme.accent)
                            Text("Connecting to your Mac…")
                                .typeStep(.body)
                                .foregroundStyle(Theme.ink2)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentCard()
                        .accessibilityElement(children: .combine)
                    }
                    if let message = problem ?? store.errorMessage {
                        // A failure: `redInk` words on the red tint, as the web companion's error.
                        Label {
                            Text(message)
                                .typeStep(.body)
                                .foregroundStyle(Theme.redInk)
                        } icon: {
                            Image(systemName: Theme.dangerSymbol)
                                .font(Theme.glyph)
                                .foregroundStyle(Theme.red)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Theme.Space.medium)
                        .background(
                            Theme.redTint, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                    }
                    if pasting { pasteField }
                }
                .padding(Theme.Space.large)
            }
            .flowsUnderChrome()
            .background(Theme.canvas)
            .safeAreaInset(edge: .bottom) { actions }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.canvas, for: .navigationBar)
            .toolbarBackgroundVisibility(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(title)
                        .typeStep(.title)
                        .foregroundStyle(Theme.ink)
                        .accessibilityAddTraits(.isHeader)
                }
                if embedded {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            store.cancelPairing()
                            dismiss()
                        }
                        .buttonStyle(.bar)
                    }
                    .sharedBackgroundVisibility(.hidden)
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

    private var title: String { embedded ? "Pair another Mac" : AppInfo.displayName }

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Space.smallText) {
            // The web companion's welcome heading: 24pt Inter 600, tracked in -0.02em.
            Text("Pick up where you left off.")
                .font(Theme.inter(24, Theme.emphasis(.semibold), relativeTo: .title))
                .tracking(-0.48)
                .foregroundStyle(Theme.ink)
            Text("Your Mac sessions, on your phone. Read the output, reply, and send photos.")
                .typeStep(.row)
                .foregroundStyle(Theme.ink2)
        }
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: Theme.Space.mediumText) {
            step(1, "On your Mac, open Sigil → Settings → Remote.")
            step(2, "Select Connect Phone.")
            step(3, "Scan the code here. It expires in five minutes.")
            Rectangle()
                .fill(Theme.lineSoft)
                .frame(height: 1)
            Label {
                Text("Keep Sigil open and your Mac awake.")
                    .typeStep(.small)
                    .foregroundStyle(Theme.ink2)
            } icon: {
                Image(systemName: "desktopcomputer")
                    .foregroundStyle(Theme.ink3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentCard()
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.smallText) {
            Text("\(number)")
                .font(Theme.font(.mono, weight: .medium))
                .foregroundStyle(Theme.ink)
                .frame(minWidth: stepBadge, minHeight: stepBadge)
                .background(Theme.hover2, in: RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
            Text(text)
                .typeStep(.body)
                .foregroundStyle(Theme.ink)
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
                .foregroundStyle(Theme.ink)
                .focused($linkFocused)
                .padding(.horizontal, Theme.Space.medium)
                .padding(.vertical, Theme.Space.small)
                .frame(minHeight: Theme.tapTarget)
                .fieldBackground(isFocused: linkFocused)
                .onSubmit { submit(link) }
                .privacySensitive()
            Button("Pair") { submit(link) }
                .buttonStyle(.primary)
                .disabled(link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || waiting)
        }
        .contentCard()
    }

    private var actions: some View {
        // Side by side; stacked at accessibility sizes, so each label keeps a full line.
        let layout =
            dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: Theme.Space.small))
            : AnyLayout(HStackLayout(spacing: Theme.Space.small))
        return layout {
            Button {
                problem = nil
                scanning = true
            } label: {
                Label("Scan code", systemImage: "qrcode.viewfinder")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.primary)
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
            .buttonStyle(.secondary)
            .disabled(waiting)
        }
        .padding(.horizontal, Theme.Space.large)
        .padding(.top, Theme.Space.small)
        .padding(.bottom, Theme.Space.small)
        // Opaque chrome: the steps scroll under the canvas, not under the buttons' gap.
        .background(Theme.canvas)
    }

    private func submit(_ text: String) {
        problem = store.pair(with: text)
        if problem == nil {
            link = ""
            linkFocused = false
        }
    }
}
