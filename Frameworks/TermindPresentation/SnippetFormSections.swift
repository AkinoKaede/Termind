import SwiftUI
import TermindDomain

public struct SnippetOrganizationSection<PackageField: View>: View {
    @Binding private var name: String
    @Binding private var color: TagColor
    private let packageField: PackageField

    public init(name: Binding<String>, color: Binding<TagColor>, @ViewBuilder packageField: () -> PackageField) {
        _name = name
        _color = color
        self.packageField = packageField()
    }

    public var body: some View {
        Section {
            VaultNameField(text: $name)
            packageField
            VaultColorField(selection: $color)
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
