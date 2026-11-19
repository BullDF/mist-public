import Foundation

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}
let route = MarkdownDocumentRoute.self
check(TextFind.ranges(of: "cafe", in: "CAFÉ cafe") == [NSRange(location: 0, length: 4), NSRange(location: 5, length: 4)], "case and accents")
check(TextFind.ranges(of: "aa", in: "aaaa") == [NSRange(location: 0, length: 2), NSRange(location: 2, length: 2)], "adjacent")
check(TextFind.ranges(of: "long", in: "a").isEmpty && TextFind.ranges(of: "", in: "a").isEmpty, "empty or long")
check(TextFind.ranges(of: "a", in: "😀a") == [NSRange(location: 2, length: 1)], "UTF-16")
let matches = [NSRange(location: 2, length: 1), NSRange(location: 8, length: 1)]
check(TextFind.current(in: matches, at: 3) == 1 && TextFind.current(in: matches, at: 9) == 0, "current")
check(TextFind.step(1, count: 2, forward: true) == 0 && TextFind.step(0, count: 2, forward: false) == 1, "wrap")
check(MarkdownReaderZoom.step(1, up: true) == 1.1 && MarkdownReaderZoom.step(1, up: false) == 0.9, "zoom")
check(MarkdownReaderZoom.step(0.25, up: false) == 0.25 && MarkdownReaderZoom.step(5, up: true) == 5, "zoom clamps")
check(MarkdownReaderZoom.step(1.2, up: true) == 1.25 && MarkdownReaderZoom.step(1.2, up: false) == 1.1, "zoom between")
for value in ["file:///Users/x/README.md", "file:///a.MARKDOWN", "file:///a%20b.md#part", "file://localhost/a.md"] {
    check(route.localFile(for: value) != nil, value)
}
check(route.localFile(for: "file:///a%20b.md#part")?.path == "/a b.md", "decoded local path")
for value in ["file:///a.txt", "file://remote/a.md", "https://example.com/a.md"] { check(route.localFile(for: value) == nil, value) }
for value in ["https://raw.githubusercontent.com/u/r/main/README.md", "https://x-apidata.googleusercontent.com/download/storage/v1/b/b/o/docs%2FREADME.md?jk=x&authuser=0", "https://github.com/u/r/blob/main/README.md", "http://localhost:8000/a.md"] { check(route.isRemoteCandidate(value), value) }
for value in ["https://example.com/page", "ftp://h/a.md", "file:///a.md"] { check(!route.isRemoteCandidate(value), value) }
for value in ["text/markdown", "text/x-markdown", "text/plain", "TEXT/PLAIN; charset=utf-8"] { check(route.acceptsRemote(contentType: value), value) }
for value in ["text/html", "text/xml", "application/json", "application/octet-stream"] { check(!route.acceptsRemote(contentType: value), value) }
let mapping: [UInt32] = [0x20ac, 0x81, 0x201a, 0x192, 0x201e, 0x2026, 0x2020, 0x2021, 0x2c6, 0x2030, 0x160, 0x2039, 0x152, 0x8d, 0x17d, 0x8f, 0x90, 0x2018, 0x2019, 0x201c, 0x201d, 0x2022, 0x2013, 0x2014, 0x2dc, 0x2122, 0x161, 0x203a, 0x153, 0x9d, 0x17e, 0x178]
func mojibake(_ text: String) -> String { String(String.UnicodeScalarView(text.utf8.map { UnicodeScalar((0x80...0x9f).contains($0) ? mapping[Int($0) - 0x80] : UInt32($0))! })) }
check(route.decodedText("â€”", characterSet: "windows-1252") == "—", "em dash")
let original = "├── café — ok"
check(route.decodedText(mojibake(original), characterSet: "windows-1252") == original, "mojibake")
for value in ["ASCII", "café", "日本", "\u{81}"] { check(route.decodedText(value, characterSet: "windows-1252") == value, value) }
check(route.decodedText(mojibake("\u{81}"), characterSet: "windows-1252") == "\u{81}", "undefined byte")
check(route.decodedText("â€”", characterSet: "UTF-8") == "â€”", "UTF-8")
let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: directory) }
let file = directory.appendingPathComponent("a.md")
try Data("initial".utf8).write(to: file)
var seen: [String] = []
let watcher = MarkdownFileWatcher(url: file) { seen.append($0) }
func waitFor(_ value: String) {
    let deadline = Date().addingTimeInterval(2)
    while !seen.contains(value) && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    check(seen.contains(value), "watcher: \(value), got \(seen)")
}
waitFor("initial")
let handle = try FileHandle(forWritingTo: file)
try handle.seekToEnd()
try handle.write(contentsOf: Data(" append".utf8))
try handle.close()
waitFor("initial append")
let replacement = directory.appendingPathComponent("replacement")
try Data("replaced".utf8).write(to: replacement)
check(rename(replacement.path, file.path) == 0, "rename")
waitFor("replaced")
watcher.cancel()
print("Markdown reader tests passed")
