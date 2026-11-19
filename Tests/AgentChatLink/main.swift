import Foundation

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}
let folder = URL(fileURLWithPath: "/Users/x/project", isDirectory: true)
func target(_ link: String, folder: URL? = folder) -> String { AgentChatLink.target(URL(string: link)!, folder: folder).absoluteString }

check(target("/Users/x/temp/notes.md") == "file:///Users/x/temp/notes.md", "absolute path")
check(target("docs/spec.md") == "file:///Users/x/project/docs/spec.md", "relative to the chat's folder")
check(target("../other/a.md") == "file:///Users/x/other/a.md", "parent folder")
check(target("Sources/a.swift#L42") == "file:///Users/x/project/Sources/a.swift#L42", "fragment kept")
check(target("my%20notes.md") == "file:///Users/x/project/my%20notes.md", "percent-encoded name")
check(target("~/a.md", folder: nil) == FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("a.md").absoluteString, "home path")
check(target("notes.md", folder: nil) == FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("notes.md").absoluteString, "no folder")
for link in ["https://example.com/a.md", "file:///a.md", "mailto:a@b.c", "#section"] {
    check(target(link) == link, "kept: \(link)")
}
print("Agent chat link tests passed")
