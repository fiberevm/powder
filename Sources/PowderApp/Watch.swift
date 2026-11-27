import SwiftUI
import UserNotifications

/// A market that can be watched or alerted on: a Hyperliquid perp, or a Solana token in one pool.
struct MarketRef: Codable, Equatable, Hashable, Identifiable, Sendable {
    /// "perp:ETH", "pool:<pool>|<mint>", or "sol:<mint>" for a token named without a pool.
    let id: String
    var symbol: String
    var name = ""
    /// The Solana tab this came from, as the layout writes it, so opening it returns to the same pool.
    var saved: String?

    /// The token's mint, whichever pool it is watched in.
    var mint: String? {
        if id.hasPrefix("sol:") { return String(id.dropFirst(4)) }
        if id.hasPrefix("pool:") { return id.split(separator: "|").last.map(String.init) }
        return nil
    }

    var pool: String? {
        id.hasPrefix("pool:") ? id.dropFirst(5).split(separator: "|").first.map(String.init) : nil
    }

    var coin: String? { id.hasPrefix("perp:") ? String(id.dropFirst(5)) : nil }

    var solana: SolanaToken? {
        if let token = saved.flatMap(SolanaToken.init(savedName:)) { return token }
        return mint.map { SolanaToken(address: $0, symbol: symbol, name: name) }
    }

    /// Where its price is found in `SolanaQuotes`: the pool's own price when it names a pool, else the token's.
    var quoteKey: String? { pool != nil ? id : mint }

    static func perp(_ coin: String) -> MarketRef { MarketRef(id: "perp:\(coin)", symbol: coin) }

    /// A Solana market is a token in a pool: the same token in another pool is another market, with its own price.
    static func solana(_ token: SolanaToken) -> MarketRef {
        guard let pool = token.pool else { return MarketRef(id: "sol:\(token.address)", symbol: token.symbol, name: token.name) }
        return MarketRef(id: "pool:\(pool.address)|\(token.address)", symbol: token.pairName, name: token.name, saved: token.savedName)
    }
}

/// Live prices for Solana markets that tabs other than their own need (watchlist, alerts, stops). Polled while anyone asks.
/// Keyed by `MarketRef.quoteKey`: a mint for a token's overall price, a pool reference for its price in that pool.
@MainActor
final class SolanaQuotes: ObservableObject {
    @Published private(set) var stats: [String: SolanaStats] = [:]
    private var wanted: [String: Set<String>] = [:]
    private var task: Task<Void, Never>?

    /// Each user names the markets it needs (by quote key); an empty set stops its share of the polling.
    func want(_ keys: Set<String>, for user: String) {
        wanted[user] = keys.isEmpty ? nil : keys
        if wanted.isEmpty {
            task?.cancel()
            task = nil
        } else if task == nil {
            task = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.refresh()
                    // A stop loss should not wait four seconds for a price.
                    try? await Task.sleep(for: .seconds(self?.wanted["triggers"] == nil ? 4 : 1.5))
                }
            }
        }
    }

    private func refresh() async {
        let keys = wanted.values.reduce(into: Set<String>()) { $0.formUnion($1) }
        // Pools are read one by one; their tokens are also read together, as the price to fall back on.
        let pools = keys.filter { $0.hasPrefix("pool:") }.sorted().prefix(40).compactMap { key -> (key: String, pool: String, mint: String)? in
            let parts = key.dropFirst(5).split(separator: "|").map(String.init)
            return parts.count == 2 ? (key, parts[0], parts[1]) : nil
        }
        let mints = Array(Set(keys.filter { !$0.hasPrefix("pool:") }).union(pools.map(\.mint)).sorted().prefix(200))
        if !mints.isEmpty, let fresh = try? await SolanaAPI.stats(addresses: mints) {
            for stat in fresh where stats[stat.token.address] != stat { stats[stat.token.address] = stat }
        }
        await withTaskGroup(of: (String, SolanaStats?).self) { group in
            for item in pools {
                group.addTask { (item.key, try? await SolanaAPI.pool(address: item.pool, base: item.mint)) }
            }
            for await (key, stat) in group {
                // A pool that does not price this token itself has no price of its own: the token's overall one stands in.
                let mint = String(key.split(separator: "|").last ?? "")
                guard let chosen = (stat.flatMap { $0.price > 0 ? $0 : nil }) ?? stats[mint] else { continue }
                if stats[key] != chosen { stats[key] = chosen }
            }
        }
    }
}

// MARK: - Watchlist

/// The markets the user keeps an eye on, in the order they were added.
@MainActor
final class WatchlistStore: ObservableObject {
    @Published private(set) var items: [MarketRef] = []
    @Published var selection: String?

    private let defaults: UserDefaults
    private static let key = "watchlist"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        items = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([MarketRef].self, from: $0) } ?? []
    }

    func contains(_ id: String) -> Bool { items.contains { $0.id == id } }

    /// Adds the market, or removes it if it is already there. Returns whether it is now watched.
    @discardableResult
    func toggle(_ market: MarketRef) -> Bool {
        if let index = items.firstIndex(where: { $0.id == market.id }) {
            items.remove(at: index)
            save()
            return false
        }
        items.append(market)
        save()
        return true
    }

    func remove(_ id: String) {
        let index = items.firstIndex { $0.id == id }
        items.removeAll { $0.id == id }
        save()
        if selection == id { selection = index.flatMap { items.indices.contains($0) ? items[$0].id : items.last?.id } }
    }

    func move(_ delta: Int) {
        guard !items.isEmpty else { return }
        let current = selection.flatMap { id in items.firstIndex { $0.id == id } }
        let next = current.map { min(max($0 + delta, 0), items.count - 1) } ?? (delta > 0 ? 0 : items.count - 1)
        selection = items[next].id
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) { defaults.set(data, forKey: Self.key) }
    }
}

/// The price, change and volume of one watched or alerted market, wherever it trades.
struct MarketQuoteLine {
    let price: Double?
    let change: Double?
    let volume: Double?
    let funding: Double?
    let isSolana: Bool

    @MainActor
    init(_ market: MarketRef, directory: MarketDirectory, quotes: SolanaQuotes) {
        if let coin = market.coin {
            let perp = directory.markets[coin]
            let last = directory.mids[coin] ?? perp?.ctx.midPx ?? perp?.ctx.markPx
            price = last
            change = perp.flatMap { $0.ctx.prevDayPx > 0 ? (last ?? $0.ctx.markPx) / $0.ctx.prevDayPx - 1 : nil }
            volume = perp?.ctx.dayNtlVlm
            funding = perp?.ctx.funding
            isSolana = false
        } else {
            let stat = market.quoteKey.flatMap { quotes.stats[$0] }
            price = stat?.price
            change = stat?.change24
            volume = stat?.volume24
            funding = nil
            isSolana = true
        }
    }
}

struct WatchlistView: View {
    @ObservedObject var store: WatchlistStore
    @ObservedObject var directory: MarketDirectory
    @ObservedObject var quotes: SolanaQuotes
    let onOpen: (MarketRef) -> Void

    private static let band = Term.chrome

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                TableBadge(text: "WATCHLIST")
                Text("\(store.items.count) MARKET\(store.items.count == 1 ? "" : "S")").foregroundStyle(MarketsView.dim)
                Spacer(minLength: 0)
            }
            .tableBand(height: 26, background: Self.band)

            TableRow(isHeader: true) {
                TableCell("MARKET", width: 128, leading: true, color: Term.accent)
                TableCell("TYPE", width: 64, leading: true, color: Term.accent)
                TableCell("LAST", width: 110, color: Term.accent)
                TableCell("CHG %", width: 84, color: Term.accent)
                TableCell("VOL 24H", width: 96, color: Term.accent)
                TableCell("FUND 1H", width: 90, color: Term.accent)
            }
            .background(Self.band)

            if store.items.isEmpty {
                Text("NOTHING WATCHED YET. PRESS W ON A MARKET TAB OR F IN THE MARKETS TABLE TO ADD ONE.")
                    .foregroundStyle(MarketsView.dim)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(12)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(store.items.enumerated()), id: \.element.id) { index, market in
                                row(market, index: index)
                                    .id(market.id)
                                    .onTapGesture {
                                        store.selection = market.id
                                        if NSApp.currentEvent?.clickCount == 2 { onOpen(market) }
                                    }
                            }
                        }
                    }
                    .onChange(of: store.selection) { _, selection in
                        if let selection { proxy.scrollTo(selection) }
                    }
                }
            }

            HStack(spacing: 16) {
                TableHint(key: "↑↓", action: "SELECT")
                TableHint(key: "⏎", action: "OPEN")
                TableHint(key: "⌫", action: "REMOVE")
                Spacer(minLength: 0)
            }
            .font(Term.font(10.5))
            .tableBand(height: 22, background: Self.band)
        }
        .font(Term.font(11.5))
        .foregroundStyle(MarketsView.text)
        .background(MarketsView.field)
        .onAppear {
            directory.watch(true)
            quotes.want(Set(store.items.compactMap(\.quoteKey)), for: "watchlist")
        }
        .onDisappear {
            directory.watch(false)
            quotes.want([], for: "watchlist")
        }
        .onChange(of: store.items) { _, items in quotes.want(Set(items.compactMap(\.quoteKey)), for: "watchlist") }
    }

    private func row(_ market: MarketRef, index: Int) -> some View {
        let quote = MarketQuoteLine(market, directory: directory, quotes: quotes)
        let isSelected = market.id == store.selection
        let ink = { (color: Color) in isSelected ? MarketsView.field : color }
        let decimals = PositionLine.priceDecimals(quote.price ?? 1, isSolana: quote.isSolana)
        return TableRow {
            TableCell(market.symbol, width: 128, leading: true, color: ink(Term.accent), weight: .bold)
            TableCell(quote.isSolana ? "SOLANA" : "PERP", width: 64, leading: true, color: ink(MarketsView.dim))
            TableCell(quote.price.map { HLFormat.price($0, decimals: decimals) } ?? "—", width: 110, color: ink(MarketsView.text), weight: .semibold)
            TableCell(quote.change.map { HLFormat.percent($0) } ?? "—", width: 84, color: ink(quote.change.map(PowderPalette.market) ?? MarketsView.dim))
            TableCell(quote.volume.map { HLFormat.compact($0) } ?? "—", width: 96, color: ink(MarketsView.text))
            TableCell(quote.funding.map { HLFormat.percent($0, decimals: 4) } ?? "—", width: 90, color: ink(quote.funding.map(PowderPalette.market) ?? MarketsView.dim))
        }
        .background(isSelected ? Term.accent : (index.isMultiple(of: 2) ? .clear : Color.primary.opacity(0.035)))
        .contentShape(Rectangle())
    }
}

// MARK: - Alerts

struct PriceAlert: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    let market: MarketRef
    let price: Double
    /// True: fires when the price rises to it. False: when it falls to it.
    let isAbove: Bool
    var created = Date()
    var triggeredAt: Date?
    /// The price that set it off.
    var triggeredPrice: Double?

    var isActive: Bool { triggeredAt == nil }
}

/// Price alerts across both venues. Checked once a second for as long as any is waiting.
@MainActor
final class AlertStore: ObservableObject {
    @Published private(set) var alerts: [PriceAlert] = []
    @Published var selection: UUID?
    @Published var entry = ""
    @Published var entryMessage: String?
    /// Bumped to put the cursor in the tab's entry line.
    @Published var entryFocusRequest = 0

    private let defaults: UserDefaults
    private let directory: MarketDirectory
    let quotes: SolanaQuotes
    private var task: Task<Void, Never>?
    private static let key = "alerts"
    private static let chime = NSSound(named: "Glass")

    init(defaults: UserDefaults = .standard, directory: MarketDirectory, quotes: SolanaQuotes) {
        self.defaults = defaults
        self.directory = directory
        self.quotes = quotes
        alerts = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([PriceAlert].self, from: $0) } ?? []
        updateWatching()
    }

    func price(of market: MarketRef) -> Double? {
        if let coin = market.coin { return directory.mids[coin] ?? directory.markets[coin]?.ctx.midPx ?? directory.markets[coin]?.ctx.markPx }
        return market.quoteKey.flatMap { quotes.stats[$0]?.price }
    }

    func alerts(for market: MarketRef) -> [PriceAlert] {
        alerts.filter { $0.market.id == market.id && $0.isActive }
    }

    /// Adds an alert at `price`: above the current price it waits for a rise, below it for a fall.
    @discardableResult
    func add(_ market: MarketRef, price: Double, current: Double? = nil) -> PriceAlert? {
        guard price > 0, let now = current ?? self.price(of: market) else { return nil }
        let alert = PriceAlert(market: market, price: price, isAbove: price >= now)
        alerts.insert(alert, at: 0)
        save()
        updateWatching()
        Self.askPermission()
        return alert
    }

    func remove(_ id: UUID) {
        let index = alerts.firstIndex { $0.id == id }
        alerts.removeAll { $0.id == id }
        save()
        updateWatching()
        if selection == id { selection = index.flatMap { alerts.indices.contains($0) ? alerts[$0].id : alerts.last?.id } }
    }

    func clearTriggered() {
        alerts.removeAll { !$0.isActive }
        save()
    }

    func move(_ delta: Int) {
        guard !alerts.isEmpty else { return }
        let current = selection.flatMap { id in alerts.firstIndex { $0.id == id } }
        let next = current.map { min(max($0 + delta, 0), alerts.count - 1) } ?? (delta > 0 ? 0 : alerts.count - 1)
        selection = alerts[next].id
    }

    /// Reads "ETH 1700" from the tab's entry line. Only perps are named this way; a Solana token's alert is set from its chart.
    func submitEntry() {
        let parts = entry.split(whereSeparator: { $0 == " " || $0 == "@" || $0 == ">" || $0 == "<" }).map(String.init)
        guard parts.count == 2, let price = Double(parts[1].replacingOccurrences(of: ",", with: "")) else {
            entryMessage = "TYPE A COIN AND A PRICE, LIKE: ETH 1700"
            return
        }
        guard let coin = directory.markets.keys.first(where: { $0.caseInsensitiveCompare(parts[0]) == .orderedSame }) else {
            entryMessage = "NO PERP NAMED \(parts[0].uppercased()). FOR A SOLANA TOKEN, RIGHT-CLICK ITS CHART."
            return
        }
        guard add(.perp(coin), price: price) != nil else {
            entryMessage = "NO PRICE FOR \(coin) YET. TRY AGAIN IN A MOMENT."
            return
        }
        entry = ""
        entryMessage = nil
    }

    private func save() {
        if let data = try? JSONEncoder().encode(alerts) { defaults.set(data, forKey: Self.key) }
    }

    /// Perp prices stream for the whole app; Solana prices are polled only while an alert waits on one.
    private func updateWatching() {
        let active = alerts.filter(\.isActive)
        quotes.want(Set(active.compactMap(\.market.quoteKey)), for: "alerts")
        if active.isEmpty {
            task?.cancel()
            task = nil
        } else if task == nil {
            task = Task { [weak self] in
                while !Task.isCancelled {
                    self?.check()
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        }
    }

    private func check() {
        var fired: [PriceAlert] = []
        for index in alerts.indices where alerts[index].isActive {
            guard let now = price(of: alerts[index].market) else { continue }
            if alerts[index].isAbove ? now >= alerts[index].price : now <= alerts[index].price {
                alerts[index].triggeredAt = Date()
                alerts[index].triggeredPrice = now
                fired.append(alerts[index])
            }
        }
        guard !fired.isEmpty else { return }
        save()
        updateWatching()
        Self.chime?.play()
        for alert in fired { Self.notify(alert) }
    }

    static func describe(_ alert: PriceAlert) -> String {
        let decimals = PositionLine.priceDecimals(alert.price, isSolana: alert.market.mint != nil)
        return "\(alert.market.symbol) \(alert.isAbove ? "rose to" : "fell to") \(HLFormat.price(alert.price, decimals: decimals))"
    }

    private static func askPermission() {
        NotificationPresenter.center?.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private static func notify(_ alert: PriceAlert) {
        let content = UNMutableNotificationContent()
        content.title = "Powder: \(describe(alert))"
        if let price = alert.triggeredPrice {
            content.body = "Now \(HLFormat.price(price, decimals: PositionLine.priceDecimals(price, isSolana: alert.market.mint != nil)))"
        }
        NotificationPresenter.center?.add(UNNotificationRequest(identifier: alert.id.uuidString, content: content, trigger: nil))
    }
}

/// Lets a notification show as a banner even while Powder is the app in front.
final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate, Sendable {
    static let shared = NotificationPresenter()

    /// macOS only gives a notification centre to a real app bundle; run any other way (tests, `swift run`), there is none.
    static var center: UNUserNotificationCenter? {
        Bundle.main.bundleURL.pathExtension == "app" ? .current() : nil
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }
}

struct AlertsView: View {
    @ObservedObject var store: AlertStore
    @ObservedObject var directory: MarketDirectory
    @ObservedObject var quotes: SolanaQuotes
    let onOpen: (MarketRef) -> Void

    @FocusState private var isEntryFocused: Bool
    private static let band = Term.chrome
    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM dd HH:mm:ss"
        return formatter
    }()

    var body: some View {
        let waiting = store.alerts.filter(\.isActive).count
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                TableBadge(text: "ALERTS")
                Text("NEW ❯").foregroundStyle(Term.accent)
                TextField("ETH 1700", text: $store.entry)
                    .textFieldStyle(.plain)
                    .focused($isEntryFocused)
                    .onSubmit { store.submitEntry() }
                    .frame(maxWidth: 220)
                if let message = store.entryMessage {
                    Text(message).foregroundStyle(PowderPalette.riskCoral)
                }
                Spacer(minLength: 0)
                Text("\(waiting) WAITING · \(store.alerts.count - waiting) TRIGGERED").foregroundStyle(MarketsView.dim)
            }
            .tableBand(height: 26, background: Self.band)

            TableRow(isHeader: true) {
                TableCell("MARKET", width: 128, leading: true, color: Term.accent)
                TableCell("WHEN PRICE", width: 104, leading: true, color: Term.accent)
                TableCell("LEVEL", width: 110, color: Term.accent)
                TableCell("LAST", width: 110, color: Term.accent)
                TableCell("AWAY", width: 80, color: Term.accent)
                TableCell("STATUS", width: 200, leading: true, color: Term.accent)
            }
            .background(Self.band)

            if store.alerts.isEmpty {
                Text("NO ALERTS. TYPE A COIN AND A PRICE ABOVE, OR RIGHT-CLICK A CHART AT THE PRICE YOU WANT.")
                    .foregroundStyle(MarketsView.dim)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(12)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(store.alerts.enumerated()), id: \.element.id) { index, alert in
                                row(alert, index: index)
                                    .id(alert.id)
                                    .onTapGesture {
                                        store.selection = alert.id
                                        if NSApp.currentEvent?.clickCount == 2 { onOpen(alert.market) }
                                    }
                            }
                        }
                    }
                    .onChange(of: store.selection) { _, selection in
                        if let selection { proxy.scrollTo(selection) }
                    }
                }
            }

            HStack(spacing: 16) {
                TableHint(key: "A", action: "NEW")
                TableHint(key: "↑↓", action: "SELECT")
                TableHint(key: "⏎", action: "OPEN MARKET")
                TableHint(key: "⌫", action: "DELETE")
                TableHint(key: "C", action: "CLEAR TRIGGERED")
                Spacer(minLength: 0)
                Text("CHECKED EVERY SECOND WHILE POWDER IS OPEN").foregroundStyle(MarketsView.dim)
            }
            .font(Term.font(10.5))
            .tableBand(height: 22, background: Self.band)
        }
        .font(Term.font(11.5))
        .foregroundStyle(MarketsView.text)
        .background(MarketsView.field)
        .onChange(of: store.entryFocusRequest) { isEntryFocused = true }
    }

    private func row(_ alert: PriceAlert, index: Int) -> some View {
        let isSelected = alert.id == store.selection
        let ink = { (color: Color) in isSelected ? MarketsView.field : color }
        let isSolana = alert.market.mint != nil
        let last = store.price(of: alert.market)
        let decimals = PositionLine.priceDecimals(alert.price, isSolana: isSolana)
        let away = last.map { alert.price / $0 - 1 }
        return TableRow {
            TableCell(alert.market.symbol, width: 128, leading: true, color: ink(Term.accent), weight: .bold)
            TableCell(alert.isAbove ? "RISES TO" : "FALLS TO", width: 104, leading: true, color: ink(alert.isAbove ? PowderPalette.signalGreen : PowderPalette.riskCoral))
            TableCell(HLFormat.price(alert.price, decimals: decimals), width: 110, color: ink(MarketsView.text), weight: .semibold)
            TableCell(last.map { HLFormat.price($0, decimals: decimals) } ?? "—", width: 110, color: ink(MarketsView.text))
            TableCell(alert.isActive ? (away.map { HLFormat.percent($0) } ?? "—") : "—", width: 80, color: ink(MarketsView.dim))
            TableCell(
                alert.triggeredAt.map { "TRIGGERED \(Self.stamp.string(from: $0).uppercased())" } ?? "WAITING",
                width: 200, leading: true, color: ink(alert.isActive ? MarketsView.dim : Term.accent)
            )
        }
        .background(isSelected ? Term.accent : (index.isMultiple(of: 2) ? .clear : Color.primary.opacity(0.035)))
        .contentShape(Rectangle())
    }
}

// MARK: - Table pieces shared by the simple tabs

struct TableBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Term.font(11.5, .bold))
            .foregroundStyle(MarketsView.field)
            .padding(.horizontal, 6)
            .frame(height: 16)
            .background(Term.accent)
    }
}

struct TableHint: View {
    let key: String
    let action: String

    var body: some View {
        HStack(spacing: 5) {
            Text(key).foregroundStyle(Term.accent)
            Text(action).foregroundStyle(MarketsView.dim)
        }
        .fixedSize()
    }
}

struct TableCell: View {
    let text: String
    let width: CGFloat
    var leading = false
    var color: Color = MarketsView.text
    var weight: Font.Weight = .regular

    init(_ text: String, width: CGFloat, leading: Bool = false, color: Color = MarketsView.text, weight: Font.Weight = .regular) {
        self.text = text
        self.width = width
        self.leading = leading
        self.color = color
        self.weight = weight
    }

    var body: some View {
        Text(text)
            .fontWeight(weight)
            .foregroundStyle(color)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .frame(width: width, height: 20, alignment: leading ? .leading : .trailing)
    }
}

/// One line of cells that takes the pane's width and is cut off at its edge rather than widening the table.
struct TableRow<Content: View>: View {
    var isHeader = false
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 0) {
            content
            Spacer(minLength: 0)
        }
        .font(Term.font(isHeader ? 10.5 : 11.5))
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .clipped()
    }
}

extension View {
    /// A full-width strip of fixed height: the command line and footer of a table tab.
    func tableBand(height: CGFloat, background: Color) -> some View {
        lineLimit(1)
            .padding(.horizontal, 10)
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .leading)
            .background(background)
            .clipped()
    }
}
