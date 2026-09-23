import Foundation
import SwiftParser
import SwiftSyntax

final class SwiftDataRepositoryDeclarationVisitor: SyntaxVisitor {
    private static let namePattern = try! NSRegularExpression(
        pattern: #"^SwiftData[A-Za-z0-9_]*Repository$"#
    )

    private(set) var containsDeclaration = false

    init() {
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        record(node.name)
        return .visitChildren
    }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        record(node.name)
        return .visitChildren
    }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        record(node.name)
        return .visitChildren
    }

    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        record(node.name)
        return .visitChildren
    }

    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
        record(node.name)
        return .visitChildren
    }

    override func visit(_ node: TypeAliasDeclSyntax) -> SyntaxVisitorContinueKind {
        record(node.name)
        return .visitChildren
    }

    private func record(_ token: TokenSyntax) {
        var name = token.text
        if name.count >= 2, name.first == "`", name.last == "`" {
            name.removeFirst()
            name.removeLast()
        }
        let range = NSRange(name.startIndex..<name.endIndex, in: name)
        if Self.namePattern.firstMatch(in: name, range: range) != nil {
            containsDeclaration = true
        }
    }
}

guard CommandLine.arguments.count == 2 else {
    throw CocoaError(.fileReadInvalidFileName)
}

let requestURL = URL(fileURLWithPath: CommandLine.arguments[1])
let request = try JSONDecoder().decode([String].self, from: Data(contentsOf: requestURL))
let results = try request.map { source in
    let tree = Parser.parse(source: source)
    guard !tree.hasError else {
        throw CocoaError(.fileReadCorruptFile)
    }
    let visitor = SwiftDataRepositoryDeclarationVisitor()
    visitor.walk(tree)
    return visitor.containsDeclaration
}
let output = try JSONEncoder().encode(results)
try FileHandle.standardOutput.write(contentsOf: output)
try FileHandle.standardOutput.write(contentsOf: Data("\n".utf8))
