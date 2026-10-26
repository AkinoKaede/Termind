// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import TermindApplication

extension ResourceToolSpecification {
    var name: String {
        switch (resource, action) {
        case (.host, .get): TermindToolName.getHost
        case (.host, .add): TermindToolName.addHost
        case (.host, .edit): TermindToolName.editHost
        case (.host, .delete): TermindToolName.deleteHost
        case (.hostGroup, .list): TermindToolName.listHostGroups
        case (.hostGroup, .get): TermindToolName.getHostGroup
        case (.hostGroup, .add): TermindToolName.addHostGroup
        case (.hostGroup, .edit): TermindToolName.editHostGroup
        case (.hostGroup, .delete): TermindToolName.deleteHostGroup
        case (.identity, .list): TermindToolName.listIdentities
        case (.identity, .get): TermindToolName.getIdentity
        case (.identity, .add): TermindToolName.addIdentity
        case (.identity, .edit): TermindToolName.editIdentity
        case (.identity, .delete): TermindToolName.deleteIdentity
        case (.key, .list): TermindToolName.listKeys
        case (.key, .get): TermindToolName.getKey
        case (.key, .add): TermindToolName.addKey
        case (.key, .edit): TermindToolName.editKey
        case (.key, .delete): TermindToolName.deleteKey
        case (.key, .generate): TermindToolName.generateKey
        case (.portForwarding, .list): TermindToolName.listPortForwardings
        case (.portForwarding, .get): TermindToolName.getPortForwarding
        case (.portForwarding, .add): TermindToolName.addPortForwarding
        case (.portForwarding, .edit): TermindToolName.editPortForwarding
        case (.portForwarding, .delete): TermindToolName.deletePortForwarding
        case (.portForwarding, .start): TermindToolName.startPortForwarding
        case (.portForwarding, .stop): TermindToolName.stopPortForwarding
        case (.snippet, .list): TermindToolName.listSnippets
        case (.snippet, .get): TermindToolName.getSnippet
        case (.snippet, .add): TermindToolName.addSnippet
        case (.snippet, .edit): TermindToolName.editSnippet
        case (.snippet, .delete): TermindToolName.deleteSnippet
        case (.snippetPackage, .list): TermindToolName.listSnippetPackages
        case (.snippetPackage, .get): TermindToolName.getSnippetPackage
        case (.snippetPackage, .add): TermindToolName.addSnippetPackage
        case (.snippetPackage, .edit): TermindToolName.editSnippetPackage
        case (.snippetPackage, .delete): TermindToolName.deleteSnippetPackage
        case (.metrics, .list): TermindToolName.listMetrics
        case (.metrics, .add): TermindToolName.addMetrics
        case (.metrics, .edit): TermindToolName.editMetrics
        case (.metrics, .delete): TermindToolName.deleteMetrics
        case (.metrics, .start): TermindToolName.startMetrics
        case (.metrics, .stop): TermindToolName.stopMetrics
        case (.metrics, .refresh): TermindToolName.refreshMetrics
        default: preconditionFailure("Unsupported resource operation")
        }
    }
}
