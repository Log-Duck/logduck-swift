import Foundation

/// What to do about a response.
///
/// Kept apart from the client so the rules — what counts as retryable, how long
/// to wait, which error to surface — can be tested without any networking.
enum RetryDecision: Equatable {
    /// The response is a 2xx; the caller decodes the body.
    case succeed
    /// Wait, then send the same request again.
    case retry(delay: TimeInterval, reason: String)
    /// Give up.
    case fail(error: LogDuckError, warning: String)

    static func == (lhs: RetryDecision, rhs: RetryDecision) -> Bool {
        switch (lhs, rhs) {
        case (.succeed, .succeed):
            return true
        case let (.retry(l, _), .retry(r, _)):
            return l == r
        case let (.fail(l, _), .fail(r, _)):
            return l.status == r.status && l.retryAfter == r.retryAfter
        default:
            return false
        }
    }
}

enum RetryPolicy {
    /// Delay before retrying a 5xx or a network failure.
    static let transientRetryDelay: TimeInterval = 1

    /// The server rate-limits in fixed one-minute windows, so a missing or
    /// unparseable `Retry-After` cannot mean less than a full window. Assume
    /// the maximum rather than retrying immediately and adding load to a server
    /// that just asked us to back off.
    static let retryAfterFallback: TimeInterval = 60

    static func decide(
        status: Int,
        retryAfterHeader: String?,
        body: String,
        attempt: Int,
        maxAttempts: Int,
        maxRetryDelay: TimeInterval
    ) -> RetryDecision {
        if (200..<300).contains(status) {
            return .succeed
        }

        // 429 is the one 4xx worth retrying: the server tells us when its
        // window resets, and the unchanged Idempotency-Key makes it safe.
        if status == 429 {
            let retryAfter = parseRetryAfter(retryAfterHeader)

            if attempt < maxAttempts, retryAfter <= maxRetryDelay {
                return .retry(
                    delay: retryAfter,
                    reason: "rate limited, retrying in \(Int(retryAfter))s"
                )
            }

            // Out of attempts, or the wait is longer than a caller should be
            // blocked for. Surface retryAfter so the event can be queued.
            return .fail(
                error: LogDuckError(
                    "Rate limit exceeded. Retry after \(Int(retryAfter))s.",
                    status: status,
                    body: body,
                    retryAfter: retryAfter
                ),
                warning: "event dropped: rate limit exceeded, retry after \(Int(retryAfter))s"
            )
        }

        // Any other 4xx is our fault and will fail identically next time.
        if (400..<500).contains(status) {
            let message = clientErrorMessage(status)
            return .fail(
                error: LogDuckError(message, status: status, body: body),
                warning: "event failed: \(message)"
            )
        }

        if attempt < maxAttempts {
            return .retry(
                delay: transientRetryDelay,
                reason: "request failed with status \(status), retrying"
            )
        }

        return .fail(
            error: LogDuckError(
                "Request failed with status \(status) after \(maxAttempts) attempts",
                status: status,
                body: body
            ),
            warning: "event failed after \(maxAttempts) attempts"
        )
    }

    /// Classifies a network failure — no response ever arrived.
    static func decideTransportFailure(
        error: Error,
        attempt: Int,
        maxAttempts: Int
    ) -> RetryDecision {
        if attempt < maxAttempts {
            return .retry(
                delay: transientRetryDelay,
                reason: "request failed (\(error.localizedDescription)), retrying"
            )
        }

        return .fail(
            error: LogDuckError(
                "\(error.localizedDescription) (after \(maxAttempts) attempts)"
            ),
            warning: "event failed after \(maxAttempts) attempts"
        )
    }

    /// Seconds to wait, from either form the spec allows.
    ///
    /// `Retry-After` may be delta-seconds or an HTTP-date. Treating the date
    /// form as unparseable would fall back to a full minute and delay events
    /// that were only seconds from being sendable.
    static func parseRetryAfter(_ header: String?, now: Date = Date()) -> TimeInterval {
        guard let header = header?.trimmingCharacters(in: .whitespaces), !header.isEmpty else {
            return retryAfterFallback
        }

        if let seconds = TimeInterval(header) {
            return max(0, seconds)
        }

        if let date = httpDate(from: header) {
            return max(0, date.timeIntervalSince(now))
        }

        return retryAfterFallback
    }

    private static func clientErrorMessage(_ status: Int) -> String {
        switch status {
        case 400: return "Validation error"
        case 401: return "Invalid API key"
        case 403: return "API key expired or unauthorized"
        default: return "Request failed with status \(status)"
        }
    }
}

/// Parses RFC 1123, the only `Retry-After` date form worth supporting.
///
/// The fixed locale is load-bearing: on a device set to a non-Gregorian
/// calendar, the default locale reads the month name as gibberish and the
/// header silently degrades to the full-minute fallback.
///
/// Built per call rather than cached in a global, because `DateFormatter` is a
/// class with mutable state and a shared instance is not `Sendable`. This runs
/// only for a 429 that carries a date rather than a number, which is rare.
private func httpDate(from header: String) -> Date? {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "GMT")
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
    return formatter.date(from: header)
}
