import AppKit
import ImageIO
import UniformTypeIdentifiers

enum ClaudeCodeImageNormalizer {
    static let maximumBytes = 5 * 1024 * 1024
    static let maximumDimension = 2000
    static let pasteboardTypes: [NSPasteboard.PasteboardType] = Array(Set([
        .fileURL, .png, .tiff, .init(UTType.jpeg.identifier),
        .init(UTType.gif.identifier), .init(UTType.webP.identifier), .init(UTType.heic.identifier),
    ] + NSImage.imageTypes.map { NSPasteboard.PasteboardType($0) }))

    static func attachment(fileURL: URL) -> AgentAttachment? {
        guard fileURL.isFileURL else { return nil }
        let source = fileURL.resolvingSymlinksInPath()
        guard let values = try? source.resourceValues(forKeys: [.isRegularFileKey, .isPackageKey, .contentTypeKey]),
              values.isRegularFile == true, values.isPackage != true else { return nil }
        if values.contentType?.conforms(to: .image) == true, let image = normalize(fileURL: source) {
            return .image(image)
        }
        return .file(.init(url: fileURL.standardizedFileURL))
    }

    static func attachment(item: NSPasteboardItem) -> AgentAttachment? {
        if item.types.contains(.fileURL) {
            guard let path = item.string(forType: .fileURL), let url = URL(string: path) else { return nil }
            return attachment(fileURL: url)
        }
        return normalize(item: item).map(AgentAttachment.image)
    }

    static func normalize(fileURL: URL) -> AgentImageAttachment? {
        guard fileURL.isFileURL, let data = try? Data(contentsOf: fileURL) else { return nil }
        return normalize(data: data)
    }

    static func normalize(item: NSPasteboardItem) -> AgentImageAttachment? {
        // Prefer the original encoding to a pasteboard's generated TIFF representation.
        for type in item.types where type != .tiff && type != .fileURL {
            guard UTType(type.rawValue)?.conforms(to: .image) == true,
                  let data = item.data(forType: type) else { continue }
            if let attachment = normalize(data: data) { return attachment }
        }
        return item.data(forType: .tiff).flatMap { normalize(data: $0) }
    }

    static func normalize(data: Data) -> AgentImageAttachment? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            // AppKit can decode additional image representations (for example PDF).
            guard let image = NSImage(data: data), let tiff = image.tiffRepresentation,
                  tiff != data else { return nil }
            return normalize(data: tiff)
        }
        let type = CGImageSourceGetType(source) as String?
        let mediaTypes = [UTType.png.identifier: "image/png", UTType.jpeg.identifier: "image/jpeg",
                          UTType.gif.identifier: "image/gif", UTType.webP.identifier: "image/webp"]
        let oversized = data.count > maximumBytes || max(width, height) > maximumDimension
        if !oversized, let type, let mediaType = mediaTypes[type] {
            return .init(data: data, mediaType: mediaType)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(max(width, height), maximumDimension),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let bitmap = NSBitmapImageRep(cgImage: image)
        let output = bitmap.representation(using: oversized ? .jpeg : .png,
                                           properties: oversized ? [.compressionFactor: 0.85] : [:])
        guard let output else { return nil }
        // A converted source can be larger than its compressed original.
        if !oversized && output.count > maximumBytes { return normalize(data: output) }
        guard output.count <= maximumBytes else { return nil }
        return .init(data: output, mediaType: oversized ? "image/jpeg" : "image/png")
    }
}
