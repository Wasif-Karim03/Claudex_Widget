import ClaudexCore
import SwiftUI

struct ProviderCard: View {
    let snapshot: ProviderSnapshot
    let now: Date
    /// True while the card is on screen; drives the bar fill-in and mascot life.
    let revealed: Bool

    static let maxLiveRows = 3

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var tint: Color { Theme.tint(snapshot.kind) }
    private var activity: Activity { snapshot.activity(now: now) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            usage
            liveSection
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.top, 11)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(panel)
    }

    /// A soft glass tile with a faint glow of the provider's colour from the top.
    private var panel: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color.white.opacity(0.035))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(RadialGradient(colors: [tint.opacity(activity == .working ? 0.20 : 0.11), .clear],
                                         center: .topLeading, startRadius: 0, endRadius: 170))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [Color.white.opacity(0.12), Color.white.opacity(0.03)],
                                                 startPoint: .top, endPoint: .bottom), lineWidth: 0.5)
            )
            .animation(Theme.motion(.easeInOut(duration: 0.6), reduceMotion: reduceMotion), value: activity)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 9) {
            PixelMascot(kind: snapshot.kind, pixel: snapshot.kind == .claude ? 2 : 1.5,
                        mood: snapshot.mood, activity: activity, animated: revealed)
                .frame(width: 40, height: 30)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(snapshot.kind.displayName)
                        .font(Theme.font(14, .bold))
                        .foregroundStyle(Theme.primaryText)
                    Spacer(minLength: 0)
                    if let plan = snapshot.visiblePlan {
                        PlanBadge(text: plan, kind: snapshot.kind)
                    }
                }
                HStack(spacing: 5) {
                    ActivityDot(active: activity == .working, animated: revealed)
                    Text(activityText)
                        .font(Theme.font(9.5, .semibold))
                        .foregroundStyle(activity == .working ? Theme.active.opacity(0.9) : Theme.tertiaryText)
                        .contentTransition(.opacity)
                    Spacer(minLength: 0)
                    ModelChip(text: ModelNameFormatter.pretty(snapshot.model), tint: tint, prominent: true)
                }
            }
        }
    }

    private var activityText: String {
        switch activity {
        case .working:
            let n = snapshot.live.count
            return n > 1 ? "\(n) working" : "working"
        case .idle:
            return snapshot.lastActivity.map { "idle · \(Self.ago($0, now: now))" } ?? "idle"
        case .sleepy:
            return "asleep"
        }
    }

    // MARK: Usage

    @ViewBuilder
    private var usage: some View {
        switch snapshot.status {
        case .loading:
            VStack(alignment: .leading, spacing: 10) {
                ShimmerRow()
                ShimmerRow()
            }
        case .needsSignIn:
            StatusMessage(symbol: "person.crop.circle.badge.exclamationmark", text: "Sign in to Claude Code")
        case let .unavailable(message):
            StatusMessage(symbol: snapshot.kind == .codex ? "moon.zzz" : "wifi.exclamationmark", text: message)
        case .ok, .stale:
            VStack(alignment: .leading, spacing: 10) {
                if snapshot.windows.isEmpty {
                    StatusMessage(symbol: "hourglass", text: "No limits reported yet")
                }
                ForEach(Array(snapshot.windows.prefix(2).enumerated()), id: \.element.id) { index, window in
                    WindowRow(kind: snapshot.kind, window: window, now: now, revealed: revealed,
                              delay: 0.12 + Double(index) * 0.07)
                }
                if case let .stale(since) = snapshot.status {
                    Text("stale · \(Self.ago(since, now: now))")
                        .font(Theme.font(9, .medium))
                        .foregroundStyle(Theme.tertiaryText)
                }
            }
        }
    }

    // MARK: Live now

    private var liveSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Text("LIVE NOW")
                    .font(Theme.font(8.5, .heavy))
                    .tracking(0.9)
                    .foregroundStyle(Theme.tertiaryText)
                if !snapshot.live.isEmpty {
                    Text("\(snapshot.live.count)")
                        .font(Theme.font(8.5, .heavy))
                        .monospacedDigit()
                        .foregroundStyle(tint)
                        .contentTransition(.numericText(value: Double(snapshot.live.count)))
                }
                Rectangle().fill(Theme.hairline).frame(height: 0.5)
            }
            if snapshot.live.isEmpty {
                Text(activity == .sleepy ? "Nothing running · all quiet" : "Nothing running right now")
                    .font(Theme.font(10, .medium))
                    .foregroundStyle(Theme.tertiaryText)
                    .padding(.vertical, 2)
            } else {
                ForEach(snapshot.live.prefix(Self.maxLiveRows)) { session in
                    LiveRow(session: session, tint: tint)
                        .transition(reduceMotion ? .opacity
                                    : .asymmetric(insertion: .move(edge: .top).combined(with: .opacity),
                                                  removal: .opacity))
                }
                if snapshot.live.count > Self.maxLiveRows {
                    Text("+\(snapshot.live.count - Self.maxLiveRows) more")
                        .font(Theme.font(9.5, .semibold))
                        .foregroundStyle(Theme.tertiaryText)
                        .padding(.leading, 2)
                }
            }
        }
        .animation(Theme.motion(.spring(response: 0.4, dampingFraction: 0.85), reduceMotion: reduceMotion),
                   value: snapshot.live.map(\.id))
    }

    static func ago(_ date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes)m" }
        if minutes < 1440 { return "\(minutes / 60)h" }
        return "\(minutes / 1440)d"
    }
}

struct LiveRow: View {
    let session: LiveSession
    let tint: Color

    var body: some View {
        HStack(spacing: 6) {
            ModelChip(text: ModelNameFormatter.pretty(session.model), tint: tint, prominent: false)
                .frame(minWidth: 54, alignment: .leading)
            Text(session.project)
                .font(Theme.font(10.5, .medium))
                .foregroundStyle(Theme.primaryText.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            if session.isSubagent {
                Text("subagent")
                    .font(Theme.font(8, .bold))
                    .foregroundStyle(Theme.secondaryText)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Capsule().strokeBorder(Theme.hairline, lineWidth: 0.75))
                    .fixedSize()
            }
        }
        .help("\(ModelNameFormatter.pretty(session.model)) · \(session.project)\(session.isSubagent ? " (subagent)" : "")")
    }
}

// MARK: - Pieces

struct WindowRow: View {
    let kind: ProviderKind
    let window: UsageWindow
    let now: Date
    let revealed: Bool
    let delay: Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(window.label)
                    .font(Theme.font(10, .bold))
                    .foregroundStyle(Theme.secondaryText)
                Text(CountdownFormatter.string(until: window.resetsAt, now: now))
                    .font(Theme.font(9.5, .medium))
                    .monospacedDigit()
                    .foregroundStyle(Theme.tertiaryText)
                    .contentTransition(.numericText())
                Spacer(minLength: 2)
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text("\(Int(window.leftPercent.rounded()))%")
                        .font(Theme.font(12, .bold))
                        .monospacedDigit()
                        .foregroundStyle(window.leftPercent < 20 ? Theme.worried : Theme.primaryText)
                        .contentTransition(.numericText(value: window.leftPercent))
                    Text("left")
                        .font(Theme.font(9, .medium))
                        .foregroundStyle(Theme.tertiaryText)
                }
            }
            .animation(Theme.motion(.snappy, reduceMotion: reduceMotion), value: window.leftPercent)
            CapsuleBar(kind: kind, fraction: window.leftPercent / 100, revealed: revealed, delay: delay)
                .frame(height: 6)
        }
        .help(CountdownFormatter.verbose(until: window.resetsAt, now: now))
    }
}

struct CapsuleBar: View {
    let kind: ProviderKind
    let fraction: Double
    let revealed: Bool
    var delay: Double = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var clamped: Double { max(0, min(1, fraction)) }
    private var low: Bool { clamped < 0.2 }

    var body: some View {
        GeometryReader { geo in
            let shown = revealed ? clamped : 0
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                Capsule()
                    .fill(low
                          ? LinearGradient(colors: [Theme.worried, Theme.claudeStart], startPoint: .leading, endPoint: .trailing)
                          : Theme.gradient(kind))
                    .frame(width: shown > 0 ? max(geo.size.height, geo.size.width * shown) : 0)
                    .shadow(color: (low ? Theme.worried : Theme.tint(kind)).opacity(0.55), radius: 4)
            }
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.15)
                   : (revealed ? .spring(response: 0.7, dampingFraction: 0.82).delay(delay) : .easeOut(duration: 0.1)),
                   value: revealed)
        .animation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.6, dampingFraction: 0.85),
                   value: clamped)
    }
}

struct ActivityDot: View {
    let active: Bool
    var animated = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathe = false

    var body: some View {
        ZStack {
            if active {
                Circle()
                    .fill(Theme.active.opacity(0.45))
                    .scaleEffect(breathe ? 2.2 : 1)
                    .opacity(breathe ? 0 : 0.9)
            }
            Circle().fill(active ? Theme.active : Theme.idle)
        }
        .frame(width: 6, height: 6)
        .onChange(of: active && animated && !reduceMotion, initial: true) { _, live in
            if live {
                withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) { breathe = true }
            } else {
                var t = Transaction(animation: nil)
                t.disablesAnimations = true
                withTransaction(t) { breathe = false }
            }
        }
        .help(active ? "Active in the last 2 minutes" : "Idle")
        .accessibilityLabel(active ? "Active" : "Idle")
    }
}

struct PlanBadge: View {
    let text: String
    let kind: ProviderKind

    var body: some View {
        Text(text.uppercased())
            .font(Theme.font(8, .heavy))
            .tracking(0.6)
            .foregroundStyle(Theme.tint(kind))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Capsule().fill(Theme.tint(kind).opacity(0.16)))
            .overlay(Capsule().strokeBorder(Theme.tint(kind).opacity(0.28), lineWidth: 0.5))
            .lineLimit(1)
            .fixedSize()
    }
}

struct ModelChip: View {
    let text: String
    var tint: Color = .white
    /// The headline chip is tinted; list chips are quieter.
    var prominent = false

    var body: some View {
        Text(text)
            .font(Theme.font(prominent ? 10 : 9.5, .semibold))
            .foregroundStyle(prominent ? tint : Theme.secondaryText)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(prominent ? tint.opacity(0.15) : Color.white.opacity(0.07)))
            .overlay(Capsule().strokeBorder(prominent ? tint.opacity(0.25) : .clear, lineWidth: 0.5))
            .fixedSize()
            .contentTransition(.opacity)
            .animation(.easeInOut(duration: 0.25), value: text)
    }
}

struct StatusMessage: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.tertiaryText)
            Text(text)
                .font(Theme.font(11, .medium))
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 4)
    }
}

/// Loading placeholder: a label stub and a bar with a soft light sweeping across.
struct ShimmerRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = -1

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Capsule().frame(width: 34, height: 7)
                Spacer()
                Capsule().frame(width: 40, height: 9)
            }
            Capsule().frame(height: 5)
        }
        .foregroundStyle(Theme.track)
        .overlay {
            GeometryReader { geo in
                LinearGradient(colors: [.clear, .white.opacity(0.14), .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: geo.size.width * 0.5)
                    .offset(x: phase * geo.size.width)
            }
            .mask {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Capsule().frame(width: 34, height: 7)
                        Spacer()
                        Capsule().frame(width: 40, height: 9)
                    }
                    Capsule().frame(height: 5)
                }
            }
        }
        // Follows live changes of the preference: stops the sweep when Reduce Motion is
        // switched on and restarts it when switched off.
        .onChange(of: reduceMotion, initial: true) { _, reduce in
            if reduce {
                var t = Transaction(animation: nil)
                t.disablesAnimations = true
                withTransaction(t) { phase = -1 }
            } else {
                phase = -1
                withAnimation(.linear(duration: 1.3).repeatForever(autoreverses: false)) { phase = 1.2 }
            }
        }
    }
}
