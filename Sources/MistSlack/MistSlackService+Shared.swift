import Foundation

extension MistSlackService {
    static let shared = MistSlackService(storage: SlackKeychain(), api: SlackWebAPI(transport: {
        try await APIClient.shared.slack($0, token: $1, parameters: $2)
    }))
}
