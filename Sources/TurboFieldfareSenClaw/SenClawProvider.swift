import Foundation
import SenclawSpace
import TurboFieldfareAppCore
import TurboFieldfareServerCore

/// The one model this app serves. The wire id matches the standalone
/// `TurboFieldfareServer` default so clients configured against either agree.
enum SenClawModelIdentity {
    static let id = "gemma-4-26b-a4b-it"
    static let displayName = "Gemma 4 26B A4B · TurboFieldfare"
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

    func chat(_ req: ChatRequest, _ sink: ChunkSink) throws {
        try chatRaw(req.raw, emit: { sink.send($0) }, isClosed: { sink.isClosed })
    }

    /// The whole turn, expressed against plain values so it is testable
    /// without the SDK's server-owned `ChatRequest`/`ChunkSink` types (their
    /// initializers are internal to the SDK on purpose).
    func chatRaw(_ raw: [String: Any],
                 emit: @escaping (Chunk) -> Void,
                 isClosed: @escaping () -> Bool) throws {
        guard store.installedStatus() == .complete else {
            throw SenclawError(
                "model chưa được cài — mở app TurboFieldfare trong SenClaw Space để tải về")
        }

        let openAIRequest: OpenAIChatRequest
        do {
            let body = try JSONSerialization.data(withJSONObject: raw)
            openAIRequest = try JSONDecoder().decode(OpenAIChatRequest.self, from: body)
        } catch {
            throw SenclawError("request không đúng dạng OpenAI chat.completions: \(error)")
        }

        let validated: ValidatedChatRequest
        do {
            validated = try OpenAIRequestValidator.validate(
                openAIRequest, modelID: SenClawModelIdentity.id)
        } catch let error as ServerRequestError {
            throw SenclawError(error.envelope.error.message)
        }

        let currentSettings = settings.current
        let modelDirectory = store.modelDirectory
        let engine = self.engine
        // Events are emitted one at a time from a single generation loop while
        // the connection thread is parked on the bridge semaphore, so handing
        // the non-Sendable closures across is safe.
        let emitBox = UncheckedSendableBox(emit)
        let closedBox = UncheckedSendableBox(isClosed)
        let taskHandle = TaskHandleBox()

        let completion: ServerCompletion
        do {
            completion = try BlockingBridge.run(register: { taskHandle.setCancel($0) }) {
                try await engine.chat(
                    validated,
                    settings: currentSettings,
                    modelDirectory: modelDirectory,
                    // Note the limits of `isClosed`: the SDK only learns of a
                    // disconnect after a WRITE fails, so a turn that has not
                    // streamed anything yet (long prefill, non-stream mode)
                    // cannot see it. This still stops queued turns whose
                    // stream already broke. See docs/SENCLAW_APP.md.
                    isCancelled: { closedBox.value() }
                ) { event in
                    // A disconnected client stops the generation instead of
                    // finishing into a void; the runtime's cancellation checks
                    // pick this up between tokens.
                    if closedBox.value() {
                        taskHandle.cancel()
                        return
                    }
                    switch event {
                    case .content(let text):
                        emitBox.value(.text(text))
                    case .toolCall(let call):
                        emitBox.value(.toolCall(id: call.id,
                                                name: call.name,
                                                arguments: call.argumentsJSON))
                    }
                }
            }
        } catch let error as ServerRequestError {
            throw SenclawError(error.envelope.error.message)
        } catch is CancellationError {
            // Client went away; the SDK treats a throw after streamed events
            // as an early end, which is exactly right here.
            throw SenclawError("generation đã bị hủy")
        }

        emit(.usage(promptTokens: completion.usage.promptTokens,
                    completionTokens: completion.usage.completionTokens))
    }
}
