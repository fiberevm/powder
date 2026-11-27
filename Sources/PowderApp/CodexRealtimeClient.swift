import Foundation

enum CodexStreamEvent: Sendable {
    case connected
    case filter(
        updates: [TokenSnapshot],
        removedTokenIDs: [String],
        replacesCurrentSet: Bool
    )
    case launchpad([LaunchpadRealtimePatch])
}

struct LaunchpadRealtimePatch: Sendable {
    let address: String
    let name: String?
    let symbol: String?
    let imageURL: URL?
    let launchpadName: String?
    let createdAt: Date?
    let graduationPercent: Double?
    let migrated: Bool?
    let priceUSD: Double?
    let liquidityUSD: Double?
    let marketCapUSD: Double?
    let holders: Int?
    let suspiciousHeldPercent: Double?
    let sniperHeldPercent: Double?
    let insiderHeldPercent: Double?
    let developerHeldPercent: Double?
    let topTenHeldPercent: Double?
    let eventType: String

    func applying(to existing: TokenSnapshot?) -> TokenSnapshot {
        var result = existing ?? TokenSnapshot(
            address: address,
            name: name ?? "New launch",
            symbol: symbol ?? "—",
            imageURL: imageURL,
            launchpadName: launchpadName ?? "Launchpad",
            createdAt: createdAt ?? Date(),
            graduationPercent: graduationPercent ?? 0,
            migrated: migrated ?? (eventType == "Migrated"),
            priceUSD: priceUSD ?? 0,
            change5m: 0,
            change1h: 0,
            change24h: 0,
            volume24h: 0,
            liquidityUSD: liquidityUSD ?? 0,
            marketCapUSD: marketCapUSD ?? 0,
            holders: holders ?? 0,
            transactionCount24h: 0,
            buyCount24h: 0,
            sellCount24h: 0,
            suspiciousHeldPercent: suspiciousHeldPercent ?? 0,
            sniperHeldPercent: sniperHeldPercent ?? 0,
            insiderHeldPercent: insiderHeldPercent ?? 0,
            developerHeldPercent: developerHeldPercent ?? 0,
            topTenHeldPercent: topTenHeldPercent ?? 0,
            potentialScamReasons: [],
            description: nil,
            isDemo: false
        )

        if let name, !name.isEmpty { result.name = name }
        if let symbol, !symbol.isEmpty { result.symbol = symbol }
        if let imageURL { result.imageURL = imageURL }
        if let launchpadName { result.launchpadName = launchpadName }
        if let createdAt { result.createdAt = createdAt }
        if let graduationPercent {
            result.graduationPercent = min(max(graduationPercent, 0), 100)
        }
        if let migrated { result.migrated = migrated }
        if eventType == "Migrated" {
            result.migrated = true
            result.graduationPercent = max(result.graduationPercent, 100)
        }
        if let priceUSD { result.priceUSD = priceUSD }
        if let liquidityUSD { result.liquidityUSD = liquidityUSD }
        if let marketCapUSD { result.marketCapUSD = marketCapUSD }
        if let holders { result.holders = holders }
        if let suspiciousHeldPercent { result.suspiciousHeldPercent = suspiciousHeldPercent }
        if let sniperHeldPercent { result.sniperHeldPercent = sniperHeldPercent }
        if let insiderHeldPercent { result.insiderHeldPercent = insiderHeldPercent }
        if let developerHeldPercent { result.developerHeldPercent = developerHeldPercent }
        if let topTenHeldPercent { result.topTenHeldPercent = topTenHeldPercent }
        result.isDemo = false
        return result
    }
}

extension CodexClient {
    func launchpadStream(apiKey: String) -> AsyncThrowingStream<CodexStreamEvent, Error> {
        let operations = [
            WebSocketOperation(
                id: "filter-tokens",
                operationName: "PowderFilterTokenUpdates",
                query: Self.filterSubscription
            ),
            WebSocketOperation(
                id: "launchpad-events",
                operationName: "PowderLaunchpadEvents",
                query: Self.launchpadEventSubscription
            )
        ]
        let socketStream = graphQLStream(apiKey: apiKey, operations: operations)

        return AsyncThrowingStream { continuation in
            let worker = Task {
                var isFirstFilterMessage = true

                do {
                    for try await event in socketStream {
                        try Task.checkCancellation()

                        switch event {
                        case .connected:
                            continuation.yield(.connected)

                        case let .next(id, payload):
                            if id == "filter-tokens" {
                                let response = try JSONDecoder().decode(
                                    GraphQLResponse<FilterSubscriptionData>.self,
                                    from: payload
                                )
                                try Self.throwIfGraphQLErrors(response.errors)

                                if let update = response.data?.onFilterTokensUpdated {
                                    continuation.yield(
                                        .filter(
                                            updates: update.updates.compactMap(\.snapshot),
                                            removedTokenIDs: update.removedTokenIds ?? [],
                                            replacesCurrentSet: isFirstFilterMessage
                                        )
                                    )
                                    isFirstFilterMessage = false
                                }
                            } else if id == "launchpad-events" {
                                let response = try JSONDecoder().decode(
                                    GraphQLResponse<LaunchpadSubscriptionData>.self,
                                    from: payload
                                )
                                try Self.throwIfGraphQLErrors(response.errors)

                                if let events = response.data?.onLaunchpadTokenEventBatch {
                                    continuation.yield(.launchpad(events.map(\.patch)))
                                }
                            }
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { @Sendable _ in
                worker.cancel()
            }
        }
    }

    /// Swaps as they happen, as the raw reply: across every pool of a token, or in one pool.
    /// Ends with an error when the socket drops.
    func eventStream(token: String? = nil, pair: String = "", apiKey: String) -> AsyncThrowingStream<Data, Error> {
        let socketStream = graphQLStream(apiKey: apiKey, operations: [
            token.map {
                WebSocketOperation(
                    id: "token-events", operationName: "PowderTokenEvents",
                    query: Self.tokenEventSubscription, variables: ["address": $0]
                )
            } ?? WebSocketOperation(
                id: "pair-events", operationName: "PowderPairEvents",
                query: Self.pairEventSubscription, variables: ["address": pair]
            ),
        ])
        return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(64)) { continuation in
            let worker = Task {
                do {
                    for try await event in socketStream {
                        if case let .next(_, payload) = event { continuation.yield(payload) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in worker.cancel() }
        }
    }

    static let tokenEventSubscription = """
    subscription PowderTokenEvents($address: String!) {
      onTokenEventsCreated(input: { tokenAddress: $address, networkId: \(solanaNetworkID) }) {
        events {
          timestamp eventDisplayType token0Address token1Address quoteToken transactionHash
          data { ... on SwapEventData { priceUsd priceUsdTotal amountNonLiquidityToken amount0 amount1 } }
        }
      }
    }
    """

    static let pairEventSubscription = """
    subscription PowderPairEvents($address: String!) {
      onEventsCreated(address: $address, networkId: \(solanaNetworkID)) {
        events {
          timestamp eventDisplayType token0Address token1Address quoteToken transactionHash
          data { ... on SwapEventData { priceUsd priceUsdTotal amountNonLiquidityToken amount0 amount1 } }
        }
      }
    }
    """

    func tokenDetailStream(
        for address: String,
        timeframe: ChartTimeframe,
        apiKey: String
    ) -> AsyncThrowingStream<TokenDetailStreamEvent, Error> {
        let tokenID = "\(address):\(Self.solanaNetworkID)"
        let operations = [
            WebSocketOperation(
                id: "token-bars",
                operationName: "PowderTokenBarUpdates",
                query: Self.tokenBarSubscription(for: timeframe),
                variables: ["tokenId": tokenID]
            ),
            WebSocketOperation(
                id: "token-holders",
                operationName: "PowderTokenHolderUpdates",
                query: Self.tokenHolderSubscription,
                variables: ["tokenId": tokenID]
            )
        ]
        let socketStream = graphQLStream(apiKey: apiKey, operations: operations)

        return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(8)) { continuation in
            let worker = Task {
                do {
                    for try await event in socketStream {
                        try Task.checkCancellation()

                        switch event {
                        case .connected:
                            continuation.yield(.connected)

                        case let .next(id, payload):
                            if id == "token-bars" {
                                let response = try JSONDecoder().decode(
                                    GraphQLResponse<TokenBarSubscriptionData>.self,
                                    from: payload
                                )
                                try Self.throwIfGraphQLErrors(response.errors)

                                if let point = response.data?
                                    .onTokenBarsUpdated
                                    .aggregates
                                    .point(for: timeframe) {
                                    continuation.yield(.bar(point))
                                }
                            } else if id == "token-holders" {
                                let response = try JSONDecoder().decode(
                                    GraphQLResponse<TokenHolderSubscriptionData>.self,
                                    from: payload
                                )
                                try Self.throwIfGraphQLErrors(response.errors)

                                if let holders = response.data?.onHoldersUpdated.holders {
                                    continuation.yield(.holders(holders))
                                }
                            }
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { @Sendable _ in
                worker.cancel()
            }
        }
    }
}

private extension CodexClient {
    static let webSocketEndpoint = URL(string: "wss://graph.codex.io/graphql")!

    static let filterSubscription = """
    subscription PowderFilterTokenUpdates {
      onFilterTokensUpdated(
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
        updatePeriod: 1000
        limit: 200
      ) {
        removedTokenIds
        updates {
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

    static let launchpadEventSubscription = """
    subscription PowderLaunchpadEvents {
      onLaunchpadTokenEventBatch(input: { networkId: 1399811149 }) {
        address
        eventType
        launchpadName
        marketCap
        price
        liquidity
        holders
        suspiciousHeldPercentage
        sniperHeldPercentage
        insiderHeldPercentage
        devHeldPercentage
        top10HoldersPercent
        token {
          address
          name
          symbol
          createdAt
          launchpad {
            launchpadName
            graduationPercent
            migrated
          }
          info {
            imageSmallUrl
          }
        }
      }
    }
    """

    static func tokenBarSubscription(for timeframe: ChartTimeframe) -> String {
        """
        subscription PowderTokenBarUpdates($tokenId: String!) {
          onTokenBarsUpdated(tokenId: $tokenId) {
            aggregates {
              \(timeframe.subscriptionField) {
                t
                usd {
                  t
                  o
                  h
                  l
                  c
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
            }
          }
        }
        """
    }

    static let tokenHolderSubscription = """
    subscription PowderTokenHolderUpdates($tokenId: String!) {
      onHoldersUpdated(tokenId: $tokenId) {
        holders
        tokenId
        tokenAddress
        networkId
      }
    }
    """

    static func throwIfGraphQLErrors(_ errors: [GraphQLError]?) throws {
        guard let errors, !errors.isEmpty else { return }
        let message = errors.map(\.message).joined(separator: "\n")
        if message.localizedCaseInsensitiveContains("upgrade")
            || message.localizedCaseInsensitiveContains("not authorized") {
            throw CodexError.subscriptionUnavailable
        }
        throw CodexError.graphQL(message)
    }

    func graphQLStream(
        apiKey: String,
        operations: [WebSocketOperation]
    ) -> AsyncThrowingStream<GraphQLSocketEvent, Error> {
        AsyncThrowingStream { continuation in
            let socket = session.webSocketTask(
                with: Self.webSocketEndpoint,
                protocols: ["graphql-transport-ws"]
            )

            let worker = Task {
                var heartbeat: Task<Void, Never>?

                defer {
                    heartbeat?.cancel()
                    socket.cancel(with: .goingAway, reason: nil)
                }

                do {
                    socket.resume()
                    try await Self.send(
                        [
                            "type": "connection_init",
                            "payload": ["Authorization": apiKey]
                        ],
                        through: socket
                    )

                    while !Task.isCancelled {
                        let message = try await socket.receive()
                        let data: Data
                        switch message {
                        case let .data(value):
                            data = value
                        case let .string(value):
                            data = Data(value.utf8)
                        @unknown default:
                            throw CodexError.invalidResponse
                        }

                        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let type = object["type"] as? String else {
                            throw CodexError.invalidResponse
                        }

                        switch type {
                        case "connection_ack":
                            continuation.yield(.connected)

                            for operation in operations {
                                try await Self.send(
                                    operation.subscribeMessage,
                                    through: socket
                                )
                            }

                            heartbeat = Task {
                                while !Task.isCancelled {
                                    try? await Task.sleep(for: .seconds(20))
                                    guard !Task.isCancelled else { return }
                                    try? await Self.send(["type": "ping"], through: socket)
                                }
                            }

                        case "next":
                            guard let id = object["id"] as? String,
                                  let payload = object["payload"] else {
                                throw CodexError.invalidResponse
                            }
                            let payloadData = try JSONSerialization.data(withJSONObject: payload)
                            continuation.yield(.next(id: id, payload: payloadData))

                        case "ping":
                            try await Self.send(["type": "pong"], through: socket)

                        case "pong":
                            break

                        case "error", "connection_error":
                            let message = Self.describe(object["payload"])
                            if message.localizedCaseInsensitiveContains("upgrade")
                                || message.localizedCaseInsensitiveContains("forbidden")
                                || message.localizedCaseInsensitiveContains("not authorized") {
                                throw CodexError.subscriptionUnavailable
                            }
                            throw CodexError.graphQL(message)

                        case "complete":
                            break

                        default:
                            break
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    let closeCode = Int(socket.closeCode.rawValue)
                    if closeCode == 4_403 {
                        continuation.finish(throwing: CodexError.subscriptionUnavailable)
                    } else {
                        let reason = socket.closeReason
                            .flatMap { String(data: $0, encoding: .utf8) }
                            ?? error.localizedDescription
                        let normalizedCode = closeCode == 0 ? nil : closeCode
                        continuation.finish(
                            throwing: CodexError.webSocket(normalizedCode, reason)
                        )
                    }
                }
            }

            continuation.onTermination = { @Sendable _ in
                worker.cancel()
                socket.cancel(with: .goingAway, reason: nil)
            }
        }
    }

    static func send(
        _ object: [String: Any],
        through socket: URLSessionWebSocketTask
    ) async throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        guard let message = String(data: data, encoding: .utf8) else {
            throw CodexError.invalidResponse
        }
        try await socket.send(.string(message))
    }

    static func describe(_ payload: Any?) -> String {
        guard let payload,
              JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let value = String(data: data, encoding: .utf8) else {
            return "Unknown subscription error"
        }
        return value
    }
}

private enum GraphQLSocketEvent: Sendable {
    case connected
    case next(id: String, payload: Data)
}

private struct WebSocketOperation: Sendable {
    let id: String
    let operationName: String
    let query: String
    var variables: [String: String] = [:]

    var subscribeMessage: [String: Any] {
        [
            "id": id,
            "type": "subscribe",
            "payload": [
                "variables": variables,
                "extensions": [:],
                "operationName": operationName,
                "query": query
            ] as [String: Any]
        ]
    }
}

private struct FilterSubscriptionData: Decodable {
    let onFilterTokensUpdated: FilterTokenUpdatesDTO
}

private struct FilterTokenUpdatesDTO: Decodable {
    let removedTokenIds: [String]?
    let updates: [TokenFilterResultDTO]
}

private struct LaunchpadSubscriptionData: Decodable {
    let onLaunchpadTokenEventBatch: [LaunchpadEventDTO]
}

private struct LaunchpadEventDTO: Decodable {
    let address: String
    let eventType: String
    let launchpadName: String?
    let marketCap: String?
    let price: Double?
    let liquidity: String?
    let holders: Int?
    let suspiciousHeldPercentage: Double?
    let sniperHeldPercentage: Double?
    let insiderHeldPercentage: Double?
    let devHeldPercentage: Double?
    let top10HoldersPercent: Double?
    let token: LaunchpadEventTokenDTO?

    var patch: LaunchpadRealtimePatch {
        LaunchpadRealtimePatch(
            address: address,
            name: token?.name,
            symbol: token?.symbol,
            imageURL: token?.info?.imageSmallUrl.flatMap(URL.init(string:)),
            launchpadName: launchpadName ?? token?.launchpad?.launchpadName,
            createdAt: token?.createdAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            graduationPercent: token?.launchpad?.graduationPercent,
            migrated: token?.launchpad?.migrated,
            priceUSD: price,
            liquidityUSD: liquidity.flatMap(Double.init),
            marketCapUSD: marketCap.flatMap(Double.init),
            holders: holders,
            suspiciousHeldPercent: suspiciousHeldPercentage,
            sniperHeldPercent: sniperHeldPercentage,
            insiderHeldPercent: insiderHeldPercentage,
            developerHeldPercent: devHeldPercentage,
            topTenHeldPercent: top10HoldersPercent,
            eventType: eventType
        )
    }
}

private struct LaunchpadEventTokenDTO: Decodable {
    let name: String?
    let symbol: String?
    let createdAt: Int?
    let launchpad: LaunchpadDTO?
    let info: TokenInfoDTO?
}

private struct TokenBarSubscriptionData: Decodable {
    let onTokenBarsUpdated: TokenBarUpdateDTO
}

private struct TokenBarUpdateDTO: Decodable {
    let aggregates: TokenBarAggregatesDTO
}

private struct TokenBarAggregatesDTO: Decodable {
    let r1: TokenResolutionDTO?
    let r5: TokenResolutionDTO?
    let r15: TokenResolutionDTO?
    let r60: TokenResolutionDTO?
    let r240: TokenResolutionDTO?

    func point(for timeframe: ChartTimeframe) -> PricePoint? {
        let resolution: TokenResolutionDTO?
        switch timeframe {
        case .hour:
            resolution = r1
        case .sixHours:
            resolution = r5
        case .day:
            resolution = r15
        case .week:
            resolution = r60
        case .month:
            resolution = r240
        }

        guard let bar = resolution?.usd else { return nil }
        return PricePoint(
            timestamp: Date(timeIntervalSince1970: TimeInterval(bar.t)),
            open: bar.o,
            high: bar.h,
            low: bar.l,
            close: bar.c,
            volume: bar.volume.flatMap(Double.init) ?? 0,
            buyers: bar.buyers,
            sellers: bar.sellers,
            buys: bar.buys,
            sells: bar.sells,
            buyVolume: bar.buyVolume.flatMap(Double.init),
            sellVolume: bar.sellVolume.flatMap(Double.init),
            liquidityUSD: bar.liquidity.flatMap(Double.init),
            transactions: bar.transactions
        )
    }
}

private struct TokenResolutionDTO: Decodable {
    let t: Int?
    let usd: TokenCurrencyBarDTO?
}

private struct TokenCurrencyBarDTO: Decodable {
    let t: Int
    let o: Double
    let h: Double
    let l: Double
    let c: Double
    let volume: String?
    let buyers: Int?
    let sellers: Int?
    let buys: Int?
    let sells: Int?
    let buyVolume: String?
    let sellVolume: String?
    let liquidity: String?
    let transactions: Int?
}

private struct TokenHolderSubscriptionData: Decodable {
    let onHoldersUpdated: TokenHolderUpdateDTO
}

private struct TokenHolderUpdateDTO: Decodable {
    let holders: Int
}
