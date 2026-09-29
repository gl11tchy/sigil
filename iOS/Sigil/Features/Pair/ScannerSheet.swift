import AVFoundation
import SwiftUI
import UIKit

/// Full-screen camera that reads the pairing QR code from the Mac.
struct ScannerSheet: View {
    let onCode: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var access = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var rejected: String?

    var body: some View {
        NavigationStack {
            ZStack {
                // Black behind the camera; the canvas behind everything else.
                (access == .authorized ? Color.black : Theme.canvas).ignoresSafeArea()
                switch access {
                case .authorized:
                    QRCameraView { code in
                        switch PairingLink.parse(code) {
                        case .success: onCode(code)
                        case .failure(.insecure): rejected = "This code is for an address without HTTPS."
                        case .failure(.notALink): rejected = "That code is not a Sigil pairing code."
                        }
                    }
                    .ignoresSafeArea()
                    .accessibilityLabel("Camera viewfinder")
                    viewfinder
                case .notDetermined:
                    PixelLoader(color: Theme.ink3)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("In progress")
                default:
                    ContentUnavailableView {
                        Label {
                            Text("Camera access is off")
                                .typeStep(.title)
                                .foregroundStyle(Theme.ink)
                        } icon: {
                            Image(systemName: "camera.fill")
                                .foregroundStyle(Theme.ink3)
                        }
                    } description: {
                        Text("Turn on the camera for Sigil in Settings, or paste the pairing link instead.")
                            .typeStep(.body)
                            .foregroundStyle(Theme.ink2)
                    } actions: {
                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                        .buttonStyle(.primary)
                    }
                }
            }
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
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .buttonStyle(.bar)
                }
                .sharedBackgroundVisibility(.hidden)
            }
            .task {
                if access == .notDetermined {
                    _ = await AVCaptureDevice.requestAccess(for: .video)
                    access = AVCaptureDevice.authorizationStatus(for: .video)
                }
            }
        }
    }

    private let title = "Scan the code in Sigil"

    private var viewfinder: some View {
        VStack(spacing: Theme.Space.large) {
            Spacer()
            // The web companion's viewfinder: a 2pt accent ring at the window radius.
            RoundedRectangle(cornerRadius: Theme.Radius.window, style: .continuous)
                .strokeBorder(Theme.accent, lineWidth: 2)
                .frame(width: 240, height: 240)
                .accessibilityHidden(true)
            Text(rejected ?? "Point the camera at the code on your Mac.")
                .typeStep(.body, weight: rejected == nil ? .medium : .regular)
                .multilineTextAlignment(.center)
                .foregroundStyle(rejected == nil ? Theme.ink : Theme.redInk)
                .padding(.horizontal, Theme.Space.medium)
                .padding(.vertical, Theme.Space.small)
                .surface(Theme.surface, radius: Theme.Radius.card, elevation: .overlay)
                .accessibilityAddTraits(.updatesFrequently)
            Spacer()
        }
        .padding(Theme.Space.large)
    }
}

private struct QRCameraView: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeUIViewController(context: Context) -> QRCameraController {
        let controller = QRCameraController()
        controller.onCode = onCode
        return controller
    }

    func updateUIViewController(_ controller: QRCameraController, context: Context) {
        controller.onCode = onCode
    }
}

final class QRCameraController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Void)?
    private let session = AVCaptureSession()
    private var preview: AVCaptureVideoPreviewLayer?
    private var lastCode: String?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
            let input = try? AVCaptureDeviceInput(device: camera), session.canAddInput(input)
        else { return }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(layer)
        preview = layer
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        let session = session
        DispatchQueue.global(qos: .userInitiated).async { session.startRunning() }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        let session = session
        DispatchQueue.global(qos: .userInitiated).async { session.stopRunning() }
    }

    nonisolated func metadataOutput(
        _ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        let code = (metadataObjects.first as? AVMetadataMachineReadableCodeObject)?.stringValue
        MainActor.assumeIsolated {
            // The same code arrives every frame; act on it once.
            guard let code, code != lastCode else { return }
            lastCode = code
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            onCode?(code)
        }
    }
}
