// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import TermindDomain

/// The V2 template envelope is separate from the frozen V1 pane vocabulary.
nonisolated struct VaultWorkspaceWireV2: Codable {
    enum Pane: Codable {
        case ssh(hostID: UUID)
        case mosh(hostID: UUID)
        case eternalTerminal(hostID: UUID)
        case telnet(hostID: UUID)
        case sftp(hostID: UUID)
        case empty
        init(_ value: WorkspaceTemplatePane) {
            switch value {
            case .ssh(let id): self = .ssh(hostID: id)
            case .mosh(let id): self = .mosh(hostID: id)
            case .eternalTerminal(let id): self = .eternalTerminal(hostID: id)
            case .telnet(let id): self = .telnet(hostID: id)
            case .sftp(let id): self = .sftp(hostID: id)
            case .empty: self = .empty
            }
        }
        var value: WorkspaceTemplatePane {
            switch self {
            case .ssh(let id): .ssh(hostID: id)
            case .mosh(let id): .mosh(hostID: id)
            case .eternalTerminal(let id): .eternalTerminal(hostID: id)
            case .telnet(let id): .telnet(hostID: id)
            case .sftp(let id): .sftp(hostID: id)
            case .empty: .empty
            }
        }
    }
    indirect enum Layout: Codable {
        case pane(Pane)
        case split(axis: WorkspaceTemplateSplitAxis, fraction: Double, first: Layout, second: Layout)
        init(_ value: WorkspaceTemplateLayout) {
            switch value {
            case .pane(let pane): self = .pane(Pane(pane))
            case .split(let axis, let fraction, let first, let second):
                self = .split(axis: axis, fraction: fraction, first: Layout(first), second: Layout(second))
            }
        }
        var value: WorkspaceTemplateLayout {
            switch self {
            case .pane(let pane): .pane(pane.value)
            case .split(let axis, let fraction, let first, let second):
                .split(axis: axis, fraction: fraction, first: first.value, second: second.value)
            }
        }
    }
    struct Template: Codable {
        var id: UUID
        var name: String
        var layout: Layout
    }
    enum Payload: Codable { case workspaceTemplate(Template) }
    var formatVersion: Int
    var key: VaultRecordKey
    var version: VaultVersion
    var isDeleted: Bool
    var payload: Payload?
    init(_ envelope: VaultEnvelope) throws {
        guard envelope.key.kind == .workspaceTemplate else { throw CocoaError(.coderInvalidValue) }
        formatVersion = 2
        key = envelope.key
        version = envelope.version
        isDeleted = envelope.isDeleted
        if case .workspaceTemplate(let template) = envelope.payload {
            payload = .workspaceTemplate(.init(id: template.id, name: template.name, layout: Layout(template.layout)))
        }
    }
    var domainValue: VaultEnvelope {
        var value: VaultRecordPayload?
        if case .workspaceTemplate(let template) = payload {
            value = .workspaceTemplate(.init(id: template.id, name: template.name, layout: template.layout.value))
        }
        return VaultEnvelope(
            key: key, version: version, isDeleted: isDeleted, payload: value, formatVersion: formatVersion)
    }
}
