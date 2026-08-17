import Foundation
import Synchronization
import TurboFieldfareAppCore
import TurboFieldfareRepackCore

/// One installable model (the pinned Gemma checkpoint) and its lifecycle:
/// probe, download with resume, cancel, discard, delete.
///
/// All mutable state sits behind one mutex so the SDK's thread-per-connection
/// handlers can call in from any thread. The install itself runs on a `Task`
/// owned by `RepackModelInstallerClient`, which serializes competing installs
/// and persists a resume checkpoint after every committed range.
final class SenClawModelStore: Sendable {
    struct Snapshot: Sendable {
        var state: AppModelInstallState
        var installedStatus: AppModelInstallationStatus
        var resumable: Bool
    }

    let modelDirectory: URL
    let descriptor: AppModelInstallDescriptor
    private let installer: RepackModelInstallerClient
    private let state = Mutex<AppModelInstallState>(.idle)
    private let probeCache =
        Mutex<(status: AppModelInstallationStatus, sizeBytes: UInt64?, at: Date)?>(nil)
    private let installObservers = Mutex<[@Sendable () -> Void]>([])

    init(modelDirectory: URL,
         descriptor: AppModelInstallDescriptor = .default,
         installer: RepackModelInstallerClient? = nil) {
        self.modelDirectory = modelDirectory
        self.descriptor = descriptor
        self.installer = installer ?? RepackModelInstallerClient(descriptor: descriptor)
    }

    // -- observation -------------------------------------------------------

    /// Runs after every install that reaches `.installed` (used to publish the
    /// model list so the daemon's picker learns about the model).
    func onInstalled(_ observer: @escaping @Sendable () -> Void) {
        installObservers.withLock { $0.append(observer) }
    }

    // -- probing -----------------------------------------------------------

    /// Cached probe of the installed tree. The full probe re-hashes the
    /// manifest, re-validates the receipt, and (when complete) sizes the tree
    /// — cheap, but not per-request cheap with the UI polling every couple of
    /// seconds, so results stick for a few seconds.
    func installedStatus(maxAge: TimeInterval = 5) -> AppModelInstallationStatus {
        refreshProbe(maxAge: maxAge).status
    }

    private func refreshProbe(
        maxAge: TimeInterval
    ) -> (status: AppModelInstallationStatus, sizeBytes: UInt64?, at: Date) {
        if let cached = probeCache.withLock({ $0 }),
           Date().timeIntervalSince(cached.at) < maxAge {
            return cached
        }
        let status = AppModelInstallationProbe.status(at: modelDirectory, descriptor: descriptor)
        let size = status == .complete ? measureInstalledSizeBytes() : nil
        let fresh = (status, size, Date())
        probeCache.withLock { $0 = fresh }
        return fresh
    }

    func invalidateProbe() {
        probeCache.withLock { $0 = nil }
    }

    var isInstalled: Bool { installedStatus() == .complete }

    /// A saved partial download that `--resume` semantics would pick up.
    var hasResumableCheckpoint: Bool {
        guard let paths = try? RemoteInstallPaths(outputDirectory: modelDirectory.path) else {
            return false
        }
        return FileManager.default.fileExists(atPath: paths.checkpointFile)
    }

    func snapshot() -> Snapshot {
        Snapshot(state: state.withLock { $0 },
                 installedStatus: installedStatus(),
                 resumable: hasResumableCheckpoint)
    }

    /// Byte size of the installed tree, from the same few-second cache as the
    /// probe — the UI polls this and the value only changes on install/delete.
    func installedSizeBytes() -> UInt64? {
        refreshProbe(maxAge: 5).sizeBytes
    }

    private func measureInstalledSizeBytes() -> UInt64? {
        guard let enumerator = FileManager.default.enumerator(
            at: modelDirectory,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]) else { return nil }
        var total: UInt64 = 0
        var sawAnything = false
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            sawAnything = true
            total += UInt64(values.fileSize ?? 0)
        }
        return sawAnything ? total : nil
    }

    /// Disk-space requirement for a fresh or resumed install.
    func requirement() throws -> AppModelInstallRequirement {
        try installer.checkInstallRequirement(outputDirectory: modelDirectory)
    }

    // -- lifecycle ---------------------------------------------------------

    /// Kick off (or resume) the download. Returns false when an install is
    /// already running — the running one keeps going.
    @discardableResult
    func startInstall() -> Bool {
        let alreadyRunning = state.withLock { current -> Bool in
            if current.isInstalling { return true }
            current = .checking
            return false
        }
        if alreadyRunning { return false }

        let events = installer.installDefaultModel(outputDirectory: modelDirectory)
        Task { [self] in
            do {
                var lastState: AppModelInstallState = .checking
                for try await event in events {
                    lastState = Self.state(for: event)
                    state.withLock { current in
                        // A user-initiated cancel sticks until the stream
                        // terminates — progress events already in flight must
                        // not resurrect the cancellable UI.
                        if case .cancelling = current { return }
                        current = lastState
                    }
                }
                invalidateProbe()
                // The stream finished normally, so the outcome wins even over
                // a cancel that raced completion.
                state.withLock { $0 = lastState }
                if case .installed = lastState {
                    for observer in installObservers.withLock({ $0 }) { observer() }
                }
            } catch is CancellationError {
                invalidateProbe()
                state.withLock { $0 = .cancelled }
            } catch {
                invalidateProbe()
                let message = String(describing: error)
                let resumable = hasResumableCheckpoint
                state.withLock { $0 = resumable ? .recoverable(message) : .failed(message) }
            }
        }
        return true
    }

    func cancelInstall() {
        let installing = state.withLock { current -> Bool in
            guard current.canCancel else { return false }
            current = .cancelling
            return true
        }
        if installing { installer.cancel() }
    }

    /// Remove the saved partial download and checkpoint.
    func discardPartial() async throws {
        let busy = state.withLock { $0.isInstalling }
        guard !busy else {
            throw SenClawModelStoreError.busy("đang tải — hủy trước khi xoá bản tải dở")
        }
        try await installer.discardPartialInstall(outputDirectory: modelDirectory)
        invalidateProbe()
        state.withLock { $0 = .idle }
    }

    /// Delete the installed model tree.
    func deleteInstalled() throws {
        let busy = state.withLock { $0.isInstalling }
        guard !busy else {
            throw SenClawModelStoreError.busy("đang tải — không xoá được lúc này")
        }
        guard FileManager.default.fileExists(atPath: modelDirectory.path) else { return }
        try FileManager.default.removeItem(at: modelDirectory)
        invalidateProbe()
        state.withLock { $0 = .idle }
    }

    static func state(for event: AppModelInstallEvent) -> AppModelInstallState {
        switch event {
        case .checking: .checking
        case .downloadingMetadata: .downloadingMetadata
        case .planning: .planning
        case .reservingOutput: .reservingOutput
        case .copyingPayload(let reused, let downloaded, let total):
            .copyingPayload(reusedBytes: reused,
                            downloadedThisRunBytes: downloaded,
                            totalBytes: total)
        case .hashingOutput(let file): .hashingOutput(file)
        case .finalizing: .finalizing
        case .installed(let directory): .installed(modelDirectory: directory)
        }
    }
}

enum SenClawModelStoreError: Error, CustomStringConvertible {
    case busy(String)

    var description: String {
        switch self {
        case .busy(let message): message
        }
    }
}
