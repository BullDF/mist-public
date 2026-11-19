import Combine
import Foundation
import MistMailCore

struct MistMailCode: Identifiable, Equatable {
    let messageID: UUID
    let code: String
    let sender: String
    let senderDomain: String
    let date: Date
    var id: UUID { messageID }
}

@MainActor
final class MistMailCodeSource {
    static let shared = MistMailCodeSource(source: EngineMailPageDataSource(engine: MistMailService.shared.engine))
    private let source: any MailPageDataSource
    private let clock: () -> Date
    private struct Cached {
        let code: String?
        let date: Date
    }
    private var cache: [UUID: Cached] = [:]
    private(set) var hasAccounts = false
    var newMail: AnyPublisher<Void, Never> {
        MistMailService.shared.newMessages.map { _ in () }.eraseToAnyPublisher()
    }

    init(source: any MailPageDataSource, clock: @escaping () -> Date = Date.init) {
        self.source = source
        self.clock = clock
    }

    /// `date` is the sender's Date header, so a sender clock running a little ahead still counts.
    nonisolated static func isRecent(_ date: Date, now: Date) -> Bool {
        (-300...600).contains(now.timeIntervalSince(date))
    }

    nonisolated static func rank(_ codes: [MistMailCode], pageDomain: String,
                                 domain: (String) -> String) -> [MistMailCode] {
        codes.sorted {
            let left = !pageDomain.isEmpty && domain("https://" + $0.senderDomain) == pageDomain
            let right = !pageDomain.isEmpty && domain("https://" + $1.senderDomain) == pageDomain
            if left != right { return left }
            if $0.date != $1.date { return $0.date > $1.date }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    nonisolated static func filter(_ codes: [MistMailCode], now: Date, expectedLength: Int,
                                   pageDomain: String, domain: (String) -> String) -> [MistMailCode] {
        Array(rank(codes.filter {
            isRecent($0.date, now: now) && (!(4...8).contains(expectedLength) || $0.code.count == expectedLength)
        }, pageDomain: pageDomain, domain: domain).prefix(3))
    }

    func candidates(pageDomain: String, expectedLength: Int) async -> [MistMailCode] {
        do {
            let snapshot = try await source.snapshot()
            hasAccounts = !snapshot.accounts.isEmpty
            guard hasAccounts else { cache.removeAll(); return [] }
            let messages = try await source.messages(in: .unifiedRole(.inbox), before: nil, limit: 20)
            let recent = messages.filter { Self.isRecent($0.date, now: clock()) }
            cache = cache.filter { Self.isRecent($0.value.date, now: clock()) }
            var codes: [MistMailCode] = []
            for message in recent {
                if cache[message.id] == nil {
                    // A body that fails to load is retried on the next focus, without hiding other codes.
                    guard let detail = try? await source.detail(message.id) else { continue }
                    let body = detail.plainText ?? detail.html.map(MailText.readable) ?? ""
                    cache[message.id] = Cached(code: MailVerificationCode.extract(subject: message.subject, body: body), date: message.date)
                }
                guard let code = cache[message.id]?.code, let sender = message.sender.first else { continue }
                codes.append(MistMailCode(messageID: message.id, code: code,
                    sender: sender.name.flatMap { $0.isEmpty ? nil : $0 } ?? sender.email,
                    senderDomain: sender.email.split(separator: "@").last.map(String.init) ?? "",
                    date: message.date))
            }
            return Self.filter(codes, now: clock(), expectedLength: expectedLength,
                               pageDomain: pageDomain, domain: MistPasswordTabManager.domain)
        } catch { return [] }
    }

    /// Marks the message read before moving it, so it reaches Trash read: the engine replays both in order, and a move keeps flags.
    func consume(_ code: MistMailCode) async {
        _ = try? await source.perform(.seen(true), on: code.messageID)
        _ = try? await source.trash(code.messageID)
        MistMailService.shared.removeNotification(messageID: code.messageID)
        cache[code.messageID] = nil
    }
}
