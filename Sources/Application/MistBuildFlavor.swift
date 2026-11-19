import AppKit

enum MistBuildFlavor {
    static let devBundleIdentifier = "com.bulldf.mist.dev"
    static var isDev: Bool { Bundle.main.bundleIdentifier == devBundleIdentifier }

    @MainActor
    static func applyApplicationIcon() {
        let ribbonTitle: String
        let ribbonColor: NSColor
        switch Bundle.main.bundleIdentifier {
        case devBundleIdentifier:
            ribbonTitle = "DEV"
            ribbonColor = NSColor(srgbRed: 0.12, green: 0.16, blue: 0.24, alpha: 1)
        case "com.bulldf.mist.tests":
            ribbonTitle = "TEST"
            ribbonColor = NSColor(srgbRed: 0.48, green: 0.16, blue: 0.62, alpha: 1)
        default:
            return
        }
        guard let baseIcon = NSApp.applicationIconImage else { return }

        let iconSize = NSSize(width: 512, height: 512)
        let icon = NSImage(size: iconSize)
        // Supply both standard and Retina representations. The label belongs
        // to the icon itself so Chromium's download-count updates cannot clear it.
        for pixels in [512, 1024] {
            guard let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0
            ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return }

            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            context.imageInterpolation = .high
            let side = CGFloat(pixels)
            let bounds = NSRect(x: 0, y: 0, width: side, height: side)
            context.cgContext.clear(bounds)
            baseIcon.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1)

            let ribbon = NSRect(x: side * 0.11, y: side * 0.06,
                                width: side * 0.78, height: side * 0.28)
            ribbonColor.setFill()
            NSBezierPath(roundedRect: ribbon, xRadius: side * 0.055,
                         yRadius: side * 0.055).fill()
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: side * 0.21, weight: .heavy),
                .foregroundColor: NSColor.white
            ]
            let label = ribbonTitle as NSString
            let labelSize = label.size(withAttributes: attributes)
            label.draw(at: NSPoint(x: ribbon.midX - labelSize.width / 2,
                                   y: ribbon.midY - labelSize.height / 2),
                       withAttributes: attributes)
            NSGraphicsContext.restoreGraphicsState()

            bitmap.size = iconSize
            icon.addRepresentation(bitmap)
        }
        NSApp.applicationIconImage = icon
        NSApp.dockTile.display()
    }
}
