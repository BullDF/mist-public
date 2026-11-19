import Foundation

enum MistAppID: String, CaseIterable {
    case clipboard, drifter, mail

    var name: String {
        switch self {
        case .clipboard: return "Clipboard"
        case .drifter: return "Drifter"
        case .mail: return "Mail"
        }
    }

    var hasInstances: Bool { self == .drifter }
    /// Whether the app's tabs get the Chat panel. Drifter's own pages never do.
    var hostsChatPanel: Bool { self == .mail }
}

struct MistAppAddress: Equatable {
    let app: MistAppID
    let instance: UUID?
    var chatId: UUID? { app == .drifter ? instance : nil }
}

struct MistAppIcon: Equatable {
    let asset: String
    let isTemplate: Bool
    var scale: Double = 1
}
