import SigilKit
import SwiftUI

/// A keyboard shortcut rendered as a small key cap. The app is keyboard-first,
/// so hints name the key instead of burying it in a sentence.
struct KbdChip: View {
    let label: String
    let palette: Palette

    var body: some View {
        Text(label)
            .font(.system(size: 9.5, weight: .medium, design: .monospaced))
            .foregroundStyle(palette.textDim)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(palette.raised)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(palette.hairline, lineWidth: 1)
                    )
            )
            .padding(.vertical, -2)
    }
}
