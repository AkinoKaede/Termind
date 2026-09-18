import Foundation
import SwiftData
import TermindDomain

/// Freeze the V1–V19 forwarding entity before adding its optional color in V20.
public enum TermindSchemaV19ForwardingModels {
    @Model
    public final class PersistentPortForwardingRule {
        @Attribute(.unique) public var id: UUID = UUID()
        public var hostID: UUID = UUID()
        public var kind = PortForwardingRule.Kind.local.rawValue
        public var bindHost = "127.0.0.1"
        public var bindPort = 8080
        public var targetHost: String?
        public var targetPort: Int?
        public var label = ""

        public init(_ value: PortForwardingRule) {
            id = value.id
            hostID = value.hostID
            kind = value.kind.rawValue
            bindHost = value.bindHost
            bindPort = value.bindPort
            targetHost = value.kind == .dynamic ? nil : value.targetHost
            targetPort = value.kind == .dynamic ? nil : value.targetPort
            label = value.label
        }
    }
}
