import AppKit
import CoreText
import SwiftUI

/// Beautiful UI's two typefaces: Inter for language, JetBrains Mono for
/// anything a machine wrote. Both ship in the app bundle under `Fonts/`
/// (SIL OFL 1.1). A build without them — `swift test`, a bare `swift run` —
/// falls back to the system faces so nothing breaks, it only looks less right.
public enum Typeface {
    public static let interFamily = "Inter"
    public static let monoFamily = "JetBrains Mono"

    /// Registers every font in the bundle's `Fonts` folder for this process.
    /// Call once, before the first window draws.
    @MainActor
    public static func registerBundledFonts(in bundle: Bundle = .main) {
        guard let folder = bundle.resourceURL?.appendingPathComponent("Fonts", isDirectory: true),
            let files = try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: nil)
        else { return }
        for file in files where ["ttf", "otf"].contains(file.pathExtension.lowercased()) {
            CTFontManagerRegisterFontsForURL(file as CFURL, .process, nil)
        }
        hasInter = NSFont(name: "Inter-Regular", size: 13) != nil
        hasMono = NSFont(name: "JetBrainsMono-Regular", size: 13) != nil
    }

    nonisolated(unsafe) public private(set) static var hasInter =
        NSFont(name: "Inter-Regular", size: 13) != nil
    nonisolated(unsafe) public private(set) static var hasMono =
        NSFont(name: "JetBrainsMono-Regular", size: 13) != nil

    /// The terminal's face: JetBrains Mono when bundled, else SF Mono.
    public static func terminalFont(size: CGFloat) -> NSFont {
        if hasMono, let font = NSFont(name: "JetBrainsMono-Regular", size: size) { return font }
        if let font = NSFont(name: "SF Mono", size: size) { return font }
        if let font = NSFont(name: "SFMono-Regular", size: size) { return font }
        if let font = NSFont(name: "Menlo", size: size) { return font }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }
}

extension Font {
    /// Inter at `size`. Human-language text: titles, labels, buttons.
    public static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        guard Typeface.hasInter else { return .system(size: size, weight: weight) }
        return .custom(Typeface.interFamily, fixedSize: size).weight(weight)
    }

    /// JetBrains Mono at `size`. Machine text: paths, times, counts, keys.
    public static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        guard Typeface.hasMono else {
            return .system(size: size, weight: weight, design: .monospaced)
        }
        return .custom(Typeface.monoFamily, fixedSize: size).weight(weight)
    }
}

extension View {
    /// Inter with Beautiful UI's tracking: -0.01em from 13pt up, none below.
    public func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> some View {
        font(.ui(size, weight)).tracking(size >= 13 ? -0.01 * size : 0)
    }

    /// JetBrains Mono, tabular by construction.
    public func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> some View {
        font(.mono(size, weight))
    }
}
