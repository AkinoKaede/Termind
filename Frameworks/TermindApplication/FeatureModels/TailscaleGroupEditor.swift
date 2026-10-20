// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import TermindDomain

/// A group form owns its login attempt; authentication never dismisses or saves the form.
@MainActor
@Observable
public final class TailscaleGroupEditor {
    public let model: TailscaleModel
    private let initialDraft: HostGroup
    private var initialHostname: String
    private var logoutProfileID: UUID?
    public var draft: HostGroup
    public private(set) var original: HostGroup?
    public private(set) var enabled: Bool
    public var hostname: String
    public var exitNodeID: String
    public var controlURL: String
    public private(set) var operationID: UUID?
    public private(set) var isSaving = false

    public init(model: TailscaleModel, group: HostGroup?, parentID: UUID? = nil) {
        self.model = model
        original = group
        let initial = group ?? HostGroup(name: "", parentID: parentID)
        draft = initial
        initialDraft = initial
        enabled = group?.tailscale != nil
        let savedHostname = group.flatMap { model.savedHostname(groupID: $0.id) } ?? ""
        hostname = savedHostname
        initialHostname = savedHostname
        exitNodeID = group?.tailscale?.exitNodeID ?? ""
        controlURL = group?.tailscale?.network.controlURL ?? TailscaleNetwork.defaultControlURL
    }

    public var pending: TailscalePendingLogin? {
        guard let operationID, model.pendingLogin?.id == operationID else { return nil }
        return model.pendingLogin
    }
    public var isLoggingIn: Bool { operationID != nil && model.loginOperationID == operationID && model.isLoggingIn }
    public var isLogoutPending: Bool { logoutProfileID != nil }
    public var canChangeEnabled: Bool { isLogoutPending || !model.runningGroups.contains(draft.id) }
    public var isConnected: Bool { pending != nil || (!isLogoutPending && model.runningGroups.contains(draft.id)) }
    public var device: TailscaleDeviceInfo? { pending?.device ?? model.devices[draft.id] }
    public var network: TailscaleNetwork? { pending?.network ?? model.group(draft.id)?.tailscale?.network }
    public var candidates: [TailscalePeer] {
        (pending?.peers ?? model.peers[draft.id] ?? []).filter { $0.exitNodeOption == true }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    public var loginURL: URL? { model.loginOperationID == operationID ? model.loginURL : nil }
    private var requiresLogin: Bool {
        guard enabled, !isConnected else { return false }
        let entered = controlURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let canonical = try? TailscaleNetwork(
            controlURL: entered.isEmpty ? TailscaleNetwork.defaultControlURL : entered,
            dnsSuffix: "pending.invalid"
        ).controlURL
        return original?.tailscale == nil || canonical != original?.tailscale?.network.controlURL
            || hostname != initialHostname
    }
    public var canSave: Bool {
        !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isLoggingIn && !isSaving
            && !requiresLogin
    }
    public var isDirty: Bool {
        draft != (original ?? initialDraft)
            || enabled != (original?.tailscale != nil) || isLoggingIn || pending != nil || isLogoutPending
            || hostname != initialHostname
            || exitNodeID != (original?.tailscale?.exitNodeID ?? "")
            || controlURL != (original?.tailscale?.network.controlURL ?? TailscaleNetwork.defaultControlURL)
    }

    public func setEnabled(_ value: Bool) {
        guard !isSaving, canChangeEnabled else { return }
        if !value { cancelLogin() }
        enabled = value
    }

    public func login(authKey: String?) {
        guard enabled, !isConnected, !isSaving else { return }
        let url = controlURL.trimmingCharacters(in: .whitespacesAndNewlines)
        operationID = model.beginLogin(
            controlURL: url.isEmpty ? TailscaleNetwork.defaultControlURL : url,
            authKey: authKey, groupID: draft.id, hostname: hostname)
    }

    public func receiveLogin() {
        guard let pending else { return }
        if draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { draft.name = pending.suggestedName }
        hostname = pending.hostname
        exitNodeID = pending.exitNodeID
    }

    public func logout() {
        guard !isSaving else { return }
        if pending != nil {
            cancelLogin()
        } else {
            logoutProfileID = model.profileID(groupID: draft.id)
        }
    }

    public func cancel() {
        cancelLogin()
        logoutProfileID = nil
    }

    private func cancelLogin() {
        if let operationID { model.cancelLogin(operationID: operationID) }
        operationID = nil
    }

    public func save() async throws -> HostGroup {
        guard canSave else { throw TailscaleConfigurationError.unavailable }
        isSaving = true
        defer { isSaving = false }
        if let logoutProfileID, let currentProfileID = model.profileID(groupID: draft.id),
            currentProfileID != logoutProfileID
        {
            throw TailscaleConfigurationError.unavailable
        }
        let saved: HostGroup
        if let pending {
            do {
                saved = try await model.commitLogin(
                    pending.id, group: draft, hostname: hostname, exitNodeID: exitNodeID)
            } catch {
                // A local activation failure can follow a successful public save.
                // Keep the baseline current so disabling or retrying remains possible.
                if let latest = model.group(draft.id), latest.tailscale?.network == pending.network {
                    original = latest
                }
                throw error
            }
            operationID = nil
        } else {
            // Validate the binding before applying any local edits, and again after suspension.
            guard model.group(draft.id)?.tailscale?.network == original?.tailscale?.network else {
                throw TailscaleConfigurationError.unavailable
            }
            if enabled, !isLogoutPending, model.runningGroups.contains(draft.id) {
                try await model.saveHostname(hostname, groupID: draft.id)
            }
            saved = try model.saveGroup(
                draft, original: original, enabled: enabled,
                exitNodeID: enabled && isConnected && exitNodeID != (original?.tailscale?.exitNodeID ?? "")
                    ? exitNodeID : nil)
            if let logoutProfileID {
                // A committed group edit must remain the baseline if local logout needs a retry.
                original = saved
                draft = saved
                try await model.logout(groupID: saved.id, profileID: logoutProfileID)
            }
        }
        logoutProfileID = nil
        let latest = model.group(saved.id) ?? saved
        original = latest
        draft = latest
        hostname = model.savedHostname(groupID: saved.id) ?? ""
        initialHostname = hostname
        controlURL = latest.tailscale?.network.controlURL ?? TailscaleNetwork.defaultControlURL
        exitNodeID = latest.tailscale?.exitNodeID ?? ""
        return latest
    }
}
