/// The importer can dismiss before delivering its result. Keep the target until
/// completion, without a separate presentation flag that can drift from it.
struct MobileFileImportState<Target> {
    private enum Phase {
        case presented(Target)
        case awaitingResult(Target)
    }

    private var phase: Phase?

    var isPresented: Bool {
        get {
            if case .presented = phase { return true }
            return false
        }
        set {
            if !newValue, case .presented(let target) = phase {
                phase = .awaitingResult(target)
            }
        }
    }

    mutating func present(for target: Target) {
        phase = .presented(target)
    }

    mutating func takeTarget() -> Target? {
        defer { phase = nil }
        switch phase {
        case .presented(let target), .awaitingResult(let target): return target
        case nil: return nil
        }
    }
}
