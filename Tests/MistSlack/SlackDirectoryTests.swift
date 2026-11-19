import Foundation

@MainActor enum SlackDirectoryTests {
    static func run() async {
        var token: String? = "fake-a"
        var date = Date(timeIntervalSince1970: 0)
        var calls: [(String, [String: String])] = []
        var fail = false
        let directory = SlackDirectory(call: { method, params in
            calls.append((method, params))
            if fail { throw SlackAPIError(code: "network") }
            switch method {
            case "auth.test": return ["user_id": "U1"]
            case "users.list":
                if params["cursor"] == nil { return ["members": [
                    ["id": "U1", "name": "johnny", "real_name": "Johnny"],
                    ["id": "U2", "name": "alice", "real_name": "Alice"]
                ], "response_metadata": ["next_cursor": "users-next"]] }
                return ["members": [["id": "U3", "name": "bob", "profile": ["display_name": "Bobby"]],
                                     ["id": "U4", "name": "carol", "real_name": "", "profile": ["display_name": ""]]]]
            case "users.conversations":
                if params["cursor"] == nil { return ["channels": [
                    ["id": "C1", "name": "general"], ["id": "C2", "name": "private", "is_private": true],
                    ["id": "D1", "is_im": true, "user": "U1"], ["id": "D2", "is_im": true, "user": "U2"]
                ], "response_metadata": ["next_cursor": "channels-next"]] }
                return ["channels": [["id": "D3", "is_im": true, "user": "U3"], ["id": "D4", "is_im": true, "user": "U4"],
                                     ["id": "G1", "is_mpim": true, "name": "mpdm-johnny--alice--bob--carol-1"]]]
            default: fatalError("Unexpected directory method")
            }
        }, account: { token }, clock: { date })
        await directory.refreshIfStale()
        for (id, name) in ["C1": "#general", "C2": "#private", "D1": "@Johnny", "D2": "@Alice", "D3": "@Bobby", "D4": "@carol", "G1": "Alice, Bobby, carol"] {
            precondition(directory.name(forChannel: id)?.name == name, id)
        }
        precondition(directory.name(forChannel: "D1")?.isSelf == true && directory.name(forChannel: "D2")?.isSelf == false)
        for (id, name) in ["U1": "Johnny", "U2": "Alice", "U3": "Bobby", "U4": "carol"] {
            precondition(directory.name(forUser: id) == name, id)
        }
        precondition(directory.name(forUser: "missing") == nil)
        precondition(directory.name(forChannel: "missing") == nil && calls.count == 5)
        precondition(calls[2].1["cursor"] == "users-next" && calls[4].1["cursor"] == "channels-next")
        precondition(calls[3].1 == ["limit": "200", "types": "public_channel,private_channel,mpim,im", "exclude_archived": "true"])
        await directory.refreshIfStale()
        precondition(calls.count == 5)
        date += 3600
        fail = true
        await directory.refreshIfStale()
        precondition(calls.count == 6 && directory.name(forChannel: "C1")?.name == "#general")
        precondition(directory.name(forUser: "U2") == "Alice")
        token = "fake-b"
        precondition(directory.name(forChannel: "C1") == nil)
        precondition(directory.name(forUser: "U2") == nil)
        await directory.refreshIfStale()
        precondition(calls.count == 7 && directory.name(forChannel: "C1") == nil)
        precondition(directory.name(forUser: "U2") == nil)
        fail = false
        date += 3600
        await directory.refreshIfStale()
        precondition(calls.count == 12 && directory.name(forChannel: "C1")?.name == "#general")
        precondition(directory.name(forUser: "U2") == "Alice")
        token = nil
        await directory.refreshIfStale()
        precondition(directory.name(forChannel: "C1") == nil && calls.count == 12)
        precondition(directory.name(forUser: "U2") == nil)
    }
}
