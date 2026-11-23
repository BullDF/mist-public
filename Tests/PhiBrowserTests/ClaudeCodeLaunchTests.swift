import AppKit
import XCTest
#if !MIST_CLAUDE_CODE_HOSTLESS_TESTS
@testable import Phi
#endif

final class ClaudeCodeLaunchTests: XCTestCase {
    func testDrifterOwnsNativeToolsPluginsAndSkills() throws {
        let folder = URL(fileURLWithPath: "/owned")
        let request = DrifterLaunchRequest(prompt: "hello", config: .init(), windowId: 42)
        let args = try XCTUnwrap(request.claude(folder: folder, server: .init(command: "node")).launchArguments)
        func value(_ flag: String) throws -> String { args[try XCTUnwrap(args.firstIndex(of: flag)) + 1] }
        XCTAssertEqual(try value("--tools"), "Bash,Read,Write,Edit,Glob,Grep,NotebookEdit,AskUserQuestion,EnterPlanMode,ExitPlanMode,Monitor,TaskStop,ToolSearch,WebSearch,WebFetch,ListMcpResourcesTool,ReadMcpResourceTool,ReadMcpResourceDirTool,Artifact,ArtifactComments,ArtifactData,ArtifactCheck")
        XCTAssertEqual(try value("--disallowedTools"), "Skill")
        let settings = try JSONDecoder().decode(ClaudeCodeJSON.self, from: Data(value("--settings").utf8))
        XCTAssertEqual(settings["autoMemoryDirectory"].string, "/owned/memory")
        XCTAssertEqual(settings["enabledPlugins"], .object(["cc-plugin-plugin-authoring@builtin": .bool(false)]))
        XCTAssertEqual(settings["env"], .object(["CLAUDE_CODE_DISABLE_BUNDLED_SKILLS": .string("1"), "CLAUDE_CODE_DISABLE_ADVISOR_TOOL": .string("1"),
                                                 "CLAUDE_CODE_ARTIFACT": .string("1")]))
    }

    func testAttachmentReadersKeepFilesAndIgnoreFinderIconsAndFolders() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let data = try XCTUnwrap(makeBitmap(width: 20, height: 10).representation(using: .png, properties: [:]))
        let png = root.appendingPathComponent("image.png")
        try data.write(to: png)
        XCTAssertEqual(ClaudeCodeImageNormalizer.attachment(fileURL: png), .image(.init(data: data, mediaType: "image/png")))
        for name in ["document.pdf", "source.swift", "notes.txt"] {
            let file = root.appendingPathComponent(name)
            try Data("Example".utf8).write(to: file)
            XCTAssertEqual(ClaudeCodeImageNormalizer.attachment(fileURL: file), .file(.init(url: file)))
            let item = NSPasteboardItem()
            item.setString(file.absoluteString, forType: .fileURL)
            item.setData(data, forType: .png)
            XCTAssertEqual(ClaudeCodeImageNormalizer.attachment(item: item), .file(.init(url: file)), "Finder's icon must never become an image attachment")
        }
        XCTAssertNil(ClaudeCodeImageNormalizer.attachment(fileURL: root))
        let folderItem = NSPasteboardItem()
        folderItem.setString(root.absoluteString, forType: .fileURL)
        folderItem.setData(data, forType: .png)
        XCTAssertNil(ClaudeCodeImageNormalizer.attachment(item: folderItem))
        let package = root.appendingPathComponent("Example.app")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        XCTAssertNil(ClaudeCodeImageNormalizer.attachment(fileURL: package))
        let link = root.appendingPathComponent("link.swift")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root.appendingPathComponent("source.swift"))
        XCTAssertEqual(ClaudeCodeImageNormalizer.attachment(fileURL: link), .file(.init(url: link)))
        let folderLink = root.appendingPathComponent("folder-link")
        try FileManager.default.createSymbolicLink(at: folderLink, withDestinationURL: root)
        XCTAssertNil(ClaudeCodeImageNormalizer.attachment(fileURL: folderLink))
    }

    func testPNGJPEGAndGIFAreKept() throws {
        let bitmap = try makeBitmap(width: 32, height: 16)
        for (format, mediaType) in [(NSBitmapImageRep.FileType.png, "image/png"), (.jpeg, "image/jpeg"), (.gif, "image/gif")] {
            let data = try XCTUnwrap(bitmap.representation(using: format, properties: [:]))
            let result = try XCTUnwrap(ClaudeCodeImageNormalizer.normalize(data: data))
            XCTAssertEqual(result.data, data)
            XCTAssertEqual(result.mediaType, mediaType)
        }
    }

    func testTIFFIsConvertedToPNG() throws {
        let tiff = try XCTUnwrap(makeBitmap(width: 48, height: 24).tiffRepresentation)
        let result = try XCTUnwrap(ClaudeCodeImageNormalizer.normalize(data: tiff))
        XCTAssertEqual(result.mediaType, "image/png")
        XCTAssertEqual(result.data.prefix(8), Data([137, 80, 78, 71, 13, 10, 26, 10]))
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: result.data))
        XCTAssertEqual(bitmap.pixelsWide, 48)
        XCTAssertEqual(bitmap.pixelsHigh, 24)
    }

    func testOversizeImageDownscalesToJPEG() throws {
        let data = try XCTUnwrap(makeBitmap(width: 4000, height: 1000).representation(using: .png, properties: [:]))
        let result = try XCTUnwrap(ClaudeCodeImageNormalizer.normalize(data: data))
        XCTAssertEqual(result.mediaType, "image/jpeg")
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: result.data))
        XCTAssertEqual(bitmap.pixelsWide, 2000)
        XCTAssertEqual(bitmap.pixelsHigh, 500)
        XCTAssertLessThanOrEqual(result.data.count, ClaudeCodeImageNormalizer.maximumBytes)
    }

    func testByteLimitTriggersJPEGWithoutUpscaling() throws {
        var data = try XCTUnwrap(makeBitmap(width: 100, height: 50).representation(using: .png, properties: [:]))
        data.append(Data(count: ClaudeCodeImageNormalizer.maximumBytes))
        let result = try XCTUnwrap(ClaudeCodeImageNormalizer.normalize(data: data))
        XCTAssertEqual(result.mediaType, "image/jpeg")
        XCTAssertEqual(NSBitmapImageRep(data: result.data)?.pixelsWide, 100)
        XCTAssertLessThanOrEqual(result.data.count, ClaudeCodeImageNormalizer.maximumBytes)
    }

    func testFileAndPasteboardNormalizationAndInvalidData() throws {
        let data = try XCTUnwrap(makeBitmap(width: 20, height: 10).representation(using: .png, properties: [:]))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("png")
        try data.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertEqual(ClaudeCodeImageNormalizer.normalize(fileURL: file)?.data, data)
        let item = NSPasteboardItem()
        item.setString(file.absoluteString, forType: .fileURL)
        XCTAssertEqual(ClaudeCodeImageNormalizer.attachment(item: item), .image(.init(data: data, mediaType: "image/png")))
        let raw = NSPasteboardItem()
        raw.setData(data, forType: .png)
        XCTAssertEqual(ClaudeCodeImageNormalizer.normalize(item: raw)?.mediaType, "image/png")
        XCTAssertNil(ClaudeCodeImageNormalizer.normalize(data: Data("not an image".utf8)))
        XCTAssertNil(ClaudeCodeImageNormalizer.normalize(fileURL: URL(string: "https://example.com/image.png")!))
    }

    private func makeBitmap(width: Int, height: Int) throws -> NSBitmapImageRep {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                                   bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
                                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        memset(bitmap.bitmapData, 127, bitmap.bytesPerRow * bitmap.pixelsHigh)
        return bitmap
    }
}
