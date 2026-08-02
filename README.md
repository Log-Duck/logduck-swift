# LogDuck Swift SDK

Official Swift SDK for [LogDuck](https://logduck.com) — send events from your
app and get notified about the ones that matter.

iOS 13+, macOS 10.15+, tvOS 13+, watchOS 6+ and Linux. No dependencies.

## Installation

Swift Package Manager, via Xcode (*File → Add Package Dependencies*) or
`Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/Log-Duck/logduck-swift.git", from: "1.0.0")
]
```

## Usage

```swift
import LogDuck

let logduck = LogDuckClient(
    options: LogDuckOptions(apiKey: "ld_...", source: "ios-app")
)

try await logduck.send(
    LogDuckEvent(
        type: "order.placed",
        subject: "order_9127",
        data: ["total": 4999, "currency": "NOK"],
        emoji: "🛒"
    )
)
```

`send` is `@discardableResult`, and returns `nil` rather than throwing unless
you ask for throwing — so in the common case where you do not want a failed log
line to affect anything:

```swift
try? await logduck.send(LogDuckEvent(type: "screen.viewed"))
```

One client is enough for a process. It is `Sendable`, so it can be held in a
`let` and used from any actor.

## Options

| Option | Default | What it does |
|---|---|---|
| `apiKey` | — | Required. Must start with `ld_`. |
| `source` | — | Required. Identifies the app sending events (max 200 chars). Attached to every event. |
| `throwOnError` | `false` | When false, failures are logged and `send` returns `nil`. |
| `retryEnabled` | `true` | Retry once on 5xx, network errors and rate limits. |
| `maxRetryDelay` | `10` | Longest wait, in seconds, before retrying a rate-limited request. |
| `timeout` | `30` | Request timeout in seconds. |
| `baseURL` | `https://api.logduck.com` | Override for a self-hosted deployment. |

## Event fields

| Field | Required | Limit |
|---|---|---|
| `type` | yes | 100 chars. Lowercased by the server, which requires `^[a-z][a-z0-9_.]*$` — letters, digits, `_` and `.`, starting with a letter. A hyphen is rejected. |
| `subject` | no | 500 chars. The resource the event is about. |
| `sessionId` | no | 256 chars. Groups related events. |
| `time` | no | `Date`. Defaults to server time. |
| `data` | no | `[String: JSONValue]`. |
| `emoji` | no | 10 chars. |

`source` is not an event field — it comes from the options.

### Why `JSONValue` and not `[String: Any]`

Swift has no `Any`-shaped type that is both `Sendable` and `Encodable`, and
`[String: Any]` would make the client non-`Sendable` — unusable from a
concurrent context without warnings. `JSONValue` conforms to the literal
protocols, so a payload still reads like the JSON it becomes:

```swift
data: ["total": 4999, "currency": "NOK", "gift": false, "tags": ["new", "eu"]]
```

## Errors

`send` returns `nil` on failure and logs a warning. A logging SDK that throws
can take down the code it was only meant to observe, so that is the default;
set `throwOnError: true` to get a `LogDuckError` instead.

```swift
do {
    try await logduck.send(event)
} catch let error as LogDuckError {
    if let retryAfter = error.retryAfter {
        // Rate limited. Queue it rather than lose it.
        queue.append((event, Date().addingTimeInterval(retryAfter)))
    }
}
```

### Retries and rate limits

Every request carries an `Idempotency-Key`, unchanged across a retry, so the
server deduplicates rather than double-posting.

- **5xx and network failures** — retried once after 1 second.
- **429** — retried once, waiting for the period the server gives in
  `Retry-After`, but never longer than `maxRetryDelay`. The server limits each
  API key in fixed one-minute windows, so `Retry-After` can be as much as 60
  seconds; blocking a caller that long is rarely acceptable. When the wait would
  exceed the cap the client gives up immediately and the error carries
  `retryAfter`, so the event can be queued instead of lost.
- **Other 4xx** — never retried. They will fail identically the second time.

## Logging

Warnings go to `print` by default. Supply anything conforming to
`LogDuckLogger` to redirect them:

```swift
struct OSLogLogger: LogDuckLogger {
    func warn(_ message: String) { Logger().warning("\(message)") }
}

LogDuckClient(options: options, logger: OSLogLogger())
```

## Testing

`LogDuckTransport` is the injection point, so nothing has to touch the network:

```swift
struct StubTransport: LogDuckTransport {
    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) { ... }
}

LogDuckClient(options: options, transport: StubTransport())
```

## Development

```bash
swift build
swift test
swift build -Xswiftc -strict-concurrency=complete
```

SwiftPM has no registry — the git tag *is* the release. Bump
`logDuckSDKVersion` in `Sources/LogDuck/LogDuckClient.swift`, commit, then
`git tag v1.1.0 && git push origin v1.1.0`. Because the tag is live the moment
it is pushed, `release.yml` runs the suite as a gate after the fact: if it
fails, delete the tag.

## License

MIT
