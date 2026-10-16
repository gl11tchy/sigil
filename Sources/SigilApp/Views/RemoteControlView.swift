import AppKit
import CoreImage.CIFilterBuiltins
import SigilKit
import SwiftUI

struct RemoteControlView: View {
    @Bindable var model: AppModel
    @State private var copiedLink = false
    @State private var showsServer = false
    @AppStorage("remoteServerURL") private var serverURL = RemoteControl.productionOrigin
    @Environment(\.palette) private var palette

    var body: some View {
        SettingsPage {
            SettingsSection(
                title: "Phone",
                footer: "Scan once to pair. Disconnect revokes your phone’s access. "
                    + "Sigil asks macOS to stay awake while your phone is connected "
                    + "or a verified task works with alerts on. "
                    + "After two hours without verified task progress, the work request ends. "
                    + "Closing the lid or choosing Sleep can still put the Mac to sleep."
            ) {
                HStack(spacing: 10) {
                    Image(systemName: "iphone")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(palette.ink2)
                        .frame(width: 20)
                    Text("Use your open sessions from your phone.")
                        .ui(13)
                        .foregroundStyle(palette.ink)
                    Spacer(minLength: 8)
                    if model.remoteControl.isEnabled {
                        StatusPill(
                            text: model.remoteControl.isPaired ? "Connected" : "Waiting",
                            tone: model.remoteControl.isPaired ? .green : .orange
                        )
                    }
                }
                .padding(12)
                SettingsDivider()
                if model.remoteControl.isEnabled {
                    SettingsRow(label: "Status") {
                        Text(model.remoteControl.status)
                            .ui(13)
                            .foregroundStyle(palette.ink2)
                    }
                    SettingsDivider()
                }
                HStack(spacing: 8) {
                    Button {
                        withAnimation(Motion.fade) { showsServer.toggle() }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                                .rotationEffect(.degrees(showsServer ? 90 : 0))
                            Text("Server address").ui(13)
                        }
                        .foregroundStyle(palette.ink2)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Server address")
                    .accessibilityValue(showsServer ? "Expanded" : "Collapsed")
                    Spacer(minLength: 8)
                    actions
                }
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                if showsServer {
                    FieldFrame(isFocused: false, height: 28) {
                        TextField(
                            "", text: $serverURL,
                            prompt: Text("https://…").foregroundStyle(palette.ink2)
                        )
                        .textFieldStyle(.plain)
                        .mono(12)
                        .foregroundStyle(palette.ink)
                        .disabled(model.remoteControl.isEnabled)
                        .accessibilityLabel("Server address")
                    }
                    .padding([.horizontal, .bottom], 12)
                }
            }
            if let url = model.remoteControl.pairingURL, let expiry = model.remoteControl.expiresAt {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    VStack(spacing: 12) {
                        if context.date < expiry {
                            if let image = Self.qrImage(url.absoluteString) {
                                Image(nsImage: image)
                                    .interpolation(.none)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 176, height: 176)
                                    .padding(12)
                                    .background(.white)
                                    .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                                    .accessibilityLabel("QR code. Scan it on your phone to connect")
                            }
                            Text("Scan this code with your phone’s camera")
                                .ui(13, .medium)
                                .foregroundStyle(palette.ink)
                            HStack(spacing: 10) {
                                Button(copiedLink ? "Copied" : "Copy Pairing Link") {
                                    copiedLink = Self.copy(url, to: .general)
                                }
                                .buttonStyle(.secondary)
                                .help("Paste this link into Sigil Remote on your phone")
                                Text("Expires in \(max(0, Int(expiry.timeIntervalSince(context.date)))) s")
                                    .mono(11.5)
                                    .monospacedDigit()
                                    .foregroundStyle(palette.ink2)
                            }
                        } else {
                            Text("This code expired.")
                                .ui(13, .medium)
                                .foregroundStyle(palette.ink)
                            Button("New Code") { model.remoteControl.start(urlText: serverURL, model: model) }
                                .buttonStyle(.primary)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                    .surface(palette.surface, radius: Radius.card, elevation: .card)
                }
            }
            if let error = model.remoteControl.error {
                Text(error)
                    .ui(12.5)
                    .foregroundStyle(palette.redInk)
                    .padding(.horizontal, 4)
            }
        }
        // Tall enough for the card, the code, and its buttons without a scroll.
        .frame(minHeight: model.remoteControl.pairingURL == nil ? 300 : 620)
        .onChange(of: model.remoteControl.pairingURL) { _, _ in copiedLink = false }
        .onAppear { serverURL = RemoteControl.preferredOrigin(serverURL) }
    }

    @ViewBuilder
    private var actions: some View {
        if model.remoteControl.isEnabled {
            if model.remoteControl.isPaired {
                Button("Disconnect", role: .destructive) { model.remoteControl.stop(revoke: true) }
                    .buttonStyle(.destructive)
            } else if let pending = model.remoteControl.pendingPairingGeneration {
                // Keep this rendered intent even if confirmation arrives before
                // the view redraws. Cancel must never become Disconnect.
                Button("Cancel", role: .cancel) { model.remoteControl.cancelPairing(generation: pending) }
                    .buttonStyle(.secondary)
            }
        } else {
            if model.remoteControl.revokeFailed {
                Button("Disconnect", role: .destructive) { model.remoteControl.stop(revoke: true) }
                    .buttonStyle(.destructive)
            }
            Button("Connect Phone") { model.remoteControl.start(urlText: serverURL, model: model) }
                .buttonStyle(.primary)
                .disabled(serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    /// The link pairs a phone, so clipboard managers are asked not to keep it.
    static func copy(_ link: URL, to pasteboard: NSPasteboard) -> Bool {
        let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
        pasteboard.clearContents()
        pasteboard.declareTypes([.string, concealed], owner: nil)
        return pasteboard.setString(link.absoluteString, forType: .string)
            && pasteboard.setString("", forType: concealed)
    }

    static func qrImage(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage,
            let cgImage = CIContext().createCGImage(output, from: output.extent)
        else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: output.extent.width, height: output.extent.height))
    }
}
