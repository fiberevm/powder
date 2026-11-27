import AppKit
import SwiftUI

/// The ping played when the exchange confirms an order.
@MainActor
enum OrderSound {
    private static let ping = NSSound(named: "Ping")

    static func done() {
        ping?.stop()
        ping?.play()
    }

    private static let basso = NSSound(named: "Basso")

    /// An order that was shown as done did not go through.
    static func failed() {
        ping?.stop()
        basso?.stop()
        basso?.play()
    }
}

/// Buy / sell for the tab's market: wallet selector, market or limit, a size, and the two buttons.
/// Also shows the selected wallet's balance, its position here and its resting orders.
struct OrderTicket: View {
    let model: PerpsModel
    @EnvironmentObject private var wallets: WalletProvider
    @Environment(\.openSettings) private var openSettings

    private enum Kind { case market, limit }
    private enum Field { case size, price }

    @State private var kind = Kind.market
    @State private var sizeText = ""
    @State private var sizeInUSD = true
    @State private var priceText = ""
    @State private var reduceOnly = false
    @State private var isSending = false
    @State private var message: String?
    @State private var messageIsError = false
    @FocusState private var focus: Field?

    private static let leverageSteps = [1, 2, 3, 5, 10, 15, 20, 25, 40, 50]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("ORDER")
                    .font(Term.font(11, .bold))
                Spacer()
                if let wallet = wallets.selected {
                    TermDropdown(wallet.name, items: walletItems, minWidth: 200)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 30)

            if let wallet = wallets.selected {
                ticket(wallet)
            } else {
                empty
            }
        }
        .font(Term.font(11.5))
        .foregroundStyle(Term.foreground)
        .onAppear {
            wallets.watch(true)
            fillDefaults()
        }
        .onDisappear { wallets.watch(false) }
        .onChange(of: wallets.selectedID) {
            message = nil
            sizeText = ""
            fillDefaults()
        }
        .onChange(of: model.coin) {
            message = nil
            priceText = ""
        }
        .onChange(of: model.ticketFocusRequest) { focus = .size }
        .onChange(of: sizeText) { clampSize() }
        .onChange(of: reduceOnly) { clampSize() }
        .onChange(of: currentLimit) { clampSize() }
        // Leverage is matched on the exchange as soon as the market is on screen, so an order is one request.
        // Reads the key from the Keychain now, so the first order does not wait on it (or on its permission prompt).
        .task(id: wallets.selectedID) {
            if let id = wallets.selectedID { await wallets.preloadKey(id) }
        }
        .task(id: leverageKey) {
            if let wallet = wallets.selected, let market { wallets.syncLeverage(walletID: wallet.id, market: market) }
        }
        // ⇧B and ⇧S send straight from the keyboard.
        .onChange(of: model.orderHotkey) { _, hotkey in
            guard let hotkey, let wallet = wallets.selected, !isSending else { return }
            submit(wallet, isBuy: hotkey.isBuy)
        }
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No wallet yet. Create or import one to trade.")
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

    // MARK: Ticket

    private func ticket(_ wallet: Wallet) -> some View {
        let account = wallets.accounts[wallet.id]
        let position = account?.positions.first { $0.coin == model.coin }
        let orders = account?.orders.filter { $0.coin == model.coin } ?? []

        return VStack(spacing: 8) {
            HStack(spacing: 6) {
                Text("AVAIL").foregroundStyle(.secondary)
                Text(account.map { "$" + HLFormat.price($0.withdrawable, decimals: 2) } ?? "—")
                Button {
                    reload(wallet)
                } label: {
                    Text("↻").foregroundStyle(.secondary).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Reload this wallet's balance")
                Spacer(minLength: 4)
                TermDropdown(
                    "\(leverage(wallet))x \(wallet.settings.isCross ? "CROSS" : "ISO")",
                    items: leverageItems(wallet), minWidth: 130
                )
            }

            if let account, account.spotUSDC >= 0.01 {
                spotRow(account.spotUSDC, wallet: wallet)
            }

            HStack(spacing: 0) {
                segment("MARKET", isOn: kind == .market) { kind = .market }
                segment("LIMIT", isOn: kind == .limit) {
                    kind = .limit
                    if priceText.isEmpty, let price = referencePrice {
                        priceText = HLWire.number(HLWire.price(price, szDecimals: model.sizeDecimals))
                    }
                }
                Spacer(minLength: 8)
                Button {
                    reduceOnly.toggle()
                } label: {
                    HStack(spacing: 5) {
                        Text(reduceOnly ? "■" : "□").foregroundStyle(reduceOnly ? Term.accent : Color.secondary)
                        Text("REDUCE").foregroundStyle(reduceOnly ? Term.foreground : Color.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Reduce only: the order can shrink or close a position but never open or flip one")
            }

            if kind == .limit {
                field("PRICE", text: $priceText, focused: .price) {
                    Button("MID") {
                        if let price = referencePrice { priceText = HLWire.number(HLWire.price(price, szDecimals: model.sizeDecimals)) }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }

            field("SIZE", text: $sizeText, focused: .size) {
                Button {
                    convertSizeUnit()
                } label: {
                    Text(sizeInUSD ? "USD" : model.coin)
                        .foregroundStyle(Term.accent)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Switch between a size in USD and in \(model.coin)")
            }

            let limit = maxUSD(wallet: wallet, account: account, position: position)
            if let limit, limit > 0 {
                TermSlider(fraction: sizeFraction(of: limit)) { setSize(fraction: $0, of: limit) }
            }

            HStack(spacing: 6) {
                Text(sizeSummary).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if let limit {
                    Text("\(Int((sizeFraction(of: limit) * 100).rounded()))%").foregroundStyle(Term.accent)
                    Text("MAX $\(HLFormat.price(limit, decimals: 2))").foregroundStyle(.secondary)
                }
            }
            .font(Term.font(10.5))

            HStack(spacing: 6) {
                action("BUY / LONG  ⇧B", color: PowderPalette.signalGreen) { submit(wallet, isBuy: true) }
                action("SELL / SHORT  ⇧S", color: PowderPalette.riskCoral) { submit(wallet, isBuy: false) }
            }
            .disabled(isSending)
            .opacity(isSending ? 0.5 : 1)

            if let text = message ?? wallets.accountErrors[wallet.id] {
                Text(text)
                    .font(Term.font(10.5))
                    .foregroundStyle(message == nil || messageIsError ? PowderPalette.riskCoral : PowderPalette.signalGreen)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(3)
            }

            if let position {
                positionRow(position, wallet: wallet)
            }
            ForEach(orders) { order in
                orderRow(order, wallet: wallet)
            }
            if orders.count > 1 {
                Button {
                    Task {
                        let result = await wallets.cancelAll(walletID: wallet.id, coin: model.coin)
                        messageIsError = result.hasPrefix("Cancel failed")
                        message = result
                    }
                } label: {
                    Text("CANCEL ALL \(orders.count) ORDERS")
                        .font(Term.font(10.5, .semibold))
                        .foregroundStyle(PowderPalette.riskCoral)
                        .frame(maxWidth: .infinity)
                        .frame(height: 20)
                        .overlay(Rectangle().stroke(PowderPalette.riskCoral.opacity(0.6), lineWidth: 1))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .lineLimit(1)
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    private func segment(_ title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            InverseLabel(text: title, isActive: isOn).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func field(
        _ label: String, text: Binding<String>, focused: Field, @ViewBuilder trailing: () -> some View
    ) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 38, alignment: .leading)
            TextField("0", text: text)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .focused($focus, equals: focused)
            trailing()
                .font(Term.font(10.5, .semibold))
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(Term.chrome)
        .overlay(Rectangle().stroke(focus == focused ? Term.accent : Term.rule, lineWidth: 1))
    }

    private func action(_ title: String, color: Color, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Text(title)
                .font(Term.font(11.5, .bold))
                .foregroundStyle(PowderPalette.graphite)
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                .background(color)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// USDC in the spot balance cannot back a perp order; this moves it across.
    private func spotRow(_ amount: Double, wallet: Wallet) -> some View {
        HStack(spacing: 6) {
            Text("SPOT").foregroundStyle(.secondary)
            Text("$" + HLFormat.price(amount, decimals: 2))
            Spacer(minLength: 4)
            Button {
                moveToPerps(amount, wallet: wallet)
            } label: {
                Text("MOVE TO PERPS →")
                    .font(Term.font(10.5, .bold))
                    .foregroundStyle(PowderPalette.graphite)
                    .padding(.horizontal, 6)
                    .frame(height: 18)
                    .background(Term.accent)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isSending)
            .help("Perp orders only use the perp balance. This moves all spot USDC into it; it is free and instant.")
        }
    }

    private func positionRow(_ position: HLPosition, wallet: Wallet) -> some View {
        let isLong = position.size > 0
        return VStack(spacing: 4) {
            TermRule()
            HStack(spacing: 6) {
                Text(isLong ? "LONG" : "SHORT")
                    .font(Term.font(10.5, .bold))
                    .foregroundStyle(isLong ? PowderPalette.signalGreen : PowderPalette.riskCoral)
                Text("\(HLWire.number(abs(position.size))) @ \(HLFormat.price(position.entryPrice, decimals: model.priceDecimals))")
                Spacer(minLength: 4)
                Button {
                    closePosition(position, wallet: wallet)
                } label: {
                    Text("CLOSE")
                        .font(Term.font(10.5, .bold))
                        .padding(.horizontal, 6)
                        .frame(height: 18)
                        .overlay(Rectangle().stroke(Term.rule, lineWidth: 1))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isSending)
                .help("Close the whole position at market")
            }
            HStack(spacing: 6) {
                Text("PNL").foregroundStyle(.secondary)
                Text((position.unrealizedPnl >= 0 ? "+" : "−") + "$" + HLFormat.price(abs(position.unrealizedPnl), decimals: 2))
                    .foregroundStyle(PowderPalette.market(position.unrealizedPnl))
                Spacer(minLength: 4)
                Text("LIQ").foregroundStyle(.secondary)
                Text(position.liquidationPrice.map { HLFormat.price($0, decimals: model.priceDecimals) } ?? "—")
                Text("\(position.leverage)x").foregroundStyle(.secondary)
            }
            .font(Term.font(10.5))
        }
    }

    private func orderRow(_ order: HLOpenOrder, wallet: Wallet) -> some View {
        HStack(spacing: 6) {
            Text(order.isBuy ? "BID" : "ASK")
                .font(Term.font(10.5, .bold))
                .foregroundStyle(order.isBuy ? PowderPalette.signalGreen : PowderPalette.riskCoral)
            Text("\(HLWire.number(order.size)) @ \(HLFormat.price(order.price, decimals: model.priceDecimals))")
            Spacer(minLength: 4)
            Button {
                cancel(order, wallet: wallet)
            } label: {
                Text("✕")
                    .frame(width: 18, height: 18)
                    .overlay(Rectangle().stroke(Term.rule, lineWidth: 1))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isSending)
            .help("Cancel this order")
        }
        .font(Term.font(10.5))
    }

    // MARK: Values

    private var leverageKey: String {
        guard let wallet = wallets.selected, let market else { return "" }
        let funded = (wallets.accounts[wallet.id]?.accountValue ?? 0) > 0
        return "\(wallet.id)|\(market.name)|\(wallet.settings.leverage)|\(wallet.settings.isCross)|\(funded)"
    }

    private var market: HLMarket? { model.market }

    /// The mid, falling back to the last trade.
    private var referencePrice: Double? { model.ctx?.midPx ?? model.lastPrice }

    private func number(_ text: String) -> Double? {
        Double(text.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "$", with: "").trimmingCharacters(in: .whitespaces))
    }

    private var orderPrice: Double? {
        kind == .limit ? number(priceText) : referencePrice
    }

    /// The typed size in coins.
    private var coinSize: Double? {
        guard let value = number(sizeText), value > 0 else { return nil }
        guard sizeInUSD else { return value }
        guard let price = orderPrice, price > 0 else { return nil }
        return value / price
    }

    /// The largest order the wallet can place here, in USD: free margin times leverage, a little under
    /// to leave room for the fee and slippage, plus any open position the order would close.
    /// With REDUCE on, it is the position itself.
    private func maxUSD(wallet: Wallet, account: HLAccountState?, position: HLPosition?, isBuy: Bool? = nil) -> Double? {
        guard let account else { return nil }
        let held = position.flatMap { position in orderPrice.map { abs(position.size) * $0 } } ?? 0
        if reduceOnly { return held }
        let fresh = account.withdrawable * Double(leverage(wallet)) * 0.97
        // An order against an open position can also be as large as that position, since it closes it first.
        let closes = position.map { held in isBuy.map { buy in buy == (held.size < 0) } ?? true } ?? false
        return ((fresh + (closes ? held : 0)) * 100).rounded(.down) / 100
    }

    private func sizeFraction(of limit: Double) -> Double {
        guard limit > 0, let size = coinSize, let price = orderPrice else { return 0 }
        return min(max(size * price / limit, 0), 1)
    }

    /// The cap for the selected wallet right now.
    private var currentLimit: Double? {
        guard let wallet = wallets.selected else { return nil }
        let account = wallets.accounts[wallet.id]
        return maxUSD(wallet: wallet, account: account, position: account?.positions.first { $0.coin == model.coin })
    }

    /// Pulls a size above the cap back down to it.
    private func clampSize() {
        guard let limit = currentLimit, limit > 0, let size = coinSize, let price = orderPrice, price > 0,
              size * price > limit * 1.0001 else { return }
        // A field being typed in ignores a change made during its own update, so apply it just after.
        Task { @MainActor in setSize(fraction: 1, of: limit, keepFocus: true) }
    }

    private func setSize(fraction: Double, of limit: Double, keepFocus: Bool = false) {
        // A focused field would keep showing what was typed instead of the slider's value.
        if !keepFocus { focus = nil }
        let usd = (limit * fraction * 100).rounded(.down) / 100
        if sizeInUSD {
            sizeText = HLWire.number(usd)
        } else if let price = orderPrice, price > 0 {
            sizeText = HLWire.number(HLWire.size(usd / price, szDecimals: model.sizeDecimals))
        }
    }

    private var sizeSummary: String {
        guard let size = coinSize, let price = orderPrice else { return "min order $10" }
        let rounded = HLWire.size(size, szDecimals: model.sizeDecimals)
        return sizeInUSD
            ? "≈ \(HLWire.number(rounded)) \(model.coin)"
            : "≈ $\(HLFormat.price(rounded * price, decimals: 2))"
    }

    private func leverage(_ wallet: Wallet) -> Int {
        min(max(wallet.settings.leverage, 1), market?.maxLeverage ?? 50)
    }

    private var walletItems: [DropdownItem] {
        var items = wallets.wallets.map { wallet in
            DropdownItem(
                wallet.name, id: wallet.id.uuidString, detail: wallet.shortAddress,
                isSelected: wallet.id == wallets.selectedID
            ) { wallets.selectedID = wallet.id }
        }
        items.append(DropdownItem("Manage wallets…", detail: "⌘,", startsSection: true) { openSettings() })
        return items
    }

    private func leverageItems(_ wallet: Wallet) -> [DropdownItem] {
        let limit = market?.maxLeverage ?? 50
        var items = Self.leverageSteps.filter { $0 <= limit }.map { step in
            DropdownItem("\(step)x", isSelected: step == leverage(wallet)) {
                var changed = wallet
                changed.settings.leverage = step
                wallets.update(changed)
            }
        }
        items.append(DropdownItem("Cross margin", isSelected: wallet.settings.isCross, startsSection: true) {
            var changed = wallet
            changed.settings.isCross = true
            wallets.update(changed)
        })
        items.append(DropdownItem("Isolated margin", isSelected: !wallet.settings.isCross) {
            var changed = wallet
            changed.settings.isCross = false
            wallets.update(changed)
        })
        return items
    }

    // MARK: Actions

    private func fillDefaults() {
        guard sizeText.isEmpty, let wallet = wallets.selected else { return }
        sizeInUSD = true
        sizeText = HLWire.number(wallet.settings.defaultSizeUSD)
    }

    private func convertSizeUnit() {
        if let value = number(sizeText), let price = orderPrice, price > 0 {
            sizeText = sizeInUSD
                ? HLWire.number(HLWire.size(value / price, szDecimals: model.sizeDecimals))
                : HLWire.number((value * price * 100).rounded() / 100)
        }
        sizeInUSD.toggle()
    }

    private func fail(_ text: String) {
        message = text
        messageIsError = true
    }

    private func submit(_ wallet: Wallet, isBuy: Bool) {
        message = nil
        guard let market else { return fail("Market details are still loading.") }
        guard let size = coinSize else { return fail("Enter a size.") }
        let account = wallets.accounts[wallet.id]
        if let limit = maxUSD(wallet: wallet, account: account, position: account?.positions.first { $0.coin == model.coin }, isBuy: isBuy),
           let price = orderPrice, size * price > limit * 1.0001 {
            return fail("That is above this wallet's maximum here, $\(HLFormat.price(limit, decimals: 2)).")
        }
        if kind == .limit, (number(priceText) ?? 0) <= 0 { return fail("Enter a limit price.") }
        do {
            let order = try wallets.prepare(
                wallet: wallet, market: market, isBuy: isBuy, size: size,
                limitPrice: kind == .limit ? number(priceText) : nil,
                referencePrice: referencePrice, reduceOnly: reduceOnly
            )
            send(order)
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func closePosition(_ position: HLPosition, wallet: Wallet) {
        message = nil
        guard let market else { return fail("Market details are still loading.") }
        do {
            let order = try wallets.prepare(
                wallet: wallet, market: market, isBuy: position.size < 0, size: abs(position.size),
                limitPrice: nil, referencePrice: referencePrice, reduceOnly: true
            )
            send(order)
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func send(_ order: WalletProvider.PreparedOrder) {
        isSending = true
        messageIsError = false
        // A market order is shown as done the moment it is sent; the exchange's answer confirms or corrects it.
        let isInstant = order.isMarket && order.expectedPrice != nil
        if isInstant, let expected = order.expectedPrice {
            OrderSound.done()
            message = "\(order.isBuy ? "Bought" : "Sold") \(HLWire.number(order.size)) \(order.market.name) at ≈\(HLFormat.price(expected, decimals: model.priceDecimals)) · confirming…"
        } else {
            message = "Sending…"
        }
        let started = ContinuousClock.now
        Task {
            defer { isSending = false }
            do {
                let outcome = try await wallets.send(order)
                let elapsed = ContinuousClock.now - started
                let took = " \(Int(elapsed.components.seconds * 1_000 + elapsed.components.attoseconds / 1_000_000_000_000_000)) ms"
                messageIsError = false
                if !isInstant { OrderSound.done() }
                switch outcome {
                case let .filled(size, price):
                    message = "Filled \(HLWire.number(size)) \(order.market.name) at \(HLFormat.price(price, decimals: model.priceDecimals)) in\(took)."
                case .resting, .done where isInstant:
                    // Shown as filled, but nothing traded: the account has already been put back.
                    OrderSound.failed()
                    fail("Not filled: the price moved past this wallet's slippage. Nothing was traded.")
                case .resting:
                    message = "Order resting on the book in\(took)."
                case .done:
                    message = "Sent in\(took)."
                }
            } catch {
                if isInstant { OrderSound.failed() }
                let text = error.localizedDescription
                // The exchange's message does not say where the money is.
                if text.localizedCaseInsensitiveContains("margin"),
                   let spot = wallets.accounts[order.walletID]?.spotUSDC, spot >= 0.01 {
                    fail("\(text) Your $\(HLFormat.price(spot, decimals: 2)) USDC is in the spot balance: press MOVE TO PERPS above.")
                } else {
                    fail(text)
                }
            }
        }
    }

    private func reload(_ wallet: Wallet) {
        message = nil
        Task {
            await wallets.refresh(wallet.id)
            if wallets.accountErrors[wallet.id] == nil {
                messageIsError = false
                message = "Balance reloaded."
            }
        }
    }

    private func moveToPerps(_ amount: Double, wallet: Wallet) {
        isSending = true
        message = nil
        Task {
            defer { isSending = false }
            do {
                try await wallets.transferUSDC(amount, toPerp: true, walletID: wallet.id)
                messageIsError = false
                message = "Moved $\(HLFormat.price((amount * 100).rounded(.down) / 100, decimals: 2)) to the perp balance."
            } catch {
                fail(error.localizedDescription)
            }
        }
    }

    private func cancel(_ order: HLOpenOrder, wallet: Wallet) {
        guard let market else { return }
        isSending = true
        message = nil
        Task {
            defer { isSending = false }
            do {
                try await wallets.cancel(order, asset: market.index, walletID: wallet.id)
                messageIsError = false
                message = "Order cancelled."
            } catch {
                fail(error.localizedDescription)
            }
        }
    }
}

/// A flat slider from 0 to 100% with stops at each quarter, in the terminal's style.
struct TermSlider: View {
    let fraction: Double
    let onChange: (Double) -> Void

    private static let stops = [0, 0.25, 0.5, 0.75, 1.0]

    var body: some View {
        GeometryReader { geometry in
            let inset: CGFloat = 5
            let span = max(geometry.size.width - inset * 2, 1)
            let x = inset + span * fraction
            ZStack(alignment: .leading) {
                Rectangle().fill(Term.rule).frame(height: 3).padding(.horizontal, inset)
                Rectangle().fill(Term.accent).frame(width: max(x - inset, 0), height: 3).offset(x: inset)
                ForEach(Self.stops, id: \.self) { stop in
                    Rectangle()
                        .fill(stop <= fraction ? Term.accent : Term.paneDivider)
                        .frame(width: 2, height: 9)
                        .offset(x: inset + span * stop - 1)
                }
                Rectangle()
                    .fill(Term.accent)
                    .frame(width: 8, height: 16)
                    .offset(x: x - 4)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                var next = min(max(Double((value.location.x - inset) / span), 0), 1)
                // Settle on a quarter when close to one.
                if let stop = Self.stops.first(where: { abs($0 - next) < 0.025 }) { next = stop }
                onChange(next)
            })
        }
        .frame(height: 18)
        .help("Order size as a share of the most this wallet can open here")
    }
}
