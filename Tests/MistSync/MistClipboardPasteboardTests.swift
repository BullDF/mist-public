import AppKit
import UniformTypeIdentifiers

@MainActor
enum MistClipboardPasteboardTests {
    static func run() async throws {
        let root = try syncTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let board = NSPasteboard(name: NSPasteboard.Name("MistClipboardTests-\(UUID())"))
        defer { board.releaseGlobally() }
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 8, bitsPerPixel: 32)!
        let png = bitmap.representation(using: .png, properties: [:])!
        let tiff = bitmap.tiffRepresentation!
        func put(_ values: [(NSPasteboard.PasteboardType, Data)]) {
            board.clearContents()
            let item = NSPasteboardItem()
            for (type, data) in values { item.setData(data, forType: type) }
            board.writeObjects([item])
        }
        func read() async throws -> MistClipboardDraft { try await MistClipboardPasteboard.read(board, directory: root) }
        put([(.png, png), (.string, Data("image description".utf8))])
        var draft = try await read()
        try expectSync(draft.type == .image && draft.data == png, "Image before text wins")
        put([(.string, Data("text first".utf8)), (.png, png)])
        draft = try await read()
        try expectSync(draft.type == .text && String(data: draft.data, encoding: .utf8) == "text first", "Text before image wins")
        put([(.tiff, tiff), (.png, png), (.string, Data("text".utf8))])
        draft = try await read()
        try expectSync(draft.uti == UTType.png.identifier && draft.data == png, "PNG is preferred among image representations")
        put([(.tiff, tiff)])
        draft = try await read()
        try expectSync(draft.type == .image && draft.uti == UTType.png.identifier && NSBitmapImageRep(data: draft.data) != nil,
                       "TIFF is converted to PNG")
        let largeBitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2_000, pixelsHigh: 2_000, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 8_000, bitsPerPixel: 32)!
        largeBitmap.bitmapData!.initialize(repeating: 0, count: 16_000_000)
        let largeTIFF = largeBitmap.representation(using: .tiff, properties: [.compressionMethod: NSBitmapImageRep.TIFFCompression.none.rawValue])!
        try expectSync(largeTIFF.count > MistClipboardSyncSource.maxSize, "TIFF fixture exceeds the wire cap before conversion")
        put([(.tiff, largeTIFF)])
        draft = try await read()
        try expectSync(draft.uti == UTType.png.identifier && draft.data.count < MistClipboardSyncSource.maxSize,
                       "Image size is checked after TIFF-to-PNG conversion")
        let file = root.appendingPathComponent("Finder.png")
        try png.write(to: file)
        put([(.png, png), (.fileURL, Data(file.absoluteString.utf8)), (.string, Data("text".utf8))])
        draft = try await read()
        try expectSync(draft.type == .file && draft.name == "Finder.png" && draft.data == png, "Finder image URL wins as a file")
        let chosen = try MistClipboardPasteboard.fileDraft(file)
        try expectSync(chosen.type == draft.type && chosen.name == draft.name && chosen.data == draft.data && chosen.uti == draft.uti,
                       "A chosen file stages like a dropped one")
        board.clearContents()
        board.writeObjects([file as NSURL, file as NSURL])
        try await expectSyncThrowsAsync("Multiple files") { _ = try await read() }
        board.clearContents()
        board.writeObjects([root as NSURL])
        try await expectSyncThrowsAsync("Folder") { _ = try await read() }
        put([(.string, Data())])
        try await expectSyncThrowsAsync("Empty text") { _ = try await read() }
        put([(.string, Data(repeating: 65, count: 10_000_001))])
        try await expectSyncThrowsAsync("Oversized text") { _ = try await read() }
        put([(.png, Data(repeating: 0, count: 10_000_001))])
        try await expectSyncThrowsAsync("Oversized image") { _ = try await read() }
        put([(.html, Data("<p>HTML only</p>".utf8))])
        try await expectSyncThrowsAsync("Unsupported content") { _ = try await read() }
        let empty = root.appendingPathComponent("empty.txt")
        try Data().write(to: empty)
        board.clearContents(); board.writeObjects([empty as NSURL])
        try await expectSyncThrowsAsync("Empty file") { _ = try await read() }
        let large = root.appendingPathComponent("large.bin")
        try Data(repeating: 0, count: 10_000_001).write(to: large)
        board.clearContents(); board.writeObjects([large as NSURL])
        try await expectSyncThrowsAsync("Oversized file") { _ = try await read() }

        var clock = Date()
        let source = MistClipboardSyncSource(directory: root.appendingPathComponent("source"), slot: { "pasteboard" },
            now: { clock }, timersEnabled: false, lifetime: 2)
        source.onChange = { _ in }
        try source.send(MistClipboardDraft(type: .text, data: Data("copied text".utf8)))
        try MistClipboardPasteboard.copy(source.current!, source: source, to: board)
        try expectSync(board.string(forType: .string) == "copied text", "Copy writes text")
        try expectSync(try MistClipboardPasteboard.drag(source.current!, source: source).hasItemConformingToTypeIdentifier(UTType.text.identifier),
                       "Text drag offers a text representation")
        try source.send(MistClipboardDraft(type: .file, data: png, name: "File.png", uti: UTType.png.identifier))
        try MistClipboardPasteboard.copy(source.current!, source: source, to: board)
        let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as! [URL]
        try expectSync(urls.count == 1 && (try Data(contentsOf: urls[0])) == png, "Copy writes a cached file URL")
        let downloads = root.appendingPathComponent("Downloads", isDirectory: true)
        let first = try source.download(source.current!, to: downloads)
        let second = try source.download(source.current!, to: downloads)
        try expectSync(first.lastPathComponent == "File.png" && (try Data(contentsOf: first)) == png,
                       "Download saves the file under its name")
        try expectSync(second.lastPathComponent == "File (1).png" && (try Data(contentsOf: second)) == png,
                       "Download numbers a taken name")
        try source.send(MistClipboardDraft(type: .image, data: png, uti: UTType.png.identifier))
        let image = source.current!
        try MistClipboardPasteboard.copy(image, source: source, to: board)
        try expectSync(board.data(forType: .png) == png && board.data(forType: .tiff) != nil, "Copy offers original image data and TIFF")
        let provider = try MistClipboardPasteboard.drag(image, source: source)
        try expectSync(provider.hasItemConformingToTypeIdentifier(UTType.png.identifier), "Image drag offers its original representation")
        try expectSync(provider.suggestedName == "Image", "Image drag names the dropped file without the extension Finder adds")
        clock = clock.addingTimeInterval(2)
        try expectSyncThrows("Expired copy") { try MistClipboardPasteboard.copy(image, source: source, to: board) }
        try expectSyncThrows("Expired drag") { _ = try MistClipboardPasteboard.drag(image, source: source) }
        print("Mist clipboard pasteboard checks passed: representation priority, Finder files, limits, copy, download, drag, and expiry")
    }
}
