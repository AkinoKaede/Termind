import Foundation
import TermindRemoteInfrastructure

typealias SSHImportReader = TermindRemoteInfrastructure.SSHImportReader

extension SSHImportReader {
    init() {
        self.init(
            username: NSUserName(),
            home: URL(fileURLWithPath: NSHomeDirectoryForUser(NSUserName()) ?? NSHomeDirectory()))
    }
}
