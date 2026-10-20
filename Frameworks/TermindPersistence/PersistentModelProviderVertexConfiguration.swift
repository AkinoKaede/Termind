// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AgentKit
import Foundation
import SwiftData

/// Independent backing preserves every installed provider entity hash through V18.
@Model
public final class PersistentModelProviderVertexConfiguration {
    @Attribute(.unique) public var providerID: UUID = UUID()
    public var isEnabled = false
    public var projectID = ""
    public var location = "global"
    public var credentialRef = ""
    public var clientEmail = ""

    public init(_ provider: ModelProvider) {
        providerID = provider.id
        isEnabled = provider.usesVertex
        projectID = provider.vertex.projectID
        location = provider.vertex.location
        credentialRef = provider.vertex.credentialRef
        clientEmail = provider.vertex.clientEmail
    }

    public func apply(to provider: inout ModelProvider) {
        provider.usesVertex = isEnabled
        provider.vertex = VertexConfig(
            projectID: projectID, location: location, credentialRef: credentialRef, clientEmail: clientEmail)
    }
}
