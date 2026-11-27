import Foundation
import Testing
@testable import PowderApp

@Test
func base58MatchesSolanaAddresses() throws {
    #expect(Base58.encode(Data(repeating: 0, count: 32)) == "11111111111111111111111111111111")
    #expect(Base58.decode("11111111111111111111111111111111") == Data(repeating: 0, count: 32))
    #expect(Base58.encode(Data("hello world".utf8)) == "StV1DL6CwTryKyV")
    #expect(Base58.decode("StV1DL6CwTryKyV") == Data("hello world".utf8))
    #expect(Base58.decode("0OIl") == nil)
    for account in Nozomi.tipAccounts {
        let key = try #require(Base58.decode(account))
        #expect(key.count == 32)
        #expect(Base58.encode(key) == account)
    }
    #expect(Set(Nozomi.tipAccounts).count == 17)
}

@Test
func solanaKeysFollowEd25519() throws {
    // RFC 8032, test 1.
    let seed = Data(hex: "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60")!
    let publicKey = Data(hex: "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a")!
    #expect(try SolanaKey.publicKey(of: seed) == publicKey)
    #expect(try SolanaKey.address(of: seed) == Base58.encode(publicKey))

    // A wallet's export is the 64-byte keypair; both it and a keypair file's JSON import to the same seed.
    let exported = try SolanaKey.export(seed)
    #expect(try SolanaKey.parse(exported) == seed)
    #expect(try SolanaKey.parse("[" + (seed + publicKey).map(String.init).joined(separator: ",") + "]") == seed)
    #expect(try SolanaKey.parse(Base58.encode(seed)) == seed)
    #expect(throws: SolanaError.self) { try SolanaKey.parse(Base58.encode(seed + seed)) }
    #expect(throws: SolanaError.self) { try SolanaKey.parse("0x1234") }
    #expect(SolanaKey.isAddress("DezXAZ8z7PnrnRJjz3wXBoRgixCa6xjnB7YaB1pPB263"))
    #expect(!SolanaKey.isAddress("0x14791697260e4c9a71f18484c9f997b308e59325"))
}

/// A v0 transaction shaped like a router's: payer, two writable accounts, two programs, and a lookup table.
private func sampleTransaction(payer: Data, includeSystem: Bool) -> Data {
    func key(_ byte: UInt8) -> Data { Data(repeating: byte, count: 32) }
    var keys = [payer, key(1), key(2), key(9)]
    if includeSystem { keys.append(SolanaTransaction.systemProgram) }
    var out = Data([1]) + Data(repeating: 0, count: 64)
    out += Data([0x80, 1, 0, UInt8(keys.count - 3)])
    out += SolanaTransaction.compact(keys.count)
    keys.forEach { out += $0 }
    out += key(7)
    // One instruction: program 3 (read-only), accounts 0, 1, 2, then lookup accounts.
    let first = UInt8(keys.count)
    out += Data([1, 3, 5, 0, 1, 2, first, first + 2, 3, 0xAA, 0xBB, 0xCC])
    out += Data([1]) + key(5) + Data([2, 4, 6, 1, 9])
    return out
}

@Test
func tipIsAddedWithoutDisturbingTheSwap() throws {
    let seed = Data(hex: "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60")!
    let payer = try SolanaKey.publicKey(of: seed)
    let tip = Nozomi.randomTipAccount()

    for includeSystem in [true, false] {
        let original = sampleTransaction(payer: payer, includeSystem: includeSystem)
        var transaction = try SolanaTransaction(original)
        #expect(transaction.serialized == original)

        let before = transaction
        try transaction.addTransfer(lamports: 1_000_000, to: tip)

        // The tip account is the last writable one; everything read-only moved up by one.
        #expect(transaction.keys[3] == tip)
        #expect(transaction.keys[4] == Data(repeating: 9, count: 32))
        let system = try #require(transaction.keys.firstIndex(of: SolanaTransaction.systemProgram))
        #expect(transaction.readonlyUnsigned == 2)
        #expect(transaction.keys.count == 6)

        // The swap still names the same accounts: its program, and the lookup accounts after the static ones.
        let swap = transaction.instructions[0]
        #expect(transaction.keys[Int(swap.program)] == before.keys[Int(before.instructions[0].program)])
        #expect(swap.accounts == [0, 1, 2, 6, 8])
        #expect(swap.data == Data([0xAA, 0xBB, 0xCC]))
        #expect(transaction.lookups == before.lookups)

        let transfer = try #require(transaction.instructions.last)
        #expect(Int(transfer.program) == system)
        #expect(transfer.accounts == [0, 3])
        #expect(transfer.data == Data([2, 0, 0, 0, 0x40, 0x42, 0x0F, 0, 0, 0, 0, 0]))

        try transaction.sign(seed: seed)
        #expect(transaction.signatures[0] != Data(repeating: 0, count: 64))
        #expect(try SolanaTransaction(transaction.serialized) == transaction)
    }

    // Someone else's transaction is not signed.
    var foreign = try SolanaTransaction(sampleTransaction(payer: Data(repeating: 3, count: 32), includeSystem: true))
    #expect(throws: SolanaError.self) { try foreign.sign(seed: seed) }
    #expect(throws: SolanaError.self) { _ = try SolanaTransaction(Data([1, 2, 3])) }
}

@Test
func costBasisComesFromTheWalletsOwnSwaps() throws {
    // Bought 100 at $1, 100 more at $3, sold half: 100 left at the $2 average.
    let trades = [
        SolanaTrade(amount: -100, usd: 500, time: 3),
        SolanaTrade(amount: 100, usd: 100, time: 1),
        SolanaTrade(amount: 100, usd: 300, time: 2),
    ]
    #expect(SolanaCost.average(trades) == 2)
    // Sold out, then bought back: only the new buy counts.
    #expect(SolanaCost.average(trades + [SolanaTrade(amount: -100, usd: 900, time: 4), SolanaTrade(amount: 10, usd: 50, time: 5)]) == 5)
    // Sent in from elsewhere and never bought: no cost, so no PnL.
    #expect(SolanaCost.average([]) == nil)
    #expect(SolanaCost.average([SolanaTrade(amount: -5, usd: 10, time: 1)]) == nil)

    // A pool reports amounts from its own side: what it paid out is what the wallet received.
    let bonk = "DezXAZ8z7PnrnRJjz3wXBoRgixCa6xjnB7YaB1pPB263"
    let event: [String: Any] = [
        "token0Address": "So11111111111111111111111111111111111111112", "token1Address": bonk, "timestamp": 1_795_804_348,
        "quoteToken": "token1", "eventDisplayType": "Buy",
        "data": ["amount0": "7330864", "amount1": "-24427995685", "priceUsdTotal": "0.5262", "amountNonLiquidityToken": "244279.95685"],
    ]
    let bought = try #require(SolanaAPI.trade(in: event, mint: bonk, decimals: 5))
    #expect(abs(bought.amount - 244_279.95685) < 1e-6)
    #expect(bought.usd == 0.5262)
    // The same swap seen from the SOL side is a sale of SOL.
    let sold = try #require(SolanaAPI.trade(in: event, mint: "So11111111111111111111111111111111111111112", decimals: 9))
    #expect(abs(sold.amount + 0.007330864) < 1e-12)
    #expect(SolanaAPI.trade(in: event, mint: "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v", decimals: 6) == nil)

    #expect(SolanaTradeSettings().tipLamports == 1_000_000)
    #expect(SolanaTradeSettings(tipSOL: 0.0001).tipLamports == Nozomi.minimumTipLamports)
    #expect(SolanaTradeSettings(slippagePercent: 0.5).slippageBps == 50)
}

@Test
@MainActor
func watchlistAndAlertsKeepWhatTheUserSet() throws {
    let suite = "powder.tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    let watchlist = WatchlistStore(defaults: defaults)
    let bonk = MarketRef.solana(SolanaToken(address: "DezXAZ8z7PnrnRJjz3wXBoRgixCa6xjnB7YaB1pPB263", symbol: "BONK", name: "Bonk"))
    #expect(watchlist.toggle(.perp("ETH")) && watchlist.toggle(bonk))
    #expect(bonk.mint == "DezXAZ8z7PnrnRJjz3wXBoRgixCa6xjnB7YaB1pPB263" && bonk.coin == nil && MarketRef.perp("ETH").coin == "ETH")
    #expect(WatchlistStore(defaults: defaults).items.map(\.symbol) == ["ETH", "BONK"])
    #expect(!watchlist.toggle(.perp("ETH")))
    #expect(WatchlistStore(defaults: defaults).items == [bonk])

    // An alert above the current price waits for a rise; below it, for a fall.
    let alerts = AlertStore(defaults: defaults, directory: MarketDirectory(), quotes: SolanaQuotes())
    let up = try #require(alerts.add(.perp("ETH"), price: 1_700, current: 1_650))
    let down = try #require(alerts.add(.perp("ETH"), price: 1_600, current: 1_650))
    #expect(up.isAbove && !down.isAbove && up.isActive)
    #expect(alerts.add(.perp("ETH"), price: 0, current: 1_650) == nil)
    #expect(alerts.alerts(for: .perp("ETH")).count == 2 && alerts.alerts(for: bonk).isEmpty)
    #expect(AlertStore.describe(up) == "ETH rose to 1700.0")
    alerts.remove(up.id)
    #expect(AlertStore(defaults: defaults, directory: MarketDirectory(), quotes: SolanaQuotes()).alerts.map(\.id) == [down.id])
    alerts.remove(down.id)
}

@Test
func liquidationFeedKeepsTheLiquidatedSideOnly() throws {
    let victim = "0x00000000000000000000000000000000000000aa"
    func fill(_ direction: String, side: String) -> String {
        #"{"coin":"ETH","px":"1650.5","sz":"2","side":"\#(side)","time":1795800000000,"dir":"\#(direction)","tid":77,"liquidation":{"liquidatedUser":"\#(victim)","markPx":"1651","method":"market"}}"#
    }
    let message = #"{"channel":"liquidationFills","fills":[["\#(victim)",\#(fill("Close Long", side: "A"))],["0x00000000000000000000000000000000000000bb",\#(fill("Open Long", side: "B"))],["0xcc",{"coin":"BTC","px":"1","sz":"1"}]]}"#
    let rows = LiquidationFeed.parse(Data(message.utf8))
    // The counterparty's fill and the ordinary fill are dropped.
    #expect(rows.count == 1)
    let row = try #require(rows.first)
    #expect(row.coin == "ETH" && row.wasLong && row.value == 3_301 && row.method == "market" && row.user == victim)
    #expect(LiquidationFeed.parse(Data("not json".utf8)).isEmpty)
}

@Test
@MainActor
func stopsAndTargetsOnlyGoOnTheirOwnSideOfThePrice() throws {
    let suite = "powder.tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = SolanaTriggerStore(defaults: defaults, solana: SolanaWalletProvider(defaults: defaults), quotes: SolanaQuotes())
    let wallet = UUID()
    let token = SolanaToken(address: "DezXAZ8z7PnrnRJjz3wXBoRgixCa6xjnB7YaB1pPB263", symbol: "BONK", name: "Bonk")

    // A stop above the market, or a target below it, would sell at once: refused.
    #expect(store.set(.stopLoss, walletID: wallet, token: token, price: 2.5, current: 2) != nil)
    #expect(store.set(.takeProfit, walletID: wallet, token: token, price: 1.5, current: 2) != nil)
    #expect(store.set(.stopLoss, walletID: wallet, token: token, price: 0, current: 2) != nil)
    #expect(store.triggers.isEmpty)

    #expect(store.set(.stopLoss, walletID: wallet, token: token, price: 1.5, current: 2) == nil)
    #expect(store.set(.takeProfit, walletID: wallet, token: token, price: 3, current: 2) == nil)
    // Setting the stop again moves it; there is one of each per holding.
    #expect(store.set(.stopLoss, walletID: wallet, token: token, price: 1.8, current: 2) == nil)
    let active = store.active(walletID: wallet, mint: token.address)
    #expect(active.count == 2)
    let stop = try #require(active.first { $0.kind == .stopLoss })
    let target = try #require(active.first { $0.kind == .takeProfit })
    #expect(stop.price == 1.8 && stop.isMet(by: 1.8) && stop.isMet(by: 1.2) && !stop.isMet(by: 1.81))
    #expect(target.isMet(by: 3) && target.isMet(by: 4) && !target.isMet(by: 2.99))
    #expect(store.active(walletID: UUID(), mint: token.address).isEmpty)

    store.remove(stop.id)
    store.remove(target.id)
    #expect(store.triggers.isEmpty)
}

/// Talks to Jupiter and a Solana RPC: run with POWDER_LIVE=1.
@Test(.enabled(if: ProcessInfo.processInfo.environment["POWDER_LIVE"] == "1"))
func liveSwapStillSimulatesWithTheTip() async throws {
    // An exchange wallet with plenty of SOL, so the swap can be simulated without owning it.
    let owner = "5tzFkiKscXHK5ZXCGbXZxdw7gTjjD1mBwuoFbhUvuAi9"
    let balances = try await SolanaRPC.balances(owner: owner)
    print("owner SOL", balances.sol, "tokens", balances.holdings.count)

    for output in ["DezXAZ8z7PnrnRJjz3wXBoRgixCa6xjnB7YaB1pPB263", "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v"] {
        let quote = try await Jupiter.quote(input: SolanaRPC.wrappedSOL, output: output, amount: 50_000_000, slippageBps: 100)
        let raw = try await Jupiter.transaction(for: quote, owner: owner, priorityLamports: 10_000)
        var transaction = try SolanaTransaction(raw)
        #expect(transaction.serialized == raw)
        try transaction.addTransfer(lamports: Nozomi.minimumTipLamports, to: Nozomi.randomTipAccount())
        // Some routes (private market makers) refuse to simulate at all, so the bar is: the tip changes nothing.
        let plain = try await SolanaRPC.simulate(raw)
        let result = try await SolanaRPC.simulate(transaction.serialized)
        print(output.prefix(4), "size", raw.count, "→", transaction.serialized.count, "plain", plain.error ?? "ok", "tipped", result.error ?? "ok")
        #expect(result.error == plain.error)
        if result.error == nil {
            #expect(result.logs.suffix(2) == ["Program 11111111111111111111111111111111 invoke [1]", "Program 11111111111111111111111111111111 success"])
        }
    }
}
