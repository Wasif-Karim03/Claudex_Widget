import Foundation
import Testing
@testable import ClaudexCore

@Suite struct CodexParsingTests {
    static func tokenCountLine(primary: Double, secondary: String = "null", plan: String = "pro") -> String {
        """
        {"timestamp":"2026-10-16T02:23:40Z","type":"event_msg","payload":{"type":"token_count","info":{"rate_limits":{"limit_id":"codex","primary":{"used_percent":\(primary),"window_minutes":300,"resets_at":1792674533},"secondary":\(secondary),"credits":{"has_credits":true},"plan_type":"\(plan)"}}}}
        """
    }

    @Test func findsRateLimitsNestedThreeDeep() {
        let parsed = CodexSessionReader.parse(lines: [Self.tokenCountLine(primary: 16)])
        #expect(parsed.hasRateLimits)
        #expect(parsed.windows.count == 1)
        #expect(parsed.windows[0].usedPercent == 16)
        #expect(parsed.windows[0].resetsAt == Date(timeIntervalSince1970: 1_792_674_533))
        #expect(parsed.planType == "pro")
    }

    @Test func lastRateLimitsWinAcrossLines() {
        let parsed = CodexSessionReader.parse(lines: [
            Self.tokenCountLine(primary: 10, plan: "plus"),
            Self.tokenCountLine(primary: 42, plan: "pro"),
        ])
        #expect(parsed.windows.first?.usedPercent == 42)
        #expect(parsed.planType == "pro")
    }

    @Test func nullSecondaryGivesOneWindowAndPresentGivesTwo() {
        #expect(CodexSessionReader.parse(lines: [Self.tokenCountLine(primary: 5)]).windows.count == 1)
        let both = CodexSessionReader.parse(lines: [Self.tokenCountLine(
            primary: 5, secondary: #"{"used_percent":70.5,"window_minutes":10080,"resets_at":1792999999}"#)])
        #expect(both.windows.map(\.label) == ["5h", "Week"])
        #expect(both.windows[1].usedPercent == 70.5)
    }

    @Test func resetsInSecondsIsAnchoredToTheLineTimestamp() {
        let line = #"{"timestamp":"2026-10-16T02:23:40.500Z","type":"event_msg","payload":{"rate_limits":{"primary":{"used_percent":1,"window_minutes":300,"resets_in_seconds":120}}}}"#
        let expected = isoDate("2026-10-16T02:25:40.500Z")
        // The fallback anchor is ignored when the line carries its own timestamp.
        let first = CodexSessionReader.parse(lines: [line], fallbackAnchor: Date(timeIntervalSince1970: 0))
        #expect(first.windows.first?.resetsAt == expected)
        // Same content reparsed later (different fallback, different wall clock) gives the same deadline.
        let later = CodexSessionReader.parse(lines: [line], fallbackAnchor: Date().addingTimeInterval(3600))
        #expect(later.windows.first?.resetsAt == expected)
    }

    @Test func resetsInSecondsWithoutTimestampUsesFileMtimeStably() throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let mtime = Date(timeIntervalSince1970: 1_792_000_000)
        let line = #"{"rate_limits":{"primary":{"used_percent":1,"window_minutes":300,"resets_in_seconds":120}}}"#
        let file = try dir.write("2026/10/16/rollout-a.jsonl", line + "\n", modified: mtime)
        let first = CodexSessionReader.parseFile(file)
        let second = CodexSessionReader.parseFile(file)
        #expect(first.windows.first?.resetsAt == mtime.addingTimeInterval(120))
        #expect(second.windows.first?.resetsAt == first.windows.first?.resetsAt)
        // With no timestamp and no file, there is no anchor: no deadline rather than scan time.
        #expect(CodexSessionReader.parse(lines: [line]).windows.first?.resetsAt == nil)
    }

    @Test func absurdNumbersAreDroppedWithoutTrapping() {
        let lines = [
            #"{"rate_limits":{"primary":{"used_percent":10,"window_minutes":1e30,"resets_at":1e300}}}"#,
            #"{"rate_limits":{"primary":{"used_percent":20,"window_minutes":-300,"resets_at":-1e30}}}"#,
            #"{"rate_limits":{"primary":{"used_percent":"NaN","window_minutes":300}}}"#,
            #"{"rate_limits":{"primary":{"used_percent":30,"window_minutes":"inf","resets_in_seconds":1e30}}}"#,
            #"{"rate_limits":{"primary":{"used_percent":40,"window_minutes":"nan","resets_in_seconds":"-inf"}}}"#,
        ]
        let anchor = Date(timeIntervalSince1970: 1_000_000)
        let now = Date()
        for line in lines {
            let parsed = CodexSessionReader.parse(lines: [line], fallbackAnchor: anchor)
            for window in parsed.windows {
                #expect(window.windowMinutes == nil)
                #expect(window.resetsAt == nil)
                #expect(window.label == "—")
                _ = CountdownFormatter.string(until: window.resetsAt, now: now)
            }
        }
        // A NaN used_percent drops the whole window.
        #expect(CodexSessionReader.parse(lines: [lines[2]]).windows.isEmpty)
        #expect(CodexSessionReader.parse(lines: [lines[0]]).windows.first?.usedPercent == 10)
        // Plausible values still parse.
        let ok = CodexSessionReader.parse(lines: [Self.tokenCountLine(primary: 16)])
        #expect(ok.windows.first?.windowMinutes == 300)
    }

    @Test func malformedLinesAreIgnored() {
        let parsed = CodexSessionReader.parse(lines: [
            "{not json",
            Self.tokenCountLine(primary: 30),
            "\u{0}\u{1}garbage",
            #"{"type":"turn_context","payload":{"model":"gpt-6-astra"}"#, // truncated
        ])
        #expect(parsed.windows.first?.usedPercent == 30)
        #expect(parsed.model == nil)
    }

    @Test func modelComesFromLastTurnContext() {
        let parsed = CodexSessionReader.parse(lines: [
            #"{"type":"turn_context","payload":{"cwd":"/tmp","model":"gpt-5-codex"}}"#,
            #"{"type":"response_item","payload":{"model":"some-other-model"}}"#,
            #"{"type":"turn_context","payload":{"cwd":"/tmp","model":"gpt-6-astra"}}"#,
            #"{"type":"event_msg","payload":{"model":"later-non-context"}}"#,
        ])
        #expect(parsed.model == "gpt-6-astra")
    }

    @Test func modelFallsBackToAnyModelString() {
        let parsed = CodexSessionReader.parse(lines: [#"{"type":"session_meta","payload":{"model":"gpt-6.1-sol"}}"#])
        #expect(parsed.model == "gpt-6.1-sol")
    }

    @Test func fallsBackToOlderFileForLimitsButKeepsNewestModel() throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let base = Date().addingTimeInterval(-1000)
        try dir.write("2026/10/15/rollout-old.jsonl", Self.tokenCountLine(primary: 55) + "\n"
            + #"{"type":"turn_context","payload":{"model":"gpt-5-codex"}}"# + "\n", modified: base)
        try dir.write("2026/10/16/rollout-new.jsonl",
                      #"{"type":"turn_context","payload":{"model":"gpt-6-astra"}}"# + "\n", modified: base.addingTimeInterval(500))
        let reader = CodexSessionReader(sessionsDir: dir.url)
        let candidates = reader.candidates()
        #expect(candidates.first?.url.lastPathComponent == "rollout-new.jsonl")
        let result = try #require(reader.read(candidates: candidates))
        #expect(result.parsed.model == "gpt-6-astra")
        #expect(result.parsed.windows.first?.usedPercent == 55)
        #expect(result.file.lastPathComponent == "rollout-new.jsonl")
    }

    @Test func modelFoundInHeadWhenTailLacksIt() throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let head = #"{"type":"turn_context","payload":{"model":"gpt-6.1-sol"}}"#
        let filler = (0..<40).map { _ in #"{"type":"event_msg","payload":{"type":"agent_message","message":"\#(String(repeating: "x", count: 100))"}}"# }
        let body = ([head] + filler + [Self.tokenCountLine(primary: 20)]).joined(separator: "\n") + "\n"
        try dir.write("2026/10/16/rollout-long.jsonl", body)
        let reader = CodexSessionReader(sessionsDir: dir.url)
        let result = try #require(reader.read(candidates: reader.candidates(), maxBytes: 1024))
        #expect(result.parsed.model == "gpt-6.1-sol")
        #expect(result.parsed.windows.first?.usedPercent == 20)
    }

    @Test func resumedSessionInOldDateDirIsSelectedFirst() throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let base = Date().addingTimeInterval(-100_000)
        // 31 newer day-dirs each with a rollout that is older by mtime.
        for day in 1...31 {
            try dir.write(String(format: "2026/09/%02d/rollout-\(day).jsonl", day), "{}\n",
                          modified: base.addingTimeInterval(Double(day)))
        }
        // A session from months earlier that was resumed and written most recently.
        try dir.write("2026/06/01/rollout-resumed.jsonl", "{}\n", modified: base.addingTimeInterval(10_000))
        let candidates = CodexSessionReader(sessionsDir: dir.url).candidates()
        #expect(candidates.count == CodexSessionReader.candidateCount)
        #expect(candidates.first?.url.lastPathComponent == "rollout-resumed.jsonl")
        #expect(candidates.dropFirst().map(\.url.lastPathComponent) == ["rollout-31.jsonl", "rollout-30.jsonl", "rollout-29.jsonl", "rollout-28.jsonl"])
    }

    @Test func mergesRolloutsFromEverySessionsDir() throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        try dir.write("main/2026/10/16/rollout-main.jsonl", "{}\n", modified: base)
        try dir.write("team/.codex-home/sessions/2026/10/16/rollout-team.jsonl", "{}\n", modified: base.addingTimeInterval(60))
        let reader = CodexSessionReader(sessionsDirs: [
            dir.url.appendingPathComponent("main"),
            dir.url.appendingPathComponent("team/.codex-home/sessions"),
            dir.url.appendingPathComponent("missing"),
        ])
        #expect(reader.allRollouts().map(\.url.lastPathComponent) == ["rollout-team.jsonl", "rollout-main.jsonl"])
    }

    @Test func activityIsAPureFunctionOfMtime() {
        let now = Date()
        #expect(CodexSessionReader.isActive(mtime: now.addingTimeInterval(-30), now: now))
        #expect(!CodexSessionReader.isActive(mtime: now.addingTimeInterval(-121), now: now))
        #expect(!CodexSessionReader.isActive(mtime: nil, now: now))
        #expect(ClaudeSessionReader.isActive(mtime: now.addingTimeInterval(-120), now: now))
        #expect(!ClaudeSessionReader.isActive(mtime: now.addingTimeInterval(-600), now: now))
    }
}
