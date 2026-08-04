import XCTest

@testable import LogDuck

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// A transport that answers from a script instead of the network, and records
/// what it was asked to send.
final class FakeTransport: LogDuckTransport, @unchecked Sendable {
    struct Reply {
        let status: Int
        let body: String
        let headers: [String: String]
        let error: Error?

        static func ok() -> Reply {
            Reply(
                status: 200,
                body: #"{"success":true,"eventId":"evt_1","time":"2026-08-02T09:00:00.000Z"}"#,
                headers: [:],
                error: nil
            )
        }

        static func status(_ status: Int, headers: [String: String] = [:]) -> Reply {
            Reply(status: status, body: "{}", headers: headers, error: nil)
        }

        static func failure() -> Reply {
            Reply(
                status: 0,
                body: "",
                headers: [:],
                error: URLError(.notConnectedToInternet)
            )
        }
    }

    private let lock = NSLock()
    private var replies: [Reply]
    private(set) var requests: [URLRequest] = []

    init(_ replies: [Reply]) {
        self.replies = replies
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return requests.count
    }

    /// Synchronous on purpose: taking a lock inside an `async` function is an
    /// error in the Swift 6 language mode, because the lock could be held
    /// across a suspension point.
    private func nextReply(recording request: URLRequest) -> Reply {
        lock.lock()
        defer { lock.unlock() }
        requests.append(request)
        // The last scripted reply repeats, so a test asserting "never retries"
        // does not have to know how many attempts it is guarding against.
        return replies.count > 1 ? replies.removeFirst() : replies[0]
    }

    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let reply = nextReply(recording: request)

        if let error = reply.error { throw error }

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: reply.status,
            httpVersion: "HTTP/1.1",
            headerFields: reply.headers
        )!
        return (Data(reply.body.utf8), response)
    }
}

/// Discards warnings so the test log stays readable.
struct SilentLogger: LogDuckLogger {
    func warn(_ message: String) {}
}

final class LogDuckClientTests: XCTestCase {

    private func makeClient(
        _ transport: FakeTransport,
        throwOnError: Bool = false,
        retryEnabled: Bool = true,
        maxRetryDelay: TimeInterval = 0,
        source: String = "test-suite"
    ) -> LogDuckClient {
        LogDuckClient(
            options: LogDuckOptions(
                apiKey: "ld_test_key",
                source: source,
                throwOnError: throwOnError,
                retryEnabled: retryEnabled,
                // Zero by default so a rate-limit retry does not actually sleep.
                maxRetryDelay: maxRetryDelay
            ),
            transport: transport,
            logger: SilentLogger()
        )
    }

    private func body(of request: URLRequest) throws -> [String: Any] {
        let data = try XCTUnwrap(request.httpBody)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - The request it builds

    func testPostsToV1EventsWithAuthHeaders() async throws {
        let transport = FakeTransport([.ok()])
        let client = makeClient(transport)

        _ = try await client.send(LogDuckEvent(type: "user.signup"))

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.logduck.com/v1/events")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-API-Key"), "ld_test_key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
    }

    func testSendsAnIdempotencyKeyTheServerWillAccept() async throws {
        // The server enforces ^[a-zA-Z0-9_-]{16,36}$ and rejects the request
        // outright without it, so this is part of the contract, not a nicety.
        let transport = FakeTransport([.ok()])
        let client = makeClient(transport)

        _ = try await client.send(LogDuckEvent(type: "user.signup"))

        let key = try XCTUnwrap(
            transport.requests.first?.value(forHTTPHeaderField: "Idempotency-Key")
        )
        XCTAssertNotNil(
            key.range(of: "^[a-zA-Z0-9_-]{16,36}$", options: .regularExpression),
            "\(key) would be rejected by the server"
        )
    }

    func testSourceComesFromTheClientNotTheEvent() async throws {
        let transport = FakeTransport([.ok()])
        let client = makeClient(transport, source: "checkout-api")

        _ = try await client.send(LogDuckEvent(type: "order.placed"))

        let payload = try body(of: XCTUnwrap(transport.requests.first))
        XCTAssertEqual(payload["source"] as? String, "checkout-api")
    }

    func testOmitsAbsentFieldsRatherThanSendingNull() async throws {
        let transport = FakeTransport([.ok()])
        let client = makeClient(transport)

        _ = try await client.send(LogDuckEvent(type: "user.signup"))

        let payload = try body(of: XCTUnwrap(transport.requests.first))
        XCTAssertNil(payload["subject"])
        XCTAssertNil(payload["emoji"])
        XCTAssertNil(payload["time"])
        XCTAssertNil(payload["message"])
        XCTAssertNil(payload["sessionid"])
    }

    /// The wire names are the contract, and they are not the Swift property
    /// names. A CloudEvents extension attribute name must be lowercase
    /// alphanumeric, so `sessionId` goes out as `sessionid`. The server
    /// discards what it does not recognise rather than erroring, so getting
    /// this wrong loses the field silently - hence asserting the camelCase
    /// spelling is absent, not just that the lowercase one is present.
    func testSendsCloudEventsWireNames() async throws {
        let transport = FakeTransport([.ok()])
        let client = makeClient(transport)

        _ = try await client.send(
            LogDuckEvent(
                type: "order.placed",
                subject: "order_9127",
                sessionId: "sess_8f21c",
                message: "Order placed on the Pro plan"
            )
        )

        let payload = try body(of: XCTUnwrap(transport.requests.first))
        XCTAssertEqual(payload["sessionid"] as? String, "sess_8f21c")
        XCTAssertEqual(payload["message"] as? String, "Order placed on the Pro plan")
        XCTAssertNil(payload["sessionId"])
        XCTAssertNil(payload["metadata"])
    }

    func testRejectsAnOverlongMessage() async throws {
        let transport = FakeTransport([.ok()])
        let client = makeClient(transport)

        let result = try await client.send(
            LogDuckEvent(type: "order.placed", message: String(repeating: "x", count: 501))
        )

        XCTAssertNil(result)
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testEncodesStructuredData() async throws {
        let transport = FakeTransport([.ok()])
        let client = makeClient(transport)

        _ = try await client.send(
            LogDuckEvent(
                type: "order.placed",
                data: ["total": 4999, "currency": "NOK", "gift": false]
            )
        )

        let payload = try body(of: XCTUnwrap(transport.requests.first))
        let data = try XCTUnwrap(payload["data"] as? [String: Any])
        XCTAssertEqual(data["total"] as? Int, 4999)
        XCTAssertEqual(data["currency"] as? String, "NOK")
        XCTAssertEqual(data["gift"] as? Bool, false)
    }

    func testSerialisesTimeAsISO8601() async throws {
        let transport = FakeTransport([.ok()])
        let client = makeClient(transport)

        _ = try await client.send(
            LogDuckEvent(type: "user.signup", time: Date(timeIntervalSince1970: 1_785_661_200))
        )

        let payload = try body(of: XCTUnwrap(transport.requests.first))
        XCTAssertEqual(payload["time"] as? String, "2026-08-02T09:00:00.000Z")
    }

    func testReturnsTheDecodedResponse() async throws {
        let transport = FakeTransport([.ok()])
        let client = makeClient(transport)

        let response = try await client.send(LogDuckEvent(type: "user.signup"))

        XCTAssertEqual(response?.eventId, "evt_1")
        XCTAssertEqual(response?.success, true)
    }

    // MARK: - Validation

    func testRejectsAnEmptyTypeWithoutTouchingTheNetwork() async throws {
        let transport = FakeTransport([.ok()])
        let client = makeClient(transport)

        let response = try await client.send(LogDuckEvent(type: "   "))

        XCTAssertNil(response)
        XCTAssertEqual(transport.callCount, 0)
    }

    func testRejectsOverLongFields() async throws {
        let cases: [LogDuckEvent] = [
            LogDuckEvent(type: String(repeating: "a", count: 101)),
            LogDuckEvent(type: "ok", subject: String(repeating: "a", count: 501)),
            LogDuckEvent(type: "ok", sessionId: String(repeating: "a", count: 257)),
            LogDuckEvent(type: "ok", emoji: String(repeating: "a", count: 11)),
        ]

        for event in cases {
            let transport = FakeTransport([.ok()])
            let client = makeClient(transport)

            let response = try await client.send(event)
            XCTAssertNil(response)
            XCTAssertEqual(transport.callCount, 0, "\(event.type) should not reach the network")
        }
    }

    func testFlagsAnAPIKeyWithoutTheLdPrefix() {
        let client = LogDuckClient(
            options: LogDuckOptions(apiKey: "oops", source: "s"),
            transport: FakeTransport([.ok()]),
            logger: SilentLogger()
        )

        XCTAssertFalse(client.validateConfiguration())
    }

    func testAcceptsAWellFormedConfiguration() {
        XCTAssertTrue(makeClient(FakeTransport([.ok()])).validateConfiguration())
    }

    // MARK: - Failure handling

    func testReturnsNilInsteadOfThrowingByDefault() async throws {
        // A logging SDK must not take down the code it was meant to observe.
        let transport = FakeTransport([.status(401)])
        let client = makeClient(transport)

        let response = try await client.send(LogDuckEvent(type: "user.signup"))
        XCTAssertNil(response)
    }

    func testThrowsWhenThrowOnErrorIsSet() async {
        let transport = FakeTransport([.status(401)])
        let client = makeClient(transport, throwOnError: true)

        do {
            _ = try await client.send(LogDuckEvent(type: "user.signup"))
            XCTFail("expected a LogDuckError")
        } catch let error as LogDuckError {
            XCTAssertEqual(error.status, 401)
        } catch {
            XCTFail("expected a LogDuckError, got \(error)")
        }
    }

    func testDoesNotRetryA4xx() async throws {
        // A validation error will fail identically the second time; retrying it
        // only doubles the load.
        let transport = FakeTransport([.status(400)])
        let client = makeClient(transport)

        _ = try await client.send(LogDuckEvent(type: "user.signup"))

        XCTAssertEqual(transport.callCount, 1)
    }

    func testRetriesA5xxOnceAndSucceeds() async throws {
        let transport = FakeTransport([.status(503), .ok()])
        let client = makeClient(transport)

        let response = try await client.send(LogDuckEvent(type: "user.signup"))

        XCTAssertEqual(response?.success, true)
        XCTAssertEqual(transport.callCount, 2)
    }

    func testRetriesANetworkFailureOnce() async throws {
        let transport = FakeTransport([.failure(), .ok()])
        let client = makeClient(transport)

        let response = try await client.send(LogDuckEvent(type: "user.signup"))

        XCTAssertEqual(response?.success, true)
        XCTAssertEqual(transport.callCount, 2)
    }

    func testReusesTheSameIdempotencyKeyAcrossARetry() async throws {
        // This is what makes retrying safe: the server deduplicates on the key,
        // so a retry after a timeout cannot double-post the event.
        let transport = FakeTransport([.status(503), .ok()])
        let client = makeClient(transport)

        _ = try await client.send(LogDuckEvent(type: "user.signup"))

        XCTAssertEqual(transport.requests.count, 2)
        XCTAssertEqual(
            transport.requests[0].value(forHTTPHeaderField: "Idempotency-Key"),
            transport.requests[1].value(forHTTPHeaderField: "Idempotency-Key")
        )
    }

    func testSendsExactlyOnceWhenRetriesAreDisabled() async throws {
        let transport = FakeTransport([.status(503)])
        let client = makeClient(transport, retryEnabled: false)

        let response = try await client.send(LogDuckEvent(type: "user.signup"))
        XCTAssertNil(response)
        XCTAssertEqual(transport.callCount, 1)
    }

    // MARK: - Rate limits

    func testRetriesARateLimitWithinTheCap() async throws {
        let transport = FakeTransport([
            .status(429, headers: ["Retry-After": "0"]), .ok(),
        ])
        let client = makeClient(transport, maxRetryDelay: 10)

        let response = try await client.send(LogDuckEvent(type: "user.signup"))

        XCTAssertEqual(response?.success, true)
        XCTAssertEqual(transport.callCount, 2)
    }

    func testGivesUpImmediatelyWhenRetryAfterExceedsTheCap() async {
        // The server rate-limits in one-minute windows, so Retry-After can be
        // 60s. Blocking a caller that long is worse than dropping the event.
        let transport = FakeTransport([.status(429, headers: ["Retry-After": "45"])])
        let client = makeClient(transport, throwOnError: true, maxRetryDelay: 10)

        do {
            _ = try await client.send(LogDuckEvent(type: "user.signup"))
            XCTFail("expected a LogDuckError")
        } catch let error as LogDuckError {
            XCTAssertEqual(error.status, 429)
            XCTAssertEqual(error.retryAfter, 45)
            XCTAssertEqual(transport.callCount, 1)
        } catch {
            XCTFail("expected a LogDuckError, got \(error)")
        }
    }
}
