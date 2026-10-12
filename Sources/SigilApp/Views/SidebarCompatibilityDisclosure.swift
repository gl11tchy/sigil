import SigilKit
import SwiftUI

/// Nonblocking version information has one stable, quiet entry point. Keeping
/// it outside the history scroll preserves discoverability without repeated prose.
struct SidebarCompatibilityDisclosure: View {
    let notices: [ProviderVersionNotice]
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPresented = false
    @State private var isHovering = false
    @FocusState private var buttonFocused: Bool
    @FocusState private var closeFocused: Bool

    private var usesReducedMotion: Bool {
        #if DEBUG
            reduceMotion || (SidebarNoticeFixture.requested && SidebarNoticeFixture.controls.reduceMotion)
        #else
            reduceMotion
        #endif
    }

    var body: some View {
        if !notices.isEmpty {
            Button {
                isPresented.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle").font(.system(size: 12))
                    Text("Compatibility").ui(12.5)
                    Spacer(minLength: 4)
                    Text("\(notices.count)").mono(11.5)
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .medium))
                }
                .foregroundStyle(isHovering ? palette.ink : palette.ink2)
                .padding(.horizontal, 8)
                .frame(height: 26)
                .background(isHovering ? palette.hover : .clear, in: RoundedRectangle(cornerRadius: Radius.chip))
                .overlay {
                    if buttonFocused {
                        RoundedRectangle(cornerRadius: Radius.chip).strokeBorder(palette.accent, lineWidth: 1)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable()
            .focused($buttonFocused)
            .focusEffectDisabled()
            .keyboardShortcut("i", modifiers: [.command, .shift])
            .help("Installed and checked CLI versions (⌘⇧I)")
            .accessibilityLabel("Compatibility details")
            .accessibilityValue(
                "\(notices.count) \(notices.count == 1 ? "CLI is" : "CLIs are") newer than checked versions. Details \(isPresented ? "shown" : "hidden")."
            )
            .accessibilityHint("Show installed and checked versions and their limitations. Command-Shift-I.")
            .accessibilityIdentifier("sidebar-compatibility-disclosure")
            .onHover { isHovering = $0 }
            .animation(usesReducedMotion ? nil : Motion.fade, value: isHovering)
            .popover(isPresented: $isPresented, arrowEdge: .trailing) { details }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
            .onDisappear { isPresented = false }
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Newer CLI versions").ui(13.5, .semibold).foregroundStyle(palette.ink)
                .accessibilityAddTraits(.isHeader)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(notices) { notice in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(notice.provider.name).ui(13, .medium).foregroundStyle(palette.ink)
                            version("Installed", notice.installedVersion)
                            version("Checked", notice.checkedVersion)
                            Text(notice.consequence).ui(12.5).foregroundStyle(palette.ink2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(notice.text)
                        .accessibilityIdentifier("sidebar-\(notice.provider.rawValue)-version-notice")
                    }
                }
            }
            .frame(height: min(CGFloat(notices.count) * 110, 300))
            HStack {
                Spacer()
                Button("Done", action: close)
                    .buttonStyle(SigilButtonStyle(kind: .secondary, height: 26))
                    .focusable()
                    .focused($closeFocused)
                    .keyboardShortcut(.cancelAction)
                    .onKeyPress(.escape) {
                        close()
                        return .handled
                    }
                    .accessibilityLabel("Close compatibility details")
                    .accessibilityIdentifier("sidebar-compatibility-close")
            }
        }
        .padding(14)
        .frame(width: 320)
        .background(palette.surface)
        .environment(\.palette, palette)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sidebar-compatibility-details")
        .defaultFocus($closeFocused, true)
        .task {
            await Task.yield()
            closeFocused = true
        }
        .onExitCommand(perform: close)
    }

    private func version(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).ui(12).foregroundStyle(palette.ink2)
            Text(value).mono(11.5).foregroundStyle(palette.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func close() {
        isPresented = false
        buttonFocused = true
    }
}
