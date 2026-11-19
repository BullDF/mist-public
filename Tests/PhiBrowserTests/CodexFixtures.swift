import Foundation
#if !MIST_CODEX_HOSTLESS_TESTS
@testable import Phi
#endif

/// Recorded with codex-cli 0.164.0 and codex-dummy-mcp.js. IDs and timestamps are sanitized.
enum CodexFixtures {
    static func json(_ text: String) -> CodexJSON { try! JSONDecoder().decode(CodexJSON.self, from: Data(text.utf8)) }
    static let echoStarted = json(#"{"method":"item/started","params":{"item":{"type":"mcpToolCall","id":"exec-echo","server":"mist_test","tool":"echo","status":"inProgress","arguments":{"text":"hello"},"readOnlyHint":true,"result":null,"error":null,"durationMs":null},"threadId":"thread","turnId":"turn"}}"#)
    static let echoCompleted = json(#"{"method":"item/completed","params":{"item":{"type":"mcpToolCall","id":"exec-echo","server":"mist_test","tool":"echo","status":"completed","arguments":{"text":"hello"},"readOnlyHint":true,"result":{"content":[{"type":"text","text":"echo: hello"}],"structuredContent":null,"isError":false},"error":null,"durationMs":1},"threadId":"thread","turnId":"turn"}}"#)
    static let pokeStarted = json(#"{"method":"item/started","params":{"item":{"type":"mcpToolCall","id":"exec-poke","server":"mist_test","tool":"poke","status":"inProgress","arguments":{"text":"hello"},"readOnlyHint":false,"result":null,"error":null,"durationMs":null},"threadId":"thread","turnId":"turn"}}"#)
    static let approval = json(#"{"method":"mcpServer/elicitation/request","id":0,"params":{"threadId":"thread","turnId":"turn","serverName":"mist_test","mode":"form","_meta":{"codex_approval_kind":"mcp_tool_call","tool_description":"Simulate a write, returning text only","tool_params":{"text":"hello"},"tool_params_display":[{"name":"text","value":"hello","display_name":"text"}]},"message":"Allow the mist_test MCP server to run tool \"poke\"?","requestedSchema":{"type":"object","properties":{}}}}"#)
    static let pokeFailed = json(#"{"method":"item/completed","params":{"item":{"type":"mcpToolCall","id":"exec-poke","server":"mist_test","tool":"poke","status":"failed","arguments":{"text":"hello"},"readOnlyHint":false,"result":null,"error":{"message":"user rejected MCP tool call"},"durationMs":0},"threadId":"thread","turnId":"turn"}}"#)
    static let completed = json(#"{"method":"turn/completed","params":{"threadId":"thread","turn":{"id":"turn","items":[],"itemsView":"summary","status":"completed","error":null,"startedAt":100,"completedAt":104,"durationMs":4561}}}"#)
    static let agentStarted = json(#"{"method":"item/started","params":{"item":{"type":"agentMessage","id":"message","text":"","phase":"final_answer"},"threadId":"thread","turnId":"turn"}}"#)
    static let delta = json(#"{"method":"item/agentMessage/delta","params":{"threadId":"thread","turnId":"turn","itemId":"message","delta":"Done"}}"#)
    static let agentCompleted = json(#"{"method":"item/completed","params":{"item":{"type":"agentMessage","id":"message","text":"Done.","phase":"final_answer"},"threadId":"thread","turnId":"turn"}}"#)
    static let models = json(#"{"data":[{"id":"gpt-6-luna","displayName":"GPT-6-Luna","supportedReasoningEfforts":[{"reasoningEffort":"low","description":"Fast"},{"reasoningEffort":"medium","description":"Balanced"}],"defaultReasoningEffort":"medium","inputModalities":["text","image"],"isDefault":true}],"nextCursor":null}"#)
    static let question = json(#"{"id":"question-request","method":"item/tool/requestUserInput","params":{"threadId":"thread","turnId":"turn","itemId":"question","isBlocking":true,"questions":[{"id":"color","header":"Color","question":"Pick a color","options":[{"label":"Red","description":"Warm"},{"label":"Blue","description":"Cool"}]}]}}"#)
}
