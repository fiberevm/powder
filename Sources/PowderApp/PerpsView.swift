import SwiftUI

struct PerpsView: View {
    let model: PerpsModel
    @EnvironmentObject private var wallets: WalletProvider
    @EnvironmentObject private var alerts: AlertStore
    @EnvironmentObject private var triggers: SolanaTriggerStore

    /// Below this width the book and trades move under the chart instead of beside it.
    private static let wideThreshold: CGFloat = 760

    /// Dragged at the dividers. The side column's width belongs to the tab (it lives on the model);
    /// these two heights are shared by every market tab.
    @AppStorage("layout.tradesHeight") private var tradesHeight = 220.0
    @AppStorage("layout.lowerHeight") private var lowerHeight = 300.0
    @State private var dragStart = 0.0

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                MarketHeader(model: model)
                TermRule()

                if geometry.size.width >= Self.wideThreshold {
                    HStack(alignment: .top, spacing: 0) {
                        chart
                        ResizeHandle(vertical: true) { start, translation in
                            if start { dragStart = model.sideWidth }
                            model.setSideWidth(min(max(dragStart - translation, 220), max(geometry.size.width - 320, 220)))
                        }
                        VStack(spacing: 0) {
                            if model.solana != nil {
                                // No order book on a Solana pool: the column is the ticket, the token's figures and its swaps.
                                // Shown whole when there is room; in a short pane it scrolls so the chart keeps its place.
                                ViewThatFits(in: .vertical) {
                                    solanaSide
                                    ScrollView { solanaSide }
                                }
                                .layoutPriority(1)
                                TermRule()
                                trades.frame(minHeight: 120)
                            } else {
                                OrderTicket(model: model)
                                TermRule()
                                book
                                ResizeHandle(vertical: false) { start, translation in
                                    if start { dragStart = tradesHeight }
                                    tradesHeight = min(max(dragStart - translation, 80), max(geometry.size.height - 260, 80))
                                }
                                trades.frame(height: min(tradesHeight, max(geometry.size.height - 260, 80)))
                            }
                        }
                        .frame(width: min(model.sideWidth, max(geometry.size.width - 320, 220)))
                    }
                } else {
                    chart
                    ResizeHandle(vertical: false) { start, translation in
                        if start { dragStart = lowerHeight }
                        lowerHeight = min(max(dragStart - translation, 100), max(geometry.size.height - 240, 100))
                    }
                    HStack(alignment: .top, spacing: 0) {
                        if model.solana != nil {
                            ScrollView {
                                VStack(spacing: 0) {
                                    SolanaTicket(model: model)
                                    TermRule()
                                    SolanaInfoPanel(model: model)
                                }
                            }
                            .frame(width: min(max(geometry.size.width * 0.38, 220), 300))
                            TermRule(vertical: true)
                            trades
                        } else {
                            OrderTicket(model: model)
                                .frame(width: min(max(geometry.size.width * 0.38, 220), 300))
                            TermRule(vertical: true)
                            book
                            // The narrowest panes give the trades column up to the ticket.
                            if geometry.size.width >= 600 {
                                TermRule(vertical: true)
                                trades
                            }
                        }
                    }
                    .frame(height: min(lowerHeight, max(geometry.size.height - 240, 100)))
                    .clipped()
                }

                TermRule()
                StatusBar(model: model)
                    .background(Term.chrome)
            }
        }
        .foregroundStyle(Term.foreground)
        .background(Term.background)
        .overlay {
            if model.isHelpOpen {
                KeyHelp()
            }
        }
        .onAppear { model.resume() }
        .onDisappear { model.pause() }
    }

    private var marketRef: MarketRef { model.solana.map(MarketRef.solana) ?? .perp(model.coin) }

    /// The selected wallet's resting orders in this market.
    private var restingOrders: [HLOpenOrder] {
        guard model.solana == nil, let id = wallets.selectedID else { return [] }
        return wallets.accounts[id]?.orders.filter { $0.coin == model.coin } ?? []
    }

    /// Everything of the user's drawn across the chart: position, resting orders, alerts.
    private var chartLevels: [ChartLevel] {
        var levels = positionLevels
        for order in restingOrders {
            levels.append(ChartLevel(
                kind: order.isBuy ? .orderBuy : .orderSell, price: order.price,
                label: "\(order.isBuy ? "BUY" : "SELL") \(HLWire.number(order.size)) · LIMIT"
            ))
        }
        for alert in alerts.alerts(for: marketRef) {
            levels.append(ChartLevel(kind: .alert, price: alert.price, label: "ALERT \(alert.isAbove ? "↑" : "↓")"))
        }
        if let token = model.solana {
            for trigger in triggers.active(walletID: wallets.selectedID, mint: token.address) {
                levels.append(ChartLevel(
                    kind: trigger.kind == .stopLoss ? .stopLoss : .takeProfit, price: trigger.price,
                    label: "\(trigger.kind.title.uppercased()) · SELL ALL"
                ))
            }
        }
        return levels
    }

    private func closeChartMenu() {
        model.chartMenu = nil
        DropdownCenter.dismiss = nil
    }

    /// What a right-click on the chart offers at that price.
    private var chartMenuItems: [DropdownItem] {
        guard let request = model.chartMenu else { return [] }
        let price = request.price
        let shown = HLFormat.price(price, decimals: model.priceDecimals)
        var items: [DropdownItem] = []

        // The drawing under the pointer comes first, then lines there: what is there can be changed or taken away.
        if let id = request.drawing, let drawing = model.drawings.first(where: { $0.id == id }) {
            items.append(DropdownItem("Delete \(drawing.kind.title.lowercased())", id: "drawing-delete", detail: "⌫") {
                closeChartMenu()
                model.removeDrawing(id)
            })
            items.append(DropdownItem("Duplicate", id: "drawing-duplicate") {
                closeChartMenu()
                model.duplicateDrawing(id)
            })
            for (index, tint) in ChartDrawing.tints.enumerated() {
                items.append(DropdownItem(
                    "Colour: \(tint.name)", id: "drawing-colour-\(index)", isSelected: (drawing.color ?? 0) == index, startsSection: index == 0
                ) {
                    closeChartMenu()
                    model.setDrawingColor(id, to: index)
                })
            }
        }
        let drawingItems = items.count
        for order in restingOrders where abs(order.price - price) <= request.tolerance {
            items.append(DropdownItem(
                "Cancel \(order.isBuy ? "buy" : "sell") \(HLWire.number(order.size)) at \(HLFormat.price(order.price, decimals: model.priceDecimals))",
                id: "cancel:\(order.id)", startsSection: items.count == drawingItems && drawingItems > 0
            ) {
                closeChartMenu()
                cancel(order)
            })
        }
        for alert in alerts.alerts(for: marketRef) where abs(alert.price - price) <= request.tolerance {
            items.append(DropdownItem(
                "Remove alert at \(HLFormat.price(alert.price, decimals: model.priceDecimals))",
                id: "alert:\(alert.id)", startsSection: items.count == drawingItems && drawingItems > 0
            ) {
                closeChartMenu()
                alerts.remove(alert.id)
            })
        }

        if let wallet = wallets.selected, let market = model.market, price > 0 {
            // A limit order of the wallet's default size, resting at the clicked price.
            let size = HLWire.size(wallet.settings.defaultSizeUSD / price, szDecimals: market.szDecimals)
            let amount = "\(HLWire.number(size)) \(model.coin)"
            for isBuy in [true, false] {
                items.append(DropdownItem(
                    "\(isBuy ? "Buy" : "Sell") limit \(amount) at \(shown)", id: isBuy ? "buy" : "sell",
                    detail: "$" + HLFormat.price(size * price, decimals: 0), isDisabled: size <= 0, startsSection: isBuy && !items.isEmpty
                ) {
                    closeChartMenu()
                    placeLimit(wallet: wallet, market: market, isBuy: isBuy, size: size, price: price)
                })
            }
        }
        if let token = model.solana, let id = wallets.selectedID {
            for trigger in triggers.active(walletID: id, mint: token.address) where abs(trigger.price - price) <= request.tolerance {
                items.append(DropdownItem("Remove \(trigger.kind.title.lowercased()) at \(HLFormat.price(trigger.price, decimals: model.priceDecimals))", id: "trigger:\(trigger.id)") {
                    closeChartMenu()
                    triggers.remove(trigger.id)
                })
            }
            // Below the price a click sets the stop, above it the target. Only for something actually held.
            if (wallets.solana.balances[id]?.holding(token.address)?.raw ?? 0) > 0, let last = model.lastPrice, price != last {
                let kind: SolanaTrigger.Kind = price < last ? .stopLoss : .takeProfit
                items.append(DropdownItem(
                    "\(kind.title): sell all if price \(kind == .stopLoss ? "falls" : "rises") to \(shown)", id: "trigger",
                    detail: HLFormat.percent(price / last - 1), startsSection: !items.isEmpty
                ) {
                    closeChartMenu()
                    model.notify(triggers.set(kind, walletID: id, token: token, price: price, current: last) ?? "\(kind.title) set at \(shown)")
                })
            }
        }
        items.append(DropdownItem("Alert when price reaches \(shown)", id: "alert", detail: "🔔", startsSection: !items.isEmpty) {
            closeChartMenu()
            if alerts.add(marketRef, price: price, current: model.lastPrice) != nil {
                model.notify("Alert set at \(shown)")
            }
        })
        let hasLine = model.priceLines.contains { abs($0 - price) <= request.tolerance }
        items.append(DropdownItem(hasLine ? "Remove price line" : "Draw a price line here", id: "line", detail: "⌥ click") {
            closeChartMenu()
            model.togglePriceLine(at: price, tolerance: request.tolerance)
        })
        if restingOrders.count > 1 {
            items.append(DropdownItem("Cancel all \(restingOrders.count) \(model.coin) orders", id: "cancel-all", startsSection: true) {
                closeChartMenu()
                Task {
                    model.notify(await wallets.cancelAll(walletID: wallets.selectedID, coin: model.coin))
                }
            })
        }
        return items
    }

    private func placeLimit(wallet: Wallet, market: HLMarket, isBuy: Bool, size: Double, price: Double) {
        Task {
            do {
                let order = try wallets.prepare(
                    wallet: wallet, market: market, isBuy: isBuy, size: size,
                    limitPrice: price, referencePrice: model.lastPrice, reduceOnly: false
                )
                let outcome = try await wallets.send(order)
                OrderSound.done()
                let at = HLFormat.price(order.price, decimals: model.priceDecimals)
                if case let .filled(filled, fill) = outcome {
                    // A limit past the market trades at once.
                    model.notify("Filled \(HLWire.number(filled)) \(model.coin) at \(HLFormat.price(fill, decimals: model.priceDecimals))")
                } else {
                    model.notify("\(isBuy ? "Buy" : "Sell") limit \(HLWire.number(order.size)) \(model.coin) resting at \(at)")
                }
            } catch {
                OrderSound.failed()
                model.notify(error.localizedDescription)
            }
        }
    }

    private func cancel(_ order: HLOpenOrder) {
        guard let market = model.market, let id = wallets.selectedID else { return }
        Task {
            do {
                try await wallets.cancel(order, asset: market.index, walletID: id)
                model.notify("Order cancelled")
            } catch {
                model.notify(error.localizedDescription)
            }
        }
    }

    /// Entry and liquidation of the selected wallet's position in this market.
    private var positionLevels: [ChartLevel] {
        if let token = model.solana {
            // A Solana holding: one line at the average price paid, with what it is worth against that.
            let solana = wallets.solana
            guard let id = solana.selectedID, let holding = solana.balances[id]?.holding(token.address),
                  let cost = solana.costs[SolanaWalletProvider.costKey(id, token.address)] else { return [] }
            var label = "HOLD \(HLFormat.amount(holding.amount)) \(token.symbol) · AVG ENTRY"
            if let price = model.lastPrice, cost > 0 {
                label += " · \(PositionsView.signed((price - cost) * holding.amount)) (\(HLFormat.percent(price / cost - 1)))"
            }
            return [ChartLevel(kind: .entryLong, price: cost, label: label)]
        }
        guard model.solana == nil, let id = wallets.selectedID,
              let position = wallets.accounts[id]?.positions.first(where: { $0.coin == model.coin }) else { return [] }
        let isLong = position.size > 0
        var levels = [ChartLevel(
            kind: isLong ? .entryLong : .entryShort, price: position.entryPrice,
            label: "\(isLong ? "LONG" : "SHORT") \(HLWire.number(abs(position.size))) · ENTRY"
        )]
        if let liquidation = position.liquidationPrice, liquidation > 0 {
            levels.append(ChartLevel(kind: .liquidation, price: liquidation, label: "LIQUIDATION"))
        }
        return levels
    }

    private var solanaSide: some View {
        VStack(spacing: 0) {
            SolanaTicket(model: model)
            TermRule()
            SolanaInfoPanel(model: model)
        }
    }

    private var chart: some View {
        VStack(spacing: 0) {
            ChartHeader(model: model)
            TermRule()
            PerpChart(
                model: model,
                candles: model.chartCandles,
                cursorTime: model.cursorTime,
                pitch: model.candlePitch,
                offset: model.chartOffset,
                priceZoom: model.priceZoom,
                pricePan: model.pricePan,
                decimals: model.priceDecimals,
                interval: model.interval,
                settings: model.chartSettings,
                priceLines: model.priceLines,
                levels: chartLevels,
                drawings: model.drawings,
                drawTool: model.drawTool,
                selectedDrawing: model.selectedDrawing,
                isReplay: model.replayTime != nil,
                snapshotRequest: model.snapshotRequest,
                isLoadingHistory: model.isLoadingHistory
            )
            .equatable()
            .termMenu(isOpen: model.chartMenu != nil, at: model.chartMenu?.point, items: chartMenuItems, minWidth: 260) { closeChartMenu() }
            .overlay(alignment: .top) {
                if let notice = model.notice {
                    Text(notice)
                        .font(Term.font(11, .semibold))
                        .foregroundStyle(PowderPalette.graphite)
                        .lineLimit(2)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Term.accent)
                        .padding(.top, 8)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
            }
            .animation(.easeOut(duration: 0.15), value: model.notice)
        }
    }

    private var book: some View {
        OrderBookPanel(
            book: model.book,
            lastPrice: model.lastPrice,
            lastIsBuy: model.trades.first?.isBuy,
            grouping: model.grouping,
            coin: model.coin,
            priceDecimals: model.priceDecimals,
            sizeDecimals: model.sizeDecimals
        )
        .equatable()
    }

    private var trades: some View {
        TradesPanel(
            trades: model.trades,
            priceDecimals: model.priceDecimals,
            sizeDecimals: model.sizeDecimals
        )
        .equatable()
    }
}

// MARK: - Market header

private struct MarketHeader: View {
    let model: PerpsModel

    var body: some View {
        HStack(alignment: .center, spacing: 22) {
            Button {
                model.onFindMarket?()
            } label: {
                HStack(spacing: 8) {
                    Text(model.solana.map { $0.pool == nil ? "\($0.symbol)/USD" : $0.pairName } ?? "\(model.coin)/USDC")
                        .font(Term.font(16, .bold))
                    if let leverage = model.market?.maxLeverage {
                        Text("\(leverage)x")
                            .font(Term.font(10, .semibold))
                            .foregroundStyle(PowderPalette.scopeBlue)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .fixedSize()
            .help("Switch market ( / )")
            .accessibilityLabel("\(model.coin) USDC perpetual. Switch market")

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                TickingPrice(
                    value: model.lastPrice,
                    text: model.lastPrice.map { HLFormat.price($0, decimals: model.priceDecimals) } ?? "—",
                    font: Term.font(20, .semibold),
                    color: changeColor
                )
                Text(model.dayChange.map { HLFormat.percent($0) } ?? "")
                    .font(Term.font(12, .medium))
                    .foregroundStyle(changeColor)
            }
            .fixedSize()

            if let ctx = model.ctx {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    // Offer progressively shorter stat rows so a narrow pane drops stats instead of clipping them.
                    ViewThatFits(in: .horizontal) {
                        ForEach([5, 3, 2, 1, 0], id: \.self) { count in
                            HStack(spacing: 22) {
                                ForEach(Array(stats(ctx, now: context.date).prefix(count).enumerated()), id: \.offset) { _, stat in
                                    stat
                                }
                                Spacer(minLength: 0)
                            }
                        }
                    }
                }
            } else {
                Spacer(minLength: 0)
            }

            // What kind of market this is, in the header's top right corner.
            Text(model.solana == nil ? "PERP" : "SOLANA")
                .font(Term.font(10, .semibold))
                .foregroundStyle(.secondary)
                .fixedSize()
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(.top, 8)
        }
        .lineLimit(1)
        .padding(.horizontal, 12)
        .frame(height: 50)
    }

    /// Ordered by how much a trader loses when it is dropped: the last entries go first.
    private func stats(_ ctx: HLAssetCtx, now: Date) -> [Stat] {
        if model.solana != nil {
            let stats = model.solanaStats
            return [
                Stat("MKT CAP", stats.map { "$" + HLFormat.compact($0.marketCap) } ?? "—"),
                Stat("LIQUIDITY", stats.map { "$" + HLFormat.compact($0.liquidity) } ?? "—"),
                Stat("24H VOL", "$" + HLFormat.compact(ctx.dayNtlVlm)),
                Stat("EXCHANGE", model.solana?.pool?.exchange ?? "—"),
                Stat("HOLDERS", stats?.holders.map { HLFormat.compact(Double($0)).replacingOccurrences(of: ".00", with: "") } ?? "—"),
            ]
        }
        return [
            Stat("MARK", HLFormat.price(ctx.markPx, decimals: model.priceDecimals)),
            Stat(
                "FUNDING / NEXT",
                HLFormat.percent(ctx.funding, decimals: 4) + "  " + Self.fundingCountdown(now),
                color: ctx.funding >= 0 ? PowderPalette.signalGreen : PowderPalette.riskCoral
            ),
            Stat("24H VOL", "$" + HLFormat.compact(ctx.dayNtlVlm)),
            Stat("OPEN INT", "$" + HLFormat.compact(ctx.openInterest * ctx.markPx)),
            Stat("ORACLE", HLFormat.price(ctx.oraclePx, decimals: model.priceDecimals)),
        ]
    }

    private var changeColor: Color {
        guard let change = model.dayChange else { return Term.foreground }
        return PowderPalette.market(change)
    }

    /// Hyperliquid settles funding at the top of every hour.
    private static func fundingCountdown(_ now: Date) -> String {
        let next = (now.timeIntervalSince1970 / 3_600).rounded(.down) * 3_600 + 3_600
        return HLFormat.countdown(to: Date(timeIntervalSince1970: next), from: now)
    }
}

private struct Stat: View {
    let label: String
    let value: String
    var color: Color = Term.foreground

    init(_ label: String, _ value: String, color: Color = Term.foreground) {
        self.label = label
        self.value = value
        self.color = color
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(Term.font(9.5))
                .foregroundStyle(.secondary)
            Text(value)
                .font(Term.font(12, .medium))
                .foregroundStyle(color)
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

private struct KeyCap: View {
    let key: String

    init(_ key: String) { self.key = key }

    var body: some View {
        Text(key)
            .font(Term.font(10, .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .overlay(Rectangle().stroke(Term.rule, lineWidth: 1))
    }
}

// MARK: - Chart header

private struct ChartHeader: View {
    let model: PerpsModel

    /// Shown as buttons; the rest are in the "more" menu.
    private static let favorites: [HLInterval] = [.m1, .m5, .m15, .h1, .h4, .d1]

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 0) {
                ForEach(shownIntervals, id: \.self) { interval in
                    Button {
                        model.setInterval(interval)
                    } label: {
                        InverseLabel(text: interval.rawValue, isActive: interval == model.interval)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                TermDropdown(
                    items: model.intervals.map { interval in
                        DropdownItem(interval.rawValue, isSelected: interval == model.interval) { model.setInterval(interval) }
                    },
                    minWidth: 90
                ) { isOpen in
                    InverseLabel(text: "⋯", isActive: isOpen)
                }
                .help("All intervals ( [ and ] step through them )")
            }
            .fixedSize()
            .accessibilityLabel("Interval \(model.interval.rawValue)")

            TermDropdown(
                model.chartSettings.style.title,
                items: ChartStyle.allCases.map { style in
                    DropdownItem(style.title, isSelected: style == model.chartSettings.style) { model.setStyle(style) }
                }
            )
            .help("Chart type ( c cycles )")

            TermDropdown(indicatorCount > 0 ? "Indicators \(indicatorCount)" : "Indicators", items: indicatorItems, minWidth: 250)

            TermDropdown(model.drawTool.map { "Draw: \($0.title)" } ?? "Draw", items: drawItems, minWidth: 220)
                .help("Pick a tool, then drag on the chart ( d arms the trend line ). Click a drawing to select it, drag it or its handles to change it, ⌫ deletes it.")

            TermDropdown(scaleTitle, items: scaleItems, minWidth: 170)
                .help("Price scale: logarithmic, percent change, inverted")

            TermDropdown("Tools", items: toolItems, minWidth: 210)

            Spacer(minLength: 0)

            if model.replayTime != nil {
                HStack(spacing: 0) {
                    InverseLabel(text: "REPLAY", color: PowderPalette.cautionAmber, textColor: PowderPalette.graphite)
                    replayButton("◂", help: "Back one candle ( , )") { model.stepReplay(-1) }
                    replayButton(model.isReplayPlaying ? "❚❚" : "▶", help: "Play or pause ( space )") { model.toggleReplayPlayback() }
                    replayButton("▸", help: "Forward one candle ( . )") { model.stepReplay(1) }
                    replayButton("✕", help: "Return to live ( esc )") { model.stopReplay() }
                }
                .fixedSize()
            }

            if !model.isAutoScaled {
                Button {
                    model.resetPriceScale()
                } label: {
                    InverseLabel(text: "AUTO", color: PowderPalette.cautionAmber, textColor: PowderPalette.graphite)
                }
                .buttonStyle(.plain)
                .help("Fit the price scale again (or double-click the price axis)")
            }
            if model.chartOffset != 0 || model.cursorTime != nil {
                Button {
                    model.goLive()
                } label: {
                    InverseLabel(text: "LIVE ▸", color: PowderPalette.cautionAmber, textColor: PowderPalette.graphite)
                }
                .buttonStyle(.plain)
                .help("Return to the live candle (esc, or double-click the chart)")
            }
        }
        .font(Term.font(11))
        .lineLimit(1)
        .padding(.horizontal, 12)
        .frame(height: 26)
        .clipped()
    }

    private var shownIntervals: [HLInterval] {
        Self.favorites.contains(model.interval) ? Self.favorites : Self.favorites + [model.interval]
    }

    private func replayButton(_ text: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            InverseLabel(text: text, isActive: false)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var indicatorCount: Int { model.chartSettings.indicators.count }

    private var drawItems: [DropdownItem] {
        var items = DrawTool.allCases.map { tool in
            DropdownItem(tool.title, detail: tool == .trend ? "d" : "", isSelected: model.drawTool == tool, startsSection: tool.startsSection) {
                model.setDrawTool(model.drawTool == tool ? nil : tool)
            }
        }
        items += [
            DropdownItem("Magnet", detail: "m", isSelected: model.chartSettings.magnet, startsSection: true) {
                model.chartSettings.magnet.toggle()
            },
            DropdownItem("Lock drawings", isSelected: model.chartSettings.lockDrawings) { model.chartSettings.lockDrawings.toggle() },
            DropdownItem("Hide drawings", isSelected: model.chartSettings.hideDrawings) { model.chartSettings.hideDrawings.toggle() },
            DropdownItem("Undo", detail: "⌘Z", isDisabled: !model.canUndoDrawing, startsSection: true) { model.undoDrawing() },
            DropdownItem("Redo", detail: "⇧⌘Z", isDisabled: !model.canRedoDrawing) { model.redoDrawing() },
            DropdownItem("Clear all drawings", isDisabled: !model.hasDrawings) { model.clearDrawings() },
        ]
        return items
    }

    private var indicatorItems: [DropdownItem] {
        let firstPane = ChartIndicator.allCases.first(where: \.isPane)
        return ChartIndicator.allCases.map { indicator in
            DropdownItem(
                indicator.title, isSelected: model.chartSettings.indicators.contains(indicator), startsSection: indicator == firstPane
            ) { model.toggle(indicator) }
        }
    }

    private var scaleTitle: String {
        let settings = model.chartSettings
        let marks = [settings.logScale ? "Log" : nil, settings.percentScale ? "%" : nil, settings.invertScale ? "Inv" : nil].compactMap { $0 }
        return marks.isEmpty ? "Scale" : "Scale: " + marks.joined(separator: " ")
    }

    private var scaleItems: [DropdownItem] {
        [
            DropdownItem("Auto (fit to screen)", isDisabled: model.isAutoScaled) { model.resetPriceScale() },
            DropdownItem("Logarithmic", isSelected: model.chartSettings.logScale, startsSection: true) { model.chartSettings.logScale.toggle() },
            DropdownItem("Percent", isSelected: model.chartSettings.percentScale) { model.chartSettings.percentScale.toggle() },
            DropdownItem("Inverted", isSelected: model.chartSettings.invertScale) { model.chartSettings.invertScale.toggle() },
        ]
    }

    private var toolItems: [DropdownItem] {
        [
            model.replayTime == nil
                ? DropdownItem("Replay from here", id: "replay") { model.startReplay() }
                : DropdownItem("Stop replay", id: "replay", detail: "esc") { model.stopReplay() },
            DropdownItem("Copy chart image", id: "snapshot") { model.copyChartImage() },
        ]
    }
}

/// A hairline between two panels that can be dragged to resize them.
private struct ResizeHandle: View {
    let vertical: Bool
    /// Points moved since the drag began, along the resizing axis.
    let onDrag: (_ start: Bool, _ translation: CGFloat) -> Void

    @State private var isDragging = false

    var body: some View {
        TermRule(vertical: vertical)
            .overlay {
                Color.clear
                    .frame(width: vertical ? 9 : nil, height: vertical ? nil : 9)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside {
                            (vertical ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                onDrag(!isDragging, vertical ? value.translation.width : value.translation.height)
                                isDragging = true
                            }
                            .onEnded { _ in isDragging = false }
                    )
            }
            .zIndex(1)
    }
}

// MARK: - Order book

private struct OrderBookPanel: View, Equatable {
    let book: HLBook?
    let lastPrice: Double?
    let lastIsBuy: Bool?
    let grouping: HLBookGrouping
    let coin: String
    let priceDecimals: Int
    let sizeDecimals: Int

    private struct Row {
        let level: HLLevel
        let total: Double
    }

    nonisolated static func == (lhs: OrderBookPanel, rhs: OrderBookPanel) -> Bool {
        lhs.book == rhs.book && lhs.lastPrice == rhs.lastPrice && lhs.lastIsBuy == rhs.lastIsBuy && lhs.grouping == rhs.grouping
            && lhs.coin == rhs.coin && lhs.priceDecimals == rhs.priceDecimals && lhs.sizeDecimals == rhs.sizeDecimals
    }

    var body: some View {
        VStack(spacing: 0) {
            PanelTitle("ORDER BOOK") {
                KeyCap("g")
                Text("GROUP \(HLFormat.tick(tick))")
            }
            ColumnTitles(["PRICE", "SIZE \(coin)", "TOTAL"])

            GeometryReader { geometry in
                let depth = max(Int((geometry.size.height - Term.rowHeight - 8) / 2 / Term.rowHeight), 1)
                let asks = rows(book?.asks ?? [], depth: depth)
                let bids = rows(book?.bids ?? [], depth: depth)
                let maxTotal = max(asks.last?.total ?? 0, bids.last?.total ?? 0, .leastNonzeroMagnitude)

                // Each side is drawn in one pass. As separate text views, the sixty-odd cells cost more to
                // lay out on every update than everything else in the pane together.
                VStack(spacing: 0) {
                    Canvas { context, size in
                        draw(asks, bestAtBottom: true, color: PowderPalette.riskCoral, maxTotal: maxTotal, in: &context, size: size)
                    }
                    .frame(height: CGFloat(depth) * Term.rowHeight)

                    spread
                        .frame(height: Term.rowHeight + 8)

                    Canvas { context, size in
                        draw(bids, bestAtBottom: false, color: PowderPalette.signalGreen, maxTotal: maxTotal, in: &context, size: size)
                    }
                    .frame(height: CGFloat(depth) * Term.rowHeight)
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
            .clipped()
        }
        .onChange(of: book) { old, new in flashChanges(from: old, to: new) }
    }

    /// Price levels whose size just changed, lit for a moment.
    @State private var flashing: Set<Double> = []
    @State private var flashRound = 0

    private func flashChanges(from old: HLBook?, to new: HLBook?) {
        guard let old, let new else { return }
        var sizes: [Double: Double] = [:]
        for level in old.bids + old.asks { sizes[level.px] = level.sz }
        var changed: Set<Double> = []
        for level in (new.bids.prefix(30) + new.asks.prefix(30)) {
            if let before = sizes[level.px], before != level.sz { changed.insert(level.px) }
        }
        guard changed != flashing else { return }
        flashing = changed
        flashRound += 1
        let round = flashRound
        Task { @MainActor in
            // On, then off: two redraws per update, not a fade's sixty.
            try? await Task.sleep(for: .milliseconds(160))
            if flashRound == round { flashing = [] }
        }
    }

    private func draw(
        _ rows: [Row], bestAtBottom: Bool, color: Color, maxTotal: Double, in context: inout GraphicsContext, size: CGSize
    ) {
        let rowHeight = Term.rowHeight
        let inset: CGFloat = 12
        let column = (size.width - inset * 2) / 3
        let font = Term.font(11.5)
        for (index, row) in rows.enumerated() {
            let top = bestAtBottom ? size.height - CGFloat(index + 1) * rowHeight : CGFloat(index) * rowHeight
            let middle = top + rowHeight / 2
            // Depth: a bar growing from the right, as wide as this level's share of the deepest total shown.
            let width = size.width * CGFloat(row.total / maxTotal)
            context.fill(Path(CGRect(x: size.width - width, y: top, width: width, height: rowHeight)), with: .color(color.opacity(0.14)))
            if flashing.contains(row.level.px) {
                context.fill(Path(CGRect(x: 0, y: top, width: size.width, height: rowHeight)), with: .color(color.opacity(0.3)))
            }
            context.draw(
                Text(HLFormat.price(row.level.px, decimals: priceDecimals)).font(font).foregroundStyle(color),
                at: CGPoint(x: inset, y: middle), anchor: .leading
            )
            context.draw(
                Text(HLFormat.size(row.level.sz, decimals: sizeDecimals)).font(font).foregroundStyle(Term.foreground),
                at: CGPoint(x: inset + column * 2, y: middle), anchor: .trailing
            )
            context.draw(
                Text(HLFormat.size(row.total, decimals: sizeDecimals)).font(font).foregroundStyle(.secondary),
                at: CGPoint(x: size.width - inset, y: middle), anchor: .trailing
            )
        }
    }

    private var tick: Double {
        grouping.tick(at: lastPrice ?? book?.bids.first?.px ?? 0)
    }

    private var spread: some View {
        HStack(spacing: 8) {
            if let lastPrice {
                TickingPrice(
                    value: lastPrice,
                    text: HLFormat.price(lastPrice, decimals: priceDecimals),
                    font: Term.font(13, .semibold),
                    color: lastIsBuy.map { $0 ? PowderPalette.signalGreen : PowderPalette.riskCoral } ?? Term.foreground
                )
                if let lastIsBuy {
                    Text(lastIsBuy ? "▲" : "▼")
                        .font(Term.font(9))
                        .foregroundStyle(lastIsBuy ? PowderPalette.signalGreen : PowderPalette.riskCoral)
                }
            } else {
                Text("waiting for book…").foregroundStyle(.secondary)
            }
            Spacer()
            if let bid = book?.bids.first?.px, let ask = book?.asks.first?.px, bid > 0 {
                Text("SPREAD").foregroundStyle(.secondary)
                Text(HLFormat.price(ask - bid, decimals: priceDecimals))
                Text(String(format: "%.2fbp", (ask - bid) / ((ask + bid) / 2) * 10_000))
                    .foregroundStyle(.secondary)
            }
        }
        .font(Term.font(11))
        .lineLimit(1)
        .padding(.horizontal, 12)
        .frame(maxHeight: .infinity)
        .background(Term.faint)
    }

    /// Best `depth` levels with running totals, ordered outward from the spread.
    private func rows(_ levels: [HLLevel], depth: Int) -> [Row] {
        var total = 0.0
        return levels.prefix(depth).map { level in
            total += level.sz
            return Row(level: level, total: total)
        }
    }
}

/// A price that flashes green or red behind itself as it ticks.
struct TickingPrice: View {
    let value: Double?
    let text: String
    let font: Font
    let color: Color

    @State private var flashColor = Color.clear
    @State private var flash = 0.0

    var body: some View {
        Text(text)
            .font(font)
            .foregroundStyle(color)
            .padding(.horizontal, 4)
            .background(flashColor.opacity(flash))
            .padding(.horizontal, -4)
            .onChange(of: value) { old, new in
                guard let old, let new, old != new else { return }
                flashColor = new > old ? PowderPalette.signalGreen : PowderPalette.riskCoral
                flash = 0.35
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(180))
                    flash = 0
                }
            }
    }
}

// MARK: - Trades

private struct TradesPanel: View, Equatable {
    let trades: [HLTrade]
    let priceDecimals: Int
    let sizeDecimals: Int

    /// Prints that just arrived, lit for a moment.
    @State private var flashing: Set<Int64> = []
    @State private var flashRound = 0

    nonisolated static func == (lhs: TradesPanel, rhs: TradesPanel) -> Bool {
        lhs.trades == rhs.trades && lhs.priceDecimals == rhs.priceDecimals && lhs.sizeDecimals == rhs.sizeDecimals
    }

    var body: some View {
        VStack(spacing: 0) {
            PanelTitle("TRADES") { EmptyView() }
            ColumnTitles(["PRICE", "SIZE", "TIME"])

            // The tape is drawn in one pass: a busy market prints many times a second, and as separate
            // text views every print re-laid-out the whole list.
            Canvas { context, size in
                let rowHeight = Term.rowHeight
                let inset: CGFloat = 12
                let column = (size.width - inset * 2) / 3
                let font = Term.font(11.5)
                for (index, trade) in trades.prefix(max(Int(size.height / rowHeight), 0)).enumerated() {
                    let top = CGFloat(index) * rowHeight
                    let middle = top + rowHeight / 2
                    let color = trade.isBuy ? PowderPalette.signalGreen : PowderPalette.riskCoral
                    if flashing.contains(trade.tid) {
                        context.fill(Path(CGRect(x: 0, y: top, width: size.width, height: rowHeight)), with: .color(color.opacity(0.3)))
                    }
                    context.draw(
                        Text(HLFormat.price(trade.px, decimals: priceDecimals)).font(font).foregroundStyle(color),
                        at: CGPoint(x: inset, y: middle), anchor: .leading
                    )
                    context.draw(
                        Text(HLFormat.size(trade.sz, decimals: sizeDecimals)).font(font).foregroundStyle(Term.foreground),
                        at: CGPoint(x: inset + column * 2, y: middle), anchor: .trailing
                    )
                    context.draw(
                        Text(HLFormat.clock(trade.time)).font(font).foregroundStyle(.secondary),
                        at: CGPoint(x: size.width - inset, y: middle), anchor: .trailing
                    )
                }
            }
            .clipped()
        }
        .onChange(of: trades.first?.tid) {
            // Only prints that just happened flash, not the backlog loaded with the tab.
            let now = Date().timeIntervalSince1970 * 1_000
            let fresh = Set(trades.prefix(40).filter { now - Double($0.time) < 3_000 && !flashing.contains($0.tid) }.map(\.tid))
                .subtracting(seen)
            seen = Set(trades.prefix(80).map(\.tid))
            guard !fresh.isEmpty else { return }
            flashing = fresh
            flashRound += 1
            let round = flashRound
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(200))
                if flashRound == round { flashing = [] }
            }
        }
    }

    @State private var seen: Set<Int64> = []
}

private struct PanelTitle<Accessory: View>: View {
    let title: String
    @ViewBuilder let accessory: Accessory

    init(_ title: String, @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.accessory = accessory()
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(Term.font(11, .bold))
            Spacer()
            accessory
                .foregroundStyle(.secondary)
        }
        .font(Term.font(10.5))
        .padding(.horizontal, 12)
        .frame(height: 26)
    }
}

private struct ColumnTitles: View {
    let titles: [String]

    init(_ titles: [String]) { self.titles = titles }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(titles.enumerated()), id: \.offset) { index, title in
                Text(title)
                    .frame(maxWidth: .infinity, alignment: index == 0 ? .leading : .trailing)
            }
        }
        .font(Term.font(9.5))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(height: 18)
        .overlay(alignment: .bottom) { TermRule() }
    }
}

// MARK: - Status bar

private struct StatusBar: View {
    let model: PerpsModel

    private static let hints: [(String, String)] = [
        ("t", "tab"),
        ("s", "split"),
        ("⌥←→", "pane"),
        ("/", "market"),
        ("[ ]", "interval"),
        ("← →", "inspect"),
        ("- =", "zoom"),
        ("g", "group"),
        ("?", "keys"),
    ]

    var body: some View {
        HStack(spacing: 16) {
            // Key hints give way first when the pane is narrow.
            ViewThatFits(in: .horizontal) {
                hints(Self.hints)
                hints(Array(Self.hints.suffix(1)))
            }

            if let error = model.errorMessage {
                Text(error)
                    .foregroundStyle(PowderPalette.riskCoral)
                    .truncationMode(.tail)
            }

            HStack(spacing: 6) {
                Text("●").foregroundStyle(connectionColor)
                Text(connectionLabel)
            }
            .fixedSize()
            .help(HyperliquidAPI.host)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Hyperliquid \(connectionLabel)")
        }
        .font(Term.font(10.5))
        .lineLimit(1)
        .padding(.horizontal, 12)
        .frame(height: 24)
    }

    private func hints(_ hints: [(String, String)]) -> some View {
        HStack(spacing: 16) {
            ForEach(hints, id: \.0) { key, label in
                HStack(spacing: 5) {
                    Text(key).foregroundStyle(PowderPalette.scopeBlue)
                    Text(label).foregroundStyle(.secondary)
                }
                .fixedSize()
            }
            Spacer(minLength: 8)
        }
    }

    private var connectionColor: Color {
        model.connection == .live ? PowderPalette.signalGreen : PowderPalette.cautionAmber
    }

    private var connectionLabel: String {
        switch model.connection {
        case .connecting: "CONNECTING"
        case .live: model.latencyMs.map { "LIVE \($0)ms" } ?? "LIVE"
        case let .reconnecting(attempt): "RECONNECTING #\(attempt)"
        }
    }
}

// MARK: - Key help

private struct KeyHelp: View {

    private static let keys: [(String, String)] = [
        ("1 … 9", "go to tab (⌘1 … ⌘9 while typing)"),
        ("tab", "next tab — ⇧ previous (⌘⇧] ⌘⇧[)"),
        ("⌘P  /  t", "open anything: a market (new tab, or its open tab) or a command"),
        ("⌘W", "close tab (and its pane, when it was the last)"),
        ("s  ⌘D", "split right — ⇧⌘D splits down"),
        ("⌥ ← → ↑ ↓", "focus the pane in that direction (⌥ h j k l)"),
        ("[  ]", "shorter / longer candle interval"),
        ("c", "next chart type (candles, hollow, Heikin Ashi, bars, line, step, area, baseline)"),
        ("←  →", "inspect candles (h l) — ⇧ jumps 10"),
        ("esc", "return to the live candle and auto scale"),
        ("-  =", "zoom chart out / in (scroll or pinch)"),
        ("drag", "pan — drag the price or time axis to rescale it"),
        ("⇧ drag", "measure price, percent, bars and time"),
        ("d", "draw a trend line: drag it out on the chart (more tools under Draw)"),
        ("click", "select a drawing — drag it or its handles to change it, ⌫ deletes, right-click recolours"),
        ("⌘Z  ⇧⌘Z", "undo / redo a change to the drawings"),
        ("m", "magnet: drawing points snap to open, high, low and close"),
        ("⌥ click", "remove the drawing under the pointer, or add a horizontal line"),
        (",  .  space", "while replaying (Tools ▸ Replay): step back, step on, play or pause"),
        ("g", "cycle order book grouping"),
        ("o", "type an order size (⏎ or esc leaves the field)"),
        ("⇧B  ⇧S", "buy / long and sell / short at once, with the ticket's size and wallet"),
        ("right-click", "on the chart: limit order, alert or price line at that price; cancel what is under the pointer"),
        ("w", "add this market to the watchlist, or remove it"),
        ("⌘R", "reconnect and reload"),
        ("?", "toggle this list"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("KEYS")
                .font(Term.font(11, .bold))
                .padding(.bottom, 10)
            ForEach(Self.keys, id: \.0) { key, action in
                HStack(spacing: 0) {
                    Text(key)
                        .foregroundStyle(PowderPalette.scopeBlue)
                        .frame(width: 100, alignment: .leading)
                    Text(action)
                }
                .frame(height: Term.rowHeight + 2)
            }
            Text("any key closes")
                .foregroundStyle(.secondary)
                .padding(.top, 10)
        }
        .font(Term.font(11.5))
        .padding(18)
        .background(Term.widget)
        .overlay(Rectangle().stroke(Term.rule, lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 24, y: 10)
        .accessibilityElement(children: .combine)
    }
}

/// Under the ticket on a Solana token tab: what the token is and its live figures.
private struct SolanaInfoPanel: View {
    let model: PerpsModel
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("TOKEN").font(Term.font(11, .bold))
                Spacer()
                Text("SOLANA").font(Term.font(10, .semibold)).foregroundStyle(Term.accent)
            }
            .frame(height: 22)

            if let token = model.solana {
                if !token.name.isEmpty { row("NAME", token.name) }
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(token.address, forType: .string)
                    copied = true
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(1.2))
                        copied = false
                    }
                } label: {
                    row("MINT", copied ? "copied" : "\(token.address.prefix(6))…\(token.address.suffix(6))  ⧉")
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Copy the token's mint address")
            }
            if let stats = model.solanaStats {
                row("PRICE", "$" + HLFormat.price(stats.price, decimals: model.priceDecimals))
                row("24H", HLFormat.percent(stats.change24), color: PowderPalette.market(stats.change24))
                row("MKT CAP", "$" + HLFormat.compact(stats.marketCap))
                row("LIQUIDITY", "$" + HLFormat.compact(stats.liquidity))
                row("24H VOL", "$" + HLFormat.compact(stats.volume24))
                if let holders = stats.holders { row("HOLDERS", "\(holders)") }
                if let exchange = stats.exchanges.first {
                    exchangeRow("EXCHANGE", exchange, mint: stats.token.address)
                }
                if let pool = stats.token.pool {
                    row("POOL", "\(pool.address.prefix(6))…\(pool.address.suffix(6))")
                        .help("\(stats.token.pairName) on \(pool.exchange): \(pool.address). The chart, the trades and your swaps are this pool's alone.")
                }
                if let fee = stats.poolFeeLabel {
                    row("POOL FEE", fee)
                        .help(stats.hasDynamicFee
                            ? "What this pool takes from each swap. It moves with the market: this is its current rate."
                            : "What this pool takes from each swap")
                }
                otherPools
            } else if !SolanaAPI.hasKey {
                Text("Add a Codex API key in Settings ( ⌘, ) to load Solana data.")
                    .foregroundStyle(PowderPalette.riskCoral)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let details = model.solanaDetails {
                safety(details)
                about(details)
            }
        }
        .font(Term.font(11.5))
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    private static let good = PowderPalette.signalGreen
    private static let bad = PowderPalette.riskCoral
    private static let warn = PowderPalette.cautionAmber

    /// The checks a buyer makes before touching a token: can it be printed or frozen, who holds it, how thin is it.
    @ViewBuilder
    private func safety(_ details: SolanaTokenDetails) -> some View {
        TermRule().padding(.vertical, 2)
        HStack {
            Text("SAFETY").font(Term.font(11, .bold))
            Spacer()
            if details.isScam {
                Text("FLAGGED AS SCAM").font(Term.font(10, .bold)).foregroundStyle(Self.bad)
            }
        }
        row("MINT", details.mintAuthority == nil ? "✓ renounced" : "✗ can mint more", color: details.mintAuthority == nil ? Self.good : Self.bad)
            .help(details.mintAuthority.map { "\($0) can create new tokens, diluting holders" } ?? "Nobody can create more of this token")
        row("FREEZE", details.freezeAuthority == nil ? "✓ renounced" : "✗ can freeze wallets", color: details.freezeAuthority == nil ? Self.good : Self.bad)
            .help(details.freezeAuthority.map { "\($0) can freeze a holder's tokens so they cannot be sold" } ?? "Nobody can freeze holders' tokens")
        if let top = details.top10Percent {
            row("TOP 10 HOLD", String(format: "%.1f%%", top), color: top < 30 ? Self.good : top < 50 ? Self.warn : Self.bad)
                .help("Share of supply in the ten largest wallets (pools and exchanges included)")
        }
        if let liquidity = model.solanaStats?.liquidity {
            row("LIQUIDITY", "$" + HLFormat.compact(liquidity), color: liquidity >= 100_000 ? Self.good : liquidity >= 10_000 ? Self.warn : Self.bad)
                .help("Money in the pools: with little of it, a sale moves the price a long way")
        }
        if let created = details.createdAt {
            let age = Date().timeIntervalSince(created)
            row("AGE", Self.age(age), color: age >= 7 * 86_400 ? Self.good : age >= 86_400 ? Self.warn : Self.bad)
        }
    }

    private static func age(_ seconds: TimeInterval) -> String {
        switch seconds {
        case ..<3_600: "\(max(Int(seconds / 60), 1)) min"
        case ..<86_400: "\(Int(seconds / 3_600)) h"
        case ..<(365 * 86_400): "\(Int(seconds / 86_400)) days"
        default: String(format: "%.1f years", seconds / (365 * 86_400))
        }
    }

    /// Links open in a Powder web tab, not the browser.
    @ViewBuilder
    private func about(_ details: SolanaTokenDetails) -> some View {
        if !details.links.isEmpty || !details.description.isEmpty {
            TermRule().padding(.vertical, 2)
        }
        if !details.links.isEmpty {
            HStack(spacing: 6) {
                ForEach(details.links, id: \.url) { link in
                    Button {
                        model.onOpenLink?(link.url)
                    } label: {
                        Text(link.label)
                            .font(Term.font(10, .semibold))
                            .foregroundStyle(Term.accent)
                            .padding(.horizontal, 6)
                            .frame(height: 18)
                            .overlay(Rectangle().stroke(Term.accent.opacity(0.6), lineWidth: 1))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(link.url.absoluteString)
                }
                Spacer(minLength: 0)
            }
        }
        if !details.description.isEmpty {
            Text(details.description)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
                .help(details.description)
        }
    }

    private func row(_ label: String, _ value: String, color: Color = Term.foreground) -> some View {
        HStack(spacing: 8) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(value).foregroundStyle(color).lineLimit(1).truncationMode(.middle)
        }
    }

    /// The token's other pools, most traded first. A click opens that pool as its own market tab.
    @ViewBuilder
    private var otherPools: some View {
        let pools = Array(model.solanaPools.prefix(6))
        if !pools.isEmpty {
            TermRule().padding(.vertical, 2)
            Text("OTHER POOLS").font(Term.font(11, .bold))
            ForEach(pools, id: \.pairAddress) { found in
                Button {
                    model.onOpenMarket?(found.token)
                } label: {
                    HStack(spacing: 8) {
                        Text(found.token.pool?.exchange ?? "?").foregroundStyle(Term.accent)
                        Text("/" + (found.token.pool?.quoteSymbol ?? "?")).foregroundStyle(.secondary)
                        Spacer(minLength: 4)
                        Text("$" + HLFormat.compact(found.liquidity)).foregroundStyle(.secondary)
                    }
                    .lineLimit(1)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open \(found.token.pairName) on \(found.token.pool?.exchange ?? "this exchange"): $\(HLFormat.compact(found.liquidity)) liquidity, $\(HLFormat.compact(found.volume24)) traded in 24h")
            }
        }
    }

    /// The exchange this pool is on. A click opens the token there, in a Powder web tab.
    @ViewBuilder
    private func exchangeRow(_ label: String, _ exchange: SolanaExchange, mint: String) -> some View {
        if let url = exchange.marketURL(mint: mint) {
            Button {
                model.onOpenLink?(url)
            } label: {
                row(label, exchange.name + " ↗", color: Term.accent)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open \(exchange.name): \(url.absoluteString)")
        } else {
            row(label, exchange.name)
        }
    }
}
