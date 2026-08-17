import XCTest
import TurboFieldfare
import TurboFieldfareServerCore
@testable import TurboFieldfareSenClaw

/// Pins the exact chunk shapes the daemon's OpenAI stream parser consumes —
/// the reason this app owns its chat route instead of using the SDK's.
final class SenClawChatWireTests: XCTestCase {
    private func decode(_ payload: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
    }

    func testHeartbeatIsAnEmptyDeltaChunkTheParserSkips() throws {
        let chunk = try decode(SenClawChatWire.heartbeatChunk(id: "c1"))
        XCTAssertEqual(chunk["object"] as? String, "chat.completion.chunk")
        let choice = try XCTUnwrap((chunk["choices"] as? [[String: Any]])?.first)
        let delta = try XCTUnwrap(choice["delta"] as? [String: Any])
        // Empty delta: no content, no reasoning, no tool_calls — nothing the
        // daemon appends, but a line that resets its 120 s stall timer.
        XCTAssertTrue(delta.isEmpty)
        XCTAssertTrue(choice["finish_reason"] is NSNull)
    }

    func testToolCallChunkCarriesWholeCallAtGivenIndex() throws {
        let call = ParsedToolCall(id: "call_1", name: "get_time",
                                  arguments: .object([:]), argumentsJSON: "{}")
        let chunk = try decode(SenClawChatWire.toolCallChunk(id: "c1", index: 2, call: call))
        let delta = try XCTUnwrap(
            ((chunk["choices"] as? [[String: Any]])?.first?["delta"]) as? [String: Any])
        let toolCall = try XCTUnwrap((delta["tool_calls"] as? [[String: Any]])?.first)
        XCTAssertEqual(toolCall["index"] as? Int, 2)
        XCTAssertEqual(toolCall["id"] as? String, "call_1")
        let function = try XCTUnwrap(toolCall["function"] as? [String: Any])
        XCTAssertEqual(function["name"] as? String, "get_time")
        XCTAssertEqual(function["arguments"] as? String, "{}")
    }

    func testUsageChunkRidesEmptyChoices() throws {
        let usage = OpenAIUsage(promptTokens: 10, completionTokens: 5,
                                totalTokens: 15, cachedTokens: 4)
        let chunk = try decode(SenClawChatWire.usageChunk(id: "c1", usage: usage))
        XCTAssertEqual((chunk["choices"] as? [Any])?.count, 0)
        let u = try XCTUnwrap(chunk["usage"] as? [String: Any])
        XCTAssertEqual(u["prompt_tokens"] as? Int, 10)
        XCTAssertEqual(u["total_tokens"] as? Int, 15)
    }

    func testNonStreamBodyNullsContentForToolOnlyReplies() throws {
        let call = ParsedToolCall(id: "call_1", name: "f",
                                  arguments: .object([:]), argumentsJSON: "{}")
        let usage = OpenAIUsage(promptTokens: 1, completionTokens: 1, totalTokens: 2)
        let body = SenClawChatWire.nonStreamBody(
            id: "c1", content: "", toolCalls: [call], finishReason: "stop", usage: usage)
        let message = try XCTUnwrap(
            (body["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])
        XCTAssertTrue(message["content"] is NSNull)
        XCTAssertEqual(
            (body["choices"] as? [[String: Any]])?.first?["finish_reason"] as? String,
            "tool_calls")
    }

    func testErrorMappingProducesTypedStatuses() {
        XCTAssertEqual(SenClawChatRoute.errorResponse(ServerRequestError.queueFull).status, 429)
        XCTAssertEqual(SenClawChatRoute.errorResponse(ServerRequestError.unknownModel).status, 404)
        XCTAssertEqual(
            SenClawChatRoute.errorResponse(
                ServerRequestError.invalid(message: "x", param: nil, code: "y")).status,
            400)
    }

    func testHeartbeatPumpStopHandshakePreventsLateTicks() {
        let ticks = NSLock()
        var count = 0
        let pump = HeartbeatPump(interval: 0.05) {
            ticks.lock(); count += 1; ticks.unlock()
        }
        pump.start()
        Thread.sleep(forTimeInterval: 0.18)
        pump.stop()
        ticks.lock(); let atStop = count; ticks.unlock()
        XCTAssertGreaterThanOrEqual(atStop, 2)
        Thread.sleep(forTimeInterval: 0.15)
        ticks.lock(); let after = count; ticks.unlock()
        // Nothing may fire after stop() returns — a late tick would write
        // into a recycled connection descriptor.
        XCTAssertEqual(after, atStop)
    }

    func testAutoWarmSettingRoundTrips() throws {
        var settings = SenClawAppSettings()
        XCTAssertTrue(settings.autoWarmEnabled)
        settings.autoWarmEnabled = false
        let applied = SenClawAppSettings().applying(settings.dictionary)
        XCTAssertFalse(applied.autoWarmEnabled)
        try applied.validate()
        // Not part of the load key: toggling it must not demand a reload.
        let directory = URL(fileURLWithPath: "/tmp/m.gturbo")
        XCTAssertEqual(applied.loadKey(modelDirectory: directory),
                       SenClawAppSettings().loadKey(modelDirectory: directory))
    }
}
