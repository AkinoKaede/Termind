import Observation
import TermindDomain

@MainActor
@Observable
public final class TerminalFindController {
    public private(set) var query = ""
    public private(set) var isPresented = false

    @ObservationIgnored private var searchSuspended = false
    @ObservationIgnored private let perform: (String) -> Void
    @ObservationIgnored private let focus: () -> Void

    public init(perform: @escaping (String) -> Void, focus: @escaping () -> Void) {
        self.perform = perform
        self.focus = focus
    }

    public func present() {
        let wasPresented = isPresented
        isPresented = true
        if !wasPresented, !searchSuspended, !query.isEmpty { perform(TerminalFindBinding.search(query)) }
    }

    public func updateQuery(_ query: String) {
        guard self.query != query else { return }
        self.query = query
        guard !searchSuspended else { return }
        perform(TerminalFindBinding.search(query))
    }

    public func navigate(_ direction: TerminalFindDirection) {
        guard isPresented, !searchSuspended, !query.isEmpty else { return }
        perform(TerminalFindBinding.navigate(direction))
    }

    public func presentAndNavigate(_ direction: TerminalFindDirection) {
        present()
        navigate(direction)
    }

    /// An active search can interfere with blank-row trimming during native resize.
    /// Keep the UI state while stopping the engine search for the geometry transition.
    public func suspendSearchForResize() {
        guard !searchSuspended else { return }
        searchSuspended = true
        if isPresented, !query.isEmpty { perform(TerminalFindBinding.end) }
    }

    public func resumeSearchAfterResize() {
        guard searchSuspended else { return }
        searchSuspended = false
        if isPresented, !query.isEmpty { perform(TerminalFindBinding.search(query)) }
    }

    /// Native search UI can own its keyboard dismissal instead of handing focus
    /// back to the terminal during the platform's responder transition.
    public func dismiss(restoringFocus: Bool = true) {
        guard isPresented else { return }
        perform(TerminalFindBinding.end)
        isPresented = false
        if restoringFocus { focus() }
    }
}
