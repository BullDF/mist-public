import Foundation

public struct MailRemoteMailbox: Sendable {
    public var name: String
    public var delimiter: String?
    public var attributes: Set<String>
    public init(name: String, delimiter: String? = "/", attributes: Set<String> = []) {
        self.name = name; self.delimiter = delimiter; self.attributes = attributes
    }
}
public struct MailSelection: Sendable {
    public var uidValidity: UInt32
    public var uidNext: UInt32
    public init(uidValidity: UInt32, uidNext: UInt32) { self.uidValidity = uidValidity; self.uidNext = uidNext }
}
public enum MailUIDQuery: Sendable { case all, since(Date), range(ClosedRange<UInt32>), text(String), header(String, String) }
public struct MailBody: Sendable {
    public var plainText: String?
    public var html: String?
    /// Decoded bytes for inline parts referenced by the HTML, keyed by section.
    public var inlineParts: [String: Data]
    public init(plainText: String? = nil, html: String? = nil, inlineParts: [String: Data] = [:]) {
        self.plainText = plainText; self.html = html; self.inlineParts = inlineParts
    }
}
public struct MailMoveResult: Sendable {
    public var uidValidity: UInt32
    public var uids: [UInt32: UInt32]
    public init(uidValidity: UInt32, uids: [UInt32: UInt32]) { self.uidValidity = uidValidity; self.uids = uids }
}
public enum MailPushEvent: Sendable { case changed, disconnected(MailError) }

/// Every operation names its mailbox. Implementations serialize SELECT plus the command,
/// including across actor suspension points; the IDLE connection is independent.
public protocol MailTransport: Sendable {
    func connect() async throws -> Set<String>
    func disconnect() async
    func testSMTP() async throws
    func listMailboxes() async throws -> [MailRemoteMailbox]
    func select(_ mailbox: String) async throws -> MailSelection
    func search(_ query: MailUIDQuery, in mailbox: String) async throws -> [UInt32]
    func fetch(_ uids: [UInt32], in mailbox: String, gmail: Bool) async throws -> [MailRemoteMessage]
    func flags(_ range: ClosedRange<UInt32>, in mailbox: String) async throws -> [UInt32: Set<String>]
    func body(_ message: MailRemoteMessage, in mailbox: String) async throws -> MailBody
    func attachment(_ part: MailPart, uid: UInt32, in mailbox: String) async throws -> Data
    func setFlag(_ flag: String, value: Bool, uids: [UInt32], in mailbox: String) async throws
    func setFlag(_ flag: String, value: Bool, range: ClosedRange<UInt32>, in mailbox: String) async throws
    func move(_ uids: [UInt32], from: String, to: String) async throws -> MailMoveResult?
    func delete(_ uids: [UInt32], in mailbox: String) async throws
    func createMailbox(_ name: String) async throws
    func append(_ bytes: Data, to mailbox: String, flags: Set<String>) async throws -> UInt32?
    func send(_ bytes: Data, from: MailAddress, recipients: [MailAddress]) async throws
    /// The implementation renews IDLE at this interval, reporting terminal failures.
    func idle(in mailbox: String, renewalInterval: TimeInterval) async throws -> AsyncStream<MailPushEvent>
}

public typealias MailTransportFactory = @Sendable (MailAccountConfig, String) -> any MailTransport

/// Receives one line per failed server operation, for the app's log. Set once at launch, before the engine starts.
public enum MailDiagnostics {
    nonisolated(unsafe) public static var log: (@Sendable (String) -> Void)?
}

/// Used by transport implementations to keep mailbox command sequences indivisible.
actor MailOperationGate {
    private var held = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func acquire() async { if !held { held = true; return }; await withCheckedContinuation { waiters.append($0) } }
    func release() { if waiters.isEmpty { held = false } else { waiters.removeFirst().resume() } }
}
