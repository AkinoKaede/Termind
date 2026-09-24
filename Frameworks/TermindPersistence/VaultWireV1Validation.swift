import Foundation
import TermindDomain

nonisolated extension VaultWireV1 {
    /// A future domain enum case must throw at the V1 writer boundary, before
    /// invoking the frozen adapters. It cannot become a default or crash a save.
    /// New cases belong in a new wire version with an explicit historical adapter.
    static func validateRepresentable(_ payload: VaultRecordPayload?) throws {
        func require<T>(_ value: T?) throws {
            guard value != nil else { throw CocoaError(.coderInvalidValue) }
        }
        func proxy(_ value: TermindDomain.HostProxy?) throws {
            if let value { try require(HostProxy.ProtocolKind(rawValue: value.kind.rawValue)) }
        }
        func layout(_ value: TermindDomain.WorkspaceTemplateLayout) throws {
            switch value {
            case .pane: break
            case .split(let axis, _, let first, let second):
                try require(WorkspaceTemplateSplitAxis(rawValue: axis.rawValue))
                try layout(first)
                try layout(second)
            }
        }
        switch payload {
        case .host(let value):
            try require(RemoteCharset(rawValue: value.sshCharset.rawValue))
            try require(RemoteCharset(rawValue: value.telnetCharset.rawValue))
            try require(TagColor(rawValue: value.colorTag.rawValue))
            try require(HostShellIntegrationMode(rawValue: value.shellIntegrationMode.rawValue))
            try proxy(value.proxy)
            try proxy(value.telnetProxy)
        case .identity(let value):
            try require(PasswordStorage(rawValue: value.passwordStorage.rawValue))
            try require(TagColor(rawValue: value.colorTag.rawValue))
            if let purpose = value.customPurpose { try require(HostCustomIdentityPurpose(rawValue: purpose.rawValue)) }
        case .sshKey(let value):
            try require(SSHKeyAlgorithm(rawValue: value.algorithm.rawValue))
            try require(KeyStorage(rawValue: value.storage.rawValue))
            try require(TagColor(rawValue: value.colorTag.rawValue))
        case .knownHost(let value): try require(SSHKeyAlgorithm(rawValue: value.algorithm.rawValue))
        case .portForwarding(let value):
            try require(PortForwardingRule.Kind(rawValue: value.kind.rawValue))
            try require(TagColor(rawValue: value.colorTag.rawValue))
        case .connectionHistory(let value): try require(ConnectionHistoryEntry.Kind(rawValue: value.kind.rawValue))
        case .workspaceTemplate(let value): try layout(value.layout)
        case .hostGroup, .snippet, .snippetPackage, .device, nil: break
        }
    }
}
