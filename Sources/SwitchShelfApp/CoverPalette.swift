import CoreGraphics
import Foundation

/// A small, bounded sample of the artwork, independent of the game's name or ID.
/// Keep the resulting sRGB channels dark enough for white cover titles.
struct CoverPalette: Sendable {
    let red: Double
    let green: Double
    let blue: Double

    static let fallback = CoverPalette(red: 0.10, green: 0.13, blue: 0.18)

    static func sample(_ image: CGImage) -> CoverPalette {
        let side = 24
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(
                    data: bytes.baseAddress, width: side, height: side,
                    bitsPerComponent: 8, bytesPerRow: side * 4, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                        | CGBitmapInfo.byteOrder32Big.rawValue
                  ) else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard rendered else { return .fallback }

        var red = 0.0, green = 0.0, blue = 0.0, total = 0.0
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Double(pixels[offset + 3]) / 255
            guard alpha > 0.1 else { continue }
            let r = min(1, Double(pixels[offset]) / 255 / alpha)
            let g = min(1, Double(pixels[offset + 1]) / 255 / alpha)
            let b = min(1, Double(pixels[offset + 2]) / 255 / alpha)
            let brightest = max(r, g, b)
            let chroma = brightest - min(r, g, b)
            // Favor colorful pixels over white logos and black letterboxing.
            let weight = alpha * (0.1 + chroma) * (0.1 + min(brightest, 1 - brightest))
            red += r * weight
            green += g * weight
            blue += b * weight
            total += weight
        }
        guard total > 0 else { return .fallback }
        red /= total
        green /= total
        blue /= total
        let scale = 0.24 / max(0.24, red, green, blue)
        return CoverPalette(red: red * scale, green: green * scale, blue: blue * scale)
    }
}
