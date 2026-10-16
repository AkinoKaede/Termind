import Foundation
import TermindDomain

/// One glyph per menu verb.
///
/// macOS draws an icon beside each menu item and fills it in automatically for
/// standard AppKit actions — Copy, Paste, Close Window. Termind's own commands
/// carry no such selector, so a menu that mixes the two showed half a column of
/// glyphs and half a column of nothing: About and Hide had icons, the Settings
/// item sitting between them did not.
///
/// Naming the glyphs here rather than at each call site is what keeps Copy the
/// same picture in the menu bar, in the titlebar's New pull-down, in a card's
/// context menu, and in the sidebar's AppKit menus. The four surfaces are built
/// by four different mechanisms and would otherwise drift.
///
/// Values are reused from wherever the app already draws the same thing — the
/// Vault page symbols, `AppCommandRegistry`, the connection presentation — so a
/// verb wears one picture across the whole app, menus included.
nonisolated enum MenuSymbol {

    // MARK: Navigating

    static let settings = "gearshape"
    static let quickOpen = "magnifyingglass"
    static let find = "magnifyingglass"
    static let actions = "ellipsis.circle"
    static let support = "questionmark.circle"
    static let showAssistant = "sidebar.left"

    // MARK: Connecting

    static let quickConnect = "bolt"
    static let connect = "network"
    static let batchStartup = "wind"
    static let ssh = "apple.terminal"
    static let mosh = HostTerminalProtocol.mosh.symbol
    static let eternalTerminal = HostTerminalProtocol.eternalTerminal.symbol
    static let telnet = "text.rectangle"
    static let sftp = "folder"

    // MARK: Creating

    static let newWindow = "macwindow.badge.plus"
    static let moveToNewWindow = "macwindow.on.rectangle"
    static let newChat = "plus.bubble"
    static let newHost = "plus.rectangle"
    static let newGroup = "folder.badge.plus"
    static let newPackage = "folder.badge.plus"
    static let newFolder = "folder.badge.plus"
    static let newSnippet = "curlybraces"
    static let saveAsSnippet = "curlybraces"
    static let newIdentity = "person.badge.plus"
    static let generateKey = "key.fill"
    static let generateCommand = "sparkles"

    // MARK: Moving things in and out

    static let importItem = "square.and.arrow.down"
    static let download = "square.and.arrow.down"
    static let export = "square.and.arrow.up"
    static let upload = "square.and.arrow.up"

    // MARK: Acting on one thing

    static let details = "info.circle"
    static let pause = "pause"
    static let selectDevices = "slider.horizontal.3"
    static let open = "arrow.up.right"
    static let openFullScreen = "arrow.up.left.and.arrow.down.right"
    static let edit = "pencil"
    static let rename = "character.cursor.ibeam"
    static let resetName = "arrow.uturn.backward"
    static let duplicate = "plus.square.on.square"
    static let copy = "doc.on.doc"
    static let insert = "text.insert"
    static let paste = "doc.on.clipboard"
    static let execute = "play"
    static let start = "play"
    static let stop = "stop.fill"
    static let refresh = "arrow.clockwise"
    static let showHiddenFiles = "eye"
    static let hideHiddenFiles = "eye.slash"
    static let editPath = "text.cursor"
    static let editPermissions = "lock"
    static let test = "checkmark.circle"
    static let pin = "pin"
    static let unpin = "pin.slash"
    static let archive = "archivebox"
    static let unarchive = "arrow.uturn.backward"
    static let delete = "trash"

    // MARK: Workspaces

    /// What the sidebar already draws beside a merged Workspace, so the Window
    /// menu names the same thing the Navigator does.
    ///
    /// The whole `⌘1…⌘9` run wears this one picture, the way Safari's Window
    /// menu lists every tab under the same glyph. A per-workspace symbol would
    /// say what each one holds, but a menu's icon column is meant to be read
    /// down as a group, not item by item.
    static let workspace = "rectangle.split.2x1"
    static let nextWorkspace = "chevron.forward"
    static let previousWorkspace = "chevron.backward"
    /// The pair under Duplicate and under the status bar's Open with — the one
    /// you are in, against one that does not exist yet.
    static let currentWorkspace = "rectangle.split.2x1"
    static let newWorkspace = "rectangle.badge.plus"
    static let separatePanes = "arrow.left.and.right"
    static let splitRight = "rectangle.split.2x1"
    static let splitDown = "rectangle.split.1x2"
    static let closeWorkspace = "xmark"
    static let reopenWorkspace = "arrow.uturn.backward"

    // MARK: Lists and history

    static let filterByTag = "tag"
    static let clearFilter = "xmark.circle"
    static let clearHistory = "clock.badge.xmark"

    /// Every glyph above, so `MenuSymbolTests` can confirm each one resolves to
    /// a real SF Symbol. A misspelled name draws nothing and says nothing, which
    /// is exactly the kind of mistake no one notices in review.
    static let all: [String] = [
        settings, quickOpen, find, actions, support, showAssistant,
        quickConnect, connect, batchStartup, ssh, telnet, sftp,
        newChat, newHost, newGroup, newPackage, newFolder, newSnippet, saveAsSnippet,
        newIdentity, generateKey, generateCommand,
        importItem, download, export, upload,
        details, pause, selectDevices, open, openFullScreen, edit, rename, resetName, duplicate, copy, insert, paste,
        execute, start, stop, refresh, showHiddenFiles, hideHiddenFiles, editPath,
        editPermissions, test,
        pin, unpin, archive, unarchive, delete,
        workspace, nextWorkspace, previousWorkspace, currentWorkspace, newWorkspace, newWindow, moveToNewWindow,
        separatePanes, splitRight, splitDown, closeWorkspace, reopenWorkspace,
        filterByTag, clearFilter, clearHistory,
    ]
}
