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
                    workspaceCount(context.state.workspaceCount)
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                HostSystemIcon(
                    asset: context.state.sessions.first?.iconAsset,
                    systemImageName: context.state.sessions.first?.iconSystemName, size: 18, showsBackground: false)
            } compactTrailing: {
                Text(context.state.workspaceCount, format: .number).monospacedDigit()
            } minimal: {
                HostSystemIcon(
                    asset: context.state.sessions.first?.iconAsset,
                    systemImageName: context.state.sessions.first?.iconSystemName, size: 18, showsBackground: false)
            }
            .widgetURL(context.state.destinationURL)
        }
    }

    private func sessions(_ context: ActivityViewContext<WorkspaceActivityAttributes>) -> some View {
        ViewThatFits(in: .horizontal) {
            sessionRow(
                context,
                maximumVisibleCount: WorkspaceActivityAttributes.ContentState.maximumPresentedSessionCount)
            sessionRow(context, maximumVisibleCount: 5)
            sessionRow(context, maximumVisibleCount: 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sessionRow(
        _ context: ActivityViewContext<WorkspaceActivityAttributes>,
        maximumVisibleCount: Int
    ) -> some View {
        let visibleSessions = context.state.sessions.prefix(maximumVisibleCount)

        return HStack(spacing: 8) {
            ForEach(visibleSessions) { session in
                Link(destination: session.destinationURL) {
                    HostSystemIcon(asset: session.iconAsset, systemImageName: session.iconSystemName)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel(session.title)
                .accessibilityHint("Open Workspace")
            }
            if context.state.workspaceCount > visibleSessions.count {
                Link(destination: WorkspaceActivityAttributes.destinationURL) {
                    Image(systemName: "ellipsis")
                        .frame(minWidth: 44, minHeight: 44)
                }.accessibilityLabel("All Workspaces")
            }
        }
        .fixedSize(horizontal: true, vertical: false)
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
        Text(AppStrings.Workspace.count(count))
    }
}
