#!/usr/bin/env swift
import AppKit
import CoreGraphics
import Foundation
import UniformTypeIdentifiers

// Draws a dark rounded-square mark with a terminal prompt (`>` + block cursor).
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

    let top = color(0.12, 0.13, 0.16)
    let bot = color(0.07, 0.08, 0.10)
    if size <= 32 {
        ctx.setFillColor(color(0.09, 0.10, 0.13))
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

    let accent = color(0.43, 0.91, 0.67)
    ctx.setStrokeColor(accent)
    ctx.setFillColor(accent)
    ctx.setLineCap(.butt)
    ctx.setLineJoin(.miter)
    ctx.setMiterLimit(8)

    let lineW: CGFloat
    let p0: CGPoint
    let p1: CGPoint
    let p2: CGPoint
    let cursor: CGRect

    if size <= 16 {
        // 16pt: a 2px `>` only — a cursor would merge into the chevron.
        lineW = 2
        p0 = CGPoint(x: 5, y: 11)
        p1 = CGPoint(x: 10, y: 8)
        p2 = CGPoint(x: 5, y: 5)
        cursor = .null
    } else if size <= 32 {
        lineW = 2
        p0 = CGPoint(x: 8, y: 22)
        p1 = CGPoint(x: 15, y: 16)
        p2 = CGPoint(x: 8, y: 10)
        cursor = CGRect(x: 20, y: 12, width: 2, height: 8)
    } else {
        lineW = max(2, (s * 0.075).rounded())
        p0 = CGPoint(x: (0.28 * s).rounded() + 0.5, y: (0.68 * s).rounded())
        p1 = CGPoint(x: (0.50 * s).rounded(), y: (0.50 * s).rounded())
        p2 = CGPoint(x: (0.28 * s).rounded() + 0.5, y: (0.32 * s).rounded())
        let cw = max(2, (s * 0.07).rounded())
        let ch = max(5, (s * 0.26).rounded())
        let cx = (0.62 * s).rounded()
        let cy = ((s - ch) / 2).rounded()
        cursor = CGRect(x: cx, y: cy, width: cw, height: ch)
    }

    ctx.setLineWidth(lineW)
    ctx.move(to: p0)
    ctx.addLine(to: p1)
    ctx.addLine(to: p2)
    ctx.strokePath()

    if !cursor.isNull, !cursor.isEmpty {
        let cursorRadius = size >= 64 ? max(1, cursor.width * 0.25) : 0
        if cursorRadius > 0 {
            ctx.addPath(roundedRect(cursor, radius: cursorRadius))
            ctx.fillPath()
        } else {
            ctx.fill(cursor)
        }
    }
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
