import CoreImage.CIFilterBuiltins
import SigilKit
import SwiftUI

struct RemoteControlView: View {
    @Bindable var model: AppModel
    @AppStorage("remoteServerURL") private var serverURL = ""

    var body: some View {
        Form {
            Section {
                TextField("Sidereal address", text: $serverURL, prompt: Text("https://…"))
                    .textFieldStyle(.roundedBorder)
                    .disabled(model.remoteControl.isEnabled)
                if model.remoteControl.isEnabled {
                    LabeledContent("Status", value: model.remoteControl.status)
                    Button("Disconnect", role: .destructive) { model.remoteControl.stop() }
                } else {
                    Button("Connect Phone") { model.remoteControl.start(urlText: serverURL, model: model) }
                        .disabled(serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } footer: {
                Text("Your phone can read and control open sessions. Keep this Mac awake.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
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
                                    .frame(width: 216, height: 216)
                                    .padding(12)
                                    .background(.white)
                                    .accessibilityLabel("Scan this QR code with your phone camera to connect")
                            }
                            Text("Scan with your phone’s camera")
                            Text("Expires in \(max(0, Int(expiry.timeIntervalSince(context.date)))) seconds")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("This code expired.")
                            Button("New Code") { model.remoteControl.start(urlText: serverURL, model: model) }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
            }
            if let error = model.remoteControl.error {
                Text(error).foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: model.remoteControl.pairingURL == nil ? 280 : 550)
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
