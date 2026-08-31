import AppKit

let variant = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "remote"
let size: CGFloat = 1024

// lockFocus renders at the display's backing scale, so draw into an explicit
// bitmap to get predictable pixel dimensions.
let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0
)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

let rect = NSRect(x: 0, y: 0, width: size, height: size)
NSBezierPath(roundedRect: rect, xRadius: size * 0.225, yRadius: size * 0.225).addClip()

func fill(_ colour: NSColor) {
    ctx.setFillColor(colour.cgColor)
    ctx.fill(rect)
}

let ink = NSColor(calibratedWhite: 0.91, alpha: 1)

switch variant {

case "remote":
    // Siri Remote silhouette on near-black, the way the Apple TV Remote app reads.
    fill(NSColor(calibratedWhite: 0.10, alpha: 1))

    // The Siri Remote is roughly 3.4:1 — anything squarer reads as a phone.
    let bodyWidth = size * 0.205
    let bodyHeight = size * 0.68
    let body = NSRect(
        x: (size - bodyWidth) / 2,
        y: (size - bodyHeight) / 2,
        width: bodyWidth,
        height: bodyHeight
    )
    ctx.setFillColor(ink.cgColor)
    NSBezierPath(roundedRect: body, xRadius: bodyWidth * 0.32, yRadius: bodyWidth * 0.32).fill()

    // The clickpad: a solid disc, so it survives down to 16pt.
    let padDiameter = bodyWidth * 0.60
    let padCentre = CGPoint(x: size / 2, y: body.maxY - bodyHeight * 0.185)
    ctx.setFillColor(NSColor(calibratedWhite: 0.10, alpha: 1).cgColor)
    ctx.addArc(center: padCentre, radius: padDiameter / 2, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    ctx.fillPath()

case "ring":
    // The D-pad, stripped to one stroke.
    fill(NSColor(calibratedWhite: 0.10, alpha: 1))
    ctx.setStrokeColor(ink.cgColor)
    ctx.setLineWidth(size * 0.10)
    ctx.addArc(center: CGPoint(x: size / 2, y: size / 2), radius: size * 0.28,
               startAngle: 0, endAngle: .pi * 2, clockwise: false)
    ctx.strokePath()

case "ringdot":
    fill(NSColor(calibratedWhite: 0.10, alpha: 1))
    let centre = CGPoint(x: size / 2, y: size / 2)
    ctx.setStrokeColor(ink.cgColor)
    ctx.setLineWidth(size * 0.095)
    ctx.addArc(center: centre, radius: size * 0.29, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    ctx.strokePath()
    ctx.setFillColor(ink.cgColor)
    ctx.addArc(center: centre, radius: size * 0.085, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    ctx.fillPath()

default:
    exit(1)
}

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!
    .write(to: URL(fileURLWithPath: "icon-\(variant).png"))
print("wrote icon-\(variant).png")
