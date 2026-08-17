import AppKit
import Foundation

// Render the whale into a path scaled/translated from its original
// coordinate box (roughly x∈[150,820], y∈[330,590], center ~(485,460)).
func whalePath(scale: CGFloat, cx: CGFloat, cy: CGFloat, ox: CGFloat = 485, oy: CGFloat = 460) -> NSBezierPath {
    func pt(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
        NSPoint(x: (x - ox) * scale + cx, y: (y - oy) * scale + cy)
    }
    let p = NSBezierPath()
    p.move(to: pt(820, 512))
    p.curve(to: pt(760, 386), controlPoint1: pt(830, 470), controlPoint2: pt(806, 410))
    p.curve(to: pt(430, 360), controlPoint1: pt(680, 352), controlPoint2: pt(540, 346))
    p.curve(to: pt(250, 430), controlPoint1: pt(360, 370), controlPoint2: pt(300, 410))
    p.curve(to: pt(150, 330), controlPoint1: pt(230, 400), controlPoint2: pt(175, 360))
    p.curve(to: pt(215, 470), controlPoint1: pt(150, 440), controlPoint2: pt(185, 470))
    p.curve(to: pt(160, 590), controlPoint1: pt(190, 500), controlPoint2: pt(155, 545))
    p.curve(to: pt(265, 545), controlPoint1: pt(205, 585), controlPoint2: pt(245, 560))
    p.curve(to: pt(820, 512), controlPoint1: pt(560, 640), controlPoint2: pt(760, 600))
    p.close()
    return p
}

func makeBitmap(_ pixels: Int) -> (NSBitmapImageRep, NSGraphicsContext) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    return (rep, ctx)
}

func writePNG(_ rep: NSBitmapImageRep, to path: String) {
    let png = rep.representation(using: .png, properties: [:])!
    try! png.write(to: URL(fileURLWithPath: path))
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
let top = NSColor(calibratedRed: 0.29, green: 0.45, blue: 1.00, alpha: 1.0)
let bottom = NSColor(calibratedRed: 0.08, green: 0.18, blue: 0.66, alpha: 1.0)
NSGradient(colors: [top, bottom])!.draw(in: bg, angle: -90)

// Whale scaled to ~62% width, centered
let whale = whalePath(scale: 0.62, cx: 512, cy: 512)
NSColor.white.setFill()
whale.fill()

// Eye
let eye = NSBezierPath(ovalIn: NSRect(x: 512 + (700 - 485) * 0.62, y: 512 + (470 - 460) * 0.62, width: 18, height: 18))
top.setFill()
eye.fill()

NSGraphicsContext.restoreGraphicsState()
writePNG(mainRep, to: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png")

// MARK: - Menu bar template icon (black whale silhouette, 18pt + 36pt @2x)

for (pts, name) in [(18, "menubar.png"), (36, "menubar@2x.png")] {
    let (rep, ctx) = makeBitmap(pts)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    // Fit the whale to width ~16pt with 1pt margin, centered vertically
    let scale = CGFloat(16) / 670.0
    let w = whalePath(scale: scale, cx: CGFloat(pts) / 2.0, cy: CGFloat(pts) / 2.0)
    NSColor.black.setFill()
    w.fill()
    NSGraphicsContext.restoreGraphicsState()
    writePNG(rep, to: name)
}
