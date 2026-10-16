import Foundation

public struct CodexParsed: Sendable, Equatable {
    /// Where a metadata value was read: the tail is current, the head may be outdated.
    public enum Source: Sendable, Equatable { case tail, head }

    public var windows: [UsageWindow]
    public var planType: String?
    public var model: String?
    /// Working directory of the session, from `turn_context` or `session_meta`.
    public var cwd: String?
    /// True when a `rate_limits` object was found at all.
    public var hasRateLimits: Bool
    public var modelSource: Source?
    public var cwdSource: Source?
    /// When the limits were reported: their line's `timestamp`, else the file mtime.
    public var limitsObservedAt: Date?
    /// True when the limits were carried over from an earlier parse of this file because
    /// they have since scrolled out of the tail window.
    public var limitsRetained = false

    public init(windows: [UsageWindow] = [], planType: String? = nil, model: String? = nil,
                cwd: String? = nil, hasRateLimits: Bool = false) {
        self.windows = windows
        self.planType = planType
        self.model = model
        self.cwd = cwd
        self.hasRateLimits = hasRateLimits
    }

    /// Codex reports limits throughout a turn; activity this long after the last report
    /// means the report no longer reflects that use.
    public static let freshFor: TimeInterval = 900

    /// Limits only change through use or a reset, so a report is stale (since it was made)
    /// once a window it describes has reset, or once Codex was used more than `freshFor`
    /// after it. However old, a report with neither is still accurate.
    public func usageStatus(now: Date, lastActivity: Date?) -> ProviderStatus {
        guard hasRateLimits, let observed = limitsObservedAt else { return .ok }
        let resetSince = windows.contains { $0.resetsAt.map { $0 <= now } ?? false }
        let usedSince = lastActivity.map { $0.timeIntervalSince(observed) > Self.freshFor } ?? false
        return resetSince || usedSince ? .stale(since: observed) : .ok
    }

    /// Takes `other`'s limits, keeping this value's model and cwd.
    mutating func adoptLimits(from other: CodexParsed) {
        windows = other.windows
        planType = other.planType
        hasRateLimits = other.hasRateLimits
        limitsObservedAt = other.limitsObservedAt
        limitsRetained = other.limitsRetained
    }
}

/// Read-only view of Codex CLI rollouts under `~/.codex/sessions/YYYY/MM/DD/`, plus any
/// other Codex homes in `defaultSessionsDirs`.
public struct CodexSessionReader: Sendable {
    public struct Result: Sendable, Equatable {
        public let file: URL
        public let modified: Date
        public let parsed: CodexParsed
    }

    public static let candidateCount = 5

    public let sessionsDirs: [URL]

    /// `~/.codex/sessions`, and the sessions of the Codex home Claude Code's /team pipeline
    /// runs `codex exec` with (`CODEX_HOME=~/.claude/team-runs/.codex-home`). A missing
    /// directory is simply empty.
    public static var defaultSessionsDirs: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [".codex/sessions", ".claude/team-runs/.codex-home/sessions"]
            .map { home.appendingPathComponent($0, isDirectory: true) }
    }

    public init(sessionsDirs: [URL] = Self.defaultSessionsDirs) {
        self.sessionsDirs = sessionsDirs
    }

    public init(sessionsDir: URL) {
        self.init(sessionsDirs: [sessionsDir])
    }

    /// The `candidateCount` newest rollouts across every date dir.
    public func candidates(fileManager: FileManager = .default) -> [(url: URL, modified: Date)] {
        Array(allRollouts(fileManager: fileManager).prefix(Self.candidateCount))
    }

    /// Every `rollout-*.jsonl` in every date dir (stat only, no age cutoff), newest first.
    public func allRollouts(fileManager: FileManager = .default) -> [(url: URL, modified: Date)] {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey]
        var files: [(url: URL, modified: Date)] = []
        for dir in sessionsDirs {
            guard let enumerator = fileManager.enumerator(
                at: dir, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]
            ) else { continue }
            files += rollouts(in: enumerator, keys: keys)
        }
        files.sort { $0.modified > $1.modified }
        return files
    }

    private func rollouts(in enumerator: FileManager.DirectoryEnumerator,
                          keys: Set<URLResourceKey>) -> [(url: URL, modified: Date)] {
        var files: [(url: URL, modified: Date)] = []
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            guard name.hasPrefix("rollout-"), name.hasSuffix(".jsonl"),
                  let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate else { continue }
            files.append((url, modified))
        }
        return files
    }

    /// Reads the candidates (newest first); see `withLatestLimits` for which limits win.
    public func read(candidates: [(url: URL, modified: Date)], maxBytes: Int = 65_536) -> Result? {
        guard let newest = candidates.first else { return nil }
        let parsed = candidates.map { Self.parseFile($0.url, modified: $0.modified, maxBytes: maxBytes) }
        return Result(file: newest.url, modified: newest.modified, parsed: Self.withLatestLimits(parsed))
    }

    /// The first (newest) rollout's parse, with the most recently reported limits among
    /// all of `parsed` (newest first). Limits are account-wide, so the latest report wins
    /// whichever session made it; on equal report times the newer rollout wins. Model and
    /// cwd always stay the newest rollout's.
    public static func withLatestLimits(_ parsed: [CodexParsed]) -> CodexParsed {
        guard var result = parsed.first else { return CodexParsed() }
        let latest = parsed.enumerated()
            .filter { $0.element.hasRateLimits }
            .max { a, b in
                let ta = a.element.limitsObservedAt ?? .distantPast
                let tb = b.element.limitsObservedAt ?? .distantPast
                return ta != tb ? ta < tb : a.offset > b.offset
            }
        if let latest, latest.offset != 0 { result.adoptLimits(from: latest.element) }
        return result
    }

    /// Parses a rollout's tail. Model and cwd come from the tail when it has them; else
    /// the value `previous` (this file's last parse) observed is kept, so an older head
    /// value never replaces a newer tail one. Only with no prior observation is the head
    /// read: long sessions log `turn_context`/`session_meta` near the start, beyond the
    /// tail window, and that best effort is all a first scan has.
    /// The head fallback is deliberate: real rollouts record model and cwd only near the
    /// start, so reading the tail alone would show "—" for most sessions.
    /// Rate limits likewise come from the tail, else `previous`'s are retained (with their
    /// observation time and `limitsRetained` set) rather than dropped.
    /// `modified` (the file mtime, looked up when nil) anchors `resets_in_seconds` on lines
    /// without a `timestamp`; it only changes when the content does, so reparses agree.
    public static func parseFile(_ url: URL, modified: Date? = nil, maxBytes: Int = 65_536,
                                 previous: CodexParsed? = nil) -> CodexParsed {
        let anchor = modified ?? JSONLTail.modificationDate(of: url)
        var parsed = parse(lines: JSONLTail.lines(of: url, maxBytes: maxBytes), fallbackAnchor: anchor)
        parsed.modelSource = parsed.model == nil ? nil : .tail
        parsed.cwdSource = parsed.cwd == nil ? nil : .tail
        if parsed.model == nil, let model = previous?.model {
            parsed.model = model
            parsed.modelSource = previous?.modelSource
        }
        if parsed.cwd == nil, let cwd = previous?.cwd {
            parsed.cwd = cwd
            parsed.cwdSource = previous?.cwdSource
        }
        if !parsed.hasRateLimits, let previous, previous.hasRateLimits {
            parsed.adoptLimits(from: previous)
            parsed.limitsRetained = true
        }
        if parsed.model == nil || parsed.cwd == nil {
            let head = parse(lines: JSONLTail.headLines(of: url, maxBytes: maxBytes), fallbackAnchor: anchor)
            if parsed.model == nil, let model = head.model {
                parsed.model = model
                parsed.modelSource = .head
            }
            if parsed.cwd == nil, let cwd = head.cwd {
                parsed.cwd = cwd
                parsed.cwdSource = .head
            }
        }
        return parsed
    }

    public struct Scan: Sendable, Equatable {
        public var live: [LiveSession]
        /// Model of the newest rollout (the most recently active session); nil when it
        /// never recorded one, never another session's.
        public var headlineModel: String?
        public var lastActivity: Date?
        /// The most recently reported limits among the newest few rollouts.
        public var limits: CodexParsed?
        public var hasSessions: Bool
    }

    /// Stat every rollout, then parse only the tails of the live ones and the newest few.
    public func scan(now: Date, cache: inout ParseCache<CodexParsed>, maxBytes: Int = 65_536) -> Scan {
        let all = allRollouts()
        guard let newest = all.first else {
            cache.retain(paths: [])
            return Scan(live: [], headlineModel: nil, lastActivity: nil, limits: nil, hasSessions: false)
        }
        func parsed(_ file: (url: URL, modified: Date)) -> CodexParsed {
            cache.value(for: file.url, modified: file.modified) { previous in
                Self.parseFile(file.url, modified: file.modified, maxBytes: maxBytes, previous: previous)
            }
        }

        let liveFiles = LiveSelection.select(
            all.map { SessionFile(url: $0.url, modified: $0.modified, project: "", isSubagent: false) }, now: now)
        let live = liveFiles.map { file -> LiveSession in
            let p = parsed((file.url, file.modified))
            return LiveSession(id: file.url.path, model: p.model,
                               project: ProjectName.lastComponent(ofPath: p.cwd) ?? "Codex session",
                               isSubagent: false, modified: file.modified)
        }

        let candidates = Array(all.prefix(Self.candidateCount))
        let limits = Self.withLatestLimits(candidates.map(parsed))
        // Entries are small; keeping one per existing rollout means a session that goes
        // idle and later resumes still has the model and limits it reported before.
        cache.retain(paths: Set(all.map(\.url.path)))
        return Scan(live: live, headlineModel: limits.model, lastActivity: newest.modified, limits: limits, hasSessions: true)
    }

    /// Last `rate_limits` across lines wins. `resets_in_seconds` is anchored to that line's
    /// own top-level `timestamp`, else to `fallbackAnchor` (the file mtime), never to scan
    /// time, so reparsing the same content always yields the same deadline.
    public static func parse(lines: [String], fallbackAnchor: Date? = nil) -> CodexParsed {
        var rateLimits: [String: Any]?
        var limitsAnchor: Date?
        var contextModel: String?
        var anyModel: String?
        var contextCwd: String?
        var metaCwd: String?

        for line in lines {
            guard let object = JSONLTail.object(from: line) else { continue }
            if let limits = JSONSearch.find(key: "rate_limits", in: object) as? [String: Any] {
                rateLimits = limits
                limitsAnchor = lineTimestamp(in: object) ?? fallbackAnchor
            }
            if let model = turnContextModel(in: object) { contextModel = model }
            if let (type, cwd) = typedPayloadCwd(in: object) {
                if type == "turn_context" { contextCwd = cwd } else if type == "session_meta" { metaCwd = cwd }
            }
            if let model = JSONSearch.find(key: "model", in: object) as? String, !model.isEmpty {
                anyModel = model
            }
        }

        var result = CodexParsed(model: contextModel ?? anyModel, cwd: contextCwd ?? metaCwd)
        guard let limits = rateLimits else { return result }
        result.hasRateLimits = true
        result.limitsObservedAt = limitsAnchor
        result.planType = (limits["plan_type"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        for key in ["primary", "secondary"] {
            if let raw = limits[key] as? [String: Any], let parsed = makeWindow(id: key, from: raw, anchor: limitsAnchor) {
                result.windows.append(parsed)
            }
        }
        return result
    }

    public static func isActive(mtime: Date?, now: Date) -> Bool {
        JSONLTail.isActive(mtime: mtime, now: now)
    }

    private static func turnContextModel(in object: Any) -> String? {
        guard let dict = object as? [String: Any] else { return nil }
        if dict["type"] as? String == "turn_context" {
            if let payload = dict["payload"] as? [String: Any], let model = payload["model"] as? String, !model.isEmpty {
                return model
            }
            if let model = dict["model"] as? String, !model.isEmpty { return model }
        }
        if let payload = dict["payload"] as? [String: Any], payload["type"] as? String == "turn_context",
           let model = payload["model"] as? String, !model.isEmpty {
            return model
        }
        return nil
    }

    /// `(type, cwd)` for a `{"type": "...", "payload": {"cwd": ...}}` line.
    private static func typedPayloadCwd(in object: Any) -> (String, String)? {
        guard let dict = object as? [String: Any], let type = dict["type"] as? String,
              let payload = dict["payload"] as? [String: Any],
              let cwd = payload["cwd"] as? String, !cwd.isEmpty else { return nil }
        return (type, cwd)
    }

    /// Bounds for values read from logs; anything outside is dropped rather than trusted.
    static let maxWindowMinutes: Double = 10_000_000          // ~19 years
    static let epochRange: ClosedRange<Double> = 0...32_503_680_000 // up to year 3000
    static let maxRelativeSeconds: Double = 1_000_000_000      // ~31 years

    private static func makeWindow(id: String, from dict: [String: Any], anchor: Date?) -> UsageWindow? {
        guard let used = number(dict["used_percent"]) else { return nil }
        let minutes = number(dict["window_minutes"])
            .flatMap { $0 > 0 && $0 <= maxWindowMinutes ? Int($0) : nil }
        var resetsAt: Date?
        if let epoch = number(dict["resets_at"]), epochRange.contains(epoch) {
            resetsAt = Date(timeIntervalSince1970: epoch)
        } else if let relative = number(dict["resets_in_seconds"]), abs(relative) <= maxRelativeSeconds,
                  let anchor {
            resetsAt = anchor.addingTimeInterval(relative)
        }
        return UsageWindow(id: id, label: WindowLabel.label(minutes: minutes), usedPercent: used,
                           resetsAt: resetsAt, windowMinutes: minutes)
    }

    /// The top-level ISO8601 `timestamp` Codex writes on every line, if present.
    private static func lineTimestamp(in object: Any) -> Date? {
        guard let raw = (object as? [String: Any])?["timestamp"] as? String else { return nil }
        if let date = try? Date(raw, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) { return date }
        return try? Date(raw, strategy: Date.ISO8601FormatStyle())
    }

    /// Finite numbers only; NaN and infinities (e.g. from `"nan"` strings) are dropped.
    private static func number(_ value: Any?) -> Double? {
        let result: Double?
        switch value {
        case let n as NSNumber: result = n.doubleValue
        case let s as String: result = Double(s)
        default: result = nil
        }
        return result.flatMap { $0.isFinite ? $0 : nil }
    }
}
