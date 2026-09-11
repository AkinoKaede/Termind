import Foundation

@MainActor
public protocol AISecretStoring: AnyObject {
    func string(for reference: String) throws -> String?
    func setString(_ value: String?, for reference: String) throws
}
