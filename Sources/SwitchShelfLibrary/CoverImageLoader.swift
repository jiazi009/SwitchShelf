import CoreGraphics
import Foundation
import ImageIO

/// A downscaled JPEG thumbnail. Square artwork is flagged so the UI can keep its
/// full composition above the title gradient, or display a compact square icon.
public struct CoverThumbnail: Sendable, Equatable {
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var jpegData: Data

    public init(pixelWidth: Int, pixelHeight: Int, jpegData: Data) {
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.jpegData = jpegData
    }

    public var isSquare: Bool {
        guard pixelWidth > 0, pixelHeight > 0 else { return false }
        let ratio = Double(pixelWidth) / Double(pixelHeight)
        return ratio >= 0.85 && ratio <= 1.15
    }
}

public enum CoverImageLoader {
    public static let maxPixel = 480

    /// Reads a local regular file and returns a bounded JPEG thumbnail.
    /// Symlinks, oversized files and undecodable data return nil.
    public static func thumbnail(at url: URL, maxPixel: Int = CoverImageLoader.maxPixel) -> CoverThumbnail? {
        guard url.isFileURL, maxPixel > 0 else { return nil }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let values = try? url.resourceValues(forKeys: keys),
              values.isSymbolicLink != true,
              values.isRegularFile == true,
              LocalCoverLocator.accepts(byteCount: Int64(values.fileSize ?? 0)) else { return nil }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        return thumbnail(from: source, maxPixel: maxPixel)
    }

    /// Decodes image bytes already in memory. Oversized or undecodable data returns nil.
    public static func thumbnail(from data: Data, maxPixel: Int = CoverImageLoader.maxPixel) -> CoverThumbnail? {
        guard maxPixel > 0, !data.isEmpty, data.count <= 20 * 1024 * 1024 else { return nil }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        return thumbnail(from: source, maxPixel: maxPixel)
    }

    private static func thumbnail(from source: CGImageSource, maxPixel: Int) -> CoverThumbnail? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
        let properties = [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary
        CGImageDestinationAddImage(destination, image, properties)
        guard CGImageDestinationFinalize(destination), data.length > 0 else { return nil }
        return CoverThumbnail(pixelWidth: image.width, pixelHeight: image.height, jpegData: data as Data)
    }
}
