import Foundation
import TermindDomain

extension RemoteFile.Kind {
    public var symbol: String {
        switch self {
        case .directory: "folder.fill"
        case .symbolicLink: "link"
        case .file: "doc"
        case .special, .unknown: "questionmark.square.dashed"
        }
    }
}

extension RemoteFile {
    public var sftpKindDescription: String {
        switch kind {
        case .directory: return String(localized: "Folder")
        case .symbolicLink: return String(localized: "Symbolic Link")
        case .special: return String(localized: "Special")
        case .unknown: return String(localized: "Unknown")
        case .file:
            let fileExtension = (name as NSString).pathExtension
            return fileExtension.isEmpty ? String(localized: "File") : fileExtension.lowercased()
        }
    }
}
