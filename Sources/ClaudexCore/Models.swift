import Foundation

public enum ProviderKind: String, Sendable, Equatable, CaseIterable {
    case claude, codex

    public var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        }
    }
}

/// One rate-limit window (e.g. the 5-hour or weekly window).
public struct UsageWindow: Sendable, Equatable, Identifiable {
    public let id: String
    public let label: String
    /// Percent of the window already used, clamped to 0...100.
    public let usedPercent: Double
    public let resetsAt: Date?
    public let windowMinutes: Int?

    public init(id: String, label: String, usedPercent: Double, resetsAt: Date?, windowMinutes: Int?) {
        self.id = id
        self.label = label
        self.usedPercent = usedPercent.isFinite ? min(100, max(0, usedPercent)) : 0
        self.resetsAt = resetsAt
        self.windowMinutes = windowMinutes
    }

    public var leftPercent: Double { 100 - usedPercent }
}

public enum ProviderStatus: Sendable, Equatable {
    case loading
    case ok
    case stale(since: Date)
    case needsSignIn
    case unavailable(String)
}

public enum Mood: Sendable, Equatable {
    case happy, neutral, worried
}

/// What a provider's mascot is doing.
public enum Activity: Sendable, Equatable {
    /// A session log was written within the last two minutes.
    case working
    case idle
    /// Nothing written for more than ten minutes.
    case sleepy
}

public struct ProviderSnapshot: Sendable, Equatable {
    public var kind: ProviderKind
    public var windows: [UsageWindow]
    public var model: String?
    public var planType: String?
    public var isActive: Bool
    public var lastUpdated: Date?
    public var status: ProviderStatus
    /// Sessions writing right now, most recent first.
    public var live: [LiveSession]
    /// Last time any session log for this provider was written.
    public var lastActivity: Date?

    public init(
        kind: ProviderKind,
        windows: [UsageWindow] = [],
        model: String? = nil,
        planType: String? = nil,
        isActive: Bool = false,
        lastUpdated: Date? = nil,
        status: ProviderStatus = .loading,
        live: [LiveSession] = [],
        lastActivity: Date? = nil
    ) {
        self.kind = kind
        self.windows = windows
        self.model = model
        self.planType = planType
        self.isActive = isActive
        self.lastUpdated = lastUpdated
        self.status = status
        self.live = live
        self.lastActivity = lastActivity
    }

    public static let sleepyAfter: TimeInterval = 600

    public func activity(now: Date) -> Activity {
        if isActive || !live.isEmpty { return .working }
        guard let lastActivity, now.timeIntervalSince(lastActivity) <= Self.sleepyAfter else { return .sleepy }
        return .idle
    }

    /// The 5-hour window if present, otherwise the first window.
    public var primaryWindow: UsageWindow? {
        windows.first(where: { $0.windowMinutes == 300 }) ?? windows.first
    }

    /// False when signed out or no usage was ever observed: nothing to show or react to.
    public var hasUsage: Bool {
        switch status {
        case .needsSignIn, .unavailable: false
        case .loading, .ok, .stale: true
        }
    }

    /// Plan for the header badge; hidden while signed out.
    public var visiblePlan: String? { status == .needsSignIn ? nil : planType }

    public var isStale: Bool {
        if case .stale = status { return true }
        return false
    }

    /// % left for the collapsed ring; nil (an empty ring) when there is no usage to show.
    public var indicatorLeftPercent: Double? { hasUsage ? primaryWindow?.leftPercent : nil }

    /// Usage could not be observed this time. Windows seen before stay, marked stale since
    /// `lastObserved`; with no prior observation they and the plan are cleared.
    public mutating func markUsageMissing(lastObserved: Date?, message: String) {
        if let lastObserved, !windows.isEmpty {
            status = .stale(since: lastObserved)
        } else {
            windows = []
            planType = nil
            status = .unavailable(message)
        }
    }

    /// Neutral when there is no usage to judge, so mood never comes from cleared data.
    public var mood: Mood {
        guard hasUsage else { return .neutral }
        let maxUsed = windows.map(\.usedPercent).max() ?? 0
        if maxUsed > 80 { return .worried }
        if maxUsed > 50 { return .neutral }
        return .happy
    }
}
