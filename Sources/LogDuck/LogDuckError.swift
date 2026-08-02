import Foundation

/// Thrown when a request fails and ``LogDuckOptions/throwOnError`` is enabled.
///
/// When it is not (the default), the same value is passed to the configured
/// logger so the detail is still available.
public struct LogDuckError: Error, Sendable {
    public let message: String

    /// HTTP status, or `nil` when the request never got a response.
    public let status: Int?

    /// Raw response body, when there was one.
    public let body: String?

    /// Set on a 429: how long the server asked us to wait.
    ///
    /// Present so the application can queue the event and send it later rather
    /// than drop it — the client itself refuses to block for a full rate-limit
    /// window.
    public let retryAfter: TimeInterval?

    public init(
        _ message: String,
        status: Int? = nil,
        body: String? = nil,
        retryAfter: TimeInterval? = nil
    ) {
        self.message = message
        self.status = status
        self.body = body
        self.retryAfter = retryAfter
    }
}

extension LogDuckError: LocalizedError {
    public var errorDescription: String? { message }
}

extension LogDuckError: CustomStringConvertible {
    public var description: String {
        var parts = ["LogDuckError: \(message)"]
        if let status { parts.append("status: \(status)") }
        if let retryAfter { parts.append("retryAfter: \(retryAfter)s") }
        return parts.joined(separator: ", ")
    }
}
