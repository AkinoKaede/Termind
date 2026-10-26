// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AgentKit
import TermindApplication

/// Discovery retains temporary targets; mutations operate only on the saved library.
nonisolated enum HostManagementTools {
    static let presenters = [ListHostsTool.presenter]

    static func tools(in environment: TermindAgentToolEnvironment) -> [AnyAgentTool] {
        var tools = [AnyAgentTool(ListHostsTool(hosts: environment.hosts))]
        if let manager = environment.management {
            tools += ResourceToolSpecification.all.filter {
                $0.resource == .host || $0.resource == .hostGroup
            }.map {
                AnyAgentTool(
                    ResourceManagementTool(specification: $0, manager: manager),
                    availableIn: $0.action.readOnly ? [.planning, .acting] : [.acting])
            }
        }
        return tools
    }
}
