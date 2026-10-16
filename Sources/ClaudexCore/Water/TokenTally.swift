import Foundation

/// Tokens by kind. Cache reads are kept apart because they take far less compute.
public struct TokenCounts: Sendable, Equatable {
    /// Uncached input.
    public var input = 0
    public var cacheWrite = 0
    public var cacheRead = 0
    public var output = 0

    public init(input: Int = 0, cacheWrite: Int = 0, cacheRead: Int = 0, output: Int = 0) {
        self.input = input
        self.cacheWrite = cacheWrite
        self.cacheRead = cacheRead
        self.output = output
    }

    public static func + (a: TokenCounts, b: TokenCounts) -> TokenCounts {
        TokenCounts(input: a.input + b.input, cacheWrite: a.cacheWrite + b.cacheWrite,
                    cacheRead: a.cacheRead + b.cacheRead, output: a.output + b.output)
    }

    public var isEmpty: Bool { self == TokenCounts() }
}

/// A rough estimate of the water used to serve tokens. Nobody publishes per-token figures
/// for these models, so every constant here is an assumption; they live together so they
/// are easy to change.
public enum WaterEstimate {
    /// Compute per token relative to one uncached input token, following the API price
    /// ratios: cache reads 0.1×, cache writes 1.25×, output 5×.
    static let cacheReadWeight = 0.1
    static let cacheWriteWeight = 1.25
    static let outputWeight = 5.0
    /// Energy per input-equivalent token, so about 2 J per output token (in line with
    /// public estimates of roughly 0.3 Wh for a typical chatbot reply).
    static let joulesPerToken = 0.4
    /// Water per kWh: on-site data-centre cooling (about 0.5 L/kWh) plus the water used to
    /// generate the electricity (about 3.1 L/kWh, the US average).
    static let litresPerKWh = 3.6
    /// Bottled-water comparison used by the card.
    public static let litresPerDay = 2.0

    public static func weightedTokens(_ c: TokenCounts) -> Double {
        Double(c.input) + Double(c.cacheWrite) * cacheWriteWeight
            + Double(c.cacheRead) * cacheReadWeight + Double(c.output) * outputWeight
    }

    public static func litres(_ c: TokenCounts) -> Double {
        weightedTokens(c) * joulesPerToken / 3_600_000 * litresPerKWh
    }
}

/// Today's tokens, read incrementally: each log is read once, then only the bytes
/// appended since the last scan. Counts restart at local midnight.
public struct TokenTally: Sendable {
    public struct Today: Sendable, Equatable {
        public var claude = TokenCounts()
        public var codex = TokenCounts()
        public init(claude: TokenCounts = TokenCounts(), codex: TokenCounts = TokenCounts()) {
            self.claude = claude
            self.codex = codex
        }
        public var claudeLitres: Double { WaterEstimate.litres(claude) }
        public var codexLitres: Double { WaterEstimate.litres(codex) }
        public var litres: Double { claudeLitres + codexLitres }
    }

    struct FileState: Sendable {
        /// Bytes consumed so far; always just after a newline.
        var offset: UInt64 = 0
        /// Codex: the rollout's running total at the last `token_count` read.
        var codexTotal = TokenCounts()
    }

    public private(set) var today = Today()
    private var dayKey = ""
    private var files: [String: FileState] = [:]
    /// Claude logs repeat a message's usage on each of its content lines.
    private var seenMessages: Set<String> = []

    public init() {}

    /// Updates the counts from logs changed since local midnight. `calendar` sets the day.
    public mutating func update(
        claudeFiles: [SessionFile], codexFiles: [(url: URL, modified: Date)],
        now: Date, calendar: Calendar = .current
    ) {
        let dayStart = calendar.startOfDay(for: now)
        let key = Self.timestampKey(dayStart)
        if key != dayKey {
            self = TokenTally()
            dayKey = key
        }
        for file in claudeFiles where file.modified >= dayStart {
            for line in read(file.url) { addClaude(line: line) }
        }
        for file in codexFiles where file.modified >= dayStart {
            for line in read(file.url) { addCodex(line: line, path: file.url.path) }
        }
        let live = Set(claudeFiles.map(\.url.path)).union(codexFiles.map(\.url.path))
        files = files.filter { live.contains($0.key) }
    }

    /// The complete lines appended to `url` since the last read. A file that shrank was
    /// replaced, so it is read again from the start.
    private mutating func read(_ url: URL) -> [Substring] {
        let path = url.path
        var state = files[path] ?? FileState()
        guard let file = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? file.close() }
        guard let size = try? file.seekToEnd() else { return [] }
        if size < state.offset { state = FileState() }
        guard size > state.offset, (try? file.seek(toOffset: state.offset)) != nil,
              let data = try? file.readToEnd(),
              let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else {
            files[path] = state
            return []
        }
        let complete = data[data.startIndex...lastNewline]
        state.offset += UInt64(complete.count)
        files[path] = state
        return String(decoding: complete, as: UTF8.self).split(separator: "\n")
    }

    private mutating func addClaude(line: Substring) {
        guard line.contains("\"usage\""),
              let object = JSONLTail.object(from: String(line)) as? [String: Any], isToday(object),
              let message = object["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any] else { return }
        let id = (message["id"] as? String ?? "") + "|" + (object["requestId"] as? String ?? "")
        guard id != "|", seenMessages.insert(id).inserted else { return }
        today.claude = today.claude + TokenCounts(
            input: Self.int(usage["input_tokens"]),
            cacheWrite: Self.int(usage["cache_creation_input_tokens"]),
            cacheRead: Self.int(usage["cache_read_input_tokens"]),
            output: Self.int(usage["output_tokens"]))
    }

    /// Codex reports a running total per rollout; today's share is the growth of that
    /// total across lines stamped today.
    private mutating func addCodex(line: Substring, path: String) {
        guard line.contains("\"token_count\""),
              let object = JSONLTail.object(from: String(line)) as? [String: Any],
              let payload = object["payload"] as? [String: Any],
              let info = payload["info"] as? [String: Any],
              let total = info["total_token_usage"] as? [String: Any] else { return }
        let cached = Self.int(total["cached_input_tokens"])
        let written = Self.int(total["cache_write_input_tokens"])
        let current = TokenCounts(
            input: max(0, Self.int(total["input_tokens"]) - cached - written),
            cacheWrite: written, cacheRead: cached, output: Self.int(total["output_tokens"]))
        var state = files[path] ?? FileState()
        let before = state.codexTotal
        state.codexTotal = current
        files[path] = state
        guard isToday(object) else { return }
        today.codex = today.codex + TokenCounts(
            input: max(0, current.input - before.input),
            cacheWrite: max(0, current.cacheWrite - before.cacheWrite),
            cacheRead: max(0, current.cacheRead - before.cacheRead),
            output: max(0, current.output - before.output))
    }

    /// Compares the line's UTC `timestamp` with today's start as text: both are ISO 8601
    /// in UTC, so the first 19 characters order the same way the dates do.
    private func isToday(_ object: [String: Any]) -> Bool {
        guard let stamp = (object["timestamp"] as? String)?.prefix(19), stamp.count == 19 else { return false }
        return stamp >= Substring(dayKey)
    }

    static func timestampKey(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter.string(from: date)
    }

    private static func int(_ value: Any?) -> Int {
        (value as? NSNumber)?.intValue ?? 0
    }
}
