import Foundation

/// Live state for the Perpetuals tab: one focused Hyperliquid market plus the market list.
@MainActor
final class PerpsModel: ObservableObject {
    // Market data
    @Published private(set) var markets: [HLMarket] = []
    @Published private(set) var coin: String
    @Published private(set) var ctx: HLAssetCtx?
    @Published private(set) var book: HLBook?
    @Published private(set) var trades: [HLTrade] = []
    @Published private(set) var candles: [HLCandle] = []
    @Published private(set) var interval: HLInterval = .m15
    @Published private(set) var grouping: HLBookGrouping = .full

    // Connection
    @Published private(set) var connection: HLConnectionState = .connecting
    @Published private(set) var latencyMs: Int?
    @Published private(set) var errorMessage: String?

    // Chart inspection
    /// Open time of the inspected candle; `nil` follows the live candle.
    @Published private(set) var cursorTime: Int64?
    @Published private(set) var candlePitch: CGFloat = 8
    /// Candles scrolled back from the live one; 0 keeps the newest candle at the right edge.
    @Published private(set) var chartOffset: CGFloat = 0
    @Published private(set) var priceZoom: CGFloat = 1
    @Published private(set) var pricePan: CGFloat = 0
    @Published var chartSettings = ChartSettings.load() {
        didSet { if chartSettings != oldValue { chartSettings.save() } }
    }
    /// Horizontal lines marked on this coin's chart.
    @Published private(set) var priceLines: [Double] = []
    /// Width of this tab's order ticket and book column. Each market tab keeps its own.
    @Published private(set) var sideWidth = 300.0

    /// Set when the tab shows a Solana token instead of a Hyperliquid perp. `coin` is then its symbol.
    let solana: SolanaToken?
    /// Liquidity, market cap and holders: the Solana header's figures.
    @Published private(set) var solanaStats: SolanaStats?

    /// What drawings, price lines and panel sizes are saved under.
    private var storageKey: String { solana.map { "sol:\($0.address)" } ?? coin }

    /// The candle lengths this market's data source serves.
    var intervals: [HLInterval] { solana == nil ? HLInterval.allCases : SolanaAPI.intervals }

    private static func savedSideWidth(_ coin: String) -> Double {
        let saved = UserDefaults.standard.double(forKey: "layout.sideWidth.\(coin)")
        return saved > 0 ? saved : 300
    }

    func setSideWidth(_ width: Double) {
        sideWidth = width
        UserDefaults.standard.set(width, forKey: "layout.sideWidth.\(storageKey)")
    }
    /// Trend lines and rays drawn on this coin's chart.
    @Published private(set) var drawings: [ChartDrawing] = []
    /// The drawing tool armed for the next drag or click; it disarms after one use.
    @Published private(set) var drawTool: DrawTool?
    @Published private(set) var isLoadingHistory = false

    // Overlays
    @Published var isHelpOpen = false
    /// Bumped to move the keyboard into the order ticket's size field.
    @Published var ticketFocusRequest = 0
    /// Set by ⇧B / ⇧S; the order ticket sends the order it describes. The count makes repeats distinct.
    @Published private(set) var orderHotkey: OrderHotkey?

    struct OrderHotkey: Equatable {
        let isBuy: Bool
        let count: Int
    }

    func requestOrder(isBuy: Bool) {
        orderHotkey = OrderHotkey(isBuy: isBuy, count: (orderHotkey?.count ?? 0) + 1)
    }

    private var streamTask: Task<Void, Never>?
    private var candleTask: Task<Void, Never>?
    private var marketsTask: Task<Void, Never>?
    private var historyTask: Task<Void, Never>?
    private var historyExhausted = false
    private var viewers = 0

    /// Called after the tab switches to a different market.
    var onCoinChange: (() -> Void)?
    /// Asks the workspace to open the ⌘P palette.
    var onFindMarket: (() -> Void)?

    init(coin: String = "ETH", solana: SolanaToken? = nil) {
        self.coin = solana?.symbol ?? coin
        self.solana = solana
        let key = solana.map { "sol:\($0.address)" } ?? coin
        priceLines = UserDefaults.standard.array(forKey: Self.linesKey(key)) as? [Double] ?? []
        sideWidth = Self.savedSideWidth(key)
        drawings = Self.loadDrawings(key)
    }

    static let maxTrades = 200
    private static let maxCandles = 12_000
    private static let pitchRange: ClosedRange<CGFloat> = 1.5...60

    // MARK: Derived

    var market: HLMarket? { solana == nil ? markets.first { $0.name == coin } : nil }

    var lastPrice: Double? {
        trades.first?.px ?? ctx?.midPx ?? ctx?.markPx
    }

    var dayChange: Double? {
        guard let ctx, ctx.prevDayPx > 0, let lastPrice else { return nil }
        return lastPrice / ctx.prevDayPx - 1
    }

    var priceDecimals: Int {
        // Solana tokens are often priced far below a cent: show about five significant figures.
        if solana != nil {
            guard let price = lastPrice, price > 0 else { return 4 }
            return min(max(4 - Int(floor(log10(price))), 2), 12)
        }
        return HLFormat.priceDecimals(for: lastPrice ?? 0, szDecimals: market?.szDecimals ?? 2)
    }

    var sizeDecimals: Int { market?.szDecimals ?? 2 }

    var inspectedCandle: HLCandle? {
        if let cursorTime, let match = candles.last(where: { $0.t == cursorTime }) { return match }
        return candles.last
    }

    // MARK: Lifecycle

    /// Called when a view of this market appears; starts streaming if it is not already live.
    func resume() {
        viewers += 1
        guard streamTask == nil else { return }
        reconnect()
    }

    /// Called when a view of this market disappears. Streaming stops once nothing shows it, so a tab
    /// dragged to another pane (whose new view can appear before the old one goes) keeps its connection.
    func pause() {
        viewers = max(viewers - 1, 0)
        if viewers == 0 { shutdown() }
    }

    /// Stops all network activity; the last data stays in place.
    func shutdown() {
        viewers = 0
        streamTask?.cancel()
        streamTask = nil
        candleTask?.cancel()
        marketsTask?.cancel()
        historyTask?.cancel()
        isLoadingHistory = false
        connection = .connecting
        latencyMs = nil
    }

    /// Drops the socket and reloads every snapshot.
    func reconnect() {
        errorMessage = nil
        reloadMarkets()
        reloadCandles()
        restartStream()
    }

    // MARK: Intents

    func select(coin newCoin: String) {
        guard solana == nil, newCoin != coin else { return }
        coin = newCoin
        ctx = markets.first { $0.name == newCoin }?.ctx
        book = nil
        trades = []
        resetChartData()
        priceLines = UserDefaults.standard.array(forKey: Self.linesKey(newCoin)) as? [Double] ?? []
        sideWidth = Self.savedSideWidth(newCoin)
        drawings = Self.loadDrawings(newCoin)
        drawTool = nil
        grouping = .full
        onCoinChange?()
        reloadCandles()
        restartStream()
    }

    func stepInterval(_ delta: Int) {
        let all = intervals
        guard let index = all.firstIndex(of: interval) else { return setInterval(all.first ?? .m15) }
        setInterval(all[min(max(index + delta, 0), all.count - 1)])
    }

    func setInterval(_ next: HLInterval) {
        guard next != interval, intervals.contains(next) else { return }
        interval = next
        resetChartData()
        reloadCandles()
        restartStream()
    }

    func cycleGrouping() {
        let all = HLBookGrouping.allCases
        guard solana == nil, let index = all.firstIndex(of: grouping) else { return }
        grouping = all[(index + 1) % all.count]
        restartStream()
    }

    /// Keyboard zoom: one step is 15% wider or narrower candles.
    func zoom(_ delta: CGFloat) {
        setViewport(pitch: candlePitch * pow(1.15, delta))
    }

    static func clampPitch(_ pitch: CGFloat) -> CGFloat {
        min(max(pitch, pitchRange.lowerBound), pitchRange.upperBound)
    }

    /// Candle width and how far the view is scrolled back from the live candle, in candles.
    func setViewport(pitch: CGFloat? = nil, offset: CGFloat? = nil) {
        if let pitch { candlePitch = Self.clampPitch(pitch) }
        if let offset { chartOffset = min(max(offset, -60), CGFloat(max(candles.count - 4, 0))) }
    }

    /// Manual price scale, relative to the automatic fit: `zoom` 1 and `pan` 0 is auto.
    func setPriceScale(zoom: CGFloat? = nil, pan: CGFloat? = nil) {
        if let zoom { priceZoom = min(max(zoom, 0.05), 40) }
        if let pan { pricePan = min(max(pan, -20), 20) }
    }

    func resetPriceScale() {
        priceZoom = 1
        pricePan = 0
    }

    var isAutoScaled: Bool { priceZoom == 1 && pricePan == 0 }

    /// Back to the newest candle with the price fitted.
    func goLive() {
        chartOffset = 0
        cursorTime = nil
        resetPriceScale()
    }

    func setStyle(_ style: ChartStyle) {
        chartSettings.style = style
    }

    func cycleStyle() {
        let all = ChartStyle.allCases
        guard let index = all.firstIndex(of: chartSettings.style) else { return }
        chartSettings.style = all[(index + 1) % all.count]
    }

    func toggle(_ indicator: ChartIndicator) {
        chartSettings.indicators.formSymmetricDifference([indicator])
    }

    /// Adds a horizontal price line, or removes the one within `tolerance` of `price`.
    func togglePriceLine(at price: Double, tolerance: Double) {
        if let index = priceLines.firstIndex(where: { abs($0 - price) <= tolerance }) {
            priceLines.remove(at: index)
        } else if price > 0 {
            priceLines.append(price)
        }
        UserDefaults.standard.set(priceLines, forKey: Self.linesKey(storageKey))
    }

    func clearPriceLines() {
        priceLines = []
        UserDefaults.standard.removeObject(forKey: Self.linesKey(storageKey))
    }

    func setDrawTool(_ tool: DrawTool?) {
        drawTool = tool
    }

    func addDrawing(_ drawing: ChartDrawing) {
        // A click without a drag is not a line.
        guard drawing.startTime != drawing.endTime || drawing.startPrice != drawing.endPrice else { return }
        drawings.append(drawing)
        saveDrawings()
    }

    func removeDrawing(_ id: UUID) {
        drawings.removeAll { $0.id == id }
        saveDrawings()
    }

    /// Removes every drawn line and horizontal price line on this coin.
    func clearDrawings() {
        drawings = []
        saveDrawings()
        clearPriceLines()
    }

    var hasDrawings: Bool { !drawings.isEmpty || !priceLines.isEmpty }

    private func saveDrawings() {
        if let data = try? JSONEncoder().encode(drawings) {
            UserDefaults.standard.set(data, forKey: "chart.drawings.\(storageKey)")
        }
    }

    private static func loadDrawings(_ coin: String) -> [ChartDrawing] {
        UserDefaults.standard.data(forKey: "chart.drawings.\(coin)")
            .flatMap { try? JSONDecoder().decode([ChartDrawing].self, from: $0) } ?? []
    }

    private static func linesKey(_ coin: String) -> String { "chart.lines.\(coin)" }

    /// Fetches the candles before the oldest one loaded. Called as the chart is scrolled back.
    func loadOlderCandles() {
        guard !isLoadingHistory, !historyExhausted, let first = candles.first else { return }
        isLoadingHistory = true
        let coin = coin
        let interval = interval
        let solana = solana
        historyTask = Task { [weak self] in
            let older: [HLCandle]? = if let solana {
                try? await SolanaAPI.bars(token: solana, interval: interval, end: first.t - 1, count: 1_000)
            } else {
                try? await HyperliquidAPI.candles(coin: coin, interval: interval, end: first.t - 1, count: 1_000)
            }
            guard let self, !Task.isCancelled, self.coin == coin, self.interval == interval else { return }
            self.isLoadingHistory = false
            let oldest = self.candles.first?.t ?? first.t
            let fresh = (older ?? []).filter { $0.t < oldest }
            if fresh.isEmpty {
                // Nothing older exists (or the request failed); stop asking until the market changes.
                self.historyExhausted = true
            } else {
                self.candles = fresh + self.candles
            }
        }
    }

    private func resetChartData() {
        historyTask?.cancel()
        isLoadingHistory = false
        historyExhausted = false
        candles = []
        cursorTime = nil
        chartOffset = 0
        resetPriceScale()
    }

    /// Moves the inspection cursor by whole candles. Stepping past the newest candle returns to live.
    func moveCursor(_ delta: Int) {
        guard !candles.isEmpty else { return }
        let current = cursorTime.flatMap { time in candles.lastIndex { $0.t == time } } ?? candles.count - 1
        let next = current + delta
        if next >= candles.count - 1 {
            cursorTime = cursorTime == nil || delta > 0 ? nil : candles[candles.count - 1].t
        } else {
            cursorTime = candles[max(next, 0)].t
        }
    }

    func setCursor(time: Int64?) {
        guard cursorTime != time else { return }
        cursorTime = time == candles.last?.t ? nil : time
    }

    // MARK: Loading

    private func reloadMarkets() {
        marketsTask?.cancel()
        guard solana == nil else { return }
        marketsTask = Task { [weak self] in
            do {
                let markets = try await HyperliquidAPI.markets()
                guard let self, !Task.isCancelled else { return }
                self.markets = markets
                if self.ctx == nil { self.ctx = self.market?.ctx }
            } catch {
                guard !Task.isCancelled else { return }
                self?.errorMessage = "markets: \(error.localizedDescription)"
            }
        }
    }

    private func reloadCandles() {
        candleTask?.cancel()
        let coin = coin
        let interval = interval
        let solana = solana
        candleTask = Task { [weak self] in
            do {
                let snapshot = if let solana {
                    try await SolanaAPI.bars(token: solana, interval: interval)
                } else {
                    try await HyperliquidAPI.candles(coin: coin, interval: interval)
                }
                guard let self, !Task.isCancelled, self.coin == coin, self.interval == interval else { return }
                // Keep history scrolled in earlier, and any candles the socket delivered since.
                let older = self.candles.filter { $0.t < (snapshot.first?.t ?? 0) }
                let newer = self.candles.filter { $0.t > (snapshot.last?.t ?? .max) }
                self.candles = older + snapshot + newer
                self.errorMessage = nil
            } catch {
                guard !Task.isCancelled else { return }
                self?.errorMessage = "candles: \(error.localizedDescription)"
            }
        }
    }

    private func restartStream() {
        streamTask?.cancel()
        connection = .connecting
        latencyMs = nil
        if let solana {
            if !intervals.contains(interval) { interval = .m15 }
            streamTask = Task { [weak self] in await self?.pollSolana(solana) }
            return
        }
        let subscriptions: [HLSubscription] = [
            .book(coin: coin, grouping: grouping),
            .trades(coin: coin),
            .ctx(coin: coin),
            .candle(coin: coin, interval: interval),
        ]
        streamTask = Task { [weak self] in
            for await event in HyperliquidSocket.events(subscriptions) {
                guard !Task.isCancelled else { return }
                self?.apply(event)
            }
        }
    }

    /// Solana has no socket here: the latest candles and swaps are fetched every two seconds,
    /// and the token's figures every six.
    private func pollSolana(_ token: SolanaToken) async {
        var round = 0
        while !Task.isCancelled {
            let interval = interval
            let started = ContinuousClock.now
            do {
                if round % 3 == 0, let stats = try await SolanaAPI.stats(address: token.address) {
                    guard !Task.isCancelled else { return }
                    solanaStats = stats
                    ctx = HLAssetCtx(
                        markPx: stats.price, midPx: stats.price, oraclePx: stats.price,
                        prevDayPx: stats.change24 > -1 ? stats.price / (1 + stats.change24) : 0,
                        dayNtlVlm: stats.volume24, openInterest: 0, funding: 0
                    )
                }
                async let latest = SolanaAPI.bars(token: token, interval: interval, count: 3)
                let pair = solanaStats?.pairAddress
                async let swaps: [HLTrade] = pair == nil ? [] : SolanaAPI.trades(pair: pair ?? "", symbol: token.symbol)
                let (bars, fresh) = try await (latest, swaps)
                guard !Task.isCancelled else { return }
                if self.interval == interval, !candles.isEmpty {
                    for bar in bars { apply(.candle(bar)) }
                }
                if !fresh.isEmpty { apply(.trades(fresh)) }
                connection = .live
                latencyMs = HyperliquidExchange.milliseconds(ContinuousClock.now - started)
                errorMessage = nil
            } catch {
                guard !Task.isCancelled else { return }
                connection = .reconnecting(attempt: 1)
                errorMessage = error.localizedDescription
            }
            round += 1
            try? await Task.sleep(for: .seconds(2))
        }
    }

    private func apply(_ event: HLEvent) {
        switch event {
        case let .connection(state):
            // A reconnect can miss candle closes, so backfill once the socket is live again.
            if state == .live, case .reconnecting = connection { reloadCandles() }
            connection = state
            if state != .live { latencyMs = nil }

        case let .latency(milliseconds):
            latencyMs = milliseconds

        case let .book(book):
            guard book.coin == coin else { return }
            self.book = book

        case let .trades(batch):
            let known = Set(trades.prefix(Self.maxTrades).map(\.tid))
            let fresh = batch
                .filter { $0.coin == coin && !known.contains($0.tid) }
                .sorted { $0.time > $1.time }
            guard !fresh.isEmpty else { return }
            trades = Array((fresh + trades).prefix(Self.maxTrades))

        case let .ctx(eventCoin, ctx):
            guard eventCoin == coin else { return }
            self.ctx = ctx

        case .mids:
            break

        case let .candle(candle):
            guard candle.coin == coin, candle.interval == interval.rawValue else { return }
            if let last = candles.last, last.t == candle.t {
                candles[candles.count - 1] = candle
            } else if candle.t > (candles.last?.t ?? 0) {
                candles.append(candle)
                // Hold a scrolled-back view on the same candles.
                if chartOffset > 0 { chartOffset += 1 }
                if candles.count > Self.maxCandles {
                    candles.removeFirst(candles.count - Self.maxCandles)
                }
            }
        }
    }
}

// MARK: - Formatting

enum HLFormat {
    /// Hyperliquid quotes perps to 5 significant figures, capped at `6 - szDecimals` decimals.
    static func priceDecimals(for price: Double, szDecimals: Int) -> Int {
        guard price > 0 else { return 2 }
        let integerDigits = max(Int(floor(log10(price))) + 1, 1)
        return max(0, min(6 - szDecimals, 5 - integerDigits))
    }

    static func price(_ value: Double, decimals: Int) -> String {
        value.formatted(.number.precision(.fractionLength(decimals)).grouping(.automatic).locale(posix))
    }

    static func size(_ value: Double, decimals: Int) -> String {
        if value >= 100_000 { return compact(value) }
        return value.formatted(.number.precision(.fractionLength(min(decimals, 4))).grouping(.never).locale(posix))
    }

    static func compact(_ value: Double) -> String {
        switch abs(value) {
        case 1_000_000_000...: String(format: "%.2fB", value / 1_000_000_000)
        case 1_000_000...: String(format: "%.2fM", value / 1_000_000)
        case 1_000...: String(format: "%.1fK", value / 1_000)
        default: String(format: "%.2f", value)
        }
    }

    static func percent(_ fraction: Double, decimals: Int = 2) -> String {
        String(format: "%+.\(decimals)f%%", fraction * 100)
    }

    static func tick(_ value: Double) -> String {
        value >= 1 ? String(format: "%.0f", value) : String(format: "%g", value)
    }

    static func clock(_ milliseconds: Int64) -> String {
        Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
            .formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits).locale(clock24))
    }

    static func countdown(to date: Date, from now: Date) -> String {
        let seconds = max(Int(date.timeIntervalSince(now)), 0)
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private static let posix = Locale(identifier: "en_US_POSIX")
    static let clock24 = Locale(identifier: "en_GB")
}
