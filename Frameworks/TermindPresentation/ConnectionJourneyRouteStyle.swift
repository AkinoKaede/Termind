import SwiftUI
import TermindApplication

struct ConnectionJourneyRouteStyle {
    enum Element: Equatable {
        case endpoint
        case segment
    }

    enum State: Equatable {
        case pending
        case active
        case complete
        case failed

        var color: Color {
            switch self {
            case .pending: .secondary.opacity(0.55)
            case .active, .complete: .accentColor
            case .failed: .red
            }
        }
    }

    let journey: ConnectionJourney

    func state(for element: Element, at index: Int) -> State {
        if case .failed = journey.phase {
            // Include the failure itself and any later progress made by SSH bootstrap.
            let completedIndex = max(journey.completedEndpointIndex, journey.completedCheckpoints.keys.max() ?? 0)
            let reachedIndex = max(journey.activeEndpointIndex, completedIndex)
            return index <= reachedIndex ? .failed : .pending
        }
        if let recovery = journey.transportRecovery {
            switch element {
            case .endpoint:
                if index == journey.activeEndpointIndex { return .active }
                return index == 0 ? .complete : .pending
            case .segment:
                return index == journey.activeEndpointIndex && recovery == .recovering ? .active : .pending
            }
        }
        if index <= journey.completedEndpointIndex { return .complete }
        if element == .segment, index == journey.activeEndpointIndex { return .active }
        return .pending
    }

    var activityEndpointIndex: Int? {
        guard journey.phase == .connecting, journey.checkpoint == nil,
            let lastIndex = journey.endpoints.indices.last
        else { return nil }
        if let recovery = journey.transportRecovery {
            return recovery == .recovering ? lastIndex : nil
        }
        let candidate =
            journey.activeEndpointIndex > journey.completedEndpointIndex
            ? journey.activeEndpointIndex - 1 : journey.completedEndpointIndex
        return min(max(journey.endpoints.startIndex, candidate), lastIndex)
    }
}
