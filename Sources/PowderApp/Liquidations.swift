import SwiftUI

/// One forced close on Hyperliquid.
struct Liquidation: Identifiable, Equatable, Sendable {
    let id: String
    let coin: String
    /// True when a long was liquidated (the position was sold).
    let wasLong: Bool
    let price: Double
    let size: Double
    let value: Double
    /// "market": closed on the order book. "backstop": taken over by the liquidator vault.
    let method: String
    let user: String
    /// Milliseconds since epoch.
    let time: Int64
}

/// Market-wide liquidations. Hyperliquid's own API only reports them per account, so this reads
/// GoldRush's stream of every liquidation fill, which needs the user's GoldRush API key.
enum LiquidationFeed {
    static let keychain = KeychainStore(account: "goldrush-api-key")

    static var hasKey: Bool { keychain.readAPIKey() != nil }

    static func stream(key: String) -> AsyncThrowingStream<[Liquidation], Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                guard let escaped = key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                      let url = URL(string: "wss://hypercore.goldrushdata.com/ws?key=\(escaped)") else {
                    return continuation.finish(throwing: URLError(.badURL))
                }
                let socket = URLSession.shared.webSocketTask(with: url)
                defer { socket.cancel(with: .goingAway, reason: nil) }
                socket.resume()
                do {
                    try await socket.send(.string(#"{"method":"subscribe","subscription":{"type":"liquidationFills","aggregateByTime":true}}"#))
                    while !Task.isCancelled {
                        let data: Data
                        switch try await socket.receive() {
                        case let .string(text): data = Data(text.utf8)
                        case let .data(raw): data = raw
                        @unknown default: continue
                        }
                        let batch = parse(data)
                        if !batch.isEmpty { continuation.yield(batch) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    /// `{"channel":"liquidationFills","fills":[[address, fill], …]}`; some servers wrap it in `data`.
    /// Each liquidation shows up once per side of the trade: only the liquidated account's own fill is kept.
    static func parse(_ data: Data) -> [Liquidation] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        let body = root["data"] as? [String: Any] ?? root
        guard let fills = body["fills"] as? [Any] else { return [] }
        func number(_ value: Any?) -> Double { (value as? String).flatMap(Double.init) ?? (value as? NSNumber)?.doubleValue ?? 0 }
        return fills.compactMap { entry in
            guard let pair = entry as? [Any], pair.count == 2, let address = pair[0] as? String, let fill = pair[1] as? [String: Any],
                  let detail = fill["liquidation"] as? [String: Any], let coin = fill["coin"] as? String else { return nil }
            let victim = (detail["liquidatedUser"] as? String ?? "").lowercased()
            guard victim.isEmpty || victim == address.lowercased() else { return nil }
            let price = number(fill["px"]), size = number(fill["sz"])
            guard price > 0, size > 0 else { return nil }
            // The liquidated account sells to close a long ("Close Long"), buys to close a short.
            let direction = (fill["dir"] as? String ?? "").lowercased()
            let wasLong = direction.contains("long") ? true : direction.contains("short") ? false : fill["side"] as? String == "A"
            let time = (fill["time"] as? NSNumber)?.int64Value ?? Int64(Date().timeIntervalSince1970 * 1_000)
            return Liquidation(
                id: "\(fill["tid"] ?? fill["hash"] ?? time)|\(address)|\(coin)", coin: coin, wasLong: wasLong,
                price: price, size: size, value: price * size, method: detail["method"] as? String ?? "market",
                user: address, time: time
            )
        }
    }
}

@MainActor
final class LiquidationsModel: ObservableObject {
    @Published private(set) var rows: [Liquidation] = []
    @Published private(set) var status = "CONNECTING…"
    @Published private(set) var isLive = false
    @Published var selection: String?
    /// Smaller liquidations are left out of the table.
    @Published var minimumUSD: Double = UserDefaults.standard.double(forKey: "liquidations.minimum") {
        didSet { UserDefaults.standard.set(minimumUSD, forKey: "liquidations.minimum") }
    }

    static let minimums: [Double] = [0, 1_000, 10_000, 100_000, 1_000_000]
    private static let limit = 2_000
    private var task: Task<Void, Never>?
    private var viewers = 0

    var shown: [Liquidation] { minimumUSD > 0 ? rows.filter { $0.value >= minimumUSD } : rows }

    func total(last seconds: TimeInterval, long: Bool) -> Double {
        let cutoff = Int64((Date().timeIntervalSince1970 - seconds) * 1_000)
        return rows.reduce(0) { $0 + ($1.time >= cutoff && $1.wasLong == long ? $1.value : 0) }
    }

    func cycleMinimum() {
        let index = Self.minimums.firstIndex(of: minimumUSD) ?? 0
        minimumUSD = Self.minimums[(index + 1) % Self.minimums.count]
    }

    func move(_ delta: Int) {
        let list = shown
        guard !list.isEmpty else { return }
        let current = selection.flatMap { id in list.firstIndex { $0.id == id } }
        let next = current.map { min(max($0 + delta, 0), list.count - 1) } ?? (delta > 0 ? 0 : list.count - 1)
        selection = list[next].id
    }

    var selected: Liquidation? { rows.first { $0.id == selection } }

    func resume() {
        viewers += 1
        guard task == nil else { return }
        task = Task { [weak self] in await self?.run() }
    }

    func pause() {
        viewers = max(viewers - 1, 0)
        guard viewers == 0 else { return }
        task?.cancel()
        task = nil
        isLive = false
    }

    /// Reconnects after the key is added or changed.
    func restart() {
        guard viewers > 0 else { return }
        task?.cancel()
        task = Task { [weak self] in await self?.run() }
    }

    private func run() async {
        var failures = 0
        while !Task.isCancelled {
            guard let key = LiquidationFeed.keychain.readAPIKey() else {
                status = "NO GOLDRUSH KEY"
                isLive = false
                try? await Task.sleep(for: .seconds(2))
                continue
            }
            status = "CONNECTING…"
            do {
                for try await batch in LiquidationFeed.stream(key: key) {
                    failures = 0
                    isLive = true
                    status = "LIVE"
                    let known = Set(rows.prefix(400).map(\.id))
                    let fresh = batch.filter { !known.contains($0.id) }.sorted { $0.time > $1.time }
                    if !fresh.isEmpty { rows = Array((fresh + rows).prefix(Self.limit)) }
                }
                status = "DISCONNECTED"
            } catch {
                status = error.localizedDescription.uppercased()
            }
            isLive = false
            failures += 1
            try? await Task.sleep(for: .seconds(min(Double(failures) * 2, 30)))
        }
    }
}

struct LiquidationsView: View {
    @ObservedObject var model: LiquidationsModel
    let onOpen: (String) -> Void

    @Environment(\.openSettings) private var openSettings
    private static let band = Term.chrome
    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    var body: some View {
        let rows = model.shown
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                TableBadge(text: "LIQUIDATIONS")
                Text("HYPERLIQUID · ALL ACCOUNTS").foregroundStyle(MarketsView.dim)
                Spacer(minLength: 0)
                Text(model.minimumUSD > 0 ? "≥ $\(HLFormat.compact(model.minimumUSD))" : "ALL SIZES").foregroundStyle(Term.accent)
                Text(model.status).foregroundStyle(model.isLive ? PowderPalette.signalGreen : MarketsView.dim)
            }
            .tableBand(height: 26, background: Self.band)

            HStack(spacing: 18) {
                stat("LONGS 5M", model.total(last: 300, long: true), PowderPalette.riskCoral)
                stat("SHORTS 5M", model.total(last: 300, long: false), PowderPalette.signalGreen)
                stat("LONGS 1H", model.total(last: 3_600, long: true), PowderPalette.riskCoral)
                stat("SHORTS 1H", model.total(last: 3_600, long: false), PowderPalette.signalGreen)
                Spacer(minLength: 0)
                Text("SINCE THE TAB OPENED").foregroundStyle(MarketsView.dim)
            }
            .tableBand(height: 24, background: .clear)
            .overlay(alignment: .bottom) { TermRule() }

            TableRow(isHeader: true) {
                TableCell("TIME", width: 76, leading: true, color: Term.accent)
                TableCell("COIN", width: 76, leading: true, color: Term.accent)
                TableCell("LIQUIDATED", width: 96, leading: true, color: Term.accent)
                TableCell("PRICE", width: 104, color: Term.accent)
                TableCell("SIZE", width: 104, color: Term.accent)
                TableCell("VALUE $", width: 104, color: Term.accent)
                TableCell("HOW", width: 84, leading: true, color: Term.accent)
                TableCell("ACCOUNT", width: 110, leading: true, color: Term.accent)
            }
            .background(Self.band)

            if !LiquidationFeed.hasKey {
                VStack(alignment: .leading, spacing: 8) {
                    Text("HYPERLIQUID ONLY REPORTS LIQUIDATIONS PER ACCOUNT. THE MARKET-WIDE FEED COMES FROM GOLDRUSH AND NEEDS YOUR API KEY.")
                        .foregroundStyle(MarketsView.dim)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        openSettings()
                    } label: {
                        InverseLabel(text: "ADD THE KEY IN SETTINGS → DATA  ⌘,")
                    }
                    .buttonStyle(.plain)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(12)
            } else if rows.isEmpty {
                Text(model.isLive ? "CONNECTED. WAITING FOR THE NEXT LIQUIDATION…" : model.status)
                    .foregroundStyle(MarketsView.dim)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(12)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                            line(row, index: index)
                                .onTapGesture {
                                    model.selection = row.id
                                    if NSApp.currentEvent?.clickCount == 2 { onOpen(row.coin) }
                                }
                        }
                    }
                }
            }

            HStack(spacing: 16) {
                TableHint(key: "↑↓", action: "SELECT")
                TableHint(key: "⏎", action: "OPEN MARKET")
                TableHint(key: "M", action: "MINIMUM SIZE")
                Spacer(minLength: 0)
                Text("DATA: GOLDRUSH").foregroundStyle(MarketsView.dim)
            }
            .font(Term.font(10.5))
            .tableBand(height: 22, background: Self.band)
        }
        .font(Term.font(11.5))
        .foregroundStyle(MarketsView.text)
        .background(MarketsView.field)
        .onAppear { model.resume() }
        .onDisappear { model.pause() }
    }

    private func stat(_ label: String, _ value: Double, _ color: Color) -> some View {
        HStack(spacing: 6) {
            Text(label).foregroundStyle(Term.accent)
            Text("$" + HLFormat.compact(value)).foregroundStyle(value > 0 ? color : MarketsView.dim)
        }
        .fixedSize()
    }

    private func line(_ row: Liquidation, index: Int) -> some View {
        let isSelected = row.id == model.selection
        let ink = { (color: Color) in isSelected ? MarketsView.field : color }
        let decimals = HLFormat.priceDecimals(for: row.price, szDecimals: 2)
        // Big ones stand out.
        let weight: Font.Weight = row.value >= 100_000 ? .bold : .regular
        return TableRow {
            TableCell(Self.clock.string(from: Date(timeIntervalSince1970: Double(row.time) / 1_000)), width: 76, leading: true, color: ink(MarketsView.dim))
            TableCell(row.coin, width: 76, leading: true, color: ink(Term.accent), weight: .bold)
            TableCell(row.wasLong ? "LONG" : "SHORT", width: 96, leading: true, color: ink(row.wasLong ? PowderPalette.riskCoral : PowderPalette.signalGreen), weight: .semibold)
            TableCell(HLFormat.price(row.price, decimals: decimals), width: 104, color: ink(MarketsView.text))
            TableCell(HLFormat.size(row.size, decimals: 4), width: 104, color: ink(MarketsView.text))
            TableCell(HLFormat.price(row.value, decimals: 0), width: 104, color: ink(MarketsView.text), weight: weight)
            TableCell(row.method.uppercased(), width: 84, leading: true, color: ink(MarketsView.dim))
            TableCell(Wallet.shorten(row.user), width: 110, leading: true, color: ink(MarketsView.dim))
        }
        .background(isSelected ? Term.accent : (index.isMultiple(of: 2) ? .clear : Color.primary.opacity(0.035)))
        .contentShape(Rectangle())
    }
}
