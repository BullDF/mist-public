import AppKit
import UniformTypeIdentifiers

/// Paste and drop share the same priority rules, including the source's representation order.
@MainActor
enum MistClipboardPasteboard {
    static var draggedTypes: [NSPasteboard.PasteboardType] {
        Array(Set(NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) } +
            [.fileURL, .string, .png, .tiff] +
            [UTType.jpeg, .heic, .gif, .utf16PlainText].map { NSPasteboard.PasteboardType($0.identifier) }))
    }

    static func read(_ pasteboard: NSPasteboard, directory: URL) async throws -> MistClipboardDraft {
        try await withCheckedThrowingContinuation { continuation in
            stage(pasteboard, directory: directory) { continuation.resume(with: $0) }
        }
    }

    /// Capture data and request file promises before AppKit ends the drop's pasteboard session.
    static func stage(_ pasteboard: NSPasteboard, directory: URL,
                      completion: @escaping (Result<MistClipboardDraft, Error>) -> Void) {
        do {
            if let receivers = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver],
               !receivers.isEmpty,
               (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL])?.isEmpty != false {
                guard receivers.count == 1, receivers[0].fileTypes.count <= 1 else { throw MistClipboardError.oneFile }
                let folder = directory.appendingPathComponent("Incoming/\(UUID())", isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let receiver = receivers[0]
                var finished = false
                receiver.receivePromisedFiles(atDestination: folder, options: [:], operationQueue: .main) { url, error in
                    guard !finished else { return }
                    finished = true
                    defer { try? FileManager.default.removeItem(at: folder) }
                    do {
                        if let error { throw error }
                        guard receiver.fileNames.count == 1 else { throw MistClipboardError.oneFile }
                        var draft = try fileDraft(url)
                        if draft.uti.flatMap({ UTType($0) })?.conforms(to: .image) == true { draft.type = .image }
                        completion(.success(draft))
                    } catch { completion(.failure(error)) }
                }
            } else {
                completion(.success(try immediate(pasteboard)))
            }
        } catch { completion(.failure(error)) }
    }

    private static func immediate(_ pasteboard: NSPasteboard) throws -> MistClipboardDraft {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            guard urls.count == 1 else { throw MistClipboardError.oneFile }
            return try fileDraft(urls[0])
        }
        guard let first = pasteboard.pasteboardItems?.first else { throw MistClipboardError.nothing }
        let imageIndex = first.types.firstIndex { UTType($0.rawValue)?.conforms(to: .image) == true }
        let textIndex = first.types.firstIndex { UTType($0.rawValue)?.conforms(to: .text) == true }
        if let imageIndex, textIndex == nil || imageIndex < textIndex! {
            let preferred: [UTType] = [.png, .jpeg, .heic, .gif, .tiff]
            let type = preferred.compactMap { wanted in
                first.types.first { UTType($0.rawValue)?.conforms(to: wanted) == true }
            }.first ?? first.types[imageIndex]
            guard var bytes = first.data(forType: type), !bytes.isEmpty else { throw MistClipboardError.nothing }
            var uti = type.rawValue
            if UTType(uti)?.conforms(to: .tiff) == true {
                guard let bitmap = NSBitmapImageRep(data: bytes), let png = bitmap.representation(using: .png, properties: [:]) else {
                    throw MistClipboardError.nothing
                }
                bytes = png
                uti = UTType.png.identifier
            }
            return try validated(MistClipboardDraft(type: .image, data: bytes, uti: uti))
        }
        let plainTypes = first.types.filter { UTType($0.rawValue)?.conforms(to: .plainText) == true }
        if let text = first.string(forType: .string) ?? plainTypes.compactMap({ first.string(forType: $0) }).first {
            return try validated(MistClipboardDraft(type: .text, data: Data(text.utf8), uti: UTType.utf8PlainText.identifier))
        }
        throw MistClipboardError.nothing
    }

    /// A Finder drop and a file chosen in the Clipboard tab's open panel both stage here.
    static func fileDraft(_ url: URL) throws -> MistClipboardDraft {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentTypeKey])
        guard values.isRegularFile == true else { throw MistClipboardError.oneFile }
        guard (values.fileSize ?? 0) <= MistClipboardSyncSource.maxSize else { throw MistClipboardError.tooLarge }
        return try validated(MistClipboardDraft(type: .file, data: Data(contentsOf: url), name: url.lastPathComponent,
                                                uti: values.contentType?.identifier ?? UTType.data.identifier))
    }

    private static func validated(_ draft: MistClipboardDraft) throws -> MistClipboardDraft {
        guard !draft.data.isEmpty else { throw MistClipboardError.nothing }
        guard draft.data.count <= MistClipboardSyncSource.maxSize else { throw MistClipboardError.tooLarge }
        return draft
    }

    static func copy(_ item: MistClipboardItem, source: MistClipboardSyncSource, to pasteboard: NSPasteboard = .general) throws {
        let data = try source.data(for: item)
        switch item.type {
        case .text:
            guard let text = String(data: data, encoding: .utf8) else { throw MistClipboardError.nothing }
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        case .file:
            let url = try source.cachedFileURL(for: item)
            pasteboard.clearContents()
            pasteboard.writeObjects([url as NSURL])
        case .image:
            let value = NSPasteboardItem()
            let type = NSPasteboard.PasteboardType(item.uti ?? UTType.png.identifier)
            value.setData(data, forType: type)
            if type != .tiff, let tiff = NSImage(data: data)?.tiffRepresentation { value.setData(tiff, forType: .tiff) }
            pasteboard.clearContents()
            pasteboard.writeObjects([value])
        }
    }

    static func drag(_ item: MistClipboardItem, source: MistClipboardSyncSource) throws -> NSItemProvider {
        let data = try source.data(for: item)
        if item.type == .text {
            guard let text = String(data: data, encoding: .utf8) else { throw MistClipboardError.nothing }
            return NSItemProvider(object: text as NSString)
        }
        let url = try source.cachedFileURL(for: item)
        guard let provider = NSItemProvider(contentsOf: url) else { throw MistClipboardError.nothing }
        if item.type == .image {
            provider.registerDataRepresentation(forTypeIdentifier: item.uti ?? UTType.png.identifier, visibility: .all) { completion in
                completion(data, nil)
                return nil
            }
        }
        return provider
    }
}
