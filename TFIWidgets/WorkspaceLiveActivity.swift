import ActivityKit
import SwiftUI
import TermindPresentation
import WidgetKit

@main
struct TermindWidgets: WidgetBundle {
    var body: some Widget { WorkspaceLiveActivity() }
}

struct WorkspaceLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WorkspaceActivityAttributes.self) { context in
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Termind Workspaces").font(.headline)
                    Spacer()
                    status(context)
                }
                sessions(context)
            }
            .padding()
            .widgetURL(context.state.destinationURL)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HostSystemIcon(asset: context.state.sessions.first?.iconAsset, size: 24, showsBackground: false)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.workspaceCount, format: .number).monospacedDigit()
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        sessions(context)
                        status(context)
                    }
                }
            } compactLeading: {
                HostSystemIcon(asset: context.state.sessions.first?.iconAsset, size: 18, showsBackground: false)
            } compactTrailing: {
                Text(context.state.workspaceCount, format: .number).monospacedDigit()
            } minimal: {
                HostSystemIcon(asset: context.state.sessions.first?.iconAsset, size: 18, showsBackground: false)
            }
            .widgetURL(context.state.destinationURL)
        }
    }

    private func sessions(_ context: ActivityViewContext<WorkspaceActivityAttributes>) -> some View {
        HStack(spacing: 8) {
            ForEach(context.state.sessions) { session in
                Link(destination: session.destinationURL) {
                    VStack(spacing: 4) {
                        HostSystemIcon(asset: session.iconAsset)
                        Text(session.title).font(.caption2).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                }
                .accessibilityLabel(session.title)
                .accessibilityHint("Open Workspace")
            }
            if context.state.workspaceCount > context.state.sessions.count {
                Link(destination: WorkspaceActivityAttributes.destinationURL) {
                    Image(systemName: "ellipsis").frame(minWidth: 36, minHeight: 44)
                }.accessibilityLabel("All Workspaces")
            }
        }
    }

    private func status(_ context: ActivityViewContext<WorkspaceActivityAttributes>) -> some View {
        Group {
            if context.isStale {
                Text("Open to Check Connections")
            } else {
                Text("\(context.state.connectedCount) connected · \(context.state.workspaceCount) workspaces")
            }
        }.font(.caption).foregroundStyle(.secondary)
    }
}
