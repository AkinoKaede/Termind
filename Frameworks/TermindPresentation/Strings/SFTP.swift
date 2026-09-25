import Foundation

extension AppStrings {
    public nonisolated enum SFTP {

        public static var appStoreProgress: LocalizedStringResource {
            "App Store…"
        }

        public static var applyToAllConflicts: LocalizedStringResource {
            "Use this choice for all conflicts in this batch."
        }

        public static var copyAs: LocalizedStringResource {
            "Copy As"
        }

        public static func copyItems(_ count: Int) -> LocalizedStringResource {
            "Copy \(count) Items"
        }

        public static var dateModified: LocalizedStringResource {
            "Date Modified"
        }

        public static func deleteConfirmation(_ value: String) -> LocalizedStringResource {
            "Delete \(value)?"
        }

        public static func deleteItems(_ count: Int) -> LocalizedStringResource {
            "Delete \(count) Items"
        }

        public static func deleteItemsConfirmation(_ count: Int) -> LocalizedStringResource {
            "Delete \(count) items?"
        }

        public static var deletionCancelled: LocalizedStringResource {
            "Deletion cancelled"
        }

        public static func downloadItems(_ count: Int) -> LocalizedStringResource {
            "Download \(count) Items"
        }

        public static var editPath: LocalizedStringResource {
            "Edit Path"
        }

        public static var editPermissions: LocalizedStringResource {
            "Edit Permissions"
        }

        public static func existingItemCount(_ count: Int) -> LocalizedStringResource {
            "\(count) items already exist"
        }

        public static var fileAccess: LocalizedStringResource {
            "File Access"
        }

        public static var folderName: LocalizedStringResource {
            "Folder Name"
        }

        public static var forward: LocalizedStringResource {
            "Forward"
        }

        public static var gid: LocalizedStringResource {
            "GID"
        }

        public static var importEditedCopyProgress: LocalizedStringResource {
            "Import Edited Copy…"
        }

        public static func items(_ count: Int) -> LocalizedStringResource {
            "\(count) items"
        }

        public static var loading: LocalizedStringResource {
            "Loading"
        }

        public static var mode: LocalizedStringResource {
            "Mode"
        }

        public static var names: LocalizedStringResource {
            "Names"
        }

        public static var noTransfers: LocalizedStringResource {
            "No Transfers"
        }

        public static var octalPermissions: LocalizedStringResource {
            "Octal permissions"
        }

        public static var oneExistingItem: LocalizedStringResource {
            "1 item already exists"
        }

        public static var openWith: LocalizedStringResource {
            "Open With"
        }

        public static var openWithProgress: LocalizedStringResource {
            "Open With…"
        }

        public static var otherProgress: LocalizedStringResource {
            "Other…"
        }

        public static var ownership: LocalizedStringResource {
            "Ownership"
        }

        public static var parentDirectory: LocalizedStringResource {
            "Parent Directory"
        }

        public static var path: LocalizedStringResource {
            "Path"
        }

        public static var paths: LocalizedStringResource {
            "Paths"
        }

        public static var remotePath: LocalizedStringResource {
            "Remote Path"
        }

        public static var theRemoteHomeDirectoryIsUnavailable: LocalizedStringResource {
            "The remote home directory is unavailable."
        }

        public static var thisFolderIsEmpty: LocalizedStringResource {
            "This folder is empty"
        }

        public static var uid: LocalizedStringResource {
            "UID"
        }

        public static var oneActiveTransfer: LocalizedStringResource {
            "1 active transfer"
        }

        public static var oneFailedTransfer: LocalizedStringResource {
            "1 failed transfer"
        }

        public static func browseWithSftp(_ value: String) -> LocalizedStringResource {
            "Browse with SFTP · \(value)"
        }

        public static var cancelTransfer: LocalizedStringResource {
            "Cancel transfer"
        }

        public static var editedCopyFormatRequirement: LocalizedStringResource {
            "Choose an edited copy with the same file format as the original."
        }

        public static var clearFileHistoryForThisHostConfirmation: LocalizedStringResource {
            "Clear File History for this Host?"
        }

        public static var clearFinished: LocalizedStringResource {
            "Clear Finished"
        }

        public static var clearFinishedTransfersConfirmation: LocalizedStringResource {
            "Clear Finished Transfers?"
        }

        public static var sftpPathExplanation: LocalizedStringResource {
            "Click the path to open this directory with SFTP. Right-click to copy it or open it in a new workspace."
        }

        public static var download: LocalizedStringResource {
            "Download"
        }

        public static var foldersYouVisitAndFilesYouOpenAppearHere: LocalizedStringResource {
            "Folders you visit and files you open appear here."
        }

        public static var hideHiddenFiles: LocalizedStringResource {
            "Hide Hidden Files"
        }

        public static var keepBoth: LocalizedStringResource {
            "Keep Both"
        }

        public static var newFolder: LocalizedStringResource {
            "New Folder"
        }

        public static var noInstalledAppCanOpenThisFile: LocalizedStringResource {
            "No installed app can open this file."
        }

        public static var openDirectoryWithSFTPHelp: LocalizedStringResource {
            "Open current directory with SFTP — right-click for more options"
        }

        public static var openWithSftp: LocalizedStringResource {
            "Open with SFTP"
        }

        public static var pauseTransfer: LocalizedStringResource {
            "Pause transfer"
        }

        public static var permissions: LocalizedStringResource {
            "Permissions"
        }

        public static var replace: LocalizedStringResource {
            "Replace"
        }

        public static var resumeTransfer: LocalizedStringResource {
            "Resume transfer"
        }

        public static var sftp: LocalizedStringResource {
            "SFTP"
        }

        public static var sftpError: LocalizedStringResource {
            "SFTP Error"
        }

        public static var showHiddenFiles: LocalizedStringResource {
            "Show Hidden Files"
        }

        public static var skipExisting: LocalizedStringResource {
            "Skip Existing"
        }

        public static var theSftpConnectionIsNotAvailable: LocalizedStringResource {
            "The SFTP connection is not available."
        }

        public static var theSftpLinkRequiresADirectoryButItsPathIsAFile: LocalizedStringResource {
            "The SFTP link requires a directory, but its path is a file."
        }

        public static var theCopiedSftpItemsAreInvalid: LocalizedStringResource {
            "The copied SFTP items are invalid."
        }

        public static var theRemoteFileIsNoLongerAvailable: LocalizedStringResource {
            "The remote file is no longer available."
        }

        public static var theUploadDestinationIsUnavailable: LocalizedStringResource {
            "The upload destination is unavailable."
        }

        public static var transfers: LocalizedStringResource {
            "Transfers"
        }

        public static var unknown: LocalizedStringResource {
            "Unknown"
        }

        public static var upload: LocalizedStringResource {
            "Upload"
        }

        public static func activeTransfers(_ activeCount: Int) -> LocalizedStringResource {
            "\(activeCount) active transfers"
        }

        public static func failedTransfers(_ failedCount: Int) -> LocalizedStringResource {
            "\(failedCount) failed transfers"
        }

        public static var executableFileWarning: LocalizedStringResource {
            "This remote file may contain executable content. Review it before opening."
        }

        public static var pendingEditedFilesWarning: LocalizedStringResource {
            "Your edited files have not all been uploaded. Pending edits will not be restored next time."
        }

        public static var noUploadableFilesWereFound: LocalizedStringResource {
            "No uploadable files were found."
        }
        public static var quitWithUnuploadedChangesConfirmation: LocalizedStringResource {
            "Quit with unuploaded changes?"
        }
        public static var uploadUnavailable: LocalizedStringResource {
            "Can't Upload Here"
        }
        public static var editedCopyFormatExplanation: LocalizedStringResource {
            "Save this copy separately to keep the original remote file format."
        }
        public static var unableToCopyItems: LocalizedStringResource { "Unable to copy SFTP items." }
        public static var homeDirectoryMustBeAbsolute: LocalizedStringResource {
            "The remote home directory is not absolute."
        }
        public static var promisedDownloadIncomplete: LocalizedStringResource {
            "The promised download did not finish."
        }
        public static func remainingDeletionItems(_ count: Int) -> LocalizedStringResource {
            "\nand \(count) more"
        }

        public static func deletionWarning(paths: String, remainder: String) -> LocalizedStringResource {
            "\(paths)\(remainder)\n\nDirectories are deleted recursively. This cannot be undone."
        }
        public static var recursiveDeletionWarning: LocalizedStringResource {
            "Directories are deleted recursively. This cannot be undone."
        }
        public static var modifiedDate: LocalizedStringResource {
            "Date"
        }
        public static var keepLocalCopy: LocalizedStringResource {
            "Keep Local Copy"
        }
        public static var permissionGroup: LocalizedStringResource { "Group" }
    }
}
