import Foundation

enum GeminiProtocol {
    static let authMethod = "gemini-api-key"
    static let serverName = "mistbrowser"
    static let initialize: CodexJSON = .object(["protocolVersion": .number(1), "clientCapabilities": .object([:])])
    static let builtInNames = [
        "read_file": "Read", "read_many_files": "Read", "list_directory": "Glob",
        "glob": "Glob", "grep_search": "Grep", "replace": "Edit", "write_file": "Write",
        "run_shell_command": "Bash", "web_fetch": "WebFetch", "google_web_search": "WebSearch",
        "list_mcp_resources": "list_mcp_resources", "read_mcp_resource": "read_mcp_resource",
    ]

    static func alias(model: String, effort: String) -> String {
        "mist-\(model)-\(thinkingLevel(model: model, effort: effort).lowercased())"
    }

    static func thinkingLevel(model: String, effort: String) -> String {
        (GeminiModelInfo.efforts(model).contains(effort) ? effort : GeminiModelInfo.defaultEffort).uppercased()
    }

    static func settings(models: [String]) throws -> Data {
        var aliases: [String: Any] = [:]
        for model in Set(models) {
            for effort in GeminiModelInfo.efforts(model) {
                aliases[alias(model: model, effort: effort)] = [
                    "extends": "chat-base",
                    "modelConfig": [
                        "model": model,
                        "generateContentConfig": ["thinkingConfig": ["thinkingLevel": effort.uppercased()]],
                    ],
                ]
            }
        }
        let settings: [String: Any] = [
            "general": ["enableAutoUpdate": false, "enableAutoUpdateNotification": false,
                        "checkpointing": ["enabled": false], "sessionRetention": ["enabled": false],
                        "plan": ["enabled": false, "modelRouting": false], "topicUpdateNarration": false],
            "privacy": ["usageStatisticsEnabled": false],
            "telemetry": ["enabled": false, "logPrompts": false],
            "security": ["auth": ["selectedType": authMethod, "enforcedType": authMethod], "allowedExtensions": ["(?!)"],
                         "disableAlwaysAllow": true, "enablePermanentToolApproval": false, "autoAddToPolicyByDefault": false,
                         "environmentVariableRedaction": ["enabled": true, "blocked": [GeminiEnvironment.keyName, "NODE_OPTIONS"]]],
            // In 0.70, `core` both registers the built-ins and allows them, and denies every other tool,
            // MCP ones included. Server-scoped rules (`mcp_mistbrowser_*`) never match an MCP call, whose
            // policy check carries the server as `mcp_mistbrowser`, so only `*` can send MCP calls to ACP's
            // permission request. Every call asks; DrifterConfirmation auto-allows Read, Glob and Grep.
            "tools": ["core": builtInNames.keys.sorted(), "confirmationRequired": ["*"]],
            "skills": ["enabled": false],
            "hooksConfig": ["enabled": false],
            "ide": ["enabled": false],
            "advanced": ["ignoreLocalEnv": true],
            "context": ["includeDirectoryTree": false, "loadMemoryFromIncludeDirectories": false],
            "experimental": ["enableAgents": false, "autoMemory": false, "taskTracker": false,
                             "gemmaModelRouter": ["enabled": false], "modelSteering": false, "directWebFetch": true],
            "modelConfigs": ["customAliases": aliases],
        ]
        return try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
    }

    static func session(cwd: URL, server: CodexMCPServer?, id: String? = nil) -> CodexJSON {
        let servers: [CodexJSON] = server.map { server in
            [.object(["name": .string(serverName), "command": .string(server.command),
                      "args": .array(server.args.map(CodexJSON.string)),
                      "env": .array(server.env.sorted(by: { $0.key < $1.key }).map {
                          .object(["name": .string($0.key), "value": .string($0.value)])
                      })])]
        } ?? []
        var params: [String: CodexJSON] = ["cwd": .string(cwd.path), "mcpServers": .array(servers)]
        if let id { params["sessionId"] = .string(id) }
        return .object(params)
    }

    static func prompt(sessionId: String, text: String, attachments: [AgentAttachment], supportsImages: Bool) -> CodexJSON {
        let images = supportsImages ? attachments.images.map { image in
            CodexJSON.object(["type": .string("image"), "mimeType": .string(image.mediaType), "data": .string(image.data.base64EncodedString())])
        } : []
        let parts: [CodexJSON] = [.object(["type": .string("text"), "text": .string(attachments.agentText(text))])] + images
        return .object(["sessionId": .string(sessionId), "prompt": .array(parts)])
    }
}
