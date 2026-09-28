import SwiftUI
import TermindApplication

public struct MCPImportFeedback: View {
    private let report: MCPImportReport?
    private let problem: MCPImportProblem?

    public init(report: MCPImportReport?, problem: MCPImportProblem?) {
        self.report = report
        self.problem = problem
    }

    public var body: some View {
        if let report {
            Text(AppStrings.MCP.importedServers(report.importedCount))
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(report.issues, id: \.index) { issue in
                Text(AppStrings.MCP.importEntryProblem(issue.index, String(localized: issue.problem.message)))
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        if let problem {
            Text(problem.message)
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

extension MCPImportProblem {
    public var message: LocalizedStringResource {
        switch self {
        case .unreadableFile: AppStrings.MCP.importUnreadableFile
        case .invalidDocument: AppStrings.MCP.importInvalidDocument
        case .invalidEntry: AppStrings.MCP.importInvalidEntry
        case .unsupportedTransport: AppStrings.MCP.importUnsupportedTransport
        case .invalidURL: AppStrings.Settings.enterAnHttpOrHttpsMcpUrl
        case .unresolvedVariable: AppStrings.MCP.importUnresolvedVariable
        case .unsupportedAuthentication: AppStrings.MCP.importUnsupportedAuthentication
        case .saveFailed: AppStrings.MCP.importSaveFailed
        case .secretFailed: AppStrings.MCP.importSecretFailed
        case .secretCleanupFailed: AppStrings.MCP.importSecretCleanupFailed
        }
    }
}
