import Foundation

/// The agent's own files a transcript names by purpose: memory writes and reads, and reads of a skill's SKILL.md.
struct AgentMemoryFiles: Equatable {
    static let none = AgentMemoryFiles(folders: [])
    private let roots: Set<String>
    private let skillRoots: Set<String>

    init(folders: [URL], skillFolders: [URL] = []) {
        roots = Self.roots(folders)
        skillRoots = Self.roots(skillFolders)
    }

    private static func roots(_ folders: [URL]) -> Set<String> {
        Set(folders.flatMap { folder in
            [folder.standardizedFileURL.path, folder.resolvingSymlinksInPath().standardizedFileURL.path]
        }.map { path in
            path == "/" ? path : String(path.reversed().drop(while: { $0 == "/" }).reversed())
        })
    }

    func contains(_ tool: AgentChatItem.ToolCall, cwd: URL) -> Bool {
        guard !roots.isEmpty, ["Write", "Edit", "MultiEdit"].contains(tool.name) else { return false }
        return contains(tool, cwd: cwd, input: try? JSONDecoder().decode(ClaudeCodeJSON.self, from: Data(tool.inputJSON.utf8)))
    }

    func contains(_ tool: AgentChatItem.ToolCall, cwd: URL, input: ClaudeCodeJSON?) -> Bool {
        guard !roots.isEmpty, ["Write", "Edit", "MultiEdit"].contains(tool.name), let input else { return false }
        return isMemoryFile(input["file_path"].string, cwd: cwd)
    }

    /// Whether the tool reads memory files: Claude's Read, or a Codex command whose every action reads one.
    func readsMemory(_ tool: AgentChatItem.ToolCall, cwd: URL) -> Bool {
        !roots.isEmpty && reads(tool, cwd: cwd, where: isMemoryFile)
    }

    /// Whether the tool reads a skill's instructions: Claude's Read, or a Codex command whose every action
    /// reads a `<skills>/<name>/SKILL.md`.
    func readsSkill(_ tool: AgentChatItem.ToolCall, cwd: URL) -> Bool {
        !skillRoots.isEmpty && reads(tool, cwd: cwd, where: isSkillFile)
    }

    /// Codex's relative read paths resolve against the command's own folder.
    private func reads(_ tool: AgentChatItem.ToolCall, cwd: URL, where matches: (String?, URL) -> Bool) -> Bool {
        guard ["Read", "Bash"].contains(tool.name),
              let input = try? JSONDecoder().decode(ClaudeCodeJSON.self, from: Data(tool.inputJSON.utf8)) else { return false }
        if tool.name == "Read" { return matches(input["file_path"].string, cwd) }
        let actions = tool.structuredResult["commandActions"].array
        let folder = input["cwd"].string.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? cwd
        return !actions.isEmpty && actions.allSatisfy { $0["type"].string == "read" && matches($0["path"].string, folder) }
    }

    private func isMemoryFile(_ file: String?, cwd: URL) -> Bool {
        guard let file, !file.isEmpty else { return false }
        let path = Self.path(file, cwd: cwd)
        return roots.contains { root in path == root || path.hasPrefix(root == "/" ? root : root + "/") }
    }

    private func isSkillFile(_ file: String?, cwd: URL) -> Bool {
        guard let file, !file.isEmpty else { return false }
        let url = URL(fileURLWithPath: Self.path(file, cwd: cwd))
        return url.lastPathComponent == "SKILL.md" && skillRoots.contains(url.deletingLastPathComponent().deletingLastPathComponent().path)
    }

    private static func path(_ file: String, cwd: URL) -> String {
        let expanded = (file as NSString).expandingTildeInPath
        let url = expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : cwd.appendingPathComponent(expanded)
        return url.standardizedFileURL.path
    }
}
