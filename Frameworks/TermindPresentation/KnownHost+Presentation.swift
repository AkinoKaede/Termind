import Foundation
import TermindDomain

extension KnownHostEntry {
    public var presentationTitle: String {
        isHashed ? String(localized: "Hashed Address") : displayAddress
    }
}
