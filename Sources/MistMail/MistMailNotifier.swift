import AppKit
import MistMailCore
import UserNotifications

struct MailNotificationRequest: Equatable {
    var identifier: String
    var title: String
    var subtitle: String
    var body: String
    var threadIdentifier: String
    var userInfo: [String: String]
}

enum MailNotificationContent {
    static func requests(for messages: [MailMessageSummary], accounts: [MailAccount]) -> [MailNotificationRequest] {
        let unread = messages.filter { !$0.flags.contains(MailFlags.seen) }
        if unread.count <= 3 {
            return unread.map { message in
                .init(identifier: "mist.mail.message." + message.id.uuidString,
                      title: MailPresentation.addresses(message.sender),
                      subtitle: MailPresentation.subject(message.subject),
                      body: message.snippet, threadIdentifier: message.accountID.uuidString,
                      userInfo: ["messageID": message.id.uuidString])
            }
        }
        let grouped = Dictionary(grouping: unread, by: \.accountID)
        return grouped.keys.sorted { $0.uuidString < $1.uuidString }.map { accountID in
            let messages = grouped[accountID]!
            return .init(identifier: "mist.mail.summary." + accountID.uuidString + "." + messages[0].id.uuidString,
                         title: String.localizedStringWithFormat(MailStrings.newMessages, messages.count),
                         subtitle: accounts.first { $0.id == accountID }?.config.displayName ?? "",
                         body: "", threadIdentifier: accountID.uuidString, userInfo: [:])
        }
    }
}

enum MailNotificationPolicy {
    static let settingKey = "mist.mail.notifications"
    static func handles(_ identifier: String) -> Bool { identifier.hasPrefix("mist.mail.") }
    static func isEnabled(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: settingKey) == nil || defaults.bool(forKey: settingKey)
    }
}

/// Chromium installs its own delegate lazily. Keep it as a weak forwarding target
/// whenever Mail reclaims the center, rather than taking over site notifications.
@MainActor
final class MistMailNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    private weak var forwardDelegate: (any UNUserNotificationCenterDelegate)?
    private let presentation: () -> UNNotificationPresentationOptions
    private let open: (UUID?) -> Void

    init(presentation: @escaping () -> UNNotificationPresentationOptions, open: @escaping (UUID?) -> Void) {
        self.presentation = presentation; self.open = open
    }
    func install(on center: UNUserNotificationCenter) {
        guard center.delegate !== self else { return }
        forwardDelegate = center.delegate
        center.delegate = self
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                           withCompletionHandler completionHandler: @escaping @Sendable (UNNotificationPresentationOptions) -> Void) {
        Task { @MainActor in
            if MailNotificationPolicy.handles(notification.request.identifier) { completionHandler(presentation()) }
            else if let target = forwardDelegate, target.responds(to: #selector(userNotificationCenter(_:willPresent:withCompletionHandler:))) {
                target.userNotificationCenter?(center, willPresent: notification, withCompletionHandler: completionHandler)
            } else { completionHandler([.banner, .list]) }
        }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                           withCompletionHandler completionHandler: @escaping @Sendable () -> Void) {
        Task { @MainActor in
            if MailNotificationPolicy.handles(response.notification.request.identifier) {
                if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
                    let id = (response.notification.request.content.userInfo["messageID"] as? String).flatMap(UUID.init(uuidString:))
                    open(id)
                }
                completionHandler()
            } else if let target = forwardDelegate, target.responds(to: #selector(userNotificationCenter(_:didReceive:withCompletionHandler:))) {
                target.userNotificationCenter?(center, didReceive: response, withCompletionHandler: completionHandler)
            } else { completionHandler() }
        }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, openSettingsFor notification: UNNotification?) {
        Task { @MainActor in
            if let notification, MailNotificationPolicy.handles(notification.request.identifier) { return }
            forwardDelegate?.userNotificationCenter?(center, openSettingsFor: notification)
        }
    }
}

@MainActor
final class MistMailNotifier {
    private let defaults: UserDefaults
    private let center: UNUserNotificationCenter
    private let proxy: MistMailNotificationDelegate
    private var activationObserver: NSObjectProtocol?
    private var authorizationTask: Task<Bool, Never>?

    init(defaults: UserDefaults = .standard, center: UNUserNotificationCenter = .current(), open: @escaping (UUID?) -> Void) {
        self.defaults = defaults; self.center = center
        proxy = MistMailNotificationDelegate(presentation: {
            if !MailNotificationPolicy.isEnabled(in: defaults) || Self.isViewingMail() { return [] }
            return [.banner, .list, .sound]
        }, open: open)
    }
    deinit { if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) } }
    func start() {
        proxy.install(on: center)
        guard activationObserver == nil else { return }
        activationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { guard let self else { return }; self.proxy.install(on: self.center) }
        }
    }
    @discardableResult
    func requestAuthorization() async -> Bool {
        if let authorizationTask { return await authorizationTask.value }
        let task = Task { [center] in
            let settings = await center.notificationSettings()
            switch settings.authorizationStatus {
            case .authorized, .provisional: return true
            case .notDetermined: return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            default: return false
            }
        }
        authorizationTask = task
        defer { authorizationTask = nil }
        return await task.value
    }
    private var removedIdentifiers = Set<String>()

    func removeNotification(messageID: UUID) {
        let identifier = "mist.mail.message." + messageID.uuidString
        removedIdentifiers.insert(identifier)
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
    }

    func post(_ messages: [MailMessageSummary], accounts: [MailAccount]) async {
        guard MailNotificationPolicy.isEnabled(in: defaults) else { return }
        let requests = MailNotificationContent.requests(for: messages, accounts: accounts)
        guard !requests.isEmpty, await requestAuthorization() else { return }
        for request in requests {
            guard MailNotificationPolicy.isEnabled(in: defaults) else { return }
            guard !removedIdentifiers.contains(request.identifier) else { continue }
            proxy.install(on: center)
            let content = UNMutableNotificationContent()
            content.title = request.title; content.subtitle = request.subtitle; content.body = request.body
            content.threadIdentifier = request.threadIdentifier; content.userInfo = request.userInfo; content.sound = .default
            do {
                try await center.add(UNNotificationRequest(identifier: request.identifier, content: content, trigger: nil))
                if removedIdentifiers.contains(request.identifier) {
                    center.removeDeliveredNotifications(withIdentifiers: [request.identifier])
                    center.removePendingNotificationRequests(withIdentifiers: [request.identifier])
                }
            }
            catch { AppLogError("[MistMail] Could not post notification: \(error)") }
        }
    }
    private static func isViewingMail() -> Bool {
        guard NSApp.isActive, let window = NSApp.keyWindow, window.isVisible,
              let controller = SpaceSessionControllersManager.shared.findControllerWith(window: window),
              let tab = controller.browserState.focusingTab,
              let page = controller.mainSplitViewController.webContentContainerViewController.appPage(for: tab) as? MailPageViewController,
              page.isViewLoaded else { return false }
        return page.view.window === window && !page.view.isHiddenOrHasHiddenAncestor
    }
}

extension Notification.Name {
    static let mistMailRevealMessage = Notification.Name("mistMailRevealMessage")
}
