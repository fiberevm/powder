import Foundation

/// A Solana token a market tab can show.
struct SolanaToken: Equatable, Sendable {
    let address: String
    var symbol: String
    var name: String

    /// How the tab is written in the saved layout.
    var savedName: String { "sol:\(address)|\(symbol)|\(name)" }

    init(address: String, symbol: String, name: String) {
        self.address = address
        self.symbol = symbol
        self.name = name
    }

    init?(savedName: String) {
        guard savedName.hasPrefix("sol:") else { return nil }
        let parts = savedName.dropFirst(4).split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard let address = parts.first, !address.isEmpty else { return nil }
        self.init(address: address, symbol: parts.count > 1 ? parts[1] : String(address.prefix(4)), name: parts.count > 2 ? parts[2] : "")
    }
}

/// A token's live figures from Codex.
struct SolanaStats: Equatable, Sendable {
    let token: SolanaToken
    let price: Double
    /// 24h change as a fraction.
    let change24: Double
    let volume24: Double
    let liquidity: Double
    let marketCap: Double
    let holders: Int?
    /// The token's most liquid pool; its swaps are the trades tape.
    let pairAddress: String?
}

/// Solana market data from Codex (codex.io), using the API key saved in Settings.
enum SolanaAPI {
    static let network = 1_399_811_149
    private static let endpoint = URL(string: "https://graph.codex.io/graphql")!

    /// Candle lengths Codex serves, by Hyperliquid's names so the chart needs no second vocabulary.
    static let resolutions: [(interval: HLInterval, code: String)] = [
        (.m1, "1"), (.m5, "5"), (.m15, "15"), (.m30, "30"), (.h1, "60"), (.h4, "240"), (.h12, "720"), (.d1, "1D"), (.w1, "7D"),
    ]

    static var intervals: [HLInterval] { resolutions.map(\.interval) }

    static var hasKey: Bool { KeychainStore().readAPIKey() != nil }

    private static let resultFields = """
    token { address name symbol }
    priceUSD change24 volume24 liquidity marketCap holders
    pair { address }
    """

    /// Tokens matching a name, symbol or address, most traded first.
    static func search(_ phrase: String, limit: Int = 8) async throws -> [SolanaStats] {
        let query = """
        query($phrase: String, $limit: Int) {
          filterTokens(phrase: $phrase, filters: { network: \(network) }, rankings: { attribute: volume24, direction: DESC }, limit: $limit) {
            results { \(resultFields) }
          }
        }
        """
        let data = try await post(query, variables: ["phrase": phrase, "limit": limit])
        return results(in: data)
    }

    static func stats(address: String) async throws -> SolanaStats? {
        let query = """
        query($tokens: [String]) {
          filterTokens(tokens: $tokens, limit: 1) { results { \(resultFields) } }
        }
        """
        let data = try await post(query, variables: ["tokens": ["\(address):\(network)"]])
        return results(in: data).first
    }

    private static func results(in data: [String: Any]) -> [SolanaStats] {
        let rows = (data["filterTokens"] as? [String: Any])?["results"] as? [[String: Any]] ?? []
        return rows.compactMap { row in
            guard let token = row["token"] as? [String: Any], let address = token["address"] as? String else { return nil }
            return SolanaStats(
                token: SolanaToken(address: address, symbol: token["symbol"] as? String ?? "?", name: token["name"] as? String ?? ""),
                price: number(row["priceUSD"]), change24: number(row["change24"]), volume24: number(row["volume24"]),
                liquidity: number(row["liquidity"]), marketCap: number(row["marketCap"]),
                holders: (row["holders"] as? NSNumber)?.intValue,
                pairAddress: (row["pair"] as? [String: Any])?["address"] as? String
            )
        }
    }

    /// Candles ending at `end` (milliseconds), oldest first.
    static func bars(token: SolanaToken, interval: HLInterval, end: Int64? = nil, count: Int = 600) async throws -> [HLCandle] {
        guard let code = resolutions.first(where: { $0.interval == interval })?.code else { return [] }
        let to = Int((end ?? Int64(Date().timeIntervalSince1970 * 1_000)) / 1_000)
        let from = max(to - Int(interval.milliseconds / 1_000) * count, 0)
        let query = """
        query($symbol: String!, $from: Int!, $to: Int!, $resolution: String!, $countback: Int!) {
          getTokenBars(symbol: $symbol, from: $from, to: $to, resolution: $resolution, countback: $countback,
                       removeLeadingNullValues: true, removeEmptyBars: true, statsType: FILTERED) {
            o h l c t volume
          }
        }
        """
        let data = try await post(query, variables: [
            "symbol": "\(token.address):\(network)", "from": from, "to": to, "resolution": code, "countback": min(count, 1_500),
        ])
        guard let bars = data["getTokenBars"] as? [String: Any], let times = bars["t"] as? [Any] else { return [] }
        func column(_ key: String) -> [Any] { bars[key] as? [Any] ?? [] }
        let o = column("o"), h = column("h"), l = column("l"), c = column("c"), v = column("volume")
        var candles: [HLCandle] = []
        for index in times.indices where index < o.count && index < h.count && index < l.count && index < c.count {
            let close = number(c[index])
            guard close > 0 else { continue }
            candles.append(HLCandle(
                t: Int64(number(times[index])) * 1_000, coin: token.symbol, interval: interval.rawValue,
                o: number(o[index]), h: number(h[index]), l: number(l[index]), c: close,
                v: index < v.count ? number(v[index]) : 0
            ))
        }
        return candles.sorted { $0.t < $1.t }
    }

    /// The pool's latest swaps, newest first. Size is in tokens.
    static func trades(pair: String, symbol: String, limit: Int = 60) async throws -> [HLTrade] {
        let query = """
        query($address: String!, $limit: Int) {
          getTokenEvents(query: { address: $address, networkId: \(network), eventType: Swap }, limit: $limit, direction: DESC) {
            items {
              id timestamp eventDisplayType
              data { ... on SwapEventData { priceUsd priceUsdTotal amountNonLiquidityToken } }
            }
          }
        }
        """
        let data = try await post(query, variables: ["address": pair, "limit": limit])
        let items = (data["getTokenEvents"] as? [String: Any])?["items"] as? [Any] ?? []
        return items.compactMap { item in
            guard let item = item as? [String: Any], let swap = item["data"] as? [String: Any] else { return nil }
            let price = number(swap["priceUsd"])
            var size = abs(number(swap["amountNonLiquidityToken"]))
            if size == 0, price > 0 { size = number(swap["priceUsdTotal"]) / price }
            guard price > 0, size > 0 else { return nil }
            let id = item["id"] as? String ?? "\(item["timestamp"] ?? 0)\(price)\(size)"
            return HLTrade(
                tid: stableID(id), coin: symbol, isBuy: (item["eventDisplayType"] as? String ?? "").lowercased().contains("buy"),
                px: price, sz: size, time: Int64(number(item["timestamp"])) * 1_000
            )
        }
    }

    /// FNV-1a, so the same swap gets the same id on every poll.
    private static func stableID(_ text: String) -> Int64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
        return Int64(bitPattern: hash)
    }

    private static func number(_ value: Any?) -> Double {
        if let string = value as? String { return Double(string) ?? 0 }
        return (value as? NSNumber)?.doubleValue ?? 0
    }

    private static func post(_ query: String, variables: [String: Any]) async throws -> [String: Any] {
        guard let key = KeychainStore().readAPIKey() else { throw CodexError.missingAPIKey }
        var request = URLRequest(url: endpoint, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode == 401 || http.statusCode == 403 { throw CodexError.unauthorized }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CodexError.invalidResponse }
        if let errors = root["errors"] as? [[String: Any]], let message = errors.first?["message"] as? String {
            throw CodexError.graphQL(message)
        }
        guard let payload = root["data"] as? [String: Any] else { throw CodexError.invalidResponse }
        return payload
    }
}
