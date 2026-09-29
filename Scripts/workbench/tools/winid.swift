import CoreGraphics
import Foundation
// Prints "<window id> <width> <height>" for on-screen, layer-0 windows owned by argv[1].
let owner = CommandLine.arguments.dropFirst().first ?? ""
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
for w in list where (w[kCGWindowOwnerName as String] as? String) == owner && (w[kCGWindowLayer as String] as? Int) == 0 {
    let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
    print(w[kCGWindowNumber as String] ?? "", b["Width"] ?? "", b["Height"] ?? "")
}
