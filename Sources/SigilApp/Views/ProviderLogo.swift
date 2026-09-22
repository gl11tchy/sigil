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

/// A monochrome provider mark, scaled into the tile.
struct ProviderMark: Shape {
    var data: String

    func path(in rect: CGRect) -> Path {
        let raw = SVGPath.path(from: data)
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
            } else {
                ProviderMark(data: ProviderMarks.data(for: provider))
                    .fill(palette.text, style: FillStyle(eoFill: true))
                    .padding(provider == .grokBuild ? 1 : 4)
            }
        }
        .accessibilityHidden(true)
    }
}
