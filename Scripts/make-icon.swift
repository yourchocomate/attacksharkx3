#!/usr/bin/env swift
// Generates asctl's app icon.
//
// Original artwork, drawn with the same shell outline the in-app diagram uses.
// The vendor's own Icon.ico is deliberately not used: it is their logo, it
// comes out of the extracted installer, and shipping it would contradict this
// project's position that no vendor material is redistributed.
//
// Renders one PNG per size an .icns needs, then `iconutil` assembles them.
// Run via Scripts/make-icon.sh.

import AppKit
import CoreGraphics
import Foundation

let outputDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

/// The shell outline, in a unit square. Same curve as MouseShellShape.
func shellPath(in rect: CGRect) -> CGPath {
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * (1 - y))
    }
    let path = CGMutablePath()
    path.move(to: p(0.50, 0.000))
    path.addCurve(to: p(0.90, 0.085), control1: p(0.72, 0.000), control2: p(0.84, 0.030))
    path.addCurve(to: p(0.965, 0.240), control1: p(0.945, 0.125), control2: p(0.965, 0.180))
    path.addCurve(to: p(0.970, 0.470), control1: p(0.972, 0.330), control2: p(0.968, 0.410))
    path.addCurve(to: p(0.990, 0.660), control1: p(0.965, 0.545), control2: p(0.990, 0.590))
    path.addCurve(to: p(0.855, 0.895), control1: p(0.990, 0.775), control2: p(0.940, 0.840))
    path.addCurve(to: p(0.50, 1.000), control1: p(0.775, 0.955), control2: p(0.645, 1.000))
    path.addCurve(to: p(0.145, 0.895), control1: p(0.355, 1.000), control2: p(0.225, 0.955))
    path.addCurve(to: p(0.010, 0.660), control1: p(0.060, 0.840), control2: p(0.010, 0.775))
    path.addCurve(to: p(0.030, 0.470), control1: p(0.010, 0.590), control2: p(0.028, 0.545))
    path.addCurve(to: p(0.035, 0.240), control1: p(0.032, 0.410), control2: p(0.028, 0.330))
    path.addCurve(to: p(0.10, 0.085), control1: p(0.035, 0.180), control2: p(0.055, 0.125))
    path.addCurve(to: p(0.50, 0.000), control1: p(0.16, 0.030), control2: p(0.28, 0.000))
    path.closeSubpath()
    return path
}

func render(size: Int) -> Data? {
    let s = CGFloat(size)
    guard let context = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }

    // macOS Big Sur icon geometry: a rounded square inset from the canvas.
    let inset = s * 0.09
    let plate = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let corner = plate.width * 0.225

    // Background: a deep slate gradient, so the light mouse reads at any size.
    context.saveGState()
    let platePath = CGPath(
        roundedRect: plate, cornerWidth: corner, cornerHeight: corner, transform: nil)
    context.addPath(platePath)
    context.clip()
    let colours = [
        CGColor(red: 0.16, green: 0.18, blue: 0.22, alpha: 1),
        CGColor(red: 0.07, green: 0.08, blue: 0.10, alpha: 1),
    ] as CFArray
    if let gradient = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        colors: colours, locations: [0, 1])
    {
        context.drawLinearGradient(
            gradient, start: CGPoint(x: 0, y: s), end: CGPoint(x: 0, y: 0), options: [])
    }
    context.restoreGState()

    // The mouse, centred and generously sized so it survives 16pt.
    let shellHeight = plate.height * 0.70
    let shellWidth = shellHeight * 61.0 / 118.5
    let shell = CGRect(
        x: plate.midX - shellWidth / 2,
        y: plate.midY - shellHeight / 2,
        width: shellWidth, height: shellHeight)
    let path = shellPath(in: shell)

    context.addPath(path)
    context.setFillColor(CGColor(red: 0.93, green: 0.94, blue: 0.96, alpha: 1))
    context.fillPath()

    // Button seam and the split across the shell, only where they will be seen.
    if size >= 32 {
        let line = max(1, s * 0.012)
        context.setStrokeColor(CGColor(red: 0.16, green: 0.18, blue: 0.22, alpha: 1))
        context.setLineWidth(line)
        context.setLineCap(.round)

        context.move(to: CGPoint(x: shell.midX, y: shell.maxY - shell.height * 0.005))
        context.addLine(to: CGPoint(x: shell.midX, y: shell.maxY - shell.height * 0.445))
        context.strokePath()

        context.move(to: CGPoint(x: shell.minX + shell.width * 0.05,
                                 y: shell.maxY - shell.height * 0.435))
        context.addCurve(
            to: CGPoint(x: shell.maxX - shell.width * 0.05,
                        y: shell.maxY - shell.height * 0.435),
            control1: CGPoint(x: shell.minX + shell.width * 0.30,
                              y: shell.maxY - shell.height * 0.450),
            control2: CGPoint(x: shell.minX + shell.width * 0.70,
                              y: shell.maxY - shell.height * 0.450))
        context.strokePath()
    }

    // The scroll wheel, in the accent colour, doubling as the icon's one
    // point of colour.
    let wheelWidth = shell.width * 0.13
    let wheelHeight = shell.height * 0.20
    let wheel = CGRect(
        x: shell.midX - wheelWidth / 2,
        y: shell.maxY - shell.height * 0.175 - wheelHeight / 2,
        width: wheelWidth, height: wheelHeight)
    context.addPath(CGPath(
        roundedRect: wheel, cornerWidth: wheelWidth / 2, cornerHeight: wheelWidth / 2,
        transform: nil))
    context.setFillColor(CGColor(red: 0.16, green: 0.55, blue: 0.98, alpha: 1))
    context.fillPath()

    guard let image = context.makeImage() else { return nil }
    let rep = NSBitmapImageRep(cgImage: image)
    return rep.representation(using: .png, properties: [:])
}

// The sizes an .iconset requires.
let sizes: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for entry in sizes {
    guard let data = render(size: entry.pixels) else {
        FileHandle.standardError.write(Data("failed to render \(entry.name)\n".utf8))
        exit(1)
    }
    let url = URL(fileURLWithPath: outputDir).appendingPathComponent("\(entry.name).png")
    try! data.write(to: url)
}
print("rendered \(sizes.count) sizes into \(outputDir)")
