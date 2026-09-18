import TermindDomain

@MainActor
public protocol SFTPPreferencesPersisting: AnyObject {
    func loadSFTP() throws -> SFTPPreferences
    func saveSFTP(_ value: SFTPPreferences) throws
}
