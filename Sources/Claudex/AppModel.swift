import ClaudexCore
import Foundation
import Observation

@MainActor @Observable
final class AppModel {
    var claude = ProviderSnapshot(kind: .claude)
    var codex = ProviderSnapshot(kind: .codex)
    /// Clock used by countdowns. Ticks every second while expanded, every 30s collapsed.
    var now = Date()
    var isExpanded = false {
        didSet {
            guard isExpanded != oldValue else { return }
            if isExpanded { now = Date() }
        }
    }
    var layout = NotchLayout.fallback

    /// Lines needed by the taller "Live now" list; sizes the expanded card.
    var liveLines: Int { NotchLayout.liveLines(for: [claude.live.count, codex.live.count]) }

    @ObservationIgnored private let client = ClaudeUsageClient()
    @ObservationIgnored private let scanner = LocalScanner()
    @ObservationIgnored private var cache = LocalCache()
    @ObservationIgnored private var claudeTask: Task<Void, Never>?
    /// The Claude loop's current wait; cancelling it wakes the loop early.
    @ObservationIgnored private var claudeWait: Task<Void, Never>?
    @ObservationIgnored private var localTask: Task<Void, Never>?
    @ObservationIgnored private var clockTask: Task<Void, Never>?
    @ObservationIgnored private var claudeFetchedOnce = false
    /// When a local scan last found Codex `rate_limits`; nil until the first one does.
    @ObservationIgnored private var codexObservedAt: Date?

    static let localInterval: Duration = .seconds(3)

    func start() {
        startClaudeLoop()
        startLocalLoop()
        clockTask = Task { [weak self] in
            var lastTick = Date()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                let current = Date()
                if self.isExpanded || current.timeIntervalSince(lastTick) >= 30 {
                    self.now = current
                    lastTick = current
                }
            }
        }
    }

    /// Re-polls both sources now. The Claude loop is woken rather than restarted; the
    /// client itself still enforces the 60s minimum spacing between requests.
    func refresh() {
        claudeWait?.cancel()
        startLocalLoop()
    }

    // MARK: - Claude network loop

    private func startClaudeLoop() {
        claudeTask?.cancel()
        claudeTask = Task { [weak self, client] in
            while !Task.isCancelled {
                let result = await client.poll()
                if Task.isCancelled { return }
                self?.apply(result)
                let delay: TimeInterval
                if case let .throttled(retryIn) = result {
                    delay = max(1, retryIn)
                } else {
                    delay = await client.nextDelay
                }
                await self?.wait(seconds: delay)
            }
        }
    }

    /// Sleeps for `seconds` unless `refresh()` wakes the loop or the loop is cancelled.
    private func wait(seconds: TimeInterval) async {
        let sleeper = Task<Void, Never> { try? await Task.sleep(for: .seconds(seconds)) }
        claudeWait = sleeper
        await withTaskCancellationHandler { await sleeper.value } onCancel: { sleeper.cancel() }
    }

    private func apply(_ result: ClaudeUsageResult) {
        let current = Date()
        switch result {
        case let .ok(windows, plan):
            claude.windows = windows
            claude.planType = plan ?? claude.planType
            claude.lastUpdated = current
            claude.status = .ok
            claudeFetchedOnce = true
        case .needsSignIn:
            claude.windows = []
            claude.status = .needsSignIn
        case .throttled:
            break
        case .rateLimited, .failed:
            claude.markUsageMissing(lastObserved: claudeFetchedOnce ? claude.lastUpdated : nil,
                                    message: "Couldn't reach Claude")
        }
    }

    // MARK: - Local file loop

    private func startLocalLoop() {
        localTask?.cancel()
        localTask = Task { [weak self, scanner] in
            while !Task.isCancelled {
                guard let previous = self?.cache else { return }
                let current = Date()
                let result = await Task.detached(priority: .utility) {
                    scanner.scan(previous: previous, now: current)
                }.value
                if Task.isCancelled { return }
                self?.applyLocal(result, now: current)
                try? await Task.sleep(for: Self.localInterval)
            }
        }
    }

    private func applyLocal(_ result: LocalScanResult, now current: Date) {
        cache = result.cache

        let claudeScan = result.claude
        claude.live = claudeScan.live
        claude.model = claudeScan.headlineModel ?? claude.model
        claude.lastActivity = claudeScan.lastActivity
        claude.isActive = ClaudeSessionReader.isActive(mtime: claudeScan.lastActivity, now: current)

        let codexScan = result.codex
        guard codexScan.hasSessions, let limits = codexScan.limits else {
            guard let observed = codexObservedAt else {
                codex = ProviderSnapshot(kind: .codex, status: .unavailable("No Codex sessions yet"))
                return
            }
            // Usage was seen before: keep it, marked stale, rather than clearing it.
            codex.live = []
            codex.lastActivity = nil
            codex.isActive = false
            codex.markUsageMissing(lastObserved: observed, message: "No Codex sessions yet")
            return
        }
        codex.live = codexScan.live
        codex.model = codexScan.headlineModel ?? codex.model
        codex.lastActivity = codexScan.lastActivity
        codex.isActive = CodexSessionReader.isActive(mtime: codexScan.lastActivity, now: current)
        if limits.hasRateLimits {
            codex.windows = limits.windows
            codex.planType = limits.planType
            codex.lastUpdated = codexScan.lastActivity
            codex.status = .ok
            codexObservedAt = current
        } else {
            codex.markUsageMissing(lastObserved: codexObservedAt, message: "No usage reported yet")
        }
    }
}
