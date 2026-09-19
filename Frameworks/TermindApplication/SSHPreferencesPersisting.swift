import TermindDomain

@MainActor
public protocol SSHPreferencesPersisting: AnyObject {
    func loadSSH() throws -> SSHPreferences
    func saveSSH(_ value: SSHPreferences) throws
}
