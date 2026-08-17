import Foundation
import TurboFieldfareAppCore
import TurboFieldfareServerCore

/// Owns the loaded `ServerModelSession` and serializes generations.
///
/// Load is lazy (first chat pays it), keyed by the settings that shape the
/// session; a key change releases the old session **before** constructing the
/// new one so two models are never resident at once — same rule the Mac app
/// enforces. `ServerCoordinator` provides the same admission behaviour as the
/// standalone OpenAI server: one generation at a time, a bounded queue behind
/// it.
///
/// Quiescence is tracked by `activeTurns`, counted from `chat()` entry to
/// exit. The coordinator's own `isActive` only flips once a turn is admitted
/// to the slot, which leaves a suspension window (session fetched, admission
/// pending) where an unload or reload deciding on coordinator state alone
/// would release a session that a turn is about to generate with.
actor SenClawEngine {
    struct Status: Sendable {
        var loaded: Bool
        var loading: Bool
        var busy: Bool
        var queuedCount: Int
        var loadedKeyMatches: Bool
        var lastError: String?
    }

    enum EngineError: Error, CustomStringConvertible {
        case busyGenerating
        case busyLoading

        var description: String {
            switch self {
            case .busyGenerating:
                "model đang bận sinh — đợi lượt hiện tại xong rồi thử lại"
            case .busyLoading:
                "model đang được nạp — đợi nạp xong rồi thử lại"
            }
        }
    }

    /// The queue limit the coordinator was built with. Settings can persist a
    /// different value, but it only takes effect on the next process launch —
    /// the API reports `restartRequired` from this.
    nonisolated let launchQueueLimit: Int

    private let coordinator: ServerCoordinator
    private var loadTask: Task<ServerModelSession, Error>?
    private var loadedKey: SenClawAppSettings.LoadKey?
    private var hasCompletedLoad = false
    /// Turns between `chat()` entry and exit — admission wait, prompt render,
    /// and generation included.
    private var activeTurns = 0
    private var lastUsed = Date()
    private var lastLoadError: String?

    init(queueLimit: Int) {
        self.launchQueueLimit = queueLimit
        self.coordinator = ServerCoordinator(queueLimit: queueLimit)
    }

    // -- generation --------------------------------------------------------

    func chat(_ request: ValidatedChatRequest,
              settings: SenClawAppSettings,
              modelDirectory: URL,
              isCancelled: @escaping @Sendable () -> Bool = { false },
              onEvent: @escaping @Sendable (ServerInferenceEvent) -> Void)
        async throws -> ServerCompletion {
        lastUsed = Date()
        activeTurns += 1
        defer {
            activeTurns -= 1
            lastUsed = Date()
        }
        let backend = try await backend(
            settings: settings, modelDirectory: modelDirectory, turnsHeldBySelf: 1)
        // Render the prompt before acquiring the generation slot, like the
        // standalone server's prepare path — queued turns should not pay for
        // each other's tokenization serially.
        let prepared = try await backend.prepare(request)
        return try await coordinator.run {
            // A client that disconnected while queued has nobody reading the
            // answer; drop it at the slot boundary instead of generating into
            // a void.
            if isCancelled() { throw CancellationError() }
            return try await backend.generate(prepared, onEvent: onEvent)
        }
    }

    /// Warm the model without generating (the UI's "Nạp" button).
    func ensureLoaded(settings: SenClawAppSettings, modelDirectory: URL) async throws {
        lastUsed = Date()
        _ = try await backend(settings: settings, modelDirectory: modelDirectory,
                              turnsHeldBySelf: 0)
    }

    // -- lifecycle ---------------------------------------------------------

    func unload() throws {
        guard loadTask != nil else { return }
        try releaseIfQuiescent(turnsHeldBySelf: 0)
    }

    /// Sweeper hook: drop the resident model after `idleSeconds` without a
    /// turn. Skips silently while busy; the next pass retries.
    func unloadIfIdle(idleSeconds: Int) {
        guard idleSeconds > 0, hasCompletedLoad else { return }
        guard Date().timeIntervalSince(lastUsed) >= TimeInterval(idleSeconds) else { return }
        try? unload()
    }

    /// Run `work` only while nothing is loaded, loading, or generating —
    /// atomically with that check, since both the check and the work happen on
    /// this actor. Used for deleting the model tree out from under the engine.
    func performWhileIdle<T: Sendable>(_ work: @Sendable () throws -> T) throws -> T {
        guard activeTurns == 0 else { throw EngineError.busyGenerating }
        guard loadTask == nil else {
            throw hasCompletedLoad ? EngineError.busyGenerating : EngineError.busyLoading
        }
        return try work()
    }

    func status(settings: SenClawAppSettings, modelDirectory: URL) async -> Status {
        Status(
            loaded: hasCompletedLoad,
            loading: loadTask != nil && !hasCompletedLoad,
            busy: activeTurns > 0,
            queuedCount: await coordinator.queuedCount,
            loadedKeyMatches: loadedKey == nil
                || loadedKey == settings.loadKey(modelDirectory: modelDirectory),
            lastError: lastLoadError)
    }

    // -- internals ---------------------------------------------------------

    /// Release the current session if no turn beyond the caller's own is in
    /// flight and no load is mid-way. `turnsHeldBySelf` is the caller's
    /// contribution to `activeTurns` (1 when called from inside `chat`).
    private func releaseIfQuiescent(turnsHeldBySelf: Int) throws {
        guard hasCompletedLoad else { throw EngineError.busyLoading }
        guard activeTurns == turnsHeldBySelf else { throw EngineError.busyGenerating }
        releaseSession()
    }

    private func backend(settings: SenClawAppSettings,
                         modelDirectory: URL,
                         turnsHeldBySelf: Int) async throws -> ServerModelSession {
        let key = settings.loadKey(modelDirectory: modelDirectory)
        if let task = loadTask, loadedKey == key {
            return try await task.value
        }
        if loadTask != nil {
            // A different key while a load is mid-flight or another turn is
            // running: refuse rather than let two sessions coexist.
            try releaseIfQuiescent(turnsHeldBySelf: turnsHeldBySelf)
        }

        let runtime = try settings.runtimeOptions()
            .resolvedRuntimeConfiguration(forceLogitsHead: true)
        let cacheMode: ServerPromptCacheMode = settings.promptCacheEnabled ? .singlePrefix : .off
        let maxContext = settings.maxContextTokens
        let directory = modelDirectory
        let task = Task {
            try await ServerModelSession.load(
                modelDirectory: directory,
                maxContext: maxContext,
                promptCacheMode: cacheMode,
                runtimeConfiguration: runtime)
        }
        loadTask = task
        loadedKey = key
        hasCompletedLoad = false
        lastLoadError = nil
        do {
            let session = try await task.value
            if loadedKey == key { hasCompletedLoad = true }
            return session
        } catch {
            if loadedKey == key {
                releaseSession()
                lastLoadError = String(describing: error)
            }
            throw error
        }
    }

    private func releaseSession() {
        loadTask = nil
        loadedKey = nil
        hasCompletedLoad = false
    }
}
