import SwiftUI

// MARK: - Model

/// One executed trade: a Hyperliquid fill or a Solana swap.
struct TradeRecord: Identifiable, Equatable, Sendable {
    enum Venue: String, Sendable { case perp = "PERP", spot = "SPOT", solana = "SOLANA" }

    let id: String
    let walletID: UUID
    var walletName: String
    let venue: Venue
    let market: String
    /// "Open Long", "Close Short", "Buy", "Sell".
    let side: String
    let isBuy: Bool
    let price: Double
    let size: Double
    /// Dollars traded.
    let value: Double
    let fee: Double?
    /// Realized PnL, on fills that closed something.
    let pnl: Double?
    /// Milliseconds since epoch.
    let time: Int64
    var solana: SolanaToken?
}

extension HyperliquidExchange {
    /// The account's latest fills (the exchange returns up to 2,000), newest first.
    static func fills(user: String, walletID: UUID, walletName: String) async throws -> [TradeRecord] {
        let data = try await post("info", body: #"{"type":"userFills","user":"\#(user)"}"#)
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        func number(_ value: Any?) -> Double { (value as? String).flatMap(Double.init) ?? (value as? NSNumber)?.doubleValue ?? 0 }
        return rows.compactMap { row in
            guard let coin = row["coin"] as? String, let time = (row["time"] as? NSNumber)?.int64Value else { return nil }
            let price = number(row["px"]), size = number(row["sz"])
            guard price > 0, size > 0 else { return nil }
            // Spot fills are named by pair ("PURR/USDC") or index ("@107"); perps by coin.
            let isSpot = coin.contains("/") || coin.hasPrefix("@")
            let isBuy = row["side"] as? String == "B"
            let direction = row["dir"] as? String ?? (isBuy ? "Buy" : "Sell")
            let pnl = number(row["closedPnl"])
            return TradeRecord(
                id: "hl|\(walletID)|\(row["tid"] ?? row["hash"] ?? time)|\(row["oid"] ?? 0)", walletID: walletID, walletName: walletName,
                venue: isSpot ? .spot : .perp, market: coin, side: direction, isBuy: isBuy,
                price: price, size: size, value: price * size,
                // Fees paid in another token are not dollars, so they are left out of the total.
                fee: (row["feeToken"] as? String ?? "USDC") == "USDC" ? number(row["fee"]) : nil,
                pnl: direction.lowercased().contains("open") || pnl == 0 ? nil : pnl, time: time
            )
        }
    }
}

extension SolanaAPI {
    /// A wallet's latest swaps (up to 200), each read as a buy or sell of the token that is not SOL or a stablecoin.
    static func history(maker: String, walletID: UUID, walletName: String) async throws -> [TradeRecord] {
        let events = try await makerEvents(maker: maker)
        var mints = Set<String>()
        for event in events {
            if let a = event["token0Address"] as? String { mints.insert(a) }
            if let b = event["token1Address"] as? String { mints.insert(b) }
        }
        var known: [String: SolanaStats] = [:]
        for stat in (try? await stats(addresses: Array(mints.sorted().prefix(200)))) ?? [] { known[stat.token.address] = stat }

        func isMoney(_ mint: String) -> Bool { mint == SolanaRPC.wrappedSOL || SolanaTokens.stablecoins.contains(mint) }
        return events.enumerated().compactMap { index, event in
            guard let a = event["token0Address"] as? String, let b = event["token1Address"] as? String else { return nil }
            // The traded token is the one that is not money; between two tokens (or SOL and a stablecoin), the first.
            let mint = isMoney(a) && !isMoney(b) ? b : a
            guard let stat = known[mint], let decimals = stat.decimals,
                  let own = trade(in: event, mint: mint, decimals: decimals) else { return nil }
            let size = abs(own.amount)
            return TradeRecord(
                id: "sol|\(walletID)|\(event["transactionHash"] ?? "")|\(index)", walletID: walletID, walletName: walletName,
                venue: .solana, market: stat.token.symbol, side: own.amount > 0 ? "Buy" : "Sell", isBuy: own.amount > 0,
                price: own.usd / size, size: size, value: own.usd, fee: nil, pnl: nil,
                time: Int64(own.time) * 1_000, solana: stat.token
            )
        }
    }
}

/// Every wallet's executed trades, newest first, and the totals over them.
@MainActor
final class HistoryModel: ObservableObject {
    @Published private(set) var records: [TradeRecord] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var loadedAt: Date?
    @Published private(set) var selection: String?

    /// Dollars traded since `seconds` ago, or over everything loaded.
    func volume(last seconds: TimeInterval? = nil, venue: TradeRecord.Venue? = nil) -> Double {
        let cutoff = seconds.map { Int64((Date().timeIntervalSince1970 - $0) * 1_000) } ?? 0
        return records.reduce(0) { $0 + ($1.time >= cutoff && (venue == nil || $1.venue == venue) ? $1.value : 0) }
    }

    var fees: Double { records.reduce(0) { $0 + ($1.fee ?? 0) } }
    var realized: Double { records.reduce(0) { $0 + ($1.pnl ?? 0) } }

    func select(_ id: String?) { selection = id }

    func move(_ delta: Int) {
        guard !records.isEmpty else { return }
        let current = selection.flatMap { id in records.firstIndex { $0.id == id } }
        let next = current.map { min(max($0 + delta, 0), records.count - 1) } ?? (delta > 0 ? 0 : records.count - 1)
        selection = records[next].id
    }

    var selected: TradeRecord? { records.first { $0.id == selection } }

    func load(wallets: WalletProvider) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        let hyperliquid = wallets.wallets.map { ($0.id, $0.name, $0.tradingAddress) }
        let solana = SolanaAPI.hasKey ? wallets.solana.wallets.map { ($0.id, $0.name, $0.address) } : []
        var all: [TradeRecord] = []
        var failure: String?
        await withTaskGroup(of: Result<[TradeRecord], Error>.self) { group in
            for (id, name, address) in hyperliquid {
                group.addTask {
                    do { return .success(try await HyperliquidExchange.fills(user: address, walletID: id, walletName: name)) } catch { return .failure(error) }
                }
            }
            for (id, name, address) in solana {
                group.addTask {
                    do { return .success(try await SolanaAPI.history(maker: address, walletID: id, walletName: name)) } catch { return .failure(error) }
                }
            }
            for await result in group {
                switch result {
                case let .success(records): all += records
                case let .failure(error): failure = error.localizedDescription
                }
            }
        }
        // A failed reload keeps what was already showing.
        if failure == nil || !all.isEmpty || records.isEmpty {
            records = all.sorted { $0.time != $1.time ? $0.time > $1.time : $0.id < $1.id }
        }
        errorMessage = failure
        loadedAt = Date()
    }
}

// MARK: - View

enum HistoryColumn: String, CaseIterable, Identifiable {
    case time, wallet, venue, market, side, price, size, value, fee, pnl

    var id: String { rawValue }

    var title: String {
        switch self {
        case .time: "TIME"
        case .wallet: "WALLET"
        case .venue: "TYPE"
        case .market: "MARKET"
        case .side: "SIDE"
        case .price: "PRICE"
        case .size: "SIZE"
        case .value: "VALUE $"
        case .fee: "FEE $"
        case .pnl: "PNL $"
        }
    }

    var width: CGFloat {
        switch self {
        case .time: 128
        case .wallet: 110
        case .venue: 62
        case .market: 84
        case .side: 96
        case .fee: 76
        default: 100
        }
    }

    var isText: Bool { self == .time || self == .wallet || self == .venue || self == .market || self == .side }

    /// Columns go in this order as the pane narrows.
    static let dropOrder: [HistoryColumn] = [.fee, .wallet, .venue, .size, .pnl, .side]
}

/// Every wallet's executed trades in one table, in the Positions tab's style.
struct HistoryView: View {
    @ObservedObject var model: HistoryModel
    @ObservedObject var wallets: WalletProvider
    let onOpen: (TradeRecord) -> Void

    private static let rowHeight: CGFloat = 20
    private static let band = Term.chrome
    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM dd HH:mm:ss"
        return formatter
    }()

    var body: some View {
        GeometryReader { geometry in
            let columns = Self.columns(fitting: geometry.size.width)
            VStack(spacing: 0) {
                commandLine
                summary
                header(columns)
                if model.records.isEmpty {
                    empty
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(Array(model.records.enumerated()), id: \.element.id) { index, record in
                                    line(record, index: index, columns: columns)
                                        .id(record.id)
                                        .onTapGesture {
                                            model.select(record.id)
                                            if NSApp.currentEvent?.clickCount == 2 { onOpen(record) }
                                        }
                                }
                            }
                        }
                        .onChange(of: model.selection) { _, selection in
                            if let selection { proxy.scrollTo(selection) }
                        }
                    }
                }
                footer
            }
        }
        .font(Term.font(11.5))
        .foregroundStyle(MarketsView.text)
        .background(MarketsView.field)
        .task(id: wallets.wallets.map(\.id)) {
            // Reloaded every half minute while the tab is showing.
            while !Task.isCancelled {
                await model.load(wallets: wallets)
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    private static func columns(fitting width: CGFloat) -> [HistoryColumn] {
        var columns = HistoryColumn.allCases
        for column in HistoryColumn.dropOrder where columns.reduce(0, { $0 + $1.width }) + 24 > width {
            columns.removeAll { $0 == column }
        }
        return columns
    }

    private var commandLine: some View {
        HStack(spacing: 10) {
            Text("HISTORY")
                .font(Term.font(11.5, .bold))
                .foregroundStyle(MarketsView.field)
                .padding(.horizontal, 6)
                .frame(height: 16)
                .background(Term.accent)
            Text("<GO>").foregroundStyle(Term.accent)
            Text("\(wallets.wallets.count) WALLET\(wallets.wallets.count == 1 ? "" : "S")").foregroundStyle(MarketsView.dim)
            Spacer(minLength: 0)
            Text("\(model.records.count) TRADES").foregroundStyle(MarketsView.dim)
        }
        .lineLimit(1)
        .padding(.horizontal, 10)
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 26, maxHeight: 26, alignment: .leading)
        .background(Self.band)
        .clipped()
    }

    private var summary: some View {
        HStack(spacing: 18) {
            stat("VOL 24H", "$" + HLFormat.compact(model.volume(last: 86_400)))
            stat("7D", "$" + HLFormat.compact(model.volume(last: 7 * 86_400)))
            stat("30D", "$" + HLFormat.compact(model.volume(last: 30 * 86_400)))
            stat("ALL", "$" + HLFormat.compact(model.volume()))
            stat("PERP", "$" + HLFormat.compact(model.volume(venue: .perp)))
            stat("SPOT", "$" + HLFormat.compact(model.volume(venue: .spot)))
            stat("SOLANA", "$" + HLFormat.compact(model.volume(venue: .solana)))
            stat("FEES", "$" + HLFormat.price(model.fees, decimals: 2))
            stat("REALIZED", PositionsView.signed(model.realized), PowderPalette.market(model.realized))
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

    private func header(_ columns: [HistoryColumn]) -> some View {
        HStack(spacing: 0) {
            ForEach(columns) { column in
                Text(column.title)
                    .font(Term.font(10.5))
                    .foregroundStyle(Term.accent)
                    .padding(.horizontal, 6)
                    .frame(width: column.width, height: Self.rowHeight, alignment: column.isText ? .leading : .trailing)
            }
            Spacer(minLength: 0)
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .background(Self.band)
        .clipped()
    }

    private func line(_ record: TradeRecord, index: Int, columns: [HistoryColumn]) -> some View {
        let isSelected = record.id == model.selection
        return HStack(spacing: 0) {
            ForEach(columns) { column in
                cell(column, record, isSelected: isSelected)
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .frame(width: column.width, height: Self.rowHeight, alignment: column.isText ? .leading : .trailing)
            }
            Spacer(minLength: 0)
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Term.accent : (index.isMultiple(of: 2) ? .clear : Color.primary.opacity(0.035)))
        .clipped()
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func cell(_ column: HistoryColumn, _ record: TradeRecord, isSelected: Bool) -> some View {
        let decimals = PositionLine.priceDecimals(record.price, isSolana: record.venue == .solana)
        let plain = { (text: String, color: Color, weight: Font.Weight) in
            Text(text).fontWeight(weight).foregroundStyle(isSelected ? MarketsView.field : color)
        }
        switch column {
        case .time: plain(Self.stamp.string(from: Date(timeIntervalSince1970: Double(record.time) / 1_000)), MarketsView.dim, .regular)
        case .wallet: plain(record.walletName, MarketsView.dim, .regular)
        case .venue: plain(record.venue.rawValue, MarketsView.dim, .regular)
        case .market: plain(record.market, Term.accent, .bold)
        case .side: plain(record.side.uppercased(), record.isBuy ? PowderPalette.signalGreen : PowderPalette.riskCoral, .semibold)
        case .price: plain(HLFormat.price(record.price, decimals: decimals), MarketsView.text, .regular)
        case .size: plain(record.size >= 100_000 ? HLFormat.compact(record.size) : HLFormat.size(record.size, decimals: 4), MarketsView.text, .regular)
        case .value: plain(HLFormat.price(record.value, decimals: 2), MarketsView.text, .semibold)
        case .fee: plain(record.fee.map { HLFormat.price($0, decimals: $0 < 0.01 ? 4 : 2) } ?? "—", MarketsView.dim, .regular)
        case .pnl: plain(record.pnl.map(PositionsView.signed) ?? "—", record.pnl.map(PowderPalette.market) ?? MarketsView.dim, .semibold)
        }
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.loadedAt == nil {
                Text("LOADING TRADES…").foregroundStyle(Term.accent)
            } else if wallets.wallets.isEmpty {
                Text("NO WALLETS YET. ADD ONE WITH ⌘, TO SEE ITS TRADES.").foregroundStyle(MarketsView.dim)
            } else {
                Text("NO TRADES YET IN \(wallets.wallets.count) WALLET\(wallets.wallets.count == 1 ? "" : "S").").foregroundStyle(MarketsView.dim)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(12)
    }

    private var footer: some View {
        HStack(spacing: 16) {
            if let error = model.errorMessage {
                Text(error.uppercased()).foregroundStyle(PowderPalette.riskCoral)
            } else {
                hint("↑↓", "SELECT")
                hint("O", "OPEN MARKET")
                hint("R", "RELOAD")
            }
            Spacer(minLength: 0)
            Text(model.isLoading ? "LOADING…" : "LATEST 2,000 FILLS PER WALLET · SOLANA: LATEST 200 SWAPS · EVERY 30S")
                .foregroundStyle(MarketsView.dim)
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
            Text(action).foregroundStyle(MarketsView.dim)
        }
        .fixedSize()
    }
}
