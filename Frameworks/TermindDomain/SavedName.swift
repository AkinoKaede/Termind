import AgentKit
import Foundation

/// Form defaults are materialized only by local saves, never by loading a record.
public nonisolated enum SavedName {
    public static func resolve(_ name: String, default defaultName: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? defaultName : name
    }
}

nonisolated extension Host {
    public var defaultName: String { host.trimmingCharacters(in: .whitespacesAndNewlines) }
}

nonisolated extension Identity {
    public var defaultName: String { Self.defaultName(username: username) }

    public static func defaultName(username: String) -> String {
        username.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

nonisolated extension SSHKeyRef {
    public var defaultName: String { Self.defaultName(algorithm: algorithm, storage: storage) }

    public static func defaultName(algorithm: SSHKeyAlgorithm, storage: KeyStorage) -> String {
        storage == .secureEnclave ? "Secure Enclave" : algorithm.typeName
    }
}

nonisolated extension PortForwardingRule {
    public func defaultName(hostName: String) -> String {
        guard !hostName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
        return "\(hostName) (\(kind.sshArgument))"
    }
}

nonisolated extension PortForwardingRule.Kind {
    public var sshArgument: String {
        switch self {
        case .local: "-L"
        case .remote: "-R"
        case .dynamic: "-D"
        }
    }
}

nonisolated extension AIModel {
    public var savingName: AIModel {
        var value = self
        value.displayName = SavedName.resolve(displayName, default: id)
        return value
    }
}
