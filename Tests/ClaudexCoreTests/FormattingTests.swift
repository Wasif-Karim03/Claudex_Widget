import Foundation
import Testing
@testable import ClaudexCore

@Suite struct FormattingTests {
    @Test(arguments: [
        ("claude-opus-5-5", "Opus 5.5"),
        ("claude-fable-5-1", "Fable 5.1"),
        ("claude-sonnet-5-5", "Sonnet 5.5"),
        ("claude-3-5-sonnet-20241022", "Sonnet 3.5"),
        ("claude-haiku-4-5-20251001", "Haiku 4.5"),
        ("gpt-6-astra", "GPT-6 Astra"),
        ("gpt-6.1-sol", "GPT-6.1 Sol"),
        ("gpt-5-codex", "GPT-5 Codex"),
        ("o4-mini", "O4 Mini"),
        ("some_custom-model", "Some Custom Model"),
        ("", "—"),
    ])
    func prettyModelNames(raw: String, expected: String) {
        #expect(ModelNameFormatter.pretty(raw) == expected)
    }

    @Test func prettyNilIsDash() {
        #expect(ModelNameFormatter.pretty(nil) == "—")
    }

    @Test(arguments: [
        (Optional(300), "5h"), (1440, "Day"), (10080, "Week"),
        (2880, "2d"), (120, "2h"), (45, "45m"), (nil, "—"),
    ] as [(Int?, String)])
    func windowLabels(minutes: Int?, expected: String) {
        #expect(WindowLabel.label(minutes: minutes) == expected)
    }

    @Test func countdownBranches() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        func at(_ seconds: TimeInterval) -> String { CountdownFormatter.string(until: now.addingTimeInterval(seconds), now: now) }
        #expect(CountdownFormatter.string(until: nil, now: now) == "—")
        #expect(at(-5) == "resetting…")
        #expect(at(0) == "resetting…")
        #expect(at(30) == "<1m")
        #expect(at(14 * 60) == "14m")
        #expect(at(2 * 3600 + 14 * 60) == "2h 14m")
        #expect(at(3 * 86_400 + 4 * 3600 + 59) == "3d 4h")
    }

    @Test func countdownNeverTrapsOnHugeOrNonFiniteIntervals() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(CountdownFormatter.string(until: Date(timeIntervalSince1970: 1e30), now: now) == "—")
        #expect(CountdownFormatter.string(until: Date(timeIntervalSince1970: .infinity), now: now) == "—")
        #expect(CountdownFormatter.string(until: Date(timeIntervalSince1970: .nan), now: now) == "—")
        #expect(CountdownFormatter.string(until: Date(timeIntervalSince1970: -1e30), now: now) == "resetting…")
        #expect(CountdownFormatter.verbose(until: Date(timeIntervalSince1970: 1e30), now: now) == "—")
    }

    @Test func verboseCountdown() {
        let now = Date(timeIntervalSince1970: 0)
        #expect(CountdownFormatter.verbose(until: now.addingTimeInterval(600), now: now) == "resets in 10m")
        #expect(CountdownFormatter.verbose(until: nil, now: now) == "—")
        #expect(CountdownFormatter.verbose(until: now.addingTimeInterval(-1), now: now) == "resetting…")
    }

    @Test func usageWindowClampsAndMoodThresholds() {
        let over = UsageWindow(id: "a", label: "5h", usedPercent: 140, resetsAt: nil, windowMinutes: 300)
        #expect(over.usedPercent == 100 && over.leftPercent == 0)
        #expect(UsageWindow(id: "b", label: "5h", usedPercent: -3, resetsAt: nil, windowMinutes: 300).usedPercent == 0)

        func snapshot(_ used: Double...) -> ProviderSnapshot {
            ProviderSnapshot(kind: .claude, windows: used.enumerated().map {
                UsageWindow(id: "\($0.offset)", label: "x", usedPercent: $0.element, resetsAt: nil,
                            windowMinutes: $0.offset == 0 ? 10080 : 300)
            })
        }
        #expect(snapshot(10).mood == .happy)
        #expect(snapshot(60).mood == .neutral)
        #expect(snapshot(10, 85).mood == .worried)
        #expect(snapshot(10, 85).primaryWindow?.windowMinutes == 300)
    }
}
