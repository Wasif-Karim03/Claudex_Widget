import ClaudexCore
import SwiftUI

/// One provider's column in the expanded card: who it is, how much is left, what runs.
/// Deliberately plain: type and numbers carry it; colour is reserved for the provider's
/// identity and for warnings.
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
        VStack(alignment: .leading, spacing: 14) {
            header
            usage
            liveSection
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            PixelMascot(kind: snapshot.kind, pixel: snapshot.kind == .claude ? 2 : 1.5,
                        mood: snapshot.mood, activity: activity, animated: revealed)
                .frame(width: 38, height: 30)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(snapshot.kind.displayName)
                        .font(Theme.font(14, .semibold))
                        .foregroundStyle(Theme.primaryText)
                    if let plan = snapshot.visiblePlan {
                        Text(plan.uppercased())
                            .font(Theme.mono(9, .medium))
                            .foregroundStyle(Theme.tertiaryText)
                            .fixedSize()
                    }
                    Spacer(minLength: 4)
                    Text(ModelNameFormatter.pretty(snapshot.model))
                        .font(Theme.mono(10.5, .medium))
                        .foregroundStyle(snapshot.model == nil ? Theme.tertiaryText : tint)
                        .lineLimit(1)
                        .fixedSize()
                        .contentTransition(.opacity)
                        .animation(.easeInOut(duration: 0.25), value: snapshot.model)
                }
                HStack(spacing: 5) {
                    ActivityDot(active: activity == .working, animated: revealed)
                    Text(activityText)
                        .font(Theme.font(11))
                        .foregroundStyle(activity == .working ? Theme.active : Theme.secondaryText)
                        .contentTransition(.opacity)
                    Spacer(minLength: 0)
                    if case let .stale(since) = snapshot.status {
                        Text("as of \(Self.ago(since, now: now))")
                            .font(Theme.mono(9.5))
                            .foregroundStyle(Theme.tertiaryText)
                            .help("Usage not refreshed since then")
                    }
                }
            }
        }
    }

    private var activityText: String {
        switch activity {
        case .working:
            let n = snapshot.live.count
            return n > 1 ? "\(n) sessions working" : "Working"
        case .idle:
            return snapshot.lastActivity.map { "Idle for \(Self.ago($0, now: now, short: false))" } ?? "Idle"
        case .sleepy:
            return "Asleep"
        }
    }

    // MARK: Usage

    @ViewBuilder
    private var usage: some View {
        switch snapshot.status {
        case .loading:
            HStack(spacing: 18) {
                ShimmerRow()
                ShimmerRow()
            }
        case .needsSignIn:
            StatusMessage(symbol: "person.crop.circle.badge.exclamationmark", text: "Sign in to Claude Code")
        case let .unavailable(message):
            StatusMessage(symbol: snapshot.kind == .codex ? "moon.zzz" : "wifi.exclamationmark", text: message)
        case .ok, .stale:
            if snapshot.windows.isEmpty {
                StatusMessage(symbol: "hourglass", text: "No limits reported yet")
            } else {
                let windows = Array(snapshot.windows.prefix(RingDial.maxRings))
                HStack(alignment: .center, spacing: 12) {
                    RingDial(kind: snapshot.kind, used: windows.map { $0.usedPercent / 100 }, revealed: revealed)
                        .frame(width: 80, height: 80)
                    VStack(alignment: .leading, spacing: windows.count > 2 ? 5 : 9) {
                        ForEach(Array(windows.enumerated()), id: \.element.id) { index, window in
                            RingLegendRow(window: window, color: RingDial.color(kind: snapshot.kind, ring: index,
                                                                                 used: window.usedPercent / 100),
                                          now: now,
                                          showsReset: index == 0 || !Self.sameReset(window, windows[index - 1]))
                        }
                    }
                    Spacer(minLength: 0)
                }
                .opacity(snapshot.isStale ? 0.55 : 1)
            }
        }
    }

    // MARK: Live sessions

    private var liveSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Rectangle().fill(Theme.hairline).frame(height: 0.5)
                .padding(.bottom, 4)
            if snapshot.live.isEmpty {
                Text("No live sessions")
                    .font(Theme.font(11))
                    .foregroundStyle(Theme.tertiaryText)
                    .frame(height: 17, alignment: .leading)
            } else {
                ForEach(snapshot.live.prefix(Self.maxLiveRows)) { session in
                    LiveRow(session: session, tint: tint)
                        .transition(reduceMotion ? .opacity
                                    : .asymmetric(insertion: .move(edge: .top).combined(with: .opacity),
                                                  removal: .opacity))
                }
                if snapshot.live.count > Self.maxLiveRows {
                    Text("and \(snapshot.live.count - Self.maxLiveRows) more")
                        .font(Theme.font(10.5))
                        .foregroundStyle(Theme.tertiaryText)
                        .padding(.leading, 11)
                }
            }
        }
        .animation(Theme.motion(.spring(response: 0.4, dampingFraction: 0.85), reduceMotion: reduceMotion),
                   value: snapshot.live.map(\.id))
    }

    /// Resets within a minute of each other read as the same reset.
    static func sameReset(_ a: UsageWindow, _ b: UsageWindow) -> Bool {
        guard let x = a.resetsAt, let y = b.resetsAt else { return false }
        return abs(x.timeIntervalSince(y)) < 60
    }

    static func ago(_ date: Date, now: Date, short: Bool = true) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return short ? "now" : "a moment" }
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
            // Subagents hang off their parent session rather than getting a dot of their own.
            Group {
                if session.isSubagent {
                    Text("↳").font(Theme.font(10)).foregroundStyle(Theme.tertiaryText)
                } else {
                    Circle().fill(tint).frame(width: 5, height: 5)
                }
            }
            .frame(width: 5)
            Text(session.project)
                .font(Theme.font(11.5, session.isSubagent ? .regular : .medium))
                .foregroundStyle(session.isSubagent ? Theme.secondaryText : Theme.primaryText)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 6)
            Text(ModelNameFormatter.pretty(session.model))
                .font(Theme.mono(10))
                .foregroundStyle(Theme.tertiaryText)
                .lineLimit(1)
                .fixedSize()
        }
        .frame(height: 17)
        .help("\(ModelNameFormatter.pretty(session.model)) · \(session.project)\(session.isSubagent ? " (subagent)" : "")")
    }
}

// MARK: - Pieces

/// Concentric rings, one per window, filled by how much is used (as Claude's `/usage`
/// reports it): the outer ring is the first (shortest) window, inner ones the longer or
/// model-specific ones. The centre shows the most-used window.
struct RingDial: View {
    let kind: ProviderKind
    /// Fraction used per window, outermost first.
    let used: [Double]
    let revealed: Bool

    static let maxRings = 3
    /// Used above this is a warning.
    static let warnAbove = 0.8

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var lineWidth: CGFloat { used.count > 2 ? 6 : 8 }
    private var gap: CGFloat { used.count > 2 ? 2 : 3 }

    /// The provider's colour outside, lighter tints inside; warning red when nearly spent.
    static func color(kind: ProviderKind, ring: Int, used: Double) -> Color {
        if used > warnAbove { return Theme.worried }
        switch ring {
        case 0: return Theme.tint(kind)
        case 1: return Theme.innerTint(kind)
        default: return Theme.innerTint(kind).opacity(0.6)
        }
    }

    var body: some View {
        ZStack {
            ForEach(Array(used.enumerated()), id: \.offset) { index, fraction in
                let inset = CGFloat(index) * (lineWidth + gap) + lineWidth / 2
                let clamped = max(0, min(1, fraction))
                Circle()
                    .stroke(Theme.track, lineWidth: lineWidth)
                    .padding(inset)
                Circle()
                    .trim(from: 0, to: revealed && clamped > 0 ? max(0.01, clamped) : 0)
                    .stroke(Self.color(kind: kind, ring: index, used: clamped),
                            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .padding(inset)
                    .animation(reduceMotion ? .easeInOut(duration: 0.15)
                               : (revealed ? .spring(response: 0.8, dampingFraction: 0.88).delay(0.12 + Double(index) * 0.08)
                                  : .easeOut(duration: 0.1)),
                               value: revealed)
                    .animation(Theme.motion(.spring(response: 0.6, dampingFraction: 0.9), reduceMotion: reduceMotion),
                               value: clamped)
            }
            if let most = used.max() {
                VStack(spacing: -1) {
                    Text("\(Int((most * 100).rounded()))%")
                        .font(Theme.font(used.count > 2 ? 13 : 15, .semibold))
                        .monospacedDigit()
                        .foregroundStyle(most > Self.warnAbove ? Theme.worried : Theme.primaryText)
                        .contentTransition(.numericText(value: most))
                    Text("used")
                        .font(Theme.font(8.5))
                        .foregroundStyle(Theme.tertiaryText)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(kind.displayName) \(Int(((used.max() ?? 0) * 100).rounded())) percent used")
    }
}

/// Legend line for one ring: swatch, window, % left, and its reset underneath.
struct RingLegendRow: View {
    let window: UsageWindow
    let color: Color
    let now: Date
    /// False when the window above resets at the same moment; the line would repeat it.
    var showsReset = true

    private var resetText: String {
        let core = CountdownFormatter.string(until: window.resetsAt, now: now)
        return core == "—" || core == "resetting…" ? core : "resets \(core)"
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Circle().fill(color).frame(width: 7, height: 7)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 0.5 }
                Text(window.label)
                    .font(Theme.font(11))
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize()
                Text("\(Int(window.usedPercent.rounded()))%")
                    .font(Theme.font(15, .semibold))
                    .monospacedDigit()
                    .fixedSize()
                    .foregroundStyle(window.usedPercent > RingDial.warnAbove * 100 ? Theme.worried : Theme.primaryText)
                    .contentTransition(.numericText(value: window.usedPercent))
                    .animation(Theme.motion(.snappy, reduceMotion: reduceMotion), value: window.usedPercent)
            }
            if showsReset {
                Text(resetText)
                .font(Theme.mono(10))
                .lineLimit(1)
                .fixedSize()
                .monospacedDigit()
                .foregroundStyle(Theme.tertiaryText)
                .contentTransition(.numericText())
                .padding(.leading, 13)
            }
        }
        .help(CountdownFormatter.verbose(until: window.resetsAt, now: now))
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

struct StatusMessage: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.tertiaryText)
            Text(text)
                .font(Theme.font(11.5))
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 4)
    }
}

/// Loading placeholder shaped like a `WindowMetric`, with a soft light sweeping across.
struct ShimmerRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = -1

    private var placeholder: some View {
        VStack(alignment: .leading, spacing: 8) {
            Capsule().frame(width: 46, height: 20)
            Capsule().frame(height: 3)
            Capsule().frame(width: 60, height: 7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var body: some View {
        placeholder
        .foregroundStyle(Theme.track)
        .overlay {
            GeometryReader { geo in
                LinearGradient(colors: [.clear, .white.opacity(0.14), .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: geo.size.width * 0.5)
                    .offset(x: phase * geo.size.width)
            }
            .mask { placeholder }
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
