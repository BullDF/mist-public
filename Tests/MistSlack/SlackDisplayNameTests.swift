import Foundation

enum SlackDisplayNameTests {
    @MainActor static func run() async throws {
        for (info, expected) in [
            (#"{"ok":true,"user":{"profile":{"display_name":"Johnny","real_name":"Profile Name"},"real_name":"Full Name"}}"#, "Johnny"),
            (#"{"ok":true,"user":{"profile":{"display_name":"  ","real_name":"Profile Name"},"real_name":"Full Name"}}"#, "Profile Name"),
            (#"{"ok":true,"user":{"profile":{"display_name":"","real_name":""},"real_name":"Full Name"}}"#, "Full Name"),
            (#"{"ok":true,"user":{"profile":{}}}"#, "handle"),
            (#"{"ok":false,"error":"missing_scope"}"#, "handle")
        ] {
            var calls = 0
            let api = SlackWebAPI(transport: { method, token, parameters in
                precondition(token == "xoxp-fake")
                calls += 1
                if method == "users.info" { precondition(parameters == ["user": "U1"]) }
                let body = method == "users.info" ? info : #"{"ok":true,"team":"Team","team_id":"T1","url":"https://example.invalid/","user":"handle","user_id":"U1"}"#
                return (Data(body.utf8), HTTPURLResponse(url: URL(string: "https://example.invalid")!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            })
            let storage = InMemorySlackTokenStorage()
            let service = MistSlackService(storage: storage, api: api)
            try await service.save(user: "xoxp-fake", bot: "", app: "")
            precondition(service.identity?.displayName == expected && storage.tokens?.user == "xoxp-fake")
            await service.refreshIdentity()
            precondition(service.identity?.displayName == expected && service.lastError == nil && calls == 4)
        }
    }
}
