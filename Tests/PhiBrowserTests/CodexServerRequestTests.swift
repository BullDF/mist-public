import Foundation
import XCTest
#if !MIST_CODEX_HOSTLESS_TESTS
@testable import Phi
#endif

final class CodexServerRequestTests: XCTestCase {
    func testReadOnlyCommandClassificationRejectsShellSideEffects() {
        for command in ["cat /outside/a.txt", "/bin/zsh -lc 'cat /outside/a.txt'", "rg title '/folder with spaces'", "ls /tmp"] {
            XCTAssertTrue(CodexServerRequest.isSimpleReadCommand(command), command)
        }
        for command in ["cat a > b", "cat a; rm b", "cat $(touch b)", "cat `touch b`", "cat a | sh",
                        "rg --pre=program pattern", "rg --hostname-bin=program pattern", "/tmp/cat a", "/bin/zsh -lc 'cat a > b'", "cat 'unterminated"] {
            XCTAssertFalse(CodexServerRequest.isSimpleReadCommand(command), command)
        }
    }

    func testNativeCommandAndFileChangeApprovalsDescribeActualOperations() throws {
        let command = try XCTUnwrap(CodexServerRequest(CodexFixtures.json(#"{"id":1,"method":"item/commandExecution/requestApproval","params":{"itemId":"cmd","command":"python3 task.py","cwd":"/outside"}}"#)))
        let permission = try XCTUnwrap(command.permission(items: [], allowedServers: []))
        XCTAssertEqual(permission.toolName, "Bash")
        XCTAssertEqual(permission.input["command"].string, "python3 task.py")
        XCTAssertEqual(command.reply(.allow)["decision"].string, "accept")
        XCTAssertEqual(command.reply(.deny(message: nil))["decision"].string, "decline")
        let read = try XCTUnwrap(CodexServerRequest(CodexFixtures.json(#"{"id":3,"method":"item/commandExecution/requestApproval","params":{"command":"cat /outside/a.txt","commandActions":[{"type":"read","path":"/outside/a.txt"}]}}"#)))
        XCTAssertEqual(read.permission(items: [], allowedServers: [])?.toolName, "Read")
        let mixed = try XCTUnwrap(CodexServerRequest(CodexFixtures.json(#"{"id":4,"method":"item/commandExecution/requestApproval","params":{"command":"cat a; rm b","commandActions":[{"type":"read","path":"a"},{"type":"unknown","command":"rm b"}]}}"#)))
        XCTAssertEqual(mixed.permission(items: [], allowedServers: [])?.toolName, "Bash")
        var transcript = CodexTranscript()
        transcript.apply(CodexFixtures.json(#"{"method":"item/started","params":{"item":{"id":"patch","type":"fileChange","status":"inProgress","changes":[{"path":"/outside/a.txt","kind":{"type":"add"},"diff":"a"},{"path":"/outside/b.txt","kind":{"type":"update"},"diff":"b"}]}}}"#))
        let patch = try XCTUnwrap(CodexServerRequest(CodexFixtures.json(#"{"id":2,"method":"item/fileChange/requestApproval","params":{"itemId":"patch"}}"#)))
        let files = try XCTUnwrap(patch.permission(items: transcript.items, allowedServers: []))
        XCTAssertEqual(files.input["changes"].array, [.string("/outside/a.txt"), .string("/outside/b.txt")])
        XCTAssertEqual(patch.reply(.allow)["decision"].string, "accept")
        XCTAssertNil(patch.permission(items: [], allowedServers: []))
    }

    @MainActor func testOtherThreadNotificationsAndPermissionsStayOutOfTheChat() {
        let conversation = AgentConversation()
        let request = CodexLaunchRequest(prompt: "hello", model: "chat", effort: "low", cwd: URL(fileURLWithPath: "/tmp"))
        var replies: [CodexJSON] = []
        let session = CodexSession(request: request, conversation: conversation, replyWriter: { _, result in replies.append(result) })
        for value in [
            #"{"method":"turn/started","params":{"threadId":"title","turn":{"id":"title-turn"}}}"#,
            #"{"method":"item/completed","params":{"threadId":"title","item":{"id":"title-text","type":"agentMessage","text":"Generated chat title"}}}"#,
            #"{"method":"thread/tokenUsage/updated","params":{"threadId":"title","tokenUsage":{"total":{"outputTokens":99},"last":{"totalTokens":1000},"modelContextWindow":2000}}}"#,
            #"{"id":42,"method":"item/tool/requestUserInput","params":{"threadId":"title","questions":[{"id":"q","question":"Wrong question"}]}}"#,
            #"{"method":"turn/completed","params":{"threadId":"title","turn":{"id":"title-turn","status":"completed"}}}"#,
        ] { session.receive(.message(CodexFixtures.json(value))) }
        XCTAssertTrue(conversation.items.isEmpty)
        XCTAssertEqual(conversation.status, .starting)
        XCTAssertNil(conversation.outputTokens)
        XCTAssertNil(conversation.contextTokens)
        XCTAssertNil(conversation.contextWindowSize)
        XCTAssertEqual(replies.count, 1)
        XCTAssertEqual(replies.first?["answers"]["q"]["answers"].array, [])
        session.close()
    }

    func testMCPApprovalAndReplies() throws {
        var transcript = CodexTranscript(); transcript.apply(CodexFixtures.pokeStarted)
        let request = try XCTUnwrap(CodexServerRequest(CodexFixtures.approval))
        let permission = try XCTUnwrap(request.permission(items: transcript.items, allowedServers: ["mist_test"]))
        XCTAssertEqual(permission.toolName, "mcp__mist_test__poke")
        XCTAssertEqual(permission.requestId, "0")
        XCTAssertEqual(permission.input["text"].string, "hello")
        XCTAssertEqual(request.reply(.allow)["action"].string, "accept")
        XCTAssertEqual(request.reply(.deny(message: nil))["action"].string, "decline")
        // Concurrent calls can have identical arguments; the generated message disambiguates their names.
        transcript.apply(CodexFixtures.echoStarted)
        XCTAssertEqual(request.permission(items: transcript.items, allowedServers: ["mist_test"])?.toolName, "mcp__mist_test__poke")
        XCTAssertNil(request.permission(items: [], allowedServers: ["mist_test"]))
        XCTAssertNil(request.permission(items: transcript.items, allowedServers: []))
        XCTAssertEqual(request.permission(items: transcript.items, allowedServers: nil)?.toolName, "mcp__mist_test__poke")
        XCTAssertNil(request.permission(items: [], allowedServers: nil), "Inheriting servers must still identify a running call")
    }

    func testDeclinesOtherElicitationsAndNativeApprovals() throws {
        let elicitation = try XCTUnwrap(CodexServerRequest(CodexFixtures.json(#"{"id":1,"method":"mcpServer/elicitation/request","params":{"mode":"url","serverName":"mist_test","message":"Login","url":"https://example.com"}}"#)))
        XCTAssertNil(elicitation.permission(items: [], allowedServers: ["mist_test"]))
        XCTAssertEqual(elicitation.reply(.deny(message: nil))["action"].string, "decline")
        for method in ["item/commandExecution/requestApproval", "item/fileChange/requestApproval"] {
            let request = try XCTUnwrap(CodexServerRequest(.object(["id": .string("id"), "method": .string(method), "params": .object([:])])))
            XCTAssertNil(request.permission(items: [], allowedServers: []))
            XCTAssertEqual(request.reply(.allow)["decision"].string, "accept")
        }
    }

    func testQuestionUIAndReplyMapsQuestionTextBackToId() throws {
        let request = try XCTUnwrap(CodexServerRequest(CodexFixtures.question))
        let permission = try XCTUnwrap(request.permission(items: [], allowedServers: []))
        XCTAssertTrue(permission.requiresUserInteraction)
        XCTAssertEqual(permission.toolName, "AskUserQuestion")
        XCTAssertEqual(permission.questions.first?.header, "Color")
        var selection = AgentPermissionQuestion.Selection(); selection.toggle(1, multiSelect: false)
        let response = try XCTUnwrap(permission.answerResponse([0: selection]))
        XCTAssertEqual(request.reply(response)["answers"]["color"]["answers"].array, [.string("Blue")])
        XCTAssertEqual(request.reply(.deny(message: nil))["answers"]["color"]["answers"].array, [])
    }

    func testUnknownRequestAndNotification() throws {
        XCTAssertNil(CodexServerRequest(CodexFixtures.delta))
        let request = try XCTUnwrap(CodexServerRequest(CodexFixtures.json(#"{"id":5,"method":"new/unsupported","params":{}}"#)))
        XCTAssertFalse(request.hasKnownReply)
    }
}
