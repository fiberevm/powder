import SwiftUI

// MARK: - Model

enum MarketColumn: String, CaseIterable, Identifiable {
    case rank, ticker, last, change, changeAbs, mark, oracle, premium, funding, fundingAPR, openInterest, volume, leverage

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rank: "#"
        case .ticker: "TICKER"
        case .last: "LAST"
        case .change: "CHG %"
        case .changeAbs: "CHG"
        case .mark: "MARK"
        case .oracle: "ORACLE"
        case .premium: "PREM BP"
        case .funding: "FUND 1H"
        case .fundingAPR: "FUND APR"
        case .openInterest: "OPEN INT $"
        case .volume: "VOL 24H $"
        case .leverage: "LEV"
        }
    }

    var width: CGFloat {
        switch self {
        case .rank: 38
        case .ticker: 92
        case .leverage: 48
        case .premium: 76
        case .change, .fundingAPR: 84
        case .funding: 92
        default: 104
        }
    }

    /// Columns go in this order as the pane narrows; the unlisted ones always stay.
    static let dropOrder: [MarketColumn] = [.oracle, .changeAbs, .mark, .fundingAPR, .premium, .leverage, .openInterest]

    var isSortable: Bool { self != .rank }
}

/// One market with its live price folded in.
struct MarketQuote: Identifiable, Equatable {
    let market: HLMarket
    let price: Double

    var id: String { market.name }
    var change: Double { market.ctx.prevDayPx > 0 ? price / market.ctx.prevDayPx - 1 : 0 }
    var changeAbs: Double { price - market.ctx.prevDayPx }
    /// Mark over oracle, in basis points.
    var premium: Double { market.ctx.oraclePx > 0 ? (market.ctx.markPx / market.ctx.oraclePx - 1) * 10_000 : 0 }
    var fundingAPR: Double { market.ctx.funding * 24 * 365 }
    var openInterestUSD: Double { market.ctx.openInterest * market.ctx.markPx }

    func value(_ column: MarketColumn) -> Double {
        switch column {
        case .rank, .ticker: 0
        case .last: price
        case .change: change
        case .changeAbs: changeAbs
        case .mark: market.ctx.markPx
        case .oracle: market.ctx.oraclePx
        case .premium: premium
        case .funding, .fundingAPR: market.ctx.funding
        case .openInterest: openInterestUSD
        case .volume: market.ctx.dayNtlVlm
        case .leverage: Double(market.maxLeverage)
        }
    }
}

/// Sort, filter and selection for one Markets tab.
@MainActor
final class MarketsModel: ObservableObject {
    @Published private(set) var sort: MarketColumn = .volume
    @Published private(set) var ascending = false
    @Published private(set) var selection: String?
    @Published var filter = ""

    func quotes(in directory: MarketDirectory) -> [MarketQuote] {
        let query = filter.trimmingCharacters(in: .whitespaces).uppercased()
        let quotes = directory.markets.values
            .filter { query.isEmpty || $0.name.uppercased().contains(query) }
            .map { MarketQuote(market: $0, price: directory.mids[$0.name] ?? $0.ctx.midPx ?? $0.ctx.markPx) }
        return quotes.sorted { a, b in
            if sort == .ticker { return ascending ? a.market.name < b.market.name : a.market.name > b.market.name }
            let x = a.value(sort), y = b.value(sort)
            if x == y { return a.market.name < b.market.name }
            return ascending ? x < y : x > y
        }
    }

    /// Clicking the sorted column flips it; a new column starts descending (tickers ascending).
    func sort(by column: MarketColumn) {
        guard column.isSortable else { return }
        if sort == column {
            ascending.toggle()
        } else {
            sort = column
            ascending = column == .ticker
        }
    }

    func stepSort(_ delta: Int) {
        let columns = MarketColumn.allCases.filter(\.isSortable)
        guard let index = columns.firstIndex(of: sort) else { return }
        sort(by: columns[(index + delta + columns.count) % columns.count])
    }

    func reverseSort() {
        ascending.toggle()
    }

    func select(_ coin: String?) {
        selection = coin
    }

    func move(_ delta: Int, in directory: MarketDirectory) {
        let names = quotes(in: directory).map(\.market.name)
        guard !names.isEmpty else { return }
        let current = selection.flatMap { names.firstIndex(of: $0) }
        let next = current.map { min(max($0 + delta, 0), names.count - 1) } ?? (delta > 0 ? 0 : names.count - 1)
        selection = names[next]
    }
}

// MARK: - View

/// Every Hyperliquid perp in one dense, live table, styled after a market data terminal:
/// theme background, gold labels, reverse-video selection, cells that flash as prices tick.
struct MarketsView: View {
    @ObservedObject var model: MarketsModel
    @ObservedObject var directory: MarketDirectory
    let onOpen: (String) -> Void

    // The shared theme colours, so this tab matches the chart tabs in both themes.
    static let field = Term.background
    static let text = Term.foreground
    static let dim = Color.secondary
    private static let band = Term.chrome
    private static let rowHeight: CGFloat = 20

    @FocusState private var isFilterFocused: Bool

    var body: some View {
        let quotes = model.quotes(in: directory)

        GeometryReader { geometry in
            let columns = Self.columns(fitting: geometry.size.width)

            VStack(spacing: 0) {
                commandLine(count: quotes.count)
                summary
                header(columns)

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(quotes.enumerated()), id: \.element.id) { index, quote in
                                MarketRow(
                                    rank: index + 1,
                                    quote: quote,
                                    columns: columns,
                                    isSelected: quote.id == model.selection
                                )
                                .equatable()
                                .id(quote.id)
                                // One handler for both: a separate double-click gesture makes SwiftUI
                                // hold every single click until the double-click time has passed.
                                .onTapGesture {
                                    model.select(quote.id)
                                    if NSApp.currentEvent?.clickCount == 2 { onOpen(quote.id) }
                                }
                            }
                        }
                    }
                    .onChange(of: model.selection) { _, selection in
                        if let selection { proxy.scrollTo(selection) }
                    }
                }

                footer
            }
        }
        .font(Term.font(11.5))
        .foregroundStyle(Self.text)
        .background(Self.field)
        .onAppear { directory.watch(true) }
        .onDisappear { directory.watch(false) }
    }

    private static func columns(fitting width: CGFloat) -> [MarketColumn] {
        var columns = MarketColumn.allCases
        for column in MarketColumn.dropOrder where columns.reduce(0, { $0 + $1.width }) + 24 > width {
            columns.removeAll { $0 == column }
        }
        return columns
    }

    /// The terminal's command line: function name, filter, clock.
    private func commandLine(count: Int) -> some View {
        HStack(spacing: 10) {
            Text("HYPERLIQUID PERPS")
                .font(Term.font(11.5, .bold))
                .foregroundStyle(Self.field)
                .padding(.horizontal, 7)
                .frame(height: 18)
                .background(Term.accent)
            Text("<GO>")
                .foregroundStyle(Term.accent)
            TextField("filter ticker", text: $model.filter)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .focused($isFilterFocused)
                .frame(width: 140)
            Spacer(minLength: 0)
            Text("\(count) MKTS")
                .foregroundStyle(Self.dim)
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                Text(timeline.date.formatted(
                    .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits).locale(HLFormat.clock24)
                ))
                .foregroundStyle(Term.accent)
            }
        }
        .lineLimit(1)
        .padding(.horizontal, 10)
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 26, maxHeight: 26, alignment: .leading)
        .background(Self.band)
        .clipped()
    }

    /// Whole-exchange totals.
    private var summary: some View {
        let all = directory.markets.values.map {
            MarketQuote(market: $0, price: directory.mids[$0.name] ?? $0.ctx.midPx ?? $0.ctx.markPx)
        }
        let volume = all.reduce(0) { $0 + $1.market.ctx.dayNtlVlm }
        let interest = all.reduce(0) { $0 + $1.openInterestUSD }
        let advancers = all.filter { $0.change > 0 }.count
        let decliners = all.filter { $0.change < 0 }.count
        let best = all.max { $0.change < $1.change }
        let worst = all.min { $0.change < $1.change }
        let weightedFunding = interest > 0 ? all.reduce(0) { $0 + $1.market.ctx.funding * $1.openInterestUSD } / interest : 0

        return HStack(spacing: 18) {
            stat("VOL 24H", "$" + HLFormat.compact(volume))
            stat("OPEN INT", "$" + HLFormat.compact(interest))
            stat("ADV", "\(advancers)", PowderPalette.signalGreen)
            stat("DEC", "\(decliners)", PowderPalette.riskCoral)
            stat("OI-WTD FUND", String(format: "%+.4f%%", weightedFunding * 100), PowderPalette.market(weightedFunding))
            if let best { stat("TOP", "\(best.id) \(HLFormat.percent(best.change))", PowderPalette.signalGreen) }
            if let worst { stat("BTM", "\(worst.id) \(HLFormat.percent(worst.change))", PowderPalette.riskCoral) }
            Spacer(minLength: 0)
        }
        .lineLimit(1)
        .padding(.horizontal, 10)
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 24, maxHeight: 24, alignment: .leading)
        .clipped()
        .overlay(alignment: .bottom) { TermRule() }
    }

    private func stat(_ label: String, _ value: String, _ color: Color = MarketsView.text) -> some View {
        HStack(spacing: 6) {
            Text(label).foregroundStyle(Term.accent)
            Text(value).foregroundStyle(color)
        }
        .fixedSize()
    }

    private func header(_ columns: [MarketColumn]) -> some View {
        HStack(spacing: 0) {
            ForEach(columns) { column in
                let isSorted = model.sort == column
                Text(column.title + (isSorted ? (model.ascending ? " ▲" : " ▼") : ""))
                    .font(Term.font(10.5, isSorted ? .bold : .regular))
                    .foregroundStyle(isSorted ? Self.field : Term.accent)
                    .padding(.horizontal, 6)
                    .frame(width: column.width, height: Self.rowHeight, alignment: column == .ticker ? .leading : .trailing)
                    .background(isSorted ? Term.accent : .clear)
                    .contentShape(Rectangle())
                    .onTapGesture { model.sort(by: column) }
            }
            Spacer(minLength: 0)
        }
        .lineLimit(1)
        .background(Self.band)
    }

    private var footer: some View {
        HStack(spacing: 16) {
            hint("↑↓", "SELECT")
            hint("⏎", "OPEN")
            hint("←→", "SORT COLUMN")
            hint("R", "REVERSE")
            hint("⌘P", "GO TO")
            Spacer(minLength: 0)
            Text("PRICES STREAM · FUNDING, OI, VOL EVERY 3S")
                .foregroundStyle(Self.dim)
        }
        .font(Term.font(10.5))
        .lineLimit(1)
        .padding(.horizontal, 10)
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 22, maxHeight: 22, alignment: .leading)
        .background(Self.band)
        .clipped()
    }

    private func hint(_ key: String, _ action: String) -> some View {
        HStack(spacing: 5) {
            Text(key).foregroundStyle(Term.accent)
            Text(action).foregroundStyle(Self.dim)
        }
        .fixedSize()
    }
}

private struct MarketRow: View, Equatable {
    let rank: Int
    let quote: MarketQuote
    let columns: [MarketColumn]
    let isSelected: Bool

    @State private var flashColor = Color.clear
    @State private var flashOpacity = 0.0

    nonisolated static func == (lhs: MarketRow, rhs: MarketRow) -> Bool {
        lhs.rank == rhs.rank && lhs.quote == rhs.quote && lhs.columns == rhs.columns && lhs.isSelected == rhs.isSelected
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(columns) { column in
                cell(column)
                    .padding(.horizontal, 6)
                    .frame(width: column.width, alignment: column == .ticker ? .leading : .trailing)
                    .frame(maxHeight: .infinity)
                    .background(column == .last ? flashColor.opacity(flashOpacity) : .clear)
            }
            Spacer(minLength: 0)
        }
        .lineLimit(1)
        .frame(height: 20)
        .background(isSelected ? Term.accent : (rank.isMultiple(of: 2) ? Color.primary.opacity(0.035) : .clear))
        .contentShape(Rectangle())
        .onChange(of: quote.price) { old, new in
            guard new != old else { return }
            flashColor = new > old ? PowderPalette.signalGreen : PowderPalette.riskCoral
            flashOpacity = 0.5
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(60))
                withAnimation(.easeOut(duration: 0.7)) { flashOpacity = 0 }
            }
        }
    }

    @ViewBuilder
    private func cell(_ column: MarketColumn) -> some View {
        let ctx = quote.market.ctx
        let decimals = HLFormat.priceDecimals(for: quote.price, szDecimals: quote.market.szDecimals)
        switch column {
        case .rank:
            plain("\(rank)", MarketsView.dim)
        case .ticker:
            Text(quote.id)
                .fontWeight(.bold)
                .foregroundStyle(isSelected ? MarketsView.field : Term.accent)
        case .last:
            plain(HLFormat.price(quote.price, decimals: decimals), MarketsView.text, weight: .semibold)
        case .change:
            plain(HLFormat.percent(quote.change), PowderPalette.market(quote.change))
        case .changeAbs:
            plain((quote.changeAbs >= 0 ? "+" : "−") + HLFormat.price(abs(quote.changeAbs), decimals: decimals), PowderPalette.market(quote.changeAbs))
        case .mark:
            plain(HLFormat.price(ctx.markPx, decimals: decimals), MarketsView.text)
        case .oracle:
            plain(HLFormat.price(ctx.oraclePx, decimals: decimals), MarketsView.dim)
        case .premium:
            plain(String(format: "%+.1f", quote.premium), PowderPalette.market(quote.premium))
        case .funding:
            plain(String(format: "%+.4f%%", ctx.funding * 100), PowderPalette.market(ctx.funding))
        case .fundingAPR:
            plain(String(format: "%+.1f%%", quote.fundingAPR * 100), PowderPalette.market(ctx.funding))
        case .openInterest:
            plain(HLFormat.compact(quote.openInterestUSD), MarketsView.text)
        case .volume:
            plain(HLFormat.compact(ctx.dayNtlVlm), MarketsView.text)
        case .leverage:
            plain("\(quote.market.maxLeverage)x", MarketsView.dim)
        }
    }

    /// On the selected row everything is reverse video: dark text on the gold bar.
    private func plain(_ string: String, _ color: Color, weight: Font.Weight = .regular) -> some View {
        Text(string)
            .fontWeight(weight)
            .foregroundStyle(isSelected ? MarketsView.field : color)
    }
}
