import Foundation

enum SidebarSection: String, CaseIterable, Identifiable {
    case launchpad

    var id: Self { self }

    var title: String {
        switch self {
        case .launchpad: "Launchpad"
        }
    }

    var systemImage: String {
        switch self {
        case .launchpad: "scope"
        }
    }
}

enum DataMode: Equatable {
    case demo
    case live

    var label: String {
        switch self {
        case .demo: "Demo data"
        case .live: "Live Codex"
        }
    }

    var symbol: String {
        switch self {
        case .demo: "testtube.2"
        case .live: "bolt.fill"
        }
    }
}

enum LoadState: Equatable {
    case idle
    case loading
    case loaded
}

enum RealtimeConnectionState: Equatable {
    case demo
    case connecting
    case live
    case reconnecting(attempt: Int)
    case unavailable

    var label: String {
        switch self {
        case .demo: "Demo stream"
        case .connecting: "Connecting"
        case .live: "Streaming"
        case let .reconnecting(attempt): "Reconnecting · \(attempt)"
        case .unavailable: "Snapshot only"
        }
    }

    var symbol: String {
        switch self {
        case .demo: "testtube.2"
        case .connecting, .reconnecting: "arrow.trianglehead.2.clockwise.rotate.90"
        case .live: "dot.radiowaves.left.and.right"
        case .unavailable: "pause.circle"
        }
    }
}

enum LaunchStage: String, CaseIterable, Identifiable, Sendable {
    case bonding
    case closeToMigration
    case migrated

    static let closeThreshold = 80.0

    var id: Self { self }

    var title: String {
        switch self {
        case .bonding: "Bonding"
        case .closeToMigration: "Close to migrating"
        case .migrated: "Migrated"
        }
    }

    var detail: String {
        switch self {
        case .bonding: "Below 80%"
        case .closeToMigration: "80%+ · awaiting migration"
        case .migrated: "DEX pool live"
        }
    }

    var systemImage: String {
        switch self {
        case .bonding: "point.bottomleft.forward.to.point.topright.scurvepath"
        case .closeToMigration: "arrow.up.forward"
        case .migrated: "checkmark.seal.fill"
        }
    }
}

enum RiskLevel: String, Comparable, CaseIterable {
    case clear = "Clear"
    case watch = "Watch"
    case elevated = "Elevated"

    private var order: Int {
        switch self {
        case .clear: 0
        case .watch: 1
        case .elevated: 2
        }
    }

    static func < (lhs: RiskLevel, rhs: RiskLevel) -> Bool {
        lhs.order < rhs.order
    }
}

struct TokenSnapshot: Identifiable, Hashable, Sendable {
    var address: String
    var name: String
    var symbol: String
    var imageURL: URL?
    var launchpadName: String
    var createdAt: Date
    var graduationPercent: Double
    var migrated: Bool
    var priceUSD: Double
    var change5m: Double
    var change1h: Double
    var change24h: Double
    var volume24h: Double
    var liquidityUSD: Double
    var marketCapUSD: Double
    var holders: Int
    var transactionCount24h: Int
    var buyCount24h: Int
    var sellCount24h: Int
    var suspiciousHeldPercent: Double
    var sniperHeldPercent: Double
    var insiderHeldPercent: Double
    var developerHeldPercent: Double
    var topTenHeldPercent: Double
    var potentialScamReasons: [String]
    var description: String?
    var isDemo: Bool

    var id: String { address }

    var lifecycleLabel: String {
        launchStage.title
    }

    var launchStage: LaunchStage {
        if migrated {
            return .migrated
        }
        if graduationPercent >= LaunchStage.closeThreshold {
            return .closeToMigration
        }
        return .bonding
    }

    var riskLevel: RiskLevel {
        if !potentialScamReasons.isEmpty
            || suspiciousHeldPercent >= 20
            || developerHeldPercent >= 15
            || topTenHeldPercent >= 65 {
            return .elevated
        }

        if suspiciousHeldPercent >= 8
            || developerHeldPercent >= 7
            || topTenHeldPercent >= 40 {
            return .watch
        }

        return .clear
    }

    var shortAddress: String {
        guard address.count > 12 else { return address }
        return "\(address.prefix(5))…\(address.suffix(5))"
    }
}

struct PricePoint: Identifiable, Hashable, Sendable {
    let timestamp: Date
    let open: Double
    let high: Double
    let low: Double
    let close: Double
    let volume: Double
    let buyers: Int?
    let sellers: Int?
    let buys: Int?
    let sells: Int?
    let buyVolume: Double?
    let sellVolume: Double?
    let liquidityUSD: Double?
    let transactions: Int?

    init(
        timestamp: Date,
        open: Double,
        high: Double,
        low: Double,
        close: Double,
        volume: Double,
        buyers: Int? = nil,
        sellers: Int? = nil,
        buys: Int? = nil,
        sells: Int? = nil,
        buyVolume: Double? = nil,
        sellVolume: Double? = nil,
        liquidityUSD: Double? = nil,
        transactions: Int? = nil
    ) {
        self.timestamp = timestamp
        self.open = open
        self.high = high
        self.low = low
        self.close = close
        self.volume = volume
        self.buyers = buyers
        self.sellers = sellers
        self.buys = buys
        self.sells = sells
        self.buyVolume = buyVolume
        self.sellVolume = sellVolume
        self.liquidityUSD = liquidityUSD
        self.transactions = transactions
    }

    var id: Date { timestamp }

    var change: Double {
        guard open != 0 else { return 0 }
        return (close - open) / open
    }

    var isUp: Bool {
        close >= open
    }
}

struct TokenRoute: Hashable {
    let token: TokenSnapshot

    static func == (lhs: TokenRoute, rhs: TokenRoute) -> Bool {
        lhs.token.id == rhs.token.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(token.id)
    }
}

enum ChartTimeframe: String, CaseIterable, Identifiable, Sendable {
    case hour
    case sixHours
    case day
    case week
    case month

    var id: Self { self }

    var label: String {
        switch self {
        case .hour: "1H"
        case .sixHours: "6H"
        case .day: "24H"
        case .week: "7D"
        case .month: "30D"
        }
    }

    var seconds: TimeInterval {
        switch self {
        case .hour: 3_600
        case .sixHours: 6 * 3_600
        case .day: 24 * 3_600
        case .week: 7 * 24 * 3_600
        case .month: 30 * 24 * 3_600
        }
    }

    var resolution: String {
        switch self {
        case .hour: "1"
        case .sixHours: "5"
        case .day: "15"
        case .week: "60"
        case .month: "240"
        }
    }

    var subscriptionField: String {
        switch self {
        case .hour: "r1"
        case .sixHours: "r5"
        case .day: "r15"
        case .week: "r60"
        case .month: "r240"
        }
    }

    var countback: Int {
        switch self {
        case .hour: 60
        case .sixHours: 72
        case .day: 96
        case .week: 168
        case .month: 180
        }
    }

    var resolutionLabel: String {
        switch self {
        case .hour: "1-minute"
        case .sixHours: "5-minute"
        case .day: "15-minute"
        case .week: "1-hour"
        case .month: "4-hour"
        }
    }
}

enum TokenDetailStreamEvent: Sendable {
    case connected
    case bar(PricePoint)
    case holders(Int)
}

enum ChartDataSource: Sendable {
    case illustrative
    case codexSnapshot
}

struct ChartLoadResult: Sendable {
    let points: [PricePoint]
    let source: ChartDataSource
}

enum SampleData {
    static let tokens: [TokenSnapshot] = [
        token(
            address: "Demo1111111111111111111111111111111111001",
            name: "Orbit Choir",
            symbol: "ORBIT",
            launchpad: "Pump.fun",
            minutesAgo: 11,
            graduation: 82,
            migrated: false,
            price: 0.000_084_2,
            change5m: 0.038,
            change1h: 0.127,
            change24h: 0.419,
            volume: 612_400,
            liquidity: 94_200,
            marketCap: 842_000,
            holders: 1_842,
            transactions: 4_284,
            buyCount: 2_631,
            sellCount: 1_653,
            suspicious: 4.2,
            sniper: 2.1,
            insider: 1.4,
            developer: 1.8,
            topTen: 28.4,
            description: "Synthetic launch used to demonstrate Powder’s market and lifecycle views."
        ),
        token(
            address: "Demo1111111111111111111111111111111111002",
            name: "Fieldnote",
            symbol: "FIELD",
            launchpad: "LaunchLab",
            minutesAgo: 38,
            graduation: 100,
            migrated: true,
            price: 0.001_284,
            change5m: -0.012,
            change1h: 0.064,
            change24h: 0.188,
            volume: 1_924_000,
            liquidity: 341_000,
            marketCap: 5_420_000,
            holders: 5_806,
            transactions: 10_832,
            buyCount: 5_776,
            sellCount: 5_056,
            suspicious: 6.7,
            sniper: 3.8,
            insider: 2.4,
            developer: 2.1,
            topTen: 31.2,
            description: "Synthetic launch used to demonstrate a migrated token with active liquidity."
        ),
        token(
            address: "Demo1111111111111111111111111111111111003",
            name: "Copper Sky",
            symbol: "COPR",
            launchpad: "Pump.fun",
            minutesAgo: 4,
            graduation: 46,
            migrated: false,
            price: 0.000_019_6,
            change5m: 0.091,
            change1h: 0.091,
            change24h: 0.091,
            volume: 118_600,
            liquidity: 22_800,
            marketCap: 196_000,
            holders: 684,
            transactions: 1_926,
            buyCount: 1_382,
            sellCount: 544,
            suspicious: 12.8,
            sniper: 8.4,
            insider: 4.4,
            developer: 5.2,
            topTen: 43.1,
            description: "Synthetic launch used to demonstrate an early bonding-curve state."
        ),
        token(
            address: "Demo1111111111111111111111111111111111004",
            name: "Nightjar",
            symbol: "NITE",
            launchpad: "Meteora",
            minutesAgo: 92,
            graduation: 100,
            migrated: true,
            price: 0.007_91,
            change5m: 0.004,
            change1h: -0.031,
            change24h: 0.241,
            volume: 3_481_000,
            liquidity: 712_000,
            marketCap: 12_910_000,
            holders: 8_219,
            transactions: 14_382,
            buyCount: 7_164,
            sellCount: 7_218,
            suspicious: 3.8,
            sniper: 1.6,
            insider: 1.3,
            developer: 0.9,
            topTen: 24.7,
            description: "Synthetic launch used to demonstrate a mature, migrated market."
        ),
        token(
            address: "Demo1111111111111111111111111111111111005",
            name: "Afterimage",
            symbol: "AFTR",
            launchpad: "Bonk",
            minutesAgo: 21,
            graduation: 67,
            migrated: false,
            price: 0.000_053_7,
            change5m: -0.048,
            change1h: -0.112,
            change24h: 0.076,
            volume: 382_000,
            liquidity: 61_400,
            marketCap: 537_000,
            holders: 1_124,
            transactions: 3_018,
            buyCount: 1_476,
            sellCount: 1_542,
            suspicious: 22.4,
            sniper: 13.9,
            insider: 8.5,
            developer: 16.8,
            topTen: 68.2,
            potentialScamReasons: ["Suspicious wallet activity"],
            description: "Synthetic launch used to demonstrate elevated concentration and wallet signals."
        ),
        token(
            address: "Demo1111111111111111111111111111111111006",
            name: "Luma Relay",
            symbol: "LUMA",
            launchpad: "LaunchLab",
            minutesAgo: 57,
            graduation: 94,
            migrated: false,
            price: 0.000_412,
            change5m: 0.019,
            change1h: 0.084,
            change24h: 0.312,
            volume: 884_000,
            liquidity: 152_000,
            marketCap: 2_940_000,
            holders: 3_018,
            transactions: 6_184,
            buyCount: 3_416,
            sellCount: 2_768,
            suspicious: 7.4,
            sniper: 4.1,
            insider: 3.3,
            developer: 3.8,
            topTen: 35.6,
            description: "Synthetic launch used to demonstrate a token approaching graduation."
        )
    ]

    static func chart(
        for token: TokenSnapshot,
        count: Int = 96,
        interval: TimeInterval = 15 * 60
    ) -> [PricePoint] {
        let end = Date()
        let base = max(token.priceUSD, 0.000_001)
        let seed = Double(abs(token.symbol.hashValue % 17) + 3)
        let finalIndex = Double(max(count - 1, 0))
        let finalWave = sin((finalIndex + seed) * 0.31) * 0.035
            + cos((finalIndex + seed) * 0.13) * 0.018
        let finalRawValue = max(1 + finalWave, 0.1)

        return (0..<count).map { index in
            let progress = Double(index) / Double(max(count - 1, 1))
            let drift = 0.78 + (0.22 * progress)
            let wave = sin((Double(index) + seed) * 0.31) * 0.035
                + cos((Double(index) + seed) * 0.13) * 0.018
            let close = base * max(drift + wave, 0.1) / finalRawValue
            let open = close * (1 + sin(Double(index) * 0.47) * 0.009)
            let spread = close * (0.012 + abs(cos(Double(index) * 0.23)) * 0.01)

            return PricePoint(
                timestamp: end.addingTimeInterval(-Double(count - 1 - index) * interval),
                open: open,
                high: max(open, close) + spread,
                low: max(min(open, close) - spread, 0),
                close: close,
                volume: token.volume24h / Double(count) * (0.55 + abs(sin(Double(index) * 0.29)))
            )
        }
    }

    private static func token(
        address: String,
        name: String,
        symbol: String,
        launchpad: String,
        minutesAgo: Double,
        graduation: Double,
        migrated: Bool,
        price: Double,
        change5m: Double,
        change1h: Double,
        change24h: Double,
        volume: Double,
        liquidity: Double,
        marketCap: Double,
        holders: Int,
        transactions: Int,
        buyCount: Int,
        sellCount: Int,
        suspicious: Double,
        sniper: Double,
        insider: Double,
        developer: Double,
        topTen: Double,
        potentialScamReasons: [String] = [],
        description: String
    ) -> TokenSnapshot {
        TokenSnapshot(
            address: address,
            name: name,
            symbol: symbol,
            imageURL: nil,
            launchpadName: launchpad,
            createdAt: Date().addingTimeInterval(-minutesAgo * 60),
            graduationPercent: graduation,
            migrated: migrated,
            priceUSD: price,
            change5m: change5m,
            change1h: change1h,
            change24h: change24h,
            volume24h: volume,
            liquidityUSD: liquidity,
            marketCapUSD: marketCap,
            holders: holders,
            transactionCount24h: transactions,
            buyCount24h: buyCount,
            sellCount24h: sellCount,
            suspiciousHeldPercent: suspicious,
            sniperHeldPercent: sniper,
            insiderHeldPercent: insider,
            developerHeldPercent: developer,
            topTenHeldPercent: topTen,
            potentialScamReasons: potentialScamReasons,
            description: description,
            isDemo: true
        )
    }
}
