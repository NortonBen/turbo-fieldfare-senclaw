import XCTest
@testable import TurboFieldfareAppCore
@testable import TurboFieldfareSenClaw

final class SenClawPathsTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/example/Library/Application Support",
                           isDirectory: true)
    private let cwd = URL(fileURLWithPath: "/work/app", isDirectory: true)

    func testEnvironmentOverrideWinsAndResolvesRelativePaths() {
        let absolute = SenClawPaths.modelDirectory(
            environment: ["TURBO_FIELDFARE_MODEL_DIR": "/models/g.gturbo"],
            currentDirectory: cwd,
            homeApplicationSupport: home,
            fileExists: { _ in false })
        XCTAssertEqual(absolute.path, "/models/g.gturbo")

        let relative = SenClawPaths.modelDirectory(
            environment: ["TURBO_FIELDFARE_MODEL_DIR": "local/g.gturbo"],
            currentDirectory: cwd,
            homeApplicationSupport: home,
            fileExists: { _ in false })
        XCTAssertEqual(relative.path, "/work/app/local/g.gturbo")
    }

    func testPackageCheckoutUsesScratchModel() {
        let checkout = URL(fileURLWithPath: "/repo", isDirectory: true)
        let resolved = SenClawPaths.modelDirectory(
            environment: [:],
            currentDirectory: checkout,
            homeApplicationSupport: home,
            fileExists: { path in
                path == "/repo/Package.swift" || path == "/repo/Sources/TurboFieldfareSenClaw"
            })
        XCTAssertEqual(resolved.path, "/repo/scratch/gemma4.gturbo")
    }

    func testFallsBackToSharedApplicationSupportLocation() {
        let resolved = SenClawPaths.modelDirectory(
            environment: [:],
            currentDirectory: cwd,
            homeApplicationSupport: home,
            fileExists: { _ in false })
        XCTAssertEqual(
            resolved.path,
            "/Users/example/Library/Application Support/TurboFieldfare/gemma4.gturbo")
    }

    func testSharedFallbackMatchesTheMacAppResolver() {
        // "One download serves both products" only holds while this resolver
        // and the Mac app's internal AppModelLocation agree on the shared
        // Application Support location. This pins the agreement so an upstream
        // rename fails a test here instead of silently forking two 14 GB
        // model trees.
        let support = URL(fileURLWithPath: "/Users/example/Library/Application Support",
                          isDirectory: true)
        let macApp = AppModelLocation.resolve(
            explicitURL: nil,
            executableURL: nil,
            currentDirectoryURL: URL(fileURLWithPath: "/nowhere", isDirectory: true),
            applicationSupportURL: support,
            fileExists: { _ in false })
        let senClaw = SenClawPaths.modelDirectory(
            environment: [:],
            currentDirectory: URL(fileURLWithPath: "/nowhere", isDirectory: true),
            homeApplicationSupport: support,
            fileExists: { _ in false })
        XCTAssertEqual(senClaw.path, macApp.path)
    }

    func testSettingsFileSitsBesideTheModelDirectory() {
        let model = URL(fileURLWithPath: "/x/TurboFieldfare/gemma4.gturbo", isDirectory: true)
        XCTAssertEqual(
            SenClawPaths.settingsFile(forModelDirectory: model).path,
            "/x/TurboFieldfare/senclaw-app-settings.json")
    }

    func testApplicationDirectoryPrefersWorkingDirectoryWithManifest() {
        let exe = URL(fileURLWithPath: "/opt/apps/turbo/turbo-fieldfare-senclaw")
        let byCwd = SenClawPaths.applicationDirectory(
            currentDirectory: cwd,
            executableURL: exe,
            fileExists: { $0 == "/work/app/senclaw-manifest.json" })
        XCTAssertEqual(byCwd.path, "/work/app")

        let byExe = SenClawPaths.applicationDirectory(
            currentDirectory: cwd,
            executableURL: exe,
            fileExists: { $0 == "/opt/apps/turbo/senclaw-manifest.json" })
        XCTAssertEqual(byExe.path, "/opt/apps/turbo")

        let fallback = SenClawPaths.applicationDirectory(
            currentDirectory: cwd,
            executableURL: exe,
            fileExists: { _ in false })
        XCTAssertEqual(fallback.path, "/work/app")
    }
}
