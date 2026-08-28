import Foundation
import Testing

@testable import Termind

@Suite
struct BalancedEmitterTests {
    @Test
    func burstIsSplitIntoOrderedBatchesAndWaitDrainsIt() async throws {
        let output = StringOutput()
        let emitter = BalancedEmitter(
            configuration: .init(duration: .seconds(1), frequency: 4),
            sleep: { _ in await Task.yield() }
        ) { text in
            await output.append(text)
        }

        await emitter.add("abcdefgh")
        try await emitter.wait()

        #expect(await output.values == ["ab", "cd", "ef", "gh"])
        #expect(await output.joined == "abcdefgh")
    }

    @Test
    func updateChangesTheBatchingPolicy() async throws {
        let output = StringOutput()
        let emitter = BalancedEmitter(
            configuration: .init(duration: .seconds(1), frequency: 8),
            sleep: { _ in await Task.yield() }
        ) { text in
            await output.append(text)
        }

        await emitter.update(.init(duration: .seconds(1), frequency: 2))
        await emitter.add("abcdefgh")
        try await emitter.wait()

        #expect(await output.values == ["abcd", "efgh"])
    }

    @Test
    func emptyChunksAreIgnored() async throws {
        let output = StringOutput()
        let emitter = BalancedEmitter(
            configuration: .init(duration: .seconds(1), frequency: 4),
            sleep: { _ in await Task.yield() }
        ) { text in
            await output.append(text)
        }

        await emitter.add("")
        try await emitter.wait()

        #expect(await output.values.isEmpty)
    }

    @Test
    func cancelDropsBufferedText() async {
        let output = StringOutput()
        let gate = EmitterSleepGate()
        let emitter = BalancedEmitter(
            configuration: .init(duration: .seconds(1), frequency: 4),
            sleep: { _ in try await gate.sleep() }
        ) { text in
            await output.append(text)
        }

        await emitter.add("abcdefgh")
        await gate.waitUntilSleeping()
        await emitter.cancel()
        await gate.release()
        for _ in 0..<10 { await Task.yield() }

        #expect(await output.values == ["ab"])
    }

    @Test
    func cancellingAWaitCancelsTheDrain() async {
        let output = StringOutput()
        let emitter = BalancedEmitter(
            configuration: .init(duration: .seconds(10), frequency: 2)
        ) { text in
            await output.append(text)
        }

        await emitter.add("abcd")
        let waiter = Task { try await emitter.wait() }
        await Task.yield()
        waiter.cancel()

        await #expect(throws: CancellationError.self) {
            try await waiter.value
        }
        #expect(await output.values.count <= 1)
    }

    @Test
    func turnDriverKeepsReasoningBeforeTextAndReturnsExactMessage() async throws {
        let channel = AgentEventChannel(repository: InMemoryAgentRunRepository())
        let events = AgentEventOutput()
        let consumer = Task {
            for await event in channel.events { await events.append(event) }
        }
        let driver = AgentTurnDriver(
            model: BalancedScriptedModel(events: [
                .reasoningDelta("think"), .textDelta("answer"), .finished(.completed),
            ]),
            tools: AgentToolRegistry([AnyAgentTool]()), channel: channel, runID: UUID()
        )

        let turn = try await driver.run(AgentModelContext(
            systemPrompt: "system", messages: [], tools: []
        ))
        channel.emit(.messageFinished(turn.message))
        channel.finish()
        await consumer.value

        let recorded = await events.values
        let reasoning = recorded.compactMap { event -> String? in
            guard case .reasoningDelta(_, let text) = event else { return nil }
            return text
        }.joined()
        let answer = recorded.compactMap { event -> String? in
            guard case .messageDelta(_, let text) = event else { return nil }
            return text
        }.joined()
        let lastReasoning = recorded.lastIndex {
            if case .reasoningDelta = $0 { true } else { false }
        }
        let firstAnswer = recorded.firstIndex {
            if case .messageDelta = $0 { true } else { false }
        }
        let finished = recorded.firstIndex {
            if case .messageFinished = $0 { true } else { false }
        }

        #expect(reasoning == "think")
        #expect(answer == "answer")
        #expect(lastReasoning != nil && firstAnswer != nil && lastReasoning! < firstAnswer!)
        #expect(firstAnswer != nil && finished != nil && firstAnswer! < finished!)
        #expect(turn.message.reasoning.map { $0.text }.joined() == "think")
        #expect(turn.message.text == "answer")
    }
}

private actor StringOutput {
    private(set) var values: [String] = []
    var joined: String { values.joined() }

    func append(_ value: String) {
        values.append(value)
    }
}

private actor EmitterSleepGate {
    private var isSleeping = false
    private var continuation: CheckedContinuation<Void, Never>?

    func sleep() async throws {
        isSleeping = true
        await withCheckedContinuation { continuation = $0 }
        try Task.checkCancellation()
    }

    func waitUntilSleeping() async {
        while !isSleeping { await Task.yield() }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private struct BalancedScriptedModel: AgentModelStreaming {
    let events: [AgentModelStreamEvent]

    func stream(
        _ request: AgentModelRequest
    ) -> AsyncThrowingStream<AgentModelStreamEvent, any Error> {
        AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }
}

private actor AgentEventOutput {
    private(set) var values: [AgentEvent] = []

    func append(_ value: AgentEvent) {
        values.append(value)
    }
}
