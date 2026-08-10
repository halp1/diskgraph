// Renders the app icon and writes an .icns. Original artwork.
//
//   swift Tools/GenerateAppIcon.swift App/DiskGraph/AppIcon.icns
//
// The mark is a two-ring sunburst drawn with the app's own hue mapping
// (hue° = 115 − θ), so the icon is literally a small picture of what the app
// produces rather than a generic disc.

import AppKit
import Foundation

let outputPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "AppIcon.icns"

// MARK: - Geometry

/// Fractions of the canvas. macOS app icons leave a margin around the rounded square so
/// that neighbouring icons in the Dock do not touch.
let squareInset: CGFloat = 0.098
let cornerFraction: CGFloat = 0.2237   // Apple's squircle, approximated by a rounded rect
let holeRadius: CGFloat = 0.132
let ringWidth: CGFloat = 0.096

/// Relative sizes of the wedges, outer ring nested inside the inner one. Chosen to look
/// like real disk usage — one dominant folder, a few mid-sized, a tail of small ones.
let composition: [(share: Double, children: [Double])] = [
    (0.34, [0.55, 0.27, 0.18]),
    (0.24, [0.62, 0.38]),
    (0.16, [0.5, 0.3, 0.2]),
    (0.11, [0.7, 0.3]),
    (0.08, [0.6, 0.4]),
    (0.04, [1.0]),
    (0.03, [1.0]),
]

func hue(atMidAngle radians: CGFloat) -> CGFloat {
    let degrees = radians * 180 / .pi
    var value = (115 - degrees).truncatingRemainder(dividingBy: 360)
    if value < 0 { value += 360 }
    return value / 360
}

func wedge(
    center: CGPoint, inner: CGFloat, outer: CGFloat, start: CGFloat, end: CGFloat
) -> NSBezierPath {
    // Angles run clockwise from twelve o'clock, as in the app.
    func point(_ radius: CGFloat, _ angle: CGFloat) -> CGPoint {
        CGPoint(x: center.x + sin(angle) * radius, y: center.y + cos(angle) * radius)
    }
    let path = NSBezierPath()
    let steps = max(2, Int((end - start) / 0.05))
    path.move(to: point(inner, start))
    for i in 0 ... steps {
        path.line(to: point(outer, start + (end - start) * CGFloat(i) / CGFloat(steps)))
    }
    for i in 0 ... steps {
        path.line(to: point(inner, end - (end - start) * CGFloat(i) / CGFloat(steps)))
    }
    path.close()
    return path
}

func render(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    defer { image.unlockFocus() }

    guard let context = NSGraphicsContext.current?.cgContext else { return image }
    context.setShouldAntialias(true)

    // Rounded square, dark so the vivid wedges carry the icon in both light and dark Docks.
    let inset = size * squareInset
    let square = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let corner = square.width * cornerFraction
    let plate = NSBezierPath(roundedRect: square, xRadius: corner, yRadius: corner)

    context.saveGState()
    plate.addClip()
    let background = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            NSColor(calibratedRed: 0.26, green: 0.27, blue: 0.29, alpha: 1).cgColor,
            NSColor(calibratedRed: 0.11, green: 0.11, blue: 0.12, alpha: 1).cgColor,
        ] as CFArray,
        locations: [0, 1])!
    context.drawLinearGradient(
        background,
        start: CGPoint(x: square.midX, y: square.maxY),
        end: CGPoint(x: square.midX, y: square.minY),
        options: [])
    context.restoreGState()

    // A hairline along the top edge reads as a lit bevel and keeps the plate from looking flat.
    context.saveGState()
    plate.addClip()
    NSColor(calibratedWhite: 1, alpha: 0.10).setStroke()
    let rim = NSBezierPath(roundedRect: square.insetBy(dx: size * 0.004, dy: size * 0.004),
                           xRadius: corner, yRadius: corner)
    rim.lineWidth = size * 0.008
    rim.stroke()
    context.restoreGState()

    let center = CGPoint(x: square.midX, y: square.midY)
    let hole = size * holeRadius
    let ring = size * ringWidth

    // Soft shadow under the whole mark, so it sits above the plate.
    context.saveGState()
    context.setShadow(
        offset: CGSize(width: 0, height: -size * 0.012),
        blur: size * 0.03,
        color: NSColor(calibratedWhite: 0, alpha: 0.45).cgColor)
    NSColor(calibratedWhite: 0, alpha: 0.001).setFill()
    NSBezierPath(ovalIn: CGRect(
        x: center.x - hole - ring * 2, y: center.y - hole - ring * 2,
        width: (hole + ring * 2) * 2, height: (hole + ring * 2) * 2)).fill()
    context.restoreGState()

    // The wedges. Start at three o'clock, largest first, exactly as the app lays out.
    let strokeWidth = max(size * 0.0026, 0.5)
    var angle: CGFloat = .pi / 2
    for slice in composition {
        let sweep = CGFloat(slice.share) * 2 * .pi

        func paint(_ path: NSBezierPath, midAngle: CGFloat, brightness: CGFloat) {
            NSColor(calibratedHue: hue(atMidAngle: midAngle),
                    saturation: 0.78, brightness: brightness, alpha: 1).setFill()
            path.fill()
            NSColor(calibratedWhite: 1, alpha: 0.5).setStroke()
            path.lineWidth = strokeWidth
            path.stroke()
        }

        paint(
            wedge(center: center, inner: hole, outer: hole + ring,
                  start: angle, end: angle + sweep),
            midAngle: angle + sweep / 2,
            brightness: 0.95)

        var childAngle = angle
        for share in slice.children {
            let childSweep = sweep * CGFloat(share)
            paint(
                wedge(center: center, inner: hole + ring, outer: hole + ring * 2,
                      start: childAngle, end: childAngle + childSweep),
                midAngle: childAngle + childSweep / 2,
                brightness: 0.86)
            childAngle += childSweep
        }
        angle += sweep
    }

    return image
}

// MARK: - Write the iconset

let iconset = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("DiskGraph-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let variants: [(name: String, pixels: CGFloat)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for variant in variants {
    let image = render(size: variant.pixels)
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:])
    else { fatalError("could not encode \(variant.name)") }
    try png.write(to: iconset.appendingPathComponent("\(variant.name).png"))
}

let output = URL(fileURLWithPath: outputPath)
try? FileManager.default.createDirectory(
    at: output.deletingLastPathComponent(), withIntermediateDirectories: true)

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }

try? FileManager.default.removeItem(at: iconset)
print("wrote \(output.path)")
