import Foundation
import TermindApplication
import TermindPresentation

extension KeyExportModel {
    var summary: LocalizedStringResource {
        let failures = states.values.filter { if case .failed = $0 { true } else { false } }.count
        if failures > 0 {
            return AppStrings.Keychain.exportedFailed(count1: states.count - failures, failures: failures)
        }
        return states.count == 1
            ? AppStrings.Keychain.exportedTo1Host : AppStrings.Keychain.exportedToHosts(states.count)
    }

}
