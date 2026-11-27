import SwiftUI

// MARK: - Model

enum DrawTool: String, Codable, CaseIterable, Sendable {
    case trend, ray, extended, arrow, horizontal, horizontalRay, vertical, rectangle, channel, fib, position, measure

    var title: String {
        switch self {
        case .trend: "Trend line"
        case .ray: "Ray"
        case .extended: "Extended line"
        case .arrow: "Arrow"
        case .horizontal: "Horizontal line"
        case .horizontalRay: "Horizontal ray"
        case .vertical: "Vertical line"
        case .rectangle: "Rectangle"
        case .channel: "Parallel channel"
        case .fib: "Fib retracement"
        case .position: "Long / short position"
        case .measure: "Price range"
        }
    }

    /// Placed with a click rather than dragged out.
    var isOneClick: Bool { self == .horizontal || self == .horizontalRay || self == .vertical }

    /// Where the Draw menu starts a new group.
    var startsSection: Bool { self == .horizontal || self == .rectangle || self == .fib }
}

/// Something the user drew, anchored in time and price so it holds its place on every interval and zoom.
struct ChartDrawing: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var kind: DrawTool
    var startTime: Int64
    var startPrice: Double
    var endTime: Int64
    var endPrice: Double
    /// A channel's width, as a price offset from its first line; a position's stop price.
    var extra: Double?
    /// Index into `tints`; nil is the first.
    var color: Int?

    static let tints: [(name: String, color: Color)] = [
        ("Blue", ChartTint.blue), ("Gold", Term.accent), ("Green", PowderPalette.signalGreen),
        ("Red", PowderPalette.riskCoral), ("Purple", ChartTint.purple), ("Gray", Term.foreground),
    ]

    var tint: Color { Self.tints[min(max(color ?? 0, 0), Self.tints.count - 1)].color }

    static let fibLevels: [Double] = [0, 0.236, 0.382, 0.5, 0.618, 0.786, 1]
}

enum DrawingHit: Equatable {
    case handle(Int)
    case body
}

// MARK: - Geometry

extension ChartLayout {
    /// The drawing's two anchor points on screen.
    func anchors(of drawing: ChartDrawing, interval: HLInterval) -> (CGPoint, CGPoint) {
        (
            CGPoint(x: x(time: drawing.startTime, interval: interval), y: y(drawing.startPrice)),
            CGPoint(x: x(time: drawing.endTime, interval: interval), y: y(drawing.endPrice))
        )
    }

    /// `end`, pushed out along the line from `start` until it is past the plot.
    func extended(from start: CGPoint, through end: CGPoint) -> CGPoint {
        let dx = end.x - start.x, dy = end.y - start.y
        let length = hypot(dx, dy)
        guard length > 0.01 else { return end }
        let reach = max((hypot(start.x - plot.midX, start.y - plot.midY) + plot.width + plot.height) / length, 1)
        return CGPoint(x: start.x + dx * reach, y: start.y + dy * reach)
    }

    /// How far down the screen a channel's second line sits from its first.
    func channelOffset(_ drawing: ChartDrawing) -> CGFloat {
        y(drawing.startPrice + (drawing.extra ?? 0)) - y(drawing.startPrice)
    }

    /// The points a selected drawing can be reshaped by.
    func handles(of drawing: ChartDrawing, interval: HLInterval) -> [CGPoint] {
        let (a, b) = anchors(of: drawing, interval: interval)
        switch drawing.kind {
        case .horizontal, .horizontalRay, .vertical:
            return [a]
        case .channel:
            return [a, b, CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 + channelOffset(drawing))]
        case .position:
            return [a, b, CGPoint(x: a.x, y: y(drawing.extra ?? drawing.startPrice))]
        default:
            return [a, b]
        }
    }

    /// The box a position tool covers: entry at the first anchor, target at the second, stop on the far side.
    func positionBox(_ drawing: ChartDrawing, interval: HLInterval) -> (x: ClosedRange<CGFloat>, entry: CGFloat, target: CGFloat, stop: CGFloat) {
        let (a, b) = anchors(of: drawing, interval: interval)
        let left = min(a.x, b.x)
        return (left...max(max(a.x, b.x), left + 24), a.y, b.y, y(drawing.extra ?? drawing.startPrice))
    }

    func fibY(_ drawing: ChartDrawing, _ level: Double) -> CGFloat {
        y(drawing.endPrice + (drawing.startPrice - drawing.endPrice) * level)
    }

    private func distance(from point: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(point.x - a.x, point.y - a.y) }
        let t = min(max(((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared, 0), 1)
        return hypot(point.x - (a.x + t * dx), point.y - (a.y + t * dy))
    }

    /// Distance to a rectangle's outline, from inside or out.
    private func distance(from point: CGPoint, toBorderOf rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX), dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        if dx > 0 || dy > 0 { return hypot(dx, dy) }
        return min(point.x - rect.minX, rect.maxX - point.x, point.y - rect.minY, rect.maxY - point.y)
    }

    /// How far a point is from the nearest stroke of a drawing. Filled areas do not count, so they can be panned through.
    func distance(from point: CGPoint, to drawing: ChartDrawing, interval: HLInterval) -> CGFloat {
        let (a, b) = anchors(of: drawing, interval: interval)
        switch drawing.kind {
        case .trend, .arrow:
            return distance(from: point, toSegment: a, b)
        case .ray:
            return distance(from: point, toSegment: a, extended(from: a, through: b))
        case .extended:
            return distance(from: point, toSegment: extended(from: b, through: a), extended(from: a, through: b))
        case .horizontal, .horizontalRay:
            return distance(from: point, toSegment: a, CGPoint(x: max(plot.maxX, a.x), y: a.y))
        case .vertical:
            return abs(point.x - a.x)
        case .rectangle, .measure:
            return distance(from: point, toBorderOf: CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y)))
        case .channel:
            let offset = channelOffset(drawing)
            return min(
                distance(from: point, toSegment: a, b),
                distance(from: point, toSegment: CGPoint(x: a.x, y: a.y + offset), CGPoint(x: b.x, y: b.y + offset))
            )
        case .fib:
            guard point.x >= min(a.x, b.x) - 4, point.x <= max(a.x, b.x) + 4 else { return .infinity }
            return ChartDrawing.fibLevels.map { abs(fibY(drawing, $0) - point.y) }.min() ?? .infinity
        case .position:
            let box = positionBox(drawing, interval: interval)
            let top = min(box.target, box.stop, box.entry), bottom = max(box.target, box.stop, box.entry)
            let rect = CGRect(x: box.x.lowerBound, y: top, width: box.x.upperBound - box.x.lowerBound, height: bottom - top)
            return min(
                distance(from: point, toBorderOf: rect),
                distance(from: point, toSegment: CGPoint(x: rect.minX, y: box.entry), CGPoint(x: rect.maxX, y: box.entry))
            )
        }
    }

    func hit(_ point: CGPoint, _ drawing: ChartDrawing, interval: HLInterval, handles: Bool = true) -> DrawingHit? {
        if handles, let index = self.handles(of: drawing, interval: interval).firstIndex(where: { hypot($0.x - point.x, $0.y - point.y) < 7 }) {
            return .handle(index)
        }
        return distance(from: point, to: drawing, interval: interval) < 6 ? .body : nil
    }

    /// The price under a point, pulled onto the candle's open, high, low or close when one is close by.
    func snappedPrice(at point: CGPoint) -> Double {
        let raw = price(atY: point.y)
        guard let candle = candle(index(atX: point.x)) else { return raw }
        var best = raw
        var nearest: CGFloat = 14
        for value in [candle.o, candle.h, candle.l, candle.c] {
            let gap = abs(y(value) - point.y)
            if gap < nearest {
                nearest = gap
                best = value
            }
        }
        return best
    }

    /// The drawing carried across the screen by `dx`, `dy` points, keeping its shape as drawn.
    func moved(_ drawing: ChartDrawing, dx: CGFloat, dy: CGFloat, interval: HLInterval) -> ChartDrawing {
        var out = drawing
        let shift = Int64((dx / pitch).rounded()) * interval.milliseconds
        out.startTime += shift
        out.endTime += shift
        out.startPrice = price(atY: y(drawing.startPrice) + dy)
        out.endPrice = price(atY: y(drawing.endPrice) + dy)
        if let extra = drawing.extra {
            out.extra = drawing.kind == .channel
                ? price(atY: y(drawing.startPrice + extra) + dy) - out.startPrice
                : price(atY: y(extra) + dy)
        }
        return out
    }

    /// The drawing with one of its handles dragged to `point`.
    func reshaped(_ drawing: ChartDrawing, handle: Int, to point: CGPoint, interval: HLInterval, magnet: Bool) -> ChartDrawing {
        var out = drawing
        let value = magnet ? snappedPrice(at: point) : price(atY: point.y)
        switch handle {
        case 0:
            out.startTime = time(atPointX: point.x, interval: interval)
            out.startPrice = value
            // One-point drawings keep both anchors together.
            if drawing.kind.isOneClick {
                out.endTime = out.startTime
                out.endPrice = value
            }
        case 1:
            out.endTime = time(atPointX: point.x, interval: interval)
            out.endPrice = value
        default:
            if drawing.kind == .channel {
                let (a, b) = anchors(of: drawing, interval: interval)
                out.extra = price(atY: a.y + point.y - (a.y + b.y) / 2) - drawing.startPrice
            } else {
                out.extra = value
            }
        }
        return out
    }
}

// MARK: - Rendering

extension ChartRenderer {
    func drawDrawings(_ pane: inout GraphicsContext, axis: inout GraphicsContext) {
        for drawing in drawings {
            let isSelected = drawing.id == selectedDrawing
            let isHot = isSelected || (hover.map { layout.hit($0, drawing, interval: interval, handles: false) != nil } ?? false)
            draw(drawing, width: isHot ? 2 : 1.5, in: &pane, axis: &axis)
            guard isSelected else { continue }
            for point in layout.handles(of: drawing, interval: interval) {
                let dot = CGRect(x: point.x - 3.5, y: point.y - 3.5, width: 7, height: 7)
                pane.fill(Path(ellipseIn: dot), with: .color(Term.background))
                pane.stroke(Path(ellipseIn: dot), with: .color(drawing.tint), lineWidth: 1.5)
            }
        }
    }

    private func line(_ a: CGPoint, _ b: CGPoint) -> Path {
        Path { path in
            path.move(to: a)
            path.addLine(to: b)
        }
    }

    private func draw(_ drawing: ChartDrawing, width: CGFloat, in pane: inout GraphicsContext, axis: inout GraphicsContext) {
        let (a, b) = layout.anchors(of: drawing, interval: interval)
        let color = drawing.tint
        let style = StrokeStyle(lineWidth: width, lineCap: .round)
        let rect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))

        switch drawing.kind {
        case .trend:
            pane.stroke(line(a, b), with: .color(color), style: style)

        case .ray:
            pane.stroke(line(a, layout.extended(from: a, through: b)), with: .color(color), style: style)

        case .extended:
            pane.stroke(line(layout.extended(from: b, through: a), layout.extended(from: a, through: b)), with: .color(color), style: style)

        case .arrow:
            let angle = atan2(b.y - a.y, b.x - a.x)
            var path = line(a, b)
            for side in [-1.0, 1.0] {
                let wing = angle + .pi + side * 0.42
                path.move(to: b)
                path.addLine(to: CGPoint(x: b.x + cos(wing) * 11, y: b.y + sin(wing) * 11))
            }
            pane.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))

        case .horizontal, .horizontalRay:
            let y = a.y.rounded() + 0.5
            pane.stroke(line(CGPoint(x: a.x, y: y), CGPoint(x: max(layout.plot.maxX, a.x), y: y)), with: .color(color), style: style)
            if y >= layout.mainPane.minY, y <= layout.mainPane.maxY {
                tag(HLFormat.price(drawing.startPrice, decimals: decimals), fill: color, at: CGPoint(x: layout.plot.maxX + 1, y: y), anchor: .leading, in: &axis)
            }

        case .vertical:
            let x = a.x.rounded() + 0.5
            pane.stroke(line(CGPoint(x: x, y: layout.mainPane.minY), CGPoint(x: x, y: layout.mainPane.maxY)), with: .color(color), style: style)
            pane.draw(
                Text(timeLabel(drawing.startTime, date: true, time: !interval.isDaily)).font(labelFont).foregroundStyle(color),
                at: CGPoint(x: x + 5, y: layout.mainPane.maxY - 10), anchor: .leading
            )

        case .rectangle:
            pane.fill(Path(rect), with: .color(color.opacity(0.1)))
            pane.stroke(Path(rect), with: .color(color), lineWidth: width)

        case .channel:
            let offset = layout.channelOffset(drawing)
            let c = CGPoint(x: a.x, y: a.y + offset), d = CGPoint(x: b.x, y: b.y + offset)
            var fill = Path()
            fill.addLines([a, b, d, c])
            fill.closeSubpath()
            pane.fill(fill, with: .color(color.opacity(0.08)))
            pane.stroke(line(a, b), with: .color(color), style: style)
            pane.stroke(line(c, d), with: .color(color), style: style)
            pane.stroke(
                line(CGPoint(x: a.x, y: a.y + offset / 2), CGPoint(x: b.x, y: b.y + offset / 2)),
                with: .color(color.opacity(0.6)), style: StrokeStyle(lineWidth: 1, dash: [4, 4])
            )

        case .fib:
            let levels = ChartDrawing.fibLevels
            for (position, level) in levels.enumerated() {
                let y = layout.fibY(drawing, level).rounded() + 0.5
                if position > 0 {
                    let previous = layout.fibY(drawing, levels[position - 1]).rounded() + 0.5
                    let band = CGRect(x: rect.minX, y: min(y, previous), width: rect.width, height: abs(y - previous))
                    pane.fill(Path(band), with: .color(color.opacity(position.isMultiple(of: 2) ? 0.05 : 0.1)))
                }
                pane.stroke(line(CGPoint(x: rect.minX, y: y), CGPoint(x: rect.maxX, y: y)), with: .color(color.opacity(0.85)), lineWidth: level == 0 || level == 1 ? width : 1)
                let price = drawing.endPrice + (drawing.startPrice - drawing.endPrice) * level
                pane.draw(
                    Text("\(String(format: "%g", level))  \(HLFormat.price(price, decimals: decimals))").font(labelFont).foregroundStyle(color),
                    at: CGPoint(x: rect.minX + 4, y: y - 7), anchor: .leading
                )
            }
            pane.stroke(line(a, b), with: .color(color.opacity(0.45)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

        case .position:
            let box = layout.positionBox(drawing, interval: interval)
            let entry = drawing.startPrice, target = drawing.endPrice, stop = drawing.extra ?? entry
            let span = box.x.upperBound - box.x.lowerBound
            let reward = CGRect(x: box.x.lowerBound, y: min(box.entry, box.target), width: span, height: abs(box.target - box.entry))
            let risk = CGRect(x: box.x.lowerBound, y: min(box.entry, box.stop), width: span, height: abs(box.stop - box.entry))
            pane.fill(Path(reward), with: .color(up.opacity(0.16)))
            pane.fill(Path(risk), with: .color(down.opacity(0.16)))
            pane.stroke(
                line(CGPoint(x: box.x.lowerBound, y: box.entry), CGPoint(x: box.x.upperBound, y: box.entry)),
                with: .color(Term.foreground.opacity(0.8)), lineWidth: width
            )
            let center = min(max(reward.midX, 90), layout.plot.maxX - 90)
            if entry > 0 {
                tag(
                    "TARGET \(HLFormat.price(target, decimals: decimals))  \(HLFormat.percent(abs(target / entry - 1)))", fill: up,
                    at: CGPoint(x: center, y: box.target + (box.target <= box.entry ? -10 : 10)), anchor: .center, in: &pane
                )
                tag(
                    "STOP \(HLFormat.price(stop, decimals: decimals))  \(HLFormat.percent(-abs(stop / entry - 1)))", fill: down,
                    at: CGPoint(x: center, y: box.stop + (box.stop >= box.entry ? 10 : -10)), anchor: .center, in: &pane
                )
            }
            let ratio = abs(entry - stop) > 0 ? String(format: "%.2f", abs(target - entry) / abs(entry - stop)) : "–"
            tag(
                "\(target >= entry ? "LONG" : "SHORT")  R:R \(ratio)", fill: Color(dark: 0x4A4A4A, light: 0x5A5A5A), text: .white,
                at: CGPoint(x: center, y: box.entry), anchor: .center, in: &pane
            )

        case .measure:
            let bars = Int((Double(drawing.endTime - drawing.startTime) / Double(interval.milliseconds)).rounded())
            drawMeasure(from: a, to: b, startPrice: drawing.startPrice, endPrice: drawing.endPrice, bars: bars, in: &axis)
        }
    }
}
