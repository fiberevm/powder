import Foundation

/// Product analytics, sent to PostHog: which markets are opened, what is traded and how much, which parts of
/// the app are used. Events carry a random install id, never a wallet address, a key, a web address or anything
/// typed to the assistant. It can be turned off in Settings → Data.
enum Track {
    /// A PostHog project key: it can only write events, so it is safe to ship in the app.
    private static let projectKey = "phc_AZabR8yLe8SXhUG7rHFg9yuEsJFKNrjkdWvoGEHFNdMC"
    private static let endpoint = URL(string: "https://us.i.posthog.com/batch/")!
    static let disabledKey = "analytics.disabled"

    /// Nothing is sent from tests, or from a measuring run beside the real app.
    private static let isRealRun: Bool = {
        let process = ProcessInfo.processInfo
        let name = process.processName.lowercased()
        return Launch.profile == nil && !name.contains("xctest") && !name.contains("testing")
            && process.environment["XCTestConfigurationFilePath"] == nil
    }()

    static var isEnabled: Bool {
        get { !UserDefaults.standard.bool(forKey: disabledKey) }
        set {
            guard newValue != isEnabled else { return }
            // The choice itself is the last thing sent when turning it off.
            if !newValue { event("tracking_disabled") }
            UserDefaults.standard.set(!newValue, forKey: disabledKey)
            if !newValue { queue.async { Sender.shared.flush() } } else { event("tracking_enabled") }
        }
    }

    /// Everything past the hand-off happens here, off the caller's thread and below its priority.
    private static let queue = DispatchQueue(label: "io.powder.tracking", qos: .utility)

    /// Records one thing the user did. Values are strings, numbers or booleans; nil ones are left out.
    /// It returns at once: the caller only hands the event over, so an order is never held up by it.
    static func event(_ name: String, _ properties: [String: Any?] = [:]) {
        guard isRealRun, isEnabled else { return }
        let time = Date()
        // Handed to the queue and not touched here again.
        nonisolated(unsafe) let given = properties
        queue.async { Sender.shared.add(name, given.compactMapValues { $0 }, at: time) }
    }

    /// Sends what is waiting, giving it a moment to leave: for when the app is about to quit.
    static func finish() {
        guard isRealRun else { return }
        queue.sync { Sender.shared.flush(waitingUpTo: 1.5) }
    }

    /// Which exchange family a market is on, as events name it.
    enum Venue: String {
        case hyperliquid, solana
    }

    /// Queues events and posts them in batches, so recording one never waits on the network.
    private final class Sender: @unchecked Sendable {
        static let shared = Sender()

        private let lock = NSLock()
        private var waiting: [[String: Any]] = []
        private var isScheduled = false
        private var hasSent = false
        private let installID: String
        private let sessionID = Sender.uuid7()
        private let common: [String: Any]
        private let session: URLSession = {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 15
            return URLSession(configuration: configuration)
        }()

        private init() {
            let defaults = UserDefaults.standard
            if let saved = defaults.string(forKey: "analytics.installID") {
                installID = saved
            } else {
                installID = UUID().uuidString.lowercased()
                defaults.set(installID, forKey: "analytics.installID")
            }
            let info = Bundle.main.infoDictionary
            let system = ProcessInfo.processInfo.operatingSystemVersion
            common = [
                "$lib": "powder-macos",
                "$app_version": info?["CFBundleShortVersionString"] as? String ?? "dev",
                "$app_build": info?["CFBundleVersion"] as? String ?? "dev",
                "$os": "Mac OS X",
                "$os_version": "\(system.majorVersion).\(system.minorVersion).\(system.patchVersion)",
                "$device_type": "Desktop",
                // Events are counted per install; no person profile is built from them.
                "$process_person_profile": false,
            ]
        }

        func add(_ name: String, _ properties: [String: Any], at time: Date) {
            var all = common.merging(properties) { _, given in given }
            all["$session_id"] = sessionID
            let event: [String: Any] = [
                "event": name, "distinct_id": installID, "timestamp": time.ISO8601Format(.iso8601.year().month().day().time(includingFractionalSeconds: true).timeZone(separator: .omitted)),
                "properties": all,
            ]
            lock.lock()
            waiting.append(event)
            // A long offline spell keeps only the newest events.
            if waiting.count > 500 { waiting.removeFirst(waiting.count - 500) }
            let isFull = waiting.count >= 20
            let schedule = !isScheduled && !isFull
            if schedule { isScheduled = true }
            lock.unlock()
            if isFull {
                flush()
            } else if schedule {
                Track.queue.asyncAfter(deadline: .now() + 10) { [self] in flush() }
            }
        }

        func flush(waitingUpTo seconds: Double = 0) {
            lock.lock()
            let batch = waiting
            waiting.removeAll()
            isScheduled = false
            lock.unlock()
            guard !batch.isEmpty, JSONSerialization.isValidJSONObject(batch),
                  let body = try? JSONSerialization.data(withJSONObject: ["api_key": Track.projectKey, "batch": batch]) else { return }
            var request = URLRequest(url: Track.endpoint)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
            let done = DispatchSemaphore(value: 0)
            // Only ever touched under the lock.
            nonisolated(unsafe) let kept = batch
            session.dataTask(with: request) { [self] _, response, error in
                // Kept for the next batch when the network or PostHog is down; a refused batch is dropped.
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                lock.lock()
                if error != nil || status >= 500 || status == 429 {
                    waiting.insert(contentsOf: kept, at: 0)
                }
                let isFirst = status == 200 && !hasSent
                if status == 200 { hasSent = true }
                lock.unlock()
                if isFirst {
                    HyperliquidExchange.log("tracking: first batch accepted (\(kept.count) events)")
                } else if status != 200, error == nil {
                    HyperliquidExchange.log("tracking: batch refused (\(status))")
                }
                done.signal()
            }.resume()
            if seconds > 0 { _ = done.wait(timeout: .now() + seconds) }
        }

        /// A time-ordered UUID (version 7), which is what PostHog expects a session id to be.
        private static func uuid7() -> String {
            var bytes = [UInt8](repeating: 0, count: 16)
            for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) }
            let milliseconds = UInt64(Date().timeIntervalSince1970 * 1_000)
            for index in 0..<6 { bytes[index] = UInt8((milliseconds >> UInt64(8 * (5 - index))) & 0xff) }
            bytes[6] = (bytes[6] & 0x0f) | 0x70
            bytes[8] = (bytes[8] & 0x3f) | 0x80
            let hex = bytes.map { String(format: "%02x", $0) }.joined()
            let parts = [hex.prefix(8), hex.dropFirst(8).prefix(4), hex.dropFirst(12).prefix(4), hex.dropFirst(16).prefix(4), hex.dropFirst(20)]
            return parts.map(String.init).joined(separator: "-")
        }
    }
}
