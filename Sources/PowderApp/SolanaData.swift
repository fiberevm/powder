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

/// An exchange a token trades on, and where on its site the token can be traded.
struct SolanaExchange: Equatable, Sendable {
    let name: String
    /// The exchange's own trading page, as Codex gives it.
    var tradeURL: URL?

    /// The exchange's page for one token where its address scheme is known, else its trading page.
    func marketURL(mint: String) -> URL? {
        let wrappedSOL = "So11111111111111111111111111111111111111112"
        let lowered = name.lowercased()
        if mint != wrappedSOL {
            if lowered.hasPrefix("raydium") { return URL(string: "https://raydium.io/swap/?inputMint=sol&outputMint=\(mint)") }
            if lowered.hasPrefix("pump") { return URL(string: "https://pump.fun/coin/\(mint)") }
            if lowered.hasPrefix("orca") { return URL(string: "https://www.orca.so/?tokenIn=\(wrappedSOL)&tokenOut=\(mint)") }
        }
        return tradeURL
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
    /// The exchange that pool is on ("Raydium", "Orca", "Pump"), then the others the token trades on.
    var exchanges: [SolanaExchange] = []
    var imageURL: URL?
    var decimals: Int?

    /// Where the token mostly trades.
    var exchange: String? { exchanges.first?.name }

    /// The main exchange with a count of the rest: "Orca +5".
    var exchangeLabel: String? {
        exchange.map { exchanges.count > 1 ? "\($0) +\(exchanges.count - 1)" : $0 }
    }
}

/// What a token is beyond its price: who can still change it, how concentrated it is, and where to read about it.
struct SolanaTokenDetails: Equatable, Sendable {
    /// The address that can still mint more, or nil when that was given up.
    var mintAuthority: String?
    /// The address that can freeze holders' tokens, or nil when that was given up.
    var freezeAuthority: String?
    /// Share of supply held by the ten largest holders, in percent.
    var top10Percent: Double?
    var isScam = false
    var createdAt: Date?
    var creator: String?
    var description = ""
    /// In display order: X, website, Telegram, Discord.
    var links: [(label: String, url: URL)] = []

    static func == (lhs: SolanaTokenDetails, rhs: SolanaTokenDetails) -> Bool {
        lhs.mintAuthority == rhs.mintAuthority && lhs.freezeAuthority == rhs.freezeAuthority && lhs.top10Percent == rhs.top10Percent
            && lhs.isScam == rhs.isScam && lhs.createdAt == rhs.createdAt && lhs.creator == rhs.creator
            && lhs.description == rhs.description && lhs.links.map(\.url) == rhs.links.map(\.url)
    }
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
    token { address name symbol decimals info { imageThumbUrl imageSmallUrl } }
    priceUSD change24 volume24 liquidity marketCap holders
    pair { address exchangeHash }
    exchanges { name address tradeUrl }
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

    static func details(address: String) async throws -> SolanaTokenDetails? {
        let query = """
        query($tokens: [String]) {
          filterTokens(tokens: $tokens, limit: 1) {
            results { token {
              isScam mintable freezable top10HoldersPercent createdAt creatorAddress
              socialLinks { twitter website telegram discord }
              info { description }
            } }
          }
        }
        """
        let data = try await post(query, variables: ["tokens": ["\(address):\(network)"]])
        let rows = (data["filterTokens"] as? [String: Any])?["results"] as? [[String: Any]] ?? []
        guard let token = rows.first?["token"] as? [String: Any] else { return nil }
        var details = SolanaTokenDetails()
        details.mintAuthority = token["mintable"] as? String
        details.freezeAuthority = token["freezable"] as? String
        details.top10Percent = (token["top10HoldersPercent"] as? NSNumber)?.doubleValue
        details.isScam = token["isScam"] as? Bool ?? false
        details.createdAt = (token["createdAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
        details.creator = token["creatorAddress"] as? String
        details.description = (token["info"] as? [String: Any])?["description"] as? String ?? ""
        let social = token["socialLinks"] as? [String: Any] ?? [:]
        for (label, key) in [("X", "twitter"), ("WEB", "website"), ("TELEGRAM", "telegram"), ("DISCORD", "discord")] {
            // Only real web links: the page is shown inside the app.
            if let text = social[key] as? String, let url = URL(string: text), url.scheme == "https" || url.scheme == "http" {
                details.links.append((label, url))
            }
        }
        return details
    }

    /// The most traded tokens with real liquidity behind them, for the palette before anything is typed.
    static func top(limit: Int = 40) async throws -> [SolanaStats] {
        let query = """
        query($limit: Int) {
          filterTokens(filters: { network: [\(network)], liquidity: { gt: 100000 } }, rankings: { attribute: volume24, direction: DESC }, limit: $limit) {
            results { \(resultFields) }
          }
        }
        """
        let data = try await post(query, variables: ["limit": limit])
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

    /// Live figures for several tokens at once (at most 200).
    static func stats(addresses: [String]) async throws -> [SolanaStats] {
        guard !addresses.isEmpty else { return [] }
        let query = """
        query($tokens: [String], $limit: Int) {
          filterTokens(tokens: $tokens, limit: $limit) { results { \(resultFields) } }
        }
        """
        let data = try await post(query, variables: ["tokens": addresses.map { "\($0):\(network)" }, "limit": min(addresses.count, 200)])
        return results(in: data)
    }

    /// A wallet's latest swaps of any token, newest first, as raw events.
    static func makerEvents(maker: String, limit: Int = 200) async throws -> [[String: Any]] {
        let query = """
        query($maker: String!, $limit: Int) {
          getTokenEventsForMaker(query: { maker: $maker, networkId: \(network), eventType: Swap }, limit: $limit, direction: DESC) {
            items {
              timestamp token0Address token1Address quoteToken eventDisplayType transactionHash
              data { ... on SwapEventData { amount0 amount1 priceUsdTotal amountNonLiquidityToken } }
            }
          }
        }
        """
        let data = try await post(query, variables: ["maker": maker, "limit": limit])
        return ((data["getTokenEventsForMaker"] as? [String: Any])?["items"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
    }

    /// A wallet's swaps of one token, as signed amounts with their dollar value. The latest 400.
    static func trades(maker: String, mint: String, decimals: Int) async throws -> [SolanaTrade] {
        let query = """
        query($maker: String!, $token: String, $cursor: String) {
          getTokenEventsForMaker(query: { maker: $maker, networkId: \(network), tokenAddress: $token, eventType: Swap },
                                 limit: 200, cursor: $cursor, direction: DESC) {
            cursor
            items {
              timestamp token0Address token1Address quoteToken eventDisplayType
              data { ... on SwapEventData { amount0 amount1 priceUsdTotal amountNonLiquidityToken } }
            }
          }
        }
        """
        var trades: [SolanaTrade] = []
        var cursor: String?
        for _ in 0..<2 {
            var variables: [String: Any] = ["maker": maker, "token": mint]
            if let cursor { variables["cursor"] = cursor }
            let page = (try await post(query, variables: variables))["getTokenEventsForMaker"] as? [String: Any]
            let items = page?["items"] as? [Any] ?? []
            trades += items.compactMap { trade(in: $0 as? [String: Any] ?? [:], mint: mint, decimals: decimals) }
            cursor = page?["cursor"] as? String
            if cursor == nil || items.count < 200 { break }
        }
        return trades
    }

    /// Pool amounts are from the pool's side: what it paid out is negative, and is what the wallet received.
    static func trade(in item: [String: Any], mint: String, decimals: Int) -> SolanaTrade? {
        guard let swap = item["data"] as? [String: Any] else { return nil }
        let usd = number(swap["priceUsdTotal"])
        let side = item["token0Address"] as? String == mint ? "0" : (item["token1Address"] as? String == mint ? "1" : nil)
        guard let side, usd > 0 else { return nil }
        var amount = -number(swap["amount\(side)"]) / pow(10, Double(decimals))
        if amount == 0, item["quoteToken"] as? String == "token\(side)" {
            // Some pools report no raw amounts; the priced token's size and direction are still given.
            let isBuy = (item["eventDisplayType"] as? String ?? "").lowercased().contains("buy")
            amount = abs(number(swap["amountNonLiquidityToken"])) * (isBuy ? 1 : -1)
        }
        guard amount != 0 else { return nil }
        return SolanaTrade(amount: amount, usd: usd, time: Int(number(item["timestamp"])))
    }

    private static func results(in data: [String: Any]) -> [SolanaStats] {
        let rows = (data["filterTokens"] as? [String: Any])?["results"] as? [[String: Any]] ?? []
        return rows.compactMap { row in
            guard let token = row["token"] as? [String: Any], let address = token["address"] as? String else { return nil }
            let info = token["info"] as? [String: Any]
            let pair = row["pair"] as? [String: Any]
            // The top pool's exchange first: it is where the price and the tape come from.
            let listed = (row["exchanges"] as? [[String: Any]] ?? []).filter { !(($0["name"] as? String) ?? "").isEmpty }
            let home = pair?["exchangeHash"] as? String
            var exchanges: [SolanaExchange] = []
            for exchange in listed.filter({ $0["address"] as? String == home }) + listed {
                guard let name = exchange["name"] as? String, !exchanges.contains(where: { $0.name == name }) else { continue }
                // Only real web links: the page is shown inside the app.
                let url = (exchange["tradeUrl"] as? String).flatMap(URL.init).flatMap { $0.scheme == "https" ? $0 : nil }
                exchanges.append(SolanaExchange(name: name, tradeURL: url))
            }
            let image = (info?["imageThumbUrl"] as? String ?? info?["imageSmallUrl"] as? String).flatMap(URL.init)
            return SolanaStats(
                token: SolanaToken(address: address, symbol: token["symbol"] as? String ?? "?", name: token["name"] as? String ?? ""),
                price: number(row["priceUSD"]), change24: number(row["change24"]), volume24: number(row["volume24"]),
                liquidity: number(row["liquidity"]), marketCap: number(row["marketCap"]),
                holders: (row["holders"] as? NSNumber)?.intValue,
                pairAddress: pair?["address"] as? String,
                exchanges: exchanges,
                imageURL: image,
                decimals: (token["decimals"] as? NSNumber)?.intValue
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
    /// A pool prices one of its two tokens; with the mint and its decimals the swap is read from this token's side whichever it is.
    static func trades(pair: String, symbol: String, mint: String? = nil, decimals: Int? = nil, limit: Int = 60) async throws -> [HLTrade] {
        let query = """
        query($address: String!, $limit: Int) {
          getTokenEvents(query: { address: $address, networkId: \(network), eventType: Swap }, limit: $limit, direction: DESC) {
            items {
              timestamp eventDisplayType token0Address token1Address quoteToken transactionHash
              data { ... on SwapEventData { priceUsd priceUsdTotal amountNonLiquidityToken amount0 amount1 } }
            }
          }
        }
        """
        let data = try await post(query, variables: ["address": pair, "limit": limit])
        let items = (data["getTokenEvents"] as? [String: Any])?["items"] as? [Any] ?? []
        return items.compactMap { tapeTrade($0, symbol: symbol, mint: mint, decimals: decimals) }
    }

    /// Swaps pushed by the pool's live subscription, in the same form as `trades`.
    static func liveTrades(in payload: Data, symbol: String, mint: String?, decimals: Int?) throws -> [HLTrade] {
        guard let root = try JSONSerialization.jsonObject(with: payload) as? [String: Any] else { return [] }
        if let errors = root["errors"] as? [[String: Any]], let message = errors.first?["message"] as? String {
            throw CodexError.graphQL(message)
        }
        let data = root["data"] as? [String: Any]
        let events = ((data?["onTokenEventsCreated"] ?? data?["onEventsCreated"]) as? [String: Any])?["events"] as? [Any] ?? []
        return events.compactMap { tapeTrade($0, symbol: symbol, mint: mint, decimals: decimals) }
    }

    private static func tapeTrade(_ item: Any, symbol: String, mint: String?, decimals: Int?) -> HLTrade? {
        guard let item = item as? [String: Any], let swap = item["data"] as? [String: Any] else { return nil }
        // One transaction can hold several swaps in the pool, so the amounts are part of what tells them apart.
        let id = "\(item["transactionHash"] ?? "")|\(item["timestamp"] ?? 0)|\(swap["amount0"] ?? "")|\(swap["amount1"] ?? "")|\(swap["priceUsdTotal"] ?? "")"
        if let mint, let decimals {
            guard let own = trade(in: item, mint: mint, decimals: decimals) else { return nil }
            return HLTrade(
                tid: stableID(id), coin: symbol, isBuy: own.amount > 0,
                px: own.usd / abs(own.amount), sz: abs(own.amount), time: Int64(own.time) * 1_000
            )
        }
        let price = number(swap["priceUsd"])
        var size = abs(number(swap["amountNonLiquidityToken"]))
        if size == 0, price > 0 { size = number(swap["priceUsdTotal"]) / price }
        guard price > 0, size > 0 else { return nil }
        return HLTrade(
            tid: stableID(id), coin: symbol, isBuy: (item["eventDisplayType"] as? String ?? "").lowercased().contains("buy"),
            px: price, sz: size, time: Int64(number(item["timestamp"])) * 1_000
        )
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
