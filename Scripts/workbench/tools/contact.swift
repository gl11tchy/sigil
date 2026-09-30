import AppKit
// contact <out.png> <columns> <files...>: a labelled grid of thumbnails.
let a = CommandLine.arguments
let out = a[1], cols = Int(a[2])!, files = Array(a.dropFirst(3))
let cellW = 600.0, cellH = 400.0, label = 22.0
let rows = (files.count + cols - 1) / cols
let size = NSSize(width: cellW * Double(cols), height: (cellH + label) * Double(rows))
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSColor.gray.setFill(); NSRect(origin: .zero, size: size).fill()
for (i, f) in files.enumerated() {
    guard let img = NSImage(contentsOfFile: f) else { continue }
    let c = i % cols, r = i / cols
    let top = size.height - Double(r + 1) * (cellH + label)
    let scale = min(cellW / img.size.width, cellH / img.size.height)
    let w = img.size.width * scale, h = img.size.height * scale
    img.draw(in: NSRect(x: Double(c) * cellW + (cellW - w) / 2, y: top + (cellH - h) / 2, width: w, height: h))
    (URL(fileURLWithPath: f).lastPathComponent as NSString).draw(at: NSPoint(x: Double(c) * cellW + 6, y: top + cellH + 3), withAttributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.white])
}
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
