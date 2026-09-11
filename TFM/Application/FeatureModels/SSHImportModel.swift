import Foundation
import TermindApplication

typealias SSHImportModel = TermindApplication.SSHImportModel

extension SSHImportModel {
    convenience init(library: HostLibraryModel, reader: any SSHImportReading) {
        self.init(library: library, reader: reader, defaultUsername: NSUserName())
    }
}
