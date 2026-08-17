import Foundation
import Synchronization
import TurboFieldfare
import TurboFieldfareAppCore

/// User-adjustable knobs for the SenClaw app, persisted as JSON beside the
/// model directory. Values mirror what `TurboFieldfareServer` accepts on its
/// command line; validation reuses the same allowed sets so both products
/// refuse the same inputs.
struct SenClawAppSettings: Equatable, Sendable {
    static let allowedContextTokens = [4096, 8192, 16384, 32768, 65536]
    static let allowedExpertCacheSlots = Array(AppRuntimeOptions.allowedSlotCounts)
    static let allowedPrefillChunkTokens = Array(AppRuntimeOptions.allowedPrefillChunkTokens)
    static let queueLimitRange = 1...16

    var maxContextTokens = 16384
    /// Advertised as the model card's `max_output_tokens`, which the SenClaw
    /// agent copies verbatim into every request's `max_tokens`. This is
    /// therefore the per-turn decode ceiling: at ~20-40 tok/s on a 26B model,
    /// a runaway completion at 32K would hold the generation slot for many
    /// minutes and blow the agent's per-turn budget. 4096 bounds the worst
    /// case to a couple of minutes while staying plenty for chat and tools.
    var maxOutputTokens = 4096
    var expertCacheSlots = 16
    var expertCachePolicy = AppExpertCachePolicy.lfu
    var prefillEnabled = true
    var prefillChunkTokens = 128
    var rdadvisePolicy = AppRDAdvicePolicy.off
    var promptCacheEnabled = true
    var queueLimit = 4
    /// Drop the resident model after this many idle seconds while the process
    /// stays alive (UI traffic keeps a session app running). 0 keeps it loaded
    /// until the daemon stops the process.
    var idleUnloadSeconds = 600
    /// Warm the model in the background as soon as the app starts (and right
    /// after an install finishes), so the first turn does not pay the load.
    /// Paired with `idleUnloadSeconds`, this is the auto load/release cycle.
    var autoWarmEnabled = true

    func validate() throws {
        guard Self.allowedContextTokens.contains(maxContextTokens) else {
            throw SenClawSettingsError.invalid(
                "maxContextTokens phải là một trong \(Self.allowedContextTokens)")
        }
        guard maxOutputTokens >= 1, maxOutputTokens <= maxContextTokens else {
            throw SenClawSettingsError.invalid(
                "maxOutputTokens phải trong khoảng 1...\(maxContextTokens)")
        }
        guard Self.queueLimitRange.contains(queueLimit) else {
            throw SenClawSettingsError.invalid("queueLimit phải trong khoảng \(Self.queueLimitRange)")
        }
        guard idleUnloadSeconds >= 0 else {
            throw SenClawSettingsError.invalid("idleUnloadSeconds không được âm")
        }
        // Same cross-flag rule the CLI and server enforce at parse time; the
        // runtime scheduler needs the head-room, and validating here keeps the
        // failure a 400 instead of a trap at load.
        if prefillEnabled,
           expertCacheSlots < RuntimeConfiguration.minimumExpertCacheSlotsForChunkedPrefill {
            throw SenClawSettingsError.invalid(
                "prefill theo chunk cần expertCacheSlots ≥ "
                    + "\(RuntimeConfiguration.minimumExpertCacheSlotsForChunkedPrefill) — "
                    + "tắt prefill hoặc tăng slot")
        }
        // Slots / policy / prefill / rdadvise share AppRuntimeOptions rules.
        try runtimeOptions().validate()
    }

    func runtimeOptions() -> AppRuntimeOptions {
        AppRuntimeOptions(
            expertCacheSlots: expertCacheSlots,
            expertCachePolicy: expertCachePolicy,
            prefillEnabled: prefillEnabled,
            prefillChunkTokens: prefillChunkTokens,
            rdadvisePolicy: rdadvisePolicy)
    }

    /// The fields whose change requires releasing and reloading the model.
    struct LoadKey: Equatable, Sendable {
        let modelDirectoryPath: String
        let maxContextTokens: Int
        let expertCacheSlots: Int
        let expertCachePolicy: AppExpertCachePolicy
        let prefillEnabled: Bool
        let prefillChunkTokens: Int
        let rdadvisePolicy: AppRDAdvicePolicy
        let promptCacheEnabled: Bool
    }

    func loadKey(modelDirectory: URL) -> LoadKey {
        LoadKey(
            modelDirectoryPath: modelDirectory.standardizedFileURL.path,
            maxContextTokens: maxContextTokens,
            expertCacheSlots: expertCacheSlots,
            expertCachePolicy: expertCachePolicy,
            prefillEnabled: prefillEnabled,
            prefillChunkTokens: prefillChunkTokens,
            rdadvisePolicy: rdadvisePolicy,
            promptCacheEnabled: promptCacheEnabled)
    }

    // -- wire shape --------------------------------------------------------

    var dictionary: [String: Any] {
        [
            "maxContextTokens": maxContextTokens,
            "maxOutputTokens": maxOutputTokens,
            "expertCacheSlots": expertCacheSlots,
            "expertCachePolicy": expertCachePolicy.rawValue,
            "prefillEnabled": prefillEnabled,
            "prefillChunkTokens": prefillChunkTokens,
            "rdadvisePolicy": rdadvisePolicy.rawValue,
            "promptCacheEnabled": promptCacheEnabled,
            "queueLimit": queueLimit,
            "idleUnloadSeconds": idleUnloadSeconds,
            "autoWarmEnabled": autoWarmEnabled,
        ]
    }

    /// Apply a partial update (UI sends only known keys). Unknown keys are
    /// ignored; wrong types surface as validation errors afterwards.
    func applying(_ patch: [String: Any]) -> SenClawAppSettings {
        var next = self
        if let v = intValue(patch["maxContextTokens"]) { next.maxContextTokens = v }
        if let v = intValue(patch["maxOutputTokens"]) { next.maxOutputTokens = v }
        if let v = intValue(patch["expertCacheSlots"]) { next.expertCacheSlots = v }
        if let raw = patch["expertCachePolicy"] as? String,
           let v = AppExpertCachePolicy(rawValue: raw) { next.expertCachePolicy = v }
        if let v = patch["prefillEnabled"] as? Bool { next.prefillEnabled = v }
        if let v = intValue(patch["prefillChunkTokens"]) { next.prefillChunkTokens = v }
        if let raw = patch["rdadvisePolicy"] as? String,
           let v = AppRDAdvicePolicy(rawValue: raw) { next.rdadvisePolicy = v }
        if let v = patch["promptCacheEnabled"] as? Bool { next.promptCacheEnabled = v }
        if let v = intValue(patch["queueLimit"]) { next.queueLimit = v }
        if let v = intValue(patch["idleUnloadSeconds"]) { next.idleUnloadSeconds = v }
        if let v = patch["autoWarmEnabled"] as? Bool { next.autoWarmEnabled = v }
        return next
    }

    private func intValue(_ value: Any?) -> Int? {
        if let n = value as? Int { return n }
        if let n = value as? NSNumber { return n.intValue }
        return nil
    }
}

enum SenClawSettingsError: Error, CustomStringConvertible {
    case invalid(String)

    var description: String {
        switch self {
        case .invalid(let message): message
        }
    }
}

/// Lock-guarded settings holder with an atomic on-disk copy.
///
/// Reads never touch the disk after init; writes go tmp + rename so a killed
/// process (the daemon SIGKILLs two seconds after SIGTERM) can never leave a
/// truncated file behind.
final class SenClawSettingsStore: Sendable {
    private let state: Mutex<SenClawAppSettings>
    let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
        self.state = Mutex(Self.load(from: fileURL))
    }

    var current: SenClawAppSettings {
        state.withLock { $0 }
    }

    @discardableResult
    func update(_ patch: [String: Any]) throws -> SenClawAppSettings {
        let next = current.applying(patch)
        try next.validate()
        try persist(next)
        state.withLock { $0 = next }
        return next
    }

    private func persist(_ settings: SenClawAppSettings) throws {
        let data = try JSONSerialization.data(
            withJSONObject: settings.dictionary, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        // `.atomic` is write-to-temp-then-rename — the same guarantee the Mac
        // app's settings store relies on.
        try data.write(to: fileURL, options: .atomic)
    }

    private static func load(from fileURL: URL) -> SenClawAppSettings {
        guard let data = try? Data(contentsOf: fileURL),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            return SenClawAppSettings()
        }
        let loaded = SenClawAppSettings().applying(dictionary)
        // A hand-edited file with out-of-range values falls back to defaults
        // rather than crashing the app at launch or trapping deep in the
        // runtime configuration.
        return (try? loaded.validate()) != nil ? loaded : SenClawAppSettings()
    }
}
