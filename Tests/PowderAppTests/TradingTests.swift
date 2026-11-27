import Foundation
import Testing
@testable import PowderApp

// Expected values were produced by the official hyperliquid-python-sdk (sign_l1_action, action_hash)
// and eth_account for the same inputs.
private let testKey = Data(hex: "0x0123456789012345678901234567890123456789012345678901234567890123")!
private let testNonce: Int64 = 1_677_777_606_040

@Test
func keccakAndAddressMatchEthereum() throws {
    #expect(Keccak256.hash(Data()).hex == "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470")
    #expect(Keccak256.hash(Data("abc".utf8)).hex == "4e03657aea45a94fc7d47ba826c8d667c0d1e6e33a64a036ec44f58fa12d6c45")
    #expect(try EthKey.address(of: testKey) == "0x14791697260e4c9a71f18484c9f997b308e59325")
    #expect(throws: EthKeyError.self) { try EthKey.parse("0x1234") }
    #expect(try EthKey.parse("0123456789012345678901234567890123456789012345678901234567890123") == testKey)
    #expect(try EthKey.address(of: EthKey.generate()).count == 42)
}

@Test
func orderSignatureMatchesTheReferenceSDK() throws {
    let action = HLAction.order(asset: 4, isBuy: true, price: "1670.1", size: "0.0147", reduceOnly: false, tif: .ioc)
    #expect(action.json == #"{"type":"order","orders":[{"a":4,"b":true,"p":"1670.1","s":"0.0147","r":false,"t":{"limit":{"tif":"Ioc"}}}],"grouping":"na"}"#)
    #expect(HLSigning.actionHash(action, nonce: testNonce).hex == "0fcbeda5ae3c4950a548021552a4fea2226858c4453571bf3f24ba017eac2908")

    let mainnet = try HLSigning.sign(action, nonce: testNonce, privateKey: testKey)
    #expect(mainnet == EthSignature(
        r: "0xe302c107c0048633293299b066317048f69f685aa4f536fe56c050efaf04996c",
        s: "0x70e01d4d26e3d724fb8f8ab54b3f2544a37ea1b092f83532349405274f3f3962",
        v: 28
    ))
    let testnet = try HLSigning.sign(action, nonce: testNonce, privateKey: testKey, isMainnet: false)
    #expect(testnet == EthSignature(
        r: "0x54d5cc489d4fa822a2788ecbdfe19d8dd478b9373cf0024b19aeb8452dc15474",
        s: "0x0eef26897cba04c5670c683b27c3601deb3189295a5670dda0b7cb97efe1b860",
        v: 28
    ))
}

@Test
func leverageAndCancelSignaturesMatchTheReferenceSDK() throws {
    let leverage = HLAction.updateLeverage(asset: 4, isCross: true, leverage: 7)
    #expect(HLSigning.actionHash(leverage, nonce: testNonce).hex == "cb6698b513c97d6b7e1d9e13c19a719e42b9d15b42aa63f0a764b68c53a8e250")
    #expect(try HLSigning.sign(leverage, nonce: testNonce, privateKey: testKey) == EthSignature(
        r: "0x9b983721befed922e897f92ad32a57b07f82fd81f1296cc24d4123effe40fb16",
        s: "0x60109750c00110314b3dc48e88bc7a56ab9d1863583c3a36d64ed1a76536d279",
        v: 28
    ))

    // The order id needs MessagePack's 64-bit form.
    let cancel = HLAction.cancel(asset: 4, orderID: 123_456_789_012)
    #expect(HLSigning.actionHash(cancel, nonce: testNonce).hex == "2adc006338620cc5c7868fdd43c02abe87bf5635279cde84352ee33224704670")
    #expect(try HLSigning.sign(cancel, nonce: testNonce, privateKey: testKey) == EthSignature(
        r: "0x20f1f7bb292353e962bdec33cd0717a7837cf3e275ae7ed9ab59fa19936848ea",
        s: "0x6563b942cc226a73c78e649b1e4026bdf3102c62a58ab60c9173e6dfa942a074",
        v: 28
    ))
}

@Test
func wireNumbersFollowExchangeRules() {
    #expect(HLWire.number(1670.1) == "1670.1")
    #expect(HLWire.number(100) == "100")
    #expect(HLWire.number(0.00001234) == "0.00001234")
    #expect(HLWire.number(2.5) == "2.5")

    // 5 significant figures, at most 6 - szDecimals decimals, whole numbers untouched.
    #expect(HLWire.price(1670.123, szDecimals: 4) == 1670.1)
    #expect(HLWire.price(123_456, szDecimals: 5) == 123_456)
    #expect(HLWire.price(0.0123456, szDecimals: 0) == 0.012346)
    #expect(HLWire.price(3.14159, szDecimals: 2) == 3.1416)
    #expect(HLWire.size(0.01479, szDecimals: 4) == 0.0147)
    #expect(HLWire.size(12.999, szDecimals: 0) == 12)
    #expect(HLWire.size(0.3, szDecimals: 1) == 0.3)
}

@Test
func exchangeResponsesBecomeOutcomesOrErrors() throws {
    let filled = Data(#"{"status":"ok","response":{"type":"order","data":{"statuses":[{"filled":{"totalSz":"0.02","avgPx":"1891.4","oid":77738308}}]}}}"#.utf8)
    #expect(try HyperliquidExchange.outcome(from: filled) == .filled(size: 0.02, price: 1891.4))

    let resting = Data(#"{"status":"ok","response":{"type":"order","data":{"statuses":[{"resting":{"oid":77738308}}]}}}"#.utf8)
    #expect(try HyperliquidExchange.outcome(from: resting) == .resting(orderID: 77_738_308))

    let rejected = Data(#"{"status":"ok","response":{"type":"order","data":{"statuses":[{"error":"Order must have minimum value of $10."}]}}}"#.utf8)
    #expect(throws: HLExchangeError(message: "Order must have minimum value of $10.")) {
        try HyperliquidExchange.outcome(from: rejected)
    }

    let failed = Data(#"{"status":"err","response":"User or API Wallet 0xabc does not exist."}"#.utf8)
    #expect(throws: HLExchangeError(message: "User or API Wallet 0xabc does not exist.")) {
        try HyperliquidExchange.outcome(from: failed)
    }

    let leverage = Data(#"{"status":"ok","response":{"type":"default"}}"#.utf8)
    #expect(try HyperliquidExchange.outcome(from: leverage) == .done)
}

@Test
func accountStateParsesPositionsAndOrders() throws {
    let clearing = Data(#"""
    {"marginSummary":{"accountValue":"1250.5","totalNtlPos":"340.0","totalRawUsd":"1000","totalMarginUsed":"68"},
     "withdrawable":"1182.5",
     "assetPositions":[{"type":"oneWay","position":{"coin":"ETH","szi":"-0.1","entryPx":"3400.0","positionValue":"340.0",
       "unrealizedPnl":"-2.5","liquidationPx":"4100.2","leverage":{"type":"isolated","value":5},"marginUsed":"68"}}]}
    """#.utf8)
    let orders = Data(#"[{"coin":"ETH","side":"B","limitPx":"3000.0","sz":"0.05","oid":991,"timestamp":1,"origSz":"0.05"}]"#.utf8)
    let state = try HyperliquidExchange.parseAccount(clearinghouse: clearing, openOrders: orders)
    #expect(state.accountValue == 1250.5 && state.withdrawable == 1182.5)
    #expect(state.positions == [HLPosition(
        coin: "ETH", size: -0.1, entryPrice: 3400, value: 340, unrealizedPnl: -2.5,
        liquidationPrice: 4100.2, leverage: 5, isCross: false
    )])
    #expect(state.orders == [HLOpenOrder(coin: "ETH", isBuy: true, price: 3000, size: 0.05, id: 991)])
}

@MainActor
private func makeProvider() -> WalletProvider {
    let name = "PowderWalletTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return WalletProvider(defaults: defaults, vault: MemoryVault())
}

@Test @MainActor
func walletsAreCreatedImportedNamedAndDeleted() throws {
    let provider = makeProvider()
    #expect(provider.wallets.isEmpty && provider.selected == nil)

    let first = try provider.create()
    #expect(first.name == "Wallet 1" && Wallet.isAddress(first.address))
    #expect(provider.selectedID == first.id)

    let imported = try provider.importWallet(name: "Main", privateKey: "0x" + testKey.hex)
    #expect(imported.address == "0x14791697260e4c9a71f18484c9f997b308e59325")
    #expect(provider.exportPrivateKey(imported.id) == "0x" + testKey.hex)
    #expect(throws: WalletError.duplicate("Main")) { try provider.importWallet(privateKey: testKey.hex) }
    #expect(throws: EthKeyError.self) { try provider.importWallet(privateKey: "nope") }

    // One key, two addresses: the same wallet is also a Solana wallet, and a Solana export imports as the same key.
    let solanaAddress = try SolanaKey.address(of: testKey)
    #expect(imported.solanaAddress == solanaAddress)
    #expect(provider.solana.wallets.map(\.address) == [try #require(first.solanaAddress), solanaAddress])
    #expect(provider.solana.selectedID == first.id)
    #expect(provider.exportSolanaKey(imported.id) == (try SolanaKey.export(testKey)))
    #expect(throws: WalletError.duplicate("Main")) { try provider.importWallet(privateKey: try SolanaKey.export(testKey)) }

    // Any number of wallets, each with its own settings.
    for _ in 0..<20 { try provider.create() }
    #expect(provider.wallets.count == 22)

    var changed = imported
    changed.name = "Scalper"
    changed.settings.leverage = 20
    changed.accountAddress = "0x00000000000000000000000000000000000000AA"
    provider.update(changed)
    let saved = try #require(provider.wallet(imported.id))
    #expect(saved.name == "Scalper" && saved.settings.leverage == 20)
    #expect(saved.isAgent && saved.tradingAddress == "0x00000000000000000000000000000000000000aa")
    #expect(provider.wallet(first.id)?.settings == WalletSettings())

    provider.delete(first.id)
    #expect(provider.wallet(first.id) == nil && provider.exportPrivateKey(first.id) == nil)
    #expect(!provider.solana.wallets.contains { $0.id == first.id })
    #expect(provider.selectedID != first.id && provider.selectedID != nil)
}

@Test @MainActor
func ordersAreRoundedBeforeTheyAreShownOrSent() throws {
    let provider = makeProvider()
    let wallet = try provider.create()
    let eth = HLMarket(
        index: 1, name: "ETH", szDecimals: 4, maxLeverage: 25,
        ctx: HLAssetCtx(markPx: 3_000, midPx: 3_000, oraclePx: 3_000, prevDayPx: 2_900, dayNtlVlm: 1, openInterest: 1, funding: 0)
    )

    // Market buy: priced 1% (the default slippage) above the mid, size cut to the market's step.
    let buy = try provider.prepare(wallet: wallet, market: eth, isBuy: true, size: 0.033339, limitPrice: nil, referencePrice: 3_000, reduceOnly: false)
    #expect(buy.isMarket && buy.price == 3_030 && buy.size == 0.0333)
    let sell = try provider.prepare(wallet: wallet, market: eth, isBuy: false, size: 1, limitPrice: nil, referencePrice: 3_000, reduceOnly: true)
    #expect(sell.price == 2_970 && sell.reduceOnly)

    let limit = try provider.prepare(wallet: wallet, market: eth, isBuy: true, size: 1, limitPrice: 2_950.456, referencePrice: 3_000, reduceOnly: false)
    #expect(!limit.isMarket && limit.price == 2_950.5)

    #expect(throws: WalletError.sizeTooSmall) {
        try provider.prepare(wallet: wallet, market: eth, isBuy: true, size: 0.00001, limitPrice: nil, referencePrice: 3_000, reduceOnly: false)
    }
    #expect(throws: WalletError.noPrice) {
        try provider.prepare(wallet: wallet, market: eth, isBuy: true, size: 1, limitPrice: nil, referencePrice: nil, reduceOnly: false)
    }
}

/// Sends one order from a brand-new, empty key and checks the exchange names that key's address in
/// its rejection: it can only know the address by recovering it from a correctly formed signature.
/// Nothing can fill. Runs only with POWDER_LIVE=1.
@Test(.enabled(if: ProcessInfo.processInfo.environment["POWDER_LIVE"] == "1"))
func hyperliquidRecoversOurAddressFromALiveSignature() async throws {
    let key = try EthKey.generate()
    let address = try EthKey.address(of: key)
    let action = HLAction.order(asset: 1, isBuy: true, price: "1", size: "0.01", reduceOnly: false, tif: .ioc)
    do {
        let outcome = try await HyperliquidExchange.send(action, privateKey: key)
        Issue.record("An empty wallet's order was accepted: \(outcome)")
    } catch let error as HLExchangeError {
        print("LIVE RESPONSE:", error.message, "| our address:", address)
        #expect(error.message.lowercased().contains(address))
    }
}

@Test
func spotBalancesParseAlongsidePerps() throws {
    let clearing = Data(#"{"marginSummary":{"accountValue":"0"},"withdrawable":"0","assetPositions":[]}"#.utf8)
    let orders = Data(#"[{"coin":"@107","side":"A","limitPx":"30","sz":"1","oid":5},{"coin":"ETH","side":"A","limitPx":"4000","sz":"1","oid":6}]"#.utf8)
    let spot = Data(#"{"balances":[{"coin":"USDC","token":0,"total":"250.5","hold":"0","entryNtl":"0"},{"coin":"HYPE","token":150,"total":"10","hold":"0","entryNtl":"300"},{"coin":"DUST","token":9,"total":"0","hold":"0","entryNtl":"0"}]}"#.utf8)
    let state = try HyperliquidExchange.parseAccount(clearinghouse: clearing, openOrders: orders, spot: spot)
    #expect(state.spot == [
        HLSpotBalance(coin: "USDC", token: 0, total: 250.5, entryNotional: 0),
        HLSpotBalance(coin: "HYPE", token: 150, total: 10, entryNotional: 300),
    ])
    // Spot orders are left out of the perp ticket's list.
    #expect(state.orders.map(\.id) == [6])
    #expect(HLWire.price(0.0123456789, szDecimals: 2, maxDecimals: 8) == 0.012346)
}

@Test @MainActor
func closingAPositionTakesTwoPresses() {
    let model = PositionsModel()
    let wallet = UUID()
    let rows = [
        PositionRow(id: "a", walletID: wallet, walletName: "Main", kind: .perp, coin: "ETH", size: -0.5, entry: 3_000, mark: 2_900, value: 1_450, pnl: 50, pnlPercent: 0.1, liquidation: 3_500, leverage: 5),
        PositionRow(id: "b", walletID: wallet, walletName: "Main", kind: .cash, coin: "USDC", size: 100, entry: nil, mark: nil, value: 100, pnl: nil, pnlPercent: nil, liquidation: nil, leverage: nil),
    ]
    #expect(rows[0].side == "SHORT" && rows[0].isClosable && !rows[1].isClosable)

    // Nothing selected: ⏎ does nothing.
    #expect(model.pressEnter(in: rows) == nil && model.armed == nil)

    model.move(1, in: rows)
    #expect(model.selection == "a")
    #expect(model.pressEnter(in: rows) == nil)
    #expect(model.armed == "a")
    #expect(model.pressEnter(in: rows) == rows[0])
    #expect(model.armed == nil)

    // Moving away disarms, and cash cannot be closed.
    _ = model.pressEnter(in: rows)
    model.move(1, in: rows)
    #expect(model.selection == "b" && model.armed == nil)
    #expect(model.pressEnter(in: rows) == nil && model.armed == nil)
}

@Test
func usdTransferSignatureMatchesTheReferenceSDK() throws {
    let digest = HLSigning.usdClassTransferDigest(amount: "13.66", toPerp: true, nonce: testNonce)
    #expect(try EthKey.sign(digest: digest, with: testKey) == EthSignature(
        r: "0xcd76ae5b30b7916b4712cde421d62973846c134a34b0a33a48674479ba4ebf47",
        s: "0x3cf151c60085d5e8f65e8a5838805641f91bf22b1e1bd5e0060c4e69e8a85bf7",
        v: 27
    ))
    #expect(HLAction.usdClassTransfer(amount: "13.66", toPerp: true, nonce: testNonce).json
        == #"{"type":"usdClassTransfer","amount":"13.66","toPerp":true,"nonce":1677777606040,"signatureChainId":"0x66eee","hyperliquidChain":"Mainnet"}"#)
}
