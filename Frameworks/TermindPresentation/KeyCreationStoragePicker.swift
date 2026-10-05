import SwiftUI
import TermindDomain

/// Keeps the software storage selection while the user switches to an external authenticator.
public struct KeyCreationStoragePicker: View {
    @Binding private var storage: KeyStorage
    @Binding private var usesWebAuthn: Bool
    private let allowsWebAuthn: Bool
    private let allowsSecureEnclave: Bool
    private let secureEnclaveAvailable: Bool

    public init(
        storage: Binding<KeyStorage>, usesWebAuthn: Binding<Bool>, allowsWebAuthn: Bool = true,
        allowsSecureEnclave: Bool = false, secureEnclaveAvailable: Bool = false
    ) {
        _storage = storage
        _usesWebAuthn = usesWebAuthn
        self.allowsWebAuthn = allowsWebAuthn
        self.allowsSecureEnclave = allowsSecureEnclave
        self.secureEnclaveAvailable = secureEnclaveAvailable
    }

    public var body: some View {
        Picker(AppStrings.Keychain.storeIn.swiftUIKey, selection: selection) {
            #if os(macOS)
                Label(AppStrings.Keychain.thisMac.swiftUIKey, systemImage: "lock.laptopcomputer")
                    .tag(KeyStorage.thisDevice)
            #else
                Label(AppStrings.Keychain.thisDevice.swiftUIKey, systemImage: "ipad.and.iphone")
                    .tag(KeyStorage.thisDevice)
            #endif
            Label(AppStrings.Keychain.iCloud.swiftUIKey, systemImage: "icloud.fill")
                .tag(KeyStorage.iCloud)
            if allowsSecureEnclave {
                Label(AppStrings.Keychain.secureEnclave.swiftUIKey, systemImage: "checkmark.shield.fill")
                    .tag(KeyStorage.secureEnclave)
                    .disabled(!secureEnclaveAvailable)
            }
            if allowsWebAuthn {
                Label(AppStrings.SecurityKey.title.swiftUIKey, systemImage: "key.radiowaves.forward.fill")
                    .tag(KeyStorage.external)
            }
        }
    }

    private var selection: Binding<KeyStorage> {
        Binding(
            get: { usesWebAuthn ? .external : storage },
            set: { value in
                usesWebAuthn = value == .external
                if value != .external { storage = value }
            })
    }
}
