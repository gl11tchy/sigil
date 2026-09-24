import SigilKit
import SwiftUI

/// The terminal inside the screen.
///
/// The program in the tab draws its own interface, so the app adds nothing on
/// top of it: the terminal fills the screen below the tab bar and wears the
/// theme's own ground, rounded at the bottom to the screen's 14pt corners.
/// Work in flight shows in the tab bar and the sidebar, not as a glow here.
struct TerminalScreen: View {
    let tab: TerminalTab
    let theme: TerminalTheme

    var body: some View {
        TerminalPane(
            tab: tab,
            background: Palette.nsColor(theme.backgroundHex),
            cornerRadius: Radius.window - 1,
            roundsTopCorners: false
        )
        // Clear of the screen's 1pt border on the three sides it touches.
        .padding([.leading, .trailing, .bottom], 1)
    }
}
