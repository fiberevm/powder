import AppKit
import Foundation

/// How this run was started, and how long it took to show something.
enum Launch {
    /// Set `POWDER_PROFILE` to run beside the real app with separate settings: a fresh layout and no wallets.
    /// Used for measuring start-up; such a run does not replace the tool server address other agents use.
    static let profile: String? = ProcessInfo.processInfo.environment["POWDER_PROFILE"].flatMap { $0.isEmpty ? nil : $0 }

    static var defaults: UserDefaults {
        profile.flatMap { UserDefaults(suiteName: "io.powder.app.\($0)") } ?? .standard
    }

    /// A profile run can ask for a window size with `POWDER_WINDOW=1720x1080` (points), for repeatable screenshots.
    @MainActor
    static func sizeWindow() {
        guard profile != nil, let text = ProcessInfo.processInfo.environment["POWDER_WINDOW"] else { return }
        let parts = text.lowercased().split(separator: "x").compactMap { Double($0) }
        guard parts.count == 2, let window = NSApp.windows.first(where: { $0.isVisible && !($0 is NSPanel) }) else { return }
        window.setContentSize(NSSize(width: parts[0], height: parts[1]))
        window.center()
    }

    /// Milliseconds since the process was created, as the system records it (before any of the app's code ran).
    static func sinceProcessStart() -> Int? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&name, 4, &info, &size, nil, 0) == 0 else { return nil }
        let started = info.kp_proc.p_starttime
        var now = timeval()
        gettimeofday(&now, nil)
        return (now.tv_sec - started.tv_sec) * 1_000 + Int(now.tv_usec - started.tv_usec) / 1_000
    }

    @MainActor private static var hasChart = false

    /// Called when a chart first has candles to draw. The first one of the run is written to the log.
    @MainActor
    static func chartIsReady(_ coin: String, candles: Int) {
        guard !hasChart, candles > 0, let elapsed = sinceProcessStart() else { return }
        hasChart = true
        HyperliquidExchange.log("launch: first chart (\(coin), \(candles) candles) \(elapsed)ms after process start")
    }

    /// How long the chart takes to draw a frame, written to the log every 120 frames of a measuring run.
    final class DrawTimer: @unchecked Sendable {
        static let shared = DrawTimer()
        private let lock = NSLock()
        private var samples: [Double] = []

        func record(_ milliseconds: Double) {
            guard Launch.profile != nil else { return }
            lock.lock()
            samples.append(milliseconds)
            let batch = samples.count >= 120 ? samples.sorted() : nil
            if batch != nil { samples.removeAll(keepingCapacity: true) }
            lock.unlock()
            guard let batch else { return }
            let median = batch[batch.count / 2], p99 = batch[Int(Double(batch.count) * 0.99)]
            HyperliquidExchange.log(String(format: "chart draw: median %.2fms p99 %.2fms max %.2fms over %d frames", median, p99, batch.last ?? 0, batch.count))
        }
    }
}
