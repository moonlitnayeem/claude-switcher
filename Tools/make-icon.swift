import AppKit

// Rebuild the source-controlled icon with swift Tools/make-icon.swift <output.iconset>
// followed by iconutil -c icns <output.iconset>.

let arguments = CommandLine.arguments
guard arguments.count > 1 else {
    FileHandle.standardError.write(Data("usage: make-icon <output.iconset>\n".utf8))
    exit(1)
}
let outputDirectory = URL(fileURLWithPath: arguments[1])
try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

/// The rounded square macOS uses, which is a superellipse and not a rectangle
/// with circular corners. Described, the difference sounds like nothing; in the
/// Dock it is the only icon on the shelf whose corners meet its edges at a
/// visible kink.
func squircle(in rect: CGRect, exponent: Double = 5) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2
    let centre = CGPoint(x: rect.midX, y: rect.midY)
    let steps = 512
    for step in 0...steps {
        let t = Double(step) / Double(steps) * 2 * .pi
        let power = 2 / exponent
        let x = copysign(pow(abs(cos(t)), power), cos(t))
        let y = copysign(pow(abs(sin(t)), power), sin(t))
        let point = CGPoint(x: centre.x + a * x, y: centre.y + b * y)
        step == 0 ? path.move(to: point) : path.addLine(to: point)
    }
    path.closeSubpath()
    return path
}

func colour(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xff) / 255,
            green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255,
            alpha: alpha)
}

func draw(size: Int) -> Data? {
    let side = CGFloat(size)
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
        let context = NSGraphicsContext(bitmapImageRep: bitmap)?.cgContext
    else { return nil }

    // Work in the same 1024-unit coordinate system for every Finder and Dock size.
    context.scaleBy(x: side / 1024, y: side / 1024)
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = squircle(in: body)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -11), blur: 20, color: colour(0x092C27, 0.33))
    context.addPath(shape)
    context.setFillColor(colour(0x0B3934))
    context.fillPath()
    context.restoreGState()
    context.saveGState()
    context.addPath(shape)
    context.clip()

    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: [colour(0x306D65), colour(0x174842), colour(0x082B29)] as CFArray,
                              locations: [0, 0.47, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: 125, y: 920),
                               end: CGPoint(x: 903, y: 120), options: [])
    // Opposed slider positions echo the two accounts. Their silhouettes stay distinct at 16 px.
    func track(y: CGFloat, fill: CGColor, thumbOnRight: Bool, thumb: CGColor) {
        let rect = CGRect(x: 260, y: y, width: 504, height: 158)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -4), blur: 8, color: colour(0x001C19, 0.25))
        context.addPath(CGPath(roundedRect: rect, cornerWidth: 79, cornerHeight: 79, transform: nil))
        context.setFillColor(fill)
        context.fillPath()
        context.restoreGState()
        let center = thumbOnRight ? rect.maxX - 79 : rect.minX + 79
        let circle = CGRect(x: center - 51, y: rect.midY - 51, width: 102, height: 102)
        context.setFillColor(thumb)
        context.fillEllipse(in: circle)
    }
    track(y: 542, fill: colour(0xAAF1CE), thumbOnRight: true, thumb: colour(0x174940))
    track(y: 323, fill: colour(0x467B70), thumbOnRight: false, thumb: colour(0xEBFFF2))
    context.restoreGState()

    return bitmap.representation(using: .png, properties: [:])
}

// The sizes iconutil expects, each in its one-times and two-times form.
let sizes = [16, 32, 128, 256, 512]
for size in sizes {
    for scale in [1, 2] {
        guard let data = draw(size: size * scale) else { continue }
        let name = scale == 1 ? "icon_\(size)x\(size).png" : "icon_\(size)x\(size)@2x.png"
        try? data.write(to: outputDirectory.appending(path: name))
    }
}

// The site and the README want a plain PNG of the same drawing. Written beside
// the iconset when asked for, so the two can never drift apart.
if arguments.count > 2, let data = draw(size: 512) {
    try? data.write(to: URL(fileURLWithPath: arguments[2]))
}

print("wrote \(outputDirectory.path)")
