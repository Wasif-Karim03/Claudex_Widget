import Foundation
import Testing
@testable import ClaudexCore

/// What earlier parses observed survives a tail that no longer shows it.
@Suite struct RetentionTests {
    static func filler(_ n: Int) -> [String] {
        (0..<n).map { _ in
            #"{"type":"event_msg","payload":{"type":"agent_message","message":"\#(String(repeating: "x", count: 100))"}}"#
        }
    }

    /// A token_count line reporting `used`% at `at`.
    static func limitsLine(used: Double, at: Date) -> String {
        CodexParsingTests.tokenCountLine(primary: used)
            .replacingOccurrences(of: "2026-10-16T02:23:40Z", with: at.formatted(Date.ISO8601FormatStyle()))
    }

    static func append(_ lines: [String], to file: URL, modified: Date) throws {
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((lines.joined(separator: "\n") + "\n").utf8))
        try handle.close()
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)
    }

    // MARK: Codex rate limits (R1)

    @Test func olderRolloutNeverReplacesNewerRetainedLimits() throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let now = Date()
        let a = try dir.write("2026/10/16/rollout-a.jsonl", Self.limitsLine(used: 90, at: now.addingTimeInterval(-20)) + "\n",
                              modified: now.addingTimeInterval(-20))
        try dir.write("2026/10/15/rollout-b.jsonl", Self.limitsLine(used: 10, at: now.addingTimeInterval(-100)) + "\n",
                      modified: now.addingTimeInterval(-100))
        let reader = CodexSessionReader(sessionsDir: dir.url)
        var cache = ParseCache<CodexParsed>()
        #expect(reader.scan(now: now, cache: &cache, maxBytes: 1024).limits?.windows.first?.usedPercent == 90)

        // Filler pushes A's limits out of its tail; A stays the newest rollout.
        try Self.append(Self.filler(20), to: a, modified: now.addingTimeInterval(-5))
        #expect(!CodexSessionReader.parse(lines: JSONLTail.lines(of: a, maxBytes: 1024)).hasRateLimits)

        let limits = try #require(reader.scan(now: now, cache: &cache, maxBytes: 1024).limits)
        #expect(limits.windows.first?.usedPercent == 90)
        #expect(limits.limitsRetained)
        #expect(limits.usageStatus(now: now) == .ok)
    }

    @Test func olderRolloutReportedLaterReplacesRetainedLimits() throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let now = Date()
        let a = try dir.write("2026/10/16/rollout-a.jsonl", Self.limitsLine(used: 90, at: now.addingTimeInterval(-60)) + "\n",
                              modified: now.addingTimeInterval(-60))
        let b = try dir.write("2026/10/15/rollout-b.jsonl", Self.limitsLine(used: 10, at: now.addingTimeInterval(-100)) + "\n",
                              modified: now.addingTimeInterval(-100))
        let reader = CodexSessionReader(sessionsDir: dir.url)
        var cache = ParseCache<CodexParsed>()
        #expect(reader.scan(now: now, cache: &cache, maxBytes: 1024).limits?.windows.first?.usedPercent == 90)

        try Self.append(Self.filler(20), to: a, modified: now.addingTimeInterval(-5))
        // B reports after A's retained limits were reported, but is still older by mtime.
        try Self.append([Self.limitsLine(used: 40, at: now.addingTimeInterval(-30))], to: b,
                        modified: now.addingTimeInterval(-10))

        let limits = try #require(reader.scan(now: now, cache: &cache, maxBytes: 1024).limits)
        #expect(limits.windows.first?.usedPercent == 40)
        #expect(!limits.limitsRetained)
    }

    @Test func retainedLimitsGoStaleWhenNotRecentlyObserved() {
        let now = Date()
        let seen = now.addingTimeInterval(-(CodexParsed.retainedFreshFor + 1))
        var parsed = CodexParsed(hasRateLimits: true)
        parsed.limitsObservedAt = seen
        // Limits read from the tail are current however old their report.
        #expect(parsed.usageStatus(now: now) == .ok)
        parsed.limitsRetained = true
        #expect(parsed.usageStatus(now: now) == .stale(since: seen))
        parsed.limitsObservedAt = now.addingTimeInterval(-60)
        #expect(parsed.usageStatus(now: now) == .ok)
    }

    // MARK: Claude model and cwd (R2)

    static func claudeLine(model: String, cwd: String) -> String {
        #"{"type":"assistant","cwd":"\#(cwd)","message":{"model":"\#(model)"}}"#
    }

    static func userFiller(_ n: Int) -> [String] {
        (0..<n).map { _ in #"{"type":"user","message":{"content":"\#(String(repeating: "y", count: 100))"}}"# }
    }

    @Test func claudeKeepsObservedModelAndCwdWhenTailHasNone() throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let now = Date()
        let file = try dir.write("-p-Alpha/s.jsonl", Self.claudeLine(model: "claude-opus-5-5", cwd: "/p/Real Alpha") + "\n",
                                 modified: now.addingTimeInterval(-20))
        let reader = ClaudeSessionReader(projectsDir: dir.url)
        var cache = ParseCache<ClaudeSessionReader.Parsed>()
        let first = reader.scan(now: now, cache: &cache, projectName: { _ in "decoded" }, maxBytes: 1024)
        #expect(first.headlineModel == "claude-opus-5-5")
        #expect(first.live.first?.project == "Real Alpha")

        try Self.append(Self.userFiller(20), to: file, modified: now.addingTimeInterval(-5))
        #expect(ClaudeSessionReader.parse(lines: JSONLTail.lines(of: file, maxBytes: 1024)).model == nil)

        let second = reader.scan(now: now, cache: &cache, projectName: { _ in "decoded" }, maxBytes: 1024)
        #expect(second.headlineModel == "claude-opus-5-5")
        #expect(second.live.first?.model == "claude-opus-5-5")
        #expect(second.live.first?.project == "Real Alpha")
    }

    @Test func claudeHeadlineIsNeverAnotherSessionsModel() throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let now = Date()
        // The newest session has not recorded a model yet; an older live one has.
        try dir.write("-p-A/new.jsonl", Self.userFiller(1)[0] + "\n", modified: now.addingTimeInterval(-5))
        try dir.write("-p-B/old.jsonl", Self.claudeLine(model: "claude-sonnet-5-5", cwd: "/p/B") + "\n",
                      modified: now.addingTimeInterval(-30))
        var cache = ParseCache<ClaudeSessionReader.Parsed>()
        let scan = ClaudeSessionReader(projectsDir: dir.url).scan(now: now, cache: &cache, projectName: { $0 })
        #expect(scan.live.map(\.model) == [nil, "claude-sonnet-5-5"])
        #expect(scan.headlineModel == nil)
    }

    @Test func claudeShrunkFileDropsPreservedValues() throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let now = Date()
        let body = ([Self.claudeLine(model: "claude-opus-5-5", cwd: "/p/Alpha")] + Self.userFiller(5))
            .joined(separator: "\n") + "\n"
        let file = try dir.write("-p-Alpha/s.jsonl", body, modified: now.addingTimeInterval(-20))
        let reader = ClaudeSessionReader(projectsDir: dir.url)
        var cache = ParseCache<ClaudeSessionReader.Parsed>()
        #expect(reader.scan(now: now, cache: &cache, projectName: { _ in "decoded" }).headlineModel == "claude-opus-5-5")

        // Replaced by a shorter file with no model or cwd of its own.
        try dir.write("-p-Alpha/s.jsonl", Self.userFiller(1)[0] + "\n", modified: now.addingTimeInterval(-5))
        #expect(try #require(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize) < body.utf8.count)
        let scan = reader.scan(now: now, cache: &cache, projectName: { _ in "decoded" })
        #expect(scan.headlineModel == nil)
        #expect(scan.live.first?.model == nil)
        #expect(scan.live.first?.project == "decoded")
    }

    // MARK: Plan badge (R4)

    @Test func planBadgeHiddenWhenSignedOut() {
        #expect(ProviderSnapshot(kind: .claude, planType: "max", status: .ok).visiblePlan == "max")
        #expect(ProviderSnapshot(kind: .claude, planType: "max", status: .stale(since: Date())).visiblePlan == "max")
        #expect(ProviderSnapshot(kind: .claude, planType: "max", status: .needsSignIn).visiblePlan == nil)
    }
}
