import AppKit
import Combine
import Foundation

struct DrifterSkill: Equatable, Sendable {
    let name: String
    let description: String
    let argumentHint: String
    let file: URL

    var command: ClaudeCodeSlashCommand {
        .init(name: name, description: description, argumentHint: argumentHint, isSkill: true)
    }

    var listLine: String { "- `\(name)`: \(description) (`\(file.path)`)" }

    static func parse(_ text: String, name: String, file: URL) -> Self? {
        guard name.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$", options: .regularExpression) == name.startIndex..<name.endIndex else { return nil }
        var text = text.replacingOccurrences(of: "\r\n", with: "\n")
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        let lines = text.components(separatedBy: "\n")
        guard lines.first == "---", let end = lines.indices.dropFirst().first(where: { lines[$0] == "---" || lines[$0] == "..." }) else { return nil }
        var fields: [String: String] = [:]
        var index = 1
        while index < end {
            let line = lines[index]
            index += 1
            guard let first = line.first, !first.isWhitespace, first != "#", let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let raw = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            var continuation: [String] = []
            while index < end, lines[index].isEmpty || lines[index].first?.isWhitespace == true {
                continuation.append(lines[index])
                index += 1
            }
            let value: String?
            if ["|", "|-", ">", ">-"].contains(raw) {
                while continuation.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { continuation.removeLast() }
                let indentation = continuation.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                    .map { $0.prefix(while: \.isWhitespace).count }.min() ?? 0
                let body = continuation.map { String($0.dropFirst(min(indentation, $0.count))) }
                    .joined(separator: raw.hasPrefix("|") ? "\n" : " ")
                value = body + (!body.isEmpty && !raw.hasSuffix("-") ? "\n" : "")
            } else if raw.hasPrefix("\"") {
                value = doubleQuoted(raw)
            } else if raw.hasPrefix("'") {
                value = singleQuoted(raw)
            } else {
                value = ([raw] + continuation).map { plainValue($0.trimmingCharacters(in: .whitespaces)) }
                    .joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let value { fields[key] = value }
        }
        let description = (fields["description"] ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !description.isEmpty else { return nil }
        return .init(name: name, description: description, argumentHint: fields["argument-hint"] ?? "", file: file)
    }

    private static func plainValue(_ text: String) -> String {
        guard let comment = text.indices.first(where: {
            text[$0] == "#" && ($0 == text.startIndex || text[text.index(before: $0)].isWhitespace)
        }) else { return text }
        return String(text[..<comment]).trimmingCharacters(in: .whitespaces)
    }

    private static func doubleQuoted(_ raw: String) -> String? {
        var value = "", escaped = false
        for index in raw.indices.dropFirst() {
            let character = raw[index]
            if escaped {
                switch character {
                case "\"": value.append("\"")
                case "\\": value.append("\\")
                case "n": value.append("\n")
                case "t": value.append("\t")
                default: return nil
                }
                escaped = false
            } else if character == "\\" { escaped = true }
            else if character == "\"" {
                let tail = raw[raw.index(after: index)...].trimmingCharacters(in: .whitespaces)
                return tail.isEmpty || tail.hasPrefix("#") ? value : nil
            } else { value.append(character) }
        }
        return nil
    }

    private static func singleQuoted(_ raw: String) -> String? {
        var value = ""
        var index = raw.index(after: raw.startIndex)
        while index < raw.endIndex {
            let next = raw.index(after: index)
            if raw[index] == "'" {
                if next < raw.endIndex, raw[next] == "'" {
                    value.append("'")
                    index = raw.index(after: next)
                    continue
                }
                let tail = raw[next...].trimmingCharacters(in: .whitespaces)
                return tail.isEmpty || tail.hasPrefix("#") ? value : nil
            }
            value.append(raw[index])
            index = next
        }
        return nil
    }
}

struct DrifterSkills: Sendable {
    let folder: URL
    var repository: URL? = nil
    var repoFolders: [URL] = []

    func scan() -> [DrifterSkill] {
        var seen = Set<String>()
        return (repoFolders + [folder]).flatMap { scan(folder: $0) }.filter { seen.insert($0.name).inserted }
    }

    private func scan(folder: URL) -> [DrifterSkill] {
        let files = FileManager.default
        let children = (try? files.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        return children.compactMap { child -> DrifterSkill? in
            var directory: ObjCBool = false
            guard !child.lastPathComponent.hasPrefix("."),
                  files.fileExists(atPath: child.path, isDirectory: &directory), directory.boolValue else { return nil }
            let file = child.appendingPathComponent("SKILL.md")
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
            return DrifterSkill.parse(text, name: child.lastPathComponent, file: file)
        }.sorted {
            let order = $0.name.compare($1.name, options: .caseInsensitive)
            return order == .orderedSame ? $0.name < $1.name : order == .orderedAscending
        }
    }

    func instructions() -> String {
        let skills = scan()
        let list = skills.isEmpty ? "No skills are saved yet." : "Available skills:\n" + skills.map(\.listLine).joined(separator: "\n")
        var text = """
        Skills are saved instructions for recurring tasks. They live in `\(folder.path)`, one folder per skill holding a SKILL.md. When a request matches a skill's description, read that SKILL.md with your file tools before acting, and follow it. A user message naming `/<skill-name>` invokes that skill.

        \(list)

        You may create and edit skills there. Create one when the user asks you to save a skill, and update one when the user corrects how its task should be done. Save each skill as `\(folder.path)/<name>/SKILL.md`, where `<name>` uses lowercase letters, digits and hyphens. The file starts with YAML frontmatter holding `name` (the folder's name) and `description` (one line: what the skill does and when to use it), each a double-quoted string, followed by the instructions in Markdown. Write nothing else in that folder.
        """
        text += "\n\nSkills in a repo's .claude/skills work the same way; edit them only when the user asks."
        if let repository {
            text += "\n\nCommit and push skill edits like memory edits in `\(repository.path)`, staging only the files you changed. Each SKILL.md change must bump its version: in the same commit."
        }
        return text
    }

    func allowsFileChanges(_ paths: [String], cwd: URL) -> Bool {
        BrowserAgentFileAccess.allowsFileChanges(paths, inside: folder, cwd: cwd)
    }

    func agentText(_ text: String) -> String {
        var announced: [DrifterSkill]?
        return agentText(text, announced: &announced)
    }

    /// `announced` is the list the session's agent was last given (its launch instructions, then each change
    /// note): a message after the folders change carries the difference, and `announced` becomes the current list.
    /// Nil records nothing to compare with.
    func agentText(_ text: String, announced: inout [DrifterSkill]?) -> String {
        let skills = scan()
        let change = announced.flatMap { Self.changeNote(from: $0, to: skills) }
        if announced != nil { announced = skills }
        let available = Dictionary(uniqueKeysWithValues: skills.map { ($0.name, $0) })
        var seen = Set<String>()
        let pointers = ClaudeCodeSlashTokenizer.tokens(in: text).compactMap { token -> String? in
            guard let skill = available[token.name], seen.insert(skill.name).inserted else { return nil }
            return "[Mist: this message invokes the skill `\(skill.name)`. Read `\(skill.file.path)` and follow it, using the rest of the message as its input.]"
        }
        let notes = (change.map { [$0] } ?? []) + pointers
        return notes.isEmpty ? text : notes.joined(separator: "\n") + "\n\n" + text
    }

    static func changeNote(from old: [DrifterSkill], to new: [DrifterSkill]) -> String? {
        let before = Dictionary(old.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        let names = Set(new.map(\.name))
        let added = new.filter { before[$0.name] == nil }
        let changed = new.filter { skill in
            before[skill.name].map { $0.description != skill.description || $0.file != skill.file } ?? false
        }
        let removed = old.filter { !names.contains($0.name) }
        guard !added.isEmpty || !changed.isEmpty || !removed.isEmpty else { return nil }
        var lines = ["[Mist: your skills changed since they were last listed."]
        if !added.isEmpty { lines += ["New:"] + added.map(\.listLine) }
        if !changed.isEmpty { lines += ["Changed:"] + changed.map(\.listLine) }
        if !removed.isEmpty { lines.append("Removed: " + removed.map { "`\($0.name)`" }.joined(separator: ", ") + ".") }
        lines[lines.count - 1] += "]"
        return lines.joined(separator: "\n")
    }
}

@MainActor
final class DrifterSkillCatalog: ObservableObject {
    #if !MIST_CLAUDE_CODE_HOSTLESS_TESTS
    static let shared: DrifterSkillCatalog = {
        return .init(folder: DrifterHome.current.skills)
    }()
    #endif
    @Published private(set) var skills: [DrifterSkill] = []
    var commands: [ClaudeCodeSlashCommand] { skills.map(\.command) }
    let folder: URL
    var repoFolders: [URL] = []
    private var activation: AnyCancellable?
    private var generation = 0

    init(folder: URL) {
        self.folder = folder
        activation = NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .receive(on: DispatchQueue.main).sink { [weak self] _ in
                Task { await self?.refresh() }
            }
    }

    func refresh() async {
        generation += 1
        let generation = generation, folder = folder, repoFolders = repoFolders
        let result = await Task.detached(priority: .utility) { DrifterSkills(folder: folder, repoFolders: repoFolders).scan() }.value
        guard generation == self.generation, result != skills else { return }
        skills = result
    }
}

/// Per-chat cache; filesystem traversal never runs on the main actor.
actor DrifterRepoSkills {
    private var roots: [String: URL] = [:]

    static func skillFolder(for path: String, cwd: URL, home: URL) -> URL? {
        repositoryRoot(for: path, cwd: cwd, home: home).flatMap(skillFolder(in:))
    }

    private static func skillFolder(in root: URL) -> URL? {
        let skills = root.appendingPathComponent(".claude/skills", isDirectory: true)
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: skills.path, isDirectory: &directory), directory.boolValue else { return nil }
        return BrowserAgentFileAccess.canonicalURL(skills)
    }

    private static func repositoryRoot(for path: String, cwd: URL, home: URL) -> URL? {
        let expanded = (path as NSString).expandingTildeInPath
        let url = expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : cwd.appendingPathComponent(expanded)
        guard var directory = BrowserAgentFileAccess.canonicalURL(url),
              let home = BrowserAgentFileAccess.canonicalURL(home) else { return nil }
        while directory.path != "/" {
            if directory == home { return nil }
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git").path) {
                return directory
            }
            directory.deleteLastPathComponent()
        }
        return nil
    }

    func detect(_ paths: [String], cwd: URL, home: URL) -> [URL] {
        var result: [URL] = []
        for path in paths {
            let key = cwd.path + "/" + path
            guard let root = roots[key] ?? Self.repositoryRoot(for: path, cwd: cwd, home: home) else { continue }
            roots[key] = root
            if let folder = Self.skillFolder(in: root) { result.append(folder) }
        }
        return result
    }
}
