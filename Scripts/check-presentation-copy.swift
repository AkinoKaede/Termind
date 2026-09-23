import Foundation
import SwiftParser
import SwiftSyntax

/// Uses Xcode's parser so comments, interpolation expressions, URLs, symbols,
/// HTTP fields and identifiers cannot be mistaken for UI copy by a text grep.
final class CopyBoundaryVisitor: SyntaxVisitor {
    private let path: String
    private let locations: SourceLocationConverter
    private(set) var violations: [String] = []

    private let presentationCalls: Set<String> = [
        "Text", "Button", "Label", "TextField", "SecureField", "Section", "LabeledContent", "Picker",
        "ContentUnavailableView", "ProgressView", "Toggle", "Menu", "Link", "CommandMenu", "TableColumn", "Window",
        "LocalizedStringResource", "LocalizedStringKey", "navigationTitle", "help", "accessibilityLabel",
        "accessibilityValue", "accessibilityHint", "alert", "confirmationDialog", "dismissalConfirmationDialog",
        "localized", "pageTitle", "feature", "statusCard", "emptyRow", "permissionHeader",
    ]

    init(path: String, tree: SourceFileSyntax) {
        self.path = path
        locations = SourceLocationConverter(fileName: path, tree: tree)
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: StringLiteralExprSyntax) -> SyntaxVisitorContinueKind {
        let prose = node.segments.compactMap { $0.as(StringSegmentSyntax.self)?.content.text }.joined()
        guard prose.contains(where: { $0.isLetter }), isPresentationLiteral(node) else { return .visitChildren }
        let line = locations.location(for: node.positionAfterSkippingLeadingTrivia).line
        violations.append(
            "\(path):\(line): move presentation copy into TermindPresentation: \(node.trimmedDescription)")
        return .visitChildren
    }

    private func isPresentationLiteral(_ node: StringLiteralExprSyntax) -> Bool {
        var ancestor = node.parent
        var argument: LabeledExprSyntax?
        while let current = ancestor {
            if current.is(MacroExpansionExprSyntax.self) { return false }
            if let labeled = current.as(LabeledExprSyntax.self), argument == nil { argument = labeled }
            if let call = current.as(FunctionCallExprSyntax.self) {
                let name =
                    call.calledExpression.as(MemberAccessExprSyntax.self)?.declName.baseName.text
                    ?? call.calledExpression.as(DeclReferenceExprSyntax.self)?.baseName.text ?? ""
                guard let argument else { return false }
                let label = argument.label?.text ?? ""
                if name == "String" { return label == "localized" }
                if name == "Text", label == "verbatim" { return true }
                if ["title", "prompt", "help", "emptyDescription", "actionTitle"].contains(label) { return true }
                return label.isEmpty && call.arguments.first?.id == argument.id && presentationCalls.contains(name)
            }
            if let binding = current.as(PatternBindingSyntax.self), let type = binding.typeAnnotation?.type {
                return type.trimmedDescription.contains("LocalizedString")
            }
            if let function = current.as(FunctionDeclSyntax.self), let type = function.signature.returnClause?.type {
                return type.trimmedDescription.contains("LocalizedString")
            }
            ancestor = current.parent
        }
        return false
    }
}

let repository = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
var violations: [String] = []
for app in ["TFM", "TFI"] {
    let directory = repository.appending(path: app)
    guard let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else {
        throw CocoaError(.fileReadNoSuchFile)
    }
    for case let file as URL in files where file.pathExtension == "swift" {
        let source = try String(contentsOf: file, encoding: .utf8)
        let tree = Parser.parse(source: source)
        let visitor = CopyBoundaryVisitor(path: file.path, tree: tree)
        visitor.walk(tree)
        violations += visitor.violations
    }
}
if !violations.isEmpty {
    FileHandle.standardError.write(Data((violations.sorted().joined(separator: "\n") + "\n").utf8))
    exit(1)
}
print("TFM and TFI presentation copy uses shared resources.")
