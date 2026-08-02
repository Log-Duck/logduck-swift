import XCTest

@testable import LogDuck

/// The retry rules, tested without any networking.
final class RetryPolicyTests: XCTestCase {

    private func decide(
        _ status: Int,
        attempt: Int = 1,
        retryAfter: String? = nil,
        cap: TimeInterval = 10
    ) -> RetryDecision {
        RetryPolicy.decide(
            status: status,
            retryAfterHeader: retryAfter,
            body: "",
            attempt: attempt,
            maxAttempts: 2,
            maxRetryDelay: cap
        )
    }

    func test2xxSucceeds() {
        XCTAssertEqual(decide(200), .succeed)
        XCTAssertEqual(decide(204), .succeed)
    }

    func test5xxRetriesWhileAttemptsRemain() {
        guard case .retry = decide(503, attempt: 1) else {
            return XCTFail("a 503 on the first attempt should retry")
        }
    }

    func test5xxFailsOnceAttemptsRunOut() {
        guard case .fail = decide(503, attempt: 2) else {
            return XCTFail("a 503 on the last attempt should fail")
        }
    }

    func test4xxNeverRetries() {
        // It will fail identically the second time; retrying only doubles the load.
        for status in [400, 401, 403, 404, 422] {
            guard case .fail = decide(status, attempt: 1) else {
                return XCTFail("\(status) should not retry")
            }
        }
    }

    func test429RetriesWhenTheWaitIsWithinTheCap() {
        guard case let .retry(delay, _) = decide(429, retryAfter: "5", cap: 10) else {
            return XCTFail("a 5s wait under a 10s cap should retry")
        }
        XCTAssertEqual(delay, 5)
    }

    func test429GivesUpWhenTheWaitExceedsTheCap() {
        // The server rate-limits in one-minute windows. Blocking a caller for a
        // full window is worse than dropping the event, so the failure carries
        // retryAfter and lets the application queue it instead.
        guard case let .fail(error, _) = decide(429, retryAfter: "45", cap: 10) else {
            return XCTFail("a 45s wait over a 10s cap should fail")
        }
        XCTAssertEqual(error.retryAfter, 45)
    }

    func testMissingRetryAfterAssumesAFullWindow() {
        XCTAssertEqual(RetryPolicy.parseRetryAfter(nil), 60)
        XCTAssertEqual(RetryPolicy.parseRetryAfter(""), 60)
    }

    func testUnparseableRetryAfterAssumesAFullWindow() {
        // Anything else would risk rounding down to zero and hammering a server
        // that just asked us to back off.
        XCTAssertEqual(RetryPolicy.parseRetryAfter("soon"), 60)
    }

    func testRetryAfterAcceptsDeltaSeconds() {
        XCTAssertEqual(RetryPolicy.parseRetryAfter("30"), 30)
    }

    func testRetryAfterAcceptsAnHTTPDate() {
        // The spec allows either form. Treating the date form as unparseable
        // would fall back to a full minute and delay events needlessly.
        let now = Date(timeIntervalSince1970: 1_785_661_200)  // 2026-08-02T09:00:00Z

        let wait = RetryPolicy.parseRetryAfter("Sun, 02 Aug 2026 09:00:45 GMT", now: now)

        XCTAssertEqual(wait, 45, accuracy: 0.001)
    }

    func testARetryAfterInThePastIsClampedToZero() {
        let now = Date(timeIntervalSince1970: 1_785_661_200)

        XCTAssertEqual(RetryPolicy.parseRetryAfter("Sun, 02 Aug 2026 08:59:30 GMT", now: now), 0)
    }
}
