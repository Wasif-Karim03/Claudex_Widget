import Foundation

public struct ClaudeToken: Sendable, Equatable {
    public let accessToken: String
    public let expiresAt: Date?
    public let subscriptionType: String?

    public init(accessToken: String, expiresAt: Date?, subscriptionType: String?) {
        self.accessToken = accessToken
        self.expiresAt = expiresAt
        self.subscriptionType = subscriptionType
    }

    /// Parses the JSON stored by Claude Code in the keychain.
    public static func parse(keychainJSON data: Data) -> ClaudeToken? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let access = oauth["accessToken"] as? String, !access.isEmpty else { return nil }
        var expires: Date?
        if let ms = oauth["expiresAt"] as? Double, ms.isFinite {
            expires = Date(timeIntervalSince1970: ms / 1000)
        }
        let sub = (oauth["subscriptionType"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return ClaudeToken(accessToken: access, expiresAt: expires, subscriptionType: sub)
    }
}

extension ClaudeToken: CustomStringConvertible, CustomDebugStringConvertible {
    // Never let the secret leak through string interpolation or debugging output.
    public var description: String { "ClaudeToken(redacted)" }
    public var debugDescription: String { description }
}

public protocol ClaudeTokenProviding: Sendable {
    func currentToken() async -> ClaudeToken?
}

/// Reads the Claude Code OAuth credentials with `/usr/bin/security`. Nothing is cached,
/// stored or logged; stderr is discarded.
public struct KeychainCLITokenProvider: ClaudeTokenProviding {
    public let service: String
    public let timeout: TimeInterval

    public init(service: String = "Claude Code-credentials", timeout: TimeInterval = 5) {
        self.service = service
        self.timeout = timeout
    }

    public func currentToken() async -> ClaudeToken? {
        let service = self.service
        let timeout = self.timeout
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: Self.readSync(service: service, timeout: timeout))
            }
        }
    }

    private static func readSync(service: String, timeout: TimeInterval) -> ClaudeToken? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", service, "-w"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do {
            try process.run()
        } catch {
            return nil
        }
        // Read before waiting so a large payload cannot fill the pipe and deadlock. The
        // reader hands its result over through a locked box, never a shared variable.
        let reader = DispatchQueue(label: "claudex.keychain.read")
        let output = OutputBox()
        let readDone = DispatchSemaphore(value: 0)
        reader.async {
            output.set(stdout.fileHandleForReading.readDataToEndOfFile())
            readDone.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            return nil
        }
        guard readDone.wait(timeout: .now() + 1) == .success,
              process.terminationStatus == 0,
              let data = output.take() else { return nil }
        let trimmed = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return ClaudeToken.parse(keychainJSON: Data(trimmed.utf8))
    }
}

/// Lock-protected hand-off of the keychain reader's output between threads.
private final class OutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?

    func set(_ value: Data) { lock.withLock { data = value } }
    func take() -> Data? { lock.withLock { defer { data = nil }; return data } }
}

public protocol HTTPFetching: Sendable {
    func fetch(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionFetcher: HTTPFetching {
    private let session: URLSession

    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.timeoutIntervalForRequest = 20
        session = URLSession(configuration: config)
    }

    public func fetch(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

public enum ClaudeUsageResult: Sendable, Equatable {
    case ok(windows: [UsageWindow], plan: String?)
    case needsSignIn
    case rateLimited(retryAfter: TimeInterval?)
    case failed
    /// No request was sent: one is already in flight, `nextAllowedAt` has not been
    /// reached, or the polling task was cancelled. Try again after `retryIn`.
    case throttled(retryIn: TimeInterval)
}

public actor ClaudeUsageClient {
    public static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    public static let minDelay: TimeInterval = 60
    public static let maxDelay: TimeInterval = 900
    public static let signInDelay: TimeInterval = 300

    private let tokenProvider: any ClaudeTokenProviding
    private let fetcher: any HTTPFetching
    private let now: @Sendable () -> Date

    /// Seconds to wait before the next poll; never below `minDelay`.
    public private(set) var nextDelay: TimeInterval = ClaudeUsageClient.minDelay
    /// When the last HTTP request was sent; requests are never closer than `minDelay`.
    public private(set) var lastRequestAt: Date?
    /// No request is sent before this: the later of `lastRequestAt + minDelay`, the
    /// Retry-After/backoff deadline and the sign-in wait. Manual refreshes obey it too.
    public private(set) var nextAllowedAt: Date?
    /// Single-flight guard: true from the start of a poll until it finishes.
    private var inFlight = false

    public init(
        tokenProvider: any ClaudeTokenProviding = KeychainCLITokenProvider(),
        fetcher: any HTTPFetching = URLSessionFetcher(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.tokenProvider = tokenProvider
        self.fetcher = fetcher
        self.now = now
    }

    /// Seconds until a request may be sent again (0 when allowed now).
    public func timeUntilAllowed() -> TimeInterval {
        guard let nextAllowedAt else { return 0 }
        return max(0, nextAllowedAt.timeIntervalSince(now()))
    }

    /// Sets `nextDelay` and moves `nextAllowedAt` to `delay` from now, never earlier than
    /// `minDelay` after the last request.
    private func schedule(_ delay: TimeInterval) {
        nextDelay = delay
        var deadline = now().addingTimeInterval(delay)
        if let lastRequestAt { deadline = max(deadline, lastRequestAt.addingTimeInterval(Self.minDelay)) }
        nextAllowedAt = deadline
    }

    public func poll() async -> ClaudeUsageResult {
        // Spacing and single-flight are enforced here, at the only place requests are
        // sent, so concurrent or early callers can never cause an extra request.
        if inFlight { return .throttled(retryIn: Self.minDelay) }
        if timeUntilAllowed() > 0 { return .throttled(retryIn: timeUntilAllowed()) }
        inFlight = true
        defer { inFlight = false }

        // Read the token fresh every time; it is never stored on the actor.
        let fetchedToken = await tokenProvider.currentToken()
        // Re-check after the await: actor state may have changed while suspended.
        if Task.isCancelled { return .throttled(retryIn: 0) }
        if timeUntilAllowed() > 0 { return .throttled(retryIn: timeUntilAllowed()) }
        guard let token = fetchedToken else {
            schedule(Self.signInDelay)
            return .needsSignIn
        }
        if let expires = token.expiresAt, expires < now() {
            schedule(Self.signInDelay)
            return .needsSignIn
        }

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        lastRequestAt = now()
        nextAllowedAt = lastRequestAt?.addingTimeInterval(Self.minDelay)

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await fetcher.fetch(request)
        } catch {
            backOff(retryAfter: nil)
            return .failed
        }

        switch response.statusCode {
        case 200:
            guard let decoded = try? ClaudeUsageResponse.decode(data) else {
                backOff(retryAfter: nil)
                return .failed
            }
            schedule(Self.minDelay)
            return .ok(windows: decoded.toWindows(), plan: token.subscriptionType)
        case 401, 403:
            schedule(Self.signInDelay)
            return .needsSignIn
        case 429, 500...599:
            let retryAfter = response.value(forHTTPHeaderField: "Retry-After")
                .flatMap { Self.parseRetryAfter($0, now: now()) }
            backOff(retryAfter: retryAfter)
            return .rateLimited(retryAfter: retryAfter)
        default:
            backOff(retryAfter: nil)
            return .failed
        }
    }

    /// `Retry-After` as delta-seconds or an HTTP-date (RFC 9110), clamped to
    /// [`minDelay`, `maxDelay`]. Nil when the header is unparseable.
    public static func parseRetryAfter(_ value: String, now: Date) -> TimeInterval? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        var seconds: TimeInterval?
        if let delta = TimeInterval(trimmed), delta.isFinite {
            seconds = delta
        } else if let date = httpDate(trimmed) {
            seconds = date.timeIntervalSince(now)
        }
        return seconds.map { min(maxDelay, max(minDelay, $0)) }
    }

    private static func httpDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        // IMF-fixdate, then the obsolete RFC 850 and asctime forms.
        for format in ["EEE, dd MMM yyyy HH:mm:ss zzz", "EEEE, dd-MMM-yy HH:mm:ss zzz", "EEE MMM d HH:mm:ss yyyy"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }

    private func backOff(retryAfter: TimeInterval?) {
        var delay = min(nextDelay * 2, Self.maxDelay)
        if let retryAfter, retryAfter > delay { delay = min(retryAfter, Self.maxDelay) }
        schedule(max(Self.minDelay, delay))
    }
}
