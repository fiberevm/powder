import AppKit
import Charts
import SwiftUI

struct TokenDetailView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var navigation: LaunchpadNavigation
    @Environment(\.colorScheme) private var colorScheme
    @State private var points: [PricePoint] = []
    @State private var timeframe: ChartTimeframe = .day
    @State private var chartStyle: PriceChartStyle = .candles
    @State private var chartIsLoading = true
    @State private var chartProvenance = "Loading price history…"
    @State private var detailStreamState: DetailStreamState = .connecting
    @State private var selectedPoint: PricePoint?
    @State private var liveHolders: Int?
    @State private var lastDetailEventAt: Date?
    @State private var copied = false

    let token: TokenSnapshot

    private var liveToken: TokenSnapshot {
        model.token(withID: token.id) ?? token
    }

    private var displayedPrice: Double {
        points.last?.close ?? liveToken.priceUSD
    }

    private var displayedHolders: Int {
        liveHolders ?? liveToken.holders
    }

    private var displayedLiquidity: Double {
        points.last?.liquidityUSD ?? liveToken.liquidityUSD
    }

    private var paneBar: some View {
        HStack(spacing: 10) {
            Button {
                navigation.token = nil
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.left")
                    Text("Launchpad")
                }
                .font(Term.font(12))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help("Back to the launchpad (esc)")

            Text(liveToken.symbol)
                .font(Term.font(12, .semibold))
                .foregroundStyle(Term.foreground)

            Spacer()

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(liveToken.address, forType: .string)
                copied = true
            } label: {
                Label(copied ? "Copied" : "Copy address", systemImage: copied ? "checkmark" : "doc.on.doc")
                    .font(Term.font(11))
            }
            .buttonStyle(.plain)
            .help("Copy token address")
        }
        .padding(.horizontal, 12)
        .frame(height: 28)
        .background(Term.chrome)
        .overlay(alignment: .bottom) { TermRule() }
    }

    var body: some View {
        VStack(spacing: 0) {
            paneBar
            detail
        }
    }

    private var detail: some View {
        GeometryReader { geometry in
            let stacked = geometry.size.width < 980

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    tokenHeader

                    if liveToken.isDemo {
                        demoNotice
                    }

                    if stacked {
                        VStack(spacing: 0) {
                            marketWorkspace
                            Divider()
                            inspector
                        }
                    } else {
                        HStack(alignment: .top, spacing: 0) {
                            marketWorkspace
                                .frame(maxWidth: .infinity)
                            Divider()
                            inspector
                                .frame(width: 312)
                        }
                    }
                }
            }
        }
        .background(PowderPalette.workspace(colorScheme))
        .onAppear {
            model.setDetailToken(token.id, isPinned: true)
        }
        .onDisappear {
            model.setDetailToken(token.id, isPinned: false)
        }
        .task(id: "\(token.id)|\(timeframe.rawValue)") {
            chartIsLoading = true
            detailStreamState = model.dataMode == .live ? .connecting : .demo
            selectedPoint = nil
            chartProvenance = "Loading \(timeframe.resolutionLabel) price history…"
            let loadResult = await model.chart(
                for: liveToken,
                timeframe: timeframe
            )
            points = loadResult.points
            chartIsLoading = false

            switch loadResult.source {
            case .illustrative:
                chartProvenance = model.dataMode == .live
                    ? "Illustrative history · connecting live Codex \(timeframe.resolutionLabel) bars"
                    : "Illustrative \(timeframe.resolutionLabel) trace"
            case .codexSnapshot:
                chartProvenance = "Codex aggregate OHLCV · connecting live \(timeframe.resolutionLabel) bars"
            }

            guard let stream = model.liveTokenDetailStream(
                for: liveToken,
                timeframe: timeframe
            ) else {
                detailStreamState = .demo
                return
            }

            do {
                for try await event in stream {
                    switch event {
                    case .connected:
                        detailStreamState = .live
                    case let .bar(point):
                        merge(point)
                        lastDetailEventAt = Date()
                        detailStreamState = .live
                        chartProvenance = "Live \(timeframe.resolutionLabel) OHLCV · aggregated across Codex-indexed pools"
                        // A hot market can emit many updates for the open candle. The
                        // socket remains continuous, while the newest buffered value
                        // is committed at the same stable cadence as the launch board.
                        try await Task.sleep(for: .seconds(3))
                    case let .holders(count):
                        liveHolders = count
                        lastDetailEventAt = Date()
                        detailStreamState = .live
                    }
                }
                detailStreamState = .snapshot
                chartProvenance += " · stream ended"
            } catch is CancellationError {
                return
            } catch {
                detailStreamState = .snapshot
                chartProvenance += " · live stream unavailable"
            }
        }
    }

    private var tokenHeader: some View {
        HStack(alignment: .top, spacing: 16) {
            TokenMark(token: liveToken, size: 54)

            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline, spacing: 9) {
                    Text(liveToken.symbol)
                        .font(.largeTitle.weight(.semibold))
                    Text(liveToken.name)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    RealtimeStatusBadge(state: model.realtimeState)
                }

                HStack(spacing: 7) {
                    Text(liveToken.launchpadName)
                    Text("·")
                    Label("Solana", systemImage: "circle.hexagongrid")
                    Text("·")
                    Text(liveToken.shortAddress)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 5) {
                MonospacedValue(
                    text: PowderFormat.currency(displayedPrice, precise: true),
                    weight: .semibold
                )
                .font(.title2)

                HStack(spacing: 9) {
                    Text("1h")
                        .foregroundStyle(.secondary)
                    Text(PowderFormat.percent(liveToken.change1h))
                        .foregroundStyle(PowderPalette.market(liveToken.change1h))
                }
                .font(.system(.callout, design: .monospaced, weight: .semibold))
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 22)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var demoNotice: some View {
        Label(
            "Illustrative token and market values — connect Codex in Settings for live data.",
            systemImage: "testtube.2"
        )
        .font(.callout)
        .foregroundStyle(PowderPalette.cautionAmber)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 28)
        .padding(.vertical, 9)
        .background(PowderPalette.cautionAmber.opacity(0.08))
        .overlay(alignment: .bottom) { Divider() }
    }

    private var marketWorkspace: some View {
        VStack(alignment: .leading, spacing: 26) {
            priceInstrument
            marketReadouts
            tokenDescription
        }
        .padding(28)
    }

    private var priceInstrument: some View {
        VStack(alignment: .leading, spacing: 14) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 18) {
                    chartTitle
                    Spacer(minLength: 20)
                    chartControls
                }

                VStack(alignment: .leading, spacing: 12) {
                    chartTitle
                    chartControls
                }
            }

            VStack(spacing: 0) {
                chartReadout
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)

                Divider()

                ZStack {
                    if chartIsLoading {
                        ProgressView("Loading Codex bars…")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if filteredPoints.isEmpty {
                        ContentUnavailableView(
                            "No price bars",
                            systemImage: "chart.xyaxis.line",
                            description: Text("Codex has not returned price history for this token.")
                        )
                    } else {
                        DetailedPriceChart(
                            points: filteredPoints,
                            style: chartStyle,
                            timeframe: timeframe,
                            selection: selectedPoint,
                            selectedPoint: $selectedPoint
                        )
                        .equatable()
                    }
                }
                .frame(height: 440)
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
            }
            .background(
                PowderPalette.surface(colorScheme),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
        }
    }

    private var chartTitle: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("Aggregate price instrument")
                    .font(.headline)
                DetailStreamBadge(state: detailStreamState)
            }

            Text(chartProvenance)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var chartControls: some View {
        HStack(spacing: 10) {
            HStack(spacing: 2) {
                ForEach(PriceChartStyle.allCases) { style in
                    InstrumentSegment(
                        title: style.label,
                        systemImage: style.systemImage,
                        isSelected: chartStyle == style,
                        minimumWidth: 34
                    ) {
                        chartStyle = style
                    }
                }
            }
            .padding(3)
            .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Chart style")

            HStack(spacing: 2) {
                ForEach(ChartTimeframe.allCases) { option in
                    InstrumentSegment(
                        title: option.label,
                        isSelected: timeframe == option,
                        minimumWidth: 44
                    ) {
                        timeframe = option
                    }
                }
            }
            .padding(3)
            .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Chart timeframe")
        }
    }

    private var chartReadout: some View {
        let focus = selectedPoint ?? filteredPoints.last

        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 0) {
                CandleReadout(
                    label: selectedPoint == nil ? "LATEST" : "INSPECT",
                    value: focus.map {
                        $0.timestamp.formatted(date: .omitted, time: .shortened)
                    } ?? "—",
                    color: .secondary
                )
                readoutDivider
                CandleReadout(
                    label: "OPEN",
                    value: focus.map {
                        PowderFormat.currency($0.open, precise: true)
                    } ?? "—"
                )
                readoutDivider
                CandleReadout(
                    label: "HIGH",
                    value: focus.map {
                        PowderFormat.currency($0.high, precise: true)
                    } ?? "—",
                    color: PowderPalette.signalGreen
                )
                readoutDivider
                CandleReadout(
                    label: "LOW",
                    value: focus.map {
                        PowderFormat.currency($0.low, precise: true)
                    } ?? "—",
                    color: PowderPalette.riskCoral
                )
                readoutDivider
                CandleReadout(
                    label: "CLOSE",
                    value: focus.map {
                        PowderFormat.currency($0.close, precise: true)
                    } ?? "—"
                )
                readoutDivider
                CandleReadout(
                    label: "CHANGE",
                    value: focus.map {
                        PowderFormat.percent($0.change)
                    } ?? "—",
                    color: PowderPalette.market(focus?.change ?? 0)
                )
                readoutDivider
                CandleReadout(
                    label: "VOLUME",
                    value: focus.map {
                        PowderFormat.currency($0.volume)
                    } ?? "—"
                )
            }

            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(selectedPoint == nil ? "Latest candle" : "Inspected candle")
                        .font(.caption.weight(.semibold))
                    Text(focus?.timestamp.formatted() ?? "No candle selected")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(focus.map { PowderFormat.currency($0.close, precise: true) } ?? "—")
                    .font(.system(.callout, design: .monospaced, weight: .semibold))
            }
        }
    }

    private var readoutDivider: some View {
        Divider()
            .frame(height: 30)
            .padding(.horizontal, 10)
    }

    private var marketReadouts: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Live market readouts")
                    .font(.headline)
                Spacer()
                if let lastDetailEventAt {
                    Text("Updated \(lastDetailEventAt, style: .relative)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Grid(alignment: .leading, horizontalSpacing: 26, verticalSpacing: 0) {
                GridRow {
                    MetricCell(label: "Market cap", value: PowderFormat.currency(liveToken.marketCapUSD))
                    Divider()
                    MetricCell(label: "Liquidity", value: PowderFormat.currency(displayedLiquidity))
                    Divider()
                    MetricCell(label: "24h volume", value: PowderFormat.currency(liveToken.volume24h))
                }
                Divider()
                    .gridCellColumns(5)
                GridRow {
                    MetricCell(label: "Holders", value: displayedHolders.formatted())
                    Divider()
                    MetricCell(label: "24h transactions", value: liveToken.transactionCount24h.formatted())
                    Divider()
                    MetricCell(
                        label: "Buy / sell",
                        value: "\(PowderFormat.count(liveToken.buyCount24h)) / \(PowderFormat.count(liveToken.sellCount24h))"
                    )
                }
                Divider()
                    .gridCellColumns(5)
                GridRow {
                    MetricCell(
                        label: "5m change",
                        value: PowderFormat.percent(liveToken.change5m),
                        color: PowderPalette.market(liveToken.change5m)
                    )
                    Divider()
                    MetricCell(
                        label: "1h change",
                        value: PowderFormat.percent(liveToken.change1h),
                        color: PowderPalette.market(liveToken.change1h)
                    )
                    Divider()
                    MetricCell(
                        label: "24h change",
                        value: PowderFormat.percent(liveToken.change24h),
                        color: PowderPalette.market(liveToken.change24h)
                    )
                }
            }
            .padding(.horizontal, 2)
            .background(PowderPalette.surface(colorScheme), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    @ViewBuilder
    private var tokenDescription: some View {
        if let description = liveToken.description, !description.isEmpty {
            VStack(alignment: .leading, spacing: 9) {
                Text("About")
                    .font(.headline)
                Text(description)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: 720, alignment: .leading)
            }
        }
    }

    private var inspector: some View {
        VStack(alignment: .leading, spacing: 0) {
            lifecycleInspector
                .padding(22)

            Divider()

            riskInspector
                .padding(22)

            Divider()

            tradeSetup
                .padding(22)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PowderPalette.inspector(colorScheme))
    }

    private var lifecycleInspector: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Launch lifecycle", systemImage: "point.3.filled.connected.trianglepath.dotted")
                .font(.headline)

            HStack {
                Text(liveToken.lifecycleLabel)
                    .font(.callout.weight(.semibold))
                Spacer()
                MonospacedValue(text: PowderFormat.wholePercent(liveToken.graduationPercent))
            }

            ProgressView(value: liveToken.graduationPercent, total: 100)
                .tint(liveToken.migrated ? PowderPalette.signalGreen : PowderPalette.scopeBlue)

            HStack {
                Label(PowderFormat.age(since: liveToken.createdAt), systemImage: "clock")
                Spacer()
                Text(liveToken.launchpadName)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var riskInspector: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Signal check", systemImage: "shield.lefthalf.filled")
                    .font(.headline)
                Spacer()
                Text(liveToken.riskLevel.rawValue)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(PowderPalette.risk(liveToken.riskLevel))
            }

            RiskSignalRow(
                label: "Top 10",
                value: liveToken.topTenHeldPercent,
                watchThreshold: 40,
                elevatedThreshold: 65
            )
            RiskSignalRow(
                label: "Suspicious",
                value: liveToken.suspiciousHeldPercent,
                watchThreshold: 8,
                elevatedThreshold: 20
            )
            RiskSignalRow(
                label: "Snipers",
                value: liveToken.sniperHeldPercent,
                watchThreshold: 8,
                elevatedThreshold: 20
            )
            RiskSignalRow(
                label: "Insiders",
                value: liveToken.insiderHeldPercent,
                watchThreshold: 8,
                elevatedThreshold: 20
            )
            RiskSignalRow(
                label: "Developer",
                value: liveToken.developerHeldPercent,
                watchThreshold: 7,
                elevatedThreshold: 15
            )

            Text("Signals are informational and derived from Codex wallet and concentration fields, not an endorsement.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var tradeSetup: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Trade setup", systemImage: "arrow.left.arrow.right")
                .font(.headline)

            Text("Wallet signing and execution are intentionally not included in this first slice.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button("Trading not configured") {}
                .buttonStyle(.borderedProminent)
                .disabled(true)
                .frame(maxWidth: .infinity)
        }
    }

    private func merge(_ point: PricePoint) {
        if let index = points.firstIndex(where: { $0.timestamp == point.timestamp }) {
            points[index] = point
        } else {
            points.append(point)
            points.sort { $0.timestamp < $1.timestamp }
        }

        if points.count > 256 {
            points.removeFirst(points.count - 256)
        }
    }

    private var filteredPoints: [PricePoint] {
        guard let last = points.last?.timestamp else { return points }
        let cutoff = last.addingTimeInterval(-timeframe.seconds)
        return points.filter { $0.timestamp >= cutoff }
    }
}

private struct InstrumentSegment: View {
    let title: String
    var systemImage: String?
    let isSelected: Bool
    let minimumWidth: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if let systemImage {
                    Image(systemName: systemImage)
                } else {
                    Text(title)
                }
            }
            .font(.caption.weight(.semibold))
            .frame(minWidth: minimumWidth, minHeight: 23)
            .foregroundStyle(isSelected ? PowderPalette.scopeBlue : .secondary)
            .background(
                isSelected ? PowderPalette.scopeBlue.opacity(0.14) : .clear,
                in: RoundedRectangle(cornerRadius: 5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct MetricCell: View {
    let label: String
    let value: String
    var color: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            MonospacedValue(text: value, color: color)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

private struct RiskSignalRow: View {
    let label: String
    let value: Double
    let watchThreshold: Double
    let elevatedThreshold: Double

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            ProgressView(value: min(max(value, 0), 100), total: 100)
                .progressViewStyle(.linear)
                .tint(color)
                .frame(width: 86)
            Text(String(format: "%.1f%%", value))
                .font(.system(.caption, design: .monospaced, weight: .medium))
                .frame(width: 48, alignment: .trailing)
        }
        .font(.caption)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label), \(String(format: "%.1f percent", value))")
    }

    private var color: Color {
        if value >= elevatedThreshold { return PowderPalette.riskCoral }
        if value >= watchThreshold { return PowderPalette.cautionAmber }
        return PowderPalette.signalGreen
    }
}
