import CoreGraphics
import ImageIO
import Foundation

let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let width = size * scale
        let context = CGContext(data: nil, width: width, height: width, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.scaleBy(x: CGFloat(width) / 1024, y: CGFloat(width) / 1024)
        let rect = CGRect(x: 74, y: 74, width: 876, height: 876)
        context.addPath(CGPath(roundedRect: rect, cornerWidth: 205, cornerHeight: 205, transform: nil))
        context.clip()
        let colors = [CGColor(red: 0.05, green: 0.50, blue: 0.99, alpha: 1), CGColor(red: 0.12, green: 0.24, blue: 0.83, alpha: 1)]
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1])!
        context.drawLinearGradient(gradient, start: CGPoint(x: 200, y: 900), end: CGPoint(x: 850, y: 100), options: [])
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        for (i, height) in [150.0, 320, 490, 270, 390, 190].enumerated() {
            let bar = CGRect(x: 242 + Double(i) * 91, y: 512 - height / 2, width: 46, height: height)
            context.addPath(CGPath(roundedRect: bar, cornerWidth: 23, cornerHeight: 23, transform: nil)); context.fillPath()
        }
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        let destination = CGImageDestinationCreateWithURL(directory.appendingPathComponent(name) as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        guard CGImageDestinationFinalize(destination) else { fatalError("Icon generation failed") }
    }
}
