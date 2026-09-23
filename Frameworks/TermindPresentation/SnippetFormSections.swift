import SwiftUI

public struct SnippetOrganizationSection<PackageField: View>: View {
    @Binding private var name: String
    private let packageField: PackageField

    public init(name: Binding<String>, @ViewBuilder packageField: () -> PackageField) {
        _name = name
        self.packageField = packageField()
    }

    public var body: some View {
        Section {
            VaultNameField(text: $name)
            packageField
        }
    }
}

public struct SnippetScriptSection<Assessment: View>: View {
    @Binding private var script: String
    private let minHeight: CGFloat
    private let assessment: Assessment

    public init(
        script: Binding<String>, minHeight: CGFloat,
        @ViewBuilder assessment: () -> Assessment
    ) {
        _script = script
        self.minHeight = minHeight
        self.assessment = assessment()
    }

    public var body: some View {
        Section(AppStrings.Snippets.script.swiftUIKey) {
            TextEditor(text: $script)
                .multilineTextAlignment(.leading)
                .font(.body.monospaced())
                .frame(minHeight: minHeight)
                #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                #endif
            assessment
        }
    }
}
