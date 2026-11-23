import AppKit
import UserNotifications

enum DrifterNotifier {
    private static let prefix = "mist.drifter."

    static func handles(_ identifier: String) -> Bool { identifier.hasPrefix(prefix) }

    @MainActor
    static func post(chat id: UUID, title: String, message: String) async throws -> Bool {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = message
        content.threadIdentifier = id.uuidString
        content.sound = .default
        let request = UNNotificationRequest(identifier: prefix + UUID().uuidString, content: content, trigger: nil)
        return try await MistMailService.shared.postNotification(request)
    }

    @MainActor
    static func openChat(_ id: UUID) {
        let store = AgentChatStore.shared
        NSApp.activate()
        for controller in SpaceSessionControllersManager.shared.getAllWindows()
            where controller.browserType == .normal && !controller.browserState.isIncognito {
            if let tab = controller.browserState.tabs.first(where: { store.route.conversationId(for: $0.url) == id }) {
                controller.selectTab(tab)
                return
            }
        }
        AppController.shared?.application(NSApp, open: [store.route.placeholderURL(for: id)])
    }
}
