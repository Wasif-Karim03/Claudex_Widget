import Foundation
import Testing
@testable import ClaudexCore

@Suite struct ClaudeUsageDecodingTests {
    static let sample = """
    {
      "five_hour": {"utilization": 35.0, "resets_at": "2026-10-16T08:50:00.288412+00:00"},
      "seven_day": {"utilization": 16.0, "resets_at": "2026-10-20T03:00:00.123456+00:00"},
      "seven_day_opus": null,
      "seven_day_oauth_apps": null,
      "extra_usage": {"is_enabled": false, "monthly_limit": null, "used_credits": null, "limit_dollars": 50},
      "some_future_key": [1, 2, {"nested": true}]
    }
    """

    @Test func decodesSampleWithUnknownKeys() throws {
        let response = try ClaudeUsageResponse.decode(Data(Self.sample.utf8))
        #expect(response.fiveHour?.utilization == 35.0)
        #expect(response.sevenDay?.utilization == 16.0)
        let expected = isoDate("2026-10-16T08:50:00.288Z")
        let actual = try #require(response.fiveHour?.resetsAt)
        #expect(abs(actual.timeIntervalSince(expected)) <= 0.001)
        let week = try #require(response.sevenDay?.resetsAt)
        #expect(abs(week.timeIntervalSince(isoDate("2026-10-20T03:00:00.123Z"))) <= 0.001)
    }

    @Test func mapsToWindows() throws {
        let windows = try ClaudeUsageResponse.decode(Data(Self.sample.utf8)).toWindows()
        #expect(windows.map(\.label) == ["5h", "Week"])
        #expect(windows.map(\.windowMinutes) == [300, 10080])
        #expect(windows[0].leftPercent == 65)
    }

    @Test func missingFiveHourYieldsOnlyWeek() throws {
        let json = #"{"seven_day": {"utilization": 50, "resets_at": "2026-10-20T03:00:00Z"}}"#
        let response = try ClaudeUsageResponse.decode(Data(json.utf8))
        #expect(response.fiveHour == nil)
        #expect(response.toWindows().map(\.label) == ["Week"])
    }

    @Test func parsesZuluWithoutFraction() throws {
        let json = #"{"five_hour": {"utilization": 1.5, "resets_at": "2026-10-16T08:50:00Z"}}"#
        let response = try ClaudeUsageResponse.decode(Data(json.utf8))
        let date = try #require(response.fiveHour?.resetsAt)
        #expect(date == isoDate("2026-10-16T08:50:00.000Z"))
    }

    @Test func nullWindowsAreSkipped() throws {
        let json = #"{"five_hour": null, "seven_day": {"utilization": null, "resets_at": null}}"#
        #expect(try ClaudeUsageResponse.decode(Data(json.utf8)).toWindows().isEmpty)
    }
}
