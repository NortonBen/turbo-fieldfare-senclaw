import XCTest
@testable import TurboFieldfareSenClaw

final class SenClawSettingsTests: XCTestCase {
    func testDefaultsValidate() throws {
        try SenClawAppSettings().validate()
    }

    func testPatchRoundTripsThroughDictionary() throws {
        var expected = SenClawAppSettings()
        expected.maxContextTokens = 8192
        expected.maxOutputTokens = 2048
        expected.expertCacheSlots = 24
        expected.expertCachePolicy = .lru
        expected.prefillEnabled = false
        expected.prefillChunkTokens = 64
        expected.rdadvisePolicy = .adaptive
        expected.promptCacheEnabled = false
        expected.queueLimit = 2
        expected.idleUnloadSeconds = 0

        let applied = SenClawAppSettings().applying(expected.dictionary)
        XCTAssertEqual(applied, expected)
        try applied.validate()
    }

    func testUnknownAndWrongTypedKeysAreIgnored() {
        let applied = SenClawAppSettings().applying([
            "maxContextTokens": "not-a-number",
            "somebodyElsesKey": true,
        ])
        XCTAssertEqual(applied, SenClawAppSettings())
    }

    func testRejectsContextOutsideAllowedSet() {
        var settings = SenClawAppSettings()
        settings.maxContextTokens = 5000
        XCTAssertThrowsError(try settings.validate())
    }

    func testRejectsOutputAboveContext() {
        var settings = SenClawAppSettings()
        settings.maxContextTokens = 4096
        settings.maxOutputTokens = 8192
        XCTAssertThrowsError(try settings.validate())
    }

    func testRejectsChunkedPrefillWithEightSlots() {
        // The same cross-flag rule the CLI and the server enforce at parse
        // time; without it the runtime traps at load instead of answering 400.
        var settings = SenClawAppSettings()
        settings.expertCacheSlots = 8
        settings.prefillEnabled = true
        XCTAssertThrowsError(try settings.validate())

        settings.prefillEnabled = false
        XCTAssertNoThrow(try settings.validate())
    }

    func testLoadKeyIgnoresFieldsThatDoNotShapeTheSession() {
        let directory = URL(fileURLWithPath: "/tmp/model.gturbo", isDirectory: true)
        var a = SenClawAppSettings()
        var b = a
        b.maxOutputTokens = 1024
        b.queueLimit = 8
        b.idleUnloadSeconds = 0
        XCTAssertEqual(a.loadKey(modelDirectory: directory), b.loadKey(modelDirectory: directory))

        a.maxContextTokens = 4096
        XCTAssertNotEqual(a.loadKey(modelDirectory: directory), b.loadKey(modelDirectory: directory))
    }

    // -- store -------------------------------------------------------------

    private func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("senclaw-settings-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("settings.json")
    }

    func testStorePersistsAcrossInstances() throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        let store = SenClawSettingsStore(fileURL: file)
        let updated = try store.update(["maxContextTokens": 8192, "queueLimit": 2])
        XCTAssertEqual(updated.maxContextTokens, 8192)

        let reloaded = SenClawSettingsStore(fileURL: file)
        XCTAssertEqual(reloaded.current.maxContextTokens, 8192)
        XCTAssertEqual(reloaded.current.queueLimit, 2)
    }

    func testStoreRejectsInvalidPatchAndKeepsOldValue() throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        let store = SenClawSettingsStore(fileURL: file)
        XCTAssertThrowsError(try store.update(["maxContextTokens": 5000]))
        XCTAssertEqual(store.current, SenClawAppSettings())
    }

    func testCorruptFileFallsBackToDefaults() throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{\"maxContextTokens\": 12345}".utf8).write(to: file)

        // Out-of-range persisted value must not crash the app at launch or
        // trap later in RuntimeConfiguration — defaults win.
        XCTAssertEqual(SenClawSettingsStore(fileURL: file).current, SenClawAppSettings())

        try Data("not json at all".utf8).write(to: file)
        XCTAssertEqual(SenClawSettingsStore(fileURL: file).current, SenClawAppSettings())
    }
}
