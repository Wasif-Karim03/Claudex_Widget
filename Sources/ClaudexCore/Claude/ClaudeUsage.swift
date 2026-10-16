import Foundation

/// Response of `GET https://api.anthropic.com/api/oauth/usage`. Only the fields Claudex
/// shows are decoded; unknown keys are ignored.
public struct ClaudeUsageResponse: Decodable, Sendable, Equatable {
    public struct Window: Decodable, Sendable, Equatable {
        public let utilization: Double?
        public let resetsAt: Date?

        enum CodingKeys: String, CodingKey {
            case utilization
            case resetsAt = "resets_at"
        }

        public init(utilization: Double?, resetsAt: Date?) {
            self.utilization = utilization
            self.resetsAt = resetsAt
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            utilization = try? c.decodeIfPresent(Double.self, forKey: .utilization)
            resetsAt = try? c.decodeIfPresent(Date.self, forKey: .resetsAt)
        }
    }

    public let fiveHour: Window?
    public let sevenDay: Window?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
    }

    public init(fiveHour: Window?, sevenDay: Window?) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fiveHour = try? c.decodeIfPresent(Window.self, forKey: .fiveHour)
        sevenDay = try? c.decodeIfPresent(Window.self, forKey: .sevenDay)
    }

    public static func decode(_ data: Data) throws -> ClaudeUsageResponse {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            guard let date = ClaudeDateParser.parse(string) else {
                throw DecodingError.dataCorruptedError(
                    in: container, debugDescription: "Unrecognised date: \(string)")
            }
            return date
        }
        return try decoder.decode(ClaudeUsageResponse.self, from: data)
    }

    public func toWindows() -> [UsageWindow] {
        var windows: [UsageWindow] = []
        if let w = fiveHour, let used = w.utilization {
            windows.append(UsageWindow(id: "five_hour", label: "5h", usedPercent: used, resetsAt: w.resetsAt, windowMinutes: 300))
        }
        if let w = sevenDay, let used = w.utilization {
            windows.append(UsageWindow(id: "seven_day", label: "Week", usedPercent: used, resetsAt: w.resetsAt, windowMinutes: 10080))
        }
        return windows
    }
}

/// ISO 8601 parsing tolerant of 0–9 fractional digits and `Z` or `±hh:mm` offsets.
public enum ClaudeDateParser {
    public static func parse(_ raw: String) -> Date? {
        let string = raw.trimmingCharacters(in: .whitespaces)
        let normalised = normaliseFraction(string)
        if let date = try? Date(normalised, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) {
            return date
        }
        return try? Date(normalised, strategy: Date.ISO8601FormatStyle())
    }

    /// Pads or truncates the fractional-seconds part to exactly three digits.
    static func normaliseFraction(_ s: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"\.(\d+)"#) else { return s }
        let ns = s as NSString
        guard let match = regex.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return s }
        let digits = ns.substring(with: match.range(at: 1))
        let three = String((digits + "000").prefix(3))
        return ns.replacingCharacters(in: match.range, with: "." + three)
    }
}
