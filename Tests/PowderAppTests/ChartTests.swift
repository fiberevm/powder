import AppKit
import Foundation
import SwiftUI
import Testing
@testable import PowderApp

/// A repeatable wandering market: the same candles on every run.
private func sampleCandles(_ count: Int = 600, interval: HLInterval = .m15) -> [HLCandle] {
    var seed: UInt64 = 42
    func next() -> Double {
        seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Double(seed >> 33) / Double(1 << 31)
    }
    var price = 100.0
    return (0..<count).map { index in
        let open = price
        price = max(open * (1 + (next() - 0.5) * 0.02), 1)
        let high = max(open, price) * (1 + next() * 0.004), low = min(open, price) * (1 - next() * 0.004)
        return HLCandle(
            t: 1_700_000_000_000 + Int64(index) * interval.milliseconds, coin: "TEST", interval: interval.rawValue,
            o: open, h: high, l: low, c: price, v: 10 + next() * 90
        )
    }
}

@Test
func chartStudiesStayInRangeAndLineUp() {
    let candles = sampleCandles()
    let closes = candles.map(\.c), highs = candles.map(\.h), lows = candles.map(\.l)

    #expect(ChartMath.highest([1, 3, 2, 5, 4], 3) == [nil, nil, 3, 5, 5])
    #expect(ChartMath.lowest([1, 3, 2, 5, 4], 3) == [nil, nil, 1, 2, 2])
    #expect(ChartMath.wilder([2, 2, 2, 2], 2) == [nil, 2, 2, 2])

    let stoch = ChartMath.stochastic(high: highs, low: lows, close: closes)
    let stochRSI = ChartMath.stochasticRSI(closes)
    for series in [stoch.k, stoch.d, stochRSI.k, stochRSI.d, ChartMath.mfi(candles)] {
        #expect(series.count == candles.count)
        #expect(series.last! != nil)
        #expect(series.compactMap { $0 }.allSatisfy { $0 >= -0.0001 && $0 <= 100.0001 })
    }
    #expect(ChartMath.williamsR(candles).compactMap { $0 }.allSatisfy { $0 <= 0 && $0 >= -100 })

    let range = ChartMath.atr(candles)
    #expect(range[12] == nil && range[13] != nil)
    #expect(range.compactMap { $0 }.allSatisfy { $0 > 0 })

    // The supertrend sits under the close while rising and over it while falling.
    let trend = ChartMath.supertrend(candles)
    for index in candles.indices {
        guard let stop = trend.line[index] else { continue }
        #expect(trend.rising[index] ? stop <= candles[index].c : stop >= candles[index].c)
    }

    let strength = ChartMath.adx(candles)
    #expect(strength.adx.last! != nil)
    #expect(strength.adx.compactMap { $0 }.allSatisfy { $0 >= 0 && $0 <= 100 })

    // On-balance volume rises by the candle's volume on an up close.
    let balance = ChartMath.obv(candles)
    let step = balance[10]! - balance[9]!
    #expect(abs(step) == (candles[10].c == candles[9].c ? 0 : candles[10].v))

    // The cloud runs 26 candles past the last one, and the lagging line stops 26 short of it.
    let cloud = ChartMath.ichimoku(candles)
    #expect(cloud.spanA.count == candles.count + 26)
    #expect(cloud.spanB.last! != nil)
    #expect(cloud.lagging[candles.count - 27] == closes.last && cloud.lagging.last! == nil)

    #expect(ChartMath.sar(candles).dropFirst().allSatisfy { $0 != nil })
    #expect(ChartMath.cci(candles).last! != nil)
}

@Test
func chartSettingsLoadOlderAndNewerSaves() throws {
    // What a build before the new scales and studies wrote.
    let old = #"{"style":"hollow","indicators":["volume","rsi"],"logScale":true}"#
    let settings = try JSONDecoder().decode(ChartSettings.self, from: Data(old.utf8))
    #expect(settings.style == .hollow && settings.indicators == [.volume, .rsi] && settings.logScale)
    #expect(!settings.percentScale && !settings.invertScale && !settings.magnet)

    // A study or style this build does not know is dropped, not a reason to lose everything.
    let newer = #"{"style":"renko","indicators":["volume","somethingNew"],"magnet":true}"#
    let tolerant = try JSONDecoder().decode(ChartSettings.self, from: Data(newer.utf8))
    #expect(tolerant.style == .candles && tolerant.indicators == [.volume] && tolerant.magnet)

    var changed = ChartSettings()
    changed.indicators = [.ichimoku, .adx]
    changed.invertScale = true
    #expect(try JSONDecoder().decode(ChartSettings.self, from: JSONEncoder().encode(changed)) == changed)

    // A drawing saved before colours and channels existed.
    let line = #"[{"id":"7F0C3C0A-58B5-4B4F-9A58-0B0C3D8F7C11","kind":"ray","startTime":1,"startPrice":2,"endTime":3,"endPrice":4}]"#
    let drawings = try JSONDecoder().decode([ChartDrawing].self, from: Data(line.utf8))
    #expect(drawings.first?.kind == .ray && drawings.first?.extra == nil)
}

@Test
func chartDrawingsHitMoveAndReshape() {
    let candles = sampleCandles()
    let interval = HLInterval.m15
    for inverted in [false, true] {
        var settings = ChartSettings()
        settings.invertScale = inverted
        let layout = ChartLayout(
            size: CGSize(width: 900, height: 500), candles: candles, pitch: 8, offset: 0, priceZoom: 1, pricePan: 0, settings: settings
        )
        // Price and screen position convert back and forth, whichever way up the axis is.
        let price = layout.price(atY: 200)
        #expect(abs(layout.y(price) - 200) < 0.001)
        #expect((layout.y(layout.high) < layout.y(layout.low)) == !inverted)

        let start = CGPoint(x: 300, y: 150), end = CGPoint(x: 500, y: 260)
        let trend = ChartDrawing(
            kind: .trend, startTime: layout.time(atPointX: start.x, interval: interval), startPrice: layout.price(atY: start.y),
            endTime: layout.time(atPointX: end.x, interval: interval), endPrice: layout.price(atY: end.y)
        )
        #expect(layout.hit(start, trend, interval: interval) == .handle(0))
        #expect(layout.hit(end, trend, interval: interval) == .handle(1))
        #expect(layout.hit(CGPoint(x: 400, y: 205), trend, interval: interval) == .body)
        #expect(layout.hit(CGPoint(x: 400, y: 260), trend, interval: interval) == nil)
        // Past its second point a trend line stops, and a ray carries on.
        var ray = trend
        ray.kind = .ray
        #expect(layout.hit(CGPoint(x: 600, y: 315), trend, interval: interval) == nil)
        #expect(layout.hit(CGPoint(x: 600, y: 315), ray, interval: interval) == .body)

        // Dragged by whole candles and some points down, it lands where it was dropped.
        let moved = layout.moved(trend, dx: 80, dy: 30, interval: interval)
        let (a, b) = layout.anchors(of: moved, interval: interval)
        #expect(abs(a.x - 380) < 0.5 && abs(a.y - 180) < 0.5 && abs(b.x - 580) < 0.5 && abs(b.y - 290) < 0.5)

        let reshaped = layout.reshaped(trend, handle: 1, to: CGPoint(x: 520, y: 100), interval: interval, magnet: false)
        #expect(reshaped.startPrice == trend.startPrice && abs(layout.y(reshaped.endPrice) - 100) < 0.001)

        // A rectangle is taken by its outline, so the chart can still be panned through its middle.
        var box = trend
        box.kind = .rectangle
        #expect(layout.hit(CGPoint(x: 400, y: 150), box, interval: interval) == .body)
        #expect(layout.hit(CGPoint(x: 400, y: 205), box, interval: interval) == nil)

        // The magnet pulls a point onto the candle's nearest price.
        let index = layout.index(atX: 400)
        let candle = layout.candle(index)!
        #expect(layout.snappedPrice(at: CGPoint(x: 400, y: layout.y(candle.h))) == candle.h)
    }
}

/// Draws every chart type with every study and one of each drawing, on both scales. A crash or an
/// out-of-range index anywhere in the renderer fails here. Set POWDER_CHART_PNG to a folder to keep the pictures.
@Test @MainActor
func chartRendersEveryStyleStudyAndDrawing() throws {
    let candles = sampleCandles()
    let interval = HLInterval.m15
    let cache = ChartSeriesCache()
    for (pass, style) in ChartStyle.allCases.enumerated() {
        var settings = ChartSettings()
        settings.style = style
        settings.indicators = Set(ChartIndicator.allCases.filter { !$0.isPane }).union(pass.isMultiple(of: 2) ? [.rsi, .macd, .adx] : [.stoch, .obv, .cci])
        settings.logScale = pass % 3 == 1
        settings.percentScale = pass % 3 == 2
        settings.invertScale = pass == 3
        let size = CGSize(width: 1_100, height: 760)
        let layout = ChartLayout(size: size, candles: candles, pitch: 7, offset: CGFloat(pass * 9), priceZoom: 1, pricePan: 0, settings: settings)
        #expect(layout.panes.count == 3)

        func drawing(_ kind: DrawTool, _ from: CGPoint, _ to: CGPoint, color: Int) -> ChartDrawing {
            var drawing = ChartDrawing(
                kind: kind, startTime: layout.time(atPointX: from.x, interval: interval), startPrice: layout.price(atY: from.y),
                endTime: layout.time(atPointX: to.x, interval: interval), endPrice: layout.price(atY: to.y)
            )
            drawing.color = color
            if kind == .channel { drawing.extra = layout.price(atY: from.y + 40) - drawing.startPrice }
            if kind == .position { drawing.extra = layout.price(atY: from.y + 30) }
            return drawing
        }
        let drawings = DrawTool.allCases.enumerated().map { position, kind in
            let x = 60 + CGFloat(position) * 80
            return drawing(kind, CGPoint(x: x, y: 120 + CGFloat(position % 4) * 40), CGPoint(x: x + 70, y: 90 + CGFloat(position % 3) * 50), color: position % 6)
        }
        let series = cache.series(window: layout.window, base: layout.base, indicators: settings.indicators, interval: interval)
        #expect(series.panes.count == 3 && series.ichimoku != nil && series.bands.count == 3)
        let renderer = ChartRenderer(
            layout: layout, series: series, cursorTime: candles[candles.count - 20 - pass * 9].t, hover: CGPoint(x: 400, y: 200),
            measure: ChartMeasure(startIndex: 500, startPrice: layout.price(atY: 300), endIndex: 540, endPrice: layout.price(atY: 250)),
            drawings: drawings, selectedDrawing: drawings[pass % drawings.count].id, interval: interval, decimals: 2, settings: settings,
            priceLines: [layout.price(atY: 330)], levels: [ChartLevel(kind: .entryLong, price: layout.price(atY: 280), label: "LONG 1 · ENTRY")],
            isReplay: pass == 2, isLoadingHistory: false
        )
        let image = ImageRenderer(
            content: Canvas { context, _ in renderer.draw(in: &context, now: Date(timeIntervalSince1970: 1_700_500_000)) }
                .frame(width: size.width, height: size.height)
                .background(Term.background)
                .environment(\.colorScheme, .dark)
        )
        image.scale = 2
        let picture = try #require(image.nsImage)
        if let folder = ProcessInfo.processInfo.environment["POWDER_CHART_PNG"],
           let data = picture.tiffRepresentation.flatMap({ NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) }) {
            try data.write(to: URL(fileURLWithPath: folder).appendingPathComponent("chart-\(style.rawValue).png"))
        }
    }

    // The same candles and studies come back from the cache untouched; a changed candle is recomputed.
    let settings = ChartSettings()
    let layout = ChartLayout(size: CGSize(width: 900, height: 500), candles: candles, pitch: 8, offset: 0, priceZoom: 1, pricePan: 0, settings: settings)
    let first = cache.series(window: layout.window, base: layout.base, indicators: [.ma], interval: interval)
    var revised = layout.window
    let last = revised.removeLast()
    revised.append(HLCandle(t: last.t, coin: last.coin, interval: last.interval, o: last.o, h: last.h, l: last.l, c: last.c * 1.01, v: last.v))
    let second = cache.series(window: revised, base: layout.base, indicators: [.ma], interval: interval)
    #expect(first.lines[0].values.last! != second.lines[0].values.last!)
}
