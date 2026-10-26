// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AgentKit
import TermindApplication

/// Cached reading and monitor management share one catalog, without making reads start collection.
nonisolated enum MetricsManagementTools {
    static let presenters = [GetMetricsTool.presenter]

    static func tools(in environment: TermindAgentToolEnvironment) -> [AnyAgentTool] {
        var tools = [AnyAgentTool(GetMetricsTool(hosts: environment.hosts, metrics: environment.metrics))]
        if let manager = environment.management {
            tools += ResourceToolSpecification.all.filter { $0.resource == .metrics }.map {
                AnyAgentTool(
                    ResourceManagementTool(specification: $0, manager: manager),
                    availableIn: $0.action.readOnly ? [.planning, .acting] : [.acting])
            }
        }
        return tools
    }
}
