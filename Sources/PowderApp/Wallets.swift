import Combine
import Foundation
import Security

// MARK: - Model

/// Trading preferences kept per wallet.
struct WalletSettings: Codable, Equatable, Sendable {
    /// How far past the mid a market order may fill, in percent.
    var slippagePercent = 1.0
    /// What the order ticket's size starts at.
    var defaultSizeUSD = 100.0
    /// Leverage set on a market before this wallet opens a position there.
    var leverage = 5
    var isCross = true
}

struct Wallet: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var name: String
    /// The key's own address, lowercase with `0x`.
    let address: String
    /// Set when this key is an API (agent) wallet approved by another account: orders signed here
    /// trade that account, and balances are read from it.
    var accountAddress = ""
    var settings = WalletSettings()
    /// The same key's Solana address (base58). Filled in on first launch for wallets saved before Solana.
    var solanaAddress: String?
    /// Nil until changed, so wallets saved before Solana still load.
    var solanaSettings: SolanaTradeSettings?

    /// How this wallet's Solana swaps are sent.
    var solana: SolanaTradeSettings {
        get { solanaSettings ?? SolanaTradeSettings() }
        set { solanaSettings = newValue }
    }

    /// The account whose balance and positions this wallet trades.
    var tradingAddress: String {
        let account = accountAddress.trimmingCharacters(in: .whitespaces).lowercased()
        return Self.isAddress(account) ? account : address
    }

    var isAgent: Bool { tradingAddress != address }

    var shortAddress: String { Self.shorten(tradingAddress) }

    static func shorten(_ address: String) -> String {
        address.count > 12 ? "\(address.prefix(6))…\(address.suffix(4))" : address
    }

    static func isAddress(_ text: String) -> Bool {
        text.hasPrefix("0x") && text.count == 42 && Data(hex: text) != nil
    }
}

// MARK: - Key storage

/// Where private keys live. The app uses the Keychain; tests use memory.
protocol KeyVault: Sendable {
    func read(_ id: UUID) -> Data?
    func save(_ key: Data, for id: UUID) throws
    func delete(_ id: UUID)
}

struct KeychainVault: KeyVault {
    private let service = "io.powder.wallet"

    private func query(_ id: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
        ]
    }

    func read(_ id: UUID) -> Data? {
        var query = query(id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    func save(_ key: Data, for id: UUID) throws {
        SecItemDelete(query(id) as CFDictionary)
        var insert = query(id)
        insert[kSecValueData as String] = key
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        insert[kSecAttrLabel as String] = "Powder wallet key"
        let status = SecItemAdd(insert as CFDictionary, nil)
        guard status == errSecSuccess else { throw WalletError.keychain(status) }
    }

    func delete(_ id: UUID) {
        SecItemDelete(query(id) as CFDictionary)
    }
}

final class MemoryVault: KeyVault, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [UUID: Data] = [:]

    func read(_ id: UUID) -> Data? { lock.withLock { keys[id] } }
    func save(_ key: Data, for id: UUID) throws { lock.withLock { keys[id] = key } }
    func delete(_ id: UUID) { lock.withLock { keys[id] = nil } }
}

enum WalletError: LocalizedError, Equatable {
    case keychain(OSStatus)
    case duplicate(String)
    case missingKey
    case sizeTooSmall
    case noPrice
    case agentCannotTransfer

    var errorDescription: String? {
        switch self {
        case let .keychain(status): "The key could not be saved to the Keychain (status \(status))."
        case let .duplicate(name): "That key is already here as “\(name)”."
        case .missingKey: "This wallet's private key is not in the Keychain."
        case .sizeTooSmall: "The size is below this market's smallest step."
        case .noPrice: "No price yet for this market."
        case .agentCannotTransfer: "An API wallet cannot move funds. Move USDC from spot to perps with the main wallet."
        }
    }
}

// MARK: - Provider

/// Every wallet the app knows, which one is selected, and the trading that goes through them.
/// Names and settings are stored in user defaults; private keys only in the vault.
@MainActor
final class WalletProvider: ObservableObject {
    @Published private(set) var wallets: [Wallet] = [] {
        didSet { syncSolana() }
    }
    @Published var selectedID: UUID? {
        didSet {
            solana.selectedID = selectedID
            guard selectedID != oldValue else { return }
            defaults.set(selectedID?.uuidString, forKey: Self.selectedKey)
            Task { await refresh() }
        }
    }
    /// Balance, positions and open orders by wallet, as last fetched.
    @Published private(set) var accounts: [UUID: HLAccountState] = [:]
    @Published private(set) var accountErrors: [UUID: String] = [:]

    /// Solana wallets and swaps. Its changes are republished here, so views watching this provider follow both.
    let solana: SolanaWalletProvider
    private var solanaChanges: AnyCancellable?

    private let defaults: UserDefaults
    private let vault: KeyVault
    private var keyCache: [UUID: Data] = [:]
    /// Leverage this session has already set, by wallet and coin, so it is not re-sent with every order.
    private var appliedLeverage: [String: String] = [:]
    private var leverageSyncs: [String: Task<Void, Never>] = [:]
    private var watchers = 0
    private var allWatchers = 0
    private var pollTask: Task<Void, Never>?

    private static let walletsKey = "wallets"
    private static let selectedKey = "wallets.selected"

    init(defaults: UserDefaults = .standard, vault: KeyVault = KeychainVault()) {
        self.defaults = defaults
        self.vault = vault
        solana = SolanaWalletProvider(defaults: defaults)
        wallets = defaults.data(forKey: Self.walletsKey)
            .flatMap { try? JSONDecoder().decode([Wallet].self, from: $0) } ?? []
        let saved = defaults.string(forKey: Self.selectedKey).flatMap(UUID.init)
        selectedID = wallets.contains { $0.id == saved } ? saved : wallets.first?.id
        solanaChanges = solana.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        solana.keySource = { [weak self] id in
            guard let self else { throw WalletError.missingKey }
            return try self.privateKey(for: id)
        }
        solana.selectedID = selectedID
        syncSolana()
        Task { await deriveSolanaAddresses() }
    }

    private func syncSolana() {
        solana.sync(wallets.compactMap { wallet in
            wallet.solanaAddress.map { SolanaWallet(id: wallet.id, name: wallet.name, address: $0, settings: wallet.solana) }
        })
    }

    /// Wallets saved before Solana have no Solana address yet: it is worked out from the key, read off the main thread.
    private func deriveSolanaAddresses() async {
        for wallet in wallets where wallet.solanaAddress == nil {
            await preloadKey(wallet.id)
            guard let key = keyCache[wallet.id], let address = try? SolanaKey.address(of: key),
                  let index = wallets.firstIndex(where: { $0.id == wallet.id }) else { continue }
            wallets[index].solanaAddress = address
            persist()
        }
    }

    var selected: Wallet? { wallets.first { $0.id == selectedID } }

    func wallet(_ id: UUID) -> Wallet? { wallets.first { $0.id == id } }

    // MARK: Managing wallets

    /// Generates a new key on this Mac.
    @discardableResult
    func create(name: String = "") throws -> Wallet {
        try add(key: EthKey.generate(), name: name)
    }

    /// Adds an existing private key: 64 hex characters (with or without `0x`), or a Solana wallet's
    /// export (base58, or a keypair file's JSON array). Either way the one key serves both chains.
    @discardableResult
    func importWallet(name: String = "", privateKey: String) throws -> Wallet {
        if let key = try? EthKey.parse(privateKey) { return try add(key: key, name: name) }
        guard let seed = try? SolanaKey.parse(privateKey), (try? EthKey.address(of: seed)) != nil else {
            throw EthKeyError.invalidPrivateKey
        }
        return try add(key: seed, name: name)
    }

    private func add(key: Data, name: String) throws -> Wallet {
        let address = try EthKey.address(of: key)
        if let existing = wallets.first(where: { $0.address == address }) {
            throw WalletError.duplicate(existing.name)
        }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        var wallet = Wallet(id: UUID(), name: trimmed.isEmpty ? "Wallet \(wallets.count + 1)" : trimmed, address: address)
        wallet.solanaAddress = try? SolanaKey.address(of: key)
        try vault.save(key, for: wallet.id)
        keyCache[wallet.id] = key
        wallets.append(wallet)
        persist()
        if selectedID == nil { selectedID = wallet.id }
        return wallet
    }

    /// Saves a renamed wallet or changed settings.
    func update(_ wallet: Wallet) {
        guard let index = wallets.firstIndex(where: { $0.id == wallet.id }), wallets[index] != wallet else { return }
        let accountChanged = wallets[index].tradingAddress != wallet.tradingAddress
        wallets[index] = wallet
        persist()
        if accountChanged {
            accounts[wallet.id] = nil
            Task { await refresh(wallet.id) }
        }
    }

    /// Removes the wallet and its key. The key cannot be recovered afterwards.
    func delete(_ id: UUID) {
        vault.delete(id)
        keyCache[id] = nil
        accounts[id] = nil
        accountErrors[id] = nil
        wallets.removeAll { $0.id == id }
        persist()
        if selectedID == id { selectedID = wallets.first?.id }
    }

    func privateKey(for id: UUID) throws -> Data {
        if let cached = keyCache[id] { return cached }
        guard let key = vault.read(id) else { throw WalletError.missingKey }
        keyCache[id] = key
        return key
    }

    /// Reads the key ahead of the first order, off the main thread: if macOS asks for permission,
    /// the app keeps running behind the prompt instead of freezing.
    func preloadKey(_ id: UUID) async {
        guard keyCache[id] == nil else { return }
        let vault = vault
        if let key = await Task.detached(operation: { vault.read(id) }).value { keyCache[id] = key }
    }

    /// The key as `0x` hex, for backing it up.
    func exportPrivateKey(_ id: UUID) -> String? {
        (try? privateKey(for: id)).map { "0x" + $0.hex }
    }

    /// The same key in the form Solana wallets import: the base58 keypair.
    func exportSolanaKey(_ id: UUID) -> String? {
        (try? privateKey(for: id)).flatMap { try? SolanaKey.export($0) }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(wallets) { defaults.set(data, forKey: Self.walletsKey) }
    }

    // MARK: Account state

    /// Order tickets call this while visible; the selected wallet is then refreshed every few seconds.
    func watch(_ isWatching: Bool) {
        watchers = max(watchers + (isWatching ? 1 : -1), 0)
        updatePolling()
    }

    /// The Positions tab calls this while visible; every wallet is then refreshed, not just the selected one.
    func watchAll(_ isWatching: Bool) {
        allWatchers = max(allWatchers + (isWatching ? 1 : -1), 0)
        updatePolling()
    }

    private func updatePolling() {
        if watchers + allWatchers > 0, pollTask == nil {
            pollTask = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.poll()
                    try? await Task.sleep(for: .seconds(3))
                }
            }
        } else if watchers + allWatchers == 0 {
            pollTask?.cancel()
            pollTask = nil
        }
    }

    private func poll() async {
        Task { await HyperliquidExchange.warm() }
        Task { await solana.tick() }
        guard allWatchers > 0 else { return await refresh() }
        await withTaskGroup(of: Void.self) { group in
            for wallet in wallets {
                group.addTask { await self.refresh(wallet.id) }
            }
        }
    }

    /// Closes a holding shown in the Positions tab: a perp at market, reduce-only, or a spot
    /// balance sold for USDC. Both use the wallet's market slippage.
    func close(_ row: PositionRow, directory: MarketDirectory) async throws -> HLOrderOutcome {
        if let mint = row.solanaMint {
            // A Solana token is sold for SOL.
            guard row.kind == .spot, let holding = solana.balances[row.walletID]?.holding(mint) else { return .done }
            _ = try await solana.swap(walletID: row.walletID, input: mint, output: SolanaRPC.wrappedSOL, amount: holding.raw)
            return row.mark.map { .filled(size: holding.amount, price: $0) } ?? .done
        }
        guard let wallet = wallet(row.walletID) else { throw WalletError.missingKey }
        switch row.kind {
        case .cash:
            return .done
        case .perp:
            guard let market = directory.markets[row.coin] else { throw WalletError.noPrice }
            let mid = directory.mids[row.coin] ?? market.ctx.midPx ?? market.ctx.markPx
            return try await send(prepare(
                wallet: wallet, market: market, isBuy: row.size < 0, size: abs(row.size),
                limitPrice: nil, referencePrice: mid, reduceOnly: true
            ))
        case .spot:
            guard let pair = row.token.flatMap({ directory.spotPairs[$0] }), let mid = directory.mids[pair.midKey], mid > 0 else {
                throw WalletError.noPrice
            }
            let size = HLWire.size(row.size, szDecimals: pair.szDecimals)
            guard size > 0 else { throw WalletError.sizeTooSmall }
            let price = HLWire.price(mid * (1 - wallet.settings.slippagePercent / 100), szDecimals: pair.szDecimals, maxDecimals: 8)
            let outcome = try await HyperliquidExchange.send(
                HLAction.order(asset: pair.asset, isBuy: false, price: HLWire.number(price), size: HLWire.number(size), reduceOnly: false, tif: .ioc),
                privateKey: privateKey(for: wallet.id)
            )
            Task { await refresh(wallet.id) }
            return outcome
        }
    }

    /// Moves USDC between the wallet's spot and perp balances. Rounded down to cents so it never asks for more than is there.
    func transferUSDC(_ amount: Double, toPerp: Bool, walletID: UUID) async throws {
        guard let wallet = wallet(walletID) else { throw WalletError.missingKey }
        if wallet.isAgent { throw WalletError.agentCannotTransfer }
        let rounded = (amount * 100).rounded(.down) / 100
        guard rounded > 0 else { throw WalletError.sizeTooSmall }
        try await HyperliquidExchange.transferUSDC(amount: rounded, toPerp: toPerp, privateKey: privateKey(for: wallet.id))
        await refresh(wallet.id)
    }

    func refresh(_ id: UUID? = nil) async {
        guard let wallet = (id ?? selectedID).flatMap(wallet) else { return }
        do {
            let state = try await HyperliquidExchange.accountState(user: wallet.tradingAddress)
            // While an order is in flight the account shows its expected result; a fetch from before it lands must not undo that.
            guard inFlight[wallet.id, default: 0] == 0 else { return }
            if accounts[wallet.id] != state { accounts[wallet.id] = state }
            if accountErrors[wallet.id] != nil { accountErrors[wallet.id] = nil }
        } catch {
            accountErrors[wallet.id] = error.localizedDescription
        }
    }

    // MARK: Trading

    /// The exact order that would be sent: size and price already rounded to what the exchange accepts.
    struct PreparedOrder: Equatable {
        let walletID: UUID
        let market: HLMarket
        let isBuy: Bool
        let size: Double
        /// The limit price; for a market order, the worst price it may fill at.
        let price: Double
        let isMarket: Bool
        let reduceOnly: Bool
        /// The mid when a market order was prepared: where it is shown as filled until the exchange answers.
        var expectedPrice: Double?
    }

    /// Rounds a requested order. `referencePrice` is the current mid, used for market orders.
    func prepare(
        wallet: Wallet, market: HLMarket, isBuy: Bool, size: Double,
        limitPrice: Double?, referencePrice: Double?, reduceOnly: Bool
    ) throws -> PreparedOrder {
        let price: Double
        if let limitPrice {
            price = HLWire.price(limitPrice, szDecimals: market.szDecimals)
        } else {
            guard let referencePrice, referencePrice > 0 else { throw WalletError.noPrice }
            let slippage = wallet.settings.slippagePercent / 100
            price = HLWire.price(referencePrice * (isBuy ? 1 + slippage : 1 - slippage), szDecimals: market.szDecimals)
        }
        let rounded = HLWire.size(size, szDecimals: market.szDecimals)
        guard price > 0 else { throw WalletError.noPrice }
        guard rounded > 0 else { throw WalletError.sizeTooSmall }
        return PreparedOrder(
            walletID: wallet.id, market: market, isBuy: isBuy, size: rounded,
            price: price, isMarket: limitPrice == nil, reduceOnly: reduceOnly,
            expectedPrice: limitPrice == nil ? referencePrice : nil
        )
    }

    /// Orders sent and not yet answered, by wallet.
    private var inFlight: [UUID: Int] = [:]

    /// Signs and sends the order, first setting the wallet's leverage on that market if it differs.
    /// A market order shows in the account at once, at the price it was sent from; the exchange's answer
    /// then corrects it, or takes it back out if the order was refused.
    func send(_ order: PreparedOrder) async throws -> HLOrderOutcome {
        guard let wallet = wallet(order.walletID) else { throw WalletError.missingKey }
        let started = ContinuousClock.now
        let key = try privateKey(for: wallet.id)

        let before = accounts[wallet.id]
        inFlight[wallet.id, default: 0] += 1
        defer { inFlight[wallet.id, default: 1] -= 1 }
        if order.isMarket, let expected = order.expectedPrice {
            var signed = order.isBuy ? order.size : -order.size
            if order.reduceOnly {
                // A reduce-only order can close the position but never open the other side.
                let held = before?.positions.first { $0.coin == order.market.name }?.size ?? 0
                signed = signed > 0 ? min(signed, max(-held, 0)) : max(signed, min(-held, 0))
            }
            if signed != 0 { applyFill(walletID: wallet.id, coin: order.market.name, signedSize: signed, price: expected) }
        }
        do {
            return try await deliver(order, wallet: wallet, key: key, before: before, started: started)
        } catch {
            if let before { accounts[wallet.id] = before }
            throw error
        }
    }

    private func deliver(
        _ order: PreparedOrder, wallet: Wallet, key: Data, before: HLAccountState?, started: ContinuousClock.Instant
    ) async throws -> HLOrderOutcome {

        if !order.reduceOnly {
            // Normally a no-op: the ticket has already matched the exchange's leverage in the background.
            let cacheKey = "\(wallet.id)|\(order.market.name)"
            await leverageSyncs[cacheKey]?.value
            if let wanted = leverageChange(wallet: wallet, market: order.market) {
                try await HyperliquidExchange.send(
                    HLAction.updateLeverage(asset: order.market.index, isCross: wallet.settings.isCross, leverage: wanted.leverage),
                    privateKey: key
                )
                appliedLeverage[cacheKey] = wanted.key
            }
        }

        let outcome = try await HyperliquidExchange.send(
            HLAction.order(
                asset: order.market.index, isBuy: order.isBuy,
                price: HLWire.number(order.price), size: HLWire.number(order.size),
                reduceOnly: order.reduceOnly, tif: order.isMarket ? .ioc : .gtc
            ),
            privateKey: key
        )
        // The expected fill gives way to the real one: what actually filled, at the price it filled at.
        if let before { accounts[wallet.id] = before }
        if case let .filled(size, price) = outcome {
            applyFill(walletID: wallet.id, coin: order.market.name, signedSize: order.isBuy ? size : -size, price: price)
        }
        HyperliquidExchange.log("order \(order.market.name) total=\(HyperliquidExchange.milliseconds(ContinuousClock.now - started))ms")
        let id = wallet.id
        Task {
            // After this call returns, so the in-flight guard no longer holds the fetch back.
            await Task.yield()
            await refresh(id)
        }
        return outcome
    }

    /// Updates the position from a fill without waiting for the next balance fetch.
    private func applyFill(walletID: UUID, coin: String, signedSize: Double, price: Double) {
        guard var account = accounts[walletID] else { return }
        let old = account.positions.first { $0.coin == coin }
        let before = old?.size ?? 0
        let after = before + signedSize
        account.positions.removeAll { $0.coin == coin }
        if abs(after) > 1e-9 {
            let entry: Double
            if before == 0 || (before > 0) != (after > 0) {
                entry = price
            } else if abs(after) > abs(before) {
                entry = (abs(before) * (old?.entryPrice ?? price) + abs(signedSize) * price) / abs(after)
            } else {
                entry = old?.entryPrice ?? price
            }
            let settings = wallet(walletID)?.settings
            account.positions.append(HLPosition(
                coin: coin, size: after, entryPrice: entry, value: abs(after) * price,
                unrealizedPnl: (price - entry) * after,
                // Not known until the exchange reports it.
                liquidationPrice: nil,
                leverage: old?.leverage ?? settings?.leverage ?? 1, isCross: old?.isCross ?? settings?.isCross ?? true
            ))
        }
        accounts[walletID] = account
    }

    /// The leverage to send if the exchange is not already known to have the wallet's setting for this market.
    private func leverageChange(wallet: Wallet, market: HLMarket) -> (leverage: Int, key: String)? {
        let leverage = min(max(wallet.settings.leverage, 1), market.maxLeverage)
        let wanted = "\(leverage)|\(wallet.settings.isCross)"
        let position = accounts[wallet.id]?.positions.first { $0.coin == market.name }
        let current = position.map { "\($0.leverage)|\($0.isCross)" } ?? appliedLeverage["\(wallet.id)|\(market.name)"]
        return current == wanted ? nil : (leverage, wanted)
    }

    /// Called when a ticket shows a market: sets the wallet's leverage there ahead of time, so the
    /// order itself is a single request. Nothing is sent when the exchange already matches.
    func syncLeverage(walletID: UUID, market: HLMarket) {
        guard let wallet = wallet(walletID), leverageChange(wallet: wallet, market: market) != nil else { return }
        let cacheKey = "\(wallet.id)|\(market.name)"
        leverageSyncs[cacheKey]?.cancel()
        leverageSyncs[cacheKey] = Task { [weak self] in
            defer { if !Task.isCancelled { self?.leverageSyncs[cacheKey] = nil } }
            if let live = try? await HyperliquidExchange.leverage(user: wallet.tradingAddress, coin: market.name),
               !Task.isCancelled, let self {
                // Only trust the exchange's value while there is no position to read it from.
                if self.accounts[wallet.id]?.positions.contains(where: { $0.coin == market.name }) != true {
                    self.appliedLeverage[cacheKey] = "\(live.value)|\(live.isCross)"
                }
            }
            guard !Task.isCancelled, let self, let fresh = self.wallet(walletID),
                  let wanted = self.leverageChange(wallet: fresh, market: market),
                  (self.accounts[walletID]?.accountValue ?? 0) > 0,
                  let key = try? self.privateKey(for: walletID) else { return }
            let action = HLAction.updateLeverage(asset: market.index, isCross: fresh.settings.isCross, leverage: wanted.leverage)
            if (try? await HyperliquidExchange.send(action, privateKey: key)) != nil {
                self.appliedLeverage[cacheKey] = wanted.key
            }
        }
    }

    /// Cancels resting orders: every wallet's, or one wallet's, on every market or one. One request per wallet.
    /// Returns a line saying what happened.
    func cancelAll(walletID: UUID? = nil, coin: String? = nil, directory: MarketDirectory) async -> String {
        var cancelled = 0
        var failures: [String] = []
        for wallet in wallets where walletID == nil || wallet.id == walletID {
            let orders = (accounts[wallet.id]?.orders ?? []).filter { coin == nil || $0.coin == coin }
            let cancels = orders.compactMap { order in directory.markets[order.coin].map { (asset: $0.index, orderID: order.id) } }
            guard !cancels.isEmpty else { continue }
            do {
                try await HyperliquidExchange.send(HLAction.cancel(cancels), privateKey: privateKey(for: wallet.id))
                cancelled += cancels.count
                // Gone from the list at once; the exchange's own list follows.
                if var account = accounts[wallet.id] {
                    let ids = Set(cancels.map(\.orderID))
                    account.orders.removeAll { ids.contains($0.id) }
                    accounts[wallet.id] = account
                }
            } catch {
                failures.append("\(wallet.name): \(error.localizedDescription)")
            }
            let id = wallet.id
            Task { await refresh(id) }
        }
        if !failures.isEmpty { return "Cancel failed. " + failures.joined(separator: " ") }
        return cancelled == 0 ? "No resting orders to cancel" : "Cancelled \(cancelled) order\(cancelled == 1 ? "" : "s")"
    }

    func cancel(_ order: HLOpenOrder, asset: Int, walletID: UUID) async throws {
        try await HyperliquidExchange.send(
            HLAction.cancel(asset: asset, orderID: order.id),
            privateKey: privateKey(for: walletID)
        )
        Task { await refresh(walletID) }
    }
}
