import AppKit
import SwiftUI

// MARK: - Settings

enum ChartStyle: String, Codable, CaseIterable, Sendable {
    case candles, hollow, heikinAshi, bars, line, step, area, baseline

    var title: String {
        switch self {
        case .candles: "Candles"
        case .hollow: "Hollow Candles"
        case .heikinAshi: "Heikin Ashi"
        case .bars: "Bars"
        case .line: "Line"
        case .step: "Step Line"
        case .area: "Area"
        case .baseline: "Baseline"
        }
    }

    /// Drawn through the closes alone.
    var usesClose: Bool { self == .line || self == .step || self == .area || self == .baseline }
}

enum ChartIndicator: String, Codable, CaseIterable, Sendable {
    // On the price pane.
    case volume, volumeProfile, ma, ema, bollinger, vwap, supertrend, sar, ichimoku, donchian, keltner
    // Each in a pane of its own.
    case rsi, macd, stoch, stochRSI, atr, obv, cci, mfi, williams, adx

    var title: String {
        switch self {
        case .volume: "Volume"
        case .volumeProfile: "Volume Profile (visible range)"
        case .ma: "MA 7 / 25 / 99"
        case .ema: "EMA 12 / 26"
        case .bollinger: "Bollinger Bands 20, 2"
        case .vwap: "VWAP (daily)"
        case .supertrend: "Supertrend 10, 3"
        case .sar: "Parabolic SAR"
        case .ichimoku: "Ichimoku Cloud 9, 26, 52"
        case .donchian: "Donchian Channels 20"
        case .keltner: "Keltner Channels 20, 2"
        case .rsi: "RSI 14"
        case .macd: "MACD 12, 26, 9"
        case .stoch: "Stochastic 14, 3, 3"
        case .stochRSI: "Stochastic RSI 14"
        case .atr: "ATR 14"
        case .obv: "On-Balance Volume"
        case .cci: "CCI 20"
        case .mfi: "Money Flow Index 14"
        case .williams: "Williams %R 14"
        case .adx: "ADX / DMI 14"
        }
    }

    /// Drawn in a pane of its own under the price.
    var isPane: Bool {
        switch self {
        case .rsi, .macd, .stoch, .stochRSI, .atr, .obv, .cci, .mfi, .williams, .adx: true
        default: false
        }
    }
}

/// How a tab draws its chart. The last choice is the default for new tabs.
struct ChartSettings: Codable, Equatable, Sendable {
    var style = ChartStyle.candles
    var indicators: Set<ChartIndicator> = [.volume]
    var logScale = false
    /// Labels the price axis with the change from the first candle on screen.
    var percentScale = false
    /// Turns the price axis upside down.
    var invertScale = false
    /// Drawing points snap to the nearest open, high, low or close.
    var magnet = false
    var lockDrawings = false
    var hideDrawings = false

    private static let key = "chart.settings"

    init() {}

    /// Every field is optional on disk, so settings saved by an older or newer build still load.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        func flag(_ key: CodingKeys) -> Bool { (try? values.decode(Bool.self, forKey: key)) ?? false }
        style = (try? values.decode(ChartStyle.self, forKey: .style)) ?? .candles
        indicators = Set(((try? values.decode([String].self, forKey: .indicators)) ?? ["volume"]).compactMap(ChartIndicator.init))
        logScale = flag(.logScale)
        percentScale = flag(.percentScale)
        invertScale = flag(.invertScale)
        magnet = flag(.magnet)
        lockDrawings = flag(.lockDrawings)
        hideDrawings = flag(.hideDrawings)
    }

    static func load(from defaults: UserDefaults = .standard) -> ChartSettings {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(ChartSettings.self, from: $0) } ?? ChartSettings()
    }

    func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.key) }
    }
}

// MARK: - Indicator math

enum ChartMath {
    static func sma(_ values: [Double], _ period: Int) -> [Double?] {
        var out = [Double?](repeating: nil, count: values.count)
        var sum = 0.0
        for index in values.indices {
            sum += values[index]
            if index >= period { sum -= values[index - period] }
            if index >= period - 1 { out[index] = sum / Double(period) }
        }
        return out
    }

    /// Seeded with the simple average of the first `period` values.
    static func ema(_ values: [Double], _ period: Int) -> [Double?] {
        var out = [Double?](repeating: nil, count: values.count)
        guard values.count >= period, period > 0 else { return out }
        let k = 2 / Double(period + 1)
        var current = values[0..<period].reduce(0, +) / Double(period)
        out[period - 1] = current
        for index in period..<values.count {
            current = values[index] * k + current * (1 - k)
            out[index] = current
        }
        return out
    }

    static func bollinger(_ values: [Double], period: Int = 20, width: Double = 2) -> (upper: [Double?], lower: [Double?]) {
        let mid = sma(values, period)
        var upper = [Double?](repeating: nil, count: values.count)
        var lower = upper
        for index in values.indices {
            guard let mean = mid[index] else { continue }
            let variance = values[(index - period + 1)...index].reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(period)
            let deviation = variance.squareRoot() * width
            upper[index] = mean + deviation
            lower[index] = mean - deviation
        }
        return (upper, lower)
    }

    /// Wilder's RSI.
    static func rsi(_ values: [Double], _ period: Int = 14) -> [Double?] {
        var out = [Double?](repeating: nil, count: values.count)
        guard values.count > period else { return out }
        var gain = 0.0, loss = 0.0
        for index in 1...period {
            let change = values[index] - values[index - 1]
            if change >= 0 { gain += change } else { loss -= change }
        }
        gain /= Double(period)
        loss /= Double(period)
        out[period] = loss == 0 ? 100 : 100 - 100 / (1 + gain / loss)
        for index in (period + 1)..<values.count {
            let change = values[index] - values[index - 1]
            gain = (gain * Double(period - 1) + max(change, 0)) / Double(period)
            loss = (loss * Double(period - 1) + max(-change, 0)) / Double(period)
            out[index] = loss == 0 ? 100 : 100 - 100 / (1 + gain / loss)
        }
        return out
    }

    static func macd(_ values: [Double]) -> (macd: [Double?], signal: [Double?], histogram: [Double?]) {
        let fast = ema(values, 12), slow = ema(values, 26)
        var line = [Double?](repeating: nil, count: values.count)
        for index in values.indices {
            if let a = fast[index], let b = slow[index] { line[index] = a - b }
        }
        var signal = [Double?](repeating: nil, count: values.count)
        if let start = line.firstIndex(where: { $0 != nil }) {
            let smoothed = ema(line[start...].map { $0 ?? 0 }, 9)
            for (offset, value) in smoothed.enumerated() { signal[start + offset] = value }
        }
        var histogram = [Double?](repeating: nil, count: values.count)
        for index in values.indices {
            if let a = line[index], let b = signal[index] { histogram[index] = a - b }
        }
        return (line, signal, histogram)
    }

    /// Volume-weighted average price, restarting at each UTC midnight.
    static func vwap(_ candles: [HLCandle]) -> [Double?] {
        var out = [Double?](repeating: nil, count: candles.count)
        var day: Int64 = -1
        var notional = 0.0, volume = 0.0
        for (index, candle) in candles.enumerated() {
            let candleDay = candle.t / 86_400_000
            if candleDay != day {
                day = candleDay
                notional = 0
                volume = 0
            }
            notional += (candle.h + candle.l + candle.c) / 3 * candle.v
            volume += candle.v
            if volume > 0 { out[index] = notional / volume }
        }
        return out
    }

    static func heikinAshi(_ candles: [HLCandle]) -> [HLCandle] {
        var out: [HLCandle] = []
        out.reserveCapacity(candles.count)
        for candle in candles {
            let close = (candle.o + candle.h + candle.l + candle.c) / 4
            let open = out.last.map { ($0.o + $0.c) / 2 } ?? (candle.o + candle.c) / 2
            out.append(HLCandle(
                t: candle.t, coin: candle.coin, interval: candle.interval,
                o: open, h: max(candle.h, open, close), l: min(candle.l, open, close), c: close, v: candle.v
            ))
        }
        return out
    }
}

// MARK: - Chart view

/// The trading chart: candles (or another style), volume, overlays and oscillator panes, drawn in one
/// Canvas pass. Drag pans, scroll and pinch zoom, the axes rescale, ⇧-drag measures, ⌥-click marks a price.
/// A price the chart marks for the selected wallet's position in this market.
struct ChartLevel: Equatable {
    enum Kind { case entryLong, entryShort, liquidation, orderBuy, orderSell, alert, stopLoss, takeProfit }
    let kind: Kind
    let price: Double
    let label: String
}

struct PerpChart: View, Equatable {
    /// Receives the gestures. Not observed: the values below are what the chart draws.
    let model: PerpsModel
    let candles: [HLCandle]
    let cursorTime: Int64?
    let pitch: CGFloat
    let offset: CGFloat
    let priceZoom: CGFloat
    let pricePan: CGFloat
    let decimals: Int
    let interval: HLInterval
    let settings: ChartSettings
    let priceLines: [Double]
    var levels: [ChartLevel] = []
    let drawings: [ChartDrawing]
    let drawTool: DrawTool?
    var selectedDrawing: UUID?
    /// True while old candles are being replayed: the newest one drawn is not the live one.
    var isReplay = false
    /// Bumped to copy a picture of the chart to the clipboard.
    var snapshotRequest = 0
    let isLoadingHistory: Bool

    nonisolated static func == (lhs: PerpChart, rhs: PerpChart) -> Bool {
        lhs.cursorTime == rhs.cursorTime
            && lhs.drawings == rhs.drawings
            && lhs.drawTool == rhs.drawTool
            && lhs.selectedDrawing == rhs.selectedDrawing
            && lhs.isReplay == rhs.isReplay
            && lhs.snapshotRequest == rhs.snapshotRequest
            && lhs.pitch == rhs.pitch
            && lhs.offset == rhs.offset
            && lhs.priceZoom == rhs.priceZoom
            && lhs.pricePan == rhs.pricePan
            && lhs.decimals == rhs.decimals
            && lhs.interval == rhs.interval
            && lhs.settings == rhs.settings
            && lhs.priceLines == rhs.priceLines
            && lhs.levels == rhs.levels
            && lhs.isLoadingHistory == rhs.isLoadingHistory
            && lhs.candles == rhs.candles
    }

    private enum DragKind {
        case pan(offset: CGFloat, pricePan: CGFloat)
        case priceAxis(zoom: CGFloat)
        case timeAxis(pitch: CGFloat)
        case measure
        case draw
        /// Moving a drawing, or one of its handles.
        case edit(original: ChartDrawing, handle: Int?)
        case priceLine(index: Int)
    }

    /// Read so the canvas redraws when the theme changes, which `==` above would otherwise skip.
    @Environment(\.colorScheme) private var colorScheme
    @State private var hover: CGPoint?
    @State private var drag: DragKind?
    @State private var measure: ChartMeasure?
    /// The drawing being dragged out with a tool, or the one being moved: shown in place of the saved one.
    @State private var draft: ChartDrawing?
    /// A horizontal price line being dragged to a new price.
    @State private var lineDrag: (index: Int, price: Double)?
    @State private var cache = ChartSeriesCache()

    private var canEditDrawings: Bool { !settings.lockDrawings && !settings.hideDrawings }

    private func renderer(_ layout: ChartLayout, hover: CGPoint?) -> ChartRenderer {
        var lines = priceLines
        if let lineDrag, lines.indices.contains(lineDrag.index) { lines[lineDrag.index] = lineDrag.price }
        return ChartRenderer(
            layout: layout,
            series: cache.series(window: layout.window, base: layout.base, indicators: settings.indicators, interval: interval),
            cursorTime: cursorTime, hover: hover, measure: measure,
            drawings: drawings.filter { $0.id != draft?.id } + (draft.map { [$0] } ?? []),
            selectedDrawing: selectedDrawing, interval: interval,
            decimals: decimals, settings: settings,
            priceLines: lines, levels: levels, isReplay: isReplay, isLoadingHistory: isLoadingHistory
        )
    }

    var body: some View {
        GeometryReader { geometry in
            let layout = ChartLayout(
                size: geometry.size, candles: candles, pitch: pitch, offset: offset,
                priceZoom: priceZoom, pricePan: pricePan, settings: settings
            )
            let renderer = renderer(layout, hover: hover)
            // Once a second, for the countdown to the candle close.
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                Canvas { context, _ in
                    let started = DispatchTime.now().uptimeNanoseconds
                    renderer.draw(in: &context, now: timeline.date)
                    Launch.DrawTimer.shared.record(Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case let .active(point):
                    hover = point
                    model.setCursor(time: point.x <= layout.plot.maxX ? layout.time(atX: point.x) : nil)
                case .ended:
                    hover = nil
                    model.setCursor(time: nil)
                }
            }
            .gesture(dragGesture(layout))
            .onTapGesture { location in
                measure = nil
                // Double-click the price axis for auto scale; anywhere else returns to the live candle.
                // (Checked here, not with a second gesture, so single clicks are not held back.)
                if NSApp.currentEvent?.clickCount == 2 {
                    if location.x > layout.plot.maxX { model.resetPriceScale() } else { model.goLive() }
                    return
                }
                guard layout.mainPane.contains(location) else { return }
                if let drawTool, drawTool.isOneClick {
                    let price = settings.magnet ? layout.snappedPrice(at: location) : layout.price(atY: location.y)
                    if drawTool == .horizontal {
                        model.togglePriceLine(at: price, tolerance: 0)
                    } else {
                        let time = layout.time(atPointX: location.x, interval: interval)
                        model.addDrawing(ChartDrawing(kind: drawTool, startTime: time, startPrice: price, endTime: time, endPrice: price))
                    }
                    model.setDrawTool(nil)
                    return
                }
                let hit = settings.hideDrawings ? nil : drawing(at: location, layout)?.drawing
                if NSEvent.modifierFlags.contains(.option) {
                    // ⌥-click removes the drawing under the pointer, else toggles a horizontal line.
                    if let hit {
                        model.removeDrawing(hit.id)
                    } else {
                        model.togglePriceLine(at: layout.price(atY: location.y), tolerance: layout.priceSpan(points: 5))
                    }
                    return
                }
                model.selectDrawing(settings.lockDrawings ? nil : hit?.id)
            }
            // Right-click: a menu at the pointer for trading and alerts at that price, and for the drawing there.
            .onRightClick { point in
                guard layout.mainPane.contains(point) else { return }
                let hit = settings.hideDrawings ? nil : drawing(at: point, layout)?.drawing
                if let hit, !settings.lockDrawings { model.selectDrawing(hit.id) }
                model.chartMenu = PerpsModel.ChartMenuRequest(
                    point: point, price: layout.price(atY: point.y), tolerance: layout.priceSpan(points: 6), drawing: hit?.id
                )
                DropdownCenter.dismiss = { [weak model] in model?.chartMenu = nil }
            }
            .background(ChartScrollCatcher { point, dx, dy, magnification in
                scroll(at: point, dx: dx, dy: dy, magnification: magnification, layout: layout)
            })
            .overlay {
                if candles.isEmpty {
                    Text("loading candles…")
                        .font(Term.font(12))
                        .foregroundStyle(.secondary)
                }
            }
            // Fetch older candles as the view nears the oldest one loaded.
            .onChange(of: layout.historyKey, initial: true) { _, key in
                if key != nil { model.loadOlderCandles() }
            }
            // Keyboard inspection can step off screen; follow it.
            .onChange(of: cursorTime) { _, time in
                guard hover == nil, let time, let index = candles.lastIndex(where: { $0.t == time }) else { return }
                if index < layout.range.lowerBound + 1 {
                    model.setViewport(offset: offset + CGFloat(layout.range.lowerBound + 2 - index))
                } else if layout.x(index) > layout.plot.maxX {
                    model.setViewport(offset: offset - (layout.x(index) - layout.plot.maxX) / pitch - 1)
                }
            }
            .onChange(of: interval) { measure = nil }
            .onChange(of: snapshotRequest) { copyImage(layout) }
        }
        .accessibilityLabel("Price chart, \(interval.rawValue) \(settings.style.title)")
    }

    /// The topmost drawing under a point, the selected one first so its handles win.
    private func drawing(at point: CGPoint, _ layout: ChartLayout) -> (drawing: ChartDrawing, hit: DrawingHit)? {
        if let selected = drawings.first(where: { $0.id == selectedDrawing }),
           let hit = layout.hit(point, selected, interval: interval) {
            return (selected, hit)
        }
        for drawing in drawings.reversed() {
            if let hit = layout.hit(point, drawing, interval: interval) { return (drawing, hit) }
        }
        return nil
    }

    /// Puts a picture of the chart as it stands, without the pointer's crosshair, on the clipboard.
    private func copyImage(_ layout: ChartLayout) {
        let renderer = renderer(layout, hover: nil)
        let content = Canvas { context, _ in renderer.draw(in: &context, now: .now) }
            .frame(width: layout.size.width, height: layout.size.height)
            .background(Term.background)
            .environment(\.colorScheme, colorScheme)
        let image = ImageRenderer(content: content)
        image.scale = NSScreen.main?.backingScaleFactor ?? 2
        guard let picture = image.nsImage else {
            model.notify("Could not render the chart")
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([picture])
        model.notify("Chart image copied to the clipboard")
    }

    private func dragGesture(_ layout: ChartLayout) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if drag == nil {
                    let start = value.startLocation
                    let inMain = layout.mainPane.contains(start)
                    if start.x > layout.plot.maxX {
                        drag = .priceAxis(zoom: priceZoom)
                    } else if start.y > layout.plot.maxY {
                        drag = .timeAxis(pitch: pitch)
                    } else if let drawTool, !drawTool.isOneClick, inMain {
                        measure = nil
                        drag = .draw
                        let time = layout.time(atPointX: start.x, interval: interval)
                        let price = settings.magnet ? layout.snappedPrice(at: start) : layout.price(atY: start.y)
                        var drawing = ChartDrawing(kind: drawTool, startTime: time, startPrice: price, endTime: time, endPrice: price)
                        // A channel starts a fixed width under its line; its third handle sets it from there.
                        if drawTool == .channel { drawing.extra = layout.price(atY: layout.y(price) + 44) - price }
                        draft = drawing
                    } else if NSEvent.modifierFlags.contains(.shift) {
                        drag = .measure
                        measure = ChartMeasure(
                            startIndex: layout.index(atX: start.x), startPrice: layout.price(atY: start.y),
                            endIndex: layout.index(atX: start.x), endPrice: layout.price(atY: start.y)
                        )
                    } else if canEditDrawings, inMain, let found = drawing(at: start, layout) {
                        measure = nil
                        model.selectDrawing(found.drawing.id)
                        draft = found.drawing
                        if case let .handle(index) = found.hit {
                            drag = .edit(original: found.drawing, handle: index)
                        } else {
                            drag = .edit(original: found.drawing, handle: nil)
                        }
                    } else if !settings.lockDrawings, inMain, let index = priceLines.firstIndex(where: { abs(layout.y($0) - start.y) < 5 }) {
                        drag = .priceLine(index: index)
                    } else {
                        measure = nil
                        drag = .pan(offset: offset, pricePan: pricePan)
                    }
                }
                switch drag {
                case let .pan(startOffset, startPan):
                    model.setViewport(offset: startOffset + value.translation.width / pitch)
                    // The price only moves by hand once the scale has been taken off auto.
                    if priceZoom != 1 || pricePan != 0 {
                        let direction: CGFloat = layout.isInverted ? -1 : 1
                        model.setPriceScale(pan: startPan + direction * value.translation.height / layout.priceZone.height / priceZoom)
                    }
                case let .priceAxis(startZoom):
                    model.setPriceScale(zoom: startZoom * exp(-value.translation.height * 0.006))
                case let .timeAxis(startPitch):
                    model.setViewport(pitch: startPitch * exp(value.translation.width * 0.006))
                case .measure:
                    measure?.endIndex = layout.index(atX: value.location.x)
                    measure?.endPrice = layout.price(atY: value.location.y)
                case .draw:
                    guard var drawing = draft else { break }
                    drawing.endTime = layout.time(atPointX: value.location.x, interval: interval)
                    drawing.endPrice = settings.magnet ? layout.snappedPrice(at: value.location) : layout.price(atY: value.location.y)
                    // A position is dragged from entry to target; the stop starts at half that distance, for 2:1.
                    if drawing.kind == .position { drawing.extra = drawing.startPrice - (drawing.endPrice - drawing.startPrice) / 2 }
                    draft = drawing
                case let .edit(original, handle):
                    if let handle {
                        draft = layout.reshaped(original, handle: handle, to: value.location, interval: interval, magnet: settings.magnet)
                    } else {
                        draft = layout.moved(original, dx: value.translation.width, dy: value.translation.height, interval: interval)
                    }
                case let .priceLine(index):
                    lineDrag = (index, layout.price(atY: value.location.y))
                case nil:
                    break
                }
            }
            .onEnded { _ in
                switch drag {
                case .draw:
                    if let draft {
                        model.addDrawing(draft)
                        model.setDrawTool(nil)
                    }
                case let .edit(original, _):
                    if let draft, draft != original { model.updateDrawing(draft) }
                case .priceLine:
                    if let lineDrag { model.movePriceLine(at: lineDrag.index, to: lineDrag.price) }
                default:
                    break
                }
                draft = nil
                lineDrag = nil
                drag = nil
            }
    }

    /// Horizontal scrolling pans; vertical scrolling and pinching zoom around the pointer.
    private func scroll(at point: CGPoint, dx: CGFloat, dy: CGFloat, magnification: CGFloat, layout: ChartLayout) {
        if point.x > layout.plot.maxX {
            model.setPriceScale(zoom: priceZoom * exp(dy * 0.01))
            return
        }
        let factor = magnification != 0 ? 1 + magnification : exp(dy * 0.01)
        if abs(dx) > abs(dy), magnification == 0 {
            model.setViewport(offset: offset + dx / pitch)
        } else if factor != 1 {
            let newPitch = PerpsModel.clampPitch(pitch * factor)
            // Keep the candle under the pointer where it is.
            let slots = (layout.plot.maxX - point.x) / pitch
            let anchored = offset + slots - (layout.plot.maxX - point.x) / newPitch
            model.setViewport(pitch: newPitch, offset: anchored)
        }
    }
}

struct ChartMeasure: Equatable {
    var startIndex: Int
    var startPrice: Double
    var endIndex: Int
    var endPrice: Double
}

// MARK: - Scroll and pinch

/// SwiftUI has no scroll-wheel or pinch callback on macOS, so watch the window's events and claim
/// the ones over this view.
private struct ChartScrollCatcher: NSViewRepresentable {
    let onScroll: @MainActor (_ point: CGPoint, _ dx: CGFloat, _ dy: CGFloat, _ magnification: CGFloat) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ nsView: CatcherView, context: Context) {
        nsView.onScroll = onScroll
    }

    final class CatcherView: NSView {
        var onScroll: (@MainActor (CGPoint, CGFloat, CGFloat, CGFloat) -> Void)?
        private var token: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let token { NSEvent.removeMonitor(token) }
            token = nil
            guard window != nil else { return }
            token = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { [weak self] event in
                let isMagnify = event.type == .magnify
                let location = event.locationInWindow
                let windowNumber = event.windowNumber
                // A mouse wheel reports whole lines; scale it to feel like a trackpad.
                let scale: CGFloat = isMagnify || event.hasPreciseScrollingDeltas ? 1 : 8
                let dx = isMagnify ? 0 : event.scrollingDeltaX * scale
                let dy = isMagnify ? 0 : event.scrollingDeltaY * scale
                let magnification = isMagnify ? event.magnification : 0
                let consumed = MainActor.assumeIsolated {
                    self?.handle(location, windowNumber: windowNumber, dx: dx, dy: dy, magnification: magnification) ?? false
                }
                return consumed ? nil : event
            }
        }

        private func handle(_ location: CGPoint, windowNumber: Int, dx: CGFloat, dy: CGFloat, magnification: CGFloat) -> Bool {
            guard !ChartInput.isSuspended, let window, window.windowNumber == windowNumber else { return false }
            let point = convert(location, from: nil)
            guard bounds.contains(point) else { return false }
            onScroll?(CGPoint(x: point.x, y: isFlipped ? point.y : bounds.height - point.y), dx, dy, magnification)
            return true
        }
    }
}

/// Set while something floats over the charts (the palette), so its list gets the scroll events.
@MainActor
enum ChartInput {
    static var isSuspended = false
}

// MARK: - Layout

struct ChartLayout {
    static let axisWidth: CGFloat = 70
    static let timeAxisHeight: CGFloat = 20
    /// Empty candle slots kept to the right of the newest candle.
    static let rightMargin: CGFloat = 3

    let size: CGSize
    let pitch: CGFloat
    /// What is drawn: the raw candles, or their Heikin Ashi form.
    let window: [HLCandle]
    /// Index in the full candle array of `window[0]`.
    let base: Int
    let count: Int
    /// Visible candle indices in the full array.
    let range: Range<Int>
    /// Fractional candle index at the plot's right edge.
    let rightEdge: CGFloat
    /// Everything left of the price axis and above the time axis.
    let plot: CGRect
    let mainPane: CGRect
    /// The part of the main pane prices are scaled to: below the legend, above the volume bars.
    let priceZone: CGRect
    let volumeZone: CGRect?
    /// The oscillator panes under the main one, top to bottom.
    let panes: [(indicator: ChartIndicator, frame: CGRect)]
    let isLog: Bool
    let isInverted: Bool
    /// The first close on screen when the axis shows percent change from it.
    let percentBase: Double?
    let low: Double
    let high: Double
    let maxVolume: Double
    /// Open time of the oldest candle when more history should be fetched.
    let historyKey: Int64?
    /// The live candle, whether or not it is on screen.
    let latest: HLCandle?
    /// The newest candle on screen; readouts fall back to it when nothing is inspected.
    var lastVisible: Int { range.upperBound - 1 }

    init(
        size: CGSize, candles: [HLCandle], pitch: CGFloat, offset: CGFloat,
        priceZoom: CGFloat, pricePan: CGFloat, settings: ChartSettings
    ) {
        self.size = size
        self.pitch = pitch
        count = candles.count
        plot = CGRect(x: 0, y: 0, width: max(size.width - Self.axisWidth, 1), height: max(size.height - Self.timeAxisHeight, 1))

        // Oscillator panes stack under the main pane when there is room for them.
        // They share what the main pane can spare, and the last ones drop out when that is too little.
        var subPanes = ChartIndicator.allCases.filter { $0.isPane && settings.indicators.contains($0) }
        var subHeight = min(max((plot.height * 0.2).rounded(), 64), 130)
        while !subPanes.isEmpty {
            subHeight = min(subHeight, ((plot.height - 150) / CGFloat(subPanes.count)).rounded(.down))
            if subHeight >= 44 { break }
            subPanes.removeLast()
        }
        let mainHeight = plot.height - CGFloat(subPanes.count) * subHeight
        mainPane = CGRect(x: 0, y: 0, width: plot.width, height: mainHeight)
        var frames: [(indicator: ChartIndicator, frame: CGRect)] = []
        for (position, pane) in subPanes.enumerated() {
            frames.append((pane, CGRect(x: 0, y: mainHeight + CGFloat(position) * subHeight, width: plot.width, height: subHeight)))
        }
        panes = frames

        let volumeHeight = settings.indicators.contains(.volume) ? (mainHeight * 0.16).rounded() : 0
        volumeZone = volumeHeight > 0
            ? CGRect(x: 0, y: mainPane.maxY - volumeHeight, width: plot.width, height: volumeHeight)
            : nil
        let top: CGFloat = 40
        priceZone = CGRect(x: 0, y: top, width: plot.width, height: max(mainHeight - top - volumeHeight - 10, 20))

        rightEdge = CGFloat(count - 1) + Self.rightMargin - offset
        let lower = max(0, Int((rightEdge - plot.width / pitch).rounded(.down)) - 1)
        let upper = min(count - 1, Int(rightEdge.rounded(.up)) + 1)
        range = upper >= lower && count > 0 ? lower..<(upper + 1) : 0..<0

        // Indicators need some lead-in before the first visible candle.
        base = max(0, range.lowerBound - 400)
        let raw = range.isEmpty ? [] : Array(candles[base..<range.upperBound])
        window = settings.style == .heikinAshi ? ChartMath.heikinAshi(raw) : raw

        let shown = range.isEmpty ? window[0..<0] : window[(range.lowerBound - base)...]
        let usesClose = settings.style.usesClose
        let rawLow = shown.map { usesClose ? $0.c : $0.l }.min() ?? 0
        let rawHigh = shown.map { usesClose ? $0.c : $0.h }.max() ?? 1
        isLog = settings.logScale && rawLow > 0
        isInverted = settings.invertScale
        percentBase = settings.percentScale ? shown.first(where: { $0.c > 0 })?.c : nil
        let transform: (Double) -> Double = isLog ? { log($0) } : { $0 }
        var autoLow = transform(rawLow), autoHigh = transform(rawHigh)
        if autoHigh <= autoLow {
            let pad = isLog ? 0.005 : max(abs(rawHigh) * 0.005, 0.0001)
            autoLow -= pad
            autoHigh += pad
        }
        let span = (autoHigh - autoLow) * 1.08
        let center = (autoHigh + autoLow) / 2 + Double(pricePan) * span
        low = center - span / 2 / Double(priceZoom)
        high = center + span / 2 / Double(priceZoom)
        maxVolume = shown.map(\.v).max() ?? 0

        latest = candles.last
        historyKey = count > 0 && range.lowerBound < 60 ? candles.first?.t : nil
    }

    /// Horizontal center of the candle at `index` in the full array.
    func x(_ index: Int) -> CGFloat {
        plot.maxX - (rightEdge - CGFloat(index)) * pitch - pitch / 2
    }

    func index(atX x: CGFloat) -> Int {
        Int((rightEdge - (plot.maxX - x - pitch / 2) / pitch).rounded())
    }

    func time(atX x: CGFloat) -> Int64? {
        let index = index(atX: x)
        return range.contains(index) ? window[index - base].t : nil
    }

    func y(_ price: Double) -> CGFloat {
        let value = isLog ? log(max(price, .leastNonzeroMagnitude)) : price
        let fraction = CGFloat((high - value) / (high - low))
        return priceZone.minY + (isInverted ? 1 - fraction : fraction) * priceZone.height
    }

    func price(atY y: CGFloat) -> Double {
        let fraction = Double((y - priceZone.minY) / priceZone.height)
        let value = high - (isInverted ? 1 - fraction : fraction) * (high - low)
        return isLog ? exp(value) : value
    }

    /// The price distance covered by `points` of height around the middle of the pane.
    func priceSpan(points: CGFloat) -> Double {
        abs(price(atY: priceZone.midY) - price(atY: priceZone.midY + points))
    }

    // MARK: Time anchors

    /// The time under a point, between candles and past either end of the data.
    func time(atPointX x: CGFloat, interval: HLInterval) -> Int64 {
        guard let first = window.first else { return 0 }
        let position = rightEdge - (plot.maxX - x - pitch / 2) / pitch - CGFloat(base)
        return first.t + Int64((Double(position) * Double(interval.milliseconds)).rounded())
    }

    /// Where a time falls on screen. Candles are evenly spaced, so this is linear from the window's first candle.
    func x(time: Int64, interval: HLInterval) -> CGFloat {
        guard let first = window.first else { return 0 }
        let position = Double(time - first.t) / Double(interval.milliseconds)
        return plot.maxX - (rightEdge - CGFloat(base) - CGFloat(position)) * pitch - pitch / 2
    }

    func candle(_ index: Int) -> HLCandle? {
        let position = index - base
        return window.indices.contains(position) ? window[position] : nil
    }
}

// MARK: - Renderer

struct ChartRenderer {
    let layout: ChartLayout
    let series: ChartSeries
    let cursorTime: Int64?
    let hover: CGPoint?
    let measure: ChartMeasure?
    let drawings: [ChartDrawing]
    let selectedDrawing: UUID?
    let interval: HLInterval
    let decimals: Int
    let settings: ChartSettings
    let priceLines: [Double]
    let levels: [ChartLevel]
    let isReplay: Bool
    let isLoadingHistory: Bool

    /// User-drawn price lines; blue so they stand apart from the gold accent.
    private static let lineColor = ChartTint.blue
    let labelFont = Font.system(size: 10.5, design: .monospaced)
    private let grid = Color.primary.opacity(0.07)
    let up = PowderPalette.signalGreen
    let down = PowderPalette.riskCoral

    private var zone: TimeZone { interval.isDaily ? .gmt : .current }

    func draw(in context: inout GraphicsContext, now: Date) {
        guard !layout.range.isEmpty else { return }
        let cursorIndex = cursorTime.flatMap { time in layout.range.last { layout.candle($0)?.t == time } }

        drawPriceAxis(&context)
        drawTimeAxis(&context)

        var pane = context
        pane.clip(to: Path(layout.mainPane))
        drawVolume(&pane)
        if settings.indicators.contains(.volumeProfile) { drawVolumeProfile(&pane) }
        if let cloud = series.ichimoku { drawIchimoku(cloud, in: &pane) }
        for band in series.bands { drawBand(band, in: &pane) }
        drawSeries(&pane)
        for line in series.lines {
            stroke(line.values, color: line.color, y: layout.y, in: &pane)
        }
        if let trend = series.supertrend { drawSupertrend(trend, in: &pane) }
        if let stops = series.sar { drawSAR(stops, in: &pane) }
        drawExtremes(&pane)
        drawPriceLines(&pane, axis: &context)
        drawLevels(&pane, axis: &context)
        if !settings.hideDrawings { drawDrawings(&pane, axis: &context) }
        drawLastPrice(&context, now: now)

        for (indicator, frame) in layout.panes {
            if let study = series.panes[indicator] { drawPane(study, frame: frame, cursor: cursorIndex, in: &context) }
        }

        if let measure {
            drawMeasure(
                from: CGPoint(x: layout.x(measure.startIndex), y: layout.y(measure.startPrice)),
                to: CGPoint(x: layout.x(measure.endIndex), y: layout.y(measure.endPrice)),
                startPrice: measure.startPrice, endPrice: measure.endPrice, bars: measure.endIndex - measure.startIndex, in: &context
            )
        }
        drawCrosshair(cursorIndex, in: &context)
        drawLegend(cursorIndex ?? layout.lastVisible, in: &context)

        if isLoadingHistory {
            context.draw(
                Text("loading history…").font(labelFont).foregroundStyle(.secondary),
                at: CGPoint(x: 10, y: layout.mainPane.maxY - 12), anchor: .leading
            )
        }
    }

    // MARK: Axes

    private func drawPriceAxis(_ context: inout GraphicsContext) {
        var prices: [Double] = []
        if layout.isLog {
            // Even spacing on screen; the labels are whatever prices fall there.
            prices = stride(from: layout.mainPane.minY + 30, to: layout.mainPane.maxY, by: 56).map { layout.price(atY: $0) }
        } else {
            // Round steps of price, or of percent change when the axis shows that.
            let base = layout.percentBase
            let scaled: (Double) -> Double = { price in base.map { price / $0 - 1 } ?? price }
            let edges = [scaled(layout.price(atY: layout.mainPane.minY)), scaled(layout.price(atY: layout.mainPane.maxY))]
            let top = max(edges[0], edges[1]), bottom = min(edges[0], edges[1])
            let step = Self.niceStep((top - bottom) / max(Double(layout.mainPane.height / 56), 2))
            if step > 0 {
                var value = (bottom / step).rounded(.up) * step
                while value <= top {
                    prices.append(base.map { $0 * (1 + value) } ?? value)
                    value += step
                }
            }
        }
        for price in prices {
            let y = layout.y(price).rounded() + 0.5
            guard y > layout.mainPane.minY + 6, y < layout.mainPane.maxY - 4 else { continue }
            context.stroke(horizontal(y), with: .color(grid), lineWidth: 1)
            let label = layout.percentBase.map { HLFormat.percent(price / $0 - 1) } ?? HLFormat.price(price, decimals: decimals)
            axisLabel(label, y: y, in: &context)
        }
        context.stroke(
            Path { path in
                path.move(to: CGPoint(x: layout.plot.maxX + 0.5, y: 0))
                path.addLine(to: CGPoint(x: layout.plot.maxX + 0.5, y: layout.size.height))
            },
            with: .color(Term.rule), lineWidth: 1
        )
        context.stroke(horizontal(layout.plot.maxY + 0.5, to: layout.size.width), with: .color(Term.rule), lineWidth: 1)
    }

    private func axisLabel(_ string: String, y: CGFloat, in context: inout GraphicsContext) {
        context.draw(
            Text(string).font(labelFont).foregroundStyle(.secondary),
            at: CGPoint(x: layout.plot.maxX + 8, y: y), anchor: .leading
        )
    }

    private func drawTimeAxis(_ context: inout GraphicsContext) {
        let minimumSlots = Int64((96 / layout.pitch).rounded(.up))
        let offset = Int64(zone.secondsFromGMT()) * 1_000
        let day: Int64 = 86_400_000
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt

        // Intraday labels land on round clock times; longer intervals count candles.
        let spans: [Int64] = [1, 5, 15, 30, 60, 120, 240, 360, 720, 1_440, 2_880, 10_080].map { $0 * 60_000 }
        let span = spans.first { $0 >= interval.milliseconds && $0 / interval.milliseconds >= minimumSlots }
        let every = [1, 2, 3, 4, 6, 12, 24, 60, 120].first { Int64($0) >= minimumSlots } ?? 240

        for index in layout.range {
            guard let candle = layout.candle(index) else { continue }
            let isLabelled: Bool
            if interval == .mo1 {
                let parts = calendar.dateComponents([.year, .month], from: Date(timeIntervalSince1970: Double(candle.t) / 1_000))
                isLabelled = ((parts.year ?? 0) * 12 + (parts.month ?? 0)) % every == 0
            } else if interval.isDaily || span == nil {
                isLabelled = Int(candle.t / interval.milliseconds) % every == 0
            } else {
                isLabelled = (candle.t + offset) % (span ?? day) == 0
            }
            guard isLabelled else { continue }
            let x = layout.x(index).rounded() + 0.5
            guard x > 28, x < layout.plot.maxX - 24 else { continue }
            context.stroke(vertical(x), with: .color(grid), lineWidth: 1)
            let showsDate = interval.isDaily || (span ?? day) >= day || (candle.t + offset) % day == 0
            context.draw(
                Text(timeLabel(candle.t, date: showsDate, time: !showsDate)).font(labelFont).foregroundStyle(.secondary),
                at: CGPoint(x: x, y: layout.plot.maxY + ChartLayout.timeAxisHeight / 2), anchor: .center
            )
        }
    }

    // MARK: Main pane

    private var bodyWidth: CGFloat {
        max((layout.pitch * 0.72).rounded(), 1)
    }

    private func drawVolume(_ context: inout GraphicsContext) {
        guard let zone = layout.volumeZone, layout.maxVolume > 0 else { return }
        // All the rising bars are one shape and all the falling bars another: two fills, however many candles show.
        var rising = Path(), falling = Path()
        for index in layout.range {
            guard let candle = layout.candle(index) else { continue }
            let height = max(CGFloat(candle.v / layout.maxVolume) * zone.height, 1)
            let bar = CGRect(x: layout.x(index).rounded() - bodyWidth / 2, y: zone.maxY - height, width: bodyWidth, height: height)
            if candle.c >= candle.o { rising.addRect(bar) } else { falling.addRect(bar) }
        }
        context.fill(rising, with: .color(up.opacity(0.3)))
        context.fill(falling, with: .color(down.opacity(0.3)))
    }

    private func drawSeries(_ context: inout GraphicsContext) {
        switch settings.style {
        case .line, .step, .area, .baseline:
            var points: [CGPoint] = []
            points.reserveCapacity(layout.range.count)
            for index in layout.range {
                guard let candle = layout.candle(index) else { continue }
                points.append(CGPoint(x: layout.x(index), y: layout.y(candle.c)))
            }
            guard let first = points.first, let last = points.last else { return }
            var trace = Path()
            trace.move(to: first)
            for (previous, point) in zip(points, points.dropFirst()) {
                if settings.style == .step { trace.addLine(to: CGPoint(x: point.x, y: previous.y)) }
                trace.addLine(to: point)
            }
            /// The trace closed down (or up) to a level, for filling.
            func closed(at y: CGFloat) -> Path {
                var path = trace
                path.addLine(to: CGPoint(x: last.x, y: y))
                path.addLine(to: CGPoint(x: first.x, y: y))
                path.closeSubpath()
                return path
            }
            let lineStyle = StrokeStyle(lineWidth: 1.5, lineJoin: .round)
            if settings.style == .baseline {
                // Green above the middle of the pane and red below it: each half is the same trace, clipped.
                let baseY = layout.priceZone.midY.rounded() + 0.5
                let halves = [
                    (CGRect(x: 0, y: layout.mainPane.minY, width: layout.plot.width, height: baseY - layout.mainPane.minY), layout.isInverted ? down : up),
                    (CGRect(x: 0, y: baseY, width: layout.plot.width, height: layout.mainPane.maxY - baseY), layout.isInverted ? up : down),
                ]
                for (frame, color) in halves {
                    var half = context
                    half.clip(to: Path(frame))
                    half.fill(closed(at: baseY), with: .color(color.opacity(0.14)))
                    half.stroke(trace, with: .color(color), style: lineStyle)
                }
                context.stroke(horizontal(baseY), with: .color(Term.foreground.opacity(0.4)), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
            } else {
                if settings.style == .area {
                    context.fill(closed(at: layout.mainPane.maxY), with: .linearGradient(
                        Gradient(colors: [Term.accent.opacity(0.32), Term.accent.opacity(0.02)]),
                        startPoint: CGPoint(x: 0, y: layout.priceZone.minY),
                        endPoint: CGPoint(x: 0, y: layout.mainPane.maxY)
                    ))
                }
                context.stroke(trace, with: .color(Term.accent), style: lineStyle)
            }

        case .bars:
            let tick = max((layout.pitch * 0.36).rounded(), 1)
            for index in layout.range {
                guard let candle = layout.candle(index) else { continue }
                let color = candle.c >= candle.o ? up : down
                let x = layout.x(index).rounded()
                var path = Path()
                path.move(to: CGPoint(x: x + 0.5, y: layout.y(candle.h)))
                path.addLine(to: CGPoint(x: x + 0.5, y: layout.y(candle.l)))
                path.move(to: CGPoint(x: x - tick, y: layout.y(candle.o)))
                path.addLine(to: CGPoint(x: x + 0.5, y: layout.y(candle.o)))
                path.move(to: CGPoint(x: x + 0.5, y: layout.y(candle.c)))
                path.addLine(to: CGPoint(x: x + tick + 1, y: layout.y(candle.c)))
                context.stroke(path, with: .color(color), lineWidth: 1)
            }

        case .candles, .heikinAshi:
            // Wicks and bodies of one colour are a single shape, so a full chart is two fills.
            var rising = Path(), falling = Path()
            for index in layout.range {
                guard let candle = layout.candle(index) else { continue }
                let x = layout.x(index).rounded()
                let wick = span(candle.h, candle.l, x: x - 0.5, width: 1)
                let body = span(candle.o, candle.c, x: x - bodyWidth / 2, width: bodyWidth)
                if candle.c >= candle.o {
                    rising.addRect(wick)
                    rising.addRect(body)
                } else {
                    falling.addRect(wick)
                    falling.addRect(body)
                }
            }
            context.fill(rising, with: .color(up))
            context.fill(falling, with: .color(down))

        case .hollow:
            for index in layout.range {
                guard let candle = layout.candle(index) else { continue }
                let rises = candle.c >= candle.o
                let color = rises ? up : down
                let x = layout.x(index).rounded()
                let wick = span(candle.h, candle.l, x: x - 0.5, width: 1)
                let body = span(candle.o, candle.c, x: x - bodyWidth / 2, width: bodyWidth)
                context.fill(Path(wick), with: .color(color))
                if settings.style == .hollow, rises, bodyWidth >= 3 {
                    context.fill(Path(body), with: .color(Term.background))
                    context.stroke(Path(body.insetBy(dx: 0.5, dy: 0.5)), with: .color(color), lineWidth: 1)
                } else {
                    context.fill(Path(body), with: .color(color))
                }
            }
        }
    }

    /// The bar between two prices, whichever way up the axis is.
    private func span(_ a: Double, _ b: Double, x: CGFloat, width: CGFloat) -> CGRect {
        let first = layout.y(a), second = layout.y(b)
        return CGRect(x: x, y: min(first, second), width: width, height: max(abs(second - first), 1))
    }

    private func drawBand(_ band: ChartSeries.Band, in context: inout GraphicsContext) {
        var fill = Path()
        var lowerPoints: [CGPoint] = []
        var started = false
        for index in layout.range {
            guard let upper = value(band.upper, index), let lower = value(band.lower, index) else { continue }
            let point = CGPoint(x: layout.x(index), y: layout.y(upper))
            if started { fill.addLine(to: point) } else { fill.move(to: point); started = true }
            lowerPoints.append(CGPoint(x: layout.x(index), y: layout.y(lower)))
        }
        if started {
            for point in lowerPoints.reversed() { fill.addLine(to: point) }
            fill.closeSubpath()
            context.fill(fill, with: .color(band.color.opacity(0.07)))
        }
        stroke(band.upper, color: band.color.opacity(0.8), y: layout.y, in: &context)
        stroke(band.lower, color: band.color.opacity(0.8), y: layout.y, in: &context)
        if let middle = band.middle { stroke(middle, color: band.color.opacity(0.45), y: layout.y, in: &context) }
    }

    /// Volume by price for the candles on screen, as bars growing in from the right. Each candle's volume
    /// is spread evenly over the prices it traded through; the busiest price is marked across the pane.
    private func drawVolumeProfile(_ context: inout GraphicsContext) {
        let zone = layout.priceZone
        let rows = max(Int(zone.height / 6), 8)
        var bought = [Double](repeating: 0, count: rows), sold = bought
        for index in layout.range {
            guard let candle = layout.candle(index), candle.v > 0 else { continue }
            let x = layout.x(index)
            guard x >= layout.plot.minX, x <= layout.plot.maxX else { continue }
            let a = layout.y(candle.h), b = layout.y(candle.l)
            let first = Int(((min(a, b) - zone.minY) / zone.height * CGFloat(rows)).rounded(.down))
            let last = Int(((max(a, b) - zone.minY) / zone.height * CGFloat(rows)).rounded(.down))
            let from = max(first, 0), through = min(last, rows - 1)
            guard from <= through else { continue }
            let share = candle.v / Double(last - first + 1)
            for row in from...through {
                if candle.c >= candle.o { bought[row] += share } else { sold[row] += share }
            }
        }
        var peak = 0.0, peakRow = 0
        for row in 0..<rows where bought[row] + sold[row] > peak {
            peak = bought[row] + sold[row]
            peakRow = row
        }
        guard peak > 0 else { return }
        let reach = layout.plot.width * 0.24, rowHeight = zone.height / CGFloat(rows)
        var rising = Path(), falling = Path()
        for row in 0..<rows where bought[row] + sold[row] > 0 {
            let y = zone.minY + CGFloat(row) * rowHeight
            let buyWidth = CGFloat(bought[row] / peak) * reach, sellWidth = CGFloat(sold[row] / peak) * reach
            let height = max(rowHeight - 1, 1)
            rising.addRect(CGRect(x: layout.plot.maxX - buyWidth, y: y, width: buyWidth, height: height))
            falling.addRect(CGRect(x: layout.plot.maxX - buyWidth - sellWidth, y: y, width: sellWidth, height: height))
        }
        context.fill(rising, with: .color(up.opacity(0.22)))
        context.fill(falling, with: .color(down.opacity(0.22)))
        let peakY = (zone.minY + (CGFloat(peakRow) + 0.5) * rowHeight).rounded() + 0.5
        context.stroke(horizontal(peakY), with: .color(Term.accent.opacity(0.55)), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
        context.draw(
            Text("POC \(HLFormat.price(layout.price(atY: peakY), decimals: decimals))").font(labelFont).foregroundStyle(Term.accent),
            at: CGPoint(x: layout.plot.maxX - 6, y: peakY - 8), anchor: .trailing
        )
    }

    /// The cloud between the two leading spans, green where the first is on top, and the three lines over it.
    private func drawIchimoku(_ cloud: ChartMath.Ichimoku, in context: inout GraphicsContext) {
        var bullish = Path(), bearish = Path()
        for index in layout.range.lowerBound..<(layout.range.upperBound + cloud.shift - 1) {
            guard let a0 = value(cloud.spanA, index), let b0 = value(cloud.spanB, index),
                  let a1 = value(cloud.spanA, index + 1), let b1 = value(cloud.spanB, index + 1) else { continue }
            let x0 = layout.x(index), x1 = layout.x(index + 1)
            let corners = [
                CGPoint(x: x0, y: layout.y(a0)), CGPoint(x: x1, y: layout.y(a1)),
                CGPoint(x: x1, y: layout.y(b1)), CGPoint(x: x0, y: layout.y(b0)),
            ]
            if a0 + a1 >= b0 + b1 { bullish.addLines(corners); bullish.closeSubpath() } else { bearish.addLines(corners); bearish.closeSubpath() }
        }
        context.fill(bullish, with: .color(up.opacity(0.1)))
        context.fill(bearish, with: .color(down.opacity(0.1)))
        stroke(cloud.spanA, color: up.opacity(0.55), y: layout.y, extend: cloud.shift, in: &context)
        stroke(cloud.spanB, color: down.opacity(0.55), y: layout.y, extend: cloud.shift, in: &context)
        stroke(cloud.lagging, color: ChartTint.purple.opacity(0.6), y: layout.y, in: &context)
        stroke(cloud.conversion, color: ChartTint.blue, y: layout.y, in: &context)
        stroke(cloud.base, color: ChartTint.orange, y: layout.y, in: &context)
    }

    /// One line in two colours: green while it trails under price, red while it sits over it.
    private func drawSupertrend(_ trend: (line: [Double?], rising: [Bool]), in context: inout GraphicsContext) {
        var rising = Path(), falling = Path()
        for index in layout.range.dropFirst() {
            let position = index - layout.base
            guard position > 0, position < trend.rising.count, trend.rising[position] == trend.rising[position - 1],
                  let from = value(trend.line, index - 1), let to = value(trend.line, index) else { continue }
            let a = CGPoint(x: layout.x(index - 1), y: layout.y(from)), b = CGPoint(x: layout.x(index), y: layout.y(to))
            if trend.rising[position] {
                rising.move(to: a)
                rising.addLine(to: b)
            } else {
                falling.move(to: a)
                falling.addLine(to: b)
            }
        }
        let style = StrokeStyle(lineWidth: 1.5, lineCap: .round)
        context.stroke(rising, with: .color(up), style: style)
        context.stroke(falling, with: .color(down), style: style)
    }

    private func drawSAR(_ stops: [Double?], in context: inout GraphicsContext) {
        let radius = min(max(layout.pitch * 0.18, 1), 2.5)
        var dots = Path()
        for index in layout.range {
            guard let stop = value(stops, index) else { continue }
            dots.addEllipse(in: CGRect(x: layout.x(index) - radius, y: layout.y(stop) - radius, width: radius * 2, height: radius * 2))
        }
        context.fill(dots, with: .color(ChartTint.blue))
    }

    /// Marks the highest high and lowest low on screen.
    private func drawExtremes(_ context: inout GraphicsContext) {
        guard !settings.style.usesClose else { return }
        var highest: (index: Int, price: Double)?
        var lowest: (index: Int, price: Double)?
        for index in layout.range {
            guard let candle = layout.candle(index), layout.x(index) <= layout.plot.maxX else { continue }
            if candle.h > (highest?.price ?? -.infinity) { highest = (index, candle.h) }
            if candle.l < (lowest?.price ?? .infinity) { lowest = (index, candle.l) }
        }
        for (mark, isHigh) in [(highest, true), (lowest, false)] {
            guard let mark else { continue }
            let x = layout.x(mark.index)
            let leftSide = x > layout.plot.midX
            let y = layout.y(mark.price) + (isHigh != layout.isInverted ? -7 : 7)
            let label = HLFormat.price(mark.price, decimals: decimals)
            context.draw(
                Text(leftSide ? "\(label) ─" : "─ \(label)").font(labelFont).foregroundStyle(Term.foreground.opacity(0.75)),
                at: CGPoint(x: x, y: y), anchor: leftSide ? .trailing : .leading
            )
        }
    }

    private func drawPriceLines(_ pane: inout GraphicsContext, axis: inout GraphicsContext) {
        for price in priceLines {
            let y = layout.y(price).rounded() + 0.5
            guard y >= layout.mainPane.minY, y <= layout.mainPane.maxY else { continue }
            pane.stroke(horizontal(y), with: .color(Self.lineColor.opacity(0.9)), lineWidth: 1)
            tag(HLFormat.price(price, decimals: decimals), fill: Self.lineColor, at: CGPoint(x: layout.plot.maxX + 1, y: y), anchor: .leading, in: &axis)
        }
    }

    /// The position's entry and liquidation prices: a dashed line, a label at the left and the price on the axis.
    /// A level outside the visible range is pinned to the edge with an arrow so it is never lost.
    private func drawLevels(_ pane: inout GraphicsContext, axis: inout GraphicsContext) {
        for level in levels {
            let color: Color = switch level.kind {
            case .entryLong, .orderBuy, .takeProfit: up
            case .entryShort, .orderSell, .stopLoss: down
            case .liquidation: PowderPalette.cautionAmber
            case .alert: Term.accent
            }
            // A position is dashed; an order waiting on the book is dotted, an alert a thin solid line.
            let dash: [CGFloat] = switch level.kind {
            case .orderBuy, .orderSell: [2, 3]
            case .alert: []
            default: [6, 3]
            }
            let rawY = layout.y(level.price).rounded() + 0.5
            let y = min(max(rawY, layout.mainPane.minY + 8), layout.mainPane.maxY - 8)
            var label = level.label
            if rawY == y {
                pane.stroke(horizontal(y), with: .color(color.opacity(0.9)), style: StrokeStyle(lineWidth: 1, dash: dash))
            } else {
                label += rawY < y ? " ↑" : " ↓"
            }
            tag(label, fill: color, at: CGPoint(x: layout.plot.minX + 6, y: y), anchor: .leading, in: &pane)
            tag(HLFormat.price(level.price, decimals: decimals), fill: color, at: CGPoint(x: layout.plot.maxX + 1, y: y), anchor: .leading, in: &axis)
        }
    }

    private func drawLastPrice(_ context: inout GraphicsContext, now: Date) {
        guard let last = layout.latest else { return }
        let color = last.c >= last.o ? up : down
        let rawY = layout.y(last.c).rounded() + 0.5
        let y = min(max(rawY, layout.mainPane.minY + 8), layout.mainPane.maxY - 8)
        if rawY == y {
            context.stroke(horizontal(y), with: .color(color.opacity(0.7)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }
        tag(HLFormat.price(last.c, decimals: decimals), fill: color, at: CGPoint(x: layout.plot.maxX + 1, y: y), anchor: .leading, in: &context)

        // Time left in the forming candle.
        guard interval != .mo1, !isReplay else { return }
        let close = Date(timeIntervalSince1970: Double(last.t + interval.milliseconds) / 1_000)
        let seconds = max(Int(close.timeIntervalSince(now)), 0)
        let text = seconds >= 86_400
            ? "\(seconds / 86_400)d \(seconds % 86_400 / 3_600)h"
            : seconds >= 3_600
                ? String(format: "%d:%02d:%02d", seconds / 3_600, seconds % 3_600 / 60, seconds % 60)
                : String(format: "%02d:%02d", seconds / 60, seconds % 60)
        context.draw(
            Text(text).font(labelFont).foregroundStyle(color),
            at: CGPoint(x: layout.plot.maxX + 7, y: y + 15), anchor: .leading
        )
    }

    // MARK: Oscillators

    private func paneFrame(_ frame: CGRect, title: String, in context: inout GraphicsContext) {
        context.stroke(horizontal(frame.minY + 0.5), with: .color(Term.rule), lineWidth: 1)
        context.draw(
            Text(title).font(labelFont).foregroundStyle(.secondary),
            at: CGPoint(x: 8, y: frame.minY + 10), anchor: .leading
        )
    }

    /// Any oscillator: its guide levels, histogram and lines on a scale of its own, with the readout in the title.
    private func drawPane(_ study: ChartSeries.Pane, frame: CGRect, cursor: Int?, in context: inout GraphicsContext) {
        let format: (Double) -> String = { value in
            switch study.format {
            case .price: HLFormat.price(value, decimals: decimals)
            case .compact: HLFormat.compact(value)
            case let .plain(places): String(format: "%.\(places)f", value)
            }
        }
        let at = cursor ?? layout.lastVisible
        var readout: [String] = study.lines.map { line in
            (line.label.isEmpty ? "" : line.label + " ") + (value(line.values, at).map(format) ?? "–")
        }
        if let bars = study.histogram { readout.append(value(bars, at).map(format) ?? "–") }
        let title = study.title + "  " + readout.joined(separator: "  ")

        var low = Double.infinity, high = -Double.infinity
        switch study.scale {
        case let .fixed(range):
            low = range.lowerBound
            high = range.upperBound
        case .auto, .centered:
            for index in layout.range {
                for line in study.lines {
                    if let value = value(line.values, index) {
                        low = min(low, value)
                        high = max(high, value)
                    }
                }
                if let value = study.histogram.flatMap({ value($0, index) }) {
                    low = min(low, value)
                    high = max(high, value)
                }
            }
            if case .centered = study.scale {
                let extent = max(abs(low), abs(high), study.guides.map(abs).max() ?? 0)
                low = -extent
                high = extent
            }
        }
        guard low.isFinite, high.isFinite, high > low else {
            paneFrame(frame, title: study.title, in: &context)
            return
        }
        let inner = frame.insetBy(dx: 0, dy: 8)
        let y: (Double) -> CGFloat = { inner.minY + CGFloat((high - $0) / (high - low)) * inner.height }

        for guide in study.guides {
            let line = y(guide).rounded() + 0.5
            context.stroke(horizontal(line), with: .color(Color.primary.opacity(0.16)), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
            axisLabel(format(guide), y: line, in: &context)
        }
        if study.guides.isEmpty {
            axisLabel(format(high), y: inner.minY + 4, in: &context)
            axisLabel(format(low), y: inner.maxY - 4, in: &context)
        }

        var pane = context
        pane.clip(to: Path(frame))
        if low < 0, high > 0 {
            pane.stroke(horizontal(y(0).rounded() + 0.5), with: .color(Color.primary.opacity(0.14)), lineWidth: 1)
        }
        if let bars = study.histogram {
            let zero = y(min(max(0, low), high))
            var rising = Path(), falling = Path()
            for index in layout.range {
                guard let bar = value(bars, index) else { continue }
                let rect = CGRect(x: layout.x(index).rounded() - bodyWidth / 2, y: min(y(bar), zero), width: bodyWidth, height: max(abs(y(bar) - zero), 1))
                if bar >= 0 { rising.addRect(rect) } else { falling.addRect(rect) }
            }
            pane.fill(rising, with: .color(up.opacity(0.55)))
            pane.fill(falling, with: .color(down.opacity(0.55)))
        }
        for line in study.lines {
            stroke(line.values, color: line.color, y: y, in: &pane)
        }
        paneFrame(frame, title: title, in: &context)
    }

    // MARK: Crosshair, measure, legend

    private func drawCrosshair(_ cursorIndex: Int?, in context: inout GraphicsContext) {
        let style = StrokeStyle(lineWidth: 1, dash: [4, 3])
        let color = Term.foreground.opacity(0.45)
        if let cursorIndex, let time = cursorTime {
            let x = layout.x(cursorIndex).rounded() + 0.5
            if x <= layout.plot.maxX {
                context.stroke(vertical(x), with: .color(color), style: style)
                tag(
                    timeLabel(time, date: true, time: !interval.isDaily),
                    fill: Color(dark: 0x4A4A4A, light: 0x5A5A5A), text: .white,
                    at: CGPoint(x: min(max(x, 52), layout.plot.maxX - 52), y: layout.plot.maxY + ChartLayout.timeAxisHeight / 2),
                    anchor: .center, in: &context
                )
            }
        }
        guard let hover, hover.x <= layout.plot.maxX, hover.y <= layout.plot.maxY else { return }
        let y = hover.y.rounded() + 0.5
        context.stroke(horizontal(y), with: .color(color), style: style)
        if layout.mainPane.contains(hover) {
            tag(
                HLFormat.price(layout.price(atY: hover.y), decimals: decimals),
                fill: Color(dark: 0x4A4A4A, light: 0x5A5A5A), text: .white,
                at: CGPoint(x: layout.plot.maxX + 1, y: y), anchor: .leading, in: &context
            )
        }
    }

    /// A shaded box between two points with what lies between them: price change, percent, bars and time.
    func drawMeasure(
        from start: CGPoint, to end: CGPoint, startPrice: Double, endPrice: Double, bars: Int, in context: inout GraphicsContext
    ) {
        let rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
        let rises = endPrice >= startPrice
        let color = rises ? up : down
        var pane = context
        pane.clip(to: Path(layout.mainPane))
        pane.fill(Path(rect), with: .color(color.opacity(0.14)))
        pane.stroke(Path(rect), with: .color(color.opacity(0.7)), lineWidth: 1)

        let change = endPrice - startPrice
        let percent = startPrice > 0 ? HLFormat.percent(change / startPrice) : ""
        let sign = change >= 0 ? "+" : "−"
        let label = "\(sign)\(HLFormat.price(abs(change), decimals: decimals))  \(percent)  ·  \(bars) bars  \(Self.duration(Int64(abs(bars)) * interval.milliseconds))"
        let anchorY = end.y <= start.y ? rect.minY - 12 : rect.maxY + 12
        tag(
            label, fill: color,
            at: CGPoint(x: min(max(rect.midX, 110), layout.plot.maxX - 110), y: min(max(anchorY, 12), layout.mainPane.maxY - 12)),
            anchor: .center, in: &context
        )
    }

    private func drawLegend(_ index: Int, in context: inout GraphicsContext) {
        guard let candle = layout.candle(index) else { return }
        let color = candle.c >= candle.o ? up : down
        let price: (Double?) -> String = { $0.map { HLFormat.price($0, decimals: decimals) } ?? "–" }
        var first: [(String, Color)] = []
        for (label, value) in [("O", candle.o), ("H", candle.h), ("L", candle.l), ("C", candle.c)] {
            first.append((label, .secondary))
            first.append((price(value), color))
        }
        if candle.o > 0 { first.append((HLFormat.percent(candle.c / candle.o - 1), color)) }
        first.append(("V", .secondary))
        first.append((HLFormat.compact(candle.v), Term.foreground))
        if settings.style == .heikinAshi { first.append(("HA", .secondary)) }
        if layout.isLog { first.append(("LOG", .secondary)) }
        if layout.percentBase != nil { first.append(("%", .secondary)) }
        if layout.isInverted { first.append(("INV", .secondary)) }
        if isReplay { first.append(("REPLAY", PowderPalette.cautionAmber)) }
        legendLine(first, y: 12, in: &context)

        // Each study keeps its label and values together; a full row wraps to the next.
        var groups: [[(String, Color)]] = series.lines.map { line in
            [(line.label, .secondary), (price(value(line.values, index)), line.color)]
        }
        for band in series.bands {
            groups.append([(band.label, .secondary), (price(value(band.upper, index)), band.color), (price(value(band.lower, index)), band.color)])
        }
        if let trend = series.supertrend {
            let rising = trend.rising.indices.contains(index - layout.base) ? trend.rising[index - layout.base] : true
            groups.append([("ST", .secondary), (price(value(trend.line, index)), rising ? up : down)])
        }
        if let stops = series.sar { groups.append([("SAR", .secondary), (price(value(stops, index)), ChartTint.blue)]) }
        if let cloud = series.ichimoku {
            groups.append([
                ("ICHI", .secondary), (price(value(cloud.conversion, index)), ChartTint.blue), (price(value(cloud.base, index)), ChartTint.orange),
                (price(value(cloud.spanA, index)), up), (price(value(cloud.spanB, index)), down),
            ])
        }
        var x: CGFloat = 10, y: CGFloat = 28
        for group in groups {
            let texts = group.map { context.resolve(Text($0.0).font(labelFont).foregroundStyle($0.1)) }
            let widths = texts.map { $0.measure(in: CGSize(width: 400, height: 40)).width }
            let width = widths.reduce(0, +) + CGFloat(widths.count) * 6
            if x > 10, x + width > layout.plot.maxX - 6 {
                x = 10
                y += 15
            }
            guard y < layout.mainPane.maxY - 20 else { return }
            for (text, width) in zip(texts, widths) {
                context.draw(text, at: CGPoint(x: x, y: y), anchor: .leading)
                x += width + 6
            }
            x += 4
        }
    }

    private func legendLine(_ parts: [(String, Color)], y: CGFloat, in context: inout GraphicsContext) {
        var x: CGFloat = 10
        for (string, color) in parts {
            let text = context.resolve(Text(string).font(labelFont).foregroundStyle(color))
            let width = text.measure(in: CGSize(width: 400, height: 40)).width
            guard x + width < layout.plot.maxX - 6 else { return }
            context.draw(text, at: CGPoint(x: x, y: y), anchor: .leading)
            x += width + 6
        }
    }

    // MARK: Helpers

    private func value(_ values: [Double?], _ index: Int) -> Double? {
        let position = index - layout.base
        return values.indices.contains(position) ? values[position] : nil
    }

    /// Polyline through the visible part of a window-indexed series, broken where values are missing.
    private func stroke(
        _ values: [Double?], color: Color, width: CGFloat = 1, y: (Double) -> CGFloat, extend: Int = 0,
        in context: inout GraphicsContext
    ) {
        var path = Path()
        var isDrawing = false
        // `extend` carries on past the newest candle, for series projected ahead of it.
        for index in layout.range.lowerBound..<(layout.range.upperBound + extend) {
            guard let value = value(values, index) else {
                isDrawing = false
                continue
            }
            let point = CGPoint(x: layout.x(index), y: y(value))
            if isDrawing { path.addLine(to: point) } else { path.move(to: point) }
            isDrawing = true
        }
        context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineJoin: .round))
    }

    private func horizontal(_ y: CGFloat, to maxX: CGFloat? = nil) -> Path {
        Path { path in
            path.move(to: CGPoint(x: layout.plot.minX, y: y))
            path.addLine(to: CGPoint(x: maxX ?? layout.plot.maxX, y: y))
        }
    }

    private func vertical(_ x: CGFloat) -> Path {
        Path { path in
            path.move(to: CGPoint(x: x, y: layout.plot.minY))
            path.addLine(to: CGPoint(x: x, y: layout.plot.maxY))
        }
    }

    /// A filled label, used for prices on the axis, the cursor time and the measure readout.
    func tag(
        _ string: String, fill: Color, text textColor: Color = PowderPalette.graphite,
        at point: CGPoint, anchor: UnitPoint, in context: inout GraphicsContext
    ) {
        let text = context.resolve(Text(string).font(labelFont.weight(.semibold)).foregroundStyle(textColor))
        let textSize = text.measure(in: CGSize(width: 600, height: 40))
        let size = CGSize(width: textSize.width + 12, height: textSize.height + 4)
        let origin = CGPoint(x: point.x - size.width * anchor.x, y: point.y - size.height * anchor.y)
        context.fill(Path(CGRect(origin: origin, size: size)), with: .color(fill))
        context.draw(text, at: CGPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2), anchor: .center)
    }

    func timeLabel(_ milliseconds: Int64, date: Bool, time: Bool) -> String {
        let value = Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
        var parts: [String] = []
        if date {
            var style = interval == .mo1 || interval == .w1
                ? Date.FormatStyle.dateTime.month(.abbreviated).year()
                : Date.FormatStyle.dateTime.month(.abbreviated).day()
            if interval == .w1 { style = Date.FormatStyle.dateTime.month(.abbreviated).day().year(.twoDigits) }
            style.timeZone = zone
            parts.append(value.formatted(style))
        }
        if time {
            var style = Date.FormatStyle.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).locale(HLFormat.clock24)
            style.timeZone = zone
            parts.append(value.formatted(style))
        }
        return parts.joined(separator: " ")
    }

    private static func duration(_ milliseconds: Int64) -> String {
        let minutes = milliseconds / 60_000
        if minutes >= 2_880 { return "\(minutes / 1_440)d" }
        if minutes >= 60 { return minutes % 60 == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h \(minutes % 60)m" }
        return "\(minutes)m"
    }

    private static func niceStep(_ raw: Double) -> Double {
        guard raw > 0, raw.isFinite else { return 0 }
        let magnitude = pow(10, floor(log10(raw)))
        let fraction = raw / magnitude
        let nice: Double = fraction <= 1 ? 1 : fraction <= 2 ? 2 : fraction <= 5 ? 5 : 10
        return nice * magnitude
    }
}
