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

    /// One entry of the `limits` list. Only model-scoped weekly limits (e.g. a separate
    /// weekly cap for one model) are used; the session and all-models week come from
    /// `five_hour` / `seven_day`.
    public struct Limit: Decodable, Sendable, Equatable {
        public let kind: String?
        public let percent: Double?
        public let resetsAt: Date?
        public let modelName: String?

        enum CodingKeys: String, CodingKey {
            case kind, percent, scope
            case resetsAt = "resets_at"
        }

        public init(kind: String?, percent: Double?, resetsAt: Date?, modelName: String?) {
            self.kind = kind
            self.percent = percent
            self.resetsAt = resetsAt
            self.modelName = modelName
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            kind = try? c.decodeIfPresent(String.self, forKey: .kind)
            percent = try? c.decodeIfPresent(Double.self, forKey: .percent)
            resetsAt = try? c.decodeIfPresent(Date.self, forKey: .resetsAt)
            modelName = (try? c.decodeIfPresent(Scope.self, forKey: .scope))??.model?.displayName
        }

        private struct Scope: Decodable {
            struct Model: Decodable {
                let displayName: String?
                enum CodingKeys: String, CodingKey { case displayName = "display_name" }
            }
            let model: Model?
        }
    }

    public let fiveHour: Window?
    public let sevenDay: Window?
    public let limits: [Limit]

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case limits
    }

    public init(fiveHour: Window?, sevenDay: Window?, limits: [Limit] = []) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.limits = limits
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fiveHour = try? c.decodeIfPresent(Window.self, forKey: .fiveHour)
        sevenDay = try? c.decodeIfPresent(Window.self, forKey: .sevenDay)
        // Entries that fail to decode are dropped rather than failing the response.
        let raw = (try? c.decodeIfPresent([Lenient<Limit>].self, forKey: .limits)) ?? nil
        limits = raw?.compactMap(\.value) ?? []
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

    /// Session, week (all models), then any per-model weekly limits, labelled as Claude
    /// Code's `/usage` names them.
    public func toWindows() -> [UsageWindow] {
        var windows: [UsageWindow] = []
        if let w = fiveHour, let used = w.utilization {
            windows.append(UsageWindow(id: "five_hour", label: "Session", usedPercent: used, resetsAt: w.resetsAt, windowMinutes: 300))
        }
        if let w = sevenDay, let used = w.utilization {
            windows.append(UsageWindow(id: "seven_day", label: "Week", usedPercent: used, resetsAt: w.resetsAt, windowMinutes: 10080))
        }
        for limit in limits where limit.kind == "weekly_scoped" {
            guard let used = limit.percent, let model = limit.modelName, !model.isEmpty else { continue }
            windows.append(UsageWindow(id: "weekly_\(model.lowercased())", label: "\(model) week", usedPercent: used,
                                       resetsAt: limit.resetsAt, windowMinutes: 10080))
        }
        return windows
    }
}

/// Decodes `T` when it can and yields nil otherwise, so one odd array element does not
/// sink the rest.
struct Lenient<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
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
