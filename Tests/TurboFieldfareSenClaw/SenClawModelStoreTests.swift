import XCTest
import TurboFieldfareAppCore
@testable import TurboFieldfareSenClaw

final class SenClawModelStoreTests: XCTestCase {
    private func temporaryModelDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("senclaw-store-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("gemma4.gturbo", isDirectory: true)
    }

    func testEmptyDirectoryReportsMissingAndNotResumable() {
        let store = SenClawModelStore(modelDirectory: temporaryModelDirectory())
        XCTAssertEqual(store.installedStatus(), .missing)
        XCTAssertFalse(store.hasResumableCheckpoint)
        XCTAssertFalse(store.isInstalled)
        XCTAssertNil(store.installedSizeBytes())
    }

    func testResumableCheckpointIsDetected() throws {
        let modelDirectory = temporaryModelDirectory()
        let parent = modelDirectory.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }

        // The repacker's resume checkpoint sits beside the output directory.
        let checkpoint = parent.appendingPathComponent("gemma4.gturbo.resume.json")
        try Data("{}".utf8).write(to: checkpoint)

        XCTAssertTrue(SenClawModelStore(modelDirectory: modelDirectory).hasResumableCheckpoint)
    }

    func testDeleteInstalledRemovesTheTree() throws {
        let modelDirectory = temporaryModelDirectory()
        try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: modelDirectory.deletingLastPathComponent()) }
        try Data([1, 2, 3]).write(to: modelDirectory.appendingPathComponent("weights.bin"))

        let store = SenClawModelStore(modelDirectory: modelDirectory)
        // Size is only reported for a complete, verified install — a stray
        // tree (like this fixture) shows no size rather than a wrong one.
        XCTAssertNil(store.installedSizeBytes())
        try store.deleteInstalled()
        XCTAssertFalse(FileManager.default.fileExists(atPath: modelDirectory.path))
        // Deleting a directory that is already gone is not an error.
        XCTAssertNoThrow(try store.deleteInstalled())
    }

    func testInstallEventMapping() {
        XCTAssertEqual(
            SenClawModelStore.state(for: .copyingPayload(
                reusedBytes: 1, downloadedThisRunBytes: 2, totalBytes: 3)),
            .copyingPayload(reusedBytes: 1, downloadedThisRunBytes: 2, totalBytes: 3))
        XCTAssertEqual(SenClawModelStore.state(for: .hashingOutput("a.bin")),
                       .hashingOutput("a.bin"))
        let installed = URL(fileURLWithPath: "/tmp/x.gturbo")
        XCTAssertEqual(SenClawModelStore.state(for: .installed(installed)),
                       .installed(modelDirectory: installed))
    }

    func testInstallStateJSONCarriesProgressFields() {
        let json = SenClawRoutes.installStateJSON(.copyingPayload(
            reusedBytes: 10, downloadedThisRunBytes: 20, totalBytes: 100))
        XCTAssertEqual(json["phase"] as? String, "copying")
        XCTAssertEqual(json["reusedBytes"] as? UInt64, 10)
        XCTAssertEqual(json["downloadedThisRunBytes"] as? UInt64, 20)
        XCTAssertEqual(json["totalBytes"] as? UInt64, 100)

        XCTAssertEqual(
            SenClawRoutes.installStateJSON(.recoverable("mất mạng"))["message"] as? String,
            "mất mạng")
    }
}
