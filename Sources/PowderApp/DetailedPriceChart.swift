import Charts
import SwiftUI

enum PriceChartStyle: String, CaseIterable, Identifiable, Sendable {
    case candles
    case line

    var id: Self { self }

    var label: String {
        switch self {
        case .candles: "Candlesticks"
        case .line: "Close line"
        }
    }

    var systemImage: String {
        switch self {
        case .candles: "chart.bar.fill"
        case .line: "chart.xyaxis.line"
        }
    }
}

enum DetailStreamState {
    case demo
    case connecting
    case live
    case snapshot

    var label: String {
        switch self {
        case .demo: "Demo"
        case .connecting: "Connecting"
        case .live: "Live"
        case .snapshot: "Snapshot"
        }
    }

    var color: Color {
        switch self {
        case .demo, .snapshot: PowderPalette.cautionAmber
        case .connecting: PowderPalette.scopeBlue
        case .live: PowderPalette.signalGreen
        }
    }

    var systemImage: String {
        switch self {
        case .demo: "testtube.2"
        case .connecting: "arrow.trianglehead.2.clockwise.rotate.90"
        case .live: "dot.radiowaves.left.and.right"
        case .snapshot: "pause.fill"
        }
    }
}

struct DetailStreamBadge: View {
    let state: DetailStreamState

    var body: some View {
        Label(state.label, systemImage: state.systemImage)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(state.color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(state.color.opacity(0.1), in: Capsule())
            .accessibilityLabel("Chart status: \(state.label)")
    }
}

struct CandleReadout: View {
    let label: String
    let value: String
    var color: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(.caption2, design: .monospaced, weight: .semibold))
                .foregroundStyle(.secondary)
            MonospacedValue(
                text: value,
                color: color,
                weight: .semibold,
                animatesChanges: false
            )
            .font(.caption)
            .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct DetailedPriceChart: View, Equatable {
    let points: [PricePoint]
    let style: PriceChartStyle
    let timeframe: ChartTimeframe
    let selection: PricePoint?
    @Binding var selectedPoint: PricePoint?

    nonisolated static func == (lhs: DetailedPriceChart, rhs: DetailedPriceChart) -> Bool {
        lhs.points == rhs.points
            && lhs.style == rhs.style
            && lhs.timeframe == rhs.timeframe
            && lhs.selection == rhs.selection
    }

    var body: some View {
        VStack(spacing: 8) {
            priceChart
                .frame(maxHeight: .infinity)

            volumeChart
                .frame(height: 86)

            HStack(spacing: 16) {
                Label("OHLC", systemImage: "chart.bar.fill")
                    .foregroundStyle(.secondary)
                Label("SMA 9", systemImage: "line.diagonal")
                    .foregroundStyle(PowderPalette.cautionAmber)
                Label("Volume", systemImage: "chart.bar.xaxis")
                    .foregroundStyle(PowderPalette.scopeBlue)
                Spacer()
                Text("\(points.count) \(timeframe.resolutionLabel) bars")
                    .foregroundStyle(.secondary)
            }
            .font(.caption2)
            .padding(.horizontal, 4)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Detailed token price and volume chart")
    }

    private var priceChart: some View {
        Chart {
            if style == .candles {
                ForEach(points) { point in
                    RuleMark(
                        x: .value("Time", point.timestamp),
                        yStart: .value("Low", point.low),
                        yEnd: .value("High", point.high)
                    )
                    .foregroundStyle(candleColor(point).opacity(0.82))
                    .lineStyle(StrokeStyle(lineWidth: 1))

                    RectangleMark(
                        x: .value("Time", point.timestamp),
                        yStart: .value("Open", point.open),
                        yEnd: .value("Close", candleBodyEnd(point)),
                        width: .fixed(candleWidth)
                    )
                    .foregroundStyle(candleColor(point))
                    .cornerRadius(1)
                }
            } else {
                ForEach(points) { point in
                    AreaMark(
                        x: .value("Time", point.timestamp),
                        yStart: .value("Baseline", lowerBound),
                        yEnd: .value("Close", point.close)
                    )
                    .foregroundStyle(
                        .linearGradient(
                            colors: [
                                PowderPalette.scopeBlue.opacity(0.18),
                                PowderPalette.scopeBlue.opacity(0.015)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .interpolationMethod(.catmullRom)

                    LineMark(
                        x: .value("Time", point.timestamp),
                        y: .value("Close", point.close)
                    )
                    .foregroundStyle(PowderPalette.scopeBlue)
                    .lineStyle(
                        StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
                    )
                    .interpolationMethod(.catmullRom)
                }
            }

            ForEach(movingAverage) { sample in
                LineMark(
                    x: .value("Time", sample.timestamp),
                    y: .value("SMA 9", sample.value),
                    series: .value("Series", "SMA 9")
                )
                .foregroundStyle(PowderPalette.cautionAmber.opacity(0.9))
                .lineStyle(StrokeStyle(lineWidth: 1.25))
                .interpolationMethod(.catmullRom)
            }

            if let selection {
                RuleMark(x: .value("Inspected time", selection.timestamp))
                    .foregroundStyle(.secondary.opacity(0.48))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 4]))

                RuleMark(y: .value("Inspected price", selection.close))
                    .foregroundStyle(.secondary.opacity(0.28))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 4]))

                PointMark(
                    x: .value("Inspected time", selection.timestamp),
                    y: .value("Inspected price", selection.close)
                )
                .symbolSize(30)
                .foregroundStyle(PowderPalette.scopeBlue)
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(.secondary.opacity(0.1))
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 5)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(.secondary.opacity(0.12))
                AxisValueLabel {
                    if let price = value.as(Double.self) {
                        Text(PowderFormat.currency(price, precise: true))
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .chartXScale(domain: xDomain)
        .chartYScale(domain: lowerBound...upperBound)
        .chartPlotStyle { plotArea in
            plotArea
                .background(.secondary.opacity(0.025))
                .border(.secondary.opacity(0.08), width: 0.5)
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case let .active(location):
                            guard let plotFrame = proxy.plotFrame else { return }
                            let frame = geometry[plotFrame]
                            let xPosition = location.x - frame.origin.x
                            guard xPosition >= 0,
                                  xPosition <= frame.width,
                                  let date: Date = proxy.value(atX: xPosition) else {
                                selectedPoint = nil
                                return
                            }
                            selectedPoint = points.min {
                                abs($0.timestamp.timeIntervalSince(date))
                                    < abs($1.timestamp.timeIntervalSince(date))
                            }
                        case .ended:
                            selectedPoint = nil
                        }
                    }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            style == .candles
                ? "Token candlesticks over time"
                : "Token close price over time"
        )
        .accessibilityValue(
            points.last.map { PowderFormat.currency($0.close, precise: true) } ?? "No price"
        )
    }

    private var volumeChart: some View {
        Chart {
            ForEach(points) { point in
                BarMark(
                    x: .value("Time", point.timestamp),
                    y: .value("Volume", point.volume),
                    width: .fixed(candleWidth)
                )
                .foregroundStyle(candleColor(point).opacity(0.58))
            }

            if let selection {
                RuleMark(x: .value("Inspected time", selection.timestamp))
                    .foregroundStyle(.secondary.opacity(0.4))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 4]))
            }
        }
        .chartXScale(domain: xDomain)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(.secondary.opacity(0.09))
                AxisValueLabel(format: xAxisFormat)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 2)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(.secondary.opacity(0.09))
                AxisValueLabel {
                    if let volume = value.as(Double.self) {
                        Text(PowderFormat.currency(volume))
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .chartPlotStyle { plotArea in
            plotArea
                .background(.secondary.opacity(0.02))
                .border(.secondary.opacity(0.08), width: 0.5)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Trading volume over time")
        .accessibilityValue(
            points.last.map { PowderFormat.currency($0.volume) } ?? "No volume"
        )
    }

    private var movingAverage: [MovingAverageSample] {
        guard points.count >= 9 else { return [] }

        return (8..<points.count).map { index in
            let average = points[(index - 8)...index]
                .reduce(0) { $0 + $1.close } / 9
            return MovingAverageSample(
                timestamp: points[index].timestamp,
                value: average
            )
        }
    }

    private var xDomain: ClosedRange<Date> {
        let start = points.first?.timestamp ?? Date()
        let end = points.last?.timestamp ?? start.addingTimeInterval(1)
        return start...max(end, start.addingTimeInterval(1))
    }

    private var xAxisFormat: Date.FormatStyle {
        switch timeframe {
        case .hour, .sixHours, .day:
            .dateTime.hour().minute()
        case .week:
            .dateTime.weekday(.abbreviated).hour()
        case .month:
            .dateTime.month(.abbreviated).day()
        }
    }

    private func candleColor(_ point: PricePoint) -> Color {
        point.isUp ? PowderPalette.signalGreen : PowderPalette.riskCoral
    }

    private var candleWidth: CGFloat {
        switch points.count {
        case 0...12: 14
        case 13...40: 8
        case 41...100: 5
        default: 3
        }
    }

    private func candleBodyEnd(_ point: PricePoint) -> Double {
        guard point.open == point.close else { return point.close }
        let minimumBody = max((upperBound - lowerBound) * 0.0015, point.close * 0.0001)
        return point.close + minimumBody
    }

    private var lowerBound: Double {
        let minValue = points.map(\.low).min() ?? 0
        let maxValue = points.map(\.high).max() ?? 1
        let padding = max((maxValue - minValue) * 0.12, maxValue * 0.005)
        return max(minValue - padding, 0)
    }

    private var upperBound: Double {
        let minValue = points.map(\.low).min() ?? 0
        let maxValue = points.map(\.high).max() ?? 1
        let padding = max((maxValue - minValue) * 0.12, maxValue * 0.005)
        return maxValue + padding
    }
}

private struct MovingAverageSample: Identifiable {
    let timestamp: Date
    let value: Double

    var id: Date { timestamp }
}
