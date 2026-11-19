import Foundation

public struct MailAddressSuggestion: Equatable, Sendable {
    public var address: MailAddress
    public var count: Int
    public var lastUsed: Date
    public init(address: MailAddress, count: Int, lastUsed: Date) {
        self.address = address; self.count = count; self.lastUsed = lastUsed
    }
}

extension MailEngine {
    public func addressSuggestions(limit: Int = 2000) throws -> [MailAddressSuggestion] {
        var merged: [String: MailAddressSuggestion] = [:]
        for message in try store.recentAddressMessages() {
            let headers = message.remote
            for address in headers.from + headers.to + headers.cc + headers.replyTo {
                let key = address.email.lowercased()
                guard !key.isEmpty else { continue }
                if var existing = merged[key] {
                    existing.count += 1
                    if existing.address.name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false,
                       address.name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                        existing.address.name = address.name
                    }
                    merged[key] = existing
                } else {
                    merged[key] = .init(address: address, count: 1, lastUsed: headers.date)
                }
            }
        }
        return Array(merged.values.sorted {
            if $0.count != $1.count { return $0.count > $1.count }
            if $0.lastUsed != $1.lastUsed { return $0.lastUsed > $1.lastUsed }
            return $0.address.email.lowercased() < $1.address.email.lowercased()
        }.prefix(max(0, limit)))
    }
}
