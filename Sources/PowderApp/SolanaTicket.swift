import SwiftUI

/// What a Solana ticket pays with and sells into. A token tab is not always priced against SOL.
struct SolanaQuoteCurrency: Equatable, Identifiable {
    let symbol: String
    let mint: String
    let decimals: Int

    var id: String { mint }

    static let sol = SolanaQuoteCurrency(symbol: "SOL", mint: SolanaRPC.wrappedSOL, decimals: 9)
    static let all = [
        sol,
        SolanaQuoteCurrency(symbol: "USDC", mint: "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v", decimals: 6),
        SolanaQuoteCurrency(symbol: "USDT", mint: "Es9vMFrzaCERmJfrF4H2FYD4KCoNkY11McCe8BenwNYB", decimals: 6),
    ]
}

/// Buy / sell for a Solana token tab: wallet, what to pay with, a size to buy, a share of the holding to sell.
/// Swaps are routed by Jupiter, signed here, and landed through Nozomi.
struct SolanaTicket: View {
    let model: PerpsModel
    @EnvironmentObject private var wallets: WalletProvider
    @EnvironmentObject private var triggers: SolanaTriggerStore
    @Environment(\.openSettings) private var openSettings

    @State private var buyText = ""
    /// The other side of the swap, remembered across tabs.
    @AppStorage("solana.quote") private var quoteMint = SolanaRPC.wrappedSOL
    @State private var sellFraction = 1.0
    @State private var stopText = ""
    @State private var targetText = ""
    @State private var isSending = false
    @State private var message: String?
    @State private var messageIsError = false
    @FocusState private var isSizeFocused: Bool

    private var solana: SolanaWalletProvider { wallets.solana }

    /// The currencies this token can be traded against: every one but itself.
    private var quotes: [SolanaQuoteCurrency] {
        SolanaQuoteCurrency.all.filter { $0.mint != model.solana?.address }
    }

    private var quote: SolanaQuoteCurrency {
        quotes.first { $0.mint == quoteMint } ?? quotes.first ?? .sol
    }

    /// What the wallet can pay with: SOL keeps back the tip and fees, a token is its whole balance.
    private func spendable(_ wallet: SolanaWallet) -> Double {
        quote.mint == SolanaRPC.wrappedSOL
            ? solana.spendableSOL(wallet.id)
            : solana.balances[wallet.id]?.holding(quote.mint)?.amount ?? 0
    }

    private var quotePrice: Double? {
        solana.prices[quote.mint]?.price ?? (SolanaTokens.stablecoins.contains(quote.mint) ? 1 : nil)
    }

    private var quoteItems: [DropdownItem] {
        quotes.map { option in
            DropdownItem(option.symbol, isSelected: option == quote) {
                quoteMint = option.mint
                fillDefault()
            }
        }
    }

    private static func round(_ value: Double) -> Double { (value * 10_000).rounded(.down) / 10_000 }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("ORDER").font(Term.font(11, .bold))
                Spacer()
                if let wallet = solana.selected {
                    TermDropdown(wallet.name, items: walletItems, minWidth: 200)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 30)

            if let wallet = solana.selected, let token = model.solana {
                ticket(wallet, token)
            } else {
                empty
            }
        }
        .font(Term.font(11.5))
        .foregroundStyle(Term.foreground)
        .onAppear {
            wallets.watch(true)
            if buyText.isEmpty { fillDefault() }
        }
        .onDisappear { wallets.watch(false) }
        .task(id: solana.selectedID) {
            guard let id = solana.selectedID else { return }
            await wallets.preloadKey(id)
            await solana.refresh(id)
        }
        .onChange(of: solana.selectedID) {
            message = nil
            fillDefault()
        }
        .onChange(of: model.ticketFocusRequest) { isSizeFocused = true }
        .onChange(of: model.orderHotkey) { _, hotkey in
            guard let hotkey, let wallet = solana.selected, let token = model.solana else { return }
            if hotkey.isBuy { buy(wallet, token) } else { sell(wallet, token) }
        }
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(wallets.wallets.isEmpty
                ? "No wallet yet. Create or import one to trade this token."
                : "Reading this wallet's Solana address…")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                openSettings()
            } label: {
                InverseLabel(text: "WALLETS  ⌘,")
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }

    private var walletItems: [DropdownItem] {
        var items = solana.wallets.map { wallet in
            DropdownItem(wallet.name, id: wallet.id.uuidString, detail: wallet.shortAddress, isSelected: wallet.id == solana.selectedID) {
                wallets.selectedID = wallet.id
            }
        }
        items.append(DropdownItem("Manage wallets…", detail: "⌘,", startsSection: true) { openSettings() })
        return items
    }

    // MARK: Ticket

    private func ticket(_ wallet: SolanaWallet, _ token: SolanaToken) -> some View {
        let balances = solana.balances[wallet.id]
        let holding = balances?.holding(token.address)
        let spendable = spendable(wallet)
        let quote = quote
        let price = model.lastPrice ?? solana.prices[token.address]?.price
        let buySOL = Double(buyText.replacingOccurrences(of: ",", with: ".")) ?? 0
        let held = holding?.amount ?? 0
        let cost = solana.costs[SolanaWalletProvider.costKey(wallet.id, token.address)]

        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text("AVAIL").foregroundStyle(.secondary)
                Text(balances == nil ? "…" : "\(HLFormat.size(quote.mint == SolanaRPC.wrappedSOL ? balances?.sol ?? 0 : spendable, decimals: 4)) \(quote.symbol)")
                Button {
                    Task { await solana.refresh(wallet.id) }
                } label: {
                    Text("↻").foregroundStyle(Term.accent)
                }
                .buttonStyle(.plain)
                .help("Reload this wallet's balances")
                Spacer(minLength: 4)
                Text(Nozomi.hasKey ? "NOZOMI" : "RPC")
                    .font(Term.font(9.5, .semibold))
                    .foregroundStyle(Nozomi.hasKey ? Term.accent : Color.secondary)
                    .help(Nozomi.hasKey
                        ? "Swaps are sent through Nozomi with a \(HLWire.number(Double(wallet.settings.tipLamports) / 1e9)) SOL tip"
                        : "No Nozomi key: swaps go through the public RPC, which is slower. Add a key in Settings → Solana.")
            }

            // Buy: a size in the paying currency, as a share of what the wallet can spend.
            HStack(spacing: 6) {
                Text("BUY").foregroundStyle(.secondary).frame(width: 30, alignment: .leading)
                TextField("0", text: $buyText)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.trailing)
                    .focused($isSizeFocused)
                    .onSubmit { isSizeFocused = false }
                TermDropdown(items: quoteItems, minWidth: 90) { isOpen in
                    HStack(spacing: 3) {
                        Text(quote.symbol).foregroundStyle(Term.accent)
                        Text(isOpen ? "▴" : "▾").font(Term.font(8)).foregroundStyle(Term.accent)
                    }
                }
                .help("What to pay with when buying and receive when selling")
            }
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(Term.background)
            .overlay(Rectangle().stroke(isSizeFocused ? Term.accent : Term.rule, lineWidth: 1))
            .onChange(of: buyText) { _, text in
                // Never more than the wallet can spend.
                if let typed = Double(text.replacingOccurrences(of: ",", with: ".")), balances != nil, typed > spendable {
                    buyText = HLWire.number(Self.round(spendable))
                }
            }

            TermSlider(fraction: spendable > 0 ? min(buySOL / spendable, 1) : 0) { fraction in
                buyText = HLWire.number(Self.round(spendable * fraction))
            }

            HStack(spacing: 6) {
                if let price, let paid = quotePrice, buySOL > 0, price > 0 {
                    Text("≈ \(HLFormat.amount(buySOL * paid / price)) \(token.symbol)").foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Text("MAX \(HLFormat.size(spendable, decimals: 4))").foregroundStyle(.secondary)
            }
            .font(Term.font(10.5))

            action("BUY \(token.symbol)  ⇧B", color: PowderPalette.signalGreen) { buy(wallet, token) }
                .disabled(isSending || buySOL <= 0)

            TermRule().padding(.vertical, 2)

            // Sell: a share of the holding, for the same currency.
            HStack(spacing: 6) {
                Text("HOLD").foregroundStyle(.secondary)
                Text(held > 0 ? "\(HLFormat.amount(held)) \(token.symbol)" : "—")
                Spacer(minLength: 4)
                if let price, held > 0 {
                    Text("$" + HLFormat.price(held * price, decimals: 2)).foregroundStyle(.secondary)
                }
            }
            if let cost, let price, held > 0 {
                let pnl = (price - cost) * held
                HStack(spacing: 6) {
                    Text("PNL").foregroundStyle(.secondary)
                    Text(PositionsView.signed(pnl)).foregroundStyle(PowderPalette.market(pnl))
                    Text(HLFormat.percent(price / cost - 1)).foregroundStyle(PowderPalette.market(pnl))
                    Spacer(minLength: 0)
                }
            }

            if held > 0 {
                triggerRow(.takeProfit, text: $targetText, wallet: wallet, token: token, price: price)
                triggerRow(.stopLoss, text: $stopText, wallet: wallet, token: token, price: price)
                if let result = triggers.lastResult(walletID: wallet.id, mint: token.address) {
                    Text(result)
                        .font(Term.font(10.5))
                        .foregroundStyle(Term.accent)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineLimit(3)
                }
            }

            TermSlider(fraction: sellFraction) { sellFraction = max($0, 0.01) }
                .disabled(held <= 0)
                .opacity(held > 0 ? 1 : 0.4)

            action("SELL \(Int((sellFraction * 100).rounded()))% FOR \(quote.symbol)  ⇧S", color: PowderPalette.riskCoral) { sell(wallet, token) }
                .disabled(isSending || held <= 0)

            if let text = message ?? solana.errors[wallet.id] {
                Text(text)
                    .font(Term.font(10.5))
                    .foregroundStyle(message == nil || messageIsError ? PowderPalette.riskCoral : PowderPalette.signalGreen)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(4)
                    .textSelection(.enabled)
            }
        }
        .lineLimit(1)
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    /// A stop or a target for the whole holding: shown with a ✕ when set, a field to type a price when not.
    private func triggerRow(
        _ kind: SolanaTrigger.Kind, text: Binding<String>, wallet: SolanaWallet, token: SolanaToken, price: Double?
    ) -> some View {
        let existing = triggers.active(walletID: wallet.id, mint: token.address).first { $0.kind == kind }
        let color = kind == .stopLoss ? PowderPalette.riskCoral : PowderPalette.signalGreen
        return HStack(spacing: 6) {
            Text(kind == .stopLoss ? "STOP" : "TAKE").foregroundStyle(.secondary).frame(width: 34, alignment: .leading)
            if let existing {
                Text("$" + HLFormat.price(existing.price, decimals: PositionLine.priceDecimals(existing.price, isSolana: true)))
                    .foregroundStyle(color)
                if let price, price > 0 {
                    Text(HLFormat.percent(existing.price / price - 1)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Button {
                    triggers.remove(existing.id)
                } label: {
                    Text("✕").foregroundStyle(.secondary).frame(width: 16, height: 16).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Remove this \(kind.title.lowercased())")
            } else {
                TextField(kind == .stopLoss ? "sell all below $" : "sell all above $", text: text)
                    .textFieldStyle(.plain)
                    .onSubmit {
                        guard let value = Double(text.wrappedValue.replacingOccurrences(of: ",", with: ".").replacingOccurrences(of: "$", with: "")) else {
                            return report("Type a price in dollars.", isError: true)
                        }
                        if let problem = triggers.set(kind, walletID: wallet.id, token: token, price: value, current: price) {
                            report(problem, isError: true)
                        } else {
                            text.wrappedValue = ""
                            report("\(kind.title) set. It sells the whole holding for SOL while Powder is open.", isError: false)
                        }
                    }
            }
        }
        .font(Term.font(11))
        .frame(height: 18)
        .help(kind == .stopLoss
            ? "Sells the whole holding for SOL when the price falls to this. Works only while Powder is open."
            : "Sells the whole holding for SOL when the price rises to this. Works only while Powder is open.")
    }

    private func action(_ title: String, color: Color, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Text(title)
                .font(Term.font(11, .bold))
                .foregroundStyle(PowderPalette.graphite)
                .frame(maxWidth: .infinity)
                .frame(height: 26)
                .background(color)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isSending ? 0.5 : 1)
    }

    /// The wallet's default buy is in SOL; another currency starts at the same value.
    private func fillDefault() {
        let sol = solana.selected?.settings.defaultBuySOL ?? SolanaTradeSettings().defaultBuySOL
        guard quote != .sol, let solPrice = solana.solPrice, let paid = quotePrice, paid > 0 else {
            buyText = HLWire.number(sol)
            return
        }
        buyText = HLWire.number((sol * solPrice / paid).rounded())
    }

    // MARK: Sending

    private func buy(_ wallet: SolanaWallet, _ token: SolanaToken) {
        let quote = quote
        let amount = Double(buyText.replacingOccurrences(of: ",", with: ".")) ?? 0
        guard amount > 0 else { return report("Type how much \(quote.symbol) to spend.", isError: true) }
        let available = spendable(wallet)
        guard amount <= available + 1e-9 else {
            let reason = quote == .sol ? " after the tip and fees" : ""
            return report("Not enough \(quote.symbol): this wallet can spend \(HLFormat.size(available, decimals: 4))\(reason).", isError: true)
        }
        guard quote == .sol || (solana.balances[wallet.id]?.sol ?? 0) > 0.002 else {
            return report("This wallet needs a little SOL for the network fee and tip.", isError: true)
        }
        let raw = UInt64((amount * pow(10, Double(quote.decimals))).rounded())
        let decimals = model.solanaStats?.decimals ?? solana.balances[wallet.id]?.holding(token.address)?.decimals
        send(wallet, input: quote.mint, output: token.address, amount: raw, outputDecimals: decimals) { received in
            let got = decimals.map { HLFormat.amount(Double(received) / pow(10, Double($0))) + " " } ?? ""
            return "Bought \(got)\(token.symbol) for \(HLWire.number(amount)) \(quote.symbol)"
        }
    }

    private func sell(_ wallet: SolanaWallet, _ token: SolanaToken) {
        let quote = quote
        guard let holding = solana.balances[wallet.id]?.holding(token.address), holding.raw > 0 else {
            return report("This wallet holds no \(token.symbol).", isError: true)
        }
        // All of it is sold exactly; a share is rounded down to whole units.
        let amount = sellFraction >= 0.999 ? holding.raw : UInt64((Double(holding.raw) * sellFraction).rounded(.down))
        let share = Int((sellFraction * 100).rounded())
        send(wallet, input: token.address, output: quote.mint, amount: amount, outputDecimals: quote.decimals) { received in
            "Sold \(share)% of \(token.symbol) for \(HLFormat.size(Double(received) / pow(10, Double(quote.decimals)), decimals: 4)) \(quote.symbol)"
        }
    }

    /// The result is shown, with the ping, as soon as the swap is priced; landing confirms it or takes it back.
    private func send(
        _ wallet: SolanaWallet, input: String, output: String, amount: UInt64, outputDecimals: Int?,
        describe: @escaping (UInt64) -> String
    ) {
        guard !isSending else { return }
        isSending = true
        report("Sending…", isError: false)
        Task {
            defer { isSending = false }
            var shown = false
            do {
                let fill = try await solana.swap(
                    walletID: wallet.id, input: input, output: output, amount: amount, outputDecimals: outputDecimals
                ) { stage in
                    if case let .quoted(received) = stage {
                        shown = true
                        OrderSound.done()
                        report("\(describe(received)) · landing…", isError: false)
                    }
                }
                if !shown { OrderSound.done() }
                report("\(describe(fill.received)) · landed in \(fill.milliseconds) ms\(fill.usedNozomi ? "" : " (public RPC)")", isError: false)
            } catch {
                if shown { OrderSound.failed() }
                report((shown ? "Did not go through, and the wallet is as it was. " : "") + error.localizedDescription, isError: true)
            }
        }
    }

    private func report(_ text: String, isError: Bool) {
        message = text
        messageIsError = isError
    }
}
