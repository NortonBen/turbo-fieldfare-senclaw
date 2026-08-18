import Foundation

/// Bridge the async engine into the SDK's synchronous, thread-per-connection
/// world.
///
/// `SenclawSpace` handlers run on their own plain `Thread` (never on the
/// cooperative pool), so parking that thread on a semaphore while a detached
/// task does the async work is safe — the same pattern the SDK's own
/// `SpaceClient` uses for its blocking HTTP calls.
enum BlockingBridge {
    /// Run `operation` to completion and return its value, blocking the
    /// calling thread. `register` receives a cancel handle so a disconnect
    /// observer can stop the work mid-flight.
    static func run<T: Sendable>(
        register: ((@escaping @Sendable () -> Void) -> Void)? = nil,
        _ operation: @escaping @Sendable () async throws -> T
    ) throws -> T {
        let box = ResultBox<T>()
        let semaphore = DispatchSemaphore(value: 0)
        let task = Task.detached {
            do {
                box.store(.success(try await operation()))
            } catch {
                box.store(.failure(error))
            }
            semaphore.signal()
        }
        register?({ task.cancel() })
        semaphore.wait()
        return try box.take().get()
    }
}

/// Holds one result across the semaphore. The signal/wait pair is the memory
/// barrier: the store strictly happens-before the take.
final class ResultBox<T>: @unchecked Sendable {
    private var value: Result<T, Error>?

    func store(_ result: Result<T, Error>) { value = result }

    func take() -> Result<T, Error> {
        value ?? .failure(CancellationError())
    }
}

/// A late-bound cancel handle: the event closure needs to cancel the very task
/// that runs it, so the handle is filled in right after creation.
final class TaskHandleBox: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelHandler: (@Sendable () -> Void)?
    private var cancelled = false

    func setCancel(_ handler: @escaping @Sendable () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        cancelHandler = handler
        if cancelled { handler() }
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
        cancelHandler?()
    }
}

/// Carries a non-Sendable SDK object (e.g. `ChunkSink`) into a `@Sendable`
/// event closure. Safe here because generation events are emitted one at a
/// time from a single generation loop while the connection thread is parked on
/// the bridge semaphore — there is never concurrent access.
final class UncheckedSendableBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

/// Fires exactly once across threads — for one-shot log lines from a
/// repeating watchdog tick.
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false

    /// True only on the first call.
    func trip() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if fired { return false }
        fired = true
        return true
    }
}
