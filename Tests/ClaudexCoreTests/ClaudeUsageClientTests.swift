import Foundation
import Testing
@testable import ClaudexCore

final class MockFetcher: HTTPFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [URLRequest] = []
    var statusCode: Int
    var body: Data
    var headers: [String: String]
    var error: Error?

    init(statusCode: Int = 200, body: String = ClaudeUsageDecodingTests.sample, headers: [String: String] = [:]) {
        self.statusCode = statusCode
        self.body = Data(body.utf8)
        self.headers = headers
    }

    var requests: [URLRequest] { lock.withLock { _requests } }

    func fetch(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { _requests.append(request) }
        if let error { throw error }
        let response = HTTPURLResponse(url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: headers)!
        return (body, response)
    }
}

struct MockTokenProvider: ClaudeTokenProviding {
    let token: ClaudeToken?
    func currentToken() async -> ClaudeToken? { token }
}

/// Token provider that suspends, so concurrent polls interleave across the await.
struct SlowTokenProvider: ClaudeTokenProviding {
    let token: ClaudeToken?
    func currentToken() async -> ClaudeToken? {
        try? await Task.sleep(for: .milliseconds(50))
        return token
    }
}

/// A test clock that can be moved forward.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ start: Date) { current = start }
    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current += seconds } }
}

@Suite struct ClaudeUsageClientTests {
    let now = isoDate("2026-10-16T06:00:00.000Z")
    var validToken: ClaudeToken {
        ClaudeToken(accessToken: "test-token", expiresAt: now.addingTimeInterval(3600), subscriptionType: "max")
    }

    func makeClient(_ fetcher: MockFetcher, token: ClaudeToken?, clock: TestClock? = nil) -> ClaudeUsageClient {
        let clock = clock ?? TestClock(now)
        return ClaudeUsageClient(tokenProvider: MockTokenProvider(token: token), fetcher: fetcher, now: { clock.now })
    }

    @Test func successMapsWindowsAndPlan() async {
        let fetcher = MockFetcher()
        let client = makeClient(fetcher, token: validToken)
        let result = await client.poll()
        guard case let .ok(windows, plan) = result else {
            Issue.record("expected ok, got \(result)")
            return
        }
        #expect(windows.first?.usedPercent == 35)
        #expect(plan == "max")
        #expect(await client.nextDelay == 60)
    }

    @Test func requestCarriesBothHeaders() async throws {
        let fetcher = MockFetcher()
        _ = await makeClient(fetcher, token: validToken).poll()
        let request = try #require(fetcher.requests.first)
        #expect(request.url == ClaudeUsageClient.endpoint)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
        #expect(request.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20")
    }

    @Test func unauthorizedMeansNeedsSignIn() async {
        let fetcher = MockFetcher(statusCode: 401, body: "{}")
        let client = makeClient(fetcher, token: validToken)
        #expect(await client.poll() == .needsSignIn)
        #expect(await client.nextDelay == ClaudeUsageClient.signInDelay)
    }

    @Test func expiredTokenMakesNoRequest() async {
        let fetcher = MockFetcher()
        let expired = ClaudeToken(accessToken: "old", expiresAt: now.addingTimeInterval(-1), subscriptionType: nil)
        let client = makeClient(fetcher, token: expired)
        #expect(await client.poll() == .needsSignIn)
        #expect(fetcher.requests.isEmpty)
    }

    @Test func missingTokenMakesNoRequest() async {
        let fetcher = MockFetcher()
        let client = makeClient(fetcher, token: nil)
        #expect(await client.poll() == .needsSignIn)
        #expect(fetcher.requests.isEmpty)
    }

    @Test func rateLimitBacksOffDoublingAndCaps() async {
        let fetcher = MockFetcher(statusCode: 429, body: "{}")
        let clock = TestClock(now)
        let client = makeClient(fetcher, token: validToken, clock: clock)
        var delays: [TimeInterval] = []
        for _ in 0..<6 {
            _ = await client.poll()
            let delay = await client.nextDelay
            delays.append(delay)
            clock.advance(delay)
        }
        #expect(delays == [120, 240, 480, 900, 900, 900])
        #expect(delays.allSatisfy { $0 > 60 && $0 <= 900 })

        fetcher.statusCode = 200
        fetcher.body = Data(ClaudeUsageDecodingTests.sample.utf8)
        _ = await client.poll()
        #expect(await client.nextDelay == 60)
    }

    @Test func retryAfterIsHonoured() async {
        let fetcher = MockFetcher(statusCode: 429, body: "{}", headers: ["Retry-After": "600"])
        let client = makeClient(fetcher, token: validToken)
        #expect(await client.poll() == .rateLimited(retryAfter: 600))
        #expect(await client.nextDelay == 600)
    }

    @Test func retryAfterAcceptsHTTPDateAndIsClamped() async {
        // HTTP-date form, measured against the injected clock (now = 06:00:00 GMT).
        #expect(ClaudeUsageClient.parseRetryAfter("Fri, 16 Oct 2026 06:05:00 GMT", now: now) == 300)
        #expect(ClaudeUsageClient.parseRetryAfter("Fri, 16 Oct 2026 08:00:00 GMT", now: now) == 900)
        #expect(ClaudeUsageClient.parseRetryAfter("Fri, 16 Oct 2026 05:00:00 GMT", now: now) == 60)
        // Delta-seconds form, clamped to [60, 900].
        #expect(ClaudeUsageClient.parseRetryAfter("120", now: now) == 120)
        #expect(ClaudeUsageClient.parseRetryAfter("5", now: now) == 60)
        #expect(ClaudeUsageClient.parseRetryAfter("99999", now: now) == 900)
        #expect(ClaudeUsageClient.parseRetryAfter("soon", now: now) == nil)

        let fetcher = MockFetcher(statusCode: 429, body: "{}", headers: ["Retry-After": "Fri, 16 Oct 2026 06:10:00 GMT"])
        let client = makeClient(fetcher, token: validToken)
        #expect(await client.poll() == .rateLimited(retryAfter: 600))
        #expect(await client.nextDelay == 600)
    }

    @Test func retryAfterDeadlineBlocksEarlyPolls() async {
        let fetcher = MockFetcher(statusCode: 429, body: "{}", headers: ["Retry-After": "600"])
        let clock = TestClock(now)
        let client = makeClient(fetcher, token: validToken, clock: clock)
        #expect(await client.poll() == .rateLimited(retryAfter: 600))
        #expect(fetcher.requests.count == 1)
        fetcher.statusCode = 200
        fetcher.body = Data(ClaudeUsageDecodingTests.sample.utf8)

        // Past the 60s spacing but before Retry-After: a manual refresh sends nothing.
        clock.advance(61)
        #expect(await client.poll() == .throttled(retryIn: 539))
        #expect(fetcher.requests.count == 1)

        clock.advance(540)
        guard case .ok = await client.poll() else {
            Issue.record("expected a request after the Retry-After deadline")
            return
        }
        #expect(fetcher.requests.count == 2)
    }

    @Test func signInWaitBlocksEarlyPolls() async {
        let fetcher = MockFetcher(statusCode: 401, body: "{}")
        let clock = TestClock(now)
        let client = makeClient(fetcher, token: validToken, clock: clock)
        #expect(await client.poll() == .needsSignIn)
        clock.advance(61)
        #expect(await client.poll() == .throttled(retryIn: 239))
        #expect(fetcher.requests.count == 1)
        clock.advance(240)
        _ = await client.poll()
        #expect(fetcher.requests.count == 2)
    }

    @Test func concurrentPollsSendAtMostOneRequest() async {
        let fetcher = MockFetcher()
        let fixedNow = now
        let client = ClaudeUsageClient(tokenProvider: SlowTokenProvider(token: validToken), fetcher: fetcher,
                                       now: { fixedNow })
        async let a = client.poll()
        async let b = client.poll()
        let results = await [a, b]
        #expect(fetcher.requests.count == 1)
        #expect(results.filter { if case .ok = $0 { true } else { false } }.count == 1)
        #expect(results.filter { if case .throttled = $0 { true } else { false } }.count == 1)
    }

    @Test func pollWithinMinimumSpacingSendsNoRequest() async {
        let fetcher = MockFetcher()
        let clock = TestClock(now)
        let client = makeClient(fetcher, token: validToken, clock: clock)
        _ = await client.poll()
        #expect(fetcher.requests.count == 1)
        clock.advance(59)
        #expect(await client.poll() == .throttled(retryIn: 1))
        #expect(fetcher.requests.count == 1)
        clock.advance(1)
        _ = await client.poll()
        #expect(fetcher.requests.count == 2)
    }

    @Test func cancelledPollSendsNoRequest() async {
        let fetcher = MockFetcher()
        let fixedNow = now
        let client = ClaudeUsageClient(tokenProvider: SlowTokenProvider(token: validToken), fetcher: fetcher,
                                       now: { fixedNow })
        let task = Task { await client.poll() }
        task.cancel()
        _ = await task.value
        #expect(fetcher.requests.isEmpty)
    }

    @Test func networkErrorBacksOffNeverBelowMinimum() async {
        let fetcher = MockFetcher()
        fetcher.error = URLError(.notConnectedToInternet)
        let client = makeClient(fetcher, token: validToken)
        #expect(await client.poll() == .failed)
        #expect(await client.nextDelay >= 60)
        #expect(await client.nextDelay == 120)
    }

    @Test func keychainJSONParsesWithoutLeakingInDescription() throws {
        let json = #"{"claudeAiOauth":{"accessToken":"sk-secret","refreshToken":"r","expiresAt":1792000000000,"subscriptionType":"max"}}"#
        let token = try #require(ClaudeToken.parse(keychainJSON: Data(json.utf8)))
        #expect(token.accessToken == "sk-secret")
        #expect(token.subscriptionType == "max")
        #expect(token.expiresAt == Date(timeIntervalSince1970: 1_792_000_000))
        #expect(!"\(token)".contains("sk-secret"))
        #expect(ClaudeToken.parse(keychainJSON: Data("not json".utf8)) == nil)
    }
}
