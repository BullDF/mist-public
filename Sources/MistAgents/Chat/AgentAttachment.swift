import Foundation
import CryptoKit

extension CodingUserInfoKey {
    static let agentChatImages = CodingUserInfoKey(rawValue: "agentChatImages")!
    static let agentChatAttachments = CodingUserInfoKey(rawValue: "agentChatAttachments")!
}

struct AgentFileAttachment: Codable, Equatable, Sendable {
    let url: URL

    init(url: URL) { self.url = url }
    private enum CodingKeys: String, CodingKey { case file }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let file = try values.decode(String.self, forKey: .file)
        guard let folder = decoder.userInfo[.agentChatAttachments] as? URL,
              !file.isEmpty, file == (file as NSString).lastPathComponent, file != ".", file != ".." else {
            throw DecodingError.dataCorruptedError(forKey: .file, in: values, debugDescription: "Missing attachments folder or invalid filename")
        }
        url = folder.appendingPathComponent(file)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(url.lastPathComponent, forKey: .file)
    }
}

enum AgentAttachment: Equatable, Sendable {
    case image(AgentImageAttachment)
    case file(AgentFileAttachment)
}

struct AgentAttachmentError: LocalizedError {
    let name: String
    var errorDescription: String? { AgentChatStrings.attachmentFailed(name) }
}

extension Array where Element == AgentAttachment {
    var images: [AgentImageAttachment] { compactMap { if case let .image(image) = $0 { return image }; return nil } }
    var files: [AgentFileAttachment] { compactMap { if case let .file(file) = $0 { return file }; return nil } }

    func cappingImages(at limit: Int) -> Self {
        var count = 0
        return filter {
            if case .image = $0 { count += 1; return count <= limit }
            return true
        }
    }

    func agentText(_ text: String) -> String {
        guard !files.isEmpty else { return text }
        return (text.isEmpty ? "" : text + "\n\n") + "Files the user attached:\n" + files.map { $0.url.path }.joined(separator: "\n")
    }

    func imported(into folder: URL) throws -> Self {
        try map { attachment in
            guard case let .file(file) = attachment else { return attachment }
            if file.url.deletingLastPathComponent().standardizedFileURL.path == folder.standardizedFileURL.path { return attachment }
            do {
                let source = file.url.resolvingSymlinksInPath()
                let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isPackageKey])
                guard values.isRegularFile == true, values.isPackage != true else { throw AgentAttachmentError(name: file.url.lastPathComponent) }
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let name = file.url.lastPathComponent
                let ext = file.url.pathExtension
                let stem = ext.isEmpty ? name : file.url.deletingPathExtension().lastPathComponent
                var target = folder.appendingPathComponent(name), suffix = 2
                while FileManager.default.fileExists(atPath: target.path) {
                    target = folder.appendingPathComponent(stem + " \(suffix)" + (ext.isEmpty ? "" : "." + ext))
                    suffix += 1
                }
                try FileManager.default.copyItem(at: source, to: target)
                return .file(.init(url: target))
            } catch { throw AgentAttachmentError(name: file.url.lastPathComponent) }
        }
    }
}

struct AgentImageAttachment: Codable, Equatable, Sendable {
    let data: Data
    let mediaType: String

    init(data: Data, mediaType: String) { self.data = data; self.mediaType = mediaType }

    private enum CodingKeys: String, CodingKey { case mediaType, file }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        mediaType = try values.decode(String.self, forKey: .mediaType)
        let file = try values.decode(String.self, forKey: .file)
        guard let folder = decoder.userInfo[.agentChatImages] as? URL,
              !file.isEmpty, file == (file as NSString).lastPathComponent, file != ".", file != ".." else {
            throw DecodingError.dataCorruptedError(forKey: .file, in: values, debugDescription: "Missing images folder or invalid image filename")
        }
        data = (try? Data(contentsOf: folder.appendingPathComponent(file))) ?? Data()
    }

    func encode(to encoder: Encoder) throws {
        guard let folder = encoder.userInfo[.agentChatImages] as? URL else {
            throw EncodingError.invalidValue(self, .init(codingPath: encoder.codingPath, debugDescription: "Missing images folder"))
        }
        let file = try write(to: folder)
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(mediaType, forKey: .mediaType)
        try values.encode(file.lastPathComponent, forKey: .file)
    }

    /// Transcript records and image previews share one content-addressed file.
    func write(to folder: URL) throws -> URL {
        let ext: String
        switch mediaType {
        case "image/jpeg": ext = "jpg"
        case "image/gif": ext = "gif"
        case "image/webp": ext = "webp"
        default: ext = "png"
        }
        let name = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let file = folder.appendingPathComponent(name + "." + ext)
        if !FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
        }
        return file
    }
}
