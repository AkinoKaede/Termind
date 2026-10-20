// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

public nonisolated struct TailscalePingResult: Sendable, Equatable {
    public enum Route: Sendable, Equatable {
        case direct(String)
        case derp(String)
        case peerRelay(String)
        case unknown
    }
    public var milliseconds: Double
    public var route: Route
    public init(milliseconds: Double, route: Route) {
        self.milliseconds = milliseconds
        self.route = route
    }
}
