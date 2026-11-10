import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// A copy of CoreTests' `TestImages` (test targets can't share files): solid-colour PNGs built in memory.
enum TestImagesUI {
    static func png(size: Int = 64, red: CGFloat = 1) -> Data {
        let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: red, green: 0.2, blue: 0.2, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }

    /// The RGBA bytes of the centre pixel of `image`.
    static func centrePixel(_ image: CGImage) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &out, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: -CGFloat(image.width) / 2 + 0.5, y: -CGFloat(image.height) / 2 + 0.5,
                                   width: CGFloat(image.width), height: CGFloat(image.height)))
        return out
    }
}
