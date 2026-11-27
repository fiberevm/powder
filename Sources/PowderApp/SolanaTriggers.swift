import AppKit
import Foundation
import UserNotifications

/// A stop loss or take profit on a Solana holding: when the price gets there, the whole holding is sold for SOL.
struct SolanaTrigger: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable {
        case stopLoss, takeProfit

        var title: String { self == .stopLoss ? "Stop loss" : "Take profit" }
    }

    var id = UUID()
    let walletID: UUID
    let token: MarketRef
    let kind: Kind
    let price: Double
    var firedAt: Date?
    /// What happened when it fired, or why it could not sell.
    var result: String?

    var isActive: Bool { firedAt == nil }

    func isMet(by price: Double) -> Bool {
        kind == .stopLoss ? price <= self.price : price >= self.price
    }
}

/// Watches prices and sells when a stop or target is reached. Solana has no resting stop orders, so this
/// runs inside Powder: it only acts while the app is open and online.
@MainActor
final class SolanaTriggerStore: ObservableObject {
    @Published private(set) var triggers: [SolanaTrigger] = []

    private let defaults: UserDefaults
    private let solana: SolanaWalletProvider
    private let quotes: SolanaQuotes
    private var task: Task<Void, Never>?
    private var selling: Set<UUID> = []
    private var lastBalanceCheck: [UUID: Date] = [:]
    private static let key = "solana.triggers"
    private static let chime = NSSound(named: "Glass")

    init(defaults: UserDefaults = .standard, solana: SolanaWalletProvider, quotes: SolanaQuotes) {
        self.defaults = defaults
        self.solana = solana
        self.quotes = quotes
        triggers = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([SolanaTrigger].self, from: $0) } ?? []
        updateWatching()
    }

    func active(walletID: UUID?, mint: String) -> [SolanaTrigger] {
        triggers.filter { $0.isActive && $0.walletID == walletID && $0.token.mint == mint }
    }

    /// The last thing a trigger did for this holding, for the ticket to show.
    func lastResult(walletID: UUID?, mint: String) -> String? {
        triggers.first { !$0.isActive && $0.walletID == walletID && $0.token.mint == mint }?.result
    }

    /// Sets the stop or the target for a holding, replacing the one it had. Returns why not, when it cannot be set.
    @discardableResult
    func set(_ kind: SolanaTrigger.Kind, walletID: UUID, token: SolanaToken, price: Double, current: Double?) -> String? {
        guard price > 0 else { return "Enter a price." }
        if let current {
            // On the wrong side of the market it would sell at once.
            if kind == .stopLoss, price >= current { return "A stop loss goes below the current price." }
            if kind == .takeProfit, price <= current { return "A take profit goes above the current price." }
        }
        triggers.removeAll { $0.walletID == walletID && $0.token.mint == token.address && ($0.kind == kind || !$0.isActive) }
        triggers.insert(SolanaTrigger(walletID: walletID, token: .solana(token), kind: kind, price: price), at: 0)
        save()
        NotificationPresenter.center?.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        return nil
    }

    func remove(_ id: UUID) {
        triggers.removeAll { $0.id == id }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(triggers) { defaults.set(data, forKey: Self.key) }
        updateWatching()
    }

    private func updateWatching() {
        let waiting = triggers.filter(\.isActive)
        quotes.want(Set(waiting.compactMap(\.token.mint)), for: "triggers")
        if waiting.isEmpty {
            task?.cancel()
            task = nil
        } else if task == nil {
            task = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.check()
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        }
    }

    private func check() async {
        for trigger in triggers where trigger.isActive && !selling.contains(trigger.id) {
            guard let mint = trigger.token.mint else { continue }
            // The holding must be known before anything can be sold; it is re-read now and then while waiting.
            if solana.balances[trigger.walletID] == nil || Date().timeIntervalSince(lastBalanceCheck[trigger.walletID] ?? .distantPast) > 20 {
                lastBalanceCheck[trigger.walletID] = Date()
                await solana.refresh(trigger.walletID)
            }
            guard let balances = solana.balances[trigger.walletID] else { continue }
            guard let holding = balances.holding(mint), holding.raw > 0 else {
                // Sold by hand: nothing left to protect.
                remove(trigger.id)
                continue
            }
            guard let price = quotes.stats[mint]?.price, price > 0, trigger.isMet(by: price) else { continue }
            selling.insert(trigger.id)
            Task { await sell(trigger, amount: holding.raw, at: price) }
        }
    }

    /// Sells the whole holding for SOL. A swap that fails (the price ran past the slippage) is tried again a few times.
    private func sell(_ trigger: SolanaTrigger, amount: UInt64, at price: Double) async {
        defer { selling.remove(trigger.id) }
        guard let mint = trigger.token.mint else { return }
        var failure = ""
        for attempt in 1...3 {
            do {
                let raw = solana.balances[trigger.walletID]?.holding(mint)?.raw ?? amount
                let fill = try await solana.swap(walletID: trigger.walletID, input: mint, output: SolanaRPC.wrappedSOL, amount: raw, outputDecimals: 9)
                let shown = HLFormat.price(price, decimals: PositionLine.priceDecimals(price, isSolana: true))
                finish(trigger, "\(trigger.kind.title) sold \(trigger.token.symbol) at about \(shown) for \(HLFormat.size(Double(fill.received) / 1e9, decimals: 4)) SOL", succeeded: true)
                return
            } catch {
                failure = error.localizedDescription
                HyperliquidExchange.log("solana trigger \(trigger.token.symbol) attempt \(attempt) failed: \(failure)")
                try? await Task.sleep(for: .seconds(1.5))
            }
        }
        finish(trigger, "\(trigger.kind.title) on \(trigger.token.symbol) was reached but the sale failed: \(failure) Sell it by hand.", succeeded: false)
    }

    private func finish(_ trigger: SolanaTrigger, _ text: String, succeeded: Bool) {
        if let index = triggers.firstIndex(where: { $0.id == trigger.id }) {
            triggers[index].firedAt = Date()
            triggers[index].result = text
        }
        if succeeded {
            // Its partner (the stop, when the target sold) has nothing left to act on.
            triggers.removeAll { $0.isActive && $0.walletID == trigger.walletID && $0.token.mint == trigger.token.mint }
        }
        save()
        if succeeded { Self.chime?.play() } else { OrderSound.failed() }
        let content = UNMutableNotificationContent()
        content.title = "Powder: \(trigger.kind.title.lowercased()) \(succeeded ? "sold" : "failed")"
        content.body = text
        NotificationPresenter.center?.add(UNNotificationRequest(identifier: trigger.id.uuidString, content: content, trigger: nil))
    }
}
