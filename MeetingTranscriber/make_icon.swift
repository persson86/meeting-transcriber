// make_icon.swift — gera AppIcon.icns para MeetingTranscriber
// Compile & run: swiftc make_icon.swift -framework AppKit -o make_icon && ./make_icon
import AppKit

func drawIcon(size: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    defer { img.unlockFocus() }

    let ctx = NSGraphicsContext.current!.cgContext
    let rect = CGRect(origin: .zero, size: CGSize(width: size, height: size))

    // — Background: rounded rect with deep indigo gradient —
    let corner = size * 0.22
    let path = NSBezierPath(roundedRect: rect, xRadius: corner, yRadius: corner)
    path.addClip()

    let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            CGColor(red: 0.22, green: 0.18, blue: 0.60, alpha: 1),   // indigo top
            CGColor(red: 0.10, green: 0.07, blue: 0.38, alpha: 1)    // deep indigo bottom
        ] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(gradient,
                           start: CGPoint(x: size / 2, y: size),
                           end:   CGPoint(x: size / 2, y: 0),
                           options: [])

    // — Subtle inner glow —
    let glowGradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            CGColor(red: 1, green: 1, blue: 1, alpha: 0.08),
            CGColor(red: 1, green: 1, blue: 1, alpha: 0)
        ] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawRadialGradient(glowGradient,
                           startCenter: CGPoint(x: size * 0.5, y: size * 0.72),
                           startRadius: 0,
                           endCenter:   CGPoint(x: size * 0.5, y: size * 0.5),
                           endRadius:   size * 0.55,
                           options: [])

    // — Mic body —
    let mw = size * 0.22  // mic width
    let mh = size * 0.32  // mic height
    let mx = (size - mw) / 2
    let my = size * 0.38
    let mr = mw / 2

    let micBody = NSBezierPath(roundedRect: CGRect(x: mx, y: my, width: mw, height: mh),
                               xRadius: mr, yRadius: mr)
    NSColor.white.withAlphaComponent(0.95).setFill()
    micBody.fill()

    // — Arc (mic stand) —
    let arcPath = NSBezierPath()
    let arcCX = size / 2
    let arcR  = size * 0.20
    let arcY  = my + mh * 0.35
    arcPath.move(to: CGPoint(x: arcCX - arcR, y: arcY))
    arcPath.appendArc(withCenter: CGPoint(x: arcCX, y: arcY),
                      radius: arcR,
                      startAngle: 180, endAngle: 0,
                      clockwise: true)
    arcPath.lineWidth = size * 0.045
    NSColor.white.withAlphaComponent(0.95).setStroke()
    arcPath.stroke()

    // — Stem —
    let stemPath = NSBezierPath()
    stemPath.move(to:    CGPoint(x: arcCX, y: arcY))
    stemPath.line(to:    CGPoint(x: arcCX, y: my - size * 0.07))
    stemPath.lineWidth = size * 0.045
    stemPath.stroke()

    // — Base line —
    let basePath = NSBezierPath()
    let baseW = size * 0.24
    basePath.move(to:    CGPoint(x: arcCX - baseW / 2, y: my - size * 0.07))
    basePath.line(to:    CGPoint(x: arcCX + baseW / 2, y: my - size * 0.07))
    basePath.lineWidth = size * 0.045
    basePath.lineCapStyle = .round
    basePath.stroke()

    return img
}

// Generate each required size
let iconsetPath = "Resources/AppIcon.iconset"
let fm = FileManager.default
try! fm.createDirectory(atPath: iconsetPath, withIntermediateDirectories: true)

let sizes: [(name: String, size: CGFloat, scale: Int)] = [
    ("icon_16x16",     16,  1),
    ("icon_16x16",     32,  2),
    ("icon_32x32",     32,  1),
    ("icon_32x32",     64,  2),
    ("icon_128x128",   128, 1),
    ("icon_128x128",   256, 2),
    ("icon_256x256",   256, 1),
    ("icon_256x256",   512, 2),
    ("icon_512x512",   512, 1),
    ("icon_512x512",   1024, 2),
]

for entry in sizes {
    let img = drawIcon(size: entry.size)
    let suffix = entry.scale == 2 ? "@2x" : ""
    let filename = "\(iconsetPath)/\(entry.name)\(suffix).png"

    guard let tiff = img.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else {
        print("Failed: \(filename)"); continue
    }
    try! png.write(to: URL(fileURLWithPath: filename))
    print("✓ \(filename)")
}

print("\nDone — run: iconutil -c icns Resources/AppIcon.iconset")
