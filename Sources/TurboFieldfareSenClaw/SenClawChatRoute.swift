import Foundation
import SenclawSpace
import TurboFieldfare
import TurboFieldfareServerCore

/// The app's own `POST /v1/chat/completions`, replacing the SDK's generic one.
///
/// Why not `llmRoutes`' version: an agent turn against this model can spend
/// minutes in weight load + prefill before the first token, and the daemon
/// kills any stream that stays silent for 120 s (`STREAM_STALL_TIMEOUT`,
/// reset on every byte). The SDK's renderer has no way to emit keep-alives —
/// its sink drops empty text — so this route owns the wire and sends an
/// empty-delta `chat.completion.chunk` heartbeat while the engine works.
/// Empty deltas are exactly what the daemon's parser skips over, and each one
/// resets its stall timer.
///
/// Owning the wire also buys: typed 4xx/429 envelopes decided BEFORE the
/// status line goes out, per-turn diagnostics in the app log, and real
/// disconnect detection (a failed heartbeat write flips `isClosed`, which
/// cancels the generation mid-prefill instead of finishing into a void).
enum SenClawChatRoute {
    static let heartbeatSeconds: TimeInterval = 10

    static func routes(provider: SenClawProvider) -> [RouteKey: Handler] {
        [RouteKey("POST", "/v1/chat/completions"): { request in
            handle(provider: provider, request: request)
        }]
    }

    private static func handle(provider: SenClawProvider, request: Request) -> Response {
        guard let body = (try? request.json()) as? [String: Any] else {
            return errorResponse(status: 400, message: "body phải là JSON object",
                                 code: "invalid_request_error")
        }

        // Validate before the status line goes out — a bad request gets a
        // typed envelope, not a 200 stream that ends in an error chunk.
        let prepared: SenClawProvider.PreparedTurn
        do {
            prepared = try provider.validateTurn(body)
        } catch let error as ServerRequestError {
            return errorResponse(error)
        } catch {
            return errorResponse(status: 503, message: "\(error)", code: "model_not_installed")
        }
        let validated = prepared.request

        let turnID = SenClawChatWire.completionID()
        let toolCount = (body["tools"] as? [Any])?.count ?? 0
        let started = Date()
        log("[chat] \(turnID) bắt đầu — stream=\(validated.stream) tools=\(toolCount)"
            + (prepared.droppedTools.isEmpty ? "" : " (bỏ \(prepared.droppedTools.count))"))

        if validated.stream {
            return streamResponse(provider: provider, body: body, validated: validated,
                                  turnID: turnID, started: started)
        }
        return blockingResponse(provider: provider, body: body, validated: validated,
                                turnID: turnID, started: started)
    }

    /// Run one turn; when the chat template itself rejects a tool schema
    /// (something validation cannot see), bisect out the culprits and retry
    /// once with them dropped. The render failure happens before the
    /// generation slot, so a failed first attempt has emitted no events.
    private static func generateWithRenderRecovery(
        provider: SenClawProvider,
        body: [String: Any],
        validated: ValidatedChatRequest,
        turnID: String,
        isCancelled: @escaping () -> Bool,
        onEvent: @escaping (ServerInferenceEvent) -> Void
    ) throws -> ServerCompletion {
        do {
            return try provider.generate(validated, isCancelled: isCancelled, onEvent: onEvent)
        } catch {
            guard SenClawProvider.isRenderError(error),
                  (body["tools"] as? [Any])?.isEmpty == false else { throw error }
            log("[chat] \(turnID) template từ chối schema (\(error)) — bisect tìm tool hỏng…")
            let culprits = provider.identifyRenderBreakingTools(body)
            guard !culprits.isEmpty else { throw error }
            log("[chat] \(turnID) tool phá template: \(culprits.joined(separator: ", ")) — thử lại không có chúng")
            let retried = try provider.validateTurn(body)
            return try provider.generate(retried.request, isCancelled: isCancelled,
                                         onEvent: onEvent)
        }
    }

    // -- streaming ---------------------------------------------------------

    private static func streamResponse(provider: SenClawProvider,
                                       body: [String: Any],
                                       validated: ValidatedChatRequest,
                                       turnID: String,
                                       started: Date) -> Response {
        Response.eventStream { writer in
            let wire = LockedWire(writer: writer, id: turnID)
            // Role-first chunk, the shape every OpenAI stream opens with —
            // and the first byte that arms the daemon's stall timer in our
            // favour.
            wire.send(SenClawChatWire.roleChunk(id: turnID))

            let pump = HeartbeatPump(interval: heartbeatSeconds) {
                wire.send(SenClawChatWire.heartbeatChunk(id: turnID))
            }
            pump.start()
            defer { pump.stop() }

            var firstEventAt: Date?
            var sawToolCall = false
            let completion: ServerCompletion
            do {
                completion = try generateWithRenderRecovery(
                    provider: provider,
                    body: body,
                    validated: validated,
                    turnID: turnID,
                    isCancelled: { wire.isClosed },
                    onEvent: { event in
                        if firstEventAt == nil { firstEventAt = Date() }
                        switch event {
                        case .content(let text):
                            wire.send(SenClawChatWire.contentChunk(id: turnID, text: text))
                        case .toolCall(let call):
                            sawToolCall = true
                            wire.send(wire.nextToolCallChunk(call))
                        }
                    })
            } catch {
                log("[chat] \(turnID) lỗi sau \(Self.elapsed(started)): \(error)")
                wire.send(SenClawChatWire.errorChunk(id: turnID, message: "\(error)"))
                wire.send("[DONE]")
                return
            }

            wire.send(SenClawChatWire.finishChunk(
                id: turnID,
                finishReason: sawToolCall || !completion.toolCalls.isEmpty
                    ? "tool_calls" : completion.finishReason))
            if validated.includeUsage {
                wire.send(SenClawChatWire.usageChunk(id: turnID, usage: completion.usage))
            }
            wire.send("[DONE]")

            let ttfb = firstEventAt.map { String(format: "%.1fs", $0.timeIntervalSince(started)) } ?? "-"
            log("[chat] \(turnID) xong — finish=\(completion.finishReason) "
                + "prompt=\(completion.usage.promptTokens) "
                + "(cache \(completion.usage.promptTokensDetails.cachedTokens)) "
                + "completion=\(completion.usage.completionTokens) "
                + "ttfb=\(ttfb) total=\(Self.elapsed(started))")
        }
    }

    // -- non-stream --------------------------------------------------------

    private static func blockingResponse(provider: SenClawProvider,
                                         body: [String: Any],
                                         validated: ValidatedChatRequest,
                                         turnID: String,
                                         started: Date) -> Response {
        var content = ""
        var calls: [ParsedToolCall] = []
        let completion: ServerCompletion
        do {
            completion = try generateWithRenderRecovery(
                provider: provider, body: body, validated: validated, turnID: turnID,
                isCancelled: { false }
            ) { event in
                switch event {
                case .content(let text): content += text
                case .toolCall(let call): calls.append(call)
                }
            }
        } catch let error as ServerRequestError {
            return errorResponse(error)
        } catch {
            log("[chat] \(turnID) lỗi sau \(Self.elapsed(started)): \(error)")
            return errorResponse(status: 500, message: "\(error)", code: "server_error")
        }
        log("[chat] \(turnID) xong — finish=\(completion.finishReason) "
            + "prompt=\(completion.usage.promptTokens) completion=\(completion.usage.completionTokens) "
            + "total=\(Self.elapsed(started))")
        return Response(json: SenClawChatWire.nonStreamBody(
            id: turnID,
            content: content,
            toolCalls: calls.isEmpty ? completion.toolCalls : calls,
            finishReason: completion.finishReason,
            usage: completion.usage))
    }

    // -- shared ------------------------------------------------------------

    static func errorResponse(_ error: ServerRequestError) -> Response {
        let status: Int = switch error {
        case .invalid: 400
        case .unknownModel: 404
        case .queueFull: 429
        }
        let detail = error.envelope.error
        return errorResponse(status: status, message: detail.message, code: detail.code,
                             param: detail.param)
    }

    static func errorResponse(status: Int, message: String, code: String,
                              param: String? = nil) -> Response {
        var detail: [String: Any] = [
            "message": message,
            "type": status == 429 ? "rate_limit_error" : "invalid_request_error",
            "code": code,
        ]
        if let param { detail["param"] = param }
        return Response(json: ["error": detail], status: status)
    }

    private static func elapsed(_ from: Date) -> String {
        String(format: "%.1fs", Date().timeIntervalSince(from))
    }

    private static func log(_ message: String) {
        print("[turbo-fieldfare] \(message)")
    }
}

/// Serializes SSE writes: generation events arrive from the engine's task
/// while the heartbeat fires from its own thread, and interleaved partial
/// writes would corrupt the frame stream.
final class LockedWire: @unchecked Sendable {
    private let lock = NSLock()
    private let writer: SSEWriter
    private var toolCallIndex = 0
    let id: String

    init(writer: SSEWriter, id: String) {
        self.writer = writer
        self.id = id
    }

    func send(_ payload: String) {
        lock.lock()
        defer { lock.unlock() }
        writer.data(payload)
    }

    /// A whole tool call as one delta at a fresh index — the daemon
    /// accumulates name/arguments by concatenation keyed on the index, so a
    /// reused index would weld two calls together.
    func nextToolCallChunk(_ call: ParsedToolCall) -> String {
        lock.lock()
        let index = toolCallIndex
        toolCallIndex += 1
        lock.unlock()
        return SenClawChatWire.toolCallChunk(id: id, index: index, call: call)
    }

    var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return writer.isClosed
    }
}

/// Fires `tick` every `interval` seconds until stopped. The stop is a
/// handshake: `stop()` returns only after the pump thread has exited, so a
/// tick can never race the connection teardown and write into a recycled
/// file descriptor.
final class HeartbeatPump: @unchecked Sendable {
    private let interval: TimeInterval
    private let tick: () -> Void
    private let stopRequested = DispatchSemaphore(value: 0)
    private let exited = DispatchSemaphore(value: 0)

    init(interval: TimeInterval, tick: @escaping () -> Void) {
        self.interval = interval
        self.tick = tick
    }

    func start() {
        Thread.detachNewThread { [self] in
            while stopRequested.wait(timeout: .now() + interval) == .timedOut {
                tick()
            }
            exited.signal()
        }
    }

    func stop() {
        stopRequested.signal()
        exited.wait()
    }
}

/// The exact `chat.completion` byte shapes the daemon's parser expects.
/// Pure functions so the wire contract is unit-testable.
enum SenClawChatWire {
    static func completionID() -> String {
        counterLock.lock()
        defer { counterLock.unlock() }
        counter += 1
        return "chatcmpl-\(getpid())-\(counter)"
    }

    private nonisolated(unsafe) static var counter: UInt64 = 0
    private static let counterLock = NSLock()

    static func roleChunk(id: String) -> String {
        chunk(id: id, delta: ["role": "assistant"], finishReason: nil)
    }

    /// Keep-alive: an empty delta carries nothing, is skipped by every OpenAI
    /// stream parser, and resets the daemon's read timeout.
    static func heartbeatChunk(id: String) -> String {
        chunk(id: id, delta: [:], finishReason: nil)
    }

    static func contentChunk(id: String, text: String) -> String {
        chunk(id: id, delta: ["content": text], finishReason: nil)
    }

    static func toolCallChunk(id: String, index: Int, call: ParsedToolCall) -> String {
        chunk(id: id, delta: ["tool_calls": [[
            "index": index,
            "id": call.id,
            "type": "function",
            "function": ["name": call.name, "arguments": call.argumentsJSON],
        ]]], finishReason: nil)
    }

    static func finishChunk(id: String, finishReason: String) -> String {
        chunk(id: id, delta: [:], finishReason: finishReason)
    }

    static func errorChunk(id: String, message: String) -> String {
        json([
            "id": id, "object": "chat.completion.chunk",
            "model": SenClawModelIdentity.id,
            "choices": [["index": 0, "delta": [:] as [String: Any],
                         "finish_reason": "error"]],
            "error": ["message": message, "type": "server_error"],
        ])
    }

    /// Usage rides its own chunk with an empty `choices` array — the shape
    /// `stream_options.include_usage` produces and the only place the daemon
    /// looks for it.
    static func usageChunk(id: String, usage: OpenAIUsage) -> String {
        json([
            "id": id, "object": "chat.completion.chunk",
            "model": SenClawModelIdentity.id,
            "choices": [] as [Any],
            "usage": usageJSON(usage),
        ])
    }

    static func nonStreamBody(id: String,
                              content: String,
                              toolCalls: [ParsedToolCall],
                              finishReason: String,
                              usage: OpenAIUsage) -> [String: Any] {
        var message: [String: Any] = ["role": "assistant"]
        // OpenAI nulls content when the reply is only tool calls.
        if toolCalls.isEmpty || !content.isEmpty {
            message["content"] = content
        } else {
            message["content"] = NSNull()
        }
        if !toolCalls.isEmpty {
            message["tool_calls"] = toolCalls.map { call in
                ["id": call.id, "type": "function",
                 "function": ["name": call.name, "arguments": call.argumentsJSON]]
            }
        }
        return [
            "id": id, "object": "chat.completion",
            "model": SenClawModelIdentity.id,
            "choices": [[
                "index": 0,
                "message": message,
                "finish_reason": toolCalls.isEmpty ? finishReason : "tool_calls",
            ]],
            "usage": usageJSON(usage),
        ]
    }

    private static func chunk(id: String, delta: [String: Any],
                              finishReason: String?) -> String {
        let finish: Any = finishReason.map { $0 as Any } ?? NSNull()
        return json([
            "id": id, "object": "chat.completion.chunk",
            "model": SenClawModelIdentity.id,
            "choices": [[
                "index": 0,
                "delta": delta,
                "finish_reason": finish,
            ]],
        ])
    }

    private static func usageJSON(_ usage: OpenAIUsage) -> [String: Any] {
        [
            "prompt_tokens": usage.promptTokens,
            "completion_tokens": usage.completionTokens,
            "total_tokens": usage.totalTokens,
            "prompt_tokens_details": ["cached_tokens": usage.promptTokensDetails.cachedTokens],
        ]
    }

    private static func json(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let string = String(data: data, encoding: .utf8) else { return "{}" }
        return string
    }
}
