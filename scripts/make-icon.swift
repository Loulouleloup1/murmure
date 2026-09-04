#!/usr/bin/env swift
//
// Murmure's icon, drawn from the same numbers the interface is drawn from.
//
// A script and not a PNG, for the reason every other derived thing in this repository is derived:
// an image checked in as bytes is a decision nobody can read. Here the accent is
// `NotchAppearance.accentHue`, the ground is the range `WindowPalette` already spans, and the mark
// is the waveform `DictationPhaseView` draws -- so moving the accent (which lot 3's Q-NB2 leaves
// open, and which is Louis's to move) means changing one number in one place and re-running this.
//
// **What the mark is.** The recording waveform: capsules, one row, read left to right. Not a
// microphone -- Murmure has no microphone in its interface -- and not two mirrored halves, which
// is the one shape `NotchAppearance.isMirrored` exists to refuse:
//
//     "Ça part du centre et c'est symétrique... J'aimerais vraiment avoir une barre unique."
//
// So the silhouette is asymmetric on purpose, and it ends brighter than it starts because that is
// the direction a dictation runs in: the oldest audio at the leading edge, the newest at the
// trailing one.
//
// **Where it departs from the interface, and why.** In the app the bars are white and the accent
// belongs to `refining` alone (lot 3 D11). An icon is the one surface whose job is to say WHICH
// app this is, so the ink ramps from the white the bars actually are into the colour the app is
// known by. The bars are also thicker here than `WaveformLayout.inkFraction`: that fraction is a
// density over time on a live surface, and this is a mark that has to survive 16 pt.
//
// Usage: swift scripts/make-icon.swift Murmure/Assets.xcassets/AppIcon.appiconset

import AppKit
import CoreGraphics
import Foundation

// MARK: - Murmure's numbers

/// `NotchAppearance.accentHue` -- 292°, the violet-magenta that is nobody else's.
let accentHue = 292.0 / 360
/// `NotchAppearance.accentSaturation`.
let accentSaturation = 0.55

func accent(_ brightness: Double, saturation: Double = accentSaturation, alpha: Double = 1) -> CGColor {
    NSColor(calibratedHue: accentHue, saturation: saturation, brightness: brightness, alpha: alpha)
        .cgColor
}
func grey(_ brightness: Double, alpha: Double = 1) -> CGColor {
    NSColor(white: brightness, alpha: alpha).cgColor
}

/// The heights of the seven bars, as fractions of the tallest.
///
/// A phrase rather than a ramp: it rises, peaks left of the last bar, drops and lifts again --
/// which is what speech looks like when it is drawn, and what a monotonic crescendo does not.
let levels: [Double] = [0.26, 0.44, 0.33, 0.62, 1.00, 0.52, 0.76]

/// Fractions of the icon's full canvas, including the padding macOS expects around the shape.
let rowWidth = 0.62, maxBarHeight = 0.60, inkFraction = 0.56, bloomCentre = 0.58

// MARK: - Shapes

/// The macOS icon shape is a superellipse, not a rounded rectangle: at this corner radius the
/// difference between the two is visible, and a rounded rectangle reads as a foreign app.
func squircle(in rect: CGRect, n: Double = 5.2) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2
    for i in 0...1440 {
        let t = Double(i) / 1440 * 2 * .pi
        let ct = cos(t), st = sin(t)
        let point = CGPoint(
            x: rect.midX + a * (ct < 0 ? -1 : 1) * pow(abs(ct), 2 / n),
            y: rect.midY + b * (st < 0 ? -1 : 1) * pow(abs(st), 2 / n))
        if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
    }
    path.closeSubpath()
    return path
}

func capsule(_ rect: CGRect) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: min(rect.width, rect.height) / 2,
           cornerHeight: min(rect.width, rect.height) / 2, transform: nil)
}

// MARK: - Drawing

/// The ground: the range `WindowPalette` already spans (sidebar 0.09 to card 0.20), plus the accent
/// breathed onto it rather than painted on it -- the same thing the notch does to the black around
/// a refinement.
func drawGround(_ ctx: CGContext, size: CGFloat) {
    let inset = size * 100 / 1024
    let rect = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let shape = squircle(in: rect)
    let space = CGColorSpaceCreateDeviceRGB()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    ctx.drawLinearGradient(
        CGGradient(colorsSpace: space,
                   colors: [grey(0.20), grey(0.115), grey(0.07)] as CFArray,
                   locations: [0, 0.55, 1])!,
        start: CGPoint(x: 0, y: rect.maxY), end: CGPoint(x: 0, y: rect.minY), options: [])
    ctx.drawRadialGradient(
        CGGradient(colorsSpace: space,
                   colors: [accent(1, saturation: 0.75, alpha: 0.19),
                            accent(1, saturation: 0.75, alpha: 0)] as CFArray,
                   locations: [0, 1])!,
        startCenter: CGPoint(x: size * bloomCentre, y: size * 0.5), startRadius: 0,
        endCenter: CGPoint(x: size * bloomCentre, y: size * 0.5), endRadius: size * 0.45,
        options: [])
    ctx.restoreGState()

    // The hairline the window draws around a lifted surface, at the same faintness.
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.setStrokeColor(grey(1, alpha: 0.10))
    ctx.setLineWidth(size * 2.5 / 1024)
    ctx.strokePath()
    ctx.restoreGState()
}

func drawWaveform(_ ctx: CGContext, size: CGFloat) {
    let row = size * rowWidth, tallest = size * maxBarHeight
    let slot = row / Double(levels.count)
    let barWidth = slot * inkFraction
    let x0 = (size - row) / 2 + (slot - barWidth) / 2
    for (index, level) in levels.enumerated() {
        // The same floor the live waveform keeps: a bar shorter than it is wide is a dot.
        let height = max(barWidth, tallest * level)
        let bar = CGRect(x: x0 + Double(index) * slot, y: (size - height) / 2,
                         width: barWidth, height: height)
        let along = Double(index) / Double(levels.count - 1)
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: size * 0.022,
                      color: accent(1, saturation: 0.7, alpha: 0.42 * along))
        ctx.setFillColor(accent(1, saturation: accentSaturation * along,
                                alpha: 0.95 + 0.05 * along))
        ctx.addPath(capsule(bar))
        ctx.fillPath()
        ctx.restoreGState()
    }
}

func render(size: CGFloat) -> Data {
    let px = Int(size)
    let ctx = CGContext(
        data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high
    drawGround(ctx, size: size)
    drawWaveform(ctx, size: size)
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: NSBitmapImageRep.FileType.png, properties: [:])!
}

// MARK: - The asset catalog

/// Every size macOS asks an app icon for, as (point size, scale).
let entries: [(Int, Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
                             (256, 1), (256, 2), (512, 1), (512, 2)]

let destination = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "Murmure/Assets.xcassets/AppIcon.appiconset"
try FileManager.default.createDirectory(
    atPath: destination, withIntermediateDirectories: true)

var images: [[String: String]] = []
var written: Set<Int> = []
for (points, scale) in entries {
    let pixels = points * scale
    let filename = "icon_\(pixels).png"
    if !written.contains(pixels) {
        try render(size: CGFloat(pixels)).write(to: URL(fileURLWithPath: "\(destination)/\(filename)"))
        written.insert(pixels)
    }
    images.append([
        "size": "\(points)x\(points)", "idiom": "mac",
        "filename": filename, "scale": "\(scale)x",
    ])
}
let contents: [String: Any] = [
    "images": images,
    "info": ["version": 1, "author": "xcode"],
]
let json = try JSONSerialization.data(
    withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try json.write(to: URL(fileURLWithPath: "\(destination)/Contents.json"))
print("wrote \(written.count) sizes to \(destination)")
