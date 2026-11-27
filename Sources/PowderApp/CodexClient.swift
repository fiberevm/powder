import Foundation

struct CodexClient: Sendable {
    static let endpoint = URL(string: "https://graph.codex.io/graphql")!
    static let solanaNetworkID = 1_399_811_149

    var session: URLSession = .shared

    func fetchLaunchpadTokens(apiKey: String) async throws -> [TokenSnapshot] {
        let response: GraphQLResponse<FilterTokensData> = try await post(
            apiKey: apiKey,
            request: GraphQLRequest(
                query: Self.launchpadQuery,
                variables: EmptyVariables()
            )
        )

        if let errors = response.errors, !errors.isEmpty {
            throw CodexError.graphQL(errors.map(\.message).joined(separator: "\n"))
        }

        guard let results = response.data?.filterTokens.results else {
            throw CodexError.invalidResponse
        }

        let tokens = results.compactMap(\.snapshot)
        guard !tokens.isEmpty else {
            throw CodexError.noResults
        }
        return tokens
    }

    func fetchBars(
        for address: String,
        timeframe: ChartTimeframe,
        apiKey: String,
        now: Date = Date()
    ) async throws -> [PricePoint] {
        let to = Int(now.timeIntervalSince1970)
        let from = to - Int(timeframe.seconds)
        let response: GraphQLResponse<TokenBarsData> = try await post(
            apiKey: apiKey,
            request: GraphQLRequest(
                query: Self.barsQuery,
                variables: BarsVariables(
                    symbol: "\(address):\(Self.solanaNetworkID)",
                    from: from,
                    to: to,
                    resolution: timeframe.resolution,
                    countback: timeframe.countback
                )
            )
        )

        if let errors = response.errors, !errors.isEmpty {
            throw CodexError.graphQL(errors.map(\.message).joined(separator: "\n"))
        }

        guard let bars = response.data?.getTokenBars else {
            throw CodexError.invalidResponse
        }

        let count = [bars.t.count, bars.o.count, bars.h.count, bars.l.count, bars.c.count].min() ?? 0
        guard count > 1 else { throw CodexError.noResults }

        return (0..<count).map { index in
            PricePoint(
                timestamp: Date(timeIntervalSince1970: TimeInterval(bars.t[index])),
                open: bars.o[index],
                high: bars.h[index],
                low: bars.l[index],
                close: bars.c[index],
                volume: (bars.volume?[safe: index] ?? nil).flatMap(Double.init) ?? 0,
                buyers: bars.buyers?[safe: index] ?? nil,
                sellers: bars.sellers?[safe: index] ?? nil,
                buys: bars.buys?[safe: index] ?? nil,
                sells: bars.sells?[safe: index] ?? nil,
                buyVolume: (bars.buyVolume?[safe: index] ?? nil).flatMap(Double.init),
                sellVolume: (bars.sellVolume?[safe: index] ?? nil).flatMap(Double.init),
                liquidityUSD: (bars.liquidity?[safe: index] ?? nil).flatMap(Double.init),
                transactions: bars.transactions?[safe: index] ?? nil
            )
        }
    }

    private func post<Response: Decodable, Variables: Encodable>(
        apiKey: String,
        request: GraphQLRequest<Variables>
    ) async throws -> Response {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CodexError.missingAPIKey
        }

        var urlRequest = URLRequest(url: Self.endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Codex uses the raw API key here—there is intentionally no Bearer prefix.
        urlRequest.setValue(apiKey, forHTTPHeaderField: "Authorization")
        urlRequest.timeoutInterval = 20
        urlRequest.httpBody = try JSONEncoder().encode(request)

        let (data, response) = try await session.data(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CodexError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                throw CodexError.unauthorized
            }
            throw CodexError.httpStatus(httpResponse.statusCode)
        }

        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw CodexError.decoding(error.localizedDescription)
        }
    }
}

enum CodexError: LocalizedError {
    case missingAPIKey
    case unauthorized
    case subscriptionUnavailable
    case httpStatus(Int)
    case graphQL(String)
    case decoding(String)
    case webSocket(Int?, String)
    case invalidResponse
    case noResults

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            "Add a Codex API key in Settings."
        case .unauthorized:
            "Codex rejected the API key. Check it in Settings and try again."
        case .subscriptionUnavailable:
            "This Codex key cannot open subscriptions. Growth or Enterprise access is required."
        case let .httpStatus(status):
            "Codex returned HTTP \(status). Try again shortly."
        case let .graphQL(message):
            "Codex query error: \(message)"
        case let .decoding(message):
            "Codex returned data Powder could not read: \(message)"
        case let .webSocket(code, message):
            if let code {
                "Codex WebSocket closed with \(code): \(message)"
            } else {
                "Codex WebSocket disconnected: \(message)"
            }
        case .invalidResponse:
            "Codex returned an incomplete response."
        case .noResults:
            "Codex returned no matching Solana launchpad tokens."
        }
    }
}

private extension CodexClient {
    static let launchpadQuery = """
    query PowderLaunchpad {
      filterTokens(
        filters: {
          network: 1399811149
          includeScams: false
          potentialScam: false
          trendingIgnored: false
          boolFilter: {
            or: [
              { launchpadCompleted: false }
              { launchpadMigrated: true }
              { launchpadGraduationPercent: { gte: 0 } }
            ]
          }
        }
        rankings: { attribute: createdAt, direction: DESC }
        statsType: FILTERED
        useAggregatedStats: true
        limit: 200
      ) {
        results {
          token {
            address
            name
            symbol
            createdAt
            launchpad {
              launchpadName
              graduationPercent
              completed
              migrated
              migratedAt
            }
            info {
              imageSmallUrl
              description
            }
            top10HoldersPercent
          }
          priceUSD
          change5m
          change1
          change24
          volume24
          liquidity
          marketCap
          holders
          txnCount24
          buyCount24
          sellCount24
          suspiciousHeldPercentage
          sniperHeldPercentage
          insiderHeldPercentage
          devHeldPercentage
          potentialScamReasons
        }
      }
    }
    """

    static let barsQuery = """
    query PowderTokenBars(
      $symbol: String!
      $from: Int!
      $to: Int!
      $resolution: String!
      $countback: Int!
    ) {
      getTokenBars(
        symbol: $symbol
        from: $from
        to: $to
        resolution: $resolution
        countback: $countback
        removeLeadingNullValues: true
        removeEmptyBars: true
        statsType: FILTERED
      ) {
        o
        h
        l
        c
        t
        volume
        buyers
        sellers
        buys
        sells
        buyVolume
        sellVolume
        liquidity
        transactions
      }
    }
    """
}

private struct GraphQLRequest<Variables: Encodable>: Encodable {
    let query: String
    let variables: Variables
}

private struct EmptyVariables: Encodable {}

private struct BarsVariables: Encodable {
    let symbol: String
    let from: Int
    let to: Int
    let resolution: String
    let countback: Int
}

struct GraphQLResponse<DataType: Decodable>: Decodable {
    let data: DataType?
    let errors: [GraphQLError]?
}

struct GraphQLError: Decodable {
    let message: String
}

private struct FilterTokensData: Decodable {
    let filterTokens: FilterTokensConnection
}

private struct FilterTokensConnection: Decodable {
    let results: [TokenFilterResultDTO]
}

struct TokenFilterResultDTO: Decodable {
    let token: EnhancedTokenDTO?
    let priceUSD: String?
    let change5m: String?
    let change1: String?
    let change24: String?
    let volume24: String?
    let liquidity: String?
    let marketCap: String?
    let holders: Int?
    let txnCount24: Int?
    let buyCount24: Int?
    let sellCount24: Int?
    let suspiciousHeldPercentage: Double?
    let sniperHeldPercentage: Double?
    let insiderHeldPercentage: Double?
    let devHeldPercentage: Double?
    let potentialScamReasons: [String]?

    var snapshot: TokenSnapshot? {
        guard let token else { return nil }
        let launchpad = token.launchpad
        let info = token.info

        return TokenSnapshot(
            address: token.address,
            name: token.name ?? info?.name ?? "Unknown token",
            symbol: token.symbol ?? info?.symbol ?? "—",
            imageURL: info?.imageSmallUrl.flatMap(URL.init(string:)),
            launchpadName: launchpad?.launchpadName ?? "Launchpad",
            createdAt: Date(timeIntervalSince1970: TimeInterval(token.createdAt ?? 0)),
            graduationPercent: min(max(launchpad?.graduationPercent ?? 0, 0), 100),
            migrated: launchpad?.migrated ?? false,
            priceUSD: priceUSD.doubleValue,
            change5m: change5m.doubleValue,
            change1h: change1.doubleValue,
            change24h: change24.doubleValue,
            volume24h: volume24.doubleValue,
            liquidityUSD: liquidity.doubleValue,
            marketCapUSD: marketCap.doubleValue,
            holders: holders ?? 0,
            transactionCount24h: txnCount24 ?? 0,
            buyCount24h: buyCount24 ?? 0,
            sellCount24h: sellCount24 ?? 0,
            suspiciousHeldPercent: suspiciousHeldPercentage ?? 0,
            sniperHeldPercent: sniperHeldPercentage ?? 0,
            insiderHeldPercent: insiderHeldPercentage ?? 0,
            developerHeldPercent: devHeldPercentage ?? 0,
            topTenHeldPercent: token.top10HoldersPercent ?? 0,
            potentialScamReasons: potentialScamReasons ?? [],
            description: info?.description,
            isDemo: false
        )
    }
}

struct EnhancedTokenDTO: Decodable {
    let address: String
    let name: String?
    let symbol: String?
    let createdAt: Int?
    let launchpad: LaunchpadDTO?
    let info: TokenInfoDTO?
    let top10HoldersPercent: Double?
}

struct LaunchpadDTO: Decodable {
    let launchpadName: String?
    let graduationPercent: Double?
    let completed: Bool?
    let migrated: Bool?
    let migratedAt: Int?
}

struct TokenInfoDTO: Decodable {
    let name: String?
    let symbol: String?
    let imageSmallUrl: String?
    let description: String?
}

private struct TokenBarsData: Decodable {
    let getTokenBars: TokenBarsDTO?
}

private struct TokenBarsDTO: Decodable {
    let o: [Double]
    let h: [Double]
    let l: [Double]
    let c: [Double]
    let t: [Int]
    let volume: [String?]?
    let buyers: [Int?]?
    let sellers: [Int?]?
    let buys: [Int?]?
    let sells: [Int?]?
    let buyVolume: [String?]?
    let sellVolume: [String?]?
    let liquidity: [String?]?
    let transactions: [Int?]?
}

private extension Optional where Wrapped == String {
    var doubleValue: Double {
        flatMap(Double.init) ?? 0
    }
}

private extension String {
    var doubleValue: Double { Double(self) ?? 0 }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
