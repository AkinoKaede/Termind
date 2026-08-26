import Foundation

/// The one ordered path every agent event takes, whoever raised it.
///
/// Two things used to publish events independently: `AgentRuntime`, from inside
/// its actor, and `AgentApprovalBroker`, through a closure `AppModel` handed it.
/// Each wrapped its durable write in its own unstructured `Task`, and separate
/// tasks have no order between them — so a `toolFinished` could be written
/// before the `toolStarted` it follows. Sequential tool calls hid most of it;
/// parallel ones would not.
///
/// `yield` on an `AsyncStream.Continuation` is ordered and safe from any
/// isolation, which is exactly what a fan-in point needs when the writers are a
/// task group of concurrently running tools. Durable events are handed to a
/// single drain task that awaits each write before starting the next, so
/// storage sees them in the order they happened rather than in whatever order
/// the scheduler got around to them.
nonisolated final class AgentEventChannel: Sendable {
    /// The UI's sequence. Single-consumer, like every `AsyncStream`: one channel
    /// belongs to one run.
    let events: AsyncStream<AgentEvent>

    private let output: AsyncStream<AgentEvent>.Continuation
    private let durable: AsyncStream<AgentEvent>.Continuation
    private let recorder: Task<Void, Never>

    init(repository: any AgentRunPersisting) {
        let (events, output) = AsyncStream<AgentEvent>.makeStream()
        let (durableEvents, durable) = AsyncStream<AgentEvent>.makeStream()
        self.events = events
        self.output = output
        self.durable = durable
        recorder = Task {
            for await event in durableEvents {
                // Every durable case carries its run. `associatedRunID` is the
                // single source of that fact, so nothing has to be told which
                // run it is publishing into.
                guard let runID = event.associatedRunID else { continue }
                try? await repository.record(event, runID: runID)
            }
        }
    }

    deinit {
        output.finish()
        durable.finish()
        // The drain ends on its own once its stream finishes; cancelling here
        // would abandon writes that were already accepted.
    }

    func emit(_ event: AgentEvent) {
        output.yield(event)
        // Streaming text is deliberately not durable: the transcript is written
        // from run snapshots, so a reply must not also stream database writes.
        // See `AgentEvent.isDurable`.
        guard event.isDurable else { return }
        durable.yield(event)
    }

    /// Ends the UI sequence and lets the recorder finish what it was given.
    func finish() {
        output.finish()
        durable.finish()
    }
}
