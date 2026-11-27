import SwiftUI

// MARK: - Study math

extension ChartMath {
    /// Applies `transform` from the first value on, leaving the lead-in empty. For chaining one study into another.
    static func fromFirstValue(_ values: [Double?], _ transform: ([Double]) -> [Double?]) -> [Double?] {
        var out = [Double?](repeating: nil, count: values.count)
        guard let start = values.firstIndex(where: { $0 != nil }) else { return out }
        let result = transform(values[start...].map { $0 ?? 0 })
        for (offset, value) in result.enumerated() { out[start + offset] = value }
        return out
    }

    /// The highest (or lowest, by `pick`) of the last `period` values.
    static func rolling(_ values: [Double], _ period: Int, _ pick: (Double, Double) -> Double) -> [Double?] {
        var out = [Double?](repeating: nil, count: values.count)
        guard period > 0, values.count >= period else { return out }
        for index in (period - 1)..<values.count {
            var best = values[index]
            for back in 1..<period { best = pick(best, values[index - back]) }
            out[index] = best
        }
        return out
    }

    static func highest(_ values: [Double], _ period: Int) -> [Double?] { rolling(values, period) { max($0, $1) } }
    static func lowest(_ values: [Double], _ period: Int) -> [Double?] { rolling(values, period) { min($0, $1) } }

    /// Wilder's smoothing, seeded with the simple average of the first `period` values.
    static func wilder(_ values: [Double], _ period: Int) -> [Double?] {
        var out = [Double?](repeating: nil, count: values.count)
        guard period > 0, values.count >= period else { return out }
        var current = values[0..<period].reduce(0, +) / Double(period)
        out[period - 1] = current
        for index in period..<values.count {
            current = (current * Double(period - 1) + values[index]) / Double(period)
            out[index] = current
        }
        return out
    }

    static func trueRange(_ candles: [HLCandle]) -> [Double] {
        candles.indices.map { index in
            let candle = candles[index]
            guard index > 0 else { return candle.h - candle.l }
            let previous = candles[index - 1].c
            return max(candle.h - candle.l, abs(candle.h - previous), abs(candle.l - previous))
        }
    }

    static func atr(_ candles: [HLCandle], _ period: Int = 14) -> [Double?] {
        wilder(trueRange(candles), period)
    }

    /// The trailing stop that flips sides when price closes through it, and which side it is on.
    static func supertrend(_ candles: [HLCandle], period: Int = 10, multiplier: Double = 3) -> (line: [Double?], rising: [Bool]) {
        let ranges = atr(candles, period)
        var line = [Double?](repeating: nil, count: candles.count)
        var rising = [Bool](repeating: true, count: candles.count)
        var upper = 0.0, lower = 0.0, isUp = true, started = false
        for index in candles.indices {
            guard let range = ranges[index] else { continue }
            let candle = candles[index]
            let middle = (candle.h + candle.l) / 2
            var nextUpper = middle + multiplier * range, nextLower = middle - multiplier * range
            if started {
                let previous = candles[index - 1].c
                // A band only tightens towards price until price closes through it.
                if nextUpper > upper, previous <= upper { nextUpper = upper }
                if nextLower < lower, previous >= lower { nextLower = lower }
                if isUp, candle.c < nextLower { isUp = false } else if !isUp, candle.c > nextUpper { isUp = true }
            }
            upper = nextUpper
            lower = nextLower
            started = true
            line[index] = isUp ? lower : upper
            rising[index] = isUp
        }
        return (line, rising)
    }

    /// Parabolic stop and reverse.
    static func sar(_ candles: [HLCandle], step: Double = 0.02, limit: Double = 0.2) -> [Double?] {
        var out = [Double?](repeating: nil, count: candles.count)
        guard candles.count > 1 else { return out }
        var isUp = candles[1].c >= candles[0].c
        var stop = isUp ? candles[0].l : candles[0].h
        var extreme = isUp ? candles[0].h : candles[0].l
        var factor = step
        for index in 1..<candles.count {
            let candle = candles[index], previous = candles[index - 1]
            let before = index > 1 ? candles[index - 2] : previous
            stop += factor * (extreme - stop)
            if isUp {
                stop = min(stop, previous.l, before.l)
                if candle.l < stop {
                    isUp = false
                    stop = extreme
                    extreme = candle.l
                    factor = step
                } else if candle.h > extreme {
                    extreme = candle.h
                    factor = min(factor + step, limit)
                }
            } else {
                stop = max(stop, previous.h, before.h)
                if candle.h > stop {
                    isUp = true
                    stop = extreme
                    extreme = candle.h
                    factor = step
                } else if candle.l < extreme {
                    extreme = candle.l
                    factor = min(factor + step, limit)
                }
            }
            out[index] = stop
        }
        return out
    }

    /// %K and %D: where the close sits in the last `period` candles' range, 0 to 100, smoothed.
    static func stochastic(
        high: [Double], low: [Double], close: [Double], period: Int = 14, smoothK: Int = 3, smoothD: Int = 3
    ) -> (k: [Double?], d: [Double?]) {
        let top = highest(high, period), bottom = lowest(low, period)
        var raw = [Double?](repeating: nil, count: close.count)
        for index in close.indices {
            guard let top = top[index], let bottom = bottom[index] else { continue }
            raw[index] = top > bottom ? (close[index] - bottom) / (top - bottom) * 100 : 50
        }
        let k = fromFirstValue(raw) { sma($0, smoothK) }
        return (k, fromFirstValue(k) { sma($0, smoothD) })
    }

    /// The stochastic of the RSI rather than of price.
    static func stochasticRSI(_ closes: [Double], period: Int = 14) -> (k: [Double?], d: [Double?]) {
        let strength = rsi(closes, period)
        var k = [Double?](repeating: nil, count: closes.count), d = k
        guard let start = strength.firstIndex(where: { $0 != nil }) else { return (k, d) }
        let values = strength[start...].map { $0 ?? 0 }
        let result = stochastic(high: values, low: values, close: values, period: period)
        for offset in values.indices {
            k[start + offset] = result.k[offset]
            d[start + offset] = result.d[offset]
        }
        return (k, d)
    }

    static func obv(_ candles: [HLCandle]) -> [Double?] {
        var out = [Double?](repeating: nil, count: candles.count)
        var total = 0.0
        for index in candles.indices {
            if index > 0 {
                let change = candles[index].c - candles[index - 1].c
                total += change > 0 ? candles[index].v : change < 0 ? -candles[index].v : 0
            }
            out[index] = total
        }
        return out
    }

    /// Commodity channel index: how far the typical price is from its average, in mean deviations.
    static func cci(_ candles: [HLCandle], _ period: Int = 20) -> [Double?] {
        let typical = candles.map { ($0.h + $0.l + $0.c) / 3 }
        let mean = sma(typical, period)
        var out = [Double?](repeating: nil, count: candles.count)
        for index in candles.indices {
            guard let mean = mean[index] else { continue }
            let deviation = typical[(index - period + 1)...index].reduce(0) { $0 + abs($1 - mean) } / Double(period)
            out[index] = deviation > 0 ? (typical[index] - mean) / (0.015 * deviation) : 0
        }
        return out
    }

    /// Money flow index: an RSI weighted by volume.
    static func mfi(_ candles: [HLCandle], _ period: Int = 14) -> [Double?] {
        var out = [Double?](repeating: nil, count: candles.count)
        guard candles.count > period else { return out }
        let typical = candles.map { ($0.h + $0.l + $0.c) / 3 }
        var gains = [Double](repeating: 0, count: candles.count), losses = gains
        for index in 1..<candles.count {
            let flow = typical[index] * candles[index].v
            if typical[index] > typical[index - 1] { gains[index] = flow } else if typical[index] < typical[index - 1] { losses[index] = flow }
        }
        var gain = 0.0, loss = 0.0
        for index in 1..<candles.count {
            gain += gains[index]
            loss += losses[index]
            if index > period {
                gain -= gains[index - period]
                loss -= losses[index - period]
            }
            if index >= period { out[index] = loss <= 0 ? 100 : 100 - 100 / (1 + max(gain, 0) / loss) }
        }
        return out
    }

    /// Williams %R: the stochastic turned upside down, 0 at the top of the range and −100 at the bottom.
    static func williamsR(_ candles: [HLCandle], _ period: Int = 14) -> [Double?] {
        let top = highest(candles.map(\.h), period), bottom = lowest(candles.map(\.l), period)
        var out = [Double?](repeating: nil, count: candles.count)
        for index in candles.indices {
            guard let top = top[index], let bottom = bottom[index] else { continue }
            out[index] = top > bottom ? (top - candles[index].c) / (top - bottom) * -100 : -50
        }
        return out
    }

    /// Trend strength with its two directional lines.
    static func adx(_ candles: [HLCandle], _ period: Int = 14) -> (adx: [Double?], plus: [Double?], minus: [Double?]) {
        let empty = [Double?](repeating: nil, count: candles.count)
        guard candles.count > 1 else { return (empty, empty, empty) }
        var rises = [Double](repeating: 0, count: candles.count), falls = rises
        for index in 1..<candles.count {
            let up = candles[index].h - candles[index - 1].h, down = candles[index - 1].l - candles[index].l
            if up > down, up > 0 { rises[index] = up }
            if down > up, down > 0 { falls[index] = down }
        }
        let range = wilder(trueRange(candles), period), rise = wilder(rises, period), fall = wilder(falls, period)
        var plus = empty, minus = empty, spread = empty
        for index in candles.indices {
            guard let range = range[index], let rise = rise[index], let fall = fall[index], range > 0 else { continue }
            plus[index] = 100 * rise / range
            minus[index] = 100 * fall / range
            spread[index] = rise + fall > 0 ? 100 * abs(rise - fall) / (rise + fall) : 0
        }
        return (fromFirstValue(spread) { wilder($0, period) }, plus, minus)
    }

    struct Ichimoku {
        var conversion: [Double?]
        var base: [Double?]
        /// The cloud's two edges, already moved `shift` candles ahead: `shift` longer than the candles.
        var spanA: [Double?]
        var spanB: [Double?]
        /// The close, moved `shift` candles back.
        var lagging: [Double?]
        var shift: Int
    }

    static func ichimoku(_ candles: [HLCandle], conversion: Int = 9, base: Int = 26, span: Int = 52, shift: Int = 26) -> Ichimoku {
        let highs = candles.map(\.h), lows = candles.map(\.l)
        func middle(_ period: Int) -> [Double?] {
            let top = highest(highs, period), bottom = lowest(lows, period)
            return candles.indices.map { index in
                guard let top = top[index], let bottom = bottom[index] else { return nil }
                return (top + bottom) / 2
            }
        }
        let fast = middle(conversion), slow = middle(base), wide = middle(span)
        var spanA = [Double?](repeating: nil, count: candles.count + shift), spanB = spanA
        var lagging = [Double?](repeating: nil, count: candles.count)
        for index in candles.indices {
            if let a = fast[index], let b = slow[index] { spanA[index + shift] = (a + b) / 2 }
            spanB[index + shift] = wide[index]
            if index >= shift { lagging[index - shift] = candles[index].c }
        }
        return Ichimoku(conversion: fast, base: slow, spanA: spanA, spanB: spanB, lagging: lagging, shift: shift)
    }
}

// MARK: - Computed series

enum ChartTint {
    static let gold = Color(dark: 0xE5C07B, light: 0xB8860B)
    static let purple = Color(dark: 0xC586C0, light: 0xA347A0)
    static let blue = Color(dark: 0x3794FF, light: 0x0A6FD6)
    static let teal = Color(dark: 0x4EC9B0, light: 0x16825D)
    static let orange = Color(dark: 0xCE9178, light: 0xB5532A)
    static let slate = Color(dark: 0x6A9FB5, light: 0x3F7F99)
}

/// Every study the chart has switched on, worked out over the candles it has in hand.
/// All arrays line up with the layout's window of candles.
struct ChartSeries {
    struct Line {
        let label: String
        let color: Color
        let values: [Double?]
    }

    struct Band {
        let label: String
        let color: Color
        let upper: [Double?]
        let lower: [Double?]
        var middle: [Double?]?
    }

    /// An oscillator drawn in its own pane under the price.
    struct Pane {
        enum Scale {
            case fixed(ClosedRange<Double>)
            /// Fitted to what is on screen.
            case auto
            /// Fitted, with zero in the middle.
            case centered
        }

        enum Format {
            case price, compact
            case plain(Int)
        }

        let title: String
        var lines: [Line]
        var histogram: [Double?]?
        var scale: Scale
        var guides: [Double] = []
        var format: Format
    }

    var lines: [Line] = []
    var bands: [Band] = []
    var supertrend: (line: [Double?], rising: [Bool])?
    var sar: [Double?]?
    var ichimoku: ChartMath.Ichimoku?
    var panes: [ChartIndicator: Pane] = [:]

    static func build(window: [HLCandle], indicators: Set<ChartIndicator>, interval: HLInterval) -> ChartSeries {
        var series = ChartSeries()
        guard !window.isEmpty else { return series }
        let closes = window.map(\.c)

        if indicators.contains(.ma) {
            series.lines.append(Line(label: "MA7", color: ChartTint.gold, values: ChartMath.sma(closes, 7)))
            series.lines.append(Line(label: "MA25", color: ChartTint.purple, values: ChartMath.sma(closes, 25)))
            series.lines.append(Line(label: "MA99", color: ChartTint.blue, values: ChartMath.sma(closes, 99)))
        }
        if indicators.contains(.ema) {
            series.lines.append(Line(label: "EMA12", color: ChartTint.teal, values: ChartMath.ema(closes, 12)))
            series.lines.append(Line(label: "EMA26", color: ChartTint.orange, values: ChartMath.ema(closes, 26)))
        }
        if indicators.contains(.vwap), !interval.isDaily {
            series.lines.append(Line(label: "VWAP", color: Color.primary.opacity(0.75), values: ChartMath.vwap(window)))
        }
        if indicators.contains(.bollinger) {
            let bands = ChartMath.bollinger(closes)
            series.bands.append(Band(label: "BB", color: ChartTint.slate, upper: bands.upper, lower: bands.lower))
        }
        if indicators.contains(.donchian) {
            let upper = ChartMath.highest(window.map(\.h), 20), lower = ChartMath.lowest(window.map(\.l), 20)
            let middle: [Double?] = window.indices.map { index in
                guard let top = upper[index], let bottom = lower[index] else { return nil }
                return (top + bottom) / 2
            }
            series.bands.append(Band(label: "DC", color: ChartTint.teal, upper: upper, lower: lower, middle: middle))
        }
        if indicators.contains(.keltner) {
            let middle = ChartMath.ema(closes, 20), range = ChartMath.atr(window, 10)
            var upper = [Double?](repeating: nil, count: window.count), lower = upper
            for index in window.indices {
                guard let middle = middle[index], let range = range[index] else { continue }
                upper[index] = middle + 2 * range
                lower[index] = middle - 2 * range
            }
            series.bands.append(Band(label: "KC", color: ChartTint.purple, upper: upper, lower: lower, middle: middle))
        }
        if indicators.contains(.supertrend) { series.supertrend = ChartMath.supertrend(window) }
        if indicators.contains(.sar) { series.sar = ChartMath.sar(window) }
        if indicators.contains(.ichimoku) { series.ichimoku = ChartMath.ichimoku(window) }

        let levels: Pane.Scale = .fixed(0...100)
        if indicators.contains(.rsi) {
            series.panes[.rsi] = Pane(
                title: "RSI 14", lines: [Line(label: "", color: ChartTint.purple, values: ChartMath.rsi(closes))],
                scale: levels, guides: [30, 70], format: .plain(1)
            )
        }
        if indicators.contains(.macd) {
            let macd = ChartMath.macd(closes)
            series.panes[.macd] = Pane(
                title: "MACD 12 26 9",
                lines: [Line(label: "", color: ChartTint.blue, values: macd.macd), Line(label: "", color: ChartTint.orange, values: macd.signal)],
                histogram: macd.histogram, scale: .centered, format: .price
            )
        }
        if indicators.contains(.stoch) {
            let stoch = ChartMath.stochastic(high: window.map(\.h), low: window.map(\.l), close: closes)
            series.panes[.stoch] = Pane(
                title: "Stoch 14 3 3",
                lines: [Line(label: "%K", color: ChartTint.blue, values: stoch.k), Line(label: "%D", color: ChartTint.orange, values: stoch.d)],
                scale: levels, guides: [20, 80], format: .plain(1)
            )
        }
        if indicators.contains(.stochRSI) {
            let stoch = ChartMath.stochasticRSI(closes)
            series.panes[.stochRSI] = Pane(
                title: "Stoch RSI 14",
                lines: [Line(label: "%K", color: ChartTint.blue, values: stoch.k), Line(label: "%D", color: ChartTint.orange, values: stoch.d)],
                scale: levels, guides: [20, 80], format: .plain(1)
            )
        }
        if indicators.contains(.atr) {
            series.panes[.atr] = Pane(
                title: "ATR 14", lines: [Line(label: "", color: ChartTint.gold, values: ChartMath.atr(window))],
                scale: .auto, format: .price
            )
        }
        if indicators.contains(.obv) {
            series.panes[.obv] = Pane(
                title: "OBV", lines: [Line(label: "", color: ChartTint.teal, values: ChartMath.obv(window))],
                scale: .auto, format: .compact
            )
        }
        if indicators.contains(.cci) {
            series.panes[.cci] = Pane(
                title: "CCI 20", lines: [Line(label: "", color: ChartTint.slate, values: ChartMath.cci(window))],
                scale: .centered, guides: [-100, 100], format: .plain(0)
            )
        }
        if indicators.contains(.mfi) {
            series.panes[.mfi] = Pane(
                title: "MFI 14", lines: [Line(label: "", color: ChartTint.teal, values: ChartMath.mfi(window))],
                scale: levels, guides: [20, 80], format: .plain(1)
            )
        }
        if indicators.contains(.williams) {
            series.panes[.williams] = Pane(
                title: "Williams %R 14", lines: [Line(label: "", color: ChartTint.purple, values: ChartMath.williamsR(window))],
                scale: .fixed(-100...0), guides: [-80, -20], format: .plain(1)
            )
        }
        if indicators.contains(.adx) {
            let adx = ChartMath.adx(window)
            series.panes[.adx] = Pane(
                title: "ADX 14",
                lines: [
                    Line(label: "ADX", color: ChartTint.gold, values: adx.adx),
                    Line(label: "+DI", color: PowderPalette.signalGreen, values: adx.plus),
                    Line(label: "−DI", color: PowderPalette.riskCoral, values: adx.minus),
                ],
                scale: .fixed(0...100), guides: [25], format: .plain(1)
            )
        }
        return series
    }
}

/// Keeps the last computed studies, so moving the pointer or the once-a-second redraw does not work them out again.
/// They are recomputed only when the candles in view, or the studies asked for, change.
@MainActor
final class ChartSeriesCache {
    private struct Key: Equatable {
        let base: Int
        let count: Int
        let first: Int64
        let checksum: Double
        let indicators: Set<ChartIndicator>
        let interval: HLInterval
    }

    private var key: Key?
    private var series = ChartSeries()

    func series(window: [HLCandle], base: Int, indicators: Set<ChartIndicator>, interval: HLInterval) -> ChartSeries {
        // One pass over the candles is far cheaper than the studies, and catches a revised candle anywhere.
        var checksum = 0.0
        for candle in window { checksum += candle.o + 2 * candle.h + 3 * candle.l + 5 * candle.c + 7 * candle.v }
        let next = Key(
            base: base, count: window.count, first: window.first?.t ?? 0, checksum: checksum,
            indicators: indicators.subtracting([.volume, .volumeProfile]), interval: interval
        )
        if next != key {
            key = next
            series = ChartSeries.build(window: window, indicators: indicators, interval: interval)
        }
        return series
    }
}
