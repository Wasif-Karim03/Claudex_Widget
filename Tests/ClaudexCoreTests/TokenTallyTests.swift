import Foundation
import Testing
@testable import ClaudexCore

@Suite struct TokenTallyTests {
    static let now = isoDate("2026-10-16T12:00:00.000Z")
    static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    static func claudeLine(id: String, at time: String, input: Int = 0, write: Int = 0, read: Int = 0, output: Int = 0) -> String {
        #"{"type":"assistant","timestamp":"\#(time)","requestId":"req-\#(id)","message":{"id":"msg-\#(id)","model":"claude-opus-5-5","usage":{"input_tokens":\#(input),"cache_creation_input_tokens":\#(write),"cache_read_input_tokens":\#(read),"output_tokens":\#(output)}}}"#
    }

    static func codexLine(at time: String, input: Int, cached: Int, output: Int) -> String {
        #"{"timestamp":"\#(time)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\#(input),"cached_input_tokens":\#(cached),"cache_write_input_tokens":0,"output_tokens":\#(output),"reasoning_output_tokens":0,"total_tokens":0}}}}"#
    }

    static func claudeFile(_ url: URL) -> SessionFile {
        SessionFile(url: url, modified: now, project: "p", isSubagent: false)
    }

    @Test func countsEachClaudeMessageOnceAndOnlyToday() throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let url = try dir.write("a.jsonl", [
            Self.claudeLine(id: "old", at: "2026-10-15T23:59:59.000Z", output: 1000),
            Self.claudeLine(id: "1", at: "2026-10-16T09:00:00.000Z", input: 2, write: 100, read: 5000, output: 30),
            // The same message logged again for its next content block.
            Self.claudeLine(id: "1", at: "2026-10-16T09:00:01.000Z", input: 2, write: 100, read: 5000, output: 30),
            Self.claudeLine(id: "2", at: "2026-10-16T10:00:00.000Z", output: 10),
        ].joined(separator: "\n") + "\n")

        var tally = TokenTally()
        tally.update(claudeFiles: [Self.claudeFile(url)], codexFiles: [], now: Self.now, calendar: Self.utc)
        #expect(tally.today.claude == TokenCounts(input: 2, cacheWrite: 100, cacheRead: 5000, output: 40))
    }

    @Test func readsOnlyAppendedCompleteLines() throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let first = Self.claudeLine(id: "1", at: "2026-10-16T09:00:00.000Z", output: 10) + "\n"
        let second = Self.claudeLine(id: "2", at: "2026-10-16T09:01:00.000Z", output: 5)
        // The second line is still being written: no newline yet.
        let url = try dir.write("a.jsonl", first + second)

        var tally = TokenTally()
        tally.update(claudeFiles: [Self.claudeFile(url)], codexFiles: [], now: Self.now, calendar: Self.utc)
        #expect(tally.today.claude.output == 10)

        try (first + second + "\n").write(to: url, atomically: false, encoding: .utf8)
        tally.update(claudeFiles: [Self.claudeFile(url)], codexFiles: [], now: Self.now, calendar: Self.utc)
        #expect(tally.today.claude.output == 15)

        // Nothing new: nothing added.
        tally.update(claudeFiles: [Self.claudeFile(url)], codexFiles: [], now: Self.now, calendar: Self.utc)
        #expect(tally.today.claude.output == 15)
    }

    @Test func codexCountsGrowthOfRunningTotalSinceMidnight() throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let url = try dir.write("rollout-a.jsonl", [
            Self.codexLine(at: "2026-10-15T23:00:00.000Z", input: 1000, cached: 400, output: 50),
            Self.codexLine(at: "2026-10-16T01:00:00.000Z", input: 3000, cached: 2000, output: 80),
            // Repeated report of the same total.
            Self.codexLine(at: "2026-10-16T01:00:05.000Z", input: 3000, cached: 2000, output: 80),
        ].joined(separator: "\n") + "\n")

        var tally = TokenTally()
        tally.update(claudeFiles: [], codexFiles: [(url, Self.now)], now: Self.now, calendar: Self.utc)
        // Uncached input went 600 → 1000, cached 400 → 2000, output 50 → 80.
        #expect(tally.today.codex == TokenCounts(input: 400, cacheWrite: 0, cacheRead: 1600, output: 30))
    }

    @Test func restartsAtMidnightAndSkipsOldFiles() throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let url = try dir.write("a.jsonl", Self.claudeLine(id: "1", at: "2026-10-16T09:00:00.000Z", output: 10) + "\n")
        var tally = TokenTally()
        tally.update(claudeFiles: [Self.claudeFile(url)], codexFiles: [], now: Self.now, calendar: Self.utc)
        #expect(tally.today.claude.output == 10)

        let tomorrow = isoDate("2026-10-17T08:00:00.000Z")
        tally.update(claudeFiles: [Self.claudeFile(url)], codexFiles: [], now: tomorrow, calendar: Self.utc)
        #expect(tally.today.claude.isEmpty)
    }

    @Test func rereadsAReplacedFile() throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let url = try dir.write("a.jsonl", [
            Self.claudeLine(id: "1", at: "2026-10-16T09:00:00.000Z", output: 10),
            Self.claudeLine(id: "2", at: "2026-10-16T09:00:00.000Z", output: 10),
        ].joined(separator: "\n") + "\n")
        var tally = TokenTally()
        tally.update(claudeFiles: [Self.claudeFile(url)], codexFiles: [], now: Self.now, calendar: Self.utc)

        try (Self.claudeLine(id: "3", at: "2026-10-16T11:00:00.000Z", output: 7) + "\n")
            .write(to: url, atomically: true, encoding: .utf8)
        tally.update(claudeFiles: [Self.claudeFile(url)], codexFiles: [], now: Self.now, calendar: Self.utc)
        #expect(tally.today.claude.output == 27)
    }

    @Test func waterEstimateWeightsTokenKinds() {
        // 1M input-equivalent tokens → 0.4 MJ ≈ 0.111 kWh → 0.4 L.
        #expect(abs(WaterEstimate.litres(TokenCounts(input: 1_000_000)) - 0.4) < 1e-9)
        #expect(abs(WaterEstimate.litres(TokenCounts(cacheRead: 10_000_000)) - 0.4) < 1e-9)
        #expect(abs(WaterEstimate.litres(TokenCounts(output: 200_000)) - 0.4) < 1e-9)
    }
}
