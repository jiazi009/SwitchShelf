import CoreGraphics
import Foundation

/// Standalone checks against the app's real cover sampler. No AppKit launch,
/// remote artwork, NAS access, cache writes, or USB interaction is involved.
@main
struct VerifyCoverPresentation {
    struct Pixel {
        let red: UInt8
        let green: UInt8
        let blue: UInt8
        var alpha: UInt8 = 255

        static let red = Pixel(red: 255, green: 0, blue: 0)
        static let green = Pixel(red: 0, green: 255, blue: 0)
        static let blue = Pixel(red: 0, green: 0, blue: 255)
        static let black = Pixel(red: 0, green: 0, blue: 0)
        static let white = Pixel(red: 255, green: 255, blue: 255)
        static let clear = Pixel(red: 0, green: 0, blue: 0, alpha: 0)
    }

    struct Verification {
        var count = 0
        var failures = [String]()

        mutating func check(_ name: String, _ condition: Bool) {
            count += 1
            if condition {
                print("PASS \(name)")
            } else {
                failures.append(name)
                print("FAIL \(name)")
            }
        }

        mutating func validTitleBackground(_ name: String, _ palette: CoverPalette) {
            let channels = [palette.red, palette.green, palette.blue]
            check("\(name): finite sRGB channels", channels.allSatisfy { $0.isFinite && (0...1).contains($0) })
            check("\(name): white title contrast ≥ 4.5:1", contrastWithWhite(palette) >= 4.5)
        }
    }

    static func main() throws {
        var verification = Verification()
        let colors: [(String, Pixel, (CoverPalette) -> Bool)] = [
            ("red artwork", .red, { $0.red > 0.15 && $0.red > $0.green * 3 && $0.red > $0.blue * 3 }),
            ("green artwork", .green, { $0.green > 0.15 && $0.green > $0.red * 3 && $0.green > $0.blue * 3 }),
            ("blue artwork", .blue, { $0.blue > 0.15 && $0.blue > $0.red * 3 && $0.blue > $0.green * 3 }),
            ("orange artwork", Pixel(red: 255, green: 128, blue: 0), { $0.red > $0.green && $0.green > $0.blue }),
            ("purple artwork", Pixel(red: 160, green: 32, blue: 240), { $0.blue > $0.red && $0.red > $0.green })
        ]
        for (name, color, preservesHue) in colors {
            let palette = CoverPalette.sample(try image(width: 96, height: 96) { _, _ in color })
            verification.validTitleBackground(name, palette)
            verification.check("\(name): retains sampled hue", preservesHue(palette))
        }

        let transparent = CoverPalette.sample(try image(width: 48, height: 48) { _, _ in .clear })
        verification.validTitleBackground("transparent artwork", transparent)
        verification.check("transparent artwork: uses neutral fallback", same(transparent, CoverPalette.fallback))

        let lowAlpha = CoverPalette.sample(try image(width: 48, height: 48) { _, _ in
            Pixel(red: 255, green: 0, blue: 0, alpha: 16)
        })
        verification.check("nearly transparent artwork: ignores invisible color", same(lowAlpha, CoverPalette.fallback))

        let translucent = CoverPalette.sample(try image(width: 48, height: 48) { _, _ in
            Pixel(red: 0, green: 192, blue: 255, alpha: 128)
        })
        verification.validTitleBackground("translucent artwork", translucent)
        verification.check("translucent artwork: unpremultiplies color", translucent.blue > translucent.green && translucent.green > translucent.red)

        for (name, pixel) in [("white artwork", Pixel.white), ("black artwork", Pixel.black), ("gray artwork", Pixel(red: 128, green: 128, blue: 128))] {
            let palette = CoverPalette.sample(try image(width: 48, height: 48) { _, _ in pixel })
            verification.validTitleBackground(name, palette)
            verification.check("\(name): remains achromatic", abs(palette.red - palette.green) < 0.002 && abs(palette.green - palette.blue) < 0.002)
        }

        let reference = CoverPalette.sample(try image(width: 96, height: 96) { _, _ in .green })
        for (name, width, height) in [("single pixel", 1, 1), ("wide artwork", 480, 24), ("tall artwork", 24, 480), ("thumbnail", 40, 40), ("large artwork", 1200, 1200)] {
            let palette = CoverPalette.sample(try image(width: width, height: height) { _, _ in .green })
            verification.validTitleBackground(name, palette)
            verification.check("\(name): sample is independent of image dimensions", same(palette, reference, tolerance: 0.002))
        }

        let withLogoAndBorder = CoverPalette.sample(try image(width: 120, height: 120) { x, y in
            if x < 12 || x >= 108 || y < 12 || y >= 108 { return .black }
            if x >= 36 && x < 84 && y >= 36 && y < 60 { return .white }
            return .red
        })
        verification.validTitleBackground("red artwork with white logo and black border", withLogoAndBorder)
        verification.check("logo and border do not overwhelm artwork hue", withLogoAndBorder.red > withLogoAndBorder.green * 3 && withLogoAndBorder.red > withLogoAndBorder.blue * 3)

        verification.validTitleBackground("missing artwork fallback", CoverPalette.fallback)
        print("\n\(verification.count) checks, \(verification.failures.count) failures")
        if !verification.failures.isEmpty {
            throw VerificationFailure(failures: verification.failures)
        }
    }

    private static func image(width: Int, height: Int, pixel: (Int, Int) -> Pixel) throws -> CGImage {
        var bytes = [UInt8]()
        bytes.reserveCapacity(width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let color = pixel(x, y)
                let alpha = UInt16(color.alpha)
                // Supply actual premultiplied RGBA, including partial-alpha fixtures.
                bytes.append(UInt8(UInt16(color.red) * alpha / 255))
                bytes.append(UInt8(UInt16(color.green) * alpha / 255))
                bytes.append(UInt8(UInt16(color.blue) * alpha / 255))
                bytes.append(color.alpha)
            }
        }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4, space: space,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
              ) else { throw VerificationFailure(failures: ["Could not create synthetic image fixture"] ) }
        return image
    }

    private static func same(_ lhs: CoverPalette, _ rhs: CoverPalette, tolerance: Double = 0.0001) -> Bool {
        abs(lhs.red - rhs.red) < tolerance && abs(lhs.green - rhs.green) < tolerance && abs(lhs.blue - rhs.blue) < tolerance
    }

    private static func contrastWithWhite(_ palette: CoverPalette) -> Double {
        func linearize(_ channel: Double) -> Double {
            channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linearize(palette.red) + 0.7152 * linearize(palette.green) + 0.0722 * linearize(palette.blue)
        return 1.05 / (luminance + 0.05)
    }

    private struct VerificationFailure: Error, CustomStringConvertible {
        let failures: [String]
        var description: String { failures.joined(separator: "; ") }
    }
}
