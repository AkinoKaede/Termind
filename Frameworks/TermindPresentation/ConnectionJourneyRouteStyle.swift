// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

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

    var endpointIndices: [Int] {
        let indices = Array(journey.endpoints.indices)
        guard journey.usesDirectRecoveryRoute, let first = indices.first, let last = indices.last, first != last else {
            return indices
        }
        return [first, last]
    }

    private var dataRoute: TerminalRouteSnapshot? {
        guard journey.phase == .connecting || journey.phase == .waiting || journey.transportRecovery != nil else {
            return nil
        }
        return journey.transportRoute
    }

    private var completedEndpointIndex: Int {
        guard let route = dataRoute else { return journey.completedEndpointIndex }
        switch route.stage {
        case .unavailable: return 0
        case .ready: return max(0, journey.endpoints.count - 1)
        case .opening:
            var completed = 0
            for (index, hostID) in zip(journey.endpoints.indices.dropFirst(), route.establishedHostIDs) {
                guard journey.endpoints[index].role == .jump, journey.endpoints[index].hostID == hostID else { break }
                completed = index
            }
            return completed
        }
    }

    private var activeEndpointIndex: Int {
        if journey.checkpoint != nil || journey.localRequirement != nil { return journey.activeEndpointIndex }
        guard let route = dataRoute else { return journey.activeEndpointIndex }
        switch route.stage {
        case .unavailable: return 0
        case .ready: return max(0, journey.endpoints.count - 1)
        case .opening:
            return journey.endpoints.firstIndex { $0.hostID != nil && $0.hostID == route.activeHostID }
                ?? min(completedEndpointIndex + 1, max(0, journey.endpoints.count - 1))
        }
    }

    func state(for element: Element, at index: Int) -> State {
        if case .failed = journey.phase {
            // Include the failure itself and any later progress made by SSH bootstrap.
            let completedIndex = max(journey.completedEndpointIndex, journey.completedCheckpoints.keys.max() ?? 0)
            let reachedIndex = max(journey.activeEndpointIndex, completedIndex)
            return index <= reachedIndex ? .failed : .pending
        }
        if let route = dataRoute {
            if index <= completedEndpointIndex { return .complete }
            if route.stage == .opening, element == .segment, index == activeEndpointIndex,
                journey.transportRecovery != .suspended
            {
                return .active
            }
            return .pending
        }
        if let recovery = journey.transportRecovery {
            if index == journey.activeEndpointIndex, recovery == .recovering { return .active }
            return element == .endpoint && index == 0 ? .complete : .pending
        }
        if index <= journey.completedEndpointIndex { return .complete }
        if element == .segment, index == journey.activeEndpointIndex { return .active }
        return .pending
    }

    var activityEndpointIndex: Int? {
        guard journey.phase == .connecting, journey.checkpoint == nil, journey.localRequirement == nil,
            journey.transportRecovery != .suspended,
            let lastIndex = journey.endpoints.indices.last
        else { return nil }
        if let route = dataRoute {
            switch route.stage {
            case .unavailable: return nil
            case .ready: return lastIndex
            case .opening: break
            }
        } else if let recovery = journey.transportRecovery {
            return recovery == .recovering ? lastIndex : nil
        }
        let activeIndex = activeEndpointIndex
        let completedIndex = completedEndpointIndex
        let candidate = activeIndex > completedIndex ? activeIndex - 1 : completedIndex
        return min(max(journey.endpoints.startIndex, candidate), lastIndex)
    }

    var scrollTarget: String? {
        guard let lastIndex = endpointIndices.last else { return nil }
        let candidate =
            journey.checkpoint?.endpointIndex
            ?? journey.localRequirementEndpointIndex
            ?? activityEndpointIndex
            ?? activeEndpointIndex
        let index = endpointIndices.contains(candidate) ? candidate : lastIndex
        return journey.checkpoint != nil && index > 0 ? "segment-\(index)" : "endpoint-\(index)"
    }
}
