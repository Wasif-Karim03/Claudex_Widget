import Foundation

public enum ModelNameFormatter {
    /// Turns raw model ids into short display names, e.g. `claude-opus-5-5` -> "Opus 5.5".
    public static func pretty(_ raw: String?) -> String {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return "—" }
        let lower = raw.lowercased()
        if lower.hasPrefix("claude-") { return prettyClaude(String(lower.dropFirst("claude-".count))) ?? fallback(raw) }
        if lower.hasPrefix("gpt-") { return prettyGPT(String(lower.dropFirst("gpt-".count))) ?? fallback(raw) }
        return fallback(raw)
    }

    private static func prettyClaude(_ rest: String) -> String? {
        var tokens = rest.split(separator: "-").map(String.init)
        // Drop a trailing 8-digit date stamp such as 20241022.
        if let last = tokens.last, last.count == 8, last.allSatisfy(\.isNumber) { tokens.removeLast() }
        var family: String?
        var numbers: [String] = []
        for token in tokens {
            if token.allSatisfy(\.isNumber) {
                numbers.append(token)
            } else if family == nil, token.allSatisfy(\.isLetter) {
                family = token.capitalized
            } else {
                return nil
            }
        }
        guard let family else { return nil }
        return numbers.isEmpty ? family : "\(family) \(numbers.joined(separator: "."))"
    }

    private static func prettyGPT(_ rest: String) -> String? {
        let tokens = rest.split(separator: "-").map(String.init)
        guard let version = tokens.first else { return nil }
        let words = tokens.dropFirst().map { $0.capitalized }
        return (["GPT-\(version)"] + words).joined(separator: " ")
    }

    private static func fallback(_ raw: String) -> String {
        let words = raw
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { word -> String in
                guard let first = word.first else { return "" }
                return first.uppercased() + word.dropFirst()
            }
        return words.isEmpty ? "—" : words.joined(separator: " ")
    }
}

public enum WindowLabel {
    public static func label(minutes: Int?) -> String {
        guard let minutes, minutes > 0 else { return "—" }
        switch minutes {
        case 300: return "5h"
        case 1440: return "Day"
        case 10080: return "Week"
        default:
            if minutes % 1440 == 0 { return "\(minutes / 1440)d" }
            if minutes % 60 == 0 { return "\(minutes / 60)h" }
            return "\(minutes)m"
        }
    }
}

public enum CountdownFormatter {
    static let maxSeconds: TimeInterval = 3_153_600_000

    public static func string(until date: Date?, now: Date) -> String {
        guard let date else { return "—" }
        let seconds = date.timeIntervalSince(now)
        // Non-finite or absurdly distant deadlines (> ~100 years) cannot be shown honestly
        // and would trap in the Int conversion below.
        guard seconds.isFinite, seconds < maxSeconds else { return "—" }
        if seconds <= 0 { return "resetting…" }
        if seconds < 60 { return "<1m" }
        let totalMinutes = Int(seconds / 60)
        if seconds < 3600 { return "\(totalMinutes)m" }
        if seconds < 86_400 { return "\(totalMinutes / 60)h \(totalMinutes % 60)m" }
        let totalHours = totalMinutes / 60
        return "\(totalHours / 24)d \(totalHours % 24)h"
    }

    public static func verbose(until date: Date?, now: Date) -> String {
        let core = string(until: date, now: now)
        switch core {
        case "—", "resetting…": return core
        default: return "resets in \(core)"
        }
    }
}
