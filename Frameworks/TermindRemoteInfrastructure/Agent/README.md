# Tool Output Policies

AgentKit owns whole-line truncation, optional output accumulation, scratch writes,
and model-output markers. Termind owns its tool policies and generated paths.
The default model ceiling is 64 KiB (65,536 UTF-8 bytes) and 2,000 logical lines,
including JSON escaping and the response envelope in the byte budget. A line that
cannot fit is omitted, never split. `none` explicitly bypasses this ceiling.

## Model Strategies and Automatic Capture

Every assistant-visible tool is listed below. Capture is a tool implementation
choice, not a model parameter or a Scratch enable/disable switch.

| Tools | Strategy | Automatic capture |
| --- | --- | --- |
| `ssh_exec_run` | `tail` | Cumulative command output |
| `ssh_exec_output` | `tail` | Complete snapshot of the command, not the already-shortened preview |
| Dynamic outbound MCP tools | `middle` | Received result; filename uses the called tool name |
| `fetch`, `web_search` | `head` | Received document/search output |
| `read_pane` | `none` | No |
| `sftp_read`, `scratch_read` | `head` | No; continue with the returned offset |
| `skill_read_file` | `head` for supporting files; trusted `SKILL.md` bypasses projection | No; supporting files retain their line pagination |
| `read_chat` | `head` | No; cursor continues at the first unreturned message/line |
| `memory_search`, `session_search`, `list_chats` | `head` | No; retain their query, result-count and pagination contracts |
| `scratch_search` | Default `head` | No; narrow the query/path or use `scratch_read` |
| `get_metrics`, `list_hosts`, `list_panes`, `ssh_exec_list` | `head` | No |
| `sftp_list`, `sftp_stat`, `scratch_list`, `skills_list`, `list_models` | `head` | No |
| `scratch_diff` | `head` | No; source files remain available |
| `ssh_exec_stdin`, `ssh_exec_cancel`, `terminal_suggest` | `head` | No |
| `sftp_write`, `sftp_mkdir`, `sftp_move`, `sftp_copy`, `sftp_chmod`, `sftp_delete` | `head` | No |
| `scratch_pull`, `scratch_push`, `scratch_fetch` | `head` | No automatic capture; these tools already transfer files to an explicit destination |
| `scratch_write`, `scratch_replace`, `scratch_copy`, `scratch_move`, `scratch_delete` | `head` | No |
| `request_user_input`, `present_plan`, `manage_tasks` | `head` | No |
| `skill_manage`, `skill_install`, `memory` | `head` | No |
| `create_new_chat`, `send_to_chat`, `wait_chats` | `head` | No |
| `request_user_secret` | Secret-result bypass | Never capture secrets |

Planning wrappers preserve their wrapped tool's strategy. Provider-native results
and already-frozen model projections retain their separate contracts.

External clients calling the Termind MCP server bypass model projection and
automatic capture. This also covers the external-only `sftp_upload`,
`sftp_upload_status`, `sftp_download`, and `sftp_download_status` tools.
Intrinsic source limits, such as file-read pagination, are not removed.

## Paths and Shared Scratch

Scratch is shared by all conversations on this device. Its root is
Application Support / Termind / Scratch (inside the app container on sandboxed
macOS). A conversation deletion or fork does not delete or copy these files.

The path factory returns a complete scratch-relative path. AgentKit does not
prepend `output/`, `outputs/`, a conversation ID, or an extension.
Termind's tool convention is:

| Producer | Path |
| --- | --- |
| `ssh_exec_run` | `<conversationID>/outputs/ssh-exec-<UUID>.txt` |
| `ssh_exec_output` | `<conversationID>/outputs/ssh-exec-output-<UUID>.txt` |
| `fetch` | `<conversationID>/outputs/fetch-<UUID>.txt` |
| `web_search` | `<conversationID>/outputs/web-search-<UUID>.txt` |
| Outbound MCP | `<conversationID>/outputs/<tool-name>-<UUID>.txt` |

Tool-name underscores become hyphens. Contexts without a conversation ID use
their run ID. This is file organization, not conversation isolation; the agent
must still provide explicit relative paths when reading or writing its own files.
Parent directories are created automatically. Generated collisions are not
overwritten. Existing containment, symlink and quota checks still apply.

A command's collector reuses one cumulative file. Each truncated
`ssh_exec_output` call captures its own snapshot under its own tool name. Files
contain redacted output through that snapshot, not future command output.
Capture is lazy, limited to 8 MiB per file and the shared 64 MiB/512-entry quota.
Quota or I/O failure must not claim that a complete saved copy exists.

## Markers and Presentation

AgentKit supplies two unlocalized, bracketed marker forms, following Pi:

```text
[Showing lines 101-2100 of 2100. Full output: <path>]
[Showing lines 1-2000 of 2100]
```

`middle` lists both retained ranges. Empty selections report zero returned lines;
paginated sources with unknown total length omit the total. The `Full output`
clause appears only after a successful capture. Failure details and continuation
offsets/cursors live in separate result fields, not extra markers.

Presentation never generates these markers. It may display the marker frozen by
AgentKit for actual tool/model truncation. Display-only folding adds none:

- Compact bodies share five complete logical lines/list items and 64 KiB. SSH
  keeps the tail; command metadata remains outside the body budget.
- Expansion uses the card's full retained content, without height clipping.
- Existing truncation markers appear above the left-aligned Show more/Show less
  controls.
- Other text previews use `middle`, 120 lines and 64 KiB, retaining full content
  for Copy.
- Display folding never rewrites model content or creates Scratch files.

Tool-specific source limits remain where they have meaning: file pagination,
search match counts, metric process counts, skill validation quotas and
hunk-aligned diff computation/output limits. They are not additional arbitrary
character cuts. `read_chat` no longer uses its former 8,000/40,000-character cuts.
