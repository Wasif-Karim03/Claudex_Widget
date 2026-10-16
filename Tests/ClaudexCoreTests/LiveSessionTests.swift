import Foundation
import Testing
@testable import ClaudexCore

@Suite struct ProjectNameTests {
    static let tree: [String: [String]] = [
        "/": ["Users", "private"],
        "/Users": ["wasifkarim"],
        "/Users/wasifkarim": ["Claude", ".claude", "Desktop"],
        "/Users/wasifkarim/Claude": ["Projects", "Stock"],
        "/Users/wasifkarim/Claude/Projects": ["CLAUDEX WIDGET", "CLAUDEX", "Job_Searching.Website"],
    ]
    static let lister: ProjectName.DirectoryLister = { tree[$0] }

    @Test func encodesNonAlphanumericsAsDashes() {
        #expect(ProjectName.encode("CLAUDEX WIDGET") == "CLAUDEX-WIDGET")
        #expect(ProjectName.encode(".claude") == "-claude")
        #expect(ProjectName.encode("Job_Searching.Website") == "Job-Searching-Website")
    }

    @Test func decodesProjectWithSpaceUsingFileSystem() {
        #expect(ProjectName.decodeClaudeProjectDir("-Users-wasifkarim-Claude-Projects-CLAUDEX-WIDGET", list: Self.lister) == "CLAUDEX WIDGET")
        #expect(ProjectName.decodeClaudeProjectDir("-Users-wasifkarim-Claude-Projects-CLAUDEX", list: Self.lister) == "CLAUDEX")
        #expect(ProjectName.decodeClaudeProjectDir("-Users-wasifkarim-Claude-Projects-Job-Searching-Website", list: Self.lister) == "Job_Searching.Website")
    }

    @Test func decodesHomeAndHiddenDirectories() {
        #expect(ProjectName.decodeClaudeProjectDir("-Users-wasifkarim", list: Self.lister) == "wasifkarim")
        #expect(ProjectName.decodeClaudeProjectDir("-Users-wasifkarim--claude", list: Self.lister) == ".claude")
    }

    @Test func unresolvedRemainderFallsBackToSpaces() {
        // The project folder was deleted: the unresolved tail is shown with spaces.
        #expect(ProjectName.decodeClaudeProjectDir("-Users-wasifkarim-Claude-Projects-Old-Thing", list: Self.lister) == "Old Thing")
        // Nothing on disk at all.
        #expect(ProjectName.decodeClaudeProjectDir("-Users-someone-Code-app", list: { _ in nil }) == "Users someone Code app")
    }

    @Test func neverListsPrivacyProtectedFolders() {
        #expect(ProjectName.isPrivacyProtected("/Users/me/Desktop", home: "/Users/me"))
        #expect(ProjectName.isPrivacyProtected("/Users/me/Documents/app", home: "/Users/me"))
        #expect(ProjectName.isPrivacyProtected("/Volumes/USB", home: "/Users/me"))
        #expect(!ProjectName.isPrivacyProtected("/Users/me/Claude/Projects", home: "/Users/me"))
        #expect(!ProjectName.isPrivacyProtected("/Users/me/DesktopApps", home: "/Users/me"))
    }

    @Test func lastComponentOfCwd() {
        #expect(ProjectName.lastComponent(ofPath: "/Users/me/Claude/Projects/CLAUDEX WIDGET") == "CLAUDEX WIDGET")
        #expect(ProjectName.lastComponent(ofPath: "/Users/me/app/") == "app")
        #expect(ProjectName.lastComponent(ofPath: nil) == nil)
        #expect(ProjectName.lastComponent(ofPath: "/") == nil)
    }
}

@Suite struct MultiSessionTests {
    static func assistant(_ model: String) -> String {
        #"{"type":"assistant","message":{"model":"\#(model)"}}"# + "\n"
    }

    @Test func selectionKeepsOnlyRecentFilesNewestFirst() {
        let now = Date()
        func file(_ name: String, _ age: TimeInterval) -> SessionFile {
            SessionFile(url: URL(fileURLWithPath: "/tmp/\(name)"), modified: now.addingTimeInterval(-age), project: name, isSubagent: false)
        }
        let selected = LiveSelection.select([file("old", 500), file("b", 60), file("a", 5), file("edge", 121)], now: now)
        #expect(selected.map(\.project) == ["a", "b"])
    }

    @Test func claudeScanFindsSessionsAndSubagentsAcrossProjects() throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let now = Date()
        try dir.write("-p-Alpha/s1.jsonl", Self.assistant("claude-opus-5-5"), modified: now.addingTimeInterval(-30))
        try dir.write("-p-Alpha/s1/subagents/agent-abc.jsonl", Self.assistant("claude-fable-5-1"), modified: now.addingTimeInterval(-5))
        try dir.write("-p-Alpha/s1/subagents/agent-abc.meta.json", "{}", modified: now)
        try dir.write("-p-Beta/s2.jsonl", Self.assistant("claude-sonnet-5-5"), modified: now.addingTimeInterval(-90))
        try dir.write("-p-Gamma/s3.jsonl", Self.assistant("claude-haiku-4-5"), modified: now.addingTimeInterval(-3600))

        let reader = ClaudeSessionReader(projectsDir: dir.url)
        #expect(reader.sessionFiles(projectName: { $0 }).count == 4)

        var cache = ParseCache<ClaudeSessionReader.Parsed>()
        let scan = reader.scan(now: now, cache: &cache, projectName: { String($0.split(separator: "-").last!) })
        #expect(scan.live.map(\.model) == ["claude-fable-5-1", "claude-opus-5-5", "claude-sonnet-5-5"])
        #expect(scan.live.map(\.project) == ["Alpha", "Alpha", "Beta"])
        #expect(scan.live.map(\.isSubagent) == [true, false, false])
        // Headline is the most recently active session's model.
        #expect(scan.headlineModel == "claude-fable-5-1")
        #expect(abs(scan.lastActivity!.timeIntervalSince(now.addingTimeInterval(-5))) < 1)
        // Only live files (here also the newest) were parsed; the idle one was not.
        #expect(cache.count == 3)
    }

    @Test func claudeProjectPrefersRecordedCwd() throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let line = #"{"type":"assistant","cwd":"/Users/me/Claude/Projects/CLAUDEX WIDGET","message":{"model":"claude-opus-5-5"}}"#
        try dir.write("-Users-me-Claude-Projects-CLAUDEX-WIDGET/s.jsonl", line + "\n", modified: Date())
        var cache = ParseCache<ClaudeSessionReader.Parsed>()
        let scan = ClaudeSessionReader(projectsDir: dir.url).scan(now: Date(), cache: &cache, projectName: { _ in "fallback" })
        #expect(scan.live.first?.project == "CLAUDEX WIDGET")
    }

    @Test func claudeHeadlineFallsBackToNewestWhenNothingLive() throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let now = Date()
        try dir.write("-p-A/s.jsonl", Self.assistant("claude-opus-5-5"), modified: now.addingTimeInterval(-900))
        try dir.write("-p-B/t.jsonl", Self.assistant("claude-sonnet-5-5"), modified: now.addingTimeInterval(-4000))
        var cache = ParseCache<ClaudeSessionReader.Parsed>()
        let scan = ClaudeSessionReader(projectsDir: dir.url).scan(now: now, cache: &cache, projectName: { $0 })
        #expect(scan.live.isEmpty)
        #expect(scan.headlineModel == "claude-opus-5-5")
        #expect(cache.count == 1)
    }

    @Test func codexScanListsLiveRolloutsWithProjectFromCwd() throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let now = Date()
        let meta = #"{"type":"session_meta","payload":{"cwd":"/Users/me/Projects/Whiteboard"}}"#
        let ctxA = #"{"type":"turn_context","payload":{"cwd":"/Users/me/Projects/Stock repo","model":"gpt-6-astra"}}"#
        let ctxB = #"{"type":"turn_context","payload":{"cwd":"/Users/me/Projects/Whiteboard","model":"gpt-6.1-sol"}}"#
        try dir.write("2026/10/16/rollout-a.jsonl", ctxA + "\n" + CodexParsingTests.tokenCountLine(primary: 30) + "\n",
                      modified: now.addingTimeInterval(-10))
        try dir.write("2026/10/15/rollout-b.jsonl", meta + "\n" + ctxB + "\n", modified: now.addingTimeInterval(-50))
        try dir.write("2026/10/01/rollout-c.jsonl", ctxB + "\n", modified: now.addingTimeInterval(-5000))

        var cache = ParseCache<CodexParsed>()
        let scan = CodexSessionReader(sessionsDir: dir.url).scan(now: now, cache: &cache)
        #expect(scan.hasSessions)
        #expect(scan.live.map(\.project) == ["Stock repo", "Whiteboard"])
        #expect(scan.live.map(\.model) == ["gpt-6-astra", "gpt-6.1-sol"])
        #expect(scan.headlineModel == "gpt-6-astra")
        #expect(scan.limits?.windows.first?.usedPercent == 30)
    }

    @Test func codexHeadNeverReplacesNewerTailMetadata() throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let now = Date()
        let ctxA = #"{"type":"turn_context","payload":{"cwd":"/p/Alpha","model":"gpt-6-astra"}}"#
        let ctxB = #"{"type":"turn_context","payload":{"cwd":"/p/Beta","model":"gpt-6.1-sol"}}"#
        let filler = { (n: Int) in (0..<n).map { _ in
            #"{"type":"event_msg","payload":{"type":"agent_message","message":"\#(String(repeating: "x", count: 100))"}}"#
        } }
        // Head says A; B is in the tail (the head is beyond a 1 KiB tail window).
        let lines = [ctxA] + filler(20) + [ctxB, CodexParsingTests.tokenCountLine(primary: 30)]
        let file = try dir.write("2026/10/16/rollout-a.jsonl", lines.joined(separator: "\n") + "\n",
                                 modified: now.addingTimeInterval(-20))
        let reader = CodexSessionReader(sessionsDir: dir.url)
        var cache = ParseCache<CodexParsed>()
        let first = reader.scan(now: now, cache: &cache, maxBytes: 1024)
        #expect(first.live.first?.model == "gpt-6.1-sol")
        #expect(first.live.first?.project == "Beta")

        // Append filler so B leaves the tail; the head still says A.
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((filler(20).joined(separator: "\n") + "\n").utf8))
        try handle.close()
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-5)], ofItemAtPath: file.path)
        #expect(CodexSessionReader.parse(lines: JSONLTail.lines(of: file, maxBytes: 1024)).model == nil)

        let second = reader.scan(now: now, cache: &cache, maxBytes: 1024)
        #expect(second.live.first?.model == "gpt-6.1-sol")
        #expect(second.live.first?.project == "Beta")
        #expect(second.headlineModel == "gpt-6.1-sol")
        #expect(second.limits?.modelSource == .tail)
        #expect(second.limits?.cwdSource == .tail)

        // A first scan with no prior observation falls back to the head (best effort).
        var fresh = ParseCache<CodexParsed>()
        let cold = reader.scan(now: now, cache: &fresh, maxBytes: 1024)
        #expect(cold.live.first?.model == "gpt-6-astra")
        #expect(cold.live.first?.project == "Alpha")
        #expect(cold.limits?.modelSource == .head)
    }

    @Test func missingUsageKeepsRetainedWindowsAsStale() {
        let seen = Date(timeIntervalSince1970: 1_000)
        let window = UsageWindow(id: "primary", label: "5h", usedPercent: 90, resetsAt: nil, windowMinutes: 300)
        var s = ProviderSnapshot(kind: .codex, windows: [window], planType: "pro", status: .ok)
        s.markUsageMissing(lastObserved: seen, message: "No usage reported yet")
        #expect(s.status == .stale(since: seen))
        #expect(s.windows == [window] && s.planType == "pro")
        #expect(s.isStale && s.indicatorLeftPercent == 10)
        #expect(s.mood == .worried)

        var never = ProviderSnapshot(kind: .codex, windows: [window], planType: "pro", status: .loading)
        never.markUsageMissing(lastObserved: nil, message: "No usage reported yet")
        #expect(never.status == .unavailable("No usage reported yet"))
        #expect(never.windows.isEmpty && never.planType == nil)
        #expect(!never.isStale && never.indicatorLeftPercent == nil)
        #expect(never.mood == .neutral)
    }

    @Test func signedOutOrUnavailableShowsEmptyRingAndNeutralMood() {
        let window = UsageWindow(id: "primary", label: "5h", usedPercent: 95, resetsAt: nil, windowMinutes: 300)
        for status in [ProviderStatus.needsSignIn, .unavailable("x")] {
            let s = ProviderSnapshot(kind: .claude, windows: [window], status: status)
            #expect(s.indicatorLeftPercent == nil)
            #expect(s.mood == .neutral)
        }
        #expect(ProviderSnapshot(kind: .claude, windows: [window], status: .ok).mood == .worried)
    }

    @Test func codexCwdPrefersTurnContextOverSessionMeta() {
        let parsed = CodexSessionReader.parse(lines: [
            #"{"type":"session_meta","payload":{"cwd":"/a/first"}}"#,
            #"{"type":"turn_context","payload":{"cwd":"/a/second","model":"gpt-6-astra"}}"#,
        ])
        #expect(parsed.cwd == "/a/second")
        #expect(CodexSessionReader.parse(lines: [#"{"type":"session_meta","payload":{"cwd":"/a/only"}}"#]).cwd == "/a/only")
    }

    @Test func emptyCodexDirReportsNoSessions() throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        var cache = ParseCache<CodexParsed>()
        let scan = CodexSessionReader(sessionsDir: dir.url).scan(now: Date(), cache: &cache)
        #expect(!scan.hasSessions && scan.live.isEmpty)
    }

    @Test func activityStates() {
        let now = Date()
        var s = ProviderSnapshot(kind: .claude, lastActivity: now.addingTimeInterval(-60))
        #expect(s.activity(now: now) == .idle)
        s.lastActivity = now.addingTimeInterval(-601)
        #expect(s.activity(now: now) == .sleepy)
        s.isActive = true
        #expect(s.activity(now: now) == .working)
        #expect(ProviderSnapshot(kind: .codex).activity(now: now) == .sleepy)
    }

    @Test func parseCacheReparsesOnlyWhenMtimeChanges() {
        var cache = ParseCache<Int>()
        var calls = 0
        let url = URL(fileURLWithPath: "/tmp/x.jsonl")
        let t = Date()
        _ = cache.value(for: url, modified: t) { calls += 1; return 1 }
        _ = cache.value(for: url, modified: t) { calls += 1; return 2 }
        #expect(calls == 1)
        #expect(cache.value(for: url, modified: t.addingTimeInterval(1)) { calls += 1; return 3 } == 3)
        #expect(calls == 2)
    }
}
