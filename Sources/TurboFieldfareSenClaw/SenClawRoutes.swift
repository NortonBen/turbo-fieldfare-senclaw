import Foundation
import SenclawSpace
import TurboFieldfareAppCore
import TurboFieldfareServerCore

/// REST surface behind the app's web UI. Everything here is loopback-only and
/// (when the daemon runs with app tokens on) reachable only through the
/// daemon's proxy.
enum SenClawRoutes {
    struct Context {
        let store: SenClawModelStore
        let settings: SenClawSettingsStore
        let engine: SenClawEngine
        let memory: AppMemorySampler
        /// Re-publishes the `.senclaw/llm-models.json` cache (or removes it
        /// after a delete) so the daemon's picker stays truthful.
        let republishModels: @Sendable () -> Void
        /// Kicks a background model warm-up when auto-warm is on and the
        /// model is installed. Safe to call redundantly.
        let warmModel: @Sendable () -> Void
    }

    static func build(_ context: Context) -> [RouteKey: Handler] {
        let store = context.store
        let settings = context.settings
        let engine = context.engine

        var routes: [RouteKey: Handler] = [:]

        routes[RouteKey("GET", "/api/model")] = { _ in
            modelStatusResponse(context)
        }

        routes[RouteKey("POST", "/api/model/install")] = { _ in
            if store.snapshot().installedStatus == .complete {
                return Response(json: ["error": "model đã được cài"], status: 409)
            }
            if let requirement = try? store.requirement(), !requirement.canInstall {
                return Response(json: [
                    "error": "không đủ dung lượng trống",
                    "requiredBytes": requirement.requiredBytes,
                    "availableBytes": requirement.availableBytes,
                ], status: 409)
            }
            let started = store.startInstall()
            return Response(json: ["started": started], status: 202)
        }

        routes[RouteKey("POST", "/api/model/cancel")] = { _ in
            store.cancelInstall()
            return Response(json: ["ok": true])
        }

        routes[RouteKey("POST", "/api/model/discard")] = { _ in
            do {
                try BlockingBridge.run { try await store.discardPartial() }
                return Response(json: ["ok": true])
            } catch {
                return Response(json: ["error": "\(error)"], status: 409)
            }
        }

        routes[RouteKey("DELETE", "/api/model")] = { _ in
            do {
                // Run the delete on the engine actor so the idle check and the
                // removal are atomic against a load or chat starting.
                try BlockingBridge.run {
                    try await engine.performWhileIdle { try store.deleteInstalled() }
                }
                context.republishModels()
                return Response(json: ["ok": true])
            } catch {
                return Response(json: ["error": "\(error)"], status: 409)
            }
        }

        routes[RouteKey("POST", "/api/model/load")] = { _ in
            guard store.isInstalled else {
                return Response(json: ["error": "model chưa được cài"], status: 409)
            }
            let current = settings.current
            let directory = store.modelDirectory
            Task.detached {
                do {
                    try await engine.ensureLoaded(settings: current, modelDirectory: directory)
                } catch {
                    FileHandle.standardError.write(
                        Data("[turbo-fieldfare] load failed: \(error)\n".utf8))
                }
            }
            return Response(json: ["started": true], status: 202)
        }

        routes[RouteKey("POST", "/api/model/unload")] = { _ in
            do {
                try BlockingBridge.run { try await engine.unload() }
                return Response(json: ["ok": true])
            } catch {
                return Response(json: ["error": "\(error)"], status: 409)
            }
        }

        routes[RouteKey("GET", "/api/settings")] = { _ in
            settingsResponse(context)
        }

        routes[RouteKey("PUT", "/api/settings")] = { request in
            guard let body = (try? request.json()) as? [String: Any] else {
                return Response(json: ["error": "body phải là JSON object"], status: 400)
            }
            do {
                _ = try settings.update(body)
                context.republishModels()
                // Toggling auto-warm on should take effect now, not at the
                // next app launch.
                context.warmModel()
                return settingsResponse(context)
            } catch {
                return Response(json: ["error": "\(error)"], status: 400)
            }
        }

        return routes
    }

    // -- responses ---------------------------------------------------------

    private static func statusSnapshot(_ context: Context) -> SenClawEngine.Status {
        let current = context.settings.current
        let directory = context.store.modelDirectory
        let engine = context.engine
        return (try? BlockingBridge.run {
            await engine.status(settings: current, modelDirectory: directory)
        }) ?? SenClawEngine.Status(
            loaded: false, loading: false, busy: false,
            queuedCount: 0, loadedKeyMatches: true, lastError: nil)
    }

    private static func modelStatusResponse(_ context: Context) -> Response {
        let store = context.store
        let snapshot = store.snapshot()
        let engineStatus = statusSnapshot(context)
        let descriptor = store.descriptor

        var payload: [String: Any] = [
            "modelId": SenClawModelIdentity.id,
            "displayName": descriptor.displayName,
            "repo": descriptor.repoID,
            "revision": descriptor.revision,
            "path": store.modelDirectory.path,
            "installedBytes": descriptor.installedBytes,
            "install": installStateJSON(snapshot.state),
            "resumable": snapshot.resumable,
            "engine": [
                "loaded": engineStatus.loaded,
                "loading": engineStatus.loading,
                "busy": engineStatus.busy,
                "queued": engineStatus.queuedCount,
                "reloadRequired": engineStatus.loaded && !engineStatus.loadedKeyMatches,
                "lastError": engineStatus.lastError as Any,
                "memoryBytes": context.memory.sample() as Any,
            ],
        ]

        switch snapshot.installedStatus {
        case .complete:
            payload["installed"] = true
            if let size = store.installedSizeBytes() { payload["sizeBytes"] = size }
        case .partial(let reason):
            payload["installed"] = false
            payload["partialReason"] = reason
        case .missing:
            payload["installed"] = false
        }

        // The requirement gates the Install button, so it only matters while
        // idle — and computing it re-reads the resume checkpoint, which grows
        // with completed ranges during a download.
        if snapshot.installedStatus != .complete, !snapshot.state.isInstalling {
            if let requirement = try? store.requirement() {
                payload["requirement"] = [
                    "requiredBytes": requirement.requiredBytes,
                    "availableBytes": requirement.availableBytes,
                    "canInstall": requirement.canInstall,
                ]
            }
        }

        return Response(json: payload)
    }

    private static func settingsResponse(_ context: Context) -> Response {
        let engineStatus = statusSnapshot(context)
        let current = context.settings.current
        return Response(json: [
            "settings": current.dictionary,
            "allowed": [
                "maxContextTokens": SenClawAppSettings.allowedContextTokens,
                "expertCacheSlots": SenClawAppSettings.allowedExpertCacheSlots,
                "prefillChunkTokens": SenClawAppSettings.allowedPrefillChunkTokens,
                "expertCachePolicy": AppExpertCachePolicy.allCases.map(\.rawValue),
                "rdadvisePolicy": AppRDAdvicePolicy.allCases.map(\.rawValue),
            ],
            "reloadRequired": engineStatus.loaded && !engineStatus.loadedKeyMatches,
            // The coordinator's queue limit is fixed at launch; a persisted
            // change is real but waits for the daemon to restart the app.
            "restartRequired": current.queueLimit != context.engine.launchQueueLimit,
        ])
    }

    static func installStateJSON(_ state: AppModelInstallState) -> [String: Any] {
        switch state {
        case .idle:
            ["phase": "idle"]
        case .checking:
            ["phase": "checking"]
        case .downloadingMetadata:
            ["phase": "downloadingMetadata"]
        case .planning:
            ["phase": "planning"]
        case .reservingOutput:
            ["phase": "reservingOutput"]
        case .copyingPayload(let reused, let downloaded, let total):
            [
                "phase": "copying",
                "reusedBytes": reused,
                "downloadedThisRunBytes": downloaded,
                "totalBytes": total,
            ]
        case .hashingOutput(let file):
            ["phase": "hashing", "file": file]
        case .finalizing:
            ["phase": "finalizing"]
        case .cancelling:
            ["phase": "cancelling"]
        case .discarding:
            ["phase": "discarding"]
        case .cancelled:
            ["phase": "cancelled"]
        case .recoverable(let message):
            ["phase": "recoverable", "message": message]
        case .installed:
            ["phase": "installed"]
        case .failed(let message):
            ["phase": "failed", "message": message]
        }
    }
}
