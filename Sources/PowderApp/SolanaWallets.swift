import Foundation

// MARK: - Model

struct SolanaWallet: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var name: String
    /// The wallet's public key in base58.
    let address: String
    var settings = SolanaTradeSettings()

    var shortAddress: String { "\(address.prefix(4))…\(address.suffix(4))" }
}

/// How one wallet's Solana swaps are sent.
struct SolanaTradeSettings: Codable, Equatable, Sendable {
    /// How far the price may move before a swap fails instead of filling, in percent.
    var slippagePercent = 1.0
    /// Paid to Nozomi for landing the transaction, in SOL. Charged only when it lands.
    var tipSOL = 0.001
    /// The network's own priority fee, in SOL.
    var prioritySOL = 0.00001
    /// What the ticket's buy size starts at, in SOL.
    var defaultBuySOL = 0.1

    var slippageBps: Int { Int((min(max(slippagePercent, 0.01), 50) * 100).rounded()) }
    var tipLamports: UInt64 { max(UInt64((tipSOL * 1e9).rounded()), Nozomi.minimumTipLamports) }
    var priorityLamports: UInt64 { UInt64((min(max(prioritySOL, 0), 0.01) * 1e9).rounded()) }
}

/// What a token is, and what it is worth now.
struct SolanaPrice: Equatable, Sendable {
    let symbol: String
    let name: String
    let price: Double
}

/// What a swap has reached, for showing its result before it lands.
enum SolanaSwapStage: Sendable {
    /// Priced: the amount it is expected to return, in the output token's smallest unit.
    case quoted(received: UInt64)
    /// Handed to Nozomi or the RPC.
    case sent
}

/// A swap that landed.
struct SolanaFill: Equatable, Sendable {
    let signature: String
    /// In the smallest units of the tokens paid and received (the amount received is the quoted one).
    let paid: UInt64
    let received: UInt64
    let milliseconds: Int
    let usedNozomi: Bool
}

enum SolanaTokens {
    /// Dollar stablecoins: shown as cash, with no PnL.
    static let stablecoins: Set<String> = [
        "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v", // USDC
        "Es9vMFrzaCERmJfrF4H2FYD4KCoNkY11McCe8BenwNYB", // USDT
        "2b1kV6DkPAnxd5ixfnxCpjxmKwqjjaYmCZfHsFu24GXo", // PYUSD
        "USDSwr9ApdHk5bvJKMjzff41FfuX8bSxdKcR81vTwcA", // USDS
        "USD1ttGY1N17NEEHLmELoaybftRBUSErhqYiQzvEmuB", // USD1
        "9zNQRsGLjNKwCUU5Gq5LR8beUCPzQMVMqKAi3SSZh54u", // FDUSD
        "2u1tszSeqZ3qBWF3uNGPFc8TzMk2tdiwknnRMWGWjGWH", // USDG
    ]

    /// SOL kept back from a buy for the network fee and a new token account's rent.
    static let reserveSOL = 0.004
}

/// One buy or sell of a token by a wallet, from its swap history.
struct SolanaTrade: Equatable, Sendable {
    /// Tokens gained (positive) or given up (negative).
    let amount: Double
    /// What the whole swap was worth in dollars.
    let usd: Double
    let time: Int
}

enum SolanaCost {
    /// The average price paid for what is still held: buys add to the cost, sells take a proportional share out.
    static func average(_ trades: [SolanaTrade]) -> Double? {
        var held = 0.0, cost = 0.0
        for trade in trades.sorted(by: { $0.time < $1.time }) {
            if trade.amount > 0 {
                held += trade.amount
                cost += trade.usd
            } else if held > 0 {
                let sold = min(-trade.amount, held)
                cost -= cost * sold / held
                held -= sold
                // Dust left by rounding is not a position.
                if held < 1e-9 { held = 0; cost = 0 }
            }
        }
        return held > 0 && cost > 0 ? cost / held : nil
    }
}

// MARK: - Provider

/// The Solana side of the app's wallets: balances, prices, and the swaps sent through them.
/// The wallets themselves belong to `WalletProvider`: one private key gives both a Hyperliquid and a Solana address.
@MainActor
final class SolanaWalletProvider: ObservableObject {
    /// Every wallet's Solana face, kept in step by `WalletProvider`.
    @Published private(set) var wallets: [SolanaWallet] = []
    @Published var selectedID: UUID?
    /// Reads a wallet's private key; set by `WalletProvider`.
    var keySource: (UUID) throws -> Data = { _ in throw WalletError.missingKey }
    @Published private(set) var balances: [UUID: SolanaBalances] = [:]
    @Published private(set) var errors: [UUID: String] = [:]
    /// By mint.
    @Published private(set) var prices: [String: SolanaPrice] = [:]
    /// Average price paid, by `wallet|mint`. Missing when the wallet never bought the token (it was sent in).
    @Published private(set) var costs: [String: Double] = [:]

    private let defaults: UserDefaults
    /// The balance each cost was worked out for, so history is only re-read when a holding changes.
    private var costedAmounts: [String: UInt64] = [:]
    /// Balances shown ahead of the chain while a swap lands: what is expected, and what the chain said before.
    /// The expected figures stay until the chain's own differ from `before`, or the hold runs out.
    private var expected: [UUID: (balances: SolanaBalances, before: SolanaBalances, until: Date)] = [:]
    /// Costs set from a swap just made, kept until the swap history has had time to include it.
    private var costHolds: [String: Date] = [:]
    private var ticks = 0

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Takes the current wallets. Balances of wallets that are gone are dropped; new ones load on the next tick.
    func sync(_ fresh: [SolanaWallet]) {
        guard fresh != wallets else { return }
        wallets = fresh
        for id in balances.keys where !fresh.contains(where: { $0.id == id }) {
            balances[id] = nil
            errors[id] = nil
        }
        ticks = 0
    }

    var selected: SolanaWallet? { wallets.first { $0.id == selectedID } }

    func wallet(_ id: UUID) -> SolanaWallet? { wallets.first { $0.id == id } }

    var solPrice: Double? { prices[SolanaRPC.wrappedSOL]?.price }

    static func costKey(_ wallet: UUID, _ mint: String) -> String { "\(wallet)|\(mint)" }

    // MARK: Balances and prices

    /// Called every few seconds while a ticket or the Positions tab is on screen.
    func tick() async {
        guard !wallets.isEmpty else { return }
        defer { ticks += 1 }
        // Balances every 12 s (public RPCs are rate limited), prices every 6 s, the Nozomi connection every minute.
        if ticks.isMultiple(of: 4) {
            await withTaskGroup(of: Void.self) { group in
                for wallet in wallets { group.addTask { await self.refresh(wallet.id) } }
            }
        }
        if ticks.isMultiple(of: 2) { await refreshPrices() }
        if ticks.isMultiple(of: 20) { Task { await Nozomi.warm() } }
    }

    func refresh(_ id: UUID) async {
        guard let wallet = wallet(id) else { return }
        do {
            var fresh = try await SolanaRPC.balances(owner: wallet.address)
            if let hold = expected[id] {
                if fresh == hold.before, Date() < hold.until {
                    // The node has not caught up with the swap yet.
                    fresh = hold.balances
                } else {
                    expected[id] = nil
                }
            }
            let isFirst = balances[id] == nil
            if balances[id] != fresh { balances[id] = fresh }
            if errors[id] != nil { errors[id] = nil }
            if isFirst { await refreshPrices() }
            await refreshCosts(for: wallet)
        } catch {
            errors[id] = error.localizedDescription
        }
    }

    /// Prices for SOL and everything held, plus any token a ticket is showing.
    func refreshPrices(including extra: [String] = []) async {
        var mints = Set(balances.values.flatMap { $0.holdings.map(\.mint) })
        mints.insert(SolanaRPC.wrappedSOL)
        extra.forEach { mints.insert($0) }
        // A wallet full of airdropped dust is priced a few hundred tokens at a time.
        for chunk in stride(from: 0, to: min(mints.count, 600), by: 200).map({ Array(mints.sorted().dropFirst($0).prefix(200)) }) {
            guard let stats = try? await SolanaAPI.stats(addresses: chunk) else { continue }
            for stat in stats {
                let price = SolanaPrice(symbol: stat.token.symbol, name: stat.token.name, price: stat.price)
                if prices[stat.token.address] != price { prices[stat.token.address] = price }
            }
        }
    }

    /// Works out what the wallet paid for each token worth showing, from its swap history.
    private func refreshCosts(for wallet: SolanaWallet) async {
        guard let holdings = balances[wallet.id]?.holdings else { return }
        var budget = 12
        for holding in holdings where !SolanaTokens.stablecoins.contains(holding.mint) && holding.mint != SolanaRPC.wrappedSOL {
            let key = Self.costKey(wallet.id, holding.mint)
            if let hold = costHolds[key], Date() < hold { continue }
            guard costedAmounts[key] != holding.raw, let price = prices[holding.mint]?.price, price * holding.amount >= 0.5 else { continue }
            guard budget > 0 else { break }
            budget -= 1
            guard let trades = try? await SolanaAPI.trades(maker: wallet.address, mint: holding.mint, decimals: holding.decimals) else { continue }
            costedAmounts[key] = holding.raw
            let cost = SolanaCost.average(trades)
            if costs[key] != cost { costs[key] = cost }
        }
    }

    // MARK: Trading

    /// The most SOL a buy can spend and still pay the tip, the fees and a new token account.
    func spendableSOL(_ id: UUID) -> Double {
        let settings = wallet(id)?.settings ?? SolanaTradeSettings()
        let tip = Nozomi.hasKey ? Double(settings.tipLamports) / 1e9 : 0
        return max((balances[id]?.sol ?? 0) - tip - settings.prioritySOL - SolanaTokens.reserveSOL, 0)
    }

    /// Swaps `amount` (in the input token's smallest unit) at market: routed by Jupiter, signed here, landed by Nozomi.
    /// The result shows in the wallet as soon as the swap is priced; if it then fails, the wallet is put back.
    func swap(
        walletID: UUID, input: String, output: String, amount: UInt64, outputDecimals: Int? = nil, pool: SolanaPool? = nil,
        onStage: @MainActor (SolanaSwapStage) -> Void = { _ in }
    ) async throws -> SolanaFill {
        guard let wallet = wallet(walletID) else { throw WalletError.missingKey }
        guard amount > 0 else { throw WalletError.sizeTooSmall }
        let before = balances[walletID]
        let costsBefore = costs
        do {
            return try await perform(
                wallet: wallet, input: input, output: output, amount: amount, outputDecimals: outputDecimals, pool: pool, before: before, onStage: onStage
            )
        } catch {
            // Shown ahead of the chain, and it did not happen.
            expected[walletID] = nil
            if let before { balances[walletID] = before }
            costs = costsBefore
            costHolds = costHolds.filter { !$0.key.hasPrefix("\(walletID)|") }
            Task { await refresh(walletID) }
            throw error
        }
    }

    /// Moves the wallet's shown balances to what a priced swap will leave, and its cost for the token with them.
    private func showExpected(
        wallet: SolanaWallet, before: SolanaBalances, input: String, output: String,
        paid: UInt64, received: UInt64, outputDecimals: Int?, usesTip: Bool
    ) {
        var after = before
        func change(_ mint: String, by delta: Int64, decimals: Int?) {
            if mint == SolanaRPC.wrappedSOL {
                after.lamports = UInt64(max(Int64(after.lamports) + delta, 0))
                return
            }
            let old = after.holding(mint)
            guard let decimals = old?.decimals ?? decimals else { return }
            let raw = UInt64(max(Int64(old?.raw ?? 0) + delta, 0))
            after.holdings.removeAll { $0.mint == mint }
            if raw > 0 {
                after.holdings.append(SolanaHolding(mint: mint, amount: Double(raw) / pow(10, Double(decimals)), raw: raw, decimals: decimals))
                after.holdings.sort { $0.mint < $1.mint }
            }
        }
        change(input, by: -Int64(paid), decimals: nil)
        change(output, by: Int64(received), decimals: outputDecimals)
        let fees = (usesTip ? wallet.settings.tipLamports : 0) + wallet.settings.priorityLamports + 5_000
        after.lamports = after.lamports > fees ? after.lamports - fees : 0
        guard after != before else { return }
        expected[wallet.id] = (after, before, Date().addingTimeInterval(20))
        balances[wallet.id] = after

        // The entry line and PnL move at once too: a buy blends into the average, a sale leaves it alone.
        let isMoney = { (mint: String) in mint == SolanaRPC.wrappedSOL || SolanaTokens.stablecoins.contains(mint) }
        guard !isMoney(output), let bought = after.holding(output), let unit = prices[input]?.price ?? (SolanaTokens.stablecoins.contains(input) ? 1 : nil),
              let inputDecimals = input == SolanaRPC.wrappedSOL ? 9 : before.holding(input)?.decimals else { return }
        let key = Self.costKey(wallet.id, output)
        let spent = Double(paid) / pow(10, Double(inputDecimals)) * unit
        let held = before.holding(output)?.amount ?? 0
        let earlier = (costs[key] ?? 0) * held
        if bought.amount > 0, costs[key] != nil || held == 0 {
            costs[key] = (earlier + spent) / bought.amount
            costHolds[key] = Date().addingTimeInterval(45)
        }
    }

    private func perform(
        wallet: SolanaWallet, input: String, output: String, amount: UInt64, outputDecimals: Int?, pool: SolanaPool?,
        before: SolanaBalances?, onStage: @MainActor (SolanaSwapStage) -> Void
    ) async throws -> SolanaFill {
        let walletID = wallet.id
        let seed = try keySource(walletID)
        let nozomiKey = KeychainStore.nozomi.readAPIKey()
        let settings = wallet.settings
        let clock = ContinuousClock()
        let started = clock.now

        // A route with many accounts can leave no room for the tip; a tighter one is asked for once.
        var transaction: SolanaTransaction?
        var quote: SolanaQuote?
        for maxAccounts in [56, 36] {
            let candidate = try await Jupiter.quote(input: input, output: output, amount: amount, slippageBps: settings.slippageBps, maxAccounts: maxAccounts, pool: pool)
            if quote == nil, transaction == nil, maxAccounts == 56 {
                // Priced: from here the trade shows as done while it is built, sent and landed.
                if let before {
                    showExpected(
                        wallet: wallet, before: before, input: input, output: output, paid: candidate.inAmount,
                        received: candidate.outAmount, outputDecimals: outputDecimals, usesTip: nozomiKey != nil
                    )
                }
                onStage(.quoted(received: candidate.outAmount))
            }
            let raw = try await Jupiter.transaction(for: candidate, owner: wallet.address, priorityLamports: settings.priorityLamports)
            var built = try SolanaTransaction(raw)
            do {
                if nozomiKey != nil { try built.addTransfer(lamports: settings.tipLamports, to: Nozomi.randomTipAccount()) }
                try built.sign(seed: seed)
                transaction = built
                quote = candidate
                break
            } catch SolanaError.tooLarge {
                continue
            }
        }
        guard let transaction, let quote else { throw SolanaError.tooLarge }
        let built = clock.now

        if let nozomiKey {
            try await Nozomi.send(transaction.serialized, key: nozomiKey)
        } else {
            try await SolanaRPC.send(transaction.serialized)
        }
        let sent = clock.now
        onStage(.sent)
        do {
            try await SolanaRPC.confirm(transaction.signature)
        } catch {
            HyperliquidExchange.log("solana \(transaction.signature) failed: \(error.localizedDescription)")
            Task { await refresh(walletID) }
            throw error
        }
        let total = HyperliquidExchange.milliseconds(clock.now - started)
        HyperliquidExchange.log(
            "solana \(transaction.signature) route=\(HyperliquidExchange.milliseconds(built - started))ms"
                + " send=\(HyperliquidExchange.milliseconds(sent - built))ms"
                + " land=\(HyperliquidExchange.milliseconds(clock.now - sent))ms via=\(nozomiKey == nil ? "rpc" : "nozomi")"
        )
        Task {
            await refresh(walletID)
            // The balance can trail the confirmation by a moment.
            try? await Task.sleep(for: .seconds(2))
            await refresh(walletID)
        }
        return SolanaFill(
            signature: transaction.signature, paid: quote.inAmount, received: quote.outAmount,
            milliseconds: total, usedNozomi: nozomiKey != nil
        )
    }
}
