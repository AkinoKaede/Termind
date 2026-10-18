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
                    .onChange(of: ConnectionJourneyRouteStyle(journey: journey).scrollTarget, initial: true) { _, _ in
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
        let style = ConnectionJourneyRouteStyle(journey: journey)
        let endpointIndices = style.endpointIndices
        let activityEndpointIndex = style.activityEndpointIndex
        let routeWidth = labelWidth + CGFloat(max(0, endpointIndices.count - 1)) * endpointSpacing
        let canvasWidth = max(viewportWidth, routeWidth + 58)

        return ZStack(alignment: .topLeading) {
            HStack(spacing: 0) {
                ForEach(endpointIndices.dropFirst(), id: \.self) { index in
                    JourneySegmentView(
                        state: style.state(for: .segment, at: index),
                        checkpoint: journey.checkpoint?.endpointIndex == index
                            ? journey.checkpoint?.kind : journey.completedCheckpoints[index],
                        checkpointIsWaiting: journey.checkpoint?.endpointIndex == index,
                        reduceMotion: reduceMotion || journey.transportRecovery == .suspended
                    )
                    .frame(width: endpointSpacing, height: nodeLaneHeight)
                    .id("segment-\(index)")
                }
            }
            .padding(.leading, labelWidth / 2)

            HStack(alignment: .top, spacing: gapBetweenEndpointFrames) {
                ForEach(endpointIndices.map { (index: $0, endpoint: journey.endpoints[$0]) }, id: \.endpoint.id) {
                    index, endpoint in
                    JourneyEndpointView(
                        endpoint: endpoint,
                        purpose: journey.purpose,
                        state: style.state(for: .endpoint, at: index),
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

    private func scrollToActivity(_ proxy: ScrollViewProxy) {
        guard let target = ConnectionJourneyRouteStyle(journey: journey).scrollTarget else { return }
        if reduceMotion {
            proxy.scrollTo(target, anchor: .center)
        } else {
            withAnimation(.easeInOut(duration: 0.24)) {
                proxy.scrollTo(target, anchor: .center)
            }
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

private struct JourneyEndpointView: View {
    let endpoint: ConnectionEndpoint
    let purpose: ConnectionPurpose
    let state: ConnectionJourneyRouteStyle.State
    let showsActivity: Bool
    let localRequirement: ConnectionJourney.LocalRequirement?
    let reduceMotion: Bool

    var body: some View {
        ZStack(alignment: .top) {
            ZStack {
                if showsActivity {
                    JourneyActivityRing(size: 52, color: state.color, reduceMotion: reduceMotion)
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
            case .identity, .tailscaleUsername: return "person.fill"
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
            return purpose.symbol(for: .routeDestination)
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
    let state: ConnectionJourneyRouteStyle.State
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
                            Rectangle().fill(state.color)
                                .frame(width: geometry.size.width / 2, height: 4)
                            Color.clear
                                .frame(width: geometry.size.width / 2, height: 4)
                        }
                    } else {
                        JourneyTravelingLine(color: state.color, reduceMotion: reduceMotion)
                    }
                case .pending:
                    EmptyView()
                }

                if let checkpoint {
                    ZStack {
                        if checkpointIsWaiting {
                            JourneyActivityRing(size: 42, color: state.color, reduceMotion: reduceMotion)
                        }
                        Circle().fill(state.color).frame(width: 28, height: 28)
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
    let color: Color
    let reduceMotion: Bool

    var body: some View {
        if reduceMotion {
            HStack(spacing: 0) {
                Rectangle().fill(color).frame(width: 34, height: 4)
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
                                    color,
                                    color.opacity(0.55),
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
    let color: Color
    let reduceMotion: Bool

    var body: some View {
        if reduceMotion {
            Circle().stroke(color.opacity(0.45), lineWidth: 4)
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
                                color.opacity(0.15),
                                color,
                                color.opacity(0.32),
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
