import AppKit
import XCTest
@testable import Phi

@MainActor
final class DrifterAppTests: XCTestCase {
    func testBrowserChatHasBrowserNameAndNoFolder() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var binding: Int?
        let store = AgentChatStore(route: .init(baseDirectory: directory), tabExists: { _ in true },
            browserSessionFactory: { request, _, folder in
                binding = request.windowId
                XCTAssertEqual(folder.lastPathComponent, "Drifter")
                return NSObject()
            })
        defer { store.terminate() }
        let chat = try store.create(request: DrifterLaunchRequest(prompt: "Compare tabs", config: .init(engine: .codex), windowId: 42), tabId: 1)
        XCTAssertEqual(binding, 42)
        let app = DrifterApp(store: store)
        XCTAssertEqual(app.icon(chat.id), MistAppIcon(asset: "agent-openai", isTemplate: true, scale: 8.0 / 7.0))
        let address = MistAppAddressDisplay(icon: app.addressIcon(chat.id), name: app.id.name, title: app.addressTitle(chat.id))
        let text = address.attributedString(primary: .labelColor, separator: .separatorColor).string
        XCTAssertTrue(text.contains("Drifter"))
        XCTAssertTrue(text.contains("Compare tabs"))
        XCTAssertFalse(text.contains(" · "))
    }

    func testStoreTitleAndFolderReplaceFileURL() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AgentChatStore(route: .init(baseDirectory: directory), tabExists: { _ in true }, browserSessionFactory: { _, _, _ in NSObject() })
        defer { store.terminate() }
        let chat = try store.create(request: .init(prompt: "Build a tool", attachments: [], config: .init(folder: directory), windowId: 1), tabId: 1)
        let app = DrifterApp(store: store)
        XCTAssertEqual(app.title(chat.id), "Build a tool")
        let address = MistAppAddressDisplay(icon: app.addressIcon(chat.id), name: app.id.name, title: app.addressTitle(chat.id))
        let attributed = address.attributedString(primary: .labelColor, separator: .separatorColor)
        XCTAssertTrue(attributed.string.contains("Drifter"))
        XCTAssertTrue(attributed.string.contains("Build a tool"))
        XCTAssertFalse(attributed.string.contains(directory.path))
        var attachments = 0
        attributed.enumerateAttribute(.attachment, in: NSRange(location: 0, length: attributed.length)) { value, _, _ in
            if value != nil { attachments += 1 }
        }
        XCTAssertEqual(attachments, 2)
        chat.title = "Renamed"
        XCTAssertEqual(app.title(chat.id), "Renamed")
        XCTAssertEqual(app.title(UUID()), MistAppID.drifter.name)
        XCTAssertNil(app.addressTitle(UUID()))
    }

    func testWebAddressBarNeverDisplaysChatPathAndTracksTitle() async throws {
        let id = UUID()
        let url = AgentChatRoute.current.placeholderURL(for: id)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try AgentChatRoute.html(title: "Restored chat", background: "#fff", engine: .claude).write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let tab = Tab(url: url.absoluteString, isActive: false, index: 0)
        let model = WebContentAddressBarViewModel(browserState: nil, currentTab: tab)
        XCTAssertEqual(model.appDisplay?.title, "Restored chat")
        XCTAssertEqual(model.displayText, "")
        try AgentChatRoute.html(title: "New title", background: "#fff", engine: .claude).write(to: url, atomically: true, encoding: .utf8)
        tab.title = "New title"
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(model.appDisplay?.title, "New title")
        XCTAssertEqual(model.displayText, "")
        tab.url = "https://example.com"
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertNil(model.appDisplay)
        XCTAssertFalse(model.displayText.isEmpty)
    }
}
