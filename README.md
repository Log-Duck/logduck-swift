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

## Quick start

Two settings are required: your API key, and a `source` naming the app sending
the event.

```swift
import LogDuck

let logduck = LogDuckClient(
    options: LogDuckOptions(apiKey: "ld_your_key_here", source: "ios-app")
)

try await logduck.send(LogDuckEvent(type: "order.placed"))
```

That is the whole minimal setup. Create an API key in your project settings —
see [Authentication](https://logduck.com/docs#authentication).

`send` returns `nil` rather than throwing unless you ask it to, so when a failed
log line should never affect anything:

```swift
_ = try? await logduck.send(LogDuckEvent(type: "screen.viewed"))
```

The `_ =` is needed: `send` is `@discardableResult`, but `try?` wraps its result
in a second Optional and that attribute does not carry through, so without the
explicit discard the compiler warns.

## Every option

Only `apiKey` and `source` are required. The values below are the defaults you
get by omitting each one.

```swift
import LogDuck

let logduck = LogDuckClient(
    options: LogDuckOptions(
        apiKey: "ld_your_key_here",             // required — your key, starts with `ld_`
        source: "ios-app",                      // required — which app sent this, max 200 chars
        throwOnError: false,                    // optional, default false — true throws instead of returning nil
        retryEnabled: true,                     // optional, default true  — retry once on 5xx, network errors and 429
        maxRetryDelay: 10,                      // optional, default 10    — never block your caller longer, seconds
        timeout: 30,                            // optional, default 30    — per-request timeout, seconds
        baseURL: URL(string: "https://api.logduck.com")!  // optional — only for a self-hosted deployment
    )
    // transport: URLSessionTransport(),        // optional — swap the HTTP layer, mainly for tests
    // logger: PrintLogger()                    // optional, default PrintLogger — see Logging below
)

try await logduck.send(
    LogDuckEvent(
        type: "order.placed",                   // required — max 100 chars, naming rule below
        subject: "order_9127",                  // optional — what the event is about, max 500 chars
        sessionId: "sess_8f21c",                // optional — groups related events, max 256 chars
        time: Date(),                           // optional — defaults to when the server received it
        data: ["total": 4999, "currency": "NOK"], // optional — see JSONValue below
        emoji: "🛒"                              // optional — shown next to the event, max 10 chars
    )
)
```

One client is enough for a process. It is `Sendable`, so it can be held in a
`let` and used from any actor.

**Naming `type`:** the server lowercases it and requires `^[a-z][a-z0-9_.]*$` —
letters, digits, `_` and `.`, starting with a letter. So `order.placed` and
`user.signup_completed` are fine; `order-placed` is rejected with a 400. Dots
are the conventional separator.

### Why `JSONValue` and not `[String: Any]`

Swift has no `Any`-shaped type that is both `Sendable` and `Encodable`, and
`[String: Any]` would make the client non-`Sendable` — unusable from a
concurrent context without warnings. `JSONValue` conforms to the literal
protocols, so a payload still reads like the JSON it becomes:

```swift
data: ["total": 4999, "currency": "NOK", "gift": false, "tags": ["new", "eu"]]
```

## Errors

By default `send` **never throws**. It returns `nil` and logs a warning — a
logging SDK that throws can take down the code it was only meant to observe.

```swift
let result = try await logduck.send(LogDuckEvent(type: "order.placed"))

if result == nil {
    // The event did not reach LogDuck. A warning has already been logged.
}
```

Set `throwOnError: true` to get a `LogDuckError` instead. Note that `catch` only
sees anything when that option is on — with the default, the block below would
never run:

```swift
import Foundation
import LogDuck

let logduck = LogDuckClient(
    options: LogDuckOptions(
        apiKey: "ld_your_key_here",
        source: "ios-app",
        throwOnError: true      // required, or the catch below never fires
    )
)

// Your own queue — the SDK does not provide one.
struct QueuedEvent { let event: LogDuckEvent; let notBefore: Date }
var retryQueue: [QueuedEvent] = []

let event = LogDuckEvent(type: "order.placed", subject: "order_9127")

do {
    try await logduck.send(event)
} catch let error as LogDuckError {
    if let retryAfter = error.retryAfter {
        // Rate limited for longer than the client will wait — queue it rather than lose it.
        retryQueue.append(QueuedEvent(event: event, notBefore: Date().addingTimeInterval(retryAfter)))
    }
}
```

`LogDuckError` carries `message`, `status`, `body` and `retryAfter`.

## Retries and rate limits

### The SDK sets `Idempotency-Key` for you

Every call generates an `Idempotency-Key` header, and reuses the **same** key on
the retry. The server deduplicates on it, so an event that timed out and got
retried is recorded once rather than twice.

You never set this header yourself. It is the main thing the SDK does for you
that raw HTTP does not — the endpoint *requires* the header (16–36 characters of
`[A-Za-z0-9_-]`) and rejects requests without one.

### What gets retried

| Response | Behaviour |
|---|---|
| 5xx, network failure, timeout | retried once after 1 second |
| 429 | retried once after the server's `Retry-After`, but only if that fits inside `maxRetryDelay` |
| Any other 4xx | never retried — it will fail identically the second time |

The server rate-limits each API key in fixed one-minute windows, so `Retry-After`
can be as much as 60 seconds. Blocking your caller that long is rarely
acceptable, so beyond `maxRetryDelay` the client gives up immediately and puts
the remaining wait on `error.retryAfter`, letting you queue the event instead of
losing it.

## Using the API without the SDK

The SDK is a convenience, not a requirement — `POST /v1/events` is a plain JSON
endpoint over HTTPS, usable from any language or from `curl`:

```bash
curl -X POST https://api.logduck.com/v1/events \
  -H "X-API-Key: ld_your_key_here" \
  -H "Idempotency-Key: $(uuidgen)" \
  -H "Content-Type: application/json" \
  -d '{"type":"order.placed","source":"ios-app","subject":"order_9127"}'
```

Full request and response reference:
**[logduck.com/docs#api-reference](https://logduck.com/docs#api-reference)**.

Going direct means you take on what the SDK handles: generating a valid
`Idempotency-Key` per event and reusing it across retries, honouring
`Retry-After` on a 429, and deciding which failures are worth retrying.

## Logging

Warnings go to `print` by default. Pass anything conforming to `LogDuckLogger`
to redirect them:

```swift
import OSLog
import LogDuck

struct OSLogLogger: LogDuckLogger {
    private let logger = Logger(subsystem: "com.example.app", category: "logduck")
    func warn(_ message: String) { logger.warning("\(message)") }
}

let logduck = LogDuckClient(
    options: LogDuckOptions(apiKey: "ld_your_key_here", source: "ios-app"),
    logger: OSLogLogger()
)
```

## Testing

`LogDuckTransport` is the injection point, so nothing has to touch the network:

```swift
import Foundation
import LogDuck

struct StubTransport: LogDuckTransport {
    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
        )!
        let body = Data(#"{"success":true,"eventId":"evt_1","time":"2026-01-01T00:00:00Z"}"#.utf8)
        return (body, response)
    }
}

let logduck = LogDuckClient(
    options: LogDuckOptions(apiKey: "ld_test", source: "tests"),
    transport: StubTransport()
)
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
