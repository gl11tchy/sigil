import AppKit
import SigilKit
import SwiftUI

extension CLIProvider {
    /// Bundle id of the Mac app whose icon stands for this CLI.
    /// Devin's app reports the Windsurf id. Grok Build has no Mac app.
    var applicationBundleID: String? {
        switch self {
        case .claudeCode: "com.anthropic.claudefordesktop"
        case .codex: "com.openai.codex"
        case .devin: "com.exafunction.windsurf"
        case .cursor: "com.todesktop.230313mzl4w4u92"
        case .grokBuild: nil
        }
    }
}

enum ProviderAppIcon {
    @MainActor
    static func image(for provider: CLIProvider) -> NSImage? {
        if let cached = cache[provider] { return cached }
        guard let id = provider.applicationBundleID,
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
        else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        // The workspace icon's point size is 32, so SwiftUI would scale that
        // bitmap up. A 256px representation stays sharp at the tile size.
        let preferred = [256, 128, 64]
        let rep =
            preferred.compactMap { side in
                icon.representations.first { $0.pixelsWide == side }
            }.first
            ?? icon.representations.max(by: { $0.pixelsWide < $1.pixelsWide })
        guard let rep else {
            cache[provider] = icon
            return icon
        }
        let image = NSImage(size: NSSize(width: 64, height: 64))
        image.addRepresentation(rep)
        cache[provider] = image
        return image
    }

    @MainActor private static var cache: [CLIProvider: NSImage] = [:]
}

/// The Grok mark. There is no Grok Build app to take an icon from.
struct GrokMark: Shape {
    static let pathData =
        "M9.27 15.29l7.978-5.897c.391-.29.95-.177 1.137.272.98 2.369.542 5.215-1.41 7.169-1.951 1.954-4.667 2.382-7.149 1.406l-2.711 1.257c3.889 2.661 8.611 2.003 11.562-.953 2.341-2.344 3.066-5.539 2.388-8.42l.006.007c-.983-4.232.242-5.924 2.75-9.383.06-.082.12-.164.179-.248l-3.301 3.305v-.01L9.267 15.292M7.623 16.723c-2.792-2.67-2.31-6.801.071-9.184 1.761-1.763 4.647-2.483 7.166-1.425l2.705-1.25a7.808 7.808 0 00-1.829-1A8.975 8.975 0 005.984 5.83c-2.533 2.536-3.33 6.436-1.962 9.764 1.022 2.487-.653 4.246-2.34 6.022-.599.63-1.199 1.259-1.682 1.925l7.62-6.815"

    func path(in rect: CGRect) -> Path {
        let raw = SVGPath.path(from: Self.pathData)
        let bounds = raw.boundingRect
        guard bounds.width > 0, bounds.height > 0 else { return raw }
        let scale = min(rect.width / bounds.width, rect.height / bounds.height)
        let transform = CGAffineTransform.identity
            .translatedBy(x: rect.midX, y: rect.midY)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: -bounds.midX, y: -bounds.midY)
        return raw.applying(transform)
    }
}

struct ProviderLogo: View {
    let provider: CLIProvider
    @Environment(\.palette) private var palette

    var body: some View {
        Group {
            if let image = ProviderAppIcon.image(for: provider) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
            } else if provider == .grokBuild {
                GrokMark()
                    .fill(palette.text, style: FillStyle(eoFill: true))
                    .padding(1)
            }
        }
        .accessibilityHidden(true)
    }
}
