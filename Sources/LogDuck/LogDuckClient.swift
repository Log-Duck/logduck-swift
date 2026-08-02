import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// The version reported in the `User-Agent` header. Kept in step with the git
/// tag by the release workflow, which fails if the two disagree.
let logDuckSDKVersion = "1.0.0"

/// How the client performs a request. Injectable so tests need no network.
public protocol LogDuckTransport: Sendable {
    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// Sends events to LogDuck.
///
/// ```swift
/// let logduck = LogDuckClient(options: .init(apiKey: "ld_...", source: "ios-app"))
/// try? await logduck.send(LogDuckEvent(type: "user.signup", subject: "user_42"))
/// ```
///
/// One instance is enough for a process — it holds no per-request state.
public final class LogDuckClient: Sendable {
    private let options: LogDuckOptions
    private let transport: LogDuckTransport
    private let logger: LogDuckLogger

    public init(
        options: LogDuckOptions,
        transport: LogDuckTransport? = nil,
        logger: LogDuckLogger = PrintLogger()
    ) {
        self.options = options
        self.transport = transport ?? URLSessionTransport(timeout: options.timeout)
        self.logger = logger

        if options.apiKey.isEmpty {
            logger.warn("API key is not configured - all requests will fail")
        }
        if options.source.isEmpty {
            logger.warn("source is not configured - all requests will fail")
        }
    }

    // MARK: - Configuration

    /// Checks the configuration without sending anything.
    ///
    /// Returns `false` and logs a warning for each problem, which makes it
    /// useful as a startup assertion.
    @discardableResult
    public func validateConfiguration() -> Bool {
        var valid = true

        if options.apiKey.isEmpty {
            logger.warn("validation failed: API key is not configured")
            valid = false
        } else if !options.apiKey.hasPrefix("ld_") {
            logger.warn("validation failed: API key must start with 'ld_'")
            valid = false
        }

        if options.source.isEmpty {
            logger.warn("validation failed: source is not configured")
            valid = false
        } else if options.source.count > Limits.source {
            logger.warn("validation failed: source exceeds \(Limits.source) characters")
            valid = false
        }

        return valid
    }

    // MARK: - Sending

    /// Sends one event.
    ///
    /// Returns the created event, or `nil` when the send failed and
    /// ``LogDuckOptions/throwOnError`` is off (the default). Throws only when
    /// that option is on.
    @discardableResult
    public func send(_ event: LogDuckEvent) async throws -> LogDuckResponse? {
        if let problem = validate(event) {
            return try fail(LogDuckError(problem, status: 400), "validation failed: \(problem)")
        }

        let request: URLRequest
        do {
            // One key for the whole call, reused across retries: that is what
            // makes a retry safe, since the server deduplicates on it.
            request = try buildRequest(for: event, idempotencyKey: Self.idempotencyKey())
        } catch {
            return try fail(
                LogDuckError("Failed to encode event: \(error)"),
                "event failed: could not encode payload"
            )
        }

        let maxAttempts = options.retryEnabled ? 2 : 1

        for attempt in 1...maxAttempts {
            let decision: RetryDecision
            var payload: Data?

            do {
                let (data, response) = try await transport.perform(request)
                payload = data
                decision = RetryPolicy.decide(
                    status: response.statusCode,
                    retryAfterHeader: retryAfterHeader(from: response),
                    body: String(data: data, encoding: .utf8) ?? "",
                    attempt: attempt,
                    maxAttempts: maxAttempts,
                    maxRetryDelay: options.maxRetryDelay
                )
            } catch {
                decision = RetryPolicy.decideTransportFailure(
                    error: error,
                    attempt: attempt,
                    maxAttempts: maxAttempts
                )
            }

            switch decision {
            case .succeed:
                return try decode(payload ?? Data())

            case let .retry(delay, reason):
                logger.warn(reason)
                if delay > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
                continue

            case let .fail(error, warning):
                return try fail(error, warning)
            }
        }

        return nil
    }

    // MARK: - Request construction

    private enum Limits {
        static let type = 100
        static let source = 200
        static let subject = 500
        static let sessionId = 256
        static let emoji = 10
    }

    private func validate(_ event: LogDuckEvent) -> String? {
        if event.type.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "type is required"
        }
        if event.type.count > Limits.type { return "type exceeds \(Limits.type) characters" }
        if options.source.isEmpty { return "source is not configured" }
        if options.source.count > Limits.source {
            return "source exceeds \(Limits.source) characters"
        }
        if let subject = event.subject, subject.count > Limits.subject {
            return "subject exceeds \(Limits.subject) characters"
        }
        if let sessionId = event.sessionId, sessionId.count > Limits.sessionId {
            return "sessionId exceeds \(Limits.sessionId) characters"
        }
        if let emoji = event.emoji, emoji.count > Limits.emoji {
            return "emoji exceeds \(Limits.emoji) characters"
        }
        return nil
    }

    private func buildRequest(for event: LogDuckEvent, idempotencyKey: String) throws -> URLRequest {
        var request = URLRequest(url: options.baseURL.appendingPathComponent("v1/events"))
        request.httpMethod = "POST"
        request.timeoutInterval = options.timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(options.apiKey, forHTTPHeaderField: "X-API-Key")
        request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        request.setValue("LogDuck-Swift/\(logDuckSDKVersion)", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONEncoder().encode(Payload(event: event, source: options.source))
        return request
    }

    /// The wire payload. Absent fields are omitted rather than sent as null, so
    /// it stays honest about what the caller actually set — which `JSONEncoder`
    /// does for `nil` optionals by default.
    private struct Payload: Encodable {
        let type: String
        let source: String
        let subject: String?
        let sessionId: String?
        let time: String?
        let data: [String: JSONValue]?
        let emoji: String?

        init(event: LogDuckEvent, source: String) {
            self.type = event.type
            self.source = source
            self.subject = event.subject
            self.sessionId = event.sessionId
            self.time = event.time.map(iso8601String(from:))
            self.data = event.data
            self.emoji = event.emoji
        }
    }

    /// The server requires 16-36 characters of `[A-Za-z0-9_-]`. A UUID is 36
    /// with hyphens, so it fits exactly.
    static func idempotencyKey() -> String {
        UUID().uuidString
    }

    private func retryAfterHeader(from response: HTTPURLResponse) -> String? {
        // allHeaderFields is case-sensitive on Linux, where the convenience
        // accessor that handles this does not exist.
        #if canImport(FoundationNetworking)
            for (key, value) in response.allHeaderFields {
                if (key as? String)?.lowercased() == "retry-after" { return value as? String }
            }
            return nil
        #else
            return response.value(forHTTPHeaderField: "Retry-After")
        #endif
    }

    // MARK: - Outcomes

    private func decode(_ data: Data) throws -> LogDuckResponse? {
        do {
            return try JSONDecoder().decode(LogDuckResponse.self, from: data)
        } catch {
            return try fail(
                LogDuckError("Failed to decode response: \(error)", status: 200),
                "event failed: could not decode response"
            )
        }
    }

    /// Throw or warn-and-return-nil, depending on `throwOnError`.
    private func fail(_ error: LogDuckError, _ warning: String) throws -> LogDuckResponse? {
        if options.throwOnError { throw error }
        logger.warn(warning)
        return nil
    }
}

/// The default transport.
///
/// Built on `dataTask` rather than `URLSession.data(for:)` because the latter
/// needs iOS 15 / macOS 12, and this package supports iOS 13.
public struct URLSessionTransport: LogDuckTransport {
    private let session: URLSession

    public init(timeout: TimeInterval = 30) {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = timeout
        self.session = URLSession(configuration: configuration)
    }

    public init(session: URLSession) {
        self.session = session
    }

    public func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            let task = session.dataTask(with: request) { data, response, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let http = response as? HTTPURLResponse else {
                    continuation.resume(
                        throwing: LogDuckError("Response was not HTTP")
                    )
                    return
                }
                continuation.resume(returning: (data ?? Data(), http))
            }
            task.resume()
        }
    }
}

/// Built per call rather than cached in a global.
///
/// `ISO8601DateFormatter` is a class with mutable state, so a shared instance
/// is not `Sendable` — an error in the Swift 6 language mode, and a real data
/// race if two threads format at once. This runs only when the caller sets an
/// explicit `time`, which is the uncommon case, and costs nothing next to the
/// HTTP request that follows it.
private func iso8601String(from date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
}
