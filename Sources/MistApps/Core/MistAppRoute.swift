import Foundation

struct MistAppRoute {
    private let baseDirectory: URL

    init(baseDirectory: URL) { self.baseDirectory = baseDirectory.standardizedFileURL }

    func placeholderURL(_ app: MistAppID, instance: UUID? = nil) -> URL {
        if app.hasInstances, let legacy = legacyURL(app, instance: instance),
           FileManager.default.fileExists(atPath: legacy.path) { return legacy }
        return url(app, instance: instance)
    }

    func url(_ app: MistAppID, instance: UUID? = nil) -> URL {
        let directory = baseDirectory.appendingPathComponent("MistApps/" + app.name, isDirectory: true)
        precondition(instance == nil || app.hasInstances, "This app has no instances")
        if let instance {
            return directory.appendingPathComponent(instance.uuidString + ".html")
        }
        return directory.appendingPathComponent("index.html")
    }

    func legacyURL(_ app: MistAppID, instance: UUID? = nil) -> URL? {
        switch app {
        case .clipboard: return nil
        case .mail: return baseDirectory.appendingPathComponent("MistMail/Mail.html")
        case .drifter:
            guard let instance else { return nil }
            return baseDirectory.appendingPathComponent("MistAgents/Chats/" + instance.uuidString + ".html")
        }
    }

    func resolve(_ string: String?) -> MistAppAddress? {
        guard let string, let candidate = URL(string: string), candidate.isFileURL,
              !candidate.hasDirectoryPath,
              candidate.host == nil || candidate.host == "" || candidate.host == "localhost",
              candidate.user == nil, candidate.password == nil, candidate.port == nil,
              candidate.query == nil, candidate.fragment == nil,
              candidate.path == candidate.standardizedFileURL.path else { return nil }
        for app in MistAppID.allCases {
            if candidate.path == url(app).path || candidate.path == legacyURL(app)?.path {
                return MistAppAddress(app: app, instance: nil)
            }
            if app.hasInstances, candidate.pathExtension == "html",
                      let id = UUID(uuidString: candidate.deletingPathExtension().lastPathComponent),
                      candidate.lastPathComponent.lowercased() == id.uuidString.lowercased() + ".html" {
                for expected in [url(app, instance: id), legacyURL(app, instance: id)].compactMap({ $0 }) {
                    if candidate.deletingLastPathComponent().path == expected.deletingLastPathComponent().path {
                        return MistAppAddress(app: app, instance: id)
                    }
                }
            }
        }
        return nil
    }
}
