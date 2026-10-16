import Foundation

public enum JSONLTail {
    /// Returns the non-empty lines in the last `maxBytes` of a file. When reading starts
    /// mid-file, the first (partial) line is dropped.
    public static func lines(of url: URL, maxBytes: Int = 65_536) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return [] }
        let offset = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        do {
            try handle.seek(toOffset: offset)
        } catch {
            return []
        }
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return [] }
        var lines = data
            .split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }
        if offset > 0, !lines.isEmpty { lines.removeFirst() }
        return lines.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// Returns the complete, non-empty lines in the first `maxBytes` of a file. A trailing
    /// partial line is dropped when the file is longer than `maxBytes`.
    public static func headLines(of url: URL, maxBytes: Int = 65_536) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxBytes + 1), !data.isEmpty else { return [] }
        let truncated = data.count > maxBytes
        var lines = data.prefix(maxBytes)
            .split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }
        if truncated, !lines.isEmpty { lines.removeLast() }
        return lines.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// Parses one JSONL line into a JSON object; nil for malformed lines.
    public static func object(from line: String) -> Any? {
        guard let data = line.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    /// Newest regular file in `directory` whose name passes `matching`, by modification date.
    public static func newestFile(
        in directory: URL,
        matching: (String) -> Bool,
        fileManager: FileManager = .default
    ) -> (url: URL, modified: Date)? {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let items = try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return nil }
        var best: (url: URL, modified: Date)?
        for item in items where matching(item.lastPathComponent) {
            guard let values = try? item.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate else { continue }
            if best == nil || modified > best!.modified { best = (item, modified) }
        }
        return best
    }

    /// Modification date of a file, if it exists.
    public static func modificationDate(of url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    /// Pure activity rule shared by both readers: a session is active if its log was
    /// written within `window` seconds of `now`.
    public static func isActive(mtime: Date?, now: Date, window: TimeInterval = 120) -> Bool {
        guard let mtime else { return false }
        return now.timeIntervalSince(mtime) <= window
    }
}

public enum JSONSearch {
    /// First value stored under `key` in a deterministic depth-first walk with dictionary
    /// keys in sorted order. JSONSerialization does not keep document order, so no order
    /// within one object is promised; callers get "last wins" only across lines, by
    /// overwriting with each line's match (Codex logs one `rate_limits` per line).
    public static func find(key: String, in json: Any) -> Any? {
        var result: Any?
        walk(json) { k, v in
            if k == key { result = v; return true }
            return false
        }
        return result
    }

    /// Visits every (key, value) pair depth-first, dictionary keys in sorted order, until
    /// `visit` returns true. Returns whether the walk was stopped.
    @discardableResult
    static func walk(_ json: Any, _ visit: (String, Any) -> Bool) -> Bool {
        if let dict = json as? [String: Any] {
            for key in dict.keys.sorted() {
                let value = dict[key]!
                if visit(key, value) || walk(value, visit) { return true }
            }
        } else if let array = json as? [Any] {
            for element in array where walk(element, visit) { return true }
        }
        return false
    }
}
