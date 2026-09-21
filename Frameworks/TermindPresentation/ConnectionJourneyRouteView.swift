import SwiftUI
import TermindApplication

#if os(macOS)
    import AppKit
#endif

/// The same route, checkpoints and progress animation on desktop and mobile.
public struct ConnectionJourneyRouteView: View {
    let journey: ConnectionJourney
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    public init(journey: ConnectionJourney) { self.journey = journey }
    @ViewBuilder
    public var body: some View {
        if !journey.endpoints.isEmpty {
            GeometryReader { geometry in
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        route(viewportWidth: geometry.size.width)
                            .padding(.vertical, 30)
                            #if os(macOS)
                                .background { JourneyHorizontalScrollerHider() }
                            #endif
                    }
                    .scrollIndicators(.hidden)
                    .onChange(of: journey.activeEndpointIndex) { _, _ in
                        scrollToActivity(proxy)
                    }
                    .onChange(of: journey.checkpoint) { _, _ in
                        scrollToActivity(proxy)
                    }
                    .onChange(of: journey.localRequirementEndpointIndex) { _, _ in
                        scrollToActivity(proxy)
                    }
                }
            }
            .frame(height: 152)
        }
    }

    private func route(viewportWidth: CGFloat) -> some View {
        let nodeLaneHeight: CGFloat = 56
        let endpointSpacing: CGFloat = 190
        let labelWidth: CGFloat = 150
        let gapBetweenEndpointFrames = endpointSpacing - labelWidth
        let routeWidth = labelWidth + CGFloat(max(0, journey.endpoints.count - 1)) * endpointSpacing
        let canvasWidth = max(viewportWidth, routeWidth + 58)

        return ZStack(alignment: .topLeading) {
            HStack(spacing: 0) {
                ForEach(journey.endpoints.indices.dropFirst(), id: \.self) { index in
                    JourneySegmentView(
                        state: segmentState(for: index),
                        checkpoint: journey.checkpoint?.endpointIndex == index
                            ? journey.checkpoint?.kind : journey.completedCheckpoints[index],
                        checkpointIsWaiting: journey.checkpoint?.endpointIndex == index,
                        reduceMotion: reduceMotion
                    )
                    .frame(width: endpointSpacing, height: nodeLaneHeight)
                    .id("segment-\(index)")
                }
            }
            .padding(.leading, labelWidth / 2)

            HStack(alignment: .top, spacing: gapBetweenEndpointFrames) {
                ForEach(Array(journey.endpoints.enumerated()), id: \.element.id) { index, endpoint in
                    JourneyEndpointView(
                        endpoint: endpoint,
                        purpose: journey.purpose,
                        state: endpointState(for: index),
                        showsActivity: activityEndpointIndex == index,
                        localRequirement: journey.localRequirementEndpointIndex == index
                            ? journey.localRequirement : nil,
                        reduceMotion: reduceMotion
                    )
                    .frame(width: labelWidth, height: 92, alignment: .top)
                    .id("endpoint-\(index)")
                }
            }
        }
        .frame(width: routeWidth, height: 92, alignment: .topLeading)
        .frame(width: canvasWidth, height: 92, alignment: .center)
    }

    private var activityEndpointIndex: Int? {
        guard journey.phase == .connecting, journey.checkpoint == nil,
            let lastIndex = journey.endpoints.indices.last
        else { return nil }
        let candidate: Int
        if journey.activeEndpointIndex > journey.completedEndpointIndex {
            candidate = journey.activeEndpointIndex - 1
        } else {
            candidate = journey.completedEndpointIndex
        }
        return min(max(journey.endpoints.startIndex, candidate), lastIndex)
    }

    private func endpointState(for index: Int) -> JourneyVisualState {
        if case .failed = journey.phase, index <= journey.activeEndpointIndex { return .failed }
        if index <= journey.completedEndpointIndex { return .complete }
        return .pending
    }

    private func segmentState(for targetIndex: Int) -> JourneyVisualState {
        if case .failed = journey.phase, targetIndex <= journey.activeEndpointIndex { return .failed }
        if targetIndex <= journey.completedEndpointIndex { return .complete }
        if targetIndex == journey.activeEndpointIndex { return .active }
        return .pending
    }

    private func scrollToActivity(_ proxy: ScrollViewProxy) {
        guard !reduceMotion, let lastIndex = journey.endpoints.indices.last else { return }
        let candidate =
            journey.checkpoint?.endpointIndex
            ?? journey.localRequirementEndpointIndex
            ?? journey.activeEndpointIndex
        let index = min(max(journey.endpoints.startIndex, candidate), lastIndex)
        let target =
            journey.checkpoint != nil && index > journey.endpoints.startIndex
            ? "segment-\(index)" : "endpoint-\(index)"
        withAnimation(.easeInOut(duration: 0.24)) {
            proxy.scrollTo(target, anchor: .center)
        }
    }

}

#if os(macOS)
    /// SwiftUI may recreate the native horizontal scroller when its content
    /// changes even when indicators are hidden. Keep the underlying scroll view
    /// scrollable while preventing AppKit from installing a visible scroller.
    private struct JourneyHorizontalScrollerHider: NSViewRepresentable {
        final class HiderView: NSView {
            override func viewDidMoveToSuperview() {
                super.viewDidMoveToSuperview()
                configureScrollView()
            }

            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                configureScrollView()
            }

            override func layout() {
                super.layout()
                configureScrollView()
            }

            func configureScrollView() {
                guard let scrollView = enclosingScrollView else { return }
                scrollView.hasHorizontalScroller = false
                scrollView.horizontalScroller?.isHidden = true
            }
        }

        func makeNSView(context: Context) -> HiderView { HiderView(frame: .zero) }

        func updateNSView(_ nsView: HiderView, context: Context) {
            nsView.configureScrollView()
        }
    }
#endif

private enum JourneyVisualState {
    case pending
    case active
    case complete
    case failed

    var color: Color {
        switch self {
        case .pending: .secondary.opacity(0.55)
        case .active, .complete: Color.accentColor
        case .failed: Color.red
        }
    }
}

private struct JourneyEndpointView: View {
    let endpoint: ConnectionEndpoint
    let purpose: ConnectionPurpose
    let state: JourneyVisualState
    let showsActivity: Bool
    let localRequirement: ConnectionJourney.LocalRequirement?
    let reduceMotion: Bool

    var body: some View {
        ZStack(alignment: .top) {
            ZStack {
                if showsActivity {
                    JourneyActivityRing(size: 52, reduceMotion: reduceMotion)
                }
                Circle()
                    .fill(.background)
                    .frame(width: 38, height: 38)
                Circle()
                    .fill(state.color)
                    .frame(width: 36, height: 36)
                    .overlay {
                        Image(systemName: symbol)
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(Color.white)
                    }
            }
            .frame(width: 56, height: 56)

            Text(endpoint.name)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.top, 64)
        }
        .frame(height: 92, alignment: .top)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(endpoint.name), \(accessibilityState)")
    }

    private var symbol: String {
        if let localRequirement {
            switch localRequirement {
            case .identity: return "person.fill"
            case .telnetPassword: return "key.fill"
            case .passphrase: return "key.fill"
            case .proxyAuthentication: return "lock.shield.fill"
            }
        }
        switch endpoint.role {
        case .local:
            #if os(macOS)
                return "laptopcomputer"
            #else
                return "ipad.and.iphone"
            #endif
        case .jump: return "server.rack"
        case .destination:
            return switch purpose {
            case .sshSession: "apple.terminal.fill"
            case .telnetSession: "terminal.fill"
            case .sftpChannel: "folder.fill"
            case .metrics: "waveform.path.ecg"
            case .portForwarding: "arrow.left.arrow.right"
            case .serialSession: "cable.connector"
            }
        }
    }

    private var accessibilityState: String {
        switch state {
        case .pending: String(localized: "not connected")
        case .active: String(localized: "connecting")
        case .complete: String(localized: "connected")
        case .failed: String(localized: "failed")
        }
    }
}

private struct JourneySegmentView: View {
    let state: JourneyVisualState
    let checkpoint: ConnectionJourney.CheckpointKind?
    let checkpointIsWaiting: Bool
    let reduceMotion: Bool

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Capsule().fill(Color.secondary.opacity(0.32)).frame(height: 4)
                switch state {
                case .complete, .failed:
                    Capsule().fill(state.color).frame(height: 4)
                case .active:
                    if checkpointIsWaiting {
                        HStack(spacing: 0) {
                            Rectangle().fill(Color.accentColor)
                                .frame(width: geometry.size.width / 2, height: 4)
                            Color.clear
                                .frame(width: geometry.size.width / 2, height: 4)
                        }
                    } else {
                        JourneyTravelingLine(reduceMotion: reduceMotion)
                    }
                case .pending:
                    EmptyView()
                }

                if let checkpoint {
                    ZStack {
                        if checkpointIsWaiting {
                            JourneyActivityRing(size: 42, reduceMotion: reduceMotion)
                        }
                        Circle().fill(Color.accentColor).frame(width: 28, height: 28)
                        Image(systemName: checkpoint == .authentication ? "key.fill" : "checkmark.shield.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Color.white)
                    }
                    .transition(.scale(scale: 0.65).combined(with: .opacity))
                    .accessibilityLabel(
                        checkpoint == .authentication
                            ? Text("Authentication required") : Text("Host key confirmation required"))
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .frame(height: 56)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.24), value: checkpoint)
    }
}

private struct JourneyTravelingLine: View {
    let reduceMotion: Bool

    var body: some View {
        if reduceMotion {
            HStack(spacing: 0) {
                Rectangle().fill(Color.accentColor).frame(width: 34, height: 4)
                Spacer(minLength: 0)
            }
        } else {
            TimelineView(.animation) { timeline in
                GeometryReader { proxy in
                    let time = timeline.date.timeIntervalSinceReferenceDate
                    let progress = 0.16 + 0.64 * ((sin(time * 2.4) + 1) / 2)
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.accentColor,
                                    Color.accentColor.opacity(0.55),
                                    .clear,
                                ],
                                startPoint: .leading, endPoint: .trailing
                            )
                        )
                        .frame(width: max(18, proxy.size.width * progress), height: 4)
                }
                .frame(height: 4)
            }
        }
    }
}

private struct JourneyActivityRing: View {
    let size: CGFloat
    let reduceMotion: Bool

    var body: some View {
        if reduceMotion {
            Circle().stroke(Color.accentColor.opacity(0.45), lineWidth: 4)
                .frame(width: size, height: size)
        } else {
            TimelineView(.animation) { timeline in
                let rotation =
                    timeline.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: 1.25) / 1.25 * 360
                Circle()
                    .trim(from: 0.06, to: 0.78)
                    .stroke(
                        AngularGradient(
                            colors: [
                                Color.accentColor.opacity(0.15),
                                Color.accentColor,
                                Color.accentColor.opacity(0.32),
                            ],
                            center: .center
                        ),
                        style: StrokeStyle(lineWidth: 4, lineCap: .round)
                    )
                    .rotationEffect(.degrees(rotation))
                    .frame(width: size, height: size)
            }
        }
    }
}
