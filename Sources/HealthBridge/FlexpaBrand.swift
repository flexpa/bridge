import AppKit
import SwiftUI

/// Flexpa brand tokens (from packages/design-tokens) and the "F" mark.
enum FlexpaBrand {
    static let greenPrimary = NSColor(srgbRed: 0x0D / 255, green: 0x20 / 255, blue: 0x19 / 255, alpha: 1)   // #0D2019
    static let teal = NSColor(srgbRed: 0x00 / 255, green: 0x58 / 255, blue: 0x5D / 255, alpha: 1)           // #00585D
    static let tealLight = NSColor(srgbRed: 0x40 / 255, green: 0x82 / 255, blue: 0x85 / 255, alpha: 1)      // #408285
    static let lime = NSColor(srgbRed: 0xC1 / 255, green: 0xFD / 255, blue: 0x8A / 255, alpha: 1)           // #C1FD8A
    static let tan = NSColor(srgbRed: 0xDD / 255, green: 0xD5 / 255, blue: 0xC3 / 255, alpha: 1)            // #DDD5C3

    /// Teal on light backgrounds, lime on dark ones: the brand pairing from flexpa.com, and both read well as control tints.
    static var accent: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? lime : teal
        })
    }

    /// The Flexpa "F": four rectangles in a 16.59 × 22.12 box (from apps/app/assets/logo-mark.ts).
    static func markPath(in rect: CGRect) -> CGPath {
        let scale = min(rect.width / 16.59, rect.height / 22.12)
        let w = 16.59 * scale, h = 22.12 * scale
        let ox = rect.midX - w / 2, oy = rect.midY - h / 2
        func r(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect {
            // Source coordinates are top-left origin; flip into the caller's space.
            CGRect(x: ox + x * scale, y: oy + (22.12 - y - height) * scale, width: width * scale, height: height * scale)
        }
        let path = CGMutablePath()
        path.addRect(r(0, 16.59, 5.53, 5.53))
        path.addRect(r(0, 5.53, 5.53, 5.53))
        path.addRect(r(5.53, 11.06, 11.06, 5.53))
        path.addRect(r(5.53, 0, 11.06, 5.53))
        return path
    }

    /// Menu bar status image: the F mark as a template so it follows the bar's appearance.
    static func menuBarImage(paused: Bool) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.setFillColor(NSColor.black.withAlphaComponent(paused ? 0.45 : 1).cgColor)
            ctx.addPath(markPath(in: rect.insetBy(dx: 2.5, dy: 1.5)))
            ctx.fillPath()
            if paused {
                ctx.setStrokeColor(NSColor.black.cgColor)
                ctx.setLineWidth(1.6)
                ctx.setLineCap(.round)
                ctx.move(to: CGPoint(x: 3, y: 3))
                ctx.addLine(to: CGPoint(x: 15, y: 15))
                ctx.strokePath()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
