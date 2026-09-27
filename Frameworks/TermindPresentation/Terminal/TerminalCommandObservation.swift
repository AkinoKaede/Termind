import Combine
import GhosttyTerminal
import TermindApplication

/// The duration publisher emits once per completion, including equal values.
/// Exit code is assigned first by Ghostty; capture both in the synchronous sink.
@MainActor
public final class TerminalCommandObservation {
    private var observation: AnyCancellable?

    public init(state: TerminalViewState, monitor: TerminalCommandMonitor) {
        observation = state.$lastCommandDurationNanos.dropFirst().sink { [weak state, weak monitor] duration in
            guard let duration else { return }
            monitor?.receiveOSC133(exitCode: state?.lastCommandExitCode, durationNanos: duration)
        }
    }
}
