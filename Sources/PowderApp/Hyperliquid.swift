import Foundation
import os

// MARK: - Models

struct HLAssetCtx: Sendable, Equatable {
    var markPx: Double
    var midPx: Double?
    var oraclePx: Double
    var prevDayPx: Double
    var dayNtlVlm: Double
    var openInterest: Double
    /// Hourly funding rate as a fraction (0.0000125 = 0.00125%).
    var funding: Double
}

struct HLMarket: Sendable, Equatable, Identifiable {
    /// Position in Hyperliquid's universe: the asset id orders are addressed to.
    let index: Int
    let name: String
    let szDecimals: Int
    let maxLeverage: Int
    var ctx: HLAssetCtx

    var id: String { name }

    var dayChange: Double {
        guard ctx.prevDayPx > 0 else { return 0 }
        return (ctx.midPx ?? ctx.markPx) / ctx.prevDayPx - 1
    }
}

struct HLLevel: Sendable, Equatable {
    let px: Double
    let sz: Double
    let n: Int
}

struct HLBook: Sendable, Equatable {
    let coin: String
    let time: Int64
    let bids: [HLLevel]
    let asks: [HLLevel]
}

struct HLTrade: Sendable, Equatable, Identifiable {
    let tid: Int64
    let coin: String
    let isBuy: Bool
    let px: Double
    let sz: Double
    let time: Int64

    var id: Int64 { tid }
}

struct HLCandle: Sendable, Equatable {
    /// Open time, milliseconds since epoch.
    let t: Int64
    let coin: String
    let interval: String
    let o: Double
    let h: Double
    let l: Double
    let c: Double
    let v: Double
}

enum HLInterval: String, CaseIterable, Sendable {
    case m1 = "1m", m3 = "3m", m5 = "5m", m15 = "15m", m30 = "30m"
    case h1 = "1h", h2 = "2h", h4 = "4h", h8 = "8h", h12 = "12h"
    case d1 = "1d", d3 = "3d", w1 = "1w", mo1 = "1M"

    /// Candle length. A month is counted as 30 days, which is close enough for ranges and axis spacing.
    var milliseconds: Int64 {
        let minute: Int64 = 60_000
        return switch self {
        case .m1: minute
        case .m3: 3 * minute
        case .m5: 5 * minute
        case .m15: 15 * minute
        case .m30: 30 * minute
        case .h1: 60 * minute
        case .h2: 120 * minute
        case .h4: 240 * minute
        case .h8: 480 * minute
        case .h12: 720 * minute
        case .d1: 1_440 * minute
        case .d3: 4_320 * minute
        case .w1: 10_080 * minute
        case .mo1: 43_200 * minute
        }
    }

    /// Daily and longer candles open at 00:00 UTC, so they are labelled in UTC and without a time.
    var isDaily: Bool { milliseconds >= HLInterval.d1.milliseconds }
}

/// Order book price aggregation, expressed as Hyperliquid's `nSigFigs`.
enum HLBookGrouping: Int, CaseIterable, Sendable {
    case full = 5, four = 4, three = 3

    func tick(at price: Double) -> Double {
        guard price > 0 else { return 0 }
        return pow(10, floor(log10(price)) - Double(rawValue) + 1)
    }
}

enum HLConnectionState: Sendable, Equatable {
    case connecting
    case live
    case reconnecting(attempt: Int)
}

enum HLEvent: Sendable {
    case connection(HLConnectionState)
    case latency(milliseconds: Int)
    case book(HLBook)
    case trades([HLTrade])
    case ctx(coin: String, HLAssetCtx)
    case candle(HLCandle)
    /// Mid prices for every listed asset, keyed by coin.
    case mids([String: Double])
}

enum HLSubscription: Sendable {
    case book(coin: String, grouping: HLBookGrouping)
    case trades(coin: String)
    case ctx(coin: String)
    case candle(coin: String, interval: HLInterval)
    case allMids

    fileprivate var json: String {
        switch self {
        case .allMids:
            #"{"type":"allMids"}"#
        case let .book(coin, grouping):
            grouping == .full
                ? #"{"type":"l2Book","coin":"\#(coin)"}"#
                : #"{"type":"l2Book","coin":"\#(coin)","nSigFigs":\#(grouping.rawValue)}"#
        case let .trades(coin):
            #"{"type":"trades","coin":"\#(coin)"}"#
        case let .ctx(coin):
            #"{"type":"activeAssetCtx","coin":"\#(coin)"}"#
        case let .candle(coin, interval):
            #"{"type":"candle","coin":"\#(coin)","interval":"\#(interval.rawValue)"}"#
        }
    }
}

// MARK: - Wire formats

private func number(_ string: String) -> Double { Double(string) ?? 0 }

private struct CtxDTO: Decodable {
    let markPx: String
    let midPx: String?
    let oraclePx: String
    let prevDayPx: String
    let dayNtlVlm: String
    let openInterest: String
    let funding: String

    var model: HLAssetCtx {
        HLAssetCtx(
            markPx: number(markPx),
            midPx: midPx.map(number),
            oraclePx: number(oraclePx),
            prevDayPx: number(prevDayPx),
            dayNtlVlm: number(dayNtlVlm),
            openInterest: number(openInterest),
            funding: number(funding)
        )
    }
}

private struct CandleDTO: Decodable {
    let t: Int64
    let s: String
    let i: String
    let o: String
    let h: String
    let l: String
    let c: String
    let v: String

    var model: HLCandle {
        HLCandle(t: t, coin: s, interval: i, o: number(o), h: number(h), l: number(l), c: number(c), v: number(v))
    }
}

private struct BookDTO: Decodable {
    struct Level: Decodable {
        let px: String
        let sz: String
        let n: Int

        var model: HLLevel { HLLevel(px: number(px), sz: number(sz), n: n) }
    }

    let coin: String
    let time: Int64
    let levels: [[Level]]

    var model: HLBook {
        HLBook(
            coin: coin,
            time: time,
            bids: levels.first?.map(\.model) ?? [],
            asks: levels.dropFirst().first?.map(\.model) ?? []
        )
    }
}

private struct TradeDTO: Decodable {
    let coin: String
    let side: String
    let px: String
    let sz: String
    let time: Int64
    let tid: Int64

    var model: HLTrade {
        HLTrade(tid: tid, coin: coin, isBuy: side == "B", px: number(px), sz: number(sz), time: time)
    }
}

private struct ActiveCtxDTO: Decodable {
    let coin: String
    let ctx: CtxDTO
}

private struct MetaDTO: Decodable {
    struct Asset: Decodable {
        let name: String
        let szDecimals: Int
        let maxLeverage: Int
        let isDelisted: Bool?
    }

    let universe: [Asset]
}

private struct MetaAndCtxsDTO: Decodable {
    let meta: MetaDTO
    let ctxs: [CtxDTO]

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        meta = try container.decode(MetaDTO.self)
        ctxs = try container.decode([CtxDTO].self)
    }
}

private struct AllMidsDTO: Decodable { let mids: [String: String] }
private struct ChannelDTO: Decodable { let channel: String }
private struct DataDTO<T: Decodable>: Decodable { let data: T }

// MARK: - REST

enum HyperliquidAPI {
    static let host = "api.hyperliquid.xyz"
    private static let infoURL = URL(string: "https://\(host)/info")!
    fileprivate static let socketURL = URL(string: "wss://\(host)/ws")!

    struct RequestError: LocalizedError {
        let status: Int
        var errorDescription: String? { "Hyperliquid returned HTTP \(status)" }
    }

    /// Every listed perpetual with its current market context.
    static func markets() async throws -> [HLMarket] {
        let data = try await post(#"{"type":"metaAndAssetCtxs"}"#)
        let decoded = try JSONDecoder().decode(MetaAndCtxsDTO.self, from: data)
        return zip(decoded.meta.universe, decoded.ctxs).enumerated().compactMap { index, pair in
            let (asset, ctx) = pair
            return asset.isDelisted == true
                ? nil
                : HLMarket(
                    index: index,
                    name: asset.name,
                    szDecimals: asset.szDecimals,
                    maxLeverage: asset.maxLeverage,
                    ctx: ctx.model
                )
        }
    }

    /// The `count` candles ending at `end` (now, when omitted). Hyperliquid keeps about 5,000 per interval.
    static func candles(coin: String, interval: HLInterval, end: Int64? = nil, count: Int = 600) async throws -> [HLCandle] {
        let end = end ?? Int64(Date().timeIntervalSince1970 * 1_000)
        let start = max(end - interval.milliseconds * Int64(count), 0)
        let body = #"{"type":"candleSnapshot","req":{"coin":"\#(coin)","interval":"\#(interval.rawValue)","startTime":\#(start),"endTime":\#(end)}}"#
        let data = try await post(body)
        return try JSONDecoder().decode([CandleDTO].self, from: data).map(\.model)
    }

    private static func post(_ body: String) async throws -> Data {
        var request = URLRequest(url: infoURL, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(body.utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw RequestError(status: http.statusCode)
        }
        return data
    }
}

// MARK: - WebSocket

enum HyperliquidSocket {
    /// A self-healing stream for one fixed set of subscriptions. It reconnects with backoff until
    /// the consumer stops iterating; to change subscriptions, drop the stream and open another.
    static func events(_ subscriptions: [HLSubscription]) -> AsyncStream<HLEvent> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1_024)) { continuation in
            let task = Task {
                var attempt = 0
                while !Task.isCancelled {
                    continuation.yield(.connection(attempt == 0 ? .connecting : .reconnecting(attempt: attempt)))
                    let receivedAny = await runConnection(subscriptions, continuation)
                    if Task.isCancelled { break }
                    attempt = receivedAny ? 1 : attempt + 1
                    continuation.yield(.connection(.reconnecting(attempt: attempt)))
                    try? await Task.sleep(for: .seconds(min(pow(2, Double(attempt)) / 2, 15)))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Runs one connection until it fails or is cancelled. Returns whether any data arrived.
    private static func runConnection(
        _ subscriptions: [HLSubscription],
        _ continuation: AsyncStream<HLEvent>.Continuation
    ) async -> Bool {
        let socket = URLSession.shared.webSocketTask(with: HyperliquidAPI.socketURL)
        socket.maximumMessageSize = 8 << 20
        socket.resume()

        let pingSentAt = OSAllocatedUnfairLock<ContinuousClock.Instant?>(initialState: nil)
        // Hyperliquid drops connections that are silent for 60 s; the ping doubles as a latency probe.
        let pinger = Task {
            while !Task.isCancelled {
                pingSentAt.withLock { $0 = ContinuousClock.now }
                try? await socket.send(.string(#"{"method":"ping"}"#))
                try? await Task.sleep(for: .seconds(15))
            }
        }
        defer {
            pinger.cancel()
            socket.cancel(with: .goingAway, reason: nil)
        }

        var receivedAny = false
        await withTaskCancellationHandler {
            do {
                for subscription in subscriptions {
                    try await socket.send(.string(#"{"method":"subscribe","subscription":\#(subscription.json)}"#))
                }
                while !Task.isCancelled {
                    let data: Data
                    switch try await socket.receive() {
                    case let .string(text): data = Data(text.utf8)
                    case let .data(raw): data = raw
                    @unknown default: continue
                    }
                    if !receivedAny {
                        receivedAny = true
                        continuation.yield(.connection(.live))
                    }
                    if let event = decode(data, pingSentAt: pingSentAt) {
                        continuation.yield(event)
                    }
                }
            } catch {
                // Fall through; the caller reconnects.
            }
        } onCancel: {
            socket.cancel(with: .goingAway, reason: nil)
        }
        return receivedAny
    }

    private static func decode(
        _ data: Data,
        pingSentAt: OSAllocatedUnfairLock<ContinuousClock.Instant?>
    ) -> HLEvent? {
        let decoder = JSONDecoder()
        guard let channel = try? decoder.decode(ChannelDTO.self, from: data).channel else { return nil }

        func payload<T: Decodable>(_ type: T.Type) -> T? {
            try? decoder.decode(DataDTO<T>.self, from: data).data
        }

        switch channel {
        case "l2Book":
            return payload(BookDTO.self).map { .book($0.model) }
        case "trades":
            return payload([TradeDTO].self).map { .trades($0.map(\.model)) }
        case "activeAssetCtx":
            return payload(ActiveCtxDTO.self).map { .ctx(coin: $0.coin, $0.ctx.model) }
        case "candle":
            return payload(CandleDTO.self).map { .candle($0.model) }
        case "allMids":
            return payload(AllMidsDTO.self).map { .mids($0.mids.compactMapValues(Double.init)) }
        case "pong":
            guard let sent = pingSentAt.withLock({ $0 }) else { return nil }
            let elapsed = ContinuousClock.now - sent
            return .latency(milliseconds: Int(elapsed / .milliseconds(1)))
        default:
            return nil
        }
    }
}
