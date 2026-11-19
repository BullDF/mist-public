import Foundation

enum CodexMarkerNamer {
    /// GPT Luna at effort none, in a one-shot app-server; nil on any failure. Never retries.
    static func name(text: String, context: String?, timeout: TimeInterval = 20) async -> String? {
        guard timeout > 0, timeout.isFinite, !Task.isCancelled else { return nil }
        let (results, continuation) = AsyncStream<String?>.makeStream()
        // An unstructured race also bounds catalog loading, whose shared task need not honor cancellation.
        let work = Task {
            let name = await generate(text: text, context: context)
            continuation.yield(name)
            continuation.finish()
        }
        let deadline = Task {
            do { try await Task.sleep(for: .seconds(timeout)) } catch { return }
            continuation.yield(nil)
            continuation.finish()
        }
        defer { work.cancel(); deadline.cancel() }
        var iterator = results.makeAsyncIterator()
        return await iterator.next() ?? nil
    }

    private static func generate(text: String, context: String?) async -> String? {
        do {
            let snapshot = try await CodexModelCatalog.shared.load()
            guard !Task.isCancelled, snapshot.account == .chatgpt,
                  let luna = CodexProtocol.lunaModel(snapshot.models) else { return nil }
            let folder = FileManager.default.temporaryDirectory
            let process = try await CodexProcess.launch(folder: folder)
            defer { process.terminate() }
            return try await withTaskCancellationHandler {
                try Task.checkCancellation()
                try await process.initialize()
                let result = try await process.request("thread/start", CodexProtocol.markerThreadStart(model: luna.id, cwd: folder))
                guard let id = result["thread"]["id"].string, !id.isEmpty else { return nil }
                var thread = CodexMarkerThread(id: id)
                _ = try await process.request("turn/start", CodexProtocol.turnStart(threadId: id,
                    text: CodexProtocol.markerInput(text: text, context: context), attachments: [], effort: "none", model: luna.id))
                for await output in process.output {
                    switch output {
                    case let .message(message):
                        if let outcome = thread.apply(message) {
                            if case let .named(name) = outcome { return name }
                            return nil
                        }
                    case .exited, .writeFailed: return nil
                    }
                }
                return nil
            } onCancel: {
                process.terminate()
            }
        } catch { return nil }
    }
}
