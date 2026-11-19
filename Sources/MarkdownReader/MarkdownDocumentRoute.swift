import Foundation

enum MarkdownDocumentRoute {
    static let extensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mkdn", "mdwn"]

    static func localFile(for urlString: String?) -> URL? {
        guard let urlString, let url = URL(string: urlString), url.scheme?.lowercased() == "file",
              url.host == nil || url.host == "" || url.host?.lowercased() == "localhost",
              extensions.contains(url.pathExtension.lowercased()) else { return nil }
        return URL(fileURLWithPath: url.path)
    }

    static func isRemoteCandidate(_ urlString: String?) -> Bool {
        guard let urlString, let url = URL(string: urlString),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return false }
        let path = url.path.removingPercentEncoding ?? url.path
        return extensions.contains((path as NSString).pathExtension.lowercased())
    }

    static func acceptsRemote(contentType: String) -> Bool {
        let type = contentType.components(separatedBy: ";")[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return type.hasPrefix("text/") && type != "text/html" && type != "text/xml"
    }

    static func decodedText(_ pageText: String, characterSet: String) -> String {
        guard characterSet.lowercased() == "windows-1252" else { return pageText }
        let special: [UInt32: UInt8] = [
            0x20AC: 0x80, 0x201A: 0x82, 0x0192: 0x83, 0x201E: 0x84, 0x2026: 0x85,
            0x2020: 0x86, 0x2021: 0x87, 0x02C6: 0x88, 0x2030: 0x89, 0x0160: 0x8A,
            0x2039: 0x8B, 0x0152: 0x8C, 0x017D: 0x8E, 0x2018: 0x91, 0x2019: 0x92,
            0x201C: 0x93, 0x201D: 0x94, 0x2022: 0x95, 0x2013: 0x96, 0x2014: 0x97,
            0x02DC: 0x98, 0x2122: 0x99, 0x0161: 0x9A, 0x203A: 0x9B, 0x0153: 0x9C,
            0x017E: 0x9E, 0x0178: 0x9F
        ]
        var bytes: [UInt8] = []
        for scalar in pageText.unicodeScalars {
            if let byte = special[scalar.value] { bytes.append(byte) }
            else if scalar.value <= 0xFF { bytes.append(UInt8(scalar.value)) }
            else { return pageText }
        }
        return String(bytes: bytes, encoding: .utf8) ?? pageText
    }
}
