import Foundation
import TermindRemoteInfrastructure

extension SSHImportReader {
    init() {
        self.init(
            username: NSUserName(),
            home: URL(fileURLWithPath: NSHomeDirectoryForUser(NSUserName()) ?? NSHomeDirectory()))
    }
}
