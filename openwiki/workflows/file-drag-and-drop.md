---
type: interaction workflow
title: File Drop and Upload Routing
description: How desktop file URLs and private drag payloads are validated and dispatched to terminal path insertion, SSH/SFTP uploads, or remote copies, alongside mobile and other file-drop destinations.
tags: [drag-and-drop, files, macos, ios, assistant, ssh, sftp, shell-integration, lifecycle]
sources:
  - id: openwiki-source-1c48f72c0c7a3164d7d5c715
    resource: repo://Frameworks/TermindApplication/Agent/ConversationModel.swift
  - id: openwiki-source-9f901321faf927c1696ac6e6
    resource: repo://Frameworks/TermindApplication/Transfers/WorkspaceUploadNotice.swift
  - id: openwiki-source-b37c974aaea12bd08606d67d
    resource: repo://Frameworks/TermindDomain/Commerce/ProAccessTypes.swift
  - id: openwiki-source-4b9f58eec58128055ac58b6f
    resource: repo://Frameworks/TermindInfrastructure/Agent/ContextAttachmentImporter.swift
  - id: openwiki-source-2f0ffe388e45ad08e33d678c
    resource: repo://Frameworks/TermindInfrastructure/Agent/ContextAttachmentLoading%2BLive.swift
  - id: openwiki-source-2a1410fc70d6f618f69f74fc
    resource: repo://Frameworks/TermindPresentation/DropTargetOverlay.swift
  - id: openwiki-source-faefd83262ffa05c2f2f6067
    resource: repo://Frameworks/TermindRemoteInfrastructure/Security/SoftwareKeyFileImporter.swift
  - id: openwiki-source-5a6536c30ad78ac55f3ec629
    resource: repo://Frameworks/TermindRemoteInfrastructure/Security/WebAuthnSSH.swift
  - id: openwiki-source-cc90954475bbeee75514baf8
    resource: repo://Frameworks/TermindRemoteInfrastructure/Transfers/SFTPLocalUploadPlanner.swift
  - id: openwiki-source-af958b0e71cef7f5910893cc
    resource: repo://Frameworks/TermindRemoteInfrastructure/Transfers/SFTPRemoteTransferPlanner.swift
  - id: openwiki-source-c4b6e224fdbea6dcd393344d
    resource: repo://Frameworks/TermindRemoteInfrastructure/Transfers/SFTPTransferCoordinator.swift
  - id: openwiki-source-247755d873c5d94b0a364217
    resource: repo://FrameworkTests/AssistantConversationOperationsTests.swift
  - id: openwiki-source-3dfad0e95bb7d66f292c20c9
    resource: repo://TFI/Features/AI/MobileAssistantConversation.swift
  - id: openwiki-source-492f738896225c6b3acf7d2f
    resource: repo://TFI/Features/Workspaces/MobileWorkspace.swift
  - id: openwiki-source-4c2de67bfdb2238d765a642a
    resource: repo://TFI/Features/Workspaces/MobileWorkspaceView.swift
  - id: openwiki-source-54e75456c2989a8afee2c630
    resource: repo://TFI/Platform/MobileTerminalDropTarget.swift
  - id: openwiki-source-ff70f9337ec621c20453d410
    resource: repo://TFI/UI/Components/MobileDropPayload.swift
  - id: openwiki-source-d4d621c97707c9d77357829d
    resource: repo://TFI/UI/Components/MobileWindowDropTarget.swift
  - id: openwiki-source-2ccf9b5f9aa44bcc4462adbe
    resource: repo://TFITests/MobileDropTests.swift
  - id: openwiki-source-16db5d5459897d40fe080701
    resource: repo://TFM/Features/AI/ConversationTranscriptView.swift
  - id: openwiki-source-16bb1a92866262b0d20f24e4
    resource: repo://TFM/Features/Keychain/KeychainPageView.swift
  - id: openwiki-source-61a7b49f0fef771653753f14
    resource: repo://TFM/Features/SFTP/SFTPBrowserView.swift
  - id: openwiki-source-959c55c879956237ad156bda
    resource: repo://TFM/Features/StatusBar/StatusBarView.swift
  - id: openwiki-source-fe5539ed6f675410b82b41c4
    resource: repo://TFM/Features/Terminal/PersistentTerminalSurfaceView.swift
  - id: openwiki-source-7e796927b780e67cc73f6a5b
    resource: repo://TFM/Features/Terminal/SSHSessionModel.swift
  - id: openwiki-source-c07d1ec13cbf698f5d45b98e
    resource: repo://TFM/Features/Terminal/TerminalPathDrag.swift
  - id: openwiki-source-c5cf0bfb7f2ff215114f00d5
    resource: repo://TFM/Features/Terminal/TerminalPlaceholderView.swift
  - id: openwiki-source-d7973be685aa90a4b2ec555b
    resource: repo://TFM/Features/Terminal/TerminalUploadModel.swift
  - id: openwiki-source-931aff66b28d38cd69ce2324
    resource: repo://TFM/Features/Workspaces/WorkspaceContentView.swift
  - id: openwiki-source-fbce742d07f4b9d43aaf149d
    resource: repo://TFM/UI/Components/FileURLDropTarget.swift
  - id: openwiki-source-23478c0f7b58a7222e2025d1
    resource: repo://TFMTests/FileURLDropTargetTests.swift
  - id: openwiki-source-53e2b2fd2e661123f63e69e1
    resource: repo://TFMTests/SFTPTransferContextTests.swift
  - id: openwiki-source-feb0ce87e6f1433273c91c11
    resource: repo://TFMTests/TerminalPathDragTests.swift
generated: { by: "codex", at: "2026-10-02T08:42:40.505Z" }
verified:
  - by: openwiki/0.6.0
    at: 2026-10-02T08:42:40.505Z
---

# File Drop and Upload Routing

File dragging crosses three boundaries: native event routing chooses a visible receiver, payload loading chooses a representation, and the destination starts an attachment import or a transfer. A native `.copy` proposal or a successful drop callback means the gesture was accepted; asynchronous loading, validation, conflict resolution, and transfer can still fail afterward.

This page follows those events and ownership transitions. [TFM Drag and Drop](/openwiki/workflows/desktop-drag-and-drop.md) covers Workspace/Pane layout moves and Assistant conversation-list sorting, which use different payloads and state. Transfer scheduling and connection leasing are detailed in [SFTP Transfer and External Edit](/openwiki/workflows/sftp-transfer-and-external-edit.md).

## Supported routes and destination ownership

| Gesture | TFM | TFI | Destination / operation |
| --- | --- | --- | --- |
| Local file or image → Assistant | Native AppKit receiver. | SwiftUI file-URL/image drop. | Import into the receiving conversation's composer; dropping does not send a message. |
| Local files/folders → SSH terminal | Pane receiver → terminal transfer request. | Window/terminal interaction → staged provider files. | Upload with SFTP to the shell-reported working directory. |
| Local files/folders → SFTP browser | Pane receiver → channel upload preparation. | Visible Workspace receiver → staged provider files. | Upload to the browser's current directory. |
| Local files → Telnet or Serial terminal | No desktop file-upload receiver; the pane receiver accepts only private terminal-path drags. | Workspace reports that Telnet does not support file upload. | No upload destination. Desktop empty panes have no native receiver. |
| Status-bar directory path → SSH, Telnet or Serial terminal | Private terminal-path text → focused terminal input. | No matching private-path receiver. | Insert shell-escaped path text; no file transfer or SFTP copy. An SFTP pane declines this payload. |
| SFTP entries → SSH terminal or another SFTP pane | Private remote-item payload. | The mobile upload receiver does not consume this private payload. | Remote copy to the SSH working directory or SFTP browser directory. |
| SFTP file → Finder / external file consumer | Lazy promised file. | No corresponding drag exporter in the mobile SFTP browser. | Download when the consumer requests the file representation. |
| Key file → Key editor | Native file receiver. | No matching Key drag receiver. | Software mode populates private-key/certificate fields; Security Key mode reads a validated FIDO2 reference. Save persists the chosen key type. |

“Terminal upload” here means **SSH terminal upload**, dependent on the current directory reported through Shell Integration. Telnet cannot use this path. SFTP browser uploads already have an explicit directory and do not require Shell Integration. The SSH convenience is available without Pro on both platforms; it still requires a connected session, transfer configuration and a usable reported working directory. SFTP browser upload uses its own explicit-directory path. For the separate native Upload File menu actions, see [Ghostty Terminal Integration](/openwiki/concepts/ghostty-terminal-integration.md).

Evidence: [desktop pane routing](../../TFM/Features/Workspaces/WorkspaceContentView.swift#L457-L549), [mobile destinations](../../TFI/Features/Workspaces/MobileWorkspace.swift#L194-L223), [mobile upload entry](../../TFI/Features/Workspaces/MobileWorkspaceView.swift#L560-L594), [desktop SSH availability](../../TFM/Features/Terminal/TerminalUploadModel.swift).

## TFM: AppKit events and representation priority

`NativeDropTarget` embeds `FileURLDropNSView` above native terminal, table, and transcript content. In `WorkspaceContentView` the order is layout receiver, drop decoration, then **native receiver as the outermost pane overlay**. A receiver attached only inside the terminal or Table can be bypassed by their AppKit views. SSH accepts local files, private SFTP items and private terminal paths; SFTP accepts local files and private SFTP items; Telnet and Serial accept **only** terminal paths; empty panes have no native receiver. These pane receivers are enabled only for the active Workspace surface while `window.dragging == nil`, keeping layout drags on their own path. A native copy proposal is not a guarantee that an upload is possible: destination checks occur after routing.

| Event / decision | Behavior |
| --- | --- |
| Construction / `isEnabled` change | Register supported pasteboard types only when enabled; unregister when disabled, including receivers born disabled. |
| `hitTest` → `participates` | Require enabled state, an in-bounds point, a supported payload, and an event other than ordinary pointer/scroll interaction. |
| `draggingEntered` / `draggingUpdated` | Recheck `supportedPayload`, publish its preferred kind for feedback, and propose `.copy`; unsupported or disabled targets clear targeting and decline. |
| `performDragOperation` | Recheck the same gate, pass the filtered payload to the feature, then clear targeting. |
| `draggingExited` / `concludeDragOperation` | Clear targeting. |

Retained invisible Workspaces and Assistant layers are the reason for both registration and callback gates. SwiftUI opacity and `allowsHitTesting(false)` alone do not remove a native destination. Unregistering prevents future destination selection, but an already tracked drag still needs the callback check. The drag pasteboard also retains old contents, so a stale file/image must never make the transparent receiver swallow ordinary clicks, hover, or scrolling.

Representation selection is ordered:

1. If the target accepts `.sftpItems` and the pasteboard contains `UTType.termindSFTPItems`, return that private payload immediately. Do not request the same provider's promised local file: that would trigger an unnecessary download and could turn one gesture into both a remote copy and a local upload.
2. Otherwise, if the pasteboard carries valid nonempty UTF-8 for `TerminalPathDrag.pasteboardType`, select `.terminalPath` before scanning file and bitmap representations. The private type is shell-escaped text, **not** a local file URL or remote-copy token. Ordinary text, malformed/empty private data and file URLs alone do not qualify as path insertions.
3. Otherwise, each item's file URL wins over bitmap data, preserving the original filename of a Finder image. Only `file:` URLs are collected; an image representation is read only when that item has no usable file URL. Finally restrict the result to the target's accepted kinds: Assistant accepts files/images, SSH accepts files/remote items/terminal paths, SFTP accepts files/remote items, Telnet and Serial accept paths only, and Key import accepts files.

`receivePaneDrop` dispatches terminal paths **first**: it focuses the SSH, Telnet or Serial pane and calls its persistent terminal owner's `pasteDroppedPath`. That checks the mounted visible terminal, acquires focus and pastes the escaped text into input, without Shell Integration or an SFTP transfer. The status-bar working-directory and SFTP-directory labels produce the private path provider (with a plain-text representation for other consumers, but no file URL). The embedded `TermindTerminalView` also has a path-only native drop fallback with visibility/window and copy-operation checks; the outer pane receiver is the primary route above Ghostty. For remaining payloads, the pane records a fresh `SFTPRemoteDropRequest` for SSH/SFTP remote items or `LocalFileDropRequest` for file URLs. Request UUID changes drive the terminal/SFTP views even when identical items are dropped again; no request is produced for unsupported/empty payloads.

```mermaid
flowchart TD
    Drag["Desktop drag pasteboard"] --> Gate{"Active receiver and supported kind?"}
    Gate -->|No| Decline["Decline or pass through"]
    Gate -->|Yes| Private{"Private SFTP items accepted?"}
    Private -->|Yes| Remote["Remote-copy request to SSH or SFTP"]
    Private -->|No| Path{"Valid private terminal path?"}
    Path -->|Yes| Insert["Focus terminal and paste escaped path"]
    Path -->|No| File{"Local file URL accepted?"}
    File -->|Yes| Upload["Local upload request to SSH or SFTP"]
    File -->|No| Other["Image attachment or decline"]
```

Desktop representation priority and pane dispatch; accepting a gesture precedes upload availability and transfer preflight.

Evidence: [native receiver](../../TFM/UI/Components/FileURLDropTarget.swift#L223-L285), [overlay and pane routing](../../TFM/Features/Workspaces/WorkspaceContentView.swift#L424-L610), [path producer](../../TFM/Features/Terminal/TerminalPathDrag.swift#L5-L27), [status-bar sources](../../TFM/Features/StatusBar/StatusBarView.swift#L266-L311), [terminal paste fallback](../../TFM/Features/Terminal/PersistentTerminalSurfaceView.swift#L100-L163), [terminal consumption](../../TFM/Features/Terminal/TerminalPlaceholderView.swift#L137-L149), [SFTP consumption](../../TFM/Features/SFTP/SFTPBrowserView.swift#L650-L661).

## TFI: window routing, terminal forwarding, and provider lifetime

Workspace uploads use `MobileWindowDropTarget`, with a noninteractive marker view defining the visible Workspace's bounds and a `UIDropInteraction` installed on its window. Its coordinator rejects hidden/transparent/detached regions, empty bounds, disabled surfaces, and windows with a presented controller. Enter/update track whether the pointer is inside the Workspace; crossing into the sidebar cancels the proposal even though the pointer remains in the same window.

Ghostty also owns a drop interaction. `MobileTerminalDropTarget` temporarily replaces that interaction with a forwarder: uploadable providers go to the Workspace coordinator, while ordinary text and web links go to Ghostty's original delegate. Uninstall restores the original interaction. Reattaching a retained terminal first removes an earlier forwarder rather than wrapping it again.

Two guards handle overlapping window and terminal callbacks: `activeInteraction` prevents a late exit from the old interaction from clearing the new target, and `performedSession` prevents the same native session from being uploaded twice. Leaving, ending, disabling, detaching, or moving between windows clears target state and removes/restores the relevant interactions.

### Loading files before UIKit releases them

`MobileDropPayloadLoader` distinguishes `.referenced` attachment loading from `.staged` upload loading. For upload, a file URL wins; otherwise it accepts directory/data file representations. A provider advertising a web URL is excluded. Text representations qualify as files only with a filename or an in-place representation, so dragged text selections keep their terminal-input behavior. When image attachments are requested, an image representation retains image semantics instead of becoming an upload file.

For staged files, copying occurs **inside** `loadFileRepresentation`'s callback, before UIKit can remove its temporary URL. Security-scoped access and `NSFileCoordinator` protect the read. Each item gets its own subdirectory, preserving same-named files independently; suggested names are reduced to a last path component, with a type-derived extension when needed. File URLs are copied through the same staging mechanism.

`MobileWorkspaceView.receiveUploadProviders` cancels earlier loading and pending preparation, captures `uploadDestination`, loads providers, then rechecks cancellation and destination identity before calling `prepareUpload`. Disappearance, Workspace changes, or destination changes cancel loading. Cancelled, empty, or immediately rejected payloads remove their staging root. Successful staging must survive navigation because queued transfers still read those files; staging creation also prunes old roots after seven days. Do not describe this as immediate cleanup on transfer completion.

A failed provider does not discard other successfully loaded files: the payload returns files and failures separately. The view can start the readable uploads and report the first provider failure. Assistant loading uses its own referenced file/image path and collects all provider failures into the composer error.

Evidence: [window delegate and deduplication](../../TFI/UI/Components/MobileWindowDropTarget.swift#L46-L192), [terminal forwarder](../../TFI/Platform/MobileTerminalDropTarget.swift#L4-L69), [payload selection/staging](../../TFI/UI/Components/MobileDropPayload.swift#L29-L229), [view cancellation and handoff](../../TFI/Features/Workspaces/MobileWorkspaceView.swift#L73-L93), [provider completion](../../TFI/Features/Workspaces/MobileWorkspaceView.swift#L569-L600).

## Assistant: dropping creates composer attachments

TFM's `ConversationAttachmentDropModifier` accepts file URLs and bitmap data; TFI's `MobileConversationAttachmentDropModifier` registers `.fileURL` and `.image` and resolves providers asynchronously. Both surfaces disable attachment drops for archived conversations and while approval or user-interaction cards block the composer. The compact desktop sidebar targets either its selected conversation or its draft and is enabled only when the Workspace surface is focused.

Both adapters call the shared `ConversationModel.importAttachmentFiles` / `importAttachmentImages`. The model creates pending chips, enforces a total of 20 loaded/pending attachments, tracks import tasks, and replaces a pending chip only if its ID still exists. Removing/cancelling that chip prevents a late result from attaching it again. File/image import failures become composer errors; they do not start a transfer or an agent run.

The live `ContextAttachmentLoading` implementation calls `ContextAttachmentImporter`: regular files are read under security-scoped access, with a 25 MiB input limit; text/PDF/modern Office content is extracted and images normalized. Directories, unsupported formats, and legacy Office files fail import. Extracted text is limited to 200,000 characters and normalized image output to 5 MiB. Therefore a native receiver accepting a file URL does not imply that its contents are a supported attachment.

Sending is a separate step. `AssistantExecutionController` refuses submission while attachments are pending, then captures and consumes accepted composer attachments with the submitted turn. First-send promotion and persistence follow the [Assistant runtime workflow](/openwiki/concepts/agent-runtime-and-assistant.md).

Evidence: [TFM adapter](../../TFM/Features/AI/ConversationTranscriptView.swift#L16-L91), [sidebar target](../../TFM/Features/Assistant/AssistantView.swift#L189-L237), [TFI adapter](../../TFI/Features/AI/MobileAssistantConversation.swift#L9-L83), [TFI gating](../../TFI/Features/AI/MobileAssistantConversation.swift#L556-L560), [pending imports](../../Frameworks/TermindApplication/Agent/ConversationModel.swift#L1800-L1873), [file importer](../../Frameworks/TermindInfrastructure/Agent/ContextAttachmentImporter.swift#L9-L83).

## SSH uploads: shell directory → SFTP preparation → queue

Shell Integration emits the working directory through OSC 7. Ghostty parses it; desktop `SSHSessionModel` and mobile `MobileWorkspace` observe that terminal state. `TerminalUploadAvailability.problem` requires a connected session, a transfer configuration, and a resolved nonempty working directory. It asks the user to wait for the shell prompt when the directory is unavailable; the transfer does not guess `/` or the user's home. The actual gate checks this state, rather than a separate “integration enabled” Boolean. See [Shell Integration](/openwiki/concepts/shell-integration.md) for hook installation and reporting.

On TFM, a local drop becomes `TerminalTransferRequest.local`; a valid registered SFTP token becomes `.remote`. After the upload-availability checks, `prepareTerminalTransfer` cancels prior preparation and captures the normalized directory, connection-attempt ID, and a new preparation ID. It prefers an independent SFTP connection from the SSH connection snapshot. If opening it fails while the attempt is still current, `TerminalUploadConnectionResolver` can open an SFTP channel on the PTY connection; cancellation must not trigger that fallback.

The temporary `SFTPChannelModel` prepares the local upload or remote-copy batch. After awaits, cancellation and connection-generation checks prevent an old preparation from publishing into a new session. Conflicts present Replace / Skip / Keep Both; otherwise the batch is enqueued. Enqueue dispatches to the corresponding local/remote planner, then releases the temporary channel owner. Disconnect/reconnect or disappearance cancels pending terminal preparation; already queued transfer lifetimes belong to the coordinator/context, not the view.

On TFI, `MobileWorkspace.prepareUpload` rejects non-file URLs or an unavailable transfer snapshot/destination, then captures a preparation ID, connection generation and destination. SSH opens an independent SFTP client from the snapshot (without the desktop PTY fallback); an SFTP Workspace borrows its browser client. After connection and home-directory lookup, and again after local upload preflight, it checks cancellation, preparation ID, generation and destination. It creates a donated transfer context only for the SSH client; the browser uses its existing context. Conflicts leave a pending batch for policy selection; a conflict-free batch enqueues immediately. Cancellation or preparation failure disconnects an owned client, while enqueue and pending-batch cancellation release its donated owner. Admitted queue references retain the transport independently of the Workspace.

```mermaid
flowchart TD
    Receive["Mobile staged file URLs"] --> Check["Validate destination and transfer snapshot"]
    Check --> Open["SSH opens SFTP client or browser borrows client"]
    Open --> Preflight["Check identity and destination around preflight"]
    Preflight --> Conflicts{"Remote conflicts?"}
    Conflicts -->|Yes| Policy["Wait for conflict policy"]
    Conflicts -->|No| Queue["Enqueue batch"]
    Policy --> Queue
    Open -->|Cancellation or failure| Cleanup["Disconnect owned client"]
    Preflight -->|Cancellation or failure| Cleanup
    Queue --> Release["Release donated owner after enqueue"]
```

Mobile upload preparation and ownership handoff; cancellation does not turn a stale preflight into a new transfer.

Post-drop `WorkspaceUploadNotice` reports preparing, queued, or rejected. A queued notice reports admission, not completion. SSH failures use transient notices rather than taking terminal focus with an operation alert; mobile SFTP failures use its browser operation-error path.

Evidence: [OSC 7 producer](../../Frameworks/TermindRemoteInfrastructure/SSH/SSHPTYChannel.swift#L439-L476), [desktop observation](../../TFM/Features/Terminal/SSHSessionModel.swift#L1093-L1104), [mobile observation](../../TFI/Features/Workspaces/MobileWorkspace.swift#L295-L299), [availability](../../Frameworks/TermindApplication/Transfers/WorkspaceUploadNotice.swift#L3-L26), [desktop resolver/request](../../TFM/Features/Terminal/TerminalPlaceholderView.swift#L8-L73), [desktop preparation/enqueue](../../TFM/Features/Terminal/TerminalPlaceholderView.swift#L248-L398), [mobile preparation](../../TFI/Features/Workspaces/MobileWorkspace.swift#L1311-L1414), [mobile enqueue/cancellation/errors](../../TFI/Features/Workspaces/MobileWorkspace.swift#L1563-L1644).

## SFTP uploads and desktop remote-file dragging

Local file drops onto a connected desktop SFTP pane call `SFTPChannelModel.prepareUpload`; mobile routes its staged URLs through `MobileWorkspace.prepareUpload` with the browser path as destination. Both use `SFTPLocalUploadPlanner`: enumerate selected files/folders, retain empty directories, exclude resolved descendants outside the selected root, and preflight remote conflicts before mutation. Directory creation, replacement and enqueue happen after a conflict policy is chosen. Cancelling preflight must not create remote directories.

### Remote source and receiving side

Desktop SFTP rows export `remoteDragProvider(for:)`. It resolves the selection through `menuTargets`, registers an `SFTPRemoteCopySource` with the app's `SFTPTransferCoordinator`, and advertises an own-process `UTType.termindSFTPItems` representation. The encoded `SFTPRemoteItemsPayload` contains a UUID token; source files, host and connection are resolved through the coordinator, not trusted as arbitrary pasteboard paths or credentials.

Dropping this payload onto another SFTP pane prepares a remote copy to its current browser directory. Dropping onto an SSH pane uses the same remote-copy planner with the terminal's reported directory and SSH upload-availability checks. Invalid/missing source tokens fail. Same-host copies into the source itself or a directory's descendants are rejected. Cross-host copies use the transfer coordinator's remote-copy path, with no local promised-file download/upload round trip.

These are the concrete file routes currently wired for terminal/SFTP interaction: **SFTP → SSH and SFTP → SFTP**. The SSH terminal adapter is a receiver here; it does not publish a corresponding private remote-file drag source. Dragging terminal text or moving an SSH Pane is a different interaction, and should not be documented as a reverse SSH → SFTP file-copy implementation. TFI has remote-copy commands, but its Workspace drag loader handles local provider files rather than the desktop private SFTP token.

### External file promises

A desktop non-directory SFTP row also advertises a public file representation. An external consumer requests it lazily, causing a download into a unique temporary `Termind/Drag` directory and completion with a local URL. Directory rows export only the private remote-item payload. The private representation can describe selected items, while the public promise is constructed for the dragged file; do not assume external export has identical selection/folder semantics.

Evidence: [local receive and remote decoding](../../TFM/Features/SFTP/SFTPBrowserView.swift#L1245-L1297), [desktop source and promise](../../TFM/Features/SFTP/SFTPBrowserView.swift#L1118-L1218), [token registry](../../Frameworks/TermindRemoteInfrastructure/Transfers/SFTPTransferCoordinator.swift#L194-L210), [local planner](../../Frameworks/TermindRemoteInfrastructure/Transfers/SFTPLocalUploadPlanner.swift#L32-L160), [remote-copy preflight/enqueue](../../Frameworks/TermindRemoteInfrastructure/Transfers/SFTPRemoteTransferPlanner.swift#L214-L313).

## TFM Key import: drop edits a buffer, Save validates

The Key editor mounts a `.files` native receiver only while private-key editing is permitted and the form is neither loading nor saving. In software mode, `receive(urls:)` calls shared `SoftwareKeyFileImporter.read` and applies the returned private key, certificate, and optional inferred name to form state. A private key can infer the complete filename only when the current name is blank; a certificate does not infer a name. Multiple private-key files resolve to the final one in the supplied order. In Security Key mode, the first dropped file is read as a `termind-fido2-v1:` reference; the reader requires a regular UTF-8 file of at most 1 MiB and validates the decoded credential before filling the reference field.

The importer reads security-scoped UTF-8 regular files up to 8 MiB, recognizing private-key text and OpenSSH user certificates. If any supplied file fails, the view receives an error before applying the result. This initial classification is not cryptographic validation or a save: background inspection derives public material, and explicit Save inspects changed key material, validates certificate matching, and calls the existing persistence path.

Evidence: [receiver enablement](../../TFM/Features/Keychain/KeychainPageView.swift#L678-L686), [drop handler](../../TFM/Features/Keychain/KeychainPageView.swift#L1006-L1025), [software importer](../../Frameworks/TermindRemoteInfrastructure/Security/SoftwareKeyFileImporter.swift#L14-L65), [Security Key reference reader](../../Frameworks/TermindRemoteInfrastructure/Security/WebAuthnSSH.swift#L86-L109), [save validation](../../TFM/Features/Keychain/KeychainPageView.swift#L805-L830).

## Shared Overlay UI

Both apps reuse [DropTargetOverlay](../../Frameworks/TermindPresentation/DropTargetOverlay.swift#L3-L113) with `DropTargetPresentation` (title, detail, symbol, accent/unavailable tone). Callers provide attachment/upload/copy/import wording and show it from native targeting state; the component supplies the translucent tint, dashed border, compact card and reduced-motion behavior. It disables hit testing and owns no payload decoding or transfer state. On desktop panes, `.terminalPath` deliberately suppresses this upload/copy overlay and uses the native copy cursor instead; unavailable SSH/SFTP destinations may still show an unavailable hover overlay and reject during preparation. This hover UI is separate from post-drop `WorkspaceUploadNotice` feedback.

## Regression map and change boundaries

| Concern | Focused evidence / tests |
| --- | --- |
| Native precedence, hidden targets, stale pasteboards, filename preservation | [FileURLDropTargetTests](../../TFMTests/FileURLDropTargetTests.swift), especially private SFTP payload versus promised local file, path-only copy proposal without transfer, and disabled registration/callback cases. [TerminalPathDragTests](../../TFMTests/TerminalPathDragTests.swift) checks shell escaping, absence of file-URL advertising, rejection of plain text/malformed private data, and refusal by an unmounted terminal. |
| Provider staging, text/link exclusion, cancellation, duplicate delivery, interaction restoration | [MobileDropTests](../../TFITests/MobileDropTests.swift): `MobileDropPayloadTests` and `MobileWorkspaceDropTests`. Includes late exits, presentation/hiding/detachment and window changes. |
| Shell-reported destination, folder preflight, partial provider failures, queue surviving closure | [MobileCommandGeneratorAndUploadTests](../../TFITests/MobileCommandGeneratorAndUploadTests.swift), including `sshUploadUsesTheReportedWorkingDirectoryAndReleasesPreflightClient` and `cancelledUploadDoesNotCreateRemoteDirectories`. |
| Desktop connection fallback and transfer ownership | [SFTPTransferContextTests](../../TFMTests/SFTPTransferContextTests.swift); cancellation cannot fall back, releasing a UI owner cannot invalidate retained transfers. |
| Remote manifests, conflicts, streaming without a temporary file | [SFTPFeatureTests](../../TFMTests/SFTPFeatureTests.swift) and [SFTPRemoteConflictResolverTests](../../FrameworkTests/SFTPRemoteConflictResolverTests.swift). |
| Attachment formats and pending-import/send lifetimes | [ContextAttachmentImporterTests](../../TFMTests/ContextAttachmentImporterTests.swift), [AssistantConversationOperationsTests](../../FrameworkTests/AssistantConversationOperationsTests.swift), [AssistantExecutionControllerTests](../../FrameworkTests/AssistantExecutionControllerTests.swift). |
| Key classification and name inference | [SoftwareKeyFileImporterTests](../../TFMTests/SoftwareKeyFileImporterTests.swift). |
| Upload availability and focus-preserving feedback | [WorkspaceUploadNoticeTests](../../FrameworkTests/WorkspaceUploadNoticeTests.swift), mobile upload tests, and [TerminalUploadNoticeTests](../../TFMTests/TerminalUploadNoticeTests.swift). The last suite requires visible-window opt-in and `TERMIND_SSH_FIXTURE`. |

When changing a drag entrypoint, preserve the existing receiver's private SFTP → private path → file/image representation priority, visibility gates and teardown behavior before changing feature dispatch. A generic text or Finder file URL must not become a terminal-path paste; a path-only drag must not become an upload. Keep staging alive until its consumers no longer need it, and distinguish cancelling a pending preparation from cancelling an admitted transfer. Extend the specific importer/planner for new semantics; a new Overlay label alone does not implement a drop operation. File-drop work does not require replacing the native Workspace List drag source described in the layout guide.
