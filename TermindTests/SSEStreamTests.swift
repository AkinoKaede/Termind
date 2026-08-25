import Foundation
import Testing

@testable import Termind

/// Framing tests, not field tests.
///
/// The bug these exist for: the streaming entry point framed on
/// `URLSession.AsyncBytes.lines`, and `AsyncLineSequence` discards empty lines.
/// A blank line is the only thing that dispatches an SSE event, so every chat
/// response arrived as one undelimited blob — no text, no tool calls, and an
/// agent turn that ended after one request. Nothing caught it because the
/// parser tests all called `parse*` on already-framed dictionaries, and the
/// buffered entry point framed lines a different way.
@Suite
struct SSEStreamTests {
    @Test
    func blankLineDispatchesEachEventSeparately() async throws {
        let events = try await stream("data: one\n\ndata: two\n\n")

        #expect(events.count == 2)
        #expect(events.map(\.data) == ["one", "two"])
    }

    @Test
    func aStreamOfChatChunksDoesNotCollapseIntoOneEvent() async throws {
        let body = """
            data: {"choices":[{"delta":{"content":"Let me check."}}]}

            data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"list_hosts","arguments":""}}]}}]}

            data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}

            data: [DONE]


            """
        let events = try await stream(body)

        #expect(events.count == 4)
        #expect(events.last?.data == "[DONE]")

        // The framing is what the agent loop depends on: one JSON object per
        // event, so the tool call survives to the runtime.
        var callIDs: [Int: String] = [:]
        var parsed: [AgentModelStreamEvent] = []
        for event in events where event.data != "[DONE]" {
            let root = try #require(
                try JSONSerialization.jsonObject(with: Data(event.data.utf8)) as? [String: Any]
            )
            parsed += AgentProviderClient.parseChat(root, callIDs: &callIDs)
        }
        #expect(parsed.contains { if case .textDelta("Let me check.") = $0 { true } else { false } })
        #expect(parsed.contains {
            if case .toolCallDelta(let id, let name, _) = $0 {
                id == "call_1" && name == "list_hosts"
            } else { false }
        })
        #expect(parsed.contains { if case .finished(.toolCalls) = $0 { true } else { false } })
    }

    @Test
    func bufferedAndStreamedFramingAgree() async throws {
        let bodies = [
            "data: one\n\ndata: two\n\n",
            "event: endpoint\ndata: /messages?id=1\n\n",
            "data: a\ndata: b\n\nid: 7\ndata: c\n\n",
            ": keep-alive\n\ndata: after heartbeat\n\n",
            "data: no trailing blank line\n",
            "data: no trailing newline at all",
            "data: crlf\r\n\r\ndata: second\r\n\r\n",
        ]

        for body in bodies {
            let streamed = try await stream(body)
            let buffered = SSEStream.events(in: Data(body.utf8))
            #expect(streamed == buffered, "framing diverged for \(body.debugDescription)")
        }
    }

    @Test
    func lineTerminatorsMayBeLFOrCRLFOrBareCR() async throws {
        #expect(try await stream("data: a\n\ndata: b\n\n").map(\.data) == ["a", "b"])
        #expect(try await stream("data: a\r\n\r\ndata: b\r\n\r\n").map(\.data) == ["a", "b"])
        #expect(try await stream("data: a\r\rdata: b\r\r").map(\.data) == ["a", "b"])
    }

    @Test
    func aTrailingEventWithoutABlankLineIsStillDelivered() async throws {
        #expect(try await stream("data: only\n").map(\.data) == ["only"])
        #expect(try await stream("data: only").map(\.data) == ["only"])
    }

    @Test
    func heartbeatsAndUnknownFieldsAreDroppedWithoutDispatching() async throws {
        let events = try await stream(": ping\n\nretry: 500\nx-vendor: 1\ndata: real\n\n")

        #expect(events.count == 1)
        #expect(events[0].data == "real")
    }

    @Test
    func multipleDataLinesJoinWithNewlinesAndKeepLeadingSpaces() async throws {
        let events = try await stream("data: first\ndata:  second\n\n")

        #expect(events.count == 1)
        // Exactly one space after the colon is framing; the rest is payload.
        #expect(events[0].data == "first\n second")
    }

    @Test
    func eventNameAndIDTravelWithTheirEvent() async throws {
        let events = try await stream("event: endpoint\nid: 42\ndata: /post\n\ndata: next\n\n")

        #expect(events.count == 2)
        #expect(events[0].event == "endpoint")
        #expect(events[0].id == "42")
        #expect(events[0].data == "/post")
        // Fields do not leak into the following event.
        #expect(events[1].event == "message")
        #expect(events[1].id == nil)
    }

    @Test
    func framingSurvivesMultiByteCharactersSplitAcrossReads() async throws {
        let events = try await stream("data: 主机列表 🌐\n\ndata: 完成\n\n")

        #expect(events.map(\.data) == ["主机列表 🌐", "完成"])
    }

    @Test
    func transportFailureIsThrownRatherThanReadAsAnEndOfStream() async {
        let bytes = AsyncThrowingStream<UInt8, any Error> { continuation in
            for byte in Array("data: partial\n\ndata: ".utf8) { continuation.yield(byte) }
            continuation.finish(throwing: URLError(.networkConnectionLost))
        }

        var events: [SSEEvent] = []
        var thrown: (any Error)?
        do {
            for try await event in SSEStream.events(from: bytes) { events.append(event) }
        } catch { thrown = error }

        #expect(events.map(\.data) == ["partial"])
        #expect(thrown != nil)
    }

    private func stream(_ body: String) async throws -> [SSEEvent] {
        let bytes = AsyncStream<UInt8> { continuation in
            for byte in Array(body.utf8) { continuation.yield(byte) }
            continuation.finish()
        }
        var events: [SSEEvent] = []
        for try await event in SSEStream.events(from: bytes) { events.append(event) }
        return events
    }
}
