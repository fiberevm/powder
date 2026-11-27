import AppKit
import SwiftUI

// MARK: - Settings

enum ChartStyle: String, Codable, CaseIterable, Sendable {
    case candles, hollow, heikinAshi, bars, line, area

    var title: String {
        switch self {
        case .candles: "Candles"
        case .hollow: "Hollow Candles"
        case .heikinAshi: "Heikin Ashi"
        case .bars: "Bars"
        case .line: "Line"
        case .area: "Area"
        }
    }
}

enum ChartIndicator: String, Codable, CaseIterable, Sendable {
    case volume, ma, ema, bollinger, vwap, rsi, macd

    var title: String {
        switch self {
        case .volume: "Volume"
        case .ma: "MA 7 / 25 / 99"
        case .ema: "EMA 12 / 26"
        case .bollinger: "Bollinger Bands 20, 2"
        case .vwap: "VWAP (daily)"
        case .rsi: "RSI 14"
        case .macd: "MACD 12, 26, 9"
        }
    }
}

/// How a tab draws its chart. The last choice is the default for new tabs.
struct ChartSettings: Codable, Equatable, Sendable {
    var style = ChartStyle.candles
    var indicators: Set<ChartIndicator> = [.volume]
    var logScale = false

    private static let key = "chart.settings"

    static func load(from defaults: UserDefaults = .standard) -> ChartSettings {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(ChartSettings.self, from: $0) } ?? ChartSettings()
    }

    func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.key) }
    }
}

// MARK: - Drawings

enum DrawTool: String, Codable, CaseIterable, Sendable {
    case trend, ray, horizontal

    var title: String {
        switch self {
        case .trend: "Trend line"
        case .ray: "Ray"
        case .horizontal: "Horizontal line"
        }
    }
}

/// A line the user drew, anchored in time and price so it holds its place on every interval and zoom.
struct ChartDrawing: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    /// `.trend` stops at its second point; `.ray` carries on past it.
    var kind: DrawTool
    var startTime: Int64
    var startPrice: Double
    var endTime: Int64
    var endPrice: Double
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
    enum Kind { case entryLong, entryShort, liquidation }
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
    let isLoadingHistory: Bool

    nonisolated static func == (lhs: PerpChart, rhs: PerpChart) -> Bool {
        lhs.cursorTime == rhs.cursorTime
            && lhs.drawings == rhs.drawings
            && lhs.drawTool == rhs.drawTool
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
    }

    /// Read so the canvas redraws when the theme changes, which `==` above would otherwise skip.
    @Environment(\.colorScheme) private var colorScheme
    @State private var hover: CGPoint?
    @State private var drag: DragKind?
    @State private var measure: ChartMeasure?
    /// The line being dragged out with a drawing tool.
    @State private var draft: ChartDrawing?

    var body: some View {
        GeometryReader { geometry in
            let layout = ChartLayout(
                size: geometry.size, candles: candles, pitch: pitch, offset: offset,
                priceZoom: priceZoom, pricePan: pricePan, settings: settings
            )
            let renderer = ChartRenderer(
                layout: layout, cursorTime: cursorTime, hover: hover, measure: measure,
                drawings: drawings + (draft.map { [$0] } ?? []), interval: interval,
                decimals: decimals, settings: settings,
                priceLines: priceLines, levels: levels, isLoadingHistory: isLoadingHistory
            )
            // Once a second, for the countdown to the candle close.
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                Canvas { context, _ in
                    renderer.draw(in: &context, now: timeline.date)
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
                if drawTool == .horizontal {
                    model.togglePriceLine(at: layout.price(atY: location.y), tolerance: 0)
                    model.setDrawTool(nil)
                    return
                }
                guard NSEvent.modifierFlags.contains(.option) else { return }
                // ⌥-click removes the drawn line under the pointer, else toggles a horizontal line.
                if let hit = drawings.last(where: { layout.distance(from: location, to: $0, interval: interval) < 7 }) {
                    model.removeDrawing(hit.id)
                } else {
                    model.togglePriceLine(at: layout.price(atY: location.y), tolerance: layout.priceSpan(points: 5))
                }
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
        }
        .accessibilityLabel("Price chart, \(interval.rawValue) \(settings.style.title)")
    }

    private func dragGesture(_ layout: ChartLayout) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if drag == nil {
                    let start = value.startLocation
                    if start.x > layout.plot.maxX {
                        drag = .priceAxis(zoom: priceZoom)
                    } else if start.y > layout.plot.maxY {
                        drag = .timeAxis(pitch: pitch)
                    } else if let drawTool, drawTool != .horizontal, layout.mainPane.contains(start) {
                        measure = nil
                        drag = .draw
                        let time = layout.time(atPointX: start.x, interval: interval)
                        let price = layout.price(atY: start.y)
                        draft = ChartDrawing(kind: drawTool, startTime: time, startPrice: price, endTime: time, endPrice: price)
                    } else if NSEvent.modifierFlags.contains(.shift) {
                        drag = .measure
                        measure = ChartMeasure(
                            startIndex: layout.index(atX: start.x), startPrice: layout.price(atY: start.y),
                            endIndex: layout.index(atX: start.x), endPrice: layout.price(atY: start.y)
                        )
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
                        model.setPriceScale(pan: startPan + value.translation.height / layout.priceZone.height / priceZoom)
                    }
                case let .priceAxis(startZoom):
                    model.setPriceScale(zoom: startZoom * exp(-value.translation.height * 0.006))
                case let .timeAxis(startPitch):
                    model.setViewport(pitch: startPitch * exp(value.translation.width * 0.006))
                case .measure:
                    measure?.endIndex = layout.index(atX: value.location.x)
                    measure?.endPrice = layout.price(atY: value.location.y)
                case .draw:
                    draft?.endTime = layout.time(atPointX: value.location.x, interval: interval)
                    draft?.endPrice = layout.price(atY: value.location.y)
                case nil:
                    break
                }
            }
            .onEnded { _ in
                if case .draw = drag, let draft {
                    model.addDrawing(draft)
                    model.setDrawTool(nil)
                }
                draft = nil
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

private struct ChartLayout {
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
    let rsiPane: CGRect?
    let macdPane: CGRect?
    let isLog: Bool
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
        var subPanes: [ChartIndicator] = [.rsi, .macd].filter { settings.indicators.contains($0) }
        let subHeight = min(max((plot.height * 0.2).rounded(), 64), 130)
        while !subPanes.isEmpty, plot.height - CGFloat(subPanes.count) * subHeight < 150 { subPanes.removeLast() }
        let mainHeight = plot.height - CGFloat(subPanes.count) * subHeight
        mainPane = CGRect(x: 0, y: 0, width: plot.width, height: mainHeight)
        var paneFrames: [ChartIndicator: CGRect] = [:]
        for (position, pane) in subPanes.enumerated() {
            paneFrames[pane] = CGRect(x: 0, y: mainHeight + CGFloat(position) * subHeight, width: plot.width, height: subHeight)
        }
        rsiPane = paneFrames[.rsi]
        macdPane = paneFrames[.macd]

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
        let usesClose = settings.style == .line || settings.style == .area
        let rawLow = shown.map { usesClose ? $0.c : $0.l }.min() ?? 0
        let rawHigh = shown.map { usesClose ? $0.c : $0.h }.max() ?? 1
        isLog = settings.logScale && rawLow > 0
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
        return priceZone.minY + CGFloat((high - value) / (high - low)) * priceZone.height
    }

    func price(atY y: CGFloat) -> Double {
        let value = high - Double((y - priceZone.minY) / priceZone.height) * (high - low)
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

    /// The two screen points of a drawing; a ray's second point is pushed out to the plot's edge.
    func points(of drawing: ChartDrawing, interval: HLInterval) -> (CGPoint, CGPoint) {
        let start = CGPoint(x: x(time: drawing.startTime, interval: interval), y: y(drawing.startPrice))
        var end = CGPoint(x: x(time: drawing.endTime, interval: interval), y: y(drawing.endPrice))
        if drawing.kind == .ray, end != start {
            let dx = end.x - start.x, dy = end.y - start.y
            let reach = (abs(dx) > 0.5 ? (dx > 0 ? plot.maxX - start.x : start.x - plot.minX) / abs(dx) : 4_000 / max(abs(dy), 1))
            end = CGPoint(x: start.x + dx * max(reach, 1), y: start.y + dy * max(reach, 1))
        }
        return (start, end)
    }

    func distance(from point: CGPoint, to drawing: ChartDrawing, interval: HLInterval) -> CGFloat {
        let (a, b) = points(of: drawing, interval: interval)
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(point.x - a.x, point.y - a.y) }
        let t = min(max(((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared, 0), 1)
        return hypot(point.x - (a.x + t * dx), point.y - (a.y + t * dy))
    }

    func candle(_ index: Int) -> HLCandle? {
        let position = index - base
        return window.indices.contains(position) ? window[position] : nil
    }
}

// MARK: - Renderer

private struct ChartRenderer {
    let layout: ChartLayout
    let cursorTime: Int64?
    let hover: CGPoint?
    let measure: ChartMeasure?
    let drawings: [ChartDrawing]
    let interval: HLInterval
    let decimals: Int
    let settings: ChartSettings
    let priceLines: [Double]
    let levels: [ChartLevel]
    let isLoadingHistory: Bool

    private struct Overlay {
        let label: String
        let color: Color
        let values: [Double?]
    }

    /// User-drawn price lines; blue so they stand apart from the gold accent.
    private static let lineColor = Color(dark: 0x3794FF, light: 0x0A6FD6)
    private let labelFont = Font.system(size: 10.5, design: .monospaced)
    private let grid = Color.primary.opacity(0.07)
    private let up = PowderPalette.signalGreen
    private let down = PowderPalette.riskCoral

    private var zone: TimeZone { interval.isDaily ? .gmt : .current }

    func draw(in context: inout GraphicsContext, now: Date) {
        guard !layout.range.isEmpty else { return }
        let closes = layout.window.map(\.c)
        let overlays = makeOverlays(closes)
        let bands = settings.indicators.contains(.bollinger) ? ChartMath.bollinger(closes) : nil
        let cursorIndex = cursorTime.flatMap { time in layout.range.last { layout.candle($0)?.t == time } }

        drawPriceAxis(&context)
        drawTimeAxis(&context)

        var pane = context
        pane.clip(to: Path(layout.mainPane))
        drawVolume(&pane)
        if let bands { drawBands(bands, in: &pane) }
        drawSeries(&pane)
        for overlay in overlays {
            stroke(overlay.values, color: overlay.color, y: layout.y, in: &pane)
        }
        drawExtremes(&pane)
        drawPriceLines(&pane, axis: &context)
        drawLevels(&pane, axis: &context)
        drawDrawings(&pane)
        drawLastPrice(&context, now: now)

        if let frame = layout.rsiPane { drawRSI(ChartMath.rsi(closes), frame: frame, cursor: cursorIndex, in: &context) }
        if let frame = layout.macdPane { drawMACD(ChartMath.macd(closes), frame: frame, cursor: cursorIndex, in: &context) }

        if let measure { drawMeasure(measure, in: &context) }
        drawCrosshair(cursorIndex, in: &context)
        drawLegend(cursorIndex ?? layout.lastVisible, overlays: overlays, bands: bands, in: &context)

        if isLoadingHistory {
            context.draw(
                Text("loading history…").font(labelFont).foregroundStyle(.secondary),
                at: CGPoint(x: 10, y: layout.mainPane.maxY - 12), anchor: .leading
            )
        }
    }

    private func makeOverlays(_ closes: [Double]) -> [Overlay] {
        var overlays: [Overlay] = []
        if settings.indicators.contains(.ma) {
            overlays.append(Overlay(label: "MA7", color: Color(dark: 0xE5C07B, light: 0xB8860B), values: ChartMath.sma(closes, 7)))
            overlays.append(Overlay(label: "MA25", color: Color(dark: 0xC586C0, light: 0xA347A0), values: ChartMath.sma(closes, 25)))
            overlays.append(Overlay(label: "MA99", color: Color(dark: 0x3794FF, light: 0x0A6FD6), values: ChartMath.sma(closes, 99)))
        }
        if settings.indicators.contains(.ema) {
            overlays.append(Overlay(label: "EMA12", color: Color(dark: 0x4EC9B0, light: 0x16825D), values: ChartMath.ema(closes, 12)))
            overlays.append(Overlay(label: "EMA26", color: Color(dark: 0xCE9178, light: 0xB5532A), values: ChartMath.ema(closes, 26)))
        }
        if settings.indicators.contains(.vwap), !interval.isDaily {
            overlays.append(Overlay(label: "VWAP", color: Color.primary.opacity(0.75), values: ChartMath.vwap(layout.window)))
        }
        return overlays
    }

    // MARK: Axes

    private func drawPriceAxis(_ context: inout GraphicsContext) {
        var prices: [Double] = []
        if layout.isLog {
            // Even spacing on screen; the labels are whatever prices fall there.
            prices = stride(from: layout.mainPane.minY + 30, to: layout.mainPane.maxY, by: 56).map { layout.price(atY: $0) }
        } else {
            let top = layout.price(atY: layout.mainPane.minY), bottom = layout.price(atY: layout.mainPane.maxY)
            let step = Self.niceStep((top - bottom) / max(Double(layout.mainPane.height / 56), 2))
            if step > 0 {
                var price = (bottom / step).rounded(.up) * step
                while price <= top {
                    prices.append(price)
                    price += step
                }
            }
        }
        for price in prices {
            let y = layout.y(price).rounded() + 0.5
            guard y > layout.mainPane.minY + 6, y < layout.mainPane.maxY - 4 else { continue }
            context.stroke(horizontal(y), with: .color(grid), lineWidth: 1)
            axisLabel(HLFormat.price(price, decimals: decimals), y: y, in: &context)
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
        for index in layout.range {
            guard let candle = layout.candle(index) else { continue }
            let height = max(CGFloat(candle.v / layout.maxVolume) * zone.height, 1)
            let bar = CGRect(x: layout.x(index).rounded() - bodyWidth / 2, y: zone.maxY - height, width: bodyWidth, height: height)
            context.fill(Path(bar), with: .color((candle.c >= candle.o ? up : down).opacity(0.3)))
        }
    }

    private func drawSeries(_ context: inout GraphicsContext) {
        switch settings.style {
        case .line, .area:
            let values = layout.window.map { Optional($0.c) }
            if settings.style == .area {
                var fill = Path()
                var started = false
                for index in layout.range {
                    guard let candle = layout.candle(index) else { continue }
                    let point = CGPoint(x: layout.x(index), y: layout.y(candle.c))
                    if started {
                        fill.addLine(to: point)
                    } else {
                        fill.move(to: CGPoint(x: point.x, y: layout.mainPane.maxY))
                        fill.addLine(to: point)
                        started = true
                    }
                }
                if started, let last = layout.range.last {
                    fill.addLine(to: CGPoint(x: layout.x(last), y: layout.mainPane.maxY))
                    fill.closeSubpath()
                    context.fill(fill, with: .linearGradient(
                        Gradient(colors: [Term.accent.opacity(0.32), Term.accent.opacity(0.02)]),
                        startPoint: CGPoint(x: 0, y: layout.priceZone.minY),
                        endPoint: CGPoint(x: 0, y: layout.mainPane.maxY)
                    ))
                }
            }
            stroke(values, color: Term.accent, width: 1.5, y: layout.y, in: &context)

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

        case .candles, .hollow, .heikinAshi:
            for index in layout.range {
                guard let candle = layout.candle(index) else { continue }
                let rises = candle.c >= candle.o
                let color = rises ? up : down
                let x = layout.x(index).rounded()
                let top = layout.y(max(candle.o, candle.c))
                let bottom = layout.y(min(candle.o, candle.c))
                let wick = CGRect(x: x - 0.5, y: layout.y(candle.h), width: 1, height: max(layout.y(candle.l) - layout.y(candle.h), 1))
                let body = CGRect(x: x - bodyWidth / 2, y: top, width: bodyWidth, height: max(bottom - top, 1))
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

    private func drawBands(_ bands: (upper: [Double?], lower: [Double?]), in context: inout GraphicsContext) {
        let color = Color(dark: 0x6A9FB5, light: 0x3F7F99)
        var fill = Path()
        var lowerPoints: [CGPoint] = []
        var started = false
        for index in layout.range {
            let position = index - layout.base
            guard bands.upper.indices.contains(position), let upper = bands.upper[position], let lower = bands.lower[position] else { continue }
            let point = CGPoint(x: layout.x(index), y: layout.y(upper))
            if started { fill.addLine(to: point) } else { fill.move(to: point); started = true }
            lowerPoints.append(CGPoint(x: layout.x(index), y: layout.y(lower)))
        }
        if started {
            for point in lowerPoints.reversed() { fill.addLine(to: point) }
            fill.closeSubpath()
            context.fill(fill, with: .color(color.opacity(0.07)))
        }
        stroke(bands.upper, color: color.opacity(0.8), y: layout.y, in: &context)
        stroke(bands.lower, color: color.opacity(0.8), y: layout.y, in: &context)
    }

    /// Marks the highest high and lowest low on screen.
    private func drawExtremes(_ context: inout GraphicsContext) {
        guard settings.style != .line, settings.style != .area else { return }
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
            let y = layout.y(mark.price) + (isHigh ? -7 : 7)
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
            case .entryLong: up
            case .entryShort: down
            case .liquidation: PowderPalette.cautionAmber
            }
            let rawY = layout.y(level.price).rounded() + 0.5
            let y = min(max(rawY, layout.mainPane.minY + 8), layout.mainPane.maxY - 8)
            var label = level.label
            if rawY == y {
                pane.stroke(horizontal(y), with: .color(color.opacity(0.9)), style: StrokeStyle(lineWidth: 1, dash: [6, 3]))
            } else {
                label += rawY < y ? " ↑" : " ↓"
            }
            tag(label, fill: color, at: CGPoint(x: layout.plot.minX + 6, y: y), anchor: .leading, in: &pane)
            tag(HLFormat.price(level.price, decimals: decimals), fill: color, at: CGPoint(x: layout.plot.maxX + 1, y: y), anchor: .leading, in: &axis)
        }
    }

    private func drawDrawings(_ pane: inout GraphicsContext) {
        for drawing in drawings {
            let (start, end) = layout.points(of: drawing, interval: interval)
            var path = Path()
            path.move(to: start)
            path.addLine(to: end)
            pane.stroke(path, with: .color(Self.lineColor), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            let handles = drawing.kind == .ray ? [start] : [start, end]
            for point in handles {
                let dot = CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6)
                pane.fill(Path(ellipseIn: dot), with: .color(Term.background))
                pane.stroke(Path(ellipseIn: dot), with: .color(Self.lineColor), lineWidth: 1.5)
            }
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
        guard interval != .mo1 else { return }
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

    private func drawRSI(_ values: [Double?], frame: CGRect, cursor: Int?, in context: inout GraphicsContext) {
        let inner = frame.insetBy(dx: 0, dy: 6)
        let y: (Double) -> CGFloat = { inner.minY + CGFloat((100 - $0) / 100) * inner.height }
        for level in [30.0, 70.0] {
            let line = y(level).rounded() + 0.5
            context.stroke(horizontal(line), with: .color(Color.primary.opacity(0.16)), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
            axisLabel(String(format: "%.0f", level), y: line, in: &context)
        }
        var pane = context
        pane.clip(to: Path(frame))
        stroke(values, color: Color(dark: 0xC586C0, light: 0xA347A0), y: y, in: &pane)
        let shown = value(values, cursor ?? layout.lastVisible)
        paneFrame(frame, title: "RSI 14  " + (shown.map { String(format: "%.1f", $0) } ?? "–"), in: &context)
    }

    private func drawMACD(
        _ series: (macd: [Double?], signal: [Double?], histogram: [Double?]),
        frame: CGRect, cursor: Int?, in context: inout GraphicsContext
    ) {
        let inner = frame.insetBy(dx: 0, dy: 8)
        var extent = 0.0
        for index in layout.range {
            for values in [series.macd, series.signal, series.histogram] {
                if let value = value(values, index) { extent = max(extent, abs(value)) }
            }
        }
        guard extent > 0 else {
            paneFrame(frame, title: "MACD 12 26 9", in: &context)
            return
        }
        let y: (Double) -> CGFloat = { inner.midY - CGFloat($0 / extent) * inner.height / 2 }
        var pane = context
        pane.clip(to: Path(frame))
        pane.stroke(horizontal(inner.midY.rounded() + 0.5), with: .color(Color.primary.opacity(0.14)), lineWidth: 1)
        for index in layout.range {
            guard let bar = value(series.histogram, index) else { continue }
            let top = min(y(bar), inner.midY), height = max(abs(y(bar) - inner.midY), 1)
            let rect = CGRect(x: layout.x(index).rounded() - bodyWidth / 2, y: top, width: bodyWidth, height: height)
            pane.fill(Path(rect), with: .color((bar >= 0 ? up : down).opacity(0.55)))
        }
        stroke(series.macd, color: Color(dark: 0x3794FF, light: 0x0A6FD6), y: y, in: &pane)
        stroke(series.signal, color: Color(dark: 0xCE9178, light: 0xB5532A), y: y, in: &pane)
        axisLabel(HLFormat.price(extent, decimals: decimals), y: inner.minY + 4, in: &context)
        axisLabel(HLFormat.price(-extent, decimals: decimals), y: inner.maxY - 4, in: &context)
        let at = cursor ?? layout.lastVisible
        let readout = [series.macd, series.signal, series.histogram]
            .map { value($0, at).map { HLFormat.price($0, decimals: decimals) } ?? "–" }
            .joined(separator: "  ")
        paneFrame(frame, title: "MACD 12 26 9  " + readout, in: &context)
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

    private func drawMeasure(_ measure: ChartMeasure, in context: inout GraphicsContext) {
        let x0 = layout.x(measure.startIndex), x1 = layout.x(measure.endIndex)
        let y0 = layout.y(measure.startPrice), y1 = layout.y(measure.endPrice)
        let rect = CGRect(x: min(x0, x1), y: min(y0, y1), width: abs(x1 - x0), height: abs(y1 - y0))
        let rises = measure.endPrice >= measure.startPrice
        let color = rises ? up : down
        var pane = context
        pane.clip(to: Path(layout.mainPane))
        pane.fill(Path(rect), with: .color(color.opacity(0.14)))
        pane.stroke(Path(rect), with: .color(color.opacity(0.7)), lineWidth: 1)

        let change = measure.endPrice - measure.startPrice
        let bars = measure.endIndex - measure.startIndex
        let percent = measure.startPrice > 0 ? HLFormat.percent(change / measure.startPrice) : ""
        let sign = change >= 0 ? "+" : "−"
        let label = "\(sign)\(HLFormat.price(abs(change), decimals: decimals))  \(percent)  ·  \(bars) bars  \(Self.duration(Int64(abs(bars)) * interval.milliseconds))"
        let anchorY = rises ? rect.minY - 12 : rect.maxY + 12
        tag(
            label, fill: color,
            at: CGPoint(x: min(max(rect.midX, 110), layout.plot.maxX - 110), y: min(max(anchorY, 12), layout.mainPane.maxY - 12)),
            anchor: .center, in: &context
        )
    }

    private func drawLegend(
        _ index: Int, overlays: [Overlay], bands: (upper: [Double?], lower: [Double?])?, in context: inout GraphicsContext
    ) {
        guard let candle = layout.candle(index) else { return }
        let color = candle.c >= candle.o ? up : down
        var first: [(String, Color)] = []
        for (label, value) in [("O", candle.o), ("H", candle.h), ("L", candle.l), ("C", candle.c)] {
            first.append((label, .secondary))
            first.append((HLFormat.price(value, decimals: decimals), color))
        }
        if candle.o > 0 { first.append((HLFormat.percent(candle.c / candle.o - 1), color)) }
        first.append(("V", .secondary))
        first.append((HLFormat.compact(candle.v), Term.foreground))
        if settings.style == .heikinAshi { first.append(("HA", .secondary)) }
        if layout.isLog { first.append(("LOG", .secondary)) }
        legendLine(first, y: 12, in: &context)

        var second: [(String, Color)] = []
        for overlay in overlays {
            second.append((overlay.label, .secondary))
            second.append((value(overlay.values, index).map { HLFormat.price($0, decimals: decimals) } ?? "–", overlay.color))
        }
        if let bands {
            let bandColor = Color(dark: 0x6A9FB5, light: 0x3F7F99)
            second.append(("BB", .secondary))
            second.append((value(bands.upper, index).map { HLFormat.price($0, decimals: decimals) } ?? "–", bandColor))
            second.append((value(bands.lower, index).map { HLFormat.price($0, decimals: decimals) } ?? "–", bandColor))
        }
        if !second.isEmpty { legendLine(second, y: 28, in: &context) }
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
        _ values: [Double?], color: Color, width: CGFloat = 1, y: (Double) -> CGFloat, in context: inout GraphicsContext
    ) {
        var path = Path()
        var isDrawing = false
        for index in layout.range {
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
    private func tag(
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

    private func timeLabel(_ milliseconds: Int64, date: Bool, time: Bool) -> String {
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
