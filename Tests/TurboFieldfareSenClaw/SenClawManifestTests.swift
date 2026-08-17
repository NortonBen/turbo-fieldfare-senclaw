import XCTest
import SenclawSpace
@testable import TurboFieldfareSenClaw

/// Pins the repo's own `senclaw-manifest.json` against the SDK validator and
/// the constants the Swift code assumes. A drifted manifest fails silently at
/// install time (the daemon ignores unknown values), so it fails loudly here
/// instead.
final class SenClawManifestTests: XCTestCase {
    private func repositoryRoot() -> URL {
        // Tests/TurboFieldfareSenClaw/SenClawManifestTests.swift → repo root.
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testManifestPassesSDKValidation() throws {
        let manifestPath = repositoryRoot().appendingPathComponent("senclaw-manifest.json").path
        let manifest = try loadManifest(manifestPath)
        XCTAssertEqual(validateManifest(manifest), [])
    }

    func testManifestAgreesWithTheBinaryContract() throws {
        let manifestPath = repositoryRoot().appendingPathComponent("senclaw-manifest.json").path
        let manifest = try loadManifest(manifestPath)

        XCTAssertEqual(manifest["id"] as? String, "turbo-fieldfare")

        let runtime = try XCTUnwrap(manifest["runtime"] as? [String: Any])
        XCTAssertEqual(runtime["start"] as? String, "./turbo-fieldfare-senclaw")
        XCTAssertEqual(runtime["healthPath"] as? String, "/health")
        // The default port the binary binds (SenClawDefaults.port, used by
        // main.swift) and the manifest must agree, or a by-hand run binds a
        // different port than the daemon expects.
        XCTAssertEqual(runtime["port"] as? Int, SenClawDefaults.port)
        XCTAssertEqual(runtime["mode"] as? String, "session")

        let llm = try XCTUnwrap(manifest["llm"] as? [String: Any])
        XCTAssertEqual(llm["path"] as? String, "/v1")
        XCTAssertEqual(llm["adapt"] as? String, "openai")
        XCTAssertEqual(llm["autoRegister"] as? Bool, true)
    }

    func testHubMetadataDeclaresTheDownloadHosts() throws {
        let hubPath = repositoryRoot().appendingPathComponent("senclaw-hub.json").path
        let data = try Data(contentsOf: URL(fileURLWithPath: hubPath))
        let hub = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        let permissions = try XCTUnwrap(hub["permissions"] as? [String: Any])
        let network = try XCTUnwrap(permissions["network"] as? [String])
        // The installer streams straight from HuggingFace; the permission
        // declaration users see before installing must say so.
        XCTAssertTrue(network.contains("huggingface.co"))
        XCTAssertTrue(network.contains("127.0.0.1"))

        let exec = try XCTUnwrap(permissions["exec"] as? [String])
        XCTAssertEqual(exec, ["./turbo-fieldfare-senclaw"])
    }
}
