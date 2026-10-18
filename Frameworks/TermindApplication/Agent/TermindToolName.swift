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
    public static let listHosts = "list_hosts"
    public static let getMetrics = "get_metrics"
    public static let terminalSuggest = "terminal_suggest"
    public static let listPanes = "list_panes"
    public static let readPane = "read_pane"

    public static let sshExecRun = "ssh_exec_run"
    public static let sshExecOutput = "ssh_exec_output"
    public static let sshExecStdin = "ssh_exec_stdin"
    public static let sshExecCancel = "ssh_exec_cancel"
    public static let sshExecList = "ssh_exec_list"

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
    public static let sftpDownload = "sftp_download"
    public static let sftpUploadStatus = "sftp_upload_status"
    public static let sftpDownloadStatus = "sftp_download_status"

    public static let scratchPull = "scratch_pull"
    public static let scratchPush = "scratch_push"
}
