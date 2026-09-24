#!/usr/bin/env swift
import AppKit
import CoreGraphics
import Foundation
import UniformTypeIdentifiers

// Draws the Sigil mark in Beautiful UI's tokens: a `canvas` rounded square
// with the white 11% ring every card wears, a `>` in `ink`, and the cursor as
// an underscore in `accent`. The same geometry as Site/public/icon.svg, whose
// 192-unit viewBox the numbers below are written in.

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

func hex(_ value: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    color(
        CGFloat((value >> 16) & 0xFF) / 255,
        CGFloat((value >> 8) & 0xFF) / 255,
        CGFloat(value & 0xFF) / 255,
        alpha
    )
}

func roundedRect(_ rect: CGRect, radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

let canvas = hex(0x1C1D1F)
let ink = hex(0xF2F3F4)
let accent = hex(0x3D9AFF)

func drawIcon(in ctx: CGContext, size: Int) {
    let s = CGFloat(size)
    ctx.clear(CGRect(x: 0, y: 0, width: s, height: s))
    ctx.setShouldAntialias(true)
    ctx.setAllowsAntialiasing(true)

    // macOS draws app icons inside a margin; the plate keeps it.
    let inset = max(1, (s * 0.07).rounded())
    let plateRect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let unit = plateRect.width / 192
    let plate = roundedRect(plateRect, radius: 42 * unit)

    ctx.addPath(plate)
    ctx.setFillColor(canvas)
    ctx.fillPath()

    // The card ring: 2 units wide, inside the edge.
    let ringWidth = max(1, 2 * unit)
    ctx.addPath(
        roundedRect(
            plateRect.insetBy(dx: ringWidth / 2, dy: ringWidth / 2),
            radius: 42 * unit - ringWidth / 2))
    ctx.setStrokeColor(hex(0xFFFFFF, 0.11))
    ctx.setLineWidth(ringWidth)
    ctx.strokePath()

    /// SVG coordinates (y down) to the context (y up).
    func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: plateRect.minX + x * unit, y: plateRect.maxY - y * unit)
    }

    let stroke = max(1.5, 12 * unit)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.setLineWidth(stroke)

    ctx.move(to: point(58, 70))
    ctx.addLine(to: point(84, 96))
    ctx.addLine(to: point(58, 122))
    ctx.setStrokeColor(ink)
    ctx.strokePath()

    ctx.move(to: point(102, 122))
    ctx.addLine(to: point(136, 122))
    ctx.setStrokeColor(accent)
    ctx.strokePath()
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
