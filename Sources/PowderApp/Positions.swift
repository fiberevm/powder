import SwiftUI

// MARK: - Model

enum PositionColumn: String, CaseIterable, Identifiable {
    case wallet, kind, coin, side, size, entry, mark, value, pnl, pnlPercent, liquidation, leverage

    var id: String { rawValue }

    var title: String {
        switch self {
        case .wallet: "WALLET"
        case .kind: "TYPE"
        case .coin: "ASSET"
        case .side: "SIDE"
        case .size: "SIZE"
        case .entry: "ENTRY"
        case .mark: "LAST"
        case .value: "VALUE $"
        case .pnl: "PNL $"
        case .pnlPercent: "PNL %"
        case .liquidation: "LIQ"
        case .leverage: "LEV"
        }
    }

    var width: CGFloat {
        switch self {
        case .wallet: 120
        case .kind, .leverage: 52
        case .side: 58
        case .coin, .pnlPercent: 84
        default: 104
        }
    }

    var isText: Bool { self == .wallet || self == .kind || self == .coin || self == .side }

    /// Columns go in this order as the pane narrows.
    static let dropOrder: [PositionColumn] = [.leverage, .liquidation, .kind, .entry, .side, .wallet, .pnlPercent]
}

/// One holding: a perp position, a spot balance, or cash.
struct PositionRow: Identifiable, Equatable {
    enum Kind: String { case perp = "PERP", spot = "SPOT", cash = "CASH" }

    let id: String
    let walletID: UUID
    let walletName: String
    let kind: Kind
    let coin: String
    /// Signed for perps: negative is short.
    let size: Double
    let entry: Double?
    /// The live price.
    let mark: Double?
    let value: Double
    let pnl: Double?
    let pnlPercent: Double?
    let liquidation: Double?
    let leverage: Int?
    /// Spot token index, for selling it.
    var token: Int?
    /// For cash: which balance it is idle in.
    var venue: String?
    /// Set for a Solana holding: the token, for charting and selling it.
    var solana: SolanaToken?

    var solanaMint: String? { solana?.address }

    var side: String {
        switch kind {
        case .perp: size > 0 ? "LONG" : "SHORT"
        case .spot: "HOLD"
        case .cash: venue ?? "—"
        }
    }

    var isClosable: Bool { kind != .cash }

    func sortValue(_ column: PositionColumn) -> Double {
        switch column {
        case .size: abs(size)
        case .entry: entry ?? 0
        case .mark: mark ?? 0
        case .value: value
        case .pnl: pnl ?? 0
        case .pnlPercent: pnlPercent ?? 0
        case .liquidation: liquidation ?? 0
        case .leverage: Double(leverage ?? 0)
        default: 0
        }
    }

    func sortText(_ column: PositionColumn) -> String {
        switch column {
        case .wallet: walletName
        case .kind: kind.rawValue
        case .coin: coin
        case .side: side
        default: ""
        }
    }
}

/// Sort and selection for the Positions tab, and the two-press close.
@MainActor
final class PositionsModel: ObservableObject {
    @Published private(set) var sort: PositionColumn = .value
    @Published private(set) var ascending = false
    @Published private(set) var selection: String?
    /// The row whose close is armed: a second ⏎ sends it.
    @Published private(set) var armed: String?
    @Published var status: String?
    @Published var statusIsError = false
    @Published private(set) var isClosing = false

    private var disarm: Task<Void, Never>?

    /// Every wallet's holdings priced at the live mid, so PnL moves with each tick.
    func rows(wallets: WalletProvider, directory: MarketDirectory) -> [PositionRow] {
        var rows: [PositionRow] = []
        for wallet in wallets.wallets {
            guard let account = wallets.accounts[wallet.id] else { continue }
            for position in account.positions {
                let mark = directory.mids[position.coin] ?? directory.markets[position.coin]?.ctx.markPx
                let pnl = mark.map { ($0 - position.entryPrice) * position.size } ?? position.unrealizedPnl
                let cost = abs(position.size) * position.entryPrice
                rows.append(PositionRow(
                    id: "\(wallet.id)|perp|\(position.coin)", walletID: wallet.id, walletName: wallet.name,
                    kind: .perp, coin: position.coin, size: position.size, entry: position.entryPrice, mark: mark,
                    value: mark.map { abs(position.size) * $0 } ?? position.value,
                    pnl: pnl,
                    // Return on the margin put up, as the exchange shows it.
                    pnlPercent: cost > 0 ? pnl / cost * Double(max(position.leverage, 1)) : nil,
                    liquidation: position.liquidationPrice, leverage: position.leverage
                ))
            }
            // Idle cash is always listed: what is free in the perp balance, and USDC sitting in spot.
            func cash(_ venue: String, _ amount: Double) -> PositionRow {
                var row = PositionRow(
                    id: "\(wallet.id)|cash|\(venue)", walletID: wallet.id, walletName: wallet.name,
                    kind: .cash, coin: "USDC", size: amount, entry: nil, mark: nil,
                    value: amount, pnl: nil, pnlPercent: nil, liquidation: nil, leverage: nil
                )
                row.venue = venue
                return row
            }
            rows.append(cash("PERPS", account.withdrawable))
            if account.spotUSDC > 0 { rows.append(cash("SPOT", account.spotUSDC)) }
            for balance in account.spot where balance.total > 0 {
                if balance.token == 0 { continue }
                let mark = directory.spotPairs[balance.token].flatMap { directory.mids[$0.midKey] }
                let value = mark.map { $0 * balance.total }
                let pnl = value.flatMap { balance.entryNotional > 0 ? $0 - balance.entryNotional : nil }
                rows.append(PositionRow(
                    id: "\(wallet.id)|spot|\(balance.token)", walletID: wallet.id, walletName: wallet.name,
                    kind: .spot, coin: balance.coin, size: balance.total,
                    entry: balance.entryNotional > 0 ? balance.entryNotional / balance.total : nil, mark: mark,
                    value: value ?? balance.entryNotional, pnl: pnl,
                    pnlPercent: pnl.map { $0 / balance.entryNotional },
                    liquidation: nil, leverage: nil, token: balance.token
                ))
            }
        }
        rows += solanaRows(wallets.solana)
        return rows.sorted { a, b in
            if sort.isText {
                let x = a.sortText(sort), y = b.sortText(sort)
                if x != y { return ascending ? x < y : x > y }
            } else {
                let x = a.sortValue(sort), y = b.sortValue(sort)
                if x != y { return ascending ? x < y : x > y }
            }
            return a.id < b.id
        }
    }

    /// Solana wallets: SOL and stablecoins as cash with no PnL, every other token against what was paid for it.
    private func solanaRows(_ solana: SolanaWalletProvider) -> [PositionRow] {
        var rows: [PositionRow] = []
        for wallet in solana.wallets {
            guard let balances = solana.balances[wallet.id] else { continue }
            let sol = solana.solPrice
            var row = PositionRow(
                id: "\(wallet.id)|sol", walletID: wallet.id, walletName: wallet.name,
                kind: .cash, coin: "SOL", size: balances.sol, entry: nil, mark: sol,
                value: balances.sol * (sol ?? 0), pnl: nil, pnlPercent: nil, liquidation: nil, leverage: nil
            )
            row.venue = "SOLANA"
            row.solana = SolanaToken(address: SolanaRPC.wrappedSOL, symbol: "SOL", name: "Solana")
            rows.append(row)

            for holding in balances.holdings {
                // Tokens with no market are airdropped dust, and so is anything worth under a cent.
                guard let price = solana.prices[holding.mint], holding.amount * price.price >= 0.01 else { continue }
                let isCash = SolanaTokens.stablecoins.contains(holding.mint) || holding.mint == SolanaRPC.wrappedSOL
                let value = holding.amount * price.price
                let cost = isCash ? nil : solana.costs[SolanaWalletProvider.costKey(wallet.id, holding.mint)]
                let pnl = cost.map { (price.price - $0) * holding.amount }
                var row = PositionRow(
                    id: "\(wallet.id)|sol|\(holding.mint)", walletID: wallet.id, walletName: wallet.name,
                    kind: isCash ? .cash : .spot, coin: price.symbol, size: holding.amount, entry: cost, mark: price.price,
                    value: value, pnl: pnl, pnlPercent: cost.flatMap { $0 > 0 ? price.price / $0 - 1 : nil },
                    liquidation: nil, leverage: nil
                )
                row.venue = isCash ? "SOLANA" : nil
                row.solana = SolanaToken(address: holding.mint, symbol: price.symbol, name: price.name)
                rows.append(row)
            }
        }
        return rows
    }

    func sort(by column: PositionColumn) {
        if sort == column {
            ascending.toggle()
        } else {
            sort = column
            ascending = column.isText
        }
    }

    func stepSort(_ delta: Int) {
        let columns = PositionColumn.allCases
        guard let index = columns.firstIndex(of: sort) else { return }
        sort(by: columns[(index + delta + columns.count) % columns.count])
    }

    func reverseSort() {
        ascending.toggle()
    }

    func select(_ id: String?) {
        if id != selection { cancelClose() }
        selection = id
    }

    func move(_ delta: Int, in rows: [PositionRow]) {
        guard !rows.isEmpty else { return }
        let current = selection.flatMap { id in rows.firstIndex { $0.id == id } }
        let next = current.map { min(max($0 + delta, 0), rows.count - 1) } ?? (delta > 0 ? 0 : rows.count - 1)
        select(rows[next].id)
    }

    func cancelClose() {
        disarm?.cancel()
        armed = nil
    }

    /// First ⏎ arms the selected row for a few seconds; the second returns it to be closed.
    func pressEnter(in rows: [PositionRow]) -> PositionRow? {
        guard !isClosing, let row = rows.first(where: { $0.id == selection }) else { return nil }
        guard row.isClosable else {
            statusIsError = false
            status = row.solana == nil ? "IDLE CASH IS NOT A POSITION: NOTHING TO CLOSE" : "\(row.coin) IS CASH: NOTHING TO CLOSE"
            return nil
        }
        if armed == row.id {
            cancelClose()
            return row
        }
        armed = row.id
        status = nil
        disarm?.cancel()
        disarm = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.armed = nil
        }
        return nil
    }

    /// Moves a wallet's idle USDC between its perp and spot balances.
    func transfer(_ row: PositionRow, toPerp: Bool, wallets: WalletProvider) async {
        isClosing = true
        defer { isClosing = false }
        do {
            try await wallets.transferUSDC(row.size, toPerp: toPerp, walletID: row.walletID)
            OrderSound.done()
            statusIsError = false
            status = "MOVED $\(HLFormat.price((row.size * 100).rounded(.down) / 100, decimals: 2)) TO \(toPerp ? "PERPS" : "SPOT")"
        } catch {
            statusIsError = true
            status = "USDC: \(error.localizedDescription)"
        }
    }

    /// Closes a perp at market (reduce-only) or sells a spot balance for USDC.
    func close(_ row: PositionRow, wallets: WalletProvider, directory: MarketDirectory) async {
        isClosing = true
        defer { isClosing = false }
        do {
            let outcome = try await wallets.close(row, directory: directory)
            statusIsError = false
            OrderSound.done()
            if case let .filled(size, price) = outcome {
                let realized = row.entry.map { (price - $0) * size * (row.size < 0 ? -1 : 1) }
                let result = realized.map { ($0 >= 0 ? " · +$" : " · −$") + HLFormat.price(abs($0), decimals: 2) } ?? ""
                status = "CLOSED \(HLWire.number(size)) \(row.coin) @ \(HLWire.number(price))\(result)"
            } else {
                status = "CLOSE SENT FOR \(row.coin)"
            }
        } catch {
            statusIsError = true
            status = "\(row.coin): \(error.localizedDescription)"
        }
    }
}

// MARK: - View

/// Every wallet's positions in one live table, in the Markets tab's terminal style.
struct PositionsView: View {
    @ObservedObject var model: PositionsModel
    @ObservedObject var directory: MarketDirectory
    @ObservedObject var wallets: WalletProvider
    let onOpen: (PositionRow) -> Void
    let onClose: (PositionRow) -> Void

    @Environment(\.openSettings) private var openSettings

    /// The row whose options are showing.
    @State private var menuRow: String?
    @State private var menuPoint = CGPoint.zero

    private func closeMenu() {
        menuRow = nil
        DropdownCenter.dismiss = nil
    }

    /// What a click on a row offers.
    private func options(for row: PositionRow) -> [DropdownItem] {
        let amount = "$" + HLFormat.price((row.size * 100).rounded(.down) / 100, decimals: 2)
        if let token = row.solana, let wallet = wallets.solana.wallet(row.walletID) {
            var items = [DropdownItem("Open \(row.coin) chart", detail: "O") { closeMenu(); onOpen(row) }]
            if row.kind == .spot {
                items.append(DropdownItem("Sell all for SOL at market", detail: "⏎ ⏎") { closeMenu(); onClose(row) })
            }
            items.append(DropdownItem("Copy wallet address", detail: wallet.shortAddress, startsSection: true) {
                closeMenu()
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(wallet.address, forType: .string)
            })
            if row.kind == .spot {
                items.append(DropdownItem("Copy token address", detail: "\(token.address.prefix(4))…\(token.address.suffix(4))") {
                    closeMenu()
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(token.address, forType: .string)
                })
            }
            return items
        }
        switch row.kind {
        case .perp:
            return [
                DropdownItem("Open \(row.coin) market", detail: "O") { closeMenu(); onOpen(row) },
                DropdownItem("Close at market", detail: "⏎ ⏎") { closeMenu(); onClose(row) },
            ]
        case .spot:
            return [DropdownItem("Sell all for USDC at market", detail: "⏎ ⏎") { closeMenu(); onClose(row) }]
        case .cash:
            let toPerp = row.venue == "SPOT"
            return [
                DropdownItem(
                    toPerp ? "Move \(amount) to perps" : "Move \(amount) to spot", detail: toPerp ? "SPOT → PERPS" : "PERPS → SPOT",
                    isDisabled: row.size < 0.01
                ) {
                    closeMenu()
                    Task { await model.transfer(row, toPerp: toPerp, wallets: wallets) }
                },
            ]
        }
    }

    private static let rowHeight: CGFloat = 20
    private static let band = Term.chrome

    var body: some View {
        let rows = model.rows(wallets: wallets, directory: directory)

        GeometryReader { geometry in
            let columns = Self.columns(fitting: geometry.size.width)

            VStack(spacing: 0) {
                commandLine(rows)
                summary(rows)
                header(columns)

                if rows.isEmpty {
                    empty
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                                    PositionLine(
                                        index: index, row: row, columns: columns,
                                        isSelected: row.id == model.selection, isArmed: row.id == model.armed
                                    )
                                    .equatable()
                                    .id(row.id)
                                    .termMenu(isOpen: menuRow == row.id, at: menuPoint, items: options(for: row)) { closeMenu() }
                                    .onTapGesture {
                                        model.select(row.id)
                                        closeMenu()
                                        if NSApp.currentEvent?.clickCount == 2 { onOpen(row) }
                                    }
                                    .onRightClick { point in
                                        model.select(row.id)
                                        menuPoint = point
                                        menuRow = row.id
                                        DropdownCenter.dismiss = { menuRow = nil }
                                    }
                                }
                            }
                        }
                        .onChange(of: model.selection) { _, selection in
                            if let selection { proxy.scrollTo(selection) }
                        }
                    }
                }

                footer(rows)
            }
        }
        .font(Term.font(11.5))
        .foregroundStyle(MarketsView.text)
        .background(MarketsView.field)
        .onAppear {
            directory.watch(true)
            wallets.watchAll(true)
        }
        .onDisappear {
            directory.watch(false)
            wallets.watchAll(false)
        }
    }

    private static func columns(fitting width: CGFloat) -> [PositionColumn] {
        var columns = PositionColumn.allCases
        for column in PositionColumn.dropOrder where columns.reduce(0, { $0 + $1.width }) + 24 > width {
            columns.removeAll { $0 == column }
        }
        return columns
    }

    private func commandLine(_ rows: [PositionRow]) -> some View {
        HStack(spacing: 10) {
            Text("POSITIONS")
                .font(Term.font(11.5, .bold))
                .foregroundStyle(MarketsView.field)
                .padding(.horizontal, 7)
                .frame(height: 18)
                .background(Term.accent)
            Text("<GO>").foregroundStyle(Term.accent)
            Text("\(walletCount) WALLET\(walletCount == 1 ? "" : "S")")
                .foregroundStyle(MarketsView.dim)
            Spacer(minLength: 0)
            Text("\(rows.filter { $0.kind != .cash }.count) OPEN")
                .foregroundStyle(MarketsView.dim)
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

    private var walletCount: Int { wallets.wallets.count }

    private func summary(_ rows: [PositionRow]) -> some View {
        // Perp account value already includes unrealized PnL; spot and cash are added at their live value.
        let perpEquity = wallets.wallets.reduce(0) { $0 + (wallets.accounts[$1.id]?.accountValue ?? 0) }
        let fetchedPnl = wallets.wallets.reduce(0) { total, wallet in
            total + (wallets.accounts[wallet.id]?.positions.reduce(0) { $0 + $1.unrealizedPnl } ?? 0)
        }
        let perps = rows.filter { $0.kind == .perp }
        let livePerpPnl = perps.reduce(0) { $0 + ($1.pnl ?? 0) }
        let cash = wallets.wallets.reduce(0) { $0 + (wallets.accounts[$1.id]?.spotUSDC ?? 0) }
        let perpCash = wallets.wallets.reduce(0) { $0 + (wallets.accounts[$1.id]?.withdrawable ?? 0) }
        let spotValue = rows.filter { $0.kind == .spot }.reduce(0) { $0 + $1.value } + cash
        let spotPnl = rows.filter { $0.kind == .spot }.reduce(0) { $0 + ($1.pnl ?? 0) }
        let solanaCash = rows.filter { $0.kind == .cash && $0.solana != nil }.reduce(0) { $0 + $1.value }
        let equity = perpEquity - fetchedPnl + livePerpPnl + spotValue + solanaCash
        let pnl = livePerpPnl + spotPnl
        let exposure = perps.reduce(0) { $0 + $1.value }

        return HStack(spacing: 18) {
            stat("EQUITY", "$" + HLFormat.price(equity, decimals: 2))
            stat("UNREAL PNL", Self.signed(pnl), PowderPalette.market(pnl))
            stat("PERP EXPOSURE", "$" + HLFormat.compact(exposure))
            stat("SPOT", "$" + HLFormat.price(spotValue - cash, decimals: 2))
            stat("CASH SPOT", "$" + HLFormat.price(cash, decimals: 2))
            stat("CASH PERPS", "$" + HLFormat.price(perpCash, decimals: 2))
            if !wallets.solana.wallets.isEmpty {
                stat("CASH SOLANA", "$" + HLFormat.price(solanaCash, decimals: 2))
            }
            stat("LONG", "\(perps.filter { $0.size > 0 }.count)", PowderPalette.signalGreen)
            stat("SHORT", "\(perps.filter { $0.size < 0 }.count)", PowderPalette.riskCoral)
            Spacer(minLength: 0)
        }
        .lineLimit(1)
        .padding(.horizontal, 10)
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 24, maxHeight: 24, alignment: .leading)
        .clipped()
        .overlay(alignment: .bottom) { TermRule() }
    }

    static func signed(_ value: Double) -> String {
        (value >= 0 ? "+$" : "−$") + HLFormat.price(abs(value), decimals: 2)
    }

    private func stat(_ label: String, _ value: String, _ color: Color = MarketsView.text) -> some View {
        HStack(spacing: 6) {
            Text(label).foregroundStyle(Term.accent)
            TickingPrice(value: nil, text: value, font: Term.font(11.5), color: color)
        }
        .fixedSize()
    }

    private func header(_ columns: [PositionColumn]) -> some View {
        HStack(spacing: 0) {
            ForEach(columns) { column in
                let isSorted = model.sort == column
                Text(column.title + (isSorted ? (model.ascending ? " ▲" : " ▼") : ""))
                    .font(Term.font(10.5, isSorted ? .bold : .regular))
                    .foregroundStyle(isSorted ? MarketsView.field : Term.accent)
                    .padding(.horizontal, 6)
                    .frame(width: column.width, height: Self.rowHeight, alignment: column.isText ? .leading : .trailing)
                    .background(isSorted ? Term.accent : .clear)
                    .contentShape(Rectangle())
                    .onTapGesture { model.sort(by: column) }
            }
            Spacer(minLength: 0)
        }
        .lineLimit(1)
        .background(Self.band)
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 10) {
            if walletCount == 0 {
                Text("NO WALLETS. CREATE OR IMPORT ONE TO TRACK POSITIONS.")
                    .foregroundStyle(MarketsView.dim)
                Button {
                    openSettings()
                } label: {
                    InverseLabel(text: "WALLETS  ⌘,")
                }
                .buttonStyle(.plain)
            } else {
                Text("NO OPEN POSITIONS IN \(walletCount) WALLET\(walletCount == 1 ? "" : "S").")
                    .foregroundStyle(MarketsView.dim)
                let cash = wallets.wallets.reduce(0) { $0 + (wallets.accounts[$1.id]?.spotUSDC ?? 0) }
                if cash >= 0.01 {
                    Text("$\(HLFormat.price(cash, decimals: 2)) USDC IS IN THE SPOT BALANCE. PERPS NEED IT IN THE PERP BALANCE: OPEN A MARKET AND PRESS MOVE TO PERPS IN THE ORDER TICKET.")
                        .foregroundStyle(Term.accent)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(12)
    }

    private func footer(_ rows: [PositionRow]) -> some View {
        HStack(spacing: 16) {
            if let armed = rows.first(where: { $0.id == model.armed }) {
                Text("PRESS ⏎ AGAIN TO CLOSE \(armed.coin) AT MARKET" + (armed.pnl.map { " · PNL \(Self.signed($0))" } ?? "") + " · ESC CANCELS")
                    .font(Term.font(10.5, .bold))
                    .foregroundStyle(MarketsView.field)
                    .padding(.horizontal, 6)
                    .frame(height: 16)
                    .background(PowderPalette.cautionAmber)
            } else if model.isClosing {
                Text("WORKING…").foregroundStyle(Term.accent)
            } else if let status = model.status {
                Text(status)
                    .foregroundStyle(model.statusIsError ? PowderPalette.riskCoral : PowderPalette.signalGreen)
            } else {
                hint("↑↓", "SELECT")
                hint("⏎ ⏎", "CLOSE AT MARKET")
                hint("O", "OPEN MARKET")
                hint("←→", "SORT")
                hint("R", "REVERSE")
            }
            Spacer(minLength: 0)
            Text("PNL LIVE FROM MIDS · BALANCES EVERY 3S")
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

struct PositionLine: View, Equatable {
    let index: Int
    let row: PositionRow
    let columns: [PositionColumn]
    let isSelected: Bool
    let isArmed: Bool

    @State private var flashColor = Color.clear
    @State private var flash = 0.0

    nonisolated static func == (lhs: PositionLine, rhs: PositionLine) -> Bool {
        lhs.index == rhs.index && lhs.row == rhs.row && lhs.columns == rhs.columns
            && lhs.isSelected == rhs.isSelected && lhs.isArmed == rhs.isArmed
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(columns) { column in
                cell(column)
                    .padding(.horizontal, 6)
                    .frame(width: column.width, alignment: column.isText ? .leading : .trailing)
                    .frame(maxHeight: .infinity)
                    .background(column == .pnl ? flashColor.opacity(flash) : .clear)
            }
            Spacer(minLength: 0)
        }
        .lineLimit(1)
        .frame(height: 20)
        .background(background)
        .contentShape(Rectangle())
        .onChange(of: row.pnl) { old, new in
            guard let old, let new, old != new else { return }
            flashColor = new > old ? PowderPalette.signalGreen : PowderPalette.riskCoral
            flash = 0.45
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(180))
                flash = 0
            }
        }
    }

    private var background: Color {
        if isArmed { return PowderPalette.cautionAmber }
        if isSelected { return Term.accent }
        return index.isMultiple(of: 2) ? .clear : Color.primary.opacity(0.035)
    }

    private var isReversed: Bool { isSelected || isArmed }

    @ViewBuilder
    private func cell(_ column: PositionColumn) -> some View {
        let decimals = PositionLine.priceDecimals(row.mark ?? row.entry ?? 1, isSolana: row.solana != nil)
        switch column {
        case .wallet: plain(row.walletName, MarketsView.dim)
        case .kind: plain(row.kind.rawValue, MarketsView.dim)
        case .coin:
            Text(row.coin).fontWeight(.bold).foregroundStyle(isReversed ? MarketsView.field : Term.accent)
        case .side:
            plain(row.side, row.kind == .perp ? PowderPalette.market(row.size) : MarketsView.dim, weight: .semibold)
        case .size: plain(row.solana != nil ? HLFormat.amount(abs(row.size)) : HLFormat.size(abs(row.size), decimals: 4), MarketsView.text)
        case .entry: plain(row.entry.map { HLFormat.price($0, decimals: decimals) } ?? "—", MarketsView.text)
        case .mark: plain(row.mark.map { HLFormat.price($0, decimals: decimals) } ?? "—", MarketsView.text, weight: .semibold)
        case .value: plain(HLFormat.price(row.value, decimals: 2), MarketsView.text)
        case .pnl:
            plain(row.pnl.map(PositionsView.signed) ?? "—", row.pnl.map(PowderPalette.market) ?? MarketsView.dim, weight: .semibold)
        case .pnlPercent:
            plain(row.pnlPercent.map { HLFormat.percent($0) } ?? "—", row.pnlPercent.map(PowderPalette.market) ?? MarketsView.dim)
        case .liquidation: plain(row.liquidation.map { HLFormat.price($0, decimals: decimals) } ?? "—", MarketsView.dim)
        case .leverage: plain(row.leverage.map { "\($0)x" } ?? "—", MarketsView.dim)
        }
    }

    private func plain(_ string: String, _ color: Color, weight: Font.Weight = .regular) -> some View {
        Text(string)
            .fontWeight(weight)
            .foregroundStyle(isReversed ? MarketsView.field : color)
    }

    /// Solana tokens are often priced far below a cent: about four significant figures, whatever the size.
    static func priceDecimals(_ price: Double, isSolana: Bool) -> Int {
        guard isSolana, price > 0, price < 1 else { return HLFormat.priceDecimals(for: price, szDecimals: 2) }
        return min(Int(ceil(-log10(price))) + 3, 12)
    }
}
