import Foundation
import Observation

/// Live state for the Perpetuals tab: one focused Hyperliquid market plus the market list.
@MainActor
/// Observed property by property: a view is redrawn only when a value it actually reads changes, so a new
/// order book redraws the book and nothing else. (With one change signal for the whole model, every tick
/// recomputed the entire pane.)
@Observable
final class PerpsModel {
    // Market data
    private(set) var markets: [HLMarket] = []
    private(set) var coin: String
    private(set) var ctx: HLAssetCtx?
    private(set) var book: HLBook?
    private(set) var trades: [HLTrade] = []
    private(set) var candles: [HLCandle] = []
    private(set) var interval: HLInterval = .m15
    private(set) var grouping: HLBookGrouping = .full

    // Connection
    private(set) var connection: HLConnectionState = .connecting
    private(set) var latencyMs: Int?
    private(set) var errorMessage: String?

    // Chart inspection
    /// Open time of the inspected candle; `nil` follows the live candle.
    private(set) var cursorTime: Int64?
    private(set) var candlePitch: CGFloat = 8
    /// Candles scrolled back from the live one; 0 keeps the newest candle at the right edge.
    private(set) var chartOffset: CGFloat = 0
    private(set) var priceZoom: CGFloat = 1
    private(set) var pricePan: CGFloat = 0
    var chartSettings = ChartSettings.load() {
        didSet { if chartSettings != oldValue { chartSettings.save() } }
    }
    /// Horizontal lines marked on this coin's chart.
    private(set) var priceLines: [Double] = []
    /// Width of this tab's order ticket and book column. Each market tab keeps its own.
    private(set) var sideWidth = 300.0

    /// Set when the tab shows a Solana token instead of a Hyperliquid perp. `coin` is then its symbol.
    /// A token named without a pool is settled on its main pool as the tab starts.
    private(set) var solana: SolanaToken?
    /// The token's other pools, most traded first: each can be opened as its own tab.
    private(set) var solanaPools: [SolanaStats] = []
    /// Liquidity, market cap and holders: the Solana header's figures.
    private(set) var solanaStats: SolanaStats?
    /// True while swaps are arriving over the socket rather than only by polling.
    private(set) var isSolanaStreaming = false
    /// When the newest swap folded into the candles happened.
    private var lastSwapTime: Int64 = 0
    /// The last three swap prices as they came, for telling a stray print from a move.
    private var swapPrices: [Double] = []
    /// The steadied price of each swap in the last seconds: what Codex's own candle may not hold yet.
    private var liveSwaps: [(time: Int64, px: Double)] = []
    private static let liveSwapWindow: Int64 = 15_000

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
    private(set) var drawings: [ChartDrawing] = []
    /// The drawing tool armed for the next drag or click; it disarms after one use.
    private(set) var drawTool: DrawTool?
    private(set) var isLoadingHistory = false

    // Overlays
    var isHelpOpen = false
    /// Bumped to move the keyboard into the order ticket's size field.
    var ticketFocusRequest = 0
    /// Set by ⇧B / ⇧S; the order ticket sends the order it describes. The count makes repeats distinct.
    private(set) var orderHotkey: OrderHotkey?

    struct OrderHotkey: Equatable {
        let isBuy: Bool
        let count: Int
    }

    func requestOrder(isBuy: Bool) {
        orderHotkey = OrderHotkey(isBuy: isBuy, count: (orderHotkey?.count ?? 0) + 1)
    }

    private var streamTask: Task<Void, Never>?
    private var pendingEvents: [HLEvent] = []
    private var eventFlush: Task<Void, Never>?

    /// Live data arrives many times a second, and every piece that changes redraws part of the pane.
    /// It is gathered and shown together ten times a second: nothing is dropped, and the screen is drawn once per batch.
    private func enqueue(_ event: HLEvent) {
        switch event {
        case .connection, .latency:
            apply(event)
        default:
            pendingEvents.append(event)
            guard eventFlush == nil else { return }
            eventFlush = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(100))
                guard let self else { return }
                self.eventFlush = nil
                let batch = self.pendingEvents
                self.pendingEvents.removeAll(keepingCapacity: true)
                // Only the newest order book of the batch matters; trades and candles are all applied, in order.
                let lastBook = batch.lastIndex { if case .book = $0 { true } else { false } }
                for (index, event) in batch.enumerated() {
                    if case .book = event, index != lastBook { continue }
                    self.apply(event)
                }
            }
        }
    }
    private var candleTask: Task<Void, Never>?
    private var marketsTask: Task<Void, Never>?
    private var historyTask: Task<Void, Never>?
    private var historyExhausted = false
    private var viewers = 0

    /// Called after the tab switches to a different market.
    var onCoinChange: (() -> Void)?
    /// Opens a link from the token's details in a web tab.
    var onOpenLink: ((URL) -> Void)?
    /// Opens another pool of the token in its own tab.
    var onOpenMarket: ((SolanaToken) -> Void)?
    /// A short line shown over the chart for a few seconds: what a key or menu just did.
    private(set) var notice: String?
    private var noticeTask: Task<Void, Never>?
    /// Where the chart was right-clicked, and the price there: its menu is open while this is set.
    var chartMenu: ChartMenuRequest?
    /// What a Solana token is beyond its price: safety figures and links.
    private(set) var solanaDetails: SolanaTokenDetails?

    struct ChartMenuRequest: Equatable {
        let point: CGPoint
        let price: Double
        /// How far, in price, counts as "on" a line at this zoom.
        let tolerance: Double
    }

    func notify(_ text: String) {
        notice = text
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3.5))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }
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
        // On Solana the chart's price, which ignores a stray print from a thin pool.
        liveSwaps.last?.px ?? trades.first?.px ?? ctx?.midPx ?? ctx?.markPx
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
                Launch.chartIsReady(self.coin, candles: self.candles.count)
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
                self?.enqueue(event)
            }
        }
    }

    /// The pool's swaps arrive live over Codex's socket and move the price, the tape and the forming candle as they happen.
    private func streamSolana(_ token: SolanaToken, pool: String) async {
        var failures = 0
        while !Task.isCancelled {
            guard let key = KeychainStore().readAPIKey() else {
                try? await Task.sleep(for: .milliseconds(500))
                continue
            }
            do {
                for try await payload in CodexClient().eventStream(pair: pool, apiKey: key) {
                    guard !Task.isCancelled else { return }
                    let fresh = try SolanaAPI.liveTrades(in: payload, symbol: token.symbol, mint: token.address, decimals: solanaStats?.decimals)
                    guard !fresh.isEmpty else { continue }
                    if !isSolanaStreaming { HyperliquidExchange.log("solana stream \(token.pairName): live") }
                    failures = 0
                    isSolanaStreaming = true
                    let unseen = unseen(fresh)
                    apply(.trades(fresh))
                    fold(unseen, addingVolume: true)
                }
            } catch {
                if failures == 0 { HyperliquidExchange.log("solana stream \(token.pairName): \(error.localizedDescription)") }
            }
            isSolanaStreaming = false
            failures += 1
            try? await Task.sleep(for: .seconds(min(Double(failures) * 2, 20)))
        }
    }

    /// The swaps in a batch the tape does not hold yet.
    private func unseen(_ batch: [HLTrade]) -> [HLTrade] {
        let known = Set(trades.prefix(Self.maxTrades).map(\.tid))
        return batch.filter { $0.coin == coin && !known.contains($0.tid) }
    }

    /// Folds swaps into the candles, oldest first, so the chart's price is always the tape's newest.
    /// Volume is added only for swaps Codex's own candle cannot have counted yet.
    private func fold(_ swaps: [HLTrade], addingVolume: Bool) {
        for trade in swaps.sorted(by: { $0.time < $1.time }) { extendCandle(with: trade, addingVolume: addingVolume) }
    }

    /// Folds one swap into the candle it belongs to, starting the next candle when its time has come.
    private func extendCandle(with trade: HLTrade, addingVolume: Bool) {
        // A swap read late is left to Codex's own candle: it must not move the close back behind a newer one.
        guard let last = candles.last, trade.px > 0, trade.time >= lastSwapTime else { return }
        lastSwapTime = trade.time
        let px = steadied(trade.px)
        liveSwaps.append((trade.time, px))
        liveSwaps.removeAll { $0.time < trade.time - Self.liveSwapWindow }
        let length = interval.milliseconds
        let bucket = trade.time / length * length
        let volume = addingVolume ? trade.px * trade.sz : 0
        if bucket == last.t {
            apply(.candle(HLCandle(
                t: last.t, coin: last.coin, interval: last.interval, o: last.o,
                h: max(last.h, px), l: min(last.l, px), c: px, v: last.v + volume
            )))
        } else if bucket > last.t {
            apply(.candle(HLCandle(
                t: bucket, coin: last.coin, interval: last.interval, o: last.c,
                h: max(last.c, px), l: min(last.c, px), c: px, v: volume
            )))
        }
    }

    /// Swaps come from every pool of the token, and a thin or oddly priced one can print far from the market.
    /// A price close to the one before is taken as it is; a jump has to be repeated by the next swap before the chart follows it.
    private func steadied(_ price: Double) -> Double {
        let previous = swapPrices.last
        swapPrices = Array((swapPrices + [price]).suffix(3))
        guard let previous, swapPrices.count == 3, abs(price / previous - 1) > 0.01 else { return price }
        return swapPrices.sorted()[1]
    }

    /// Codex's candles trail its swaps by a few seconds, so a re-read alone would drop the newest highs and lows
    /// and pull the close back. The last seconds' swaps are laid over it until the candle has closed.
    private func keepingLiveSwaps(_ bar: HLCandle) -> HLCandle {
        let end = bar.t + interval.milliseconds
        let inside = liveSwaps.filter { $0.time >= bar.t && $0.time < end }.map(\.px)
        guard let newest = inside.last, Int64(Date().timeIntervalSince1970 * 1_000) < end + Self.liveSwapWindow else { return bar }
        return HLCandle(
            t: bar.t, coin: bar.coin, interval: bar.interval, o: bar.o,
            h: max(bar.h, inside.max() ?? newest), l: min(bar.l, inside.min() ?? newest), c: newest, v: bar.v
        )
    }

    /// Alongside the live swaps, candles and the tape are re-read every few seconds so nothing drifts,
    /// and the token's figures every nine.
    private func pollSolana(_ named: SolanaToken) async {
        // A token named without a pool (a holding, a watchlist row, an older saved tab) goes to its main pool.
        var token = named
        while token.pool == nil {
            do {
                guard let found = try await SolanaAPI.mainPool(mint: token.address)?.token.pool else {
                    throw CodexError.graphQL("No pool trades \(token.symbol).")
                }
                guard !Task.isCancelled else { return }
                token.pool = found
                solana = token
                // The saved layout names the pool from here on, and the chart shows its candles.
                onCoinChange?()
                reloadCandles()
            } catch {
                guard !Task.isCancelled else { return }
                connection = .reconnecting(attempt: 1)
                errorMessage = error.localizedDescription
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
            }
        }
        guard let pool = token.pool else { return }
        let live = Task { [weak self] in await self?.streamSolana(token, pool: pool.address) }
        defer {
            live.cancel()
            isSolanaStreaming = false
        }
        var round = 0
        while !Task.isCancelled {
            let interval = interval
            let started = ContinuousClock.now
            do {
                // Safety figures, links and the token's other pools change rarely: read at the start, then each minute.
                if round % 20 == 0 {
                    if let details = try? await SolanaAPI.details(address: token.address) { solanaDetails = details }
                    if let pools = try? await SolanaAPI.pools(mint: token.address) {
                        solanaPools = pools.filter { $0.pairAddress != pool.address }
                    }
                }
                if round % 3 == 0 {
                    // Liquidity, volume and price are this pool's; market cap and holders are the token's.
                    async let ofToken = SolanaAPI.stats(address: token.address)
                    async let ofPool = SolanaAPI.pool(address: pool.address, base: token.address)
                    let (whole, own) = try await (ofToken, ofPool)
                    guard !Task.isCancelled else { return }
                    if var stats = whole ?? own {
                        stats.token = token
                        stats.pairAddress = pool.address
                        if let own {
                            stats.liquidity = own.liquidity
                            stats.volume24 = own.volume24
                            if own.price > 0 {
                                stats.price = own.price
                                stats.change24 = own.change24
                            }
                            stats.exchanges = own.exchanges
                        }
                        solanaStats = stats
                        ctx = HLAssetCtx(
                            markPx: stats.price, midPx: stats.price, oraclePx: stats.price,
                            prevDayPx: stats.change24 > -1 ? stats.price / (1 + stats.change24) : 0,
                            dayNtlVlm: stats.volume24, openInterest: 0, funding: 0
                        )
                    }
                }
                async let latest = SolanaAPI.bars(token: token, interval: interval, count: 3)
                let decimals = solanaStats?.decimals
                async let swaps: [HLTrade] = SolanaAPI.trades(pair: pool.address, symbol: token.symbol, mint: token.address, decimals: decimals)
                let (bars, fresh) = try await (latest, swaps)
                guard !Task.isCancelled else { return }
                // The tape first: the candles take their close from it.
                let unseen = unseen(fresh)
                if !fresh.isEmpty { apply(.trades(fresh)) }
                if self.interval == interval, !candles.isEmpty {
                    for bar in bars { apply(.candle(keepingLiveSwaps(bar))) }
                    fold(unseen, addingVolume: false)
                }
                connection = .live
                latencyMs = HyperliquidExchange.milliseconds(ContinuousClock.now - started)
                errorMessage = nil
            } catch {
                guard !Task.isCancelled else { return }
                connection = .reconnecting(attempt: 1)
                errorMessage = error.localizedDescription
            }
            round += 1
            try? await Task.sleep(for: .seconds(3))
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
            if self.book != book { self.book = book }

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
            } else if let index = candles.lastIndex(where: { $0.t <= candle.t }), candles[index].t == candle.t {
                // A candle that has closed, re-read with its final figures.
                candles[index] = candle
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

    /// A token amount of any scale: large ones shortened, small ones with enough places to mean something.
    static func amount(_ value: Double) -> String {
        switch abs(value) {
        case 100_000...: compact(value)
        case 1...: size(value, decimals: 2)
        case 0.01...: size(value, decimals: 4)
        default: size(value, decimals: 6)
        }
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
