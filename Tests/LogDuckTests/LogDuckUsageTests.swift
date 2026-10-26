import XCTest

@testable import LogDuck

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// A clock the test moves by hand, for the session timeout.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_790_000_000)

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        current = current.addingTimeInterval(seconds)
    }
}

extension FakeTransport.Reply {
    static func noContent() -> Self {
        Self(status: 204, body: "", headers: [:], error: nil)
    }
}

final class LogDuckUsageTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var directory: URL!
    private var queueFile: URL { directory.appendingPathComponent("usage.json") }
    private let clock = TestClock()

    override func setUp() {
        super.setUp()
        suiteName = "logduck.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("logduck-tests-\(UUID().uuidString)")
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    /// The timer is set far out so only the test decides when a flush runs.
    private func makeUsage(_ transport: FakeTransport, dimensions: [String: String] = [:]) -> LogDuckUsage {
        let clock = self.clock
        return LogDuckUsage(
            key: "ld_client_key",
            baseURL: LogDuckOptions.defaultBaseURL,
            dimensions: dimensions,
            transport: transport,
            logger: SilentLogger(),
            defaults: defaults,
            queueFile: queueFile,
            flushInterval: 600,
            automaticLifecycle: false,
            now: { clock.now }
        )
    }

    private func body(_ request: URLRequest) throws -> [String: Any] {
        let data = try XCTUnwrap(request.httpBody)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func hits(_ request: URLRequest) throws -> [[String: Any]] {
        try XCTUnwrap(body(request)["hits"] as? [[String: Any]])
    }

    private func allHits(_ transport: FakeTransport) throws -> [[String: Any]] {
        try transport.requests.flatMap { try hits($0) }
    }

    private func isHex32(_ value: Any?) -> Bool {
        guard let string = value as? String, string.count == 32 else { return false }
        return string.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    private func waitForRequests(_ transport: FakeTransport, _ count: Int) async {
        for _ in 0..<200 where transport.callCount < count {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    // MARK: - Screen views

    func testPostsAScreenViewWithTheContractFields() async throws {
        let transport = FakeTransport([.noContent()])
        let usage = makeUsage(transport, dimensions: ["section": "shop"])

        usage.screen("Home")
        await usage.flushAndWait()

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.logduck.com/v1/usage")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "text/plain")
        XCTAssertNil(request.value(forHTTPHeaderField: "X-API-Key"))
        XCTAssertEqual(try body(request)["key"] as? String, "ld_client_key")

        let hit = try XCTUnwrap(try hits(request).first)
        XCTAssertTrue(isHex32(hit["id"]))
        XCTAssertEqual(hit["type"] as? String, "screen.view")
        XCTAssertEqual(hit["screen"] as? String, "Home")
        XCTAssertEqual(hit["time"] as? String, "2026-09-21T14:13:20.000Z")
        XCTAssertEqual(hit["platform"] as? String, "ios")
        XCTAssertEqual(hit["host"] as? String, Bundle.main.bundleIdentifier ?? "app")
        XCTAssertTrue(isHex32(hit["sessionid"]))
        XCTAssertEqual(hit["sdkversion"] as? String, logDuckSDKVersion)
        XCTAssertEqual(hit["samplerate"] as? Int, 1)
        XCTAssertEqual(hit["dimensions"] as? [String: String], ["section": "shop"])
        XCTAssertNotNil((hit["osversion"] as? String)?.range(of: #"^\w+ \d+\.\d+"#, options: .regularExpression))
        for absent in ["previousscreen", "installid", "userid", "loggedin", "path"] {
            XCTAssertNil(hit[absent], absent)
        }
    }

    func testChainsThePreviousScreen() async throws {
        let transport = FakeTransport([.noContent()])
        let usage = makeUsage(transport)

        usage.screen("Home")
        usage.screen("Cart")
        usage.screen("Receipt", previous: "Checkout")
        await usage.flushAndWait()

        let sent = try allHits(transport)
        XCTAssertEqual(sent.map { $0["screen"] as? String }, ["Home", "Cart", "Receipt"])
        XCTAssertEqual(sent.map { $0["previousscreen"] as? String }, [nil, "Home", "Checkout"])
        XCTAssertEqual(Set(sent.compactMap { $0["sessionid"] as? String }).count, 1)
    }

    // MARK: - Lifecycle

    func testSendsInstallOnceThenOpen() async throws {
        let transport = FakeTransport([.noContent()])
        let first = makeUsage(transport)
        first.open()
        first.open()
        await first.flushAndWait()
        XCTAssertEqual(try allHits(transport).map { $0["type"] as? String }, ["app.install", "app.open"])
        XCTAssertTrue(defaults.bool(forKey: LogDuckUsage.installedKey))

        let relaunchTransport = FakeTransport([.noContent()])
        let relaunched = makeUsage(relaunchTransport)
        relaunched.open()
        await relaunched.flushAndWait()
        XCTAssertEqual(try allHits(relaunchTransport).map { $0["type"] as? String }, ["app.open"])
    }

    func testANewSessionBeginsAfterThirtyMinutesInTheBackground() async throws {
        let transport = FakeTransport([.noContent()])
        let usage = makeUsage(transport)

        usage.screen("Home")
        usage.background()
        clock.advance(10 * 60)
        usage.foreground()
        usage.background()
        clock.advance(30 * 60)
        usage.foreground()
        await usage.flushAndWait()

        let sent = try allHits(transport)
        XCTAssertEqual(
            sent.map { $0["type"] as? String },
            ["screen.view", "app.background", "app.foreground", "app.background", "app.foreground"]
        )
        let sessions = sent.map { $0["sessionid"] as? String }
        XCTAssertEqual(Set(sessions[0...3]).count, 1)
        XCTAssertNotEqual(sessions[4], sessions[0])
    }

    func testBackgroundSendsAtOnceInASingleRequest() async throws {
        let transport = FakeTransport([.failure()])
        let usage = makeUsage(transport)

        usage.screen("Home")
        usage.background()
        await waitForRequests(transport, 1)
        await usage.flushAndWait(maxBatches: 0)

        // No retry: a background flush makes one network call.
        XCTAssertEqual(transport.callCount, 1)
        XCTAssertEqual(try hits(transport.requests[0]).count, 2)
    }

    // MARK: - Identity

    func testConsentMintsAndPersistsAnInstallIdAndWithdrawalRemovesIt() async throws {
        let transport = FakeTransport([.noContent()])
        let usage = makeUsage(transport)

        usage.screen("Before")
        XCTAssertNil(defaults.string(forKey: LogDuckUsage.installIdKey))

        usage.consent(true)
        let stored = try XCTUnwrap(defaults.string(forKey: LogDuckUsage.installIdKey))
        XCTAssertTrue(isHex32(stored))
        usage.screen("Consented")

        // A later launch reuses it.
        let relaunched = makeUsage(transport)
        relaunched.screen("Relaunched")

        usage.consent(false)
        XCTAssertNil(defaults.string(forKey: LogDuckUsage.installIdKey))
        usage.screen("Withdrawn")

        await usage.flushAndWait()
        await relaunched.flushAndWait()

        let byScreen = Dictionary(
            try allHits(transport).map { ($0["screen"] as? String ?? "", $0) },
            uniquingKeysWith: { first, _ in first }
        )
        XCTAssertNil(byScreen["Before"]?["installid"])
        XCTAssertEqual(byScreen["Consented"]?["installid"] as? String, stored)
        XCTAssertEqual(byScreen["Relaunched"]?["installid"] as? String, stored)
        XCTAssertNil(byScreen["Withdrawn"]?["installid"])
    }

    func testIdentifyAttachesUserIdAndLoggedIn() async throws {
        let transport = FakeTransport([.noContent()])
        let usage = makeUsage(transport)

        usage.identify("user_42")
        usage.screen("Account")
        usage.identify("")
        usage.screen("SignedOut")
        await usage.flushAndWait()

        let sent = try allHits(transport)
        XCTAssertEqual(sent[0]["userid"] as? String, "user_42")
        XCTAssertEqual(sent[0]["loggedin"] as? Bool, true)
        XCTAssertNil(sent[1]["userid"])
        XCTAssertNil(sent[1]["loggedin"])
        // identify alone stores nothing on the device.
        XCTAssertNil(defaults.string(forKey: LogDuckUsage.installIdKey))
    }

    func testDropsInvalidDimensions() async throws {
        let transport = FakeTransport([.noContent()])
        let usage = makeUsage(transport)

        usage.setDimensions(["variant": String(repeating: "x", count: 300), "Bad-Key": "x"])
        usage.screen("Home")
        await usage.flushAndWait()

        let dimensions = try XCTUnwrap(try allHits(transport)[0]["dimensions"] as? [String: String])
        XCTAssertEqual(Array(dimensions.keys), ["variant"])
        XCTAssertEqual(dimensions["variant"]?.count, 256)
    }

    // MARK: - Batching and the offline queue

    func testFlushesOnItsOwnAtFiftyHits() async throws {
        let transport = FakeTransport([.noContent()])
        let usage = makeUsage(transport)

        for index in 0..<49 { usage.screen("S\(index)") }
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(transport.callCount, 0)

        usage.screen("S49")
        await waitForRequests(transport, 1)

        XCTAssertEqual(transport.callCount, 1)
        XCTAssertEqual(try hits(transport.requests[0]).count, 50)
    }

    func testSendsAtMostFiftyHitsPerRequest() async throws {
        let transport = FakeTransport([.noContent()])
        let usage = makeUsage(transport)

        usage.background()  // no automatic flush from here on, so the queue builds up
        await waitForRequests(transport, 1)
        for index in 0..<120 { usage.screen("S\(index)") }
        await usage.flushAndWait()

        XCTAssertEqual(try transport.requests.map { try hits($0).count }, [1, 50, 50, 20])
    }

    func testAFailedFlushKeepsTheHitsAndTheNextFlushResendsThem() async throws {
        let transport = FakeTransport([.failure(), .status(503), .noContent()])
        let usage = makeUsage(transport)

        usage.screen("Home")
        usage.screen("Cart")
        await usage.flushAndWait()  // a network failure, then a 503 on the retry
        XCTAssertEqual(transport.callCount, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: queueFile.path))

        // A later launch picks them up from disk.
        let relaunchTransport = FakeTransport([.noContent()])
        let relaunched = makeUsage(relaunchTransport)
        await relaunched.flushAndWait()
        XCTAssertEqual(try allHits(relaunchTransport).map { $0["screen"] as? String }, ["Home", "Cart"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: queueFile.path))

        await usage.flushAndWait()
        let first = try hits(transport.requests[0]).map { $0["id"] as? String }
        let resent = try hits(transport.requests[2]).map { $0["id"] as? String }
        XCTAssertEqual(resent, first)
    }

    func testA4xxDropsTheBatch() async throws {
        let transport = FakeTransport([.status(400), .noContent()])
        let usage = makeUsage(transport)

        usage.screen("Rejected")
        await usage.flushAndWait()
        XCTAssertEqual(transport.callCount, 1)  // never retried

        usage.screen("Accepted")
        await usage.flushAndWait()
        XCTAssertEqual(try hits(transport.requests[1]).map { $0["screen"] as? String }, ["Accepted"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: queueFile.path))
    }

    func testStopRecordsNothingFurther() async throws {
        let transport = FakeTransport([.noContent()])
        let usage = makeUsage(transport)

        usage.screen("Home")
        usage.stop()
        usage.screen("Ignored")
        await usage.flushAndWait()

        XCTAssertEqual(try allHits(transport).map { $0["screen"] as? String }, ["Home"])
    }
}
