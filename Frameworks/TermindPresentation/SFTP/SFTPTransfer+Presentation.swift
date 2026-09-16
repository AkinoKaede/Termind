import Foundation
import TermindDomain

nonisolated extension SFTPTransfer {
    public var statusLabel: String {
        switch (direction, state) {
        case (.upload, .running): String(localized: "Uploading")
        case (.download, .running): String(localized: "Downloading")
        case (.upload, .completed): String(localized: "Uploaded")
        case (.download, .completed): String(localized: "Downloaded")
        case (.copy, .completed): String(localized: "Copied")
        default: state.label
        }
    }
}
