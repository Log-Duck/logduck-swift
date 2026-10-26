import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

#if canImport(UIKit) && !os(watchOS)
    import UIKit
#endif

/// Counts how people move through your app — screen views and the app
/// lifecycle — into the **Site** tab of your project.
///
/// ```swift
/// let usage = LogDuckUsage(key: "ld_...")   // a client key
/// usage.screen("Checkout")
/// ```
///
/// It is not the events client: a hit never triggers a push, a webhook or an
/// alert. Hits are batched and sent in the background; a hit that cannot be
/// sent is kept on disk and sent with the next flush.
///
/// On iOS and tvOS `app.install` (once ever), `app.open` (once per process),
/// `app.foreground` and `app.background` are recorded for you. Elsewhere, call
/// ``open()``, ``foreground()`` and ``background()`` yourself.
///
/// Every method is safe to call from any thread and returns at once. Create one
/// tracker per process and keep it for the life of the app.
public final class LogDuckUsage: @unchecked Sendable {
    // MARK: - Limits

    /// The server accepts at most this many hits per request.
    static let batchSize = 50
    /// Hits kept, in memory and on disk, before the oldest are dropped.
    static let queueLimit = 500
    /// A session ends after this long in the background.
    static let sessionTimeout: TimeInterval = 30 * 60

    // In UTF-16 code units, as the server (zod) counts them.
    private static let screenMax = 128
    private static let userIdMax = 128
    private static let installIdMax = 128
    private static let dimensionKeysMax = 10
    private static let dimensionValueMax = 256

    /// Copied from `RESERVED_DIMENSION_KEYS` in the LogDuck server's
    /// `functions/src/shared/schemas/hit.ts`. The server refuses a whole hit
    /// for one of these, so they are dropped here instead.
    static let reservedDimensionKeys: Set<String> = [
        "id", "uid", "sub", "ip", "email", "mail", "phone", "name", "username", "address",
        "user", "userid", "user_id", "visitor", "visitorid", "visitor_id", "session", "sessionid", "session_id",
        "customer_id", "customerid", "member_id", "memberid", "account_id", "accountid",
        "device_id", "deviceid", "install_id", "installid", "token", "fingerprint",
    ]

    static let installedKey = "logduck.installed"
    static let installIdKey = "logduck.installid"

    // MARK: - Configuration

    private let key: String
    private let endpoint: URL
    private let transport: LogDuckTransport
    private let logger: LogDuckLogger
    // UserDefaults is documented as thread-safe; it is not marked Sendable.
    private let defaults: UserDefaults
    private let queueFile: URL?
    private let flushInterval: TimeInterval
    private let now: @Sendable () -> Date
    private let host: String
    private let appVersion: String?
    private let osVersion: String

    // MARK: - State, guarded by `lock`

    private let lock = NSLock()
    private var queue: [Hit] = []
    /// Hits recorded since the last flush began; reaching a batch flushes early.
    private var unflushed = 0
    private var dimensions: [String: String]?
    private var sessionId = LogDuckUsage.newId()
    private var installId: String?
    private var userId: String?
    private var lastScreen: String?
    private var opened = false
    private var inBackground = false
    private var backgroundedAt: Date?
    private var timer: Task<Void, Never>?
    /// The most recent flush. Each flush waits for the one before it, so they
    /// never overlap and never send a hit twice.
    private var flushChain: Task<Void, Never>?
    private var queueOnDisk = false
    private var warnedRejected = false
    private var stopped = false
    private var observers: [NSObjectProtocol] = []

    /// Creates the tracker.
    ///
    /// - Parameters:
    ///   - key: A **client** key (`ld_...`) with "allow requests without an
    ///     origin" switched on in the dashboard. A server key is refused.
    ///   - baseURL: Override only for a self-hosted deployment or in tests.
    ///   - dimensions: Attached to every hit: at most ten lowercase keys with
    ///     string values of at most 256 characters. Never an identifier.
    ///   - transport: Swap the HTTP layer, mainly for tests.
    ///   - logger: Where warnings go.
    public convenience init(
        key: String,
        baseURL: URL = LogDuckOptions.defaultBaseURL,
        dimensions: [String: String] = [:],
        transport: LogDuckTransport? = nil,
        logger: LogDuckLogger = PrintLogger()
    ) {
        self.init(
            key: key,
            baseURL: baseURL,
            dimensions: dimensions,
            transport: transport,
            logger: logger,
            defaults: .standard,
            queueFile: Self.defaultQueueFile(),
            flushInterval: 1,
            automaticLifecycle: true,
            now: { Date() }
        )
    }

    init(
        key: String,
        baseURL: URL,
        dimensions: [String: String],
        transport: LogDuckTransport?,
        logger: LogDuckLogger,
        defaults: UserDefaults,
        queueFile: URL?,
        flushInterval: TimeInterval,
        automaticLifecycle: Bool,
        now: @escaping @Sendable () -> Date
    ) {
        self.key = key
        self.endpoint = baseURL.appendingPathComponent("v1/usage")
        self.transport = transport ?? URLSessionTransport()
        self.logger = logger
        self.defaults = defaults
        self.queueFile = queueFile
        self.flushInterval = flushInterval
        self.now = now
        self.host = Bundle.main.bundleIdentifier ?? "app"
        self.appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        self.osVersion = Self.currentOSVersion()

        if key.isEmpty { warn("no key configured - every request will be refused") }
        self.dimensions = cleanDimensions(dimensions)
        // Present only if consent was granted in an earlier launch.
        self.installId = defaults.string(forKey: Self.installIdKey).map { Self.clipped($0, to: Self.installIdMax) }
        self.queue = loadQueue()
        self.queueOnDisk = !queue.isEmpty

        #if canImport(UIKit) && !os(watchOS)
            if automaticLifecycle {
                observeLifecycle()
                open()
            }
        #endif
    }

    deinit {
        timer?.cancel()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    // MARK: - Recording

    /// Records a screen view.
    ///
    /// `previous` defaults to the screen named by the last call, so a plain
    /// sequence of calls chains itself.
    public func screen(_ name: String, previous: String? = nil) {
        let name = Self.clipped(name.trimmingCharacters(in: .whitespacesAndNewlines), to: Self.screenMax)
        guard !name.isEmpty else { return }
        let previousScreen: String? = locked {
            let chained = previous ?? lastScreen
            lastScreen = name
            return chained.map { Self.clipped($0, to: Self.screenMax) }
        }
        record("screen.view", screen: name, previousScreen: previousScreen)
    }

    /// Records `app.open`, preceded by `app.install` the first time this app
    /// ever runs. Recorded for you on iOS and tvOS; a second call is ignored.
    public func open() {
        let firstOpen: Bool = locked {
            if opened { return false }
            opened = true
            return true
        }
        guard firstOpen else { return }
        if !defaults.bool(forKey: Self.installedKey) {
            defaults.set(true, forKey: Self.installedKey)
            record("app.install")
        }
        record("app.open")
    }

    /// Records `app.foreground`. After 30 minutes in the background a new
    /// session begins. Recorded for you on iOS and tvOS.
    public func foreground() {
        locked {
            if let since = backgroundedAt, now().timeIntervalSince(since) >= Self.sessionTimeout {
                sessionId = Self.newId()
                lastScreen = nil
            }
            inBackground = false
            backgroundedAt = nil
        }
        record("app.foreground")
    }

    /// Records `app.background` and sends what is queued at once, in a single
    /// request. Until ``foreground()``, no timer runs. Recorded for you on iOS
    /// and tvOS.
    public func background() {
        record("app.background")
        locked {
            inBackground = true
            backgroundedAt = now()
            timer?.cancel()
            timer = nil
        }
        Task { await self.flushAndWait(maxBatches: 1, attempts: 1, persistFirst: true) }
    }

    // MARK: - Identity

    /// Records that the user agreed to be recognised across launches.
    ///
    /// `true` mints a random install ID, keeps it in `UserDefaults` and
    /// attaches it to every later hit; `false` deletes it and strips it from
    /// hits still queued, in memory and on disk. Nothing identifying is stored
    /// before `consent(true)`.
    public func consent(_ granted: Bool) {
        locked {
            if granted {
                if installId == nil {
                    let id = Self.newId()
                    defaults.set(id, forKey: Self.installIdKey)
                    installId = id
                }
            } else {
                installId = nil
                defaults.removeObject(forKey: Self.installIdKey)
                for index in queue.indices { queue[index].installid = nil }
                // Rewritten on the flush chain, so it never overlaps a flush.
                if queueOnDisk {
                    let previous = flushChain
                    flushChain = Task {
                        await previous?.value
                        self.persist()
                    }
                }
            }
        }
    }

    /// Links later hits to your own user ID and marks them logged in. Stores
    /// nothing on the device. An empty string clears it.
    public func identify(_ userId: String) {
        let trimmed = Self.clipped(userId.trimmingCharacters(in: .whitespacesAndNewlines), to: Self.userIdMax)
        locked { self.userId = trimmed.isEmpty ? nil : trimmed }
    }

    /// Replaces the dimensions attached to every later hit.
    public func setDimensions(_ dimensions: [String: String]) {
        let cleaned = cleanDimensions(dimensions)
        locked { self.dimensions = cleaned }
    }

    // MARK: - Sending

    /// Sends whatever is queued now.
    public func flush() {
        Task { await self.flushAndWait() }
    }

    /// Stops recording, detaches the lifecycle observers and sends what is
    /// queued.
    public func stop() {
        let detached: [NSObjectProtocol] = locked {
            stopped = true
            timer?.cancel()
            timer = nil
            defer { observers = [] }
            return observers
        }
        for observer in detached { NotificationCenter.default.removeObserver(observer) }
        flush()
    }

    private func record(_ type: String, screen: String? = nil, previousScreen: String? = nil) {
        let flushEarly: Bool = locked {
            guard !stopped else { return false }
            var hit = Hit(
                id: Self.newId(),
                type: type,
                time: iso8601String(from: now()),
                platform: "ios",
                host: host,
                sessionid: sessionId,
                appversion: appVersion,
                osversion: osVersion,
                sdkversion: logDuckSDKVersion,
                samplerate: 1
            )
            hit.dimensions = dimensions
            hit.screen = screen
            hit.previousscreen = previousScreen
            hit.installid = installId
            if let userId {
                hit.userid = userId
                hit.loggedin = true
            }

            queue.append(hit)
            if queue.count > Self.queueLimit { queue.removeFirst(queue.count - Self.queueLimit) }
            unflushed += 1

            // In the background nothing is sent until the next background() or
            // foreground(): no timers, no batches.
            if inBackground { return false }
            if unflushed >= Self.batchSize { return true }
            scheduleTimer()
            return false
        }
        if flushEarly { flush() }
    }

    /// Call with the lock held. The timer exists only while hits are waiting.
    private func scheduleTimer() {
        guard timer == nil else { return }
        let nanoseconds = UInt64(flushInterval * 1_000_000_000)
        timer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled, let self else { return }
            await self.flushAndWait()
        }
    }

    /// Flushes and returns once this flush — and every one queued before it —
    /// has finished.
    ///
    /// - Parameters:
    ///   - maxBatches: Requests to make at most. `background()` makes one.
    ///   - attempts: 2 retries once on a 5xx or network failure, like events.
    ///   - persistFirst: Write the queue to disk before sending, so a process
    ///     killed mid-request loses nothing. The server deduplicates on `id`.
    func flushAndWait(maxBatches: Int = .max, attempts: Int = 2, persistFirst: Bool = false) async {
        let task: Task<Void, Never> = locked {
            let previous = flushChain
            let task = Task {
                await previous?.value
                await self.drain(maxBatches: maxBatches, attempts: attempts, persistFirst: persistFirst)
            }
            flushChain = task
            return task
        }
        await task.value
    }

    private func drain(maxBatches: Int, attempts: Int, persistFirst: Bool) async {
        if persistFirst { persist() }

        var requests = 0
        while requests < maxBatches {
            let batch: [Hit] = locked {
                timer?.cancel()
                timer = nil
                unflushed = 0
                return Array(queue.prefix(Self.batchSize))
            }
            if batch.isEmpty { break }
            requests += 1

            switch await post(batch, attempts: attempts) {
            case .delivered:
                remove(batch)
            case let .rejected(status):
                remove(batch)
                let first: Bool = locked {
                    defer { warnedRejected = true }
                    return !warnedRejected
                }
                if first {
                    warn("the server answered \(status); hits from this app are not being recorded")
                }
            case .failed:
                // Kept for the next flush, and on disk in case there is none.
                persist()
                return
            }
        }

        if locked({ queueOnDisk }) { persist() }
    }

    private enum PostResult {
        case delivered
        case rejected(status: Int)
        case failed
    }

    private func post(_ batch: [Hit], attempts: Int) async -> PostResult {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        // text/plain keeps the request "simple" for browsers; the server reads
        // the same body from every SDK.
        request.setValue("text/plain", forHTTPHeaderField: "Content-Type")
        request.setValue("LogDuck-Swift/\(logDuckSDKVersion)", forHTTPHeaderField: "User-Agent")
        do {
            request.httpBody = try JSONEncoder().encode(Body(key: key, hits: batch))
        } catch {
            warn("could not encode \(batch.count) hits; dropped")
            return .rejected(status: 0)
        }

        let outcome = await performWithRetry(
            request,
            transport: transport,
            maxAttempts: max(1, attempts),
            // A usage flush never waits out a rate-limit window; the hits stay
            // queued for the next one instead.
            maxRetryDelay: 0,
            logger: logger
        )

        switch outcome {
        case .succeeded:
            return .delivered
        case let .failed(error, _):
            // Any 4xx but a 429 will fail identically next time.
            if let status = error.status, (400..<500).contains(status), status != 429 {
                return .rejected(status: status)
            }
            return .failed
        }
    }

    /// Removes sent hits by id: the queue may have dropped its oldest while
    /// the request was in flight, so positions are not stable.
    private func remove(_ batch: [Hit]) {
        let ids = Set(batch.map(\.id))
        locked { queue.removeAll { ids.contains($0.id) } }
    }

    // MARK: - The queue on disk

    /// `Library/Caches/logduck/usage.json`. An unsandboxed Mac app shares its
    /// caches directory with every other app, so there it sits one level down,
    /// under the bundle identifier.
    static func defaultQueueFile() -> URL? {
        guard var caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        #if os(macOS)
            caches.appendPathComponent(Bundle.main.bundleIdentifier ?? "app")
        #endif
        return caches.appendingPathComponent("logduck").appendingPathComponent("usage.json")
    }

    /// Only ever called on the flush chain, which never overlaps itself.
    private func persist() {
        guard let queueFile else { return }
        let snapshot: [Hit] = locked { queue }
        do {
            if snapshot.isEmpty {
                try? FileManager.default.removeItem(at: queueFile)
            } else {
                try FileManager.default.createDirectory(
                    at: queueFile.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try JSONEncoder().encode(snapshot).write(to: queueFile, options: .atomic)
            }
            locked { queueOnDisk = !snapshot.isEmpty }
        } catch {
            warn("could not save \(snapshot.count) unsent hits: \(error.localizedDescription)")
        }
    }

    private func loadQueue() -> [Hit] {
        guard let queueFile, let data = try? Data(contentsOf: queueFile) else { return [] }
        guard let hits = try? JSONDecoder().decode([Hit].self, from: data) else {
            try? FileManager.default.removeItem(at: queueFile)
            return []
        }
        return Array(hits.suffix(Self.queueLimit))
    }

    // MARK: - Lifecycle

    #if canImport(UIKit) && !os(watchOS)
        private func observeLifecycle() {
            let center = NotificationCenter.default
            let active = center.addObserver(
                forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil
            ) { [weak self] _ in
                guard let self else { return }
                // Also posted at launch and after a pulled-down Control Centre;
                // only a return from the background is a foreground.
                if self.locked({ self.inBackground }) { self.foreground() }
            }
            let background = center.addObserver(
                forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil
            ) { [weak self] _ in
                self?.background()
            }
            locked { observers = [active, background] }
        }
    #endif

    // MARK: - Helpers

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private func warn(_ message: String) {
        logger.warn("usage: \(message)")
    }

    /// 32 lowercase hex characters, random.
    static func newId() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    private func cleanDimensions(_ input: [String: String]) -> [String: String]? {
        var out: [String: String] = [:]
        for (key, value) in input.sorted(by: { $0.key < $1.key }) {
            guard Self.isDimensionKey(key) else {
                warn("dimension \"\(key)\" dropped: keys are lowercase identifiers of at most 64 characters")
                continue
            }
            guard !Self.reservedDimensionKeys.contains(key) else {
                warn("dimension \"\(key)\" dropped: dimensions must not carry an identifier")
                continue
            }
            guard out.count < Self.dimensionKeysMax else {
                warn("dimension \"\(key)\" dropped: at most \(Self.dimensionKeysMax) dimensions")
                continue
            }
            out[key] = Self.clipped(value, to: Self.dimensionValueMax)
        }
        return out.isEmpty ? nil : out
    }

    /// At most `max` UTF-16 code units, cut on a character boundary.
    static func clipped(_ value: String, to max: Int) -> String {
        guard value.utf16.count > max else { return value }
        var units = 0
        var end = value.startIndex
        for character in value {
            units += character.utf16.count
            if units > max { break }
            end = value.index(after: end)
        }
        return String(value[..<end])
    }

    /// `^[a-z][a-z0-9_]{0,63}$`, the server's rule.
    private static func isDimensionKey(_ key: String) -> Bool {
        guard let first = key.unicodeScalars.first, key.unicodeScalars.count <= 64,
            ("a"..."z").contains(first)
        else { return false }
        return key.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "_" }
    }

    /// e.g. `iOS 17.5`.
    static func currentOSVersion() -> String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        var number = "\(version.majorVersion).\(version.minorVersion)"
        if version.patchVersion > 0 { number += ".\(version.patchVersion)" }

        #if targetEnvironment(macCatalyst)
            let name = "macOS"
        #elseif os(iOS)
            let name = "iOS"
        #elseif os(tvOS)
            let name = "tvOS"
        #elseif os(watchOS)
            let name = "watchOS"
        #elseif os(visionOS)
            let name = "visionOS"
        #elseif os(macOS)
            let name = "macOS"
        #elseif os(Linux)
            let name = "Linux"
        #else
            let name = "unknown"
        #endif
        return "\(name) \(number)"
    }
}

/// One hit on the wire. The property names are the wire names: flat, lowercase
/// CloudEvents attributes, as the server's schema names them. Absent fields are
/// omitted rather than sent as null.
struct Hit: Codable, Sendable, Equatable {
    let id: String
    let type: String
    let time: String
    let platform: String
    let host: String
    let sessionid: String
    let appversion: String?
    let osversion: String
    let sdkversion: String
    let samplerate: Int
    var dimensions: [String: String]?
    var screen: String?
    var previousscreen: String?
    var installid: String?
    var userid: String?
    var loggedin: Bool?

    init(
        id: String, type: String, time: String, platform: String, host: String,
        sessionid: String, appversion: String?, osversion: String, sdkversion: String,
        samplerate: Int
    ) {
        self.id = id
        self.type = type
        self.time = time
        self.platform = platform
        self.host = host
        self.sessionid = sessionid
        self.appversion = appversion
        self.osversion = osversion
        self.sdkversion = sdkversion
        self.samplerate = samplerate
    }
}

/// The request body. The key travels in the body, as it does from a browser's
/// `sendBeacon`, which cannot set a header.
private struct Body: Encodable {
    let key: String
    let hits: [Hit]
}
