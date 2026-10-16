import Foundation

/// Read-only view of Claude Code's local transcripts under `~/.claude/projects`.
public struct ClaudeSessionReader: Sendable {
    public struct Result: Sendable, Equatable {
        public let file: URL
        public let modified: Date
        public let model: String?
    }

    public let projectsDir: URL

    public init(projectsDir: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/projects", isDirectory: true)) {
        self.projectsDir = projectsDir
    }

    /// Newest `*.jsonl` exactly one level below the project subdirectories (stat only).
    public func newestTranscript(fileManager: FileManager = .default) -> (url: URL, modified: Date)? {
        guard let projects = try? fileManager.contentsOfDirectory(
            at: projectsDir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return nil }
        var best: (url: URL, modified: Date)?
        for dir in projects where (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            guard let candidate = JSONLTail.newestFile(in: dir, matching: { $0.hasSuffix(".jsonl") }, fileManager: fileManager)
            else { continue }
            if best == nil || candidate.modified > best!.modified { best = candidate }
        }
        return best
    }

    /// Parses the tail of a transcript.
    public func read(file: URL, modified: Date, maxBytes: Int = 65_536) -> Result {
        Result(file: file, modified: modified, model: Self.lastModel(fromLines: JSONLTail.lines(of: file, maxBytes: maxBytes)))
    }

    /// What Claudex needs from a transcript's tail.
    public struct Parsed: Sendable, Equatable {
        public var model: String?
        /// Working directory recorded on the transcript's lines.
        public var cwd: String?
        /// File size when parsed; a smaller size later means the file was replaced.
        public var fileSize: Int? = nil
    }

    public static func parse(lines: [String]) -> Parsed {
        Parsed(model: lastModel(fromLines: lines), cwd: lastCwd(fromLines: lines))
    }

    /// Parses a transcript's tail. Model and cwd come from the tail when it has them; else
    /// what `previous` (this file's last parse) observed is kept. A file that shrank was
    /// replaced or truncated, so nothing is carried over from before.
    public static func parseFile(_ url: URL, size: Int?, maxBytes: Int = 65_536, previous: Parsed? = nil) -> Parsed {
        var parsed = parse(lines: JSONLTail.lines(of: url, maxBytes: maxBytes))
        parsed.fileSize = size
        var carried = previous
        if let before = previous?.fileSize, let size, size < before { carried = nil }
        if parsed.model == nil { parsed.model = carried?.model }
        if parsed.cwd == nil { parsed.cwd = carried?.cwd }
        return parsed
    }

    /// The most recent `cwd` recorded on any line.
    public static func lastCwd(fromLines lines: [String]) -> String? {
        for line in lines.reversed() {
            guard let object = JSONLTail.object(from: line) as? [String: Any],
                  let cwd = object["cwd"] as? String, !cwd.isEmpty else { continue }
            return cwd
        }
        return nil
    }

    /// Walks backwards to the last assistant message with a real model id.
    public static func lastModel(fromLines lines: [String]) -> String? {
        for line in lines.reversed() {
            guard let object = JSONLTail.object(from: line) as? [String: Any],
                  object["type"] as? String == "assistant",
                  let message = object["message"] as? [String: Any],
                  let model = message["model"] as? String,
                  !model.isEmpty, model != "<synthetic>" else { continue }
            return model
        }
        return nil
    }

    /// Every transcript, stat only: `<project>/*.jsonl` plus subagent logs at
    /// `<project>/<session>/subagents/agent-*.jsonl`.
    public func sessionFiles(
        projectName: (String) -> String = { ProjectName.decodeClaudeProjectDir($0) },
        fileManager: FileManager = .default
    ) -> [SessionFile] {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey, .isDirectoryKey, .fileSizeKey]
        func list(_ dir: URL) -> [(url: URL, values: URLResourceValues)] {
            let items = (try? fileManager.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])) ?? []
            return items.compactMap { url in (try? url.resourceValues(forKeys: keys)).map { (url, $0) } }
        }

        var files: [SessionFile] = []
        for project in list(projectsDir) where project.values.isDirectory == true {
            let name = projectName(project.url.lastPathComponent)
            for item in list(project.url) {
                if item.values.isRegularFile == true, item.url.pathExtension == "jsonl",
                   let modified = item.values.contentModificationDate {
                    files.append(SessionFile(url: item.url, modified: modified, project: name, isSubagent: false,
                                             size: item.values.fileSize))
                } else if item.values.isDirectory == true {
                    for agent in list(item.url.appendingPathComponent("subagents", isDirectory: true))
                    where agent.values.isRegularFile == true
                        && agent.url.lastPathComponent.hasPrefix("agent-")
                        && agent.url.pathExtension == "jsonl" {
                        guard let modified = agent.values.contentModificationDate else { continue }
                        files.append(SessionFile(url: agent.url, modified: modified, project: name, isSubagent: true,
                                                 size: agent.values.fileSize))
                    }
                }
            }
        }
        return files
    }

    public struct Scan: Sendable, Equatable {
        public var live: [LiveSession]
        /// Model of the newest transcript (the most recently active session); nil when it
        /// never recorded one, never another session's.
        public var headlineModel: String?
        public var lastActivity: Date?
    }

    /// Stat every transcript, then parse only the tails of the live ones and the newest.
    public func scan(
        now: Date,
        cache: inout ParseCache<Parsed>,
        projectName: (String) -> String = { ProjectName.decodeClaudeProjectDir($0) },
        maxBytes: Int = 65_536
    ) -> Scan {
        let files = sessionFiles(projectName: projectName)
        let newest = files.max { $0.modified < $1.modified }
        let liveFiles = LiveSelection.select(files, now: now)
        func parsed(_ file: SessionFile) -> Parsed {
            cache.value(for: file.url, modified: file.modified) { previous in
                Self.parseFile(file.url, size: file.size, maxBytes: maxBytes, previous: previous)
            }
        }
        let live = liveFiles.map { file -> LiveSession in
            let p = parsed(file)
            // The recorded cwd is exact; the decoded directory name is the fallback.
            return LiveSession(id: file.url.path, model: p.model,
                               project: ProjectName.lastComponent(ofPath: p.cwd) ?? file.project,
                               isSubagent: file.isSubagent, modified: file.modified)
        }
        let headline = newest.flatMap { parsed($0).model }
        cache.retain(paths: Set(liveFiles.map(\.url.path) + (newest.map { [$0.url.path] } ?? [])))
        return Scan(live: live, headlineModel: headline, lastActivity: newest?.modified)
    }

    public static func isActive(mtime: Date?, now: Date) -> Bool {
        JSONLTail.isActive(mtime: mtime, now: now)
    }
}
