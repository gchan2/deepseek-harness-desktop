import AppKit
import Foundation

// Render a whale silhouette into a path, scaled/translated from its
// original coordinate box (center ~(500,470)).
func whalePath(scale: CGFloat, cx: CGFloat, cy: CGFloat, ox: CGFloat = 500, oy: CGFloat = 470) -> NSBezierPath {
    func pt(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
        NSPoint(x: (x - ox) * scale + cx, y: (y - oy) * scale + cy)
    }
    let p = NSBezierPath()
    // nose
    p.move(to: pt(850, 480))
    // forehead -> back -> tail base
    p.curve(to: pt(760, 360), controlPoint1: pt(860, 430), controlPoint2: pt(820, 380))
    p.curve(to: pt(420, 350), controlPoint1: pt(660, 335), controlPoint2: pt(520, 330))
    p.curve(to: pt(260, 440), controlPoint1: pt(350, 365), controlPoint2: pt(295, 415))
    // upper fluke
    p.curve(to: pt(150, 330), controlPoint1: pt(240, 410), controlPoint2: pt(175, 365))
    // fluke notch
    p.curve(to: pt(210, 480), controlPoint1: pt(150, 455), controlPoint2: pt(185, 480))
    // lower fluke
    p.curve(to: pt(150, 610), controlPoint1: pt(185, 510), controlPoint2: pt(150, 560))
    // tail base (lower)
    p.curve(to: pt(270, 550), controlPoint1: pt(205, 600), controlPoint2: pt(250, 565))
    // belly back to nose
    p.curve(to: pt(850, 480), controlPoint1: pt(560, 650), controlPoint2: pt(760, 600))
    p.close()
    return p
}

func makeBitmap(_ pixels: Int) -> (NSBitmapImageRep, NSGraphicsContext) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    return (rep, NSGraphicsContext(bitmapImageRep: rep)!)
}

func writePNG(_ rep: NSBitmapImageRep, to path: String) {
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
    print("wrote \(path)")
}

// MARK: - Main app icon (true 1024x1024)

let S = 1024
let (mainRep, mainCtx) = makeBitmap(S)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = mainCtx

let rect = NSRect(x: 0, y: 0, width: S, height: S)
let radius: CGFloat = 234
let bg = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
let top = NSColor(calibratedRed: 0.29, green: 0.45, blue: 1.00, alpha: 1.0)   // #4A73FF
let bottom = NSColor(calibratedRed: 0.08, green: 0.18, blue: 0.66, alpha: 1.0) // #142EA8
NSGradient(colors: [top, bottom])!.draw(in: bg, angle: -90)

// subtle inner ring
let ring = NSBezierPath(ovalIn: NSRect(x: 150, y: 150, width: 724, height: 724))
NSColor.white.withAlphaComponent(0.06).setStroke()
ring.lineWidth = 20
ring.stroke()

// whale, ~62% width, centered
let whale = whalePath(scale: 0.62, cx: 512, cy: 512)
NSColor.white.setFill()
whale.fill()

// eye
let eye = NSBezierPath(ovalIn: NSRect(x: 512 + (720 - 500) * 0.62, y: 512 + (430 - 470) * 0.62, width: 18, height: 18))
top.setFill()
eye.fill()

NSGraphicsContext.restoreGraphicsState()
writePNG(mainRep, to: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png")

// MARK: - Menu bar template icon (black whale, 18pt + 36pt @2x)

for (pts, name) in [(18, "menubar.png"), (36, "menubar@2x.png")] {
    let (rep, ctx) = makeBitmap(pts)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    let scale = CGFloat(16) / 700.0
    let w = whalePath(scale: scale, cx: CGFloat(pts) / 2.0, cy: CGFloat(pts) / 2.0)
    NSColor.black.setFill()
    w.fill()
    NSGraphicsContext.restoreGraphicsState()
    writePNG(rep, to: name)
}
