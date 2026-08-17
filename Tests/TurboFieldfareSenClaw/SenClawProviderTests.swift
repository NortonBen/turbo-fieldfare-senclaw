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
