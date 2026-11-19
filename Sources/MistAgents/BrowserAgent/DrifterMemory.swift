import Foundation

struct DrifterHome: Equatable, Sendable {
    let folder: URL
    let isRepository: Bool
    var memory: URL { folder.appendingPathComponent("memory", isDirectory: true) }
    var skills: URL { folder.appendingPathComponent("skills", isDirectory: true) }

    static var current: Self {
        #if !MIST_CLAUDE_CODE_HOSTLESS_TESTS
        let appData = AgentChatRoute.current.directory.deletingLastPathComponent().deletingLastPathComponent()
        #else
        let appData = FileManager.default.temporaryDirectory.appendingPathComponent("MistHostless")
        #endif
        return (try? resolve(home: FileManager.default.homeDirectoryForCurrentUser,
            bundleId: Bundle.main.bundleIdentifier, appData: appData))
            ?? Self(folder: appData.appendingPathComponent("MistAgents/Drifter"), isRepository: false)
    }

    static func resolve(home: URL, bundleId: String?, appData: URL) throws -> Self {
        let files = FileManager.default
        // Dev and tests must not even stat the user's Drifter repository.
        if bundleId == "com.bulldf.mist" {
            let repository = home.appendingPathComponent("Personal/drifter", isDirectory: true)
            var directory: ObjCBool = false
            if files.fileExists(atPath: repository.appendingPathComponent(".git").path),
               files.fileExists(atPath: repository.appendingPathComponent("memory").path, isDirectory: &directory), directory.boolValue {
                return Self(folder: repository, isRepository: true)
            }
        }
        let result = Self(folder: appData.appendingPathComponent("MistAgents/Drifter", isDirectory: true), isRepository: false)
        try files.createDirectory(at: result.memory, withIntermediateDirectories: true)
        try files.createDirectory(at: result.skills, withIntermediateDirectories: true)
        return result
    }
}

struct DrifterMemory: Sendable {
    let home: DrifterHome
    var folder: URL { home.memory }

    func instructions(for engine: DrifterEngine) -> String {
        var text = """
        Your memory is `\(folder.path)`: one folder per topic, indexed by MEMORY.md there, grouped by topic heading. Read the index at the start of work, then the files the task needs.

        Save as you go, unasked. Don't wait to be asked: when you learn something durable, not derivable from code or history, that changes what a future session does, write it at once into the file on its topic. Create a new file only for a topic no file covers, and a new topic folder only for a subject none covers. Each file starts with YAML frontmatter: name (a slug unique across topics), description (one line), and metadata.type (user, feedback, project or reference). Add a one-line pointer under its topic heading in MEMORY.md linked as <topic>/<file>.md. Rewrite a stale line or delete a dead one instead of appending. Never record a declined suggestion or a closed question; never reference transient paths (/tmp, ~/Downloads, scratch folders).
        """
        if home.isRepository {
            text += "\n\nAfter each memory edit, commit only the files you changed and push: `git -C \(home.folder.path) add <files>`, `git -C \(home.folder.path) commit -m \"<one line>\" -- <files>`, `git -C \(home.folder.path) push`; on a rejected push, `git -C \(home.folder.path) pull --rebase` and push again. Other sessions share this repo: never `add -A` or `.`."
        }
        // Claude loads the index through autoMemoryDirectory; Codex needs one injected copy.
        if engine == .codex, let index = try? String(contentsOf: folder.appendingPathComponent("MEMORY.md"), encoding: .utf8),
           !index.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            text += "\n\nYour memory index (MEMORY.md):\n" + index
        }
        return text
    }

    func allowsFileChanges(_ paths: [String], cwd: URL) -> Bool {
        BrowserAgentFileAccess.allowsFileChanges(paths, inside: folder, cwd: cwd)
    }
}

enum BrowserAgentFileAccess {
    static func allowsFileChanges(_ paths: [String], inside folder: URL, cwd: URL) -> Bool {
        guard let components = canonicalURL(folder)?.pathComponents else { return false }
        return !paths.isEmpty && paths.allSatisfy { path in
            guard !path.isEmpty else { return false }
            let url = (path as NSString).isAbsolutePath ? URL(fileURLWithPath: path) : cwd.appendingPathComponent(path)
            guard let resolved = Self.canonicalURL(url) else { return false }
            return resolved.pathComponents.starts(with: components)
        }
    }

    // URL.resolvingSymlinksInPath leaves symlinks unresolved when the final file
    // doesn't exist yet. Resolve each component so new files are checked too.
    static func canonicalURL(_ url: URL, links: Int = 0) -> URL? {
        guard links < 40 else { return nil }
        var result = URL(fileURLWithPath: "/", isDirectory: true)
        for component in url.pathComponents.dropFirst() {
            if component == "." { continue }
            if component == ".." { result.deleteLastPathComponent(); continue }
            let next = result.appendingPathComponent(component)
            if let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: next.path) {
                let target = (destination as NSString).isAbsolutePath ? URL(fileURLWithPath: destination) : result.appendingPathComponent(destination)
                guard let resolved = canonicalURL(target, links: links + 1) else { return nil }
                result = resolved
            } else { result = next }
        }
        return result.standardizedFileURL
    }
}

