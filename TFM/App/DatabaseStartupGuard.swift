import AppKit
import TermindPersistence
import TermindPresentation

@MainActor
enum DatabaseStartupGuard {
    static func checkRunningApplications() throws {
        guard let identifier = Bundle.main.bundleIdentifier else { return }
        // Older installed versions do not acquire the store lock. Refuse to open
        // their shared sandbox even when its new lock file is still available.
        let applications = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
        try checkProcessIdentifiers(
            applications.filter { !$0.isTerminated }.map(\.processIdentifier),
            current: ProcessInfo.processInfo.processIdentifier)
    }

    static func checkProcessIdentifiers(_ identifiers: [pid_t], current: pid_t) throws {
        if identifiers.contains(where: { $0 != current }) { throw PersistentStoreAccessError.inUse }
    }

    static func presentDatabaseInUseAndExit() -> Never {
        let alert = NSAlert()
        alert.messageText = String(localized: AppStrings.Common.databaseInUse)
        alert.informativeText = String(localized: AppStrings.Common.databaseInUseExplanation)
        alert.addButton(withTitle: String(localized: AppStrings.Common.ok))
        NSApplication.shared.activate()
        alert.runModal()
        exit(EXIT_SUCCESS)
    }
}
