import Foundation
import SenclawSpace
import Synchronization
import TurboFieldfareAppCore
import TurboFieldfareServerCore

/// The one model this app serves. The wire id matches the standalone
/// `TurboFieldfareServer` default so clients configured against either agree.
enum SenClawModelIdentity {
    static let id = "gemma-4-26b-a4b-it"
    /// Model name only — the daemon renders picker rows as
    /// "<llm.displayName> · <model display name>", so putting the brand here
    /// would show it twice.
    static let displayName = "Gemma 4 26B A4B"
}

/// `LlmProvider` backed by the TurboFieldfare engine.
///
/// The SDK owns the OpenAI wire (SSE chunks, indexed tool-call deltas, the
/// usage chunk, `[DONE]`); `TurboFieldfareServerCore` owns validation, prompt
/// rendering, the structured tool-call decoder, and the prompt cache. This
/// type only converts between the two vocabularies.
final class SenClawProvider: LlmProvider {
    private let store: SenClawModelStore
    private let settings: SenClawSettingsStore
    private let engine: SenClawEngine

    init(store: SenClawModelStore, settings: SenClawSettingsStore, engine: SenClawEngine) {
        self.store = store
        self.settings = settings
        self.engine = engine
    }

    /// The card the daemon's picker shows. Empty until the checkpoint is
    /// installed and verified — a model nobody can run must not be selectable.
    func models() -> [ModelCard] {
        guard store.isInstalled else { return [] }
        return [Self.card(settings: settings.current)]
    }

    static func card(settings: SenClawAppSettings) -> ModelCard {
        ModelCard(
            SenClawModelIdentity.id,
            contextLength: settings.maxContextTokens,
            maxOutputTokens: settings.maxOutputTokens,
            // The repack pipeline drops the checkpoint's multimodal tensors —
            // this build is text-only, and saying otherwise would make the
            // daemon send image blocks that 400 the whole turn.
            vision: false,
            displayName: SenClawModelIdentity.displayName,
            tools: true)
    }

    /// The SDK `LlmProvider` entry. `SenClawChatRoute` overrides the
    /// streaming POST in practice (it can send heartbeats; this path cannot),
    /// but the conformance keeps `GET /v1/models` and stays as a correct
    /// fallback.
    func chat(_ req: ChatRequest, _ sink: ChunkSink) throws {
        try chatRaw(req.raw, emit: { sink.send($0) }, isClosed: { sink.isClosed })
    }

    /// The whole turn, expressed against plain values so it is testable
    /// without the SDK's server-owned `ChatRequest`/`ChunkSink` types (their
    /// initializers are internal to the SDK on purpose).
    func chatRaw(_ raw: [String: Any],
                 emit: @escaping (Chunk) -> Void,
                 isClosed: @escaping () -> Bool) throws {
        let validated: ValidatedChatRequest
        do {
            validated = try validateTurn(raw).request
        } catch let error as ServerRequestError {
            throw SenclawError(error.envelope.error.message)
        } catch {
            throw SenclawError("\(error)")
        }
        let emitBox = UncheckedSendableBox(emit)
        let closedBox = UncheckedSendableBox(isClosed)
        let completion: ServerCompletion
        do {
            completion = try generate(validated, isCancelled: { closedBox.value() }) { event in
                switch event {
                case .content(let text):
                    emitBox.value(.text(text))
                case .toolCall(let call):
                    emitBox.value(.toolCall(id: call.id,
                                            name: call.name,
                                            arguments: call.argumentsJSON))
                }
            }
        } catch let error as ServerRequestError {
            throw SenclawError(error.envelope.error.message)
        } catch is CancellationError {
            throw SenclawError("generation đã bị hủy")
        }
        emit(.usage(promptTokens: completion.usage.promptTokens,
                    completionTokens: completion.usage.completionTokens))
    }

    struct PreparedTurn {
        let request: ValidatedChatRequest
        /// Tools removed because Gemma's native tool syntax cannot represent
        /// their schema (e.g. a three-branch union). Names only, for the log.
        let droppedTools: [String]
    }

    /// Decode + validate one OpenAI-shaped body. Throws `ServerRequestError`
    /// for typed envelopes, `SenClawProviderError.modelNotInstalled` before
    /// any decode when the checkpoint is absent.
    ///
    /// Tools with unrepresentable schemas are DROPPED, not fatal: SenClaw's
    /// agent sends its whole tool pool, and one exotic schema out of hundreds
    /// must not brick every turn on this model. The model simply cannot call
    /// the dropped tool — which it could not have done correctly anyway.
    func validateTurn(_ raw: [String: Any]) throws -> PreparedTurn {
        guard store.installedStatus() == .complete else {
            throw SenClawProviderError.modelNotInstalled
        }
        var raw = raw
        let dropped = Self.filterUnrepresentableTools(&raw)
        if !dropped.isEmpty {
            print("[turbo-fieldfare] [chat] bỏ \(dropped.count) tool không biểu diễn được: "
                + dropped.joined(separator: ", "))
        }
        let openAIRequest: OpenAIChatRequest
        do {
            let body = try JSONSerialization.data(withJSONObject: raw)
            openAIRequest = try JSONDecoder().decode(OpenAIChatRequest.self, from: body)
        } catch {
            throw ServerRequestError.invalid(
                message: "request không đúng dạng OpenAI chat.completions: \(error)",
                param: nil,
                code: "invalid_request_error")
        }
        let validated = try OpenAIRequestValidator.validate(
            openAIRequest, modelID: SenClawModelIdentity.id)
        return PreparedTurn(request: validated, droppedTools: dropped)
    }

    /// Remove tools the validator would reject, returning their names.
    ///
    /// Implemented as a per-tool probe through the public validator (the
    /// schema adapter itself is internal to the server core, which stays
    /// unmodified): each tool rides a minimal single-tool request, and only a
    /// tool-attributed rejection drops it. Tools previously identified as
    /// template-breaking (see `identifyRenderBreakingTools`) are dropped here
    /// too, without another render.
    static func filterUnrepresentableTools(_ raw: inout [String: Any]) -> [String] {
        guard let tools = raw["tools"] as? [Any], !tools.isEmpty else { return [] }
        let knownBad = knownRenderBreakingTools.withLock { $0 }
        var kept: [Any] = []
        var dropped: [String] = []
        for tool in tools {
            let name = toolName(tool)
            if knownBad.contains(name) {
                dropped.append(name)
                continue
            }
            let probe: [String: Any] = [
                "model": SenClawModelIdentity.id,
                "messages": [["role": "user", "content": "probe"]],
                "tools": [tool],
            ]
            do {
                let body = try JSONSerialization.data(withJSONObject: probe)
                let request = try JSONDecoder().decode(OpenAIChatRequest.self, from: body)
                _ = try OpenAIRequestValidator.validate(request, modelID: SenClawModelIdentity.id)
                kept.append(tool)
            } catch {
                dropped.append(name)
            }
        }
        if !dropped.isEmpty {
            raw["tools"] = kept
        }
        return dropped
    }

    // -- render-breaking tools --------------------------------------------

    /// Names of tools whose schema passed validation but blew up the Jinja
    /// chat template (e.g. `upper filter requires string`). Remembered for the
    /// process lifetime so each culprit is bisected exactly once.
    static let knownRenderBreakingTools = Mutex<Set<String>>([])

    /// Does this error look like a chat-template render failure (as opposed
    /// to a typed validation error or a cancellation)?
    static func isRenderError(_ error: Error) -> Bool {
        if error is ServerRequestError || error is CancellationError
            || error is SenClawEngine.EngineError || error is SenClawProviderError {
            return false
        }
        let description = String(describing: error).lowercased()
        return description.contains("filter") || description.contains("template")
            || description.contains("jinja") || description.contains("runtime(")
    }

    /// Bisect the request's tools with render-only probes to find every tool
    /// that breaks the template. Found names are memoized; the caller then
    /// re-validates (which drops them) and retries the turn.
    ///
    /// Cost: O(bad · log n) renders, no KV or generation slot touched.
    func identifyRenderBreakingTools(_ raw: [String: Any]) -> [String] {
        guard let tools = raw["tools"] as? [Any], !tools.isEmpty else { return [] }
        let engine = self.engine
        let currentSettings = settings.current
        let modelDirectory = store.modelDirectory
        let result = Self.renderBreakingTools(tools) { subset in
            var probe: [String: Any] = [
                "model": SenClawModelIdentity.id,
                "messages": [["role": "user", "content": "probe"]],
                "tools": subset,
            ]
            _ = Self.filterUnrepresentableTools(&probe)
            let body = try JSONSerialization.data(withJSONObject: probe)
            let request = try JSONDecoder().decode(OpenAIChatRequest.self, from: body)
            let validated = try OpenAIRequestValidator.validate(
                request, modelID: SenClawModelIdentity.id)
            try BlockingBridge.run {
                try await engine.prepareProbe(validated, settings: currentSettings,
                                              modelDirectory: modelDirectory)
            }
        }
        if !result.isEmpty {
            Self.knownRenderBreakingTools.withLock { $0.formUnion(result) }
        }
        return result
    }

    /// Pure divide-and-conquer: `probe` throws when a subset fails to render;
    /// failing singletons are the culprits. Injectable for tests.
    static func renderBreakingTools(_ tools: [Any],
                                    probe: ([Any]) throws -> Void) -> [String] {
        func failing(_ subset: [Any]) -> [String] {
            guard !subset.isEmpty else { return [] }
            do {
                try probe(subset)
                return []
            } catch {
                if subset.count == 1 {
                    return [toolName(subset[0])]
                }
                let mid = subset.count / 2
                return failing(Array(subset[..<mid])) + failing(Array(subset[mid...]))
            }
        }
        return failing(tools)
    }

    static func toolName(_ tool: Any) -> String {
        (((tool as? [String: Any])?["function"] as? [String: Any])?["name"] as? String)
            ?? "(không tên)"
    }

    /// Run one validated turn, blocking until completion. Events are emitted
    /// one at a time from a single generation loop while the calling
    /// connection thread is parked on the bridge semaphore, so the
    /// non-Sendable `onEvent` closure is safe to hand across.
    ///
    /// `isCancelled` is checked ONLY at the generation-slot boundary: a turn
    /// whose client vanished while it waited in the queue did no work and is
    /// dropped there. A turn that was already admitted runs TO COMPLETION even
    /// if the client has gone — deliberately. The daemon's agent gives a cloud
    /// provider 180 s per turn and retries; a first agent turn on a cold
    /// prefix can exceed that in prefill alone. Finishing the abandoned turn
    /// commits the single-prefix KV cache, so the retry hits the cache and
    /// completes inside the budget. Cancelling instead would invalidate the
    /// cache and make every retry start from zero — the turn could never
    /// succeed. Writes to the dead socket are harmless no-ops.
    @discardableResult
    func generate(_ validated: ValidatedChatRequest,
                  isCancelled: @escaping () -> Bool,
                  onEvent: @escaping (ServerInferenceEvent) -> Void) throws -> ServerCompletion {
        let currentSettings = settings.current
        let modelDirectory = store.modelDirectory
        let engine = self.engine
        let eventBox = UncheckedSendableBox(onEvent)
        let cancelledBox = UncheckedSendableBox(isCancelled)

        return try BlockingBridge.run {
            try await engine.chat(
                validated,
                settings: currentSettings,
                modelDirectory: modelDirectory,
                isCancelled: { cancelledBox.value() }
            ) { event in
                eventBox.value(event)
            }
        }
    }
}

enum SenClawProviderError: Error, CustomStringConvertible {
    case modelNotInstalled

    var description: String {
        switch self {
        case .modelNotInstalled:
            "model chưa được cài — mở app TurboFieldfare trong SenClaw Space để tải về"
        }
    }
}
