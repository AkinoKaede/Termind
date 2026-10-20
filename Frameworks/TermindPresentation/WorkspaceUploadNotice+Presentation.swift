// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import TermindApplication
import TermindDomain

extension WorkspaceUploadNotice {
    public var isRejected: Bool {
        if case .rejected = self { return true }
        return false
    }

    public var symbol: String? {
        switch self {
        case .preparing: nil
        case .queued: "checkmark.circle.fill"
        case .rejected: "exclamationmark.triangle.fill"
        }
    }

    public var title: String {
        switch self {
        case .preparing: String(localized: "Preparing upload…")
        case .queued(let count, _):
            count == 1
                ? String(localized: "Added 1 item to Transfers")
                : String(localized: "Added \(count) items to Transfers")
        case .rejected: String(localized: "Can't upload here")
        }
    }

    public var detail: String {
        switch self {
        case .preparing(let path), .queued(_, let path): path
        case .rejected(let reason): reason
        }
    }

    public func detail(home: RemoteHomeResolutionState) -> String {
        switch self {
        case .preparing(let path), .queued(_, let path): RemotePath.displayed(path, home: home)
        case .rejected(let reason): reason
        }
    }
}
