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
                HStack(spacing: 10) {
                    appIcon(size: 28)
                    status(context)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Spacer(minLength: 0)
                }
                sessions(context)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .widgetURL(context.state.destinationURL)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 8) {
                        appIcon(size: 24)
                        workspaceCount(context.state.workspaceCount)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    sessions(context)
                }
                .contentMargins(.horizontal, 20)
                .contentMargins(.bottom, 12)
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
        let visibleSessions = context.state.sessions.prefix(
            WorkspaceActivityAttributes.ContentState.maximumPresentedSessionCount)

        return HStack(spacing: 8) {
            ForEach(visibleSessions) { session in
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
            if context.state.workspaceCount > visibleSessions.count {
                Link(destination: WorkspaceActivityAttributes.destinationURL) {
                    Image(systemName: "ellipsis")
                        .frame(minWidth: 44, maxWidth: .infinity, minHeight: 44)
                }.accessibilityLabel("All Workspaces")
            }
        }
    }

    private func appIcon(size: CGFloat) -> some View {
        Image("TermindLiveActivityIcon")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .foregroundStyle(.primary)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    private func workspaceCount(_ count: Int) -> Text {
        switch count {
        case 1: Text("One workspace")
        case 2: Text("Two workspaces")
        default: Text("\(count) workspaces")
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
