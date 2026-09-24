#!/usr/bin/env swift
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// The Mac mark from Scripts/DrawIcon.swift, full bleed and opaque, because iOS
// masks the corners itself and App Store Connect rejects an icon with alpha.
// Same 192-unit geometry as Site/public/icon.svg.

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.png")
let size = 1024
func hex(_ v: UInt32) -> CGColor {
    CGColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
}
let ctx = CGContext(
    data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
let s = CGFloat(size)
ctx.setFillColor(hex(0x1C1D1F))
ctx.fill(CGRect(x: 0, y: 0, width: s, height: s))
let unit = s / 192
func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * unit, y: s - y * unit) }
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
ctx.setLineWidth(12 * unit)
ctx.move(to: point(58, 70))
ctx.addLine(to: point(84, 96))
ctx.addLine(to: point(58, 122))
ctx.setStrokeColor(hex(0xF2F3F4))
ctx.strokePath()
ctx.move(to: point(102, 122))
ctx.addLine(to: point(136, 122))
ctx.setStrokeColor(hex(0x3D9AFF))
ctx.strokePath()
let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
guard CGImageDestinationFinalize(dest) else { exit(1) }
