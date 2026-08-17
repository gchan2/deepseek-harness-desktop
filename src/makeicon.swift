import AppKit
import Foundation

let S: CGFloat = 1024

let image = NSImage(size: NSSize(width: S, height: S))
image.lockFocus()

// --- Background: squircle with DeepSeek-blue vertical gradient ---
let rect = NSRect(x: 0, y: 0, width: S, height: S)
let radius: CGFloat = 225
let bg = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

let top = NSColor(calibratedRed: 0.29, green: 0.45, blue: 1.00, alpha: 1.0)   // #4A73FF
let bottom = NSColor(calibratedRed: 0.08, green: 0.18, blue: 0.66, alpha: 1.0) // #142EA8
let gradient = NSGradient(colors: [top, bottom])!
gradient.draw(in: bg, angle: -90)

// --- Subtle water ring ---
let ring = NSBezierPath(ovalIn: NSRect(x: 130, y: 130, width: 764, height: 764))
NSColor.white.withAlphaComponent(0.08).setStroke()
ring.lineWidth = 26
ring.stroke()

// --- Whale silhouette (white, facing right) ---
func pt(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x, y: y) }

let whale = NSBezierPath()
// Nose tip
whale.move(to: pt(820, 512))
// Top of head
whale.curve(to: pt(760, 386), controlPoint1: pt(830, 470), controlPoint2: pt(806, 410))
// Back, sweeping left toward tail
whale.curve(to: pt(430, 360), controlPoint1: pt(680, 352), controlPoint2: pt(540, 346))
// Taper to tail base
whale.curve(to: pt(250, 430), controlPoint1: pt(360, 370), controlPoint2: pt(300, 410))
// Upper fluke
whale.curve(to: pt(150, 330), controlPoint1: pt(230, 400), controlPoint2: pt(175, 360))
// Fluke notch
whale.curve(to: pt(215, 470), controlPoint1: pt(150, 440), controlPoint2: pt(185, 470))
// Lower fluke
whale.curve(to: pt(160, 590), controlPoint1: pt(190, 500), controlPoint2: pt(155, 545))
// Back to tail base (lower)
whale.curve(to: pt(265, 545), controlPoint1: pt(205, 585), controlPoint2: pt(245, 560))
// Belly back to nose
whale.curve(to: pt(820, 512), controlPoint1: pt(560, 640), controlPoint2: pt(760, 600))
whale.close()

NSColor.white.setFill()
whale.fill()

// Eye
let eye = NSBezierPath(ovalIn: NSRect(x: 700, y: 470, width: 26, height: 26))
top.setFill()
eye.fill()

// Belly accent line
let belly = NSBezierPath()
belly.move(to: pt(300, 560))
belly.curve(to: pt(760, 560), controlPoint1: pt(420, 620), controlPoint2: pt(640, 620))
top.withAlphaComponent(0.55).setStroke()
belly.lineWidth = 14
belly.lineCapStyle = .round
belly.stroke()

image.unlockFocus()

// --- Save PNG ---
guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("Failed to render icon")
}
let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png")
try! png.write(to: out)
print("wrote \(out.path)")
