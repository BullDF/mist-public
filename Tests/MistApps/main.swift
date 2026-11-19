import Foundation

func check(_ condition: @autoclosure () -> Bool, _ message: String) { guard condition() else { fatalError(message) } }
let apps: [(id: MistAppID, keywords: [String])] = [(.clipboard, ["paste"]), (.drifter, ["agent", "chat"]), (.mail, ["email", "inbox"])]
for (query, expected): (String, [MistAppID]) in [
    ("ma", [.mail]), (" MA ", [.mail]), ("m", []), ("dr", [.drifter]), ("ch", [.drifter]),
    ("cl", [.clipboard]), ("pa", [.clipboard]), ("em", [.mail]), ("in", [.mail]),
    ("mails", []), ("docs.google.com", []), ("rift", []), ("Mäil", [.mail]),
] { check(MistAppMatcher.matches(query, in: apps) == expected, "matcher: \(query)") }
check(MistAppMatcher.matches("ma", in: [(.clipboard, ["mast"]), (.mail, [])]) == [.mail, .clipboard], "name matches first")
let route = MistAppRoute(baseDirectory: URL(fileURLWithPath: "/Users/test/Library/Application Support/com.bulldf.mist.tests"))
let id = UUID()
check(MistAppID.allCases.map(\.name) == ["Clipboard", "Drifter", "Mail"], "names and launcher order")
for (app, instance): (MistAppID, UUID?) in MistAppID.allCases.map({ ($0, nil as UUID?) }) + [(.drifter, id)] {
    let address = MistAppAddress(app: app, instance: instance)
    for url in [route.url(app, instance: instance), route.legacyURL(app, instance: instance)].compactMap({ $0 }) {
        let string = url.absoluteString
        check(route.resolve(string) == address, "round trip \(string)")
        check(route.resolve(string.replacingOccurrences(of: "file:///", with: "file://localhost/")) == address, "localhost")
        if app == .drifter {
            check(route.resolve(string.replacingOccurrences(of: id.uuidString, with: id.uuidString.lowercased())) == address, "lowercase UUID")
        }
        let parent = url.deletingLastPathComponent().lastPathComponent + "/"
        for value in [string + "?x", string + "#x", string + "/", string.lowercased(),
                      string.replacingOccurrences(of: "file:///", with: "file://remote/"),
                      string.replacingOccurrences(of: "file:///", with: "file://user@localhost/"),
                      string.replacingOccurrences(of: "file:///", with: "file://user:pass@localhost/"),
                      string.replacingOccurrences(of: "file:///", with: "file://localhost:123/"),
                      string.replacingOccurrences(of: url.lastPathComponent, with: "Other.html"),
                      string.replacingOccurrences(of: "file:", with: "https:"),
                      string.replacingOccurrences(of: parent, with: parent + "../" + parent)] {
            check(route.resolve(value) == nil, "reject \(value)")
        }
    }
}
check(route.resolve(nil) == nil && route.resolve("") == nil, "empty URL")
check(MistAppAddress(app: .drifter, instance: id).chatId == id, "Drifter chat id")
check(route.resolve(route.url(.drifter).absoluteString)?.chatId == nil, "Drifter home is not a chat")
check(route.placeholderURL(.drifter) == route.url(.drifter), "Drifter home placeholder")
check(route.resolve(route.url(.drifter).absoluteString.replacingOccurrences(of: "MistApps/Drifter", with: "MistAgents/Chats")) == nil, "legacy chats have no home")
check(MistAppAddress(app: .mail, instance: id).chatId == nil, "only Drifter has chat ids")
let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
defer { try? FileManager.default.removeItem(at: temporary) }
let temporaryRoute = MistAppRoute(baseDirectory: temporary)
check(temporaryRoute.placeholderURL(.drifter, instance: id) == temporaryRoute.url(.drifter, instance: id), "new canonical placeholder")
let legacy = temporaryRoute.legacyURL(.drifter, instance: id)!
try FileManager.default.createDirectory(at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
try Data().write(to: legacy)
check(temporaryRoute.placeholderURL(.drifter, instance: id) == legacy, "keep existing legacy placeholder")
check(temporaryRoute.placeholderURL(.mail) == temporaryRoute.url(.mail), "single-instance canonical placeholder")
check(MistAppPlaceholder.html(title: "Drifter", background: "#fff", iconPNGBase64: nil, app: .drifter, agent: "drifter codex")
    .contains("<meta name=\"mist-app\" content=\"drifter\"><meta name=\"mist-agent\" content=\"drifter codex\">"), "adjacent app and agent metas")
let html = MistAppPlaceholder.html(title: "Mail <&\"'", background: "#123456", iconPNGBase64: "cG5n", app: .mail)
check(html.contains("<title>Mail &lt;&amp;&quot;&#39;</title>"), "escaped title")
check(html.contains("html{background:#123456}") && html.contains("<meta name=\"mist-app\" content=\"mail\">"), "theme and app marker")
check(html.contains("<link rel=\"icon\" href=\"data:image/png;base64,cG5n\">"), "embedded icon")
check(!MistAppPlaceholder.html(title: "x", background: "#fff", iconPNGBase64: nil, app: .clipboard).contains("rel=\"icon\""), "optional icon")
let catalog = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("Resources/Localizable.xcstrings")
let json = try JSONSerialization.jsonObject(with: Data(contentsOf: catalog)) as! [String: Any]
let guardedNames = MistAppID.allCases.map(\.name)
for (key, entry) in json["strings"] as! [String: [String: Any]] {
    let languages = entry["localizations"] as? [String: [String: Any]]
    let unit = languages?["en"]?["stringUnit"] as? [String: Any]
    check(!guardedNames.contains(unit?["value"] as? String ?? key), "app name must be a Swift literal: \(key)")
}
print("Mist app routes, placeholders, names and catalog checks passed")
