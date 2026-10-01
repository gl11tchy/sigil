import AppKit
import SigilKit
import SwiftUI

extension TabColor {
    var color: Color {
        let parts = Self.channels(hex)
        return Color(.sRGB, red: parts.red, green: parts.green, blue: parts.blue)
    }

    var nsColor: NSColor {
        let parts = Self.channels(hex)
        return NSColor(srgbRed: parts.red, green: parts.green, blue: parts.blue, alpha: 1)
    }

    private static func channels(_ hex: UInt32) -> (red: Double, green: Double, blue: Double) {
        (
            Double((hex >> 16) & 0xFF) / 255,
            Double((hex >> 8) & 0xFF) / 255,
            Double(hex & 0xFF) / 255
        )
    }
}

/// Leading identity bar. A dot would match the status light, so this is a bar.
struct TabColorMark: View {
    let color: TabColor

    var body: some View {
        RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
            .fill(color.color)
            .frame(width: 4)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

enum TabColorSwatch {
    static func image(for color: TabColor) -> NSImage {
        let side: CGFloat = 12
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let path = NSBezierPath(
                roundedRect: rect.insetBy(dx: 1, dy: 1),
                xRadius: Radius.chip,
                yRadius: Radius.chip)
            color.nsColor.setFill()
            path.fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}
