import Foundation

/// One session log that is being written right now.
public struct LiveSession: Sendable, Equatable, Identifiable {
    /// The log file's path.
    public let id: String
    public let model: String?
    /// Short project name, e.g. "CLAUDEX WIDGET".
    public let project: String
    public let isSubagent: Bool
    public let modified: Date

    public init(id: String, model: String?, project: String, isSubagent: Bool, modified: Date) {
        self.id = id
        self.model = model
        self.project = project
        self.isSubagent = isSubagent
        self.modified = modified
    }
}

/// A discovered session log (stat only, nothing parsed yet).
public struct SessionFile: Sendable, Equatable {
    public let url: URL
    public let modified: Date
    public let project: String
    public let isSubagent: Bool
    /// Size in bytes, when the stat reported it.
    public let size: Int?

    public init(url: URL, modified: Date, project: String, isSubagent: Bool, size: Int? = nil) {
        self.url = url
        self.modified = modified
        self.project = project
        self.isSubagent = isSubagent
        self.size = size
    }
}

public enum LiveSelection {
    /// A log counts as live if it changed within this many seconds.
    public static let window: TimeInterval = 120

    /// Live files, most recently written first.
    public static func select(_ files: [SessionFile], now: Date, window: TimeInterval = window) -> [SessionFile] {
        files
            .filter { JSONLTail.isActive(mtime: $0.modified, now: now, window: window) }
            .sorted { $0.modified > $1.modified }
    }
}

/// Per-file parse results keyed by path, reused while a file's mtime is unchanged.
public struct ParseCache<Value: Sendable>: Sendable {
    struct Entry: Sendable {
        var modified: Date
        var value: Value
    }

    private var entries: [String: Entry] = [:]

    public init() {}

    public mutating func value(for url: URL, modified: Date, parse: () -> Value) -> Value {
        value(for: url, modified: modified) { (_: Value?) in parse() }
    }

    /// As above; on a reparse `parse` receives the file's previous value (nil the first
    /// time), so results can carry forward what earlier parses observed.
    public mutating func value(for url: URL, modified: Date, parse: (Value?) -> Value) -> Value {
        let previous = entries[url.path]
        if let previous, previous.modified == modified { return previous.value }
        let value = parse(previous?.value)
        entries[url.path] = Entry(modified: modified, value: value)
        return value
    }

    /// Drops entries for files no longer of interest.
    public mutating func retain(paths: Set<String>) {
        entries = entries.filter { paths.contains($0.key) }
    }

    public var count: Int { entries.count }
}

public enum ProjectName {
    /// Claude Code's directory encoding: every character that is not an ASCII letter or
    /// digit becomes "-".
    public static func encode(_ component: String) -> String {
        String(component.map { ($0.isASCII && ($0.isLetter || $0.isNumber)) ? $0 : "-" })
    }

    public typealias DirectoryLister = @Sendable (String) -> [String]?

    /// Lists real directories, but never privacy-protected ones (Desktop, Documents,
    /// Downloads, media folders, Library, iCloud, external volumes): listing those from an
    /// app bundle triggers a macOS folder-access prompt. Unlisted parts fall back to text.
    public static let fileSystemLister: DirectoryLister = { path in
        guard !isPrivacyProtected(path) else { return nil }
        return try? FileManager.default.contentsOfDirectory(atPath: path)
    }

    public static func isPrivacyProtected(_ path: String, home: String = NSHomeDirectory()) -> Bool {
        let standardized = (path as NSString).standardizingPath
        if standardized == "/Volumes" || standardized.hasPrefix("/Volumes/") { return true }
        let protected = ["Desktop", "Documents", "Downloads", "Library", "Pictures", "Movies", "Music", "Public"]
        return protected.contains { name in
            let dir = (home as NSString).appendingPathComponent(name)
            return standardized == dir || standardized.hasPrefix(dir + "/")
        }
    }

    /// Best-effort decode of a `~/.claude/projects` directory name back to the project's
    /// folder name, e.g. "-Users-me-Projects-CLAUDEX-WIDGET" -> "CLAUDEX WIDGET".
    /// Walks the real file system matching encoded names; whatever cannot be resolved is
    /// returned with dashes turned into spaces.
    public static func decodeClaudeProjectDir(_ name: String, list: DirectoryLister = fileSystemLister) -> String {
        guard name.hasPrefix("-") else { return name.replacingOccurrences(of: "-", with: " ") }
        var path = "/"
        var rest = Substring(name.dropFirst())
        var lastResolved: String?
        while !rest.isEmpty {
            guard let children = list(path) else { break }
            let ranked = children
                .map { (name: $0, encoded: encode($0)) }
                .filter { !$0.encoded.isEmpty }
                .sorted { $0.encoded.count > $1.encoded.count }
            var advanced = false
            for child in ranked {
                if rest == child.encoded { return child.name }
                if rest.hasPrefix(child.encoded + "-") {
                    path = (path as NSString).appendingPathComponent(child.name)
                    rest = rest.dropFirst(child.encoded.count + 1)
                    lastResolved = child.name
                    advanced = true
                    break
                }
            }
            if !advanced { break }
        }
        if rest.isEmpty { return lastResolved ?? name }
        let words = rest.split(separator: "-").joined(separator: " ")
        return words.isEmpty ? (lastResolved ?? name) : words
    }

    /// Last path component of a working directory, e.g. "/Users/me/app" -> "app".
    public static func lastComponent(ofPath path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        let last = (path as NSString).lastPathComponent
        return last.isEmpty || last == "/" ? nil : last
    }
}

/// Memoises decoded project names; directory names never change meaning, so each is
/// resolved against the file system once.
public final class ProjectNameCache: @unchecked Sendable {
    private let lock = NSLock()
    private var names: [String: String] = [:]
    private let list: ProjectName.DirectoryLister

    public init(list: @escaping ProjectName.DirectoryLister = ProjectName.fileSystemLister) {
        self.list = list
    }

    public func name(for directoryName: String) -> String {
        if let hit = lock.withLock({ names[directoryName] }) { return hit }
        let decoded = ProjectName.decodeClaudeProjectDir(directoryName, list: list)
        lock.withLock { names[directoryName] = decoded }
        return decoded
    }
}
