import CoreGraphics
import ImageIO
import Foundation

guard (3...4).contains(CommandLine.arguments.count) else {
    fatalError("Usage: swift make-icon.swift source.png output.iconset [--rounded]")
}
let input = URL(fileURLWithPath: CommandLine.arguments[1])
let directory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
guard let source = CGImageSourceCreateWithURL(input as CFURL, nil),
      let original = CGImageSourceCreateImageAtIndex(source, 0, nil) else { fatalError("Cannot read source icon") }
let rounded = CommandLine.arguments.count == 4 && CommandLine.arguments[3] == "--rounded"
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let width = size * scale
        guard let context = CGContext(data: nil, width: width, height: width, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fatalError("Cannot create icon bitmap") }
        context.interpolationQuality = .high
        if rounded {
            // Native app-icon clipping: preserve the original artwork, discard its
            // opaque outer canvas and shadow. The inset follows this supplied asset.
            let center = Double(width) / 2
            let radius = Double(width) * (0.5 - 0.092)
            let path = CGMutablePath()
            for step in 0...2048 {
                let angle = Double(step) / 2048 * 2 * Double.pi
                let c = cos(angle), s = sin(angle)
                let point = CGPoint(x: center + radius * (c < 0 ? -1 : 1) * pow(abs(c), 2 / 4.6),
                                    y: center + radius * (s < 0 ? -1 : 1) * pow(abs(s), 2 / 4.6))
                if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            path.closeSubpath()
            context.addPath(path)
            context.clip()
        }
        context.draw(original, in: CGRect(x: 0, y: 0, width: width, height: width))
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        guard let destination = CGImageDestinationCreateWithURL(directory.appendingPathComponent(name) as CFURL, "public.png" as CFString, 1, nil),
              let image = context.makeImage() else { fatalError("Cannot write icon") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { fatalError("Icon conversion failed") }
    }
}
