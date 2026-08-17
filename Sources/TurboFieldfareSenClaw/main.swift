// TurboFieldfare as a SenClaw Space App.
//
// One process, one HTTP surface on the daemon-assigned PORT:
//
//   /health                     — answers before any weights are read; the
//                                 daemon health-gates a new app on 30 seconds,
//                                 and the model loads lazily on the first turn.
//   /v1/models, /v1/chat/…      — the OpenAI wire, rendered by SenclawSpace
//                                 from semantic events; inference itself is
//                                 TurboFieldfareServerCore, unchanged.
//   /api/model, /api/settings   — the management REST behind the web UI
//                                 (download with resume, load/unload, knobs).
//   /                           — the static UI in web/.
//
// The daemon reads `.senclaw/llm-models.json` while this app is stopped — a
// session app's resting state — so the model list is published at startup and
// after every completed install, and removed again after a delete.

import Foundation
import SenclawSpace
import TurboFieldfareAppCore
import TurboFieldfareServerCore

// The daemon captures stdout into the app's log endpoint; block buffering
// would hold messages back until exit.
setvbuf(stdout, nil, _IOLBF, 0)

let applicationDirectory = SenClawPaths.applicationDirectory()
let modelDirectory = SenClawPaths.modelDirectory()
let settingsStore = SenClawSettingsStore(
    fileURL: SenClawPaths.settingsFile(forModelDirectory: modelDirectory))
let modelStore = SenClawModelStore(modelDirectory: modelDirectory)
let engine = SenClawEngine(queueLimit: settingsStore.current.queueLimit)
let provider = SenClawProvider(store: modelStore, settings: settingsStore, engine: engine)
let memorySampler = AppMemorySampler()

func log(_ message: String) {
    print("[turbo-fieldfare] \(message)")
}

/// Keep the on-disk model list in step with reality. Publishing an empty list
/// is refused by the SDK, so after a delete the cache file is removed instead —
/// the daemon treats "no cache" as "not known yet".
let republishModels: @Sendable () -> Void = {
    let cacheURL = applicationDirectory.appendingPathComponent(MODELS_CACHE_PATH)
    if modelStore.isInstalled {
        do {
            try publishModels(applicationDirectory.path,
                              [SenClawProvider.card(settings: settingsStore.current)])
            log("đã cập nhật \(MODELS_CACHE_PATH)")
        } catch {
            log("không ghi được danh sách model: \(error)")
        }
    } else if FileManager.default.fileExists(atPath: cacheURL.path) {
        try? FileManager.default.removeItem(at: cacheURL)
        log("đã gỡ \(MODELS_CACHE_PATH) (model chưa cài)")
    }
}

modelStore.onInstalled(republishModels)
republishModels()

// Drop the resident model when the process stays alive without real turns —
// settings-page traffic alone keeps a session app running, and ~1.6 GB of
// warm weights should not sit behind an idle browser tab.
Thread.detachNewThread {
    while true {
        Thread.sleep(forTimeInterval: 15)
        let idleSeconds = settingsStore.current.idleUnloadSeconds
        guard idleSeconds > 0 else { continue }
        try? BlockingBridge.run {
            await engine.unloadIfIdle(idleSeconds: idleSeconds)
        }
    }
}

// Own SIGTERM/SIGINT handling, installed BEFORE `Serve`. The vendored SDK
// installs its own dispatch sources, but it keeps them alive with `_ =
// sources`, whose lifetime the release optimizer is free to end immediately —
// leaving only the SIG_IGN it set first, so a release build never dies to
// SIGTERM. `ServerTerminationSignals` (the standalone server's helper) retains
// its sources in an actor property, which is immune to that.
//
// The installer's cancel is asynchronous: `cancelInstall()` only flags the
// task. The daemon allows two seconds between SIGTERM and SIGKILL, so wait —
// bounded well under that — for the install task to observe the cancel and
// wind down (its resume checkpoint is committed after every range; the wait
// lets an in-flight commit and temp-file cleanup finish) before exiting.
let terminationSignals = ServerTerminationSignals()
Task.detached {
    let signalNumber = await terminationSignals.wait()
    // write(2) straight to stderr: stdio buffers race the exit below.
    FileHandle.standardError.write(
        Data("[turbo-fieldfare] signal \(signalNumber) — dừng app (bản tải dở được giữ để tiếp tục)\n".utf8))
    let wasInstalling = modelStore.snapshot().state.isInstalling
    modelStore.cancelInstall()
    if wasInstalling {
        for _ in 0..<12 where modelStore.snapshot().state.isInstalling {
            usleep(100_000)
        }
    }
    exit(0)
}

var routes = llmRoutes(provider)
let managementRoutes = SenClawRoutes.build(SenClawRoutes.Context(
    store: modelStore,
    settings: settingsStore,
    engine: engine,
    memory: memorySampler,
    republishModels: republishModels))
routes.merge(managementRoutes) { _, management in management }

log("model dir: \(modelDirectory.path)")
log("app dir:   \(applicationDirectory.path)")

do {
    try Serve(Config(
        routes: routes,
        healthPath: "/health",
        staticDir: SenClawPaths.webDirectory(applicationDirectory: applicationDirectory).path,
        onShutdown: {
            // The SDK's own signal path (when it survives — see the note on
            // `terminationSignals`). Cancel here too; the wait below gives the
            // installer its wind-down before the process ends.
            modelStore.cancelInstall()
        },
        defaultPort: SenClawDefaults.port,
        requireAppToken: true,
        log: { log($0) }
    ))
    for _ in 0..<12 where modelStore.snapshot().state.isInstalling {
        usleep(100_000)
    }
} catch {
    FileHandle.standardError.write(Data("[turbo-fieldfare] fatal: \(error)\n".utf8))
    exit(1)
}
