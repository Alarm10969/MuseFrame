import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum DesktopCropError: LocalizedError, Sendable {
    case invalidDimensions
    case unreadableImage
    case renderFailed

    var errorDescription: String? {
        switch self {
        case .invalidDimensions: "显示器像素尺寸无效或超出支持范围。"
        case .unreadableImage: "无法读取用于居中裁切的原图。"
        case .renderFailed: "未能生成桌面裁切图片。"
        }
    }
}

/// Center Crop has the same composition as the system's centered Fill mode.
/// Unlike Fill, it produces a retained sRGB raster at each display's physical pixel size.
/// This synchronous operation belongs on a background task, never on the UI thread.
enum DesktopCropRenderer {
    private static let maximumDecodeSide = 8_192
    private static let maximumOutputSide = 16_384
    private static let maximumOutputPixels = 67_108_864

    static func cropRect(imageWidth: Double, imageHeight: Double,
                         targetWidth: Double, targetHeight: Double) -> NormalizedRect {
        guard imageWidth.isFinite, imageHeight.isFinite, targetWidth.isFinite, targetHeight.isFinite,
              imageWidth > 0, imageHeight > 0, targetWidth > 0, targetHeight > 0 else {
            return NormalizedRect(x: 0, y: 0, width: 1, height: 1)
        }
        let imageAspect = imageWidth / imageHeight
        let targetAspect = targetWidth / targetHeight
        guard imageAspect.isFinite, targetAspect.isFinite, imageAspect > 0, targetAspect > 0 else {
            return NormalizedRect(x: 0, y: 0, width: 1, height: 1)
        }
        let width = min(1, targetAspect / imageAspect)
        let height = min(1, imageAspect / targetAspect)
        return NormalizedRect(x: (1 - width) / 2, y: (1 - height) / 2, width: width, height: height)
    }

    static func render(_ source: URL, width: Int, height: Int) throws -> URL {
        try renderTrackingCreation(source, width: width, height: height).url
    }

    static func renderTrackingCreation(_ source: URL, width: Int, height: Int) throws -> (url: URL, created: Bool) {
        guard width > 0, height > 0,
              width <= maximumOutputSide, height <= maximumOutputSide,
              width <= maximumOutputPixels / height else { throw DesktopCropError.invalidDimensions }
        guard source.isFileURL else { throw DesktopCropError.unreadableImage }
        try Task.checkCancellation()
        // URL resource values may cache a previous mtime on the same URL instance.
        // Read fresh file attributes so an updated source cannot reuse an older crop.
        let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
        let byteCount = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard attributes[.type] as? FileAttributeType == .typeRegular, byteCount > 0 else {
            throw DesktopCropError.unreadableImage
        }
        let identity = [
            "center-sRGB-v1", source.resolvingSymlinksInPath().path,
            String((attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0),
            String(byteCount), "\(width)x\(height)"
        ].joined(separator: "|")
        let key = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        let output = source.deletingLastPathComponent()
            .appendingPathComponent("center-\(key)-\(width)x\(height).jpg")
        if hasDimensions(output, width: width, height: height) { return (output, false) }

        guard let imageSource = CGImageSourceCreateWithURL(
            source as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary
        ), let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
              let rawWidth = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let rawHeight = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              rawWidth > 0, rawHeight > 0, rawWidth.isFinite, rawHeight.isFinite else {
            throw DesktopCropError.unreadableImage
        }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let swapsAxes = (5...8).contains(orientation)
        let sourceWidth = swapsAxes ? rawHeight : rawWidth
        let sourceHeight = swapsAxes ? rawWidth : rawHeight
        let scale = min(1, max(Double(width) / sourceWidth, Double(height) / sourceHeight))
        let desiredSide = max(sourceWidth, sourceHeight) * scale
        let decodeSide = Int(min(Double(maximumDecodeSide), max(1, desiredSide.rounded(.up))))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: decodeSide,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
              ) else { throw DesktopCropError.renderFailed }
        try Task.checkCancellation()
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.setRenderingIntent(.perceptual)
        let cover = max(Double(width) / Double(image.width), Double(height) / Double(image.height))
        let drawnWidth = Double(image.width) * cover
        let drawnHeight = Double(image.height) * cover
        context.draw(image, in: CGRect(
            x: (Double(width) - drawnWidth) / 2, y: (Double(height) - drawnHeight) / 2,
            width: drawnWidth, height: drawnHeight
        ))
        guard let raster = context.makeImage() else { throw DesktopCropError.renderFailed }
        try Task.checkCancellation()
        let temporary = output.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".partial")
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let destination = CGImageDestinationCreateWithURL(temporary as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw DesktopCropError.renderFailed
        }
        CGImageDestinationAddImage(destination, raster, [
            kCGImageDestinationLossyCompressionQuality: 0.92,
            kCGImagePropertyOrientation: 1
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw DesktopCropError.renderFailed }
        try Task.checkCancellation()
        // Atomic replacement is safe if two display requests finish the same cached crop together.
        try Data(contentsOf: temporary, options: .mappedIfSafe).write(to: output, options: .atomic)
        return (output, true)
    }

    private static func hasDimensions(_ url: URL, width: Int, height: Int) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path),
              let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return false }
        return (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue == width
            && (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue == height
    }
}
