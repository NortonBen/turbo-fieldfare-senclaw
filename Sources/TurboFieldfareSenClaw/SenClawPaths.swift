import Foundation

/// Constants the manifest and the binary must agree on. The manifest test
/// asserts against these, so drift between `senclaw-manifest.json` and the
/// code fails a test instead of surfacing as a by-hand run binding the wrong
/// port.
enum SenClawDefaults {
    /// `runtime.port` in senclaw-manifest.json; used when `PORT` is unset.
    static let port = 4841
}

/// Where the SenClaw app keeps its pieces on disk.
///
/// The model directory deliberately matches the Mac app's default
/// (`~/Library/Application Support/TurboFieldfare/gemma4.gturbo`) so one
/// download serves both products, and settings live NEXT to the model — not in
/// the app directory, which a SenClaw update replaces wholesale.
enum SenClawPaths {
    static let modelDirectoryEnvironmentKey = "TURBO_FIELDFARE_MODEL_DIR"

    /// The installed `.gturbo` directory this app manages.
    static func modelDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        currentDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath,
                                    isDirectory: true),
        homeApplicationSupport: URL? = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false),
        fileExists: (String) -> Bool = FileManager.default.fileExists(atPath:)
    ) -> URL {
        if let explicit = environment[modelDirectoryEnvironmentKey]?
            .trimmingCharacters(in: .whitespaces), !explicit.isEmpty {
            if explicit.hasPrefix("/") {
                return URL(fileURLWithPath: explicit, isDirectory: true).standardizedFileURL
            }
            return currentDirectory.appendingPathComponent(explicit, isDirectory: true)
                .standardizedFileURL
        }
        // Development convenience: a checkout of this package uses the same
        // scratch model the Mac app and CLI use.
        let packageMarker = currentDirectory.appendingPathComponent("Package.swift").path
        let sourcesMarker = currentDirectory
            .appendingPathComponent("Sources/TurboFieldfareSenClaw", isDirectory: true).path
        if fileExists(packageMarker), fileExists(sourcesMarker) {
            return currentDirectory.appendingPathComponent("scratch/gemma4.gturbo", isDirectory: true)
                .standardizedFileURL
        }
        let support = homeApplicationSupport ?? FileManager.default.homeDirectoryForCurrentUser
        return support
            .appendingPathComponent("TurboFieldfare", isDirectory: true)
            .appendingPathComponent("gemma4.gturbo", isDirectory: true)
            .standardizedFileURL
    }

    /// Settings sit beside the model directory so they survive app reinstalls
    /// and updates: `<parent of model dir>/senclaw-app-settings.json`.
    static func settingsFile(forModelDirectory modelDirectory: URL) -> URL {
        modelDirectory.deletingLastPathComponent()
            .appendingPathComponent("senclaw-app-settings.json", isDirectory: false)
    }

    /// The app's own directory: where `senclaw-manifest.json`, `web/`, and the
    /// `.senclaw/llm-models.json` cache live. The daemon launches the binary
    /// with the app directory as the working directory; running by hand from a
    /// package checkout resolves the checkout root; as a last resort, the
    /// executable's directory (the zip layout puts the binary at the root).
    static func applicationDirectory(
        currentDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath,
                                    isDirectory: true),
        executableURL: URL? = Bundle.main.executableURL,
        fileExists: (String) -> Bool = FileManager.default.fileExists(atPath:)
    ) -> URL {
        let manifest = "senclaw-manifest.json"
        if fileExists(currentDirectory.appendingPathComponent(manifest).path) {
            return currentDirectory.standardizedFileURL
        }
        if let executableDirectory = executableURL?.deletingLastPathComponent(),
           fileExists(executableDirectory.appendingPathComponent(manifest).path) {
            return executableDirectory.standardizedFileURL
        }
        return currentDirectory.standardizedFileURL
    }

    /// The static UI directory served at `/`.
    static func webDirectory(applicationDirectory: URL) -> URL {
        applicationDirectory.appendingPathComponent("web", isDirectory: true)
    }
}
