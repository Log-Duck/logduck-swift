import Foundation

/// Configuration for ``LogDuckClient``.
public struct LogDuckOptions: Sendable {
    /// Your LogDuck API key (required). Must start with `ld_`.
    public var apiKey: String

    /// Identifies the app or service sending events (required, max 200).
    /// Set once; it is attached to every event.
    public var source: String

    /// When false (the default) errors are logged and `send` returns `nil`.
    /// When true they are thrown as ``LogDuckError``.
    ///
    /// The default is deliberate: a logging SDK that throws can take down the
    /// code it was only meant to observe.
    public var throwOnError: Bool

    /// Retry once on transient failures — 5xx, network errors and rate limits.
    public var retryEnabled: Bool

    /// Longest the client will wait before retrying a rate-limited (429)
    /// request.
    ///
    /// The server rate-limits per API key in fixed one-minute windows, so its
    /// `Retry-After` can be as much as 60 seconds. Blocking a caller that long
    /// is rarely acceptable, so when `Retry-After` exceeds this cap the client
    /// gives up immediately. The failure carries ``LogDuckError/retryAfter`` so
    /// the application can queue the event instead of losing it.
    public var maxRetryDelay: TimeInterval

    /// Request timeout.
    public var timeout: TimeInterval

    /// API base URL. Override only for a self-hosted deployment or in tests.
    public var baseURL: URL

    public init(
        apiKey: String,
        source: String,
        throwOnError: Bool = false,
        retryEnabled: Bool = true,
        maxRetryDelay: TimeInterval = 10,
        timeout: TimeInterval = 30,
        baseURL: URL = URL(string: "https://api.logduck.com")!
    ) {
        self.apiKey = apiKey
        self.source = source
        self.throwOnError = throwOnError
        self.retryEnabled = retryEnabled
        self.maxRetryDelay = maxRetryDelay
        self.timeout = timeout
        self.baseURL = baseURL
    }
}

/// Where the client sends its warnings. `print` is the default.
public protocol LogDuckLogger: Sendable {
    func warn(_ message: String)
}

/// The default logger.
public struct PrintLogger: LogDuckLogger {
    public init() {}
    public func warn(_ message: String) {
        print("[LogDuck] \(message)")
    }
}
