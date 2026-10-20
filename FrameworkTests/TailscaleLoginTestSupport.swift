// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import TermindApplication
import TermindDomain

extension TailscaleModel {
    /// Existing transport/cleanup fixtures exercise authentication followed by an explicit Save.
    @MainActor func beginLoginAndSave(
        name: String, parentID: UUID?, controlURL: String, authKey: String?, groupID: UUID? = nil
    ) {
        let target = groupID ?? UUID()
        var draft = group(target) ?? HostGroup(id: target, name: name, parentID: parentID)
        draft.name = name
        draft.parentID = parentID
        let operation = beginLogin(controlURL: controlURL, authKey: authKey, groupID: target)
        Task { @MainActor in
            while loginOperationID == operation && isLoggingIn {
                try? await Task.sleep(for: .milliseconds(5))
            }
            guard let pending = pendingLogin, pending.id == operation else { return }
            do {
                _ = try await commitLogin(
                    operation, group: draft, hostname: pending.hostname,
                    exitNodeID: group(target)?.tailscale?.exitNodeID ?? "")
            } catch {
                cancelLogin(operationID: operation)
            }
        }
    }
}
