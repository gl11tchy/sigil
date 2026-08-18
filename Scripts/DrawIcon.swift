#!/usr/bin/env swift
import AppKit
import CoreGraphics
import Foundation
import UniformTypeIdentifiers

// Draws a dark rounded-square mark with a thin ember ring framing a
// terminal prompt (`>` + block cursor) read as an occult glyph.
// Pixel sizes are written directly so 16pt stays a few hard-edged shapes.

let args = CommandLine.arguments
guard args.count == 2 else {
    fputs("usage: \(args[0]) <iconset-directory>\n", stderr)
    exit(2)
}

let outDir = URL(fileURLWithPath: args[1], isDirectory: true)
var isDir: ObjCBool = false
guard FileManager.default.fileExists(atPath: outDir.path, isDirectory: &isDir), isDir.boolValue
else {
    fputs("error: not a directory: \(outDir.path)\n", stderr)
    exit(1)
}

let specs: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r, green: g, blue: b, alpha: a)
}

func roundedRect(_ rect: CGRect, radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

// Ember: hot orange #FF7A2F at the top, deep crimson #C21F2E at the bottom.
let emberTop = color(1.0, 0.478, 0.184)
let emberBot = color(0.761, 0.122, 0.180)

func emberGradient() -> CGGradient? {
    CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [emberTop, emberBot] as CFArray,
        locations: [0, 1]
    )
}

func fillEmber(_ ctx: CGContext, size: Int) {
    let s = CGFloat(size)
    if let gradient = emberGradient() {
        ctx.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: s),
            end: CGPoint(x: 0, y: 0),
            options: []
        )
    } else {
        ctx.setFillColor(emberTop)
        ctx.fill(CGRect(x: 0, y: 0, width: s, height: s))
    }
}

struct Mark {
    var ringCenter: CGPoint
    var ringRadius: CGFloat
    var ringStroke: CGFloat
    var lineW: CGFloat
    var p0: CGPoint
    var p1: CGPoint
    var p2: CGPoint
    var cursor: CGRect
}

func mark(for size: Int) -> Mark {
    let s = CGFloat(size)
    let c = CGPoint(x: (s / 2).rounded(), y: (s / 2).rounded())

    if size <= 16 {
        // 16pt is drawn as discrete pixels in `drawMark16` — this is unused.
        return Mark(
            ringCenter: CGPoint(x: 8, y: 8),
            ringRadius: 5.5,
            ringStroke: 2,
            lineW: 2,
            p0: CGPoint(x: 6, y: 10),
            p1: CGPoint(x: 9, y: 8),
            p2: CGPoint(x: 6, y: 6),
            cursor: .null
        )
    }

    if size <= 32 {
        return Mark(
            ringCenter: CGPoint(x: 16, y: 16),
            ringRadius: 12,
            ringStroke: 3,
            lineW: 3,
            p0: CGPoint(x: 10, y: 21),
            p1: CGPoint(x: 16, y: 16),
            p2: CGPoint(x: 10, y: 11),
            cursor: CGRect(x: 19, y: 12, width: 3, height: 8)
        )
    }

    let ringRadius = (s * 0.37).rounded()
    let ringStroke = max(3, (s * 0.048).rounded())
    let inner = ringRadius - ringStroke / 2
    let usable = inner * 0.78
    let lineW = max(3, (s * 0.072).rounded())
    let p0 = CGPoint(
        x: (c.x - usable * 0.42).rounded() + 0.5,
        y: (c.y + usable * 0.52).rounded()
    )
    let p1 = CGPoint(
        x: (c.x + usable * 0.06).rounded(),
        y: c.y.rounded()
    )
    let p2 = CGPoint(
        x: (c.x - usable * 0.42).rounded() + 0.5,
        y: (c.y - usable * 0.52).rounded()
    )
    let cursorW = lineW
    let cursorH = max(lineW * 2, (usable * 0.84).rounded())
    let cursor = CGRect(
        x: (c.x + usable * 0.32).rounded(),
        y: ((c.y - cursorH / 2).rounded()),
        width: cursorW,
        height: cursorH
    )
    return Mark(
        ringCenter: c,
        ringRadius: ringRadius,
        ringStroke: ringStroke,
        lineW: lineW,
        p0: p0,
        p1: p1,
        p2: p2,
        cursor: cursor
    )
}

func lerpColor(_ a: CGColor, _ b: CGColor, _ t: CGFloat) -> CGColor {
    let ac = a.components ?? [0, 0, 0, 1]
    let bc = b.components ?? [0, 0, 0, 1]
    return color(
        ac[0] + (bc[0] - ac[0]) * t,
        ac[1] + (bc[1] - ac[1]) * t,
        ac[2] + (bc[2] - ac[2]) * t,
        1
    )
}

/// Hard-edged 16pt mark: a 2px ring and a 2px `>` with a 1–2px dark gap.
/// Antialiased strokes smear both shapes into one blob at this size.
func drawMark16(_ ctx: CGContext) {
    func isRing(_ x: Int, _ y: Int) -> Bool {
        let dx = Double(x) + 0.5 - 8
        let dy = Double(y) + 0.5 - 8
        let d = (dx * dx + dy * dy).squareRoot()
        return d >= 4.7 && d < 6.7
    }
    // 2px-wide `>` inset from the ring. No cursor — it would merge.
    func isChevron(_ x: Int, _ y: Int) -> Bool {
        switch y {
        case 11: return x == 6
        case 10: return x == 6 || x == 7
        case 9: return x == 7 || x == 8
        case 8: return x == 8 || x == 9
        case 7: return x == 7 || x == 8
        case 6: return x == 6 || x == 7
        case 5: return x == 6
        default: return false
        }
    }
    for y in 0..<16 {
        let t = 1 - CGFloat(y) / 15
        ctx.setFillColor(lerpColor(emberTop, emberBot, t))
        for x in 0..<16 where isRing(x, y) || isChevron(x, y) {
            ctx.fill(CGRect(x: x, y: y, width: 1, height: 1))
        }
    }
}

func addChevron(_ path: CGMutablePath, _ m: Mark) {
    path.move(to: m.p0)
    path.addLine(to: m.p1)
    path.addLine(to: m.p2)
}

func strokedChevron(_ m: Mark) -> CGPath {
    let path = CGMutablePath()
    addChevron(path, m)
    return path.copy(
        strokingWithWidth: m.lineW,
        lineCap: .butt,
        lineJoin: .miter,
        miterLimit: 8
    )
}

func drawIcon(in ctx: CGContext, size: Int) {
    let s = CGFloat(size)
    ctx.clear(CGRect(x: 0, y: 0, width: s, height: s))
    ctx.setShouldAntialias(true)
    ctx.setAllowsAntialiasing(true)

    let inset = max(1, (s * 0.07).rounded())
    let body = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = max(2, (body.width * 0.22).rounded(.toNearestOrAwayFromZero))
    let plate = roundedRect(body, radius: min(radius, body.width / 2))

    ctx.saveGState()
    ctx.addPath(plate)
    ctx.clip()

    let top = color(0.08, 0.07, 0.07)
    let bot = color(0.03, 0.025, 0.025)
    if size <= 32 {
        ctx.setFillColor(color(0.05, 0.04, 0.04))
        ctx.fill(CGRect(x: 0, y: 0, width: s, height: s))
    } else if let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [top, bot] as CFArray,
        locations: [0, 1]
    ) {
        ctx.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: s),
            end: CGPoint(x: 0, y: 0),
            options: []
        )
    }
    ctx.restoreGState()

    ctx.addPath(plate)
    ctx.setStrokeColor(color(0.26, 0.28, 0.33, size <= 16 ? 1 : 0.95))
    ctx.setLineWidth(max(1, (s * 0.012).rounded()))
    ctx.strokePath()

    if size >= 64 {
        let inner = body.insetBy(dx: 1, dy: 1)
        ctx.addPath(roundedRect(inner, radius: max(1, radius - 1)))
        ctx.setStrokeColor(color(1, 1, 1, 0.10))
        ctx.setLineWidth(1)
        ctx.strokePath()
    }

    if size <= 16 {
        drawMark16(ctx)
        return
    }

    let m = mark(for: size)

    if size >= 32 {
        let glyphMid = CGPoint(
            x: (m.p1.x + (m.cursor.isNull ? m.p1.x : m.cursor.midX)) / 2,
            y: m.p1.y
        )
        let glowR = max(m.lineW * 3, m.ringRadius * 0.42)
        let glowA: CGFloat = size <= 32 ? 0.14 : 0.28
        if let glow = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [
                color(1.0, 0.478, 0.184, glowA),
                color(0.761, 0.122, 0.180, 0),
            ] as CFArray,
            locations: [0, 1]
        ) {
            ctx.saveGState()
            ctx.addPath(plate)
            ctx.clip()
            ctx.drawRadialGradient(
                glow,
                startCenter: glyphMid,
                startRadius: 0,
                endCenter: glyphMid,
                endRadius: glowR,
                options: []
            )
            ctx.restoreGState()
        }
    }

    ctx.saveGState()
    let ringRect = CGRect(
        x: m.ringCenter.x - m.ringRadius,
        y: m.ringCenter.y - m.ringRadius,
        width: m.ringRadius * 2,
        height: m.ringRadius * 2
    )
    let ring = CGMutablePath()
    ring.addEllipse(in: ringRect)
    let stroked = ring.copy(
        strokingWithWidth: m.ringStroke,
        lineCap: .butt,
        lineJoin: .miter,
        miterLimit: 8
    )
    ctx.addPath(stroked)
    ctx.clip()
    fillEmber(ctx, size: size)
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(strokedChevron(m))
    if !m.cursor.isNull, !m.cursor.isEmpty {
        let cursorRadius = size >= 64 ? max(1, m.cursor.width * 0.25) : 0
        if cursorRadius > 0 {
            ctx.addPath(roundedRect(m.cursor, radius: cursorRadius))
        } else {
            ctx.addRect(m.cursor)
        }
    }
    ctx.clip()
    fillEmber(ctx, size: size)
    ctx.restoreGState()
}

func writePNG(_ image: CGImage, to url: URL) throws {
    guard let dest = CGImageDestinationCreateWithURL(
        url as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
    ) else {
        throw NSError(
            domain: "DrawIcon", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "could not create PNG writer for \(url.path)"])
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else {
        throw NSError(
            domain: "DrawIcon", code: 2,
            userInfo: [NSLocalizedDescriptionKey: "could not write \(url.path)"])
    }
}

let colorSpace = CGColorSpaceCreateDeviceRGB()
let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

for spec in specs {
    guard let ctx = CGContext(
        data: nil,
        width: spec.pixels,
        height: spec.pixels,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: bitmapInfo
    ) else {
        fputs("error: no bitmap context for \(spec.pixels)px\n", stderr)
        exit(1)
    }
    drawIcon(in: ctx, size: spec.pixels)
    guard let image = ctx.makeImage() else {
        fputs("error: no image for \(spec.pixels)px\n", stderr)
        exit(1)
    }
    do {
        try writePNG(image, to: outDir.appendingPathComponent(spec.name))
    } catch {
        fputs("error: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}
