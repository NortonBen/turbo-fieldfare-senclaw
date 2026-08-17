import XCTest
import SenclawSpace
import TurboFieldfareServerCore
@testable import TurboFieldfareSenClaw

final class SenClawProviderTests: XCTestCase {
    private func temporaryModelDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("senclaw-provider-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("gemma4.gturbo", isDirectory: true)
    }

    private func makeProvider(modelDirectory: URL) -> SenClawProvider {
        let settings = SenClawSettingsStore(
            fileURL: SenClawPaths.settingsFile(forModelDirectory: modelDirectory))
        return SenClawProvider(
            store: SenClawModelStore(modelDirectory: modelDirectory),
            settings: settings,
            engine: SenClawEngine(queueLimit: 1))
    }

    func testModelCardReflectsSettingsAndStaysTextOnly() {
        var settings = SenClawAppSettings()
        settings.maxContextTokens = 32768
        settings.maxOutputTokens = 4096
        let card = SenClawProvider.card(settings: settings)

        XCTAssertEqual(card.id, "gemma-4-26b-a4b-it")
        XCTAssertEqual(card.contextLength, 32768)
        XCTAssertEqual(card.maxOutputTokens, 4096)
        // The repack pipeline drops multimodal tensors; advertising vision
        // would make the daemon send image blocks that 400 the whole turn.
        XCTAssertFalse(card.vision)
        XCTAssertTrue(card.tools)
    }

    func testNoModelsAdvertisedWhileNotInstalled() {
        let provider = makeProvider(modelDirectory: temporaryModelDirectory())
        XCTAssertEqual(provider.models().count, 0)
    }

    func testChatWithoutInstalledModelFailsWithActionableMessage() {
        let provider = makeProvider(modelDirectory: temporaryModelDirectory())
        let raw: [String: Any] = [
            "model": "gemma-4-26b-a4b-it",
            "messages": [["role": "user", "content": "hi"]],
        ]

        XCTAssertThrowsError(try provider.chatRaw(
            raw,
            emit: { _ in XCTFail("no chunks expected") },
            isClosed: { false })
        ) { error in
            XCTAssertTrue("\(error)".contains("chưa được cài"), "got: \(error)")
        }
    }

    func testOpenAIBodyDecodesFromUntypedDictionary() throws {
        // The SDK hands the raw body as [String: Any]; the bridge re-encodes it
        // for the server core's Codable types. Snake_case keys and tool
        // payloads must survive the trip.
        let raw: [String: Any] = [
            "model": "gemma-4-26b-a4b-it",
            "messages": [
                ["role": "system", "content": "Bạn là trợ lý."],
                ["role": "user", "content": "2+2?"],
            ],
            "max_completion_tokens": 128,
            "temperature": 0.5,
            "top_k": 40,
            "stream": true,
            "stream_options": ["include_usage": true],
            "tools": [[
                "type": "function",
                "function": [
                    "name": "get_time",
                    "description": "Đọc giờ hiện tại",
                    "parameters": [
                        "type": "object",
                        "properties": [:] as [String: Any],
                    ],
                ],
            ]],
        ]
        let data = try JSONSerialization.data(withJSONObject: raw)
        let decoded = try JSONDecoder().decode(OpenAIChatRequest.self, from: data)
        XCTAssertEqual(decoded.maxCompletionTokens, 128)
        XCTAssertEqual(decoded.tools?.count, 1)

        let validated = try OpenAIRequestValidator.validate(decoded, modelID: "gemma-4-26b-a4b-it")
        XCTAssertEqual(validated.maximumCompletionTokens, 128)
        XCTAssertEqual(validated.tools.map(\.name), ["get_time"])
        XCTAssertTrue(validated.stream)
        XCTAssertTrue(validated.includeUsage)
    }

    func testUnrepresentableToolsAreDroppedNotFatal() throws {
        // The exact failure that bricked real agent turns: one tool (FormUI)
        // with a >2-branch union in its schema, sent alongside hundreds of
        // fine tools. The bad tool must drop; the good one must survive.
        let goodTool: [String: Any] = ["type": "function", "function": [
            "name": "get_time",
            "parameters": ["type": "object", "properties": [:] as [String: Any]],
        ]]
        let badTool: [String: Any] = ["type": "function", "function": [
            "name": "FormUI",
            "parameters": ["type": "object", "properties": [
                "fields": ["type": "array", "items": [
                    "anyOf": [["type": "string"], ["type": "number"], ["type": "boolean"]],
                ]],
            ]],
        ]]
        var raw: [String: Any] = [
            "model": "gemma-4-26b-a4b-it",
            "messages": [["role": "user", "content": "hi"]],
            "tools": [goodTool, badTool],
        ]
        let dropped = SenClawProvider.filterUnrepresentableTools(&raw)
        XCTAssertEqual(dropped, ["FormUI"])
        XCTAssertEqual((raw["tools"] as? [Any])?.count, 1)

        // And the filtered request now passes full validation.
        let data = try JSONSerialization.data(withJSONObject: raw)
        let decoded = try JSONDecoder().decode(OpenAIChatRequest.self, from: data)
        let validated = try OpenAIRequestValidator.validate(decoded, modelID: "gemma-4-26b-a4b-it")
        XCTAssertEqual(validated.tools.map(\.name), ["get_time"])
    }

    func testCleanToolListPassesFilterUntouched() {
        var raw: [String: Any] = [
            "model": "gemma-4-26b-a4b-it",
            "messages": [["role": "user", "content": "hi"]],
            "tools": [["type": "function", "function": [
                "name": "ping",
                "parameters": ["type": "object", "properties": [:] as [String: Any]],
            ]]],
        ]
        XCTAssertEqual(SenClawProvider.filterUnrepresentableTools(&raw), [])
        XCTAssertEqual((raw["tools"] as? [Any])?.count, 1)
    }

    func testRenderBisectFindsEveryCulpritWithFewProbes() {
        func tool(_ name: String) -> [String: Any] {
            ["type": "function", "function": ["name": name]]
        }
        let bad: Set<String> = ["FormUI", "mcp__core__browser_fill_form"]
        let tools: [Any] = ["a", "b", "FormUI", "c", "mcp__core__browser_fill_form",
                            "d", "e", "f"].map(tool)
        var probes = 0
        struct RenderBoom: Error {}
        let found = SenClawProvider.renderBreakingTools(tools) { subset in
            probes += 1
            if subset.contains(where: { bad.contains(SenClawProvider.toolName($0)) }) {
                throw RenderBoom()
            }
        }
        XCTAssertEqual(Set(found), bad)
        // Divide and conquer, not a linear scan of all 8.
        XCTAssertLessThanOrEqual(probes, 12)
    }

    func testRenderErrorClassifierSeparatesTypedErrors() {
        struct Jinja: Error, CustomStringConvertible {
            var description: String { "runtime(\"upper filter requires string\")" }
        }
        XCTAssertTrue(SenClawProvider.isRenderError(Jinja()))
        XCTAssertFalse(SenClawProvider.isRenderError(ServerRequestError.queueFull))
        XCTAssertFalse(SenClawProvider.isRenderError(CancellationError()))
    }

    func testKnownRenderBreakingToolsAreDroppedUpFront() {
        SenClawProvider.knownRenderBreakingTools.withLock { $0.insert("EvilTool") }
        defer { SenClawProvider.knownRenderBreakingTools.withLock { $0.remove("EvilTool") } }
        var raw: [String: Any] = [
            "model": "gemma-4-26b-a4b-it",
            "messages": [["role": "user", "content": "hi"]],
            "tools": [
                ["type": "function", "function": [
                    "name": "EvilTool",
                    "parameters": ["type": "object", "properties": [:] as [String: Any]],
                ]],
                ["type": "function", "function": [
                    "name": "ok_tool",
                    "parameters": ["type": "object", "properties": [:] as [String: Any]],
                ]],
            ],
        ]
        let dropped = SenClawProvider.filterUnrepresentableTools(&raw)
        XCTAssertEqual(dropped, ["EvilTool"])
        XCTAssertEqual((raw["tools"] as? [Any])?.count, 1)
    }

    func testValidationErrorSurfacesOpenAIMessage() throws {
        let raw: [String: Any] = [
            "model": "khong-ton-tai",
            "messages": [["role": "user", "content": "hi"]],
        ]
        let data = try JSONSerialization.data(withJSONObject: raw)
        let decoded = try JSONDecoder().decode(OpenAIChatRequest.self, from: data)
        XCTAssertThrowsError(
            try OpenAIRequestValidator.validate(decoded, modelID: "gemma-4-26b-a4b-it")
        ) { error in
            guard let serverError = error as? ServerRequestError else {
                return XCTFail("unexpected error type: \(error)")
            }
            XCTAssertEqual(serverError.envelope.error.code, "model_not_found")
        }
    }
}
