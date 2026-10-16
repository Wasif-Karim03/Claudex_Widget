import ClaudexCore
import Foundation

/// Parse caches carried between local scans so unchanged logs are never re-read.
struct LocalCache: Sendable {
    var claudeModels = ParseCache<ClaudeSessionReader.Parsed>()
    var codexParsed = ParseCache<CodexParsed>()
}

struct LocalScanResult: Sendable {
    var claude: ClaudeSessionReader.Scan
    var codex: CodexSessionReader.Scan
    var cache: LocalCache
}

/// Stat-only discovery of every Claude/Codex session log, then tail parsing of just the
/// live ones (and the newest). Runs off the main actor.
struct LocalScanner: Sendable {
    let claudeReader = ClaudeSessionReader()
    let codexReader = CodexSessionReader()
    let projectNames = ProjectNameCache()

    func scan(previous: LocalCache, now: Date) -> LocalScanResult {
        var cache = previous
        let names = projectNames
        let claude = claudeReader.scan(now: now, cache: &cache.claudeModels, projectName: { names.name(for: $0) })
        let codex = codexReader.scan(now: now, cache: &cache.codexParsed)
        return LocalScanResult(claude: claude, codex: codex, cache: cache)
    }

    /// Today's token tally. Kept apart from `scan` because the day's first pass reads
    /// whole logs, and live sessions shouldn't wait on it.
    func tally(_ previous: TokenTally, now: Date) -> TokenTally {
        var tally = previous
        tally.update(claudeFiles: claudeReader.sessionFiles(projectName: { $0 }), codexFiles: codexReader.allRollouts(), now: now)
        return tally
    }
}
