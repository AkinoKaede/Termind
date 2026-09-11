import Foundation
import TermindApplication

#if canImport(AppKit)
    import AppKit
#endif

typealias AppLanguage = TermindApplication.AppLanguage
typealias AppLocalization = TermindApplication.AppLocalization

#if canImport(AppKit)
    @MainActor
    enum AppRelauncher {
        static func relaunch() {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            configuration.createsNewApplicationInstance = true
            NSWorkspace.shared.openApplication(
                at: Bundle.main.bundleURL,
                configuration: configuration
            ) { _, error in
                guard error == nil else {
                    Task { @MainActor in NSSound.beep() }
                    return
                }
                Task { @MainActor in NSApp.terminate(nil) }
            }
        }
    }
#endif
