import AppKit
import ImageIO
import UniformTypeIdentifiers
import SnapKit

/// One window's out-of-sight pages, image streams, and serial captures.
@MainActor
final class BrowserAgentTabPreview {
    var holder: (() -> NSView?)?
    var realSize: (() -> CGSize?)?
    private struct Mount {
        let tab: Tab
        let page: NSView
        let target: String
    }
    private var wanted: [Tab] = []
    private var mounts: [Int: Mount] = [:]
    private var streams: [Int: BrowserAgentScreencast] = [:]
    private var streamTabs: [Tab] = []
    private var capturing = false
    private var captureCover: BrowserAgentScreenshotCover?
    private(set) var stills: [Int: CGImage] = [:]
    var onFrame: ((Int, CGImage) -> Void)?

    static func hasLivePage(_ tab: Tab?) -> Bool {
        guard let tab else { return false }
        return tab.crashState == nil && !tab.isDiscarded && !tab.isUnloaded
    }

    var hasActivity: Bool { !mounts.isEmpty || !streams.isEmpty }
    func isBorrowing(tabId: Int) -> Bool {
        guard let mount = mounts[tabId] else { return false }
        return mount.page.superview === holder?()
    }

    func updateMounts(_ tabs: [Tab]) { wanted = tabs; reconcile() }

    func reconcile() {
        captureCover?.reconcile()
        guard let host = holder?(), let size = realSize?(), size.width > 0, size.height > 0 else {
            release()
            return
        }
        let ids = Set(wanted.map(\.guid))
        for (id, mount) in mounts {
            if !ids.contains(id) || !Self.hasLivePage(mount.tab)
                || mount.page !== mount.tab.webContentWrapper?.nativeView
                || mount.target != mount.tab.webContentWrapper?.devToolsTargetId
                || mount.page.superview !== host {
                if mount.page.superview === host { mount.page.removeFromSuperview() }
                mounts[id] = nil
            }
        }
        for tab in wanted {
            guard Self.hasLivePage(tab), let page = tab.webContentWrapper?.nativeView,
                  let target = tab.webContentWrapper?.devToolsTargetId, !target.isEmpty else { continue }
            guard page.superview === host || page.window == nil || page.isHiddenOrHasHiddenAncestor else { continue }
            if page.superview !== host {
                page.snp.removeConstraints()
                page.translatesAutoresizingMaskIntoConstraints = true
                page.autoresizingMask = []
                page.isHidden = false
                host.addSubview(page)
            }
            let rect = CGRect(origin: .zero, size: size)
            if page.frame != rect { page.frame = rect }
            if page.bounds != rect { page.bounds = rect }
            mounts[tab.guid] = Mount(tab: tab, page: page, target: target)
        }
        reconcileStreams()
    }

    /// Normal mounts take ownership synchronously; never pull a page back out.
    func release() {
        let host = holder?()
        for mount in mounts.values where mount.page.superview === host { mount.page.removeFromSuperview() }
        mounts.removeAll()
        captureCover?.remove()
        captureCover = nil
    }

    func updateScreencasts(_ tabs: [Tab]) { streamTabs = tabs; reconcileStreams() }

    private func reconcileStreams() {
        var desired: [Int: Tab] = [:]
        for tab in streamTabs where Self.hasLivePage(tab) { desired[tab.guid] = tab }
        for (id, stream) in streams where desired[id]?.webContentWrapper?.devToolsTargetId != stream.targetId {
            stream.stop(); streams[id] = nil
        }
        for (id, tab) in desired {
            guard streams[id] == nil, let target = tab.webContentWrapper?.devToolsTargetId, !target.isEmpty else { continue }
            let stream = BrowserAgentScreencast(tab: tab, targetId: target) { [weak self] image in
                self?.stills[id] = image; self?.onFrame?(id, image)
            }
            streams[id] = stream
            stream.start()
        }
    }

    func dropStills(keeping ids: Set<Int>) { stills = stills.filter { ids.contains($0.key) } }

    enum Region { case viewport, clip(CGRect), fullPage }
    enum CaptureError: LocalizedError {
        case unavailable
        var errorDescription: String? {
            NSLocalizedString("browser.agent.screenshot.failed", value: "Screenshot capture failed. Retry after the page finishes loading.", comment: "Browser Agent - Screenshot capture failed")
        }
    }

    func captureStill(_ tab: Tab) async {
        do {
            // Leave room for the session handshake and capture in the read's reply timeout.
            let deadline = Date().addingTimeInterval(0.5)
            while capturing {
                guard Date() < deadline else { throw CaptureError.unavailable }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            guard Self.hasLivePage(tab), let target = tab.webContentWrapper?.devToolsTargetId,
                  !target.isEmpty else { throw CaptureError.unavailable }
            capturing = true
            defer { capturing = false }
            let session = try await AppDevToolsPageSession.open(targetId: target, timeout: 1,
                maxMessageBytes: PageScreenshotService.maxBase64Bytes + 1024)
            defer { session.close() }
            guard Self.hasLivePage(tab), tab.webContentWrapper?.devToolsTargetId == target else {
                throw CaptureError.unavailable
            }
            AgentUserSpaceDriveRegistry.shared.appWillSendPageCommand(toTab: tab.guid)
            let result = try await session.command("Page.captureScreenshot",
                params: ["format": "jpeg", "quality": 90], timeout: 5)
            guard Self.hasLivePage(tab), tab.webContentWrapper?.devToolsTargetId == target,
                  let encoded = result["data"] as? String, let data = Data(base64Encoded: encoded),
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw CaptureError.unavailable }
            try updateViewportStill(image, tabId: tab.guid)
        } catch {
            // A failed capture keeps the card's earlier still, if any.
        }
    }

    func screenshot(_ tab: Tab, region: Region, save: Bool) async throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(10)
        while capturing {
            guard Date() < deadline else { throw CaptureError.unavailable }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        guard Self.hasLivePage(tab), let target = tab.webContentWrapper?.devToolsTargetId else { throw CaptureError.unavailable }
        capturing = true
        defer { capturing = false; captureCover?.remove(); captureCover = nil }
        let session = try await AppDevToolsPageSession.open(targetId: target, timeout: 2,
            maxMessageBytes: PageScreenshotService.maxBase64Bytes + 1024)
        defer { session.close() }
        func command(_ method: String, _ params: [String: Any] = [:], timeout: TimeInterval = 2) async throws -> [String: Any] {
            guard Self.hasLivePage(tab), tab.webContentWrapper?.devToolsTargetId == target else { throw CaptureError.unavailable }
            AgentUserSpaceDriveRegistry.shared.appWillSendPageCommand(toTab: tab.guid)
            return try await session.command(method, params: params, timeout: timeout)
        }
        let ratioResult = try await command("Runtime.evaluate", ["expression": "window.devicePixelRatio", "returnByValue": true])
        let dpr = max(1, (ratioResult["result"] as? [String: Any])?["value"] as? CGFloat ?? 1)
        let layout = try await command("Page.getLayoutMetrics")
        let visual = layout["cssVisualViewport"] as? [String: Any] ?? [:]
        let viewport = CGRect(x: visual["pageX"] as? CGFloat ?? 0, y: visual["pageY"] as? CGFloat ?? 0,
            width: visual["clientWidth"] as? CGFloat ?? 1, height: visual["clientHeight"] as? CGFloat ?? 1)
        func capture(_ params: [String: Any], timeout: TimeInterval = 5) async throws -> CGImage {
            let result = try await command("Page.captureScreenshot", params, timeout: timeout)
            guard let encoded = result["data"] as? String, let data = PageScreenshotService.validatedPNG(encoded),
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw CaptureError.unavailable }
            return image
        }
        var displayed: CGImage?
        var rect = viewport
        var scale: CGFloat = 1
        // CDP clip.scale composes with DPR; divide so output pixels have the
        // requested scale in CSS coordinates, independently of the display.
        func clippedCaptures(_ rects: [CGRect], fullPage: Bool) async throws -> [CGImage] {
            guard !rects.isEmpty, rects.allSatisfy({ $0.width > 0 && $0.height > 0 }) else { throw CaptureError.unavailable }
            if let page = tab.webContentWrapper?.nativeView,
               !isBorrowing(tabId: tab.guid), BrowserAgentScreenshotCover.isVisible(page) {
                let frame: CGImage
                if let displayed { frame = displayed }
                else { frame = try await capture(["format": "png"]) }
                captureCover = BrowserAgentScreenshotCover(croppedImage: frame,
                    displaySize: CGSize(width: CGFloat(frame.width) / dpr, height: CGFloat(frame.height) / dpr),
                    page: page, backgroundColor: .white,
                    isValid: { tab.webContentWrapper?.nativeView === page && tab.webContentWrapper?.devToolsTargetId == target })
            }
            defer { captureCover?.remove(); captureCover = nil }
            var images: [CGImage] = []
            for rect in rects {
                images.append(try await capture(["format": "png", "captureBeyondViewport": BrowserAgentScreenshotGeometry.needsBeyondViewport(
                    rect: rect, viewport: viewport, fullPage: fullPage),
                    "clip": ["x": rect.minX, "y": rect.minY, "width": rect.width, "height": rect.height, "scale": scale / dpr]],
                    timeout: fullPage ? 15 : 5))
            }
            if captureCover != nil {
                AgentUserSpaceDriveRegistry.shared.appWillSendPageCommand(toTab: tab.guid)
                _ = try? await session.command("Runtime.evaluate", params: [
                    "expression": "new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r)))",
                    "awaitPromise": true], timeout: 0.5, closeOnTimeout: false)
            }
            return images
        }
        func clippedCapture(fullPage: Bool = false) async throws -> CGImage {
            try await clippedCaptures([rect], fullPage: fullPage)[0]
        }
        let image: CGImage
        switch region {
        case .viewport:
            let frame = try await capture(["format": "png"])
            displayed = frame
            rect.size = CGSize(width: CGFloat(frame.width) / dpr, height: CGFloat(frame.height) / dpr)
            if !save || dpr >= 2 {
                image = try resized(frame, to: save ? CGSize(width: rect.width * 2, height: rect.height * 2)
                    : BrowserAgentScreenshotGeometry.modelSize(for: rect.size))
            } else { scale = 2; image = try await clippedCapture() }
        case .clip(let clip):
            rect = clip.offsetBy(dx: viewport.minX, dy: viewport.minY)
            scale = save ? 2 : BrowserAgentScreenshotGeometry.closeUpScale(for: rect.size)
            image = try await clippedCapture()
        case .fullPage:
            let content = layout["cssContentSize"] as? [String: Any] ?? [:]
            rect = CGRect(x: 0, y: 0, width: content["width"] as? CGFloat ?? viewport.width,
                          height: content["height"] as? CGFloat ?? viewport.height)
            if !save, let tiling = BrowserAgentScreenshotGeometry.fullPageTiling(page: rect.size, viewport: viewport.size) {
                scale = tiling.scale
                let starts = Array(stride(from: 0, to: tiling.count, by: 4))
                let batches = starts.map { start in
                    tiling.rect(start, pageWidth: rect.width).union(tiling.rect(min(start + 3, tiling.count - 1), pageWidth: rect.width))
                }
                let images = try await clippedCaptures(batches, fullPage: true)
                var tiles: [[String: Any]] = []
                for (batch, image) in images.enumerated() {
                    let start = starts[batch]
                    for index in start..<min(start + 4, tiling.count) {
                        let tileRect = tiling.rect(index, pageWidth: rect.width)
                        let row = (index - start) * tiling.pixelHeight
                        let height = min(tiling.pixelHeight, Int((tileRect.height * scale).rounded()), image.height - row)
                        guard height > 0, let cropped = image.cropping(to: CGRect(x: 0, y: row,
                            width: min(tiling.pixelWidth, image.width), height: height)) else { throw CaptureError.unavailable }
                        var mimeType = "image/png"
                        var encoded = try encode(cropped)
                        if encoded.count > 3_500_000 { encoded = try encode(cropped, jpeg: true); mimeType = "image/jpeg" }
                        tiles.append(["image": encoded.base64EncodedString(), "mimeType": mimeType,
                            "width": cropped.width, "height": cropped.height, "y": tileRect.minY, "cssHeight": tileRect.height])
                    }
                }
                return ["ok": true, "tiles": tiles, "scale": CGFloat(tiles[0]["width"] as? Int ?? tiling.pixelWidth) / rect.width,
                    "pageWidth": rect.width, "pageHeight": rect.height, "coveredHeight": tiling.coveredHeight, "truncated": tiling.truncated]
            }
            let model = BrowserAgentScreenshotGeometry.modelSize(for: rect.size)
            scale = BrowserAgentScreenshotGeometry.fullPageScale(for: rect.size, dpr: dpr,
                maxScale: save ? 2 : model.width / rect.width)
            image = try await clippedCapture(fullPage: true)
        }
        let model = try resized(image, to: BrowserAgentScreenshotGeometry.modelSize(for: CGSize(width: image.width, height: image.height)))
        var mimeType = "image/png"
        var encoded = try encode(model)
        if encoded.count > 3_500_000 { encoded = try encode(model, jpeg: true); mimeType = "image/jpeg" }
        var result: [String: Any] = ["ok": true, "image": encoded.base64EncodedString(), "mimeType": mimeType,
            "width": model.width, "height": model.height, "scale": CGFloat(model.width) / rect.width,
            "cssRect": ["x": rect.minX, "y": rect.minY, "width": rect.width, "height": rect.height]]
        if save {
            result["data"] = try encode(image).base64EncodedString()
            result["dataWidth"] = image.width; result["dataHeight"] = image.height
        }
        if case .viewport = region {
            try updateViewportStill(image, tabId: tab.guid)
        }
        return result
    }

    private func updateViewportStill(_ image: CGImage, tabId: Int) throws {
        let size = CGSize(width: image.width, height: image.height)
        let factor = min(1, 1280 / max(size.width, size.height))
        let still = try resized(image, to: CGSize(width: size.width * factor, height: size.height * factor))
        stills[tabId] = still
        onFrame?(tabId, still)
    }

    private func resized(_ image: CGImage, to size: CGSize) throws -> CGImage {
        let width = max(1, Int(size.width)), height = max(1, Int(size.height))
        if image.width == width && image.height == height { return image }
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw CaptureError.unavailable }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let result = context.makeImage() else { throw CaptureError.unavailable }
        return result
    }

    private func encode(_ image: CGImage, jpeg: Bool = false) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data,
            (jpeg ? UTType.jpeg : UTType.png).identifier as CFString, 1, nil) else { throw CaptureError.unavailable }
        CGImageDestinationAddImage(destination, image,
            jpeg ? [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary : nil)
        guard CGImageDestinationFinalize(destination) else { throw CaptureError.unavailable }
        return data as Data
    }

    deinit { for stream in streams.values { stream.close() } }
}
