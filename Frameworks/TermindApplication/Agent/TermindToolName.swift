// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

/// Canonical names of the tools Termind registers with the agent runtime.
///
/// Tool names are protocol surface: they appear in the MCP export list, in
/// persisted disabled-tool preferences, in audit records, and in presentation
/// registries. Spelling them as literals in each of those places lets one site
/// drift from another without any compile error, so every non-documentation
/// reference goes through this enum.
///
/// Names owned by AgentKit (`request_user_secret`, `present_plan`, the
/// `scratch_*` build tools) stay with AgentKit and are intentionally absent.
/// Retired aliases (`ssh_exec`, `ssh_wait`) are historical wire values with no
/// live tool behind them, so they are absent too and keep using their literal
/// spelling where compatibility requires it.
nonisolated public enum TermindToolName {
    // MARK: - Hosts

    public static let listHosts = "list_hosts"
    public static let getHost = "get_host"
    public static let addHost = "add_host"
    public static let editHost = "edit_host"
    public static let deleteHost = "delete_host"

    // MARK: - Host Groups

    public static let listHostGroups = "list_host_groups"
    public static let getHostGroup = "get_host_group"
    public static let addHostGroup = "add_host_group"
    public static let editHostGroup = "edit_host_group"
    public static let deleteHostGroup = "delete_host_group"

    // MARK: - Identities

    public static let listIdentities = "list_identities"
    public static let getIdentity = "get_identity"
    public static let addIdentity = "add_identity"
    public static let editIdentity = "edit_identity"
    public static let deleteIdentity = "delete_identity"

    // MARK: - Keys

    public static let listKeys = "list_keys"
    public static let getKey = "get_key"
    public static let addKey = "add_key"
    public static let editKey = "edit_key"
    public static let deleteKey = "delete_key"
    public static let generateKey = "generate_key"

    // MARK: - Port Forwarding

    public static let listPortForwardings = "list_port_forwardings"
    public static let getPortForwarding = "get_port_forwarding"
    public static let addPortForwarding = "add_port_forwarding"
    public static let editPortForwarding = "edit_port_forwarding"
    public static let deletePortForwarding = "delete_port_forwarding"
    public static let startPortForwarding = "start_port_forwarding"
    public static let stopPortForwarding = "stop_port_forwarding"

    // MARK: - Snippets

    public static let listSnippets = "list_snippets"
    public static let getSnippet = "get_snippet"
    public static let addSnippet = "add_snippet"
    public static let editSnippet = "edit_snippet"
    public static let deleteSnippet = "delete_snippet"
    public static let runSnippet = "run_snippet"

    // MARK: - Snippet Packages

    public static let listSnippetPackages = "list_snippet_packages"
    public static let getSnippetPackage = "get_snippet_package"
    public static let addSnippetPackage = "add_snippet_package"
    public static let editSnippetPackage = "edit_snippet_package"
    public static let deleteSnippetPackage = "delete_snippet_package"

    // MARK: - Metrics

    public static let listMetrics = "list_metrics"
    public static let getMetrics = "get_metrics"
    public static let addMetrics = "add_metrics"
    public static let editMetrics = "edit_metrics"
    public static let deleteMetrics = "delete_metrics"
    public static let startMetrics = "start_metrics"
    public static let stopMetrics = "stop_metrics"
    public static let refreshMetrics = "refresh_metrics"

    // MARK: - Terminal Panes

    public static let listPanes = "list_panes"
    public static let readPane = "read_pane"
    public static let terminalSuggest = "terminal_suggest"

    // MARK: - SSH Commands

    public static let sshExecRun = "ssh_exec_run"
    public static let sshExecOutput = "ssh_exec_output"
    public static let sshExecStdin = "ssh_exec_stdin"
    public static let sshExecCancel = "ssh_exec_cancel"
    public static let sshExecList = "ssh_exec_list"

    // MARK: - SFTP

    public static let sftpList = "sftp_list"
    public static let sftpStat = "sftp_stat"
    public static let sftpRead = "sftp_read"
    public static let sftpWrite = "sftp_write"
    public static let sftpMkdir = "sftp_mkdir"
    public static let sftpMove = "sftp_move"
    public static let sftpCopy = "sftp_copy"
    public static let sftpChmod = "sftp_chmod"
    public static let sftpDelete = "sftp_delete"
    public static let sftpUpload = "sftp_upload"
    public static let sftpUploadStatus = "sftp_upload_status"
    public static let sftpDownload = "sftp_download"
    public static let sftpDownloadStatus = "sftp_download_status"

    // MARK: - Scratch Transfers

    public static let scratchPull = "scratch_pull"
    public static let scratchPush = "scratch_push"

    // MARK: - Resource Management Policy

    public static let managementNames: Set<String> = [
        listHosts, getHost, addHost, editHost, deleteHost,
        listHostGroups, getHostGroup, addHostGroup, editHostGroup, deleteHostGroup,
        listIdentities, getIdentity, addIdentity, editIdentity, deleteIdentity,
        listKeys, getKey, addKey, editKey, deleteKey, generateKey,
        listPortForwardings, getPortForwarding, addPortForwarding, editPortForwarding, deletePortForwarding,
        startPortForwarding, stopPortForwarding,
        listSnippets, getSnippet, addSnippet, editSnippet, deleteSnippet, runSnippet,
        listSnippetPackages, getSnippetPackage, addSnippetPackage, editSnippetPackage, deleteSnippetPackage,
        listMetrics, getMetrics, addMetrics, editMetrics, deleteMetrics, startMetrics, stopMetrics, refreshMetrics,
    ]

    public static let managementReadOnlyNames: Set<String> = [
        listHosts, getHost, listHostGroups, getHostGroup,
        listIdentities, getIdentity, listKeys, getKey, listPortForwardings, getPortForwarding, listSnippets, getSnippet,
        listSnippetPackages, getSnippetPackage, listMetrics, getMetrics,
    ]

    public static let managementDestructiveNames: Set<String> = [
        editHost, deleteHost, editHostGroup, deleteHostGroup,
        editIdentity, deleteIdentity, editKey, deleteKey, editPortForwarding, deletePortForwarding, editSnippet,
        deleteSnippet, runSnippet, editSnippetPackage, deleteSnippetPackage, editMetrics, deleteMetrics,
    ]
}
