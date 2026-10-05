import SwiftUI
import TermindDomain

public struct WebAuthnVerificationPicker: View {
    @Binding private var selection: SecurityKeyCredential.UserVerification

    public init(selection: Binding<SecurityKeyCredential.UserVerification>) {
        _selection = selection
    }

    public var body: some View {
        Picker(AppStrings.SecurityKey.verification.swiftUIKey, selection: $selection) {
            Text(AppStrings.SecurityKey.required).tag(SecurityKeyCredential.UserVerification.required)
            Text(AppStrings.SecurityKey.preferred).tag(SecurityKeyCredential.UserVerification.preferred)
            Text(AppStrings.SecurityKey.discouraged).tag(SecurityKeyCredential.UserVerification.discouraged)
        }
    }
}
