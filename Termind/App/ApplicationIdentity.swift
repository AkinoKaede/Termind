import Foundation

nonisolated enum ApplicationIdentity {
    static var teamIdentifier: String {
        Bundle.main.object(forInfoDictionaryKey: "TermindTeamIdentifier") as? String
            ?? "F6SUNDBBN9"
    }

    static var bundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? "com.akinokaede.termind"
    }

    static var keychainAccessGroup: String {
        "\(teamIdentifier).\(bundleIdentifier)"
    }
}
