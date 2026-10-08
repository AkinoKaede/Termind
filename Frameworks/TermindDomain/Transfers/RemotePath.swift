import Foundation

@MainActor
public protocol RemotePathDisplaying {
    var homeResolution: RemoteHomeResolutionState { get }
}

extension RemotePathDisplaying {
    public func displayPath(_ path: String) -> String {
        RemotePath.displayed(path, home: homeResolution)
    }
}

public nonisolated enum RemotePath {
    public struct Component: Identifiable, Equatable, Sendable {
        public var name: String
        public var path: String
        public var id: String { path }
    }

    public static func normalized(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "/" }
        var components: [Substring] = []
        for component in trimmed.split(separator: "/") {
            switch component {
            case ".": continue
            case "..": if !components.isEmpty { components.removeLast() }
            default: components.append(component)
            }
        }
        return "/" + components.joined(separator: "/")
    }

    public static func join(_ base: String, _ name: String) -> String {
        let base = normalized(base)
        return base == "/" ? "/\(name)" : "\(base)/\(name)"
    }

    public static func parent(of path: String) -> String {
        let value = normalized(path)
        guard value != "/" else { return "/" }
        let parent = (value as NSString).deletingLastPathComponent
        return parent.isEmpty ? "/" : parent
    }

    public static func components(of path: String) -> [Component] {
        let value = normalized(path)
        var result = [Component(name: "/", path: "/")]
        guard value != "/" else { return result }
        var current = ""
        for name in value.split(separator: "/").map(String.init) {
            current += "/" + name
            result.append(Component(name: name, path: current))
        }
        return result
    }

    public static func displayed(_ path: String, home: RemoteHomeResolutionState) -> String {
        let value = normalized(path)
        guard case .resolved(let proposedHome) = home else { return value }
        let home = normalized(proposedHome)
        if value == home { return "~" }
        if home == "/" { return "~" + value }
        guard value.hasPrefix(home + "/") else { return value }
        return "~" + value.dropFirst(home.count)
    }

    public static func displayedComponents(
        of path: String, home: RemoteHomeResolutionState
    ) -> [Component] {
        let value = normalized(path)
        guard case .resolved(let proposedHome) = home else { return components(of: value) }
        let home = normalized(proposedHome)
        guard value == home || home == "/" || value.hasPrefix(home + "/") else {
            return components(of: value)
        }
        var result = [Component(name: "~", path: home)]
        guard value != home else { return result }
        var current = home
        let suffix = home == "/" ? value.dropFirst() : value.dropFirst(home.count + 1)
        for name in suffix.split(separator: "/").map(String.init) {
            current = join(current, name)
            result.append(Component(name: name, path: current))
        }
        return result
    }

    public static func keepBothCandidate(for path: String, index: Int) -> String {
        let ns = path as NSString
        let parent = ns.deletingLastPathComponent
        let name = ns.lastPathComponent as NSString
        let ext = name.pathExtension
        let stem = name.deletingPathExtension
        let candidate = ext.isEmpty ? "\(stem).\(index)" : "\(stem).\(index).\(ext)"
        return parent == "/" ? "/\(candidate)" : "\(parent)/\(candidate)"
    }
}

public nonisolated enum RemoteHomeResolutionState: Hashable, Sendable {
    case pending
    case resolved(String)
    case unavailable

    public var resolvedDirectory: String? {
        guard case .resolved(let path) = self else { return nil }
        return RemotePath.normalized(path)
    }

    public var isPending: Bool {
        if case .pending = self { true } else { false }
    }
}
