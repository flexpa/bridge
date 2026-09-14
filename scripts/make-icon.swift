#!/usr/bin/env swift
// Renders the app icon (.icns) from vector drawing so no binary assets live in git.
// Usage: swift scripts/make-icon.swift Packaging/AppIcon.icns
import AppKit
import Foundation

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.icns"
let iconset = URL(fileURLWithPath: output).deletingPathExtension().appendingPathExtension("iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else { return image }
    let inset = size * 0.08  // macOS icons leave a margin inside the canvas
    let rect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let radius = rect.width * 0.225
    let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

    // Shadow
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.01), blur: size * 0.03, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    NSColor.black.setFill()
    path.fill()
    ctx.restoreGState()

    // Flexpa brand: deep green to teal, the "F" mark in warm white, a lime heart for Health.
    path.addClip()
    let gradient = NSGradient(colors: [
        NSColor(srgbRed: 0x0D / 255, green: 0x20 / 255, blue: 0x19 / 255, alpha: 1),   // flexpa-green-primary
        NSColor(srgbRed: 0x00 / 255, green: 0x58 / 255, blue: 0x5D / 255, alpha: 1),   // flexpa-green-secondary
    ])!
    gradient.draw(in: rect, angle: 60)
    let highlight = NSGradient(colors: [NSColor.white.withAlphaComponent(0.10), NSColor.white.withAlphaComponent(0)])!
    highlight.draw(in: CGRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2), angle: 90)

    // The F mark (four rectangles, 16.59 × 22.12 box) from the Flexpa logo.
    let markHeight = rect.height * 0.56
    let scale = markHeight / 22.12
    let markWidth = 16.59 * scale
    let ox = rect.midX - markWidth / 2 - rect.width * 0.04
    let oy = rect.midY - markHeight / 2
    func mark(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(x: ox + x * scale, y: oy + (22.12 - y - h) * scale, width: w * scale, height: h * scale)
    }
    NSColor(srgbRed: 0xF7 / 255, green: 0xF5 / 255, blue: 0xF0 / 255, alpha: 1).setFill()   // flexpa-tan-primary 25
    for r in [mark(0, 16.59, 5.53, 5.53), mark(0, 5.53, 5.53, 5.53), mark(5.53, 11.06, 11.06, 5.53), mark(5.53, 0, 11.06, 5.53)] {
        NSBezierPath(rect: r).fill()
    }

    // Lime heart badge, bottom right, for "Health".
    let config = NSImage.SymbolConfiguration(pointSize: size * 0.3, weight: .bold)
    if let symbol = NSImage(systemSymbolName: "heart.fill", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
        let lime = NSColor(srgbRed: 0xC1 / 255, green: 0xFD / 255, blue: 0x8A / 255, alpha: 1)   // flexpa-green-accent
        let tinted = NSImage(size: symbol.size, flipped: false) { dest in
            symbol.draw(in: dest)
            lime.set()
            dest.fill(using: .sourceAtop)
            return true
        }
        let heartSize = CGSize(width: rect.width * 0.24, height: rect.width * 0.22)
        let origin = CGPoint(x: rect.maxX - heartSize.width - rect.width * 0.11, y: rect.minY + rect.height * 0.12)
        tinted.draw(in: CGRect(origin: origin, size: heartSize), from: .zero, operation: .sourceOver, fraction: 1)
    }
    image.unlockFocus()
    return image
}

func writePNG(_ image: NSImage, pixels: Int, to url: URL) throws {
    guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return }
    rep.size = NSSize(width: pixels, height: pixels)
    guard let data = rep.representation(using: .png, properties: [:]) else { return }
    try data.write(to: url)
}

for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let pixels = points * scale
    let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
    try writePNG(render(size: CGFloat(pixels)), pixels: pixels, to: iconset.appendingPathComponent(name))
}

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", output]
try task.run()
task.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print(task.terminationStatus == 0 ? "wrote \(output)" : "iconutil failed")
exit(task.terminationStatus)
