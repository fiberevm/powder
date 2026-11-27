import UserNotifications
import AppKit
import SwiftUI

// MARK: - Layout tree

/// One tab: a Hyperliquid market view, the all-markets table, or the Solana launchpad.
struct WorkspaceTab: Identifiable {
    let id = UUID()
    /// Set on a market tab.
    var market: PerpsModel?
    /// Set on the Markets table tab.
    var list: MarketsModel?
    /// Set on the Positions table tab.
    var positions: PositionsModel?
    /// Set on a web tab.
    var web: WebTabModel?
    /// Set on the trade History tab.
    var history: HistoryModel?
    /// Set on the tabs whose state lives in the router: watchlist, alerts, liquidations.
    var board: Board?

    enum Board: String, CaseIterable {
        case watchlist, alerts, liquidations

        var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
    }

    var isLaunchpad: Bool { market == nil && list == nil && positions == nil && web == nil && history == nil && board == nil }

    /// How the tab is written in the saved layout.
    @MainActor var savedName: String {
        if let market { return market.solana?.savedName ?? "perp:\(market.coin)" }
        if positions != nil { return "positions" }
        if history != nil { return "history" }
        if let board { return board.rawValue }
        if let web { return "web:\(web.url?.absoluteString ?? "")" }
        return list == nil ? "launchpad" : "markets"
    }
}

/// One pane: a tab strip plus the view for its selected tab.
@MainActor
final class PaneGroup: Identifiable {
    nonisolated let id = UUID()
    var tabs: [WorkspaceTab]
    var selectedID: UUID?

    init(tabs: [WorkspaceTab], selectedIndex: Int = 0) {
        self.tabs = tabs
        selectedID = tabs.indices.contains(selectedIndex) ? tabs[selectedIndex].id : tabs.first?.id
    }

    var selectedTab: WorkspaceTab? { tabs.first { $0.id == selectedID } }
}

/// Children laid out side by side (`.horizontal`) or stacked (`.vertical`), each with a share of the space.
@MainActor
final class SplitBox: Identifiable {
    nonisolated let id = UUID()
    let axis: Axis
    var children: [LayoutNode]
    var fractions: [CGFloat]

    init(axis: Axis, children: [LayoutNode], fractions: [CGFloat]? = nil) {
        self.axis = axis
        self.children = children
        self.fractions = fractions ?? Array(repeating: 1 / CGFloat(max(children.count, 1)), count: children.count)
    }
}

enum LayoutNode: Identifiable {
    case group(PaneGroup)
    case split(SplitBox)

    var id: UUID {
        switch self {
        case let .group(group): group.id
        case let .split(box): box.id
        }
    }
}

enum PaneDirection {
    case left, right, up, down
}

/// Where a dragged tab or pane lands relative to a pane.
enum DropZone: Equatable {
    case center, left, right, top, bottom

    var axis: Axis? {
        switch self {
        case .left, .right: .horizontal
        case .top, .bottom: .vertical
        case .center: nil
        }
    }

    var isBefore: Bool { self == .left || self == .top }

    /// The outer third of each side splits that way; the middle drops into the pane.
    static func at(_ point: CGPoint, in size: CGSize) -> DropZone {
        guard size.width > 0, size.height > 0 else { return .center }
        let x = point.x / size.width
        let y = point.y / size.height
        let candidates: [(DropZone, CGFloat)] = [(.left, x), (.right, 1 - x), (.top, y), (.bottom, 1 - y)]
        if let nearest = candidates.min(by: { $0.1 < $1.1 }), nearest.1 < 0.33 { return nearest.0 }
        return .center
    }
}

/// The landing spot currently under a drag, for the drop preview.
struct DropTarget: Equatable {
    let group: UUID
    let zone: DropZone
    /// Insert before this tab position when dropping on the tab strip.
    var index: Int?
}

/// Drag payloads are plain strings: `powder-tab:<uuid>` or `powder-pane:<uuid>`.
enum WorkspaceDrag {
    static let tabPrefix = "powder-tab:"
    static let panePrefix = "powder-pane:"
}

/// Serializable form of the layout. Tabs are stored as `perp:<coin>`, `markets` or `launchpad`.
indirect enum SavedLayout: Codable {
    case group(tabs: [String], selected: Int, active: Bool)
    case split(horizontal: Bool, fractions: [Double], children: [SavedLayout])

    /// What a fresh install opens with, and what "Reset Layout" restores.
    static let standard: SavedLayout = .split(
        horizontal: true,
        fractions: [0.6, 0.4],
        children: [
            .group(tabs: ["perp:ETH", "perp:SOL", "perp:HYPE", "markets", "positions", "launchpad"], selected: 0, active: true),
            .group(tabs: ["perp:BTC"], selected: 0, active: false),
        ]
    )
}

// MARK: - Market directory

/// Mid prices and listing metadata for every perp, shared by the tab strips so background tabs
/// stay quoted without each holding a socket open.
@MainActor
final class MarketDirectory: ObservableObject {
    @Published private(set) var markets: [String: HLMarket] = [:]
    @Published private(set) var mids: [String: Double] = [:]
    /// Spot tokens by index: where their price is in `mids` and how to sell them.
    private(set) var spotPairs: [Int: HLSpotPair] = [:]

    private var tasks: [Task<Void, Never>] = []
    private var watchers = 0

    /// A visible Markets table asks for funding, open interest and volume every few seconds
    /// instead of once a minute.
    func watch(_ isWatching: Bool) {
        watchers = max(watchers + (isWatching ? 1 : -1), 0)
        if isWatching { refresh() }
    }

    private func refresh() {
        Task { [weak self] in
            if let list = try? await HyperliquidAPI.markets() {
                self?.markets = Dictionary(list.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
            }
        }
    }

    func start() {
        guard tasks.isEmpty else { return }
        tasks = [
            Task { [weak self] in
                if let pairs = try? await HyperliquidExchange.spotPairs() { self?.spotPairs = pairs }
            },
            Task { [weak self] in
                while !Task.isCancelled {
                    if let list = try? await HyperliquidAPI.markets() {
                        self?.markets = Dictionary(list.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
                    }
                    // Slow tick; `watch` adds the fast one below.
                    try? await Task.sleep(for: .seconds(60))
                }
            },
            Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(3))
                    guard let self, self.watchers > 0 else { continue }
                    if let list = try? await HyperliquidAPI.markets() {
                        self.markets = Dictionary(list.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
                    }
                }
            },
            Task { [weak self] in
                // Every market's price arrives with each block. Publishing each one redraws every view that
                // shows a price, so they are passed on at most four times a second, always the latest.
                var last = ContinuousClock.now - .seconds(1)
                var pending: Task<Void, Never>?
                for await event in HyperliquidSocket.events([.allMids]) {
                    guard case let .mids(mids) = event else { continue }
                    pending?.cancel()
                    let wait = Duration.milliseconds(250) - (ContinuousClock.now - last)
                    if wait <= .zero {
                        last = .now
                        if self?.mids != mids { self?.mids = mids }
                    } else {
                        pending = Task { [weak self] in
                            try? await Task.sleep(for: wait)
                            guard !Task.isCancelled else { return }
                            if self?.mids != mids { self?.mids = mids }
                        }
                    }
                }
            },
        ]
    }
}

// MARK: - Router

/// Owns the pane layout and routes keystrokes to the active pane.
@MainActor
final class AppRouter: ObservableObject {
    private(set) var root: LayoutNode
    private(set) var activeGroupID: UUID
    @Published private(set) var dropTarget: DropTarget?

    let directory = MarketDirectory()
    let keys = KeyMonitor()
    let wallets: WalletProvider
    let watchlist: WatchlistStore
    let alerts: AlertStore
    let solanaQuotes = SolanaQuotes()
    let updater: Updater
    let triggers: SolanaTriggerStore
    let liquidations = LiquidationsModel()

    private let defaults: UserDefaults
    private static let layoutKey = "workspace.layout"

    init(defaults: UserDefaults = .standard, vault: KeyVault = KeychainVault()) {
        self.defaults = defaults
        wallets = WalletProvider(defaults: defaults, vault: vault)
        wallets.directory = directory
        watchlist = WatchlistStore(defaults: defaults)
        updater = Updater(defaults: defaults)
        alerts = AlertStore(defaults: defaults, directory: directory, quotes: solanaQuotes)
        triggers = SolanaTriggerStore(defaults: defaults, solana: wallets.solana, quotes: solanaQuotes)
        NotificationPresenter.center?.delegate = NotificationPresenter.shared
        let saved = defaults.data(forKey: Self.layoutKey)
            .flatMap { try? JSONDecoder().decode(SavedLayout.self, from: $0) }
        let fallback = PaneGroup(tabs: [])
        root = .group(fallback)
        activeGroupID = fallback.id
        theme = AppTheme.saved(in: defaults)
        install(saved ?? .standard)
        // Layouts saved before the Markets tab existed get it once; after that, closing it sticks.
        if saved != nil, !defaults.bool(forKey: "markets.introduced"), !groups.contains(where: { $0.tabs.contains { $0.list != nil } }) {
            openMarkets()
        }
        defaults.set(true, forKey: "markets.introduced")
        if saved != nil, !defaults.bool(forKey: "positions.introduced"), !groups.contains(where: { $0.tabs.contains { $0.positions != nil } }) {
            let current = activeGroup.selectedID
            openPositions()
            // Added behind the tab that was showing.
            if let current { select(current, in: activeGroup) }
        }
        defaults.set(true, forKey: "positions.introduced")
        keys.handler = { [weak self] key, isTyping in
            self?.handle(key, isTyping: isTyping) ?? false
        }
    }

    var groups: [PaneGroup] { Self.groups(in: root) }
    var activeGroup: PaneGroup { groups.first { $0.id == activeGroupID } ?? groups[0] }
    var activeMarket: PerpsModel? { activeGroup.selectedTab?.market }
    private var tabCount: Int { groups.reduce(0) { $0 + $1.tabs.count } }

    // MARK: Panes

    func activate(_ group: PaneGroup) {
        guard activeGroupID != group.id else { return }
        change { activeGroupID = group.id }
    }

    /// Opens a new pane beside the active one, showing the same market.
    func split(_ axis: Axis, coin: String? = nil) {
        Track.event("pane_split", ["axis": axis == .horizontal ? "right" : "down"])
        let source = activeGroup
        let tab = if coin == nil, let token = activeMarket?.solana {
            makeSolanaTab(token)
        } else {
            makeMarketTab(coin: coin ?? activeMarket?.coin ?? "ETH")
        }
        let group = PaneGroup(tabs: [tab])
        change {
            root = Self.inserting(group, beside: source, axis: axis, before: false, in: root)
            activeGroupID = group.id
        }
    }

    func focus(_ direction: PaneDirection) {
        let frames = Self.frames(of: root, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        guard let current = frames.first(where: { $0.group.id == activeGroupID })?.frame else { return }
        let step = 0.001
        let probe: CGPoint = switch direction {
        case .left: CGPoint(x: current.minX - step, y: current.midY)
        case .right: CGPoint(x: current.maxX + step, y: current.midY)
        case .up: CGPoint(x: current.midX, y: current.minY - step)
        case .down: CGPoint(x: current.midX, y: current.maxY + step)
        }
        if let target = frames.first(where: { $0.frame.contains(probe) }) {
            activate(target.group)
        }
    }

    func resize(_ box: SplitBox, fractions: [CGFloat]) {
        change { box.fractions = fractions }
    }

    func equalize() {
        change { Self.equalize(root) }
    }

    func resetLayout() {
        groups.forEach { group in group.tabs.forEach { $0.market?.shutdown() } }
        change { install(.standard) }
    }

    // MARK: Tabs

    func select(_ id: UUID, in group: PaneGroup) {
        guard group.tabs.contains(where: { $0.id == id }) else { return }
        keys.stopTyping()
        change {
            group.selectedID = id
            activeGroupID = group.id
        }
    }

    func select(index: Int) {
        let group = activeGroup
        guard group.tabs.indices.contains(index) else { return }
        select(group.tabs[index].id, in: group)
    }

    func step(_ delta: Int) {
        let group = activeGroup
        guard let index = group.tabs.firstIndex(where: { $0.id == group.selectedID }) else { return }
        select(index: (index + delta + group.tabs.count) % group.tabs.count)
    }

    /// New tabs come from the palette: pick a market and it opens in `target` (or the active pane).
    func newMarketTab(in target: PaneGroup? = nil) {
        if let target { activate(target) }
        openPalette()
    }

    /// Shows `coin`: its existing tab if one is open anywhere, otherwise a new tab in the active pane.
    func open(coin: String) {
        Track.event("market_opened", ["venue": Track.Venue.hyperliquid.rawValue, "market": "\(coin)/USDC", "asset": coin, "kind": "perp"])
        for group in groups {
            if let existing = group.tabs.first(where: { $0.market?.coin == coin && $0.market?.solana == nil }) {
                select(existing.id, in: group)
                return
            }
        }
        let group = activeGroup
        let tab = makeMarketTab(coin: coin)
        let index = group.tabs.firstIndex { $0.id == group.selectedID }.map { $0 + 1 } ?? group.tabs.count
        change {
            group.tabs.insert(tab, at: index)
            group.selectedID = tab.id
        }
    }

    // MARK: Palette

    @Published private(set) var isPaletteOpen = false
    @Published var paletteQuery = "" {
        didSet {
            guard paletteQuery != oldValue else { return }
            paletteSelection = 0
            searchSolana(paletteQuery)
        }
    }
    @Published private(set) var paletteSelection = 0
    @Published private(set) var theme: AppTheme = .dark

    func setTheme(_ next: AppTheme) {
        if next != theme { Track.event("theme_changed", ["theme": next.rawValue]) }
        theme = next
        defaults.set(next.rawValue, forKey: AppTheme.key)
        NSApp?.appearance = next.appearance
    }

    /// Supplied by the root view, which has the SwiftUI environment actions.
    var openSettings: (() -> Void)?

    /// Shows a Solana token: its existing tab if open, otherwise a new tab in the active pane.
    func open(solana token: SolanaToken) {
        Track.event("market_opened", [
            "venue": Track.Venue.solana.rawValue, "market": token.pairName, "asset": token.symbol, "kind": "pool",
            "mint": token.address, "pool": token.pool?.address, "exchange": token.pool?.exchange, "quote": token.pool?.quoteSymbol,
        ])
        for group in groups {
            // A token named without a pool is at home in any tab of it; a pool only in its own.
            if let existing = group.tabs.first(where: {
                $0.market?.solana?.address == token.address && (token.pool == nil || $0.market?.solana?.pool?.address == token.pool?.address)
            }) {
                select(existing.id, in: group)
                return
            }
        }
        let group = activeGroup
        let tab = makeSolanaTab(token)
        let index = group.tabs.firstIndex { $0.id == group.selectedID }.map { $0 + 1 } ?? group.tabs.count
        change {
            group.tabs.insert(tab, at: index)
            group.selectedID = tab.id
        }
    }

    private func makeSolanaTab(_ token: SolanaToken) -> WorkspaceTab {
        let model = PerpsModel(solana: token)
        model.onFindMarket = { [weak self] in self?.openPalette() }
        model.onOpenLink = { [weak self] url in self?.openWeb(url.absoluteString) }
        model.onOpenMarket = { [weak self] token in self?.open(solana: token) }
        // A tab opened on a token alone settles on a pool; the saved layout should name it.
        model.onCoinChange = { [weak self] in self?.persist() }
        return WorkspaceTab(market: model)
    }

    /// Solana tokens matching what is typed in the palette, fetched a moment after typing stops.
    @Published private(set) var solanaResults: [SolanaStats] = []
    private var solanaSearch: Task<Void, Never>?

    /// The most traded Solana tokens, listed among the perps before anything is typed. Refreshed each minute.
    @Published private(set) var solanaTop: [SolanaStats] = []
    private var solanaTopLoaded = Date.distantPast

    private func loadSolanaTop() {
        guard SolanaAPI.hasKey, Date().timeIntervalSince(solanaTopLoaded) > 60 else { return }
        solanaTopLoaded = Date()
        Task { [weak self] in
            if let top = try? await SolanaAPI.topPools() { self?.solanaTop = top }
        }
    }

    private func searchSolana(_ text: String) {
        solanaSearch?.cancel()
        let query = text.trimmingCharacters(in: .whitespaces)
        guard query.count >= 2, !query.hasPrefix(">"), !WebTabModel.looksLikeAddress(query), SolanaAPI.hasKey else {
            if !solanaResults.isEmpty { solanaResults = [] }
            return
        }
        solanaSearch = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled, let found = try? await SolanaAPI.searchPools(query), !Task.isCancelled else { return }
            self?.solanaResults = found
        }
    }

    // MARK: Assistant

    let ai = AIAssistant()
    @Published private(set) var isAIOpen = false

    func openAI() {
        Track.event("ai_opened")
        if isPaletteOpen { closePalette() }
        activeMarket?.isHelpOpen = false
        isAIOpen = true
        ChartInput.isSuspended = true
    }

    func closeAI() {
        isAIOpen = false
        ChartInput.isSuspended = false
        keys.stopTyping()
    }

    func openPalette(commands: Bool = false) {
        Track.event("palette_opened", ["commands": commands])
        if isAIOpen { closeAI() }
        activeMarket?.isHelpOpen = false
        paletteQuery = commands ? ">" : ""
        paletteSelection = 0
        isPaletteOpen = true
        loadSolanaTop()
        ChartInput.isSuspended = true
    }

    func closePalette() {
        isPaletteOpen = false
        ChartInput.isSuspended = false
        keys.stopTyping()
    }

    /// Single steps wrap around; page jumps stop at the ends.
    func movePalette(_ delta: Int, wraps: Bool = true) {
        let count = paletteItems.count
        guard count > 0 else { return }
        paletteSelection = wraps
            ? (paletteSelection + delta + count) % count
            : min(max(paletteSelection + delta, 0), count - 1)
    }

    func runPalette(at index: Int? = nil) {
        let items = paletteItems
        let index = index ?? paletteSelection
        guard items.indices.contains(index) else { return }
        closePalette()
        items[index].run()
    }

    /// Markets by 24h volume, then commands. A leading ">" shows commands only.
    var paletteItems: [PaletteItem] {
        if paletteQuery.hasPrefix(">") {
            return PaletteSearch.filter(commandItems, by: String(paletteQuery.dropFirst()))
        }
        let query = paletteQuery.trimmingCharacters(in: .whitespaces)
        // Hyperliquid perps and Solana tokens are one list, most traded first.
        func byVolume(_ items: [PaletteItem]) -> [PaletteItem] {
            items.enumerated().sorted { $0.element.volume != $1.element.volume ? $0.element.volume > $1.element.volume : $0.offset < $1.offset }.map(\.element)
        }
        if query.isEmpty { return byVolume(perpItems + solanaItems(solanaTop)) + viewItems }
        // Real matches from both venues rank together; scattered-letter guesses and commands follow.
        let perps = PaletteSearch.matches(perpItems, by: paletteQuery)
        var items = byVolume(perps.prefix + perps.exact + solanaItems(solanaResults)) + perps.fuzzy
            + PaletteSearch.filter(viewItems + commandItems, by: paletteQuery)
        // Something that reads as an address can be opened as a web tab straight from here.
        let visit = PaletteItem(
            id: "web:go", title: "Open \(query)", subtitle: "Web tab", icon: "globe",
            run: { [weak self] in self?.openWeb(query) }
        )
        if WebTabModel.looksLikeAddress(query) { items.insert(visit, at: 0) } else if items.isEmpty { items.append(visit) }
        return items
    }

    private func solanaItems(_ tokens: [SolanaStats]) -> [PaletteItem] {
        tokens.filter { !SolanaTokens.stablecoins.contains($0.token.address) }.map { found in
            PaletteItem(
                // One row per pool: the same token on another exchange, or against another token, is its own market.
                id: "sol:\(found.token.address)@\(found.pairAddress ?? "")", title: found.token.pairName,
                subtitle: "\(found.token.name) · \(found.exchange ?? "Solana") · $\(HLFormat.compact(found.liquidity)) liq · $\(HLFormat.compact(found.volume24)) vol",
                detail: "$" + HLFormat.price(found.price, decimals: found.price > 0 ? min(max(4 - Int(floor(log10(found.price))), 2), 12) : 2),
                change: found.change24, icon: "sun.max", logos: found.imageURL.map { [$0] } ?? [], volume: found.volume24,
                section: "solana",
                run: { [weak self] in self?.open(solana: found.token) }
            )
        }
    }

    private var perpItems: [PaletteItem] {
        let open = Set(groups.flatMap(\.tabs).compactMap { $0.market?.coin })
        return directory.markets.values
            .sorted { $0.ctx.dayNtlVlm > $1.ctx.dayNtlVlm }
            .map { market in
                let price = directory.mids[market.name] ?? market.ctx.midPx ?? market.ctx.markPx
                let decimals = HLFormat.priceDecimals(for: price, szDecimals: market.szDecimals)
                return PaletteItem(
                    id: "perp:\(market.name)",
                    title: market.name,
                    subtitle: "USDC perp · \(market.maxLeverage)x · $\(HLFormat.compact(market.ctx.dayNtlVlm)) vol",
                    detail: HLFormat.price(price, decimals: decimals),
                    change: market.dayChange,
                    icon: "chart.xyaxis.line",
                    logos: LogoStore.perp(market.name), volume: market.ctx.dayNtlVlm,
                    section: open.contains(market.name) ? "open" : nil,
                    run: { [weak self] in self?.open(coin: market.name) }
                )
            }
    }

    private var viewItems: [PaletteItem] {
        var items: [PaletteItem] = []
        items.append(PaletteItem(
            id: "markets", title: "Markets", subtitle: "Every perp, live",
            icon: "tablecells", run: { [weak self] in self?.openMarkets() }
        ))
        items.append(PaletteItem(
            id: "positions", title: "Positions", subtitle: "Every wallet, live PnL",
            icon: "list.bullet.rectangle", run: { [weak self] in self?.openPositions() }
        ))
        items.append(PaletteItem(
            id: "history", title: "History", subtitle: "Every wallet's trades, volume, fees and realized PnL",
            icon: "clock.arrow.circlepath", run: { [weak self] in self?.openHistory() }
        ))
        items.append(PaletteItem(
            id: "watchlist", title: "Watchlist", subtitle: "The markets you follow, across Hyperliquid and Solana",
            icon: "star", run: { [weak self] in self?.openBoard(.watchlist) }
        ))
        items.append(PaletteItem(
            id: "alerts", title: "Alerts", subtitle: "Price alerts",
            icon: "bell", run: { [weak self] in self?.openBoard(.alerts) }
        ))
        items.append(PaletteItem(
            id: "liquidations", title: "Liquidations", subtitle: "Every liquidation on Hyperliquid, live",
            icon: "flame", run: { [weak self] in self?.openBoard(.liquidations) }
        ))
        items.append(PaletteItem(
            id: "web", title: "Web", subtitle: "A website in a tab: type an address here, or open a blank one",
            icon: "globe", run: { [weak self] in self?.openWeb() }
        ))
        items.append(PaletteItem(
            id: "launchpad", title: "Launchpad", subtitle: "Solana token launches",
            icon: "square.stack.3d.up", run: { [weak self] in self?.openLaunchpad() }
        ))
        return items
    }

    private var commandItems: [PaletteItem] {
        func command(_ title: String, _ key: String = "", _ icon: String, _ run: @escaping @MainActor (AppRouter) -> Void) -> PaletteItem {
            PaletteItem(id: "cmd:\(title)", title: title, detail: key, icon: icon, run: { [weak self] in
                Track.event("command_run", ["command": title])
                if let self { run(self) }
            })
        }
        var items = [
            command("View: Split Right", "⌘D", "rectangle.split.2x1") { $0.split(.horizontal) },
            command("View: Split Down", "⇧⌘D", "rectangle.split.1x2") { $0.split(.vertical) },
            command("View: Close Tab", "⌘W", "xmark") { router in
                if let selected = router.activeGroup.selectedID { router.close(selected, in: router.activeGroup) }
            },
            command("View: Next Tab", "⇧⌘]", "arrow.right") { $0.step(1) },
            command("View: Previous Tab", "⇧⌘[", "arrow.left") { $0.step(-1) },
            command("View: Focus Pane Left", "⌥←", "arrow.left.to.line") { $0.focus(.left) },
            command("View: Focus Pane Right", "⌥→", "arrow.right.to.line") { $0.focus(.right) },
            command("View: Focus Pane Above", "⌥↑", "arrow.up.to.line") { $0.focus(.up) },
            command("View: Focus Pane Below", "⌥↓", "arrow.down.to.line") { $0.focus(.down) },
            command("View: Equalize Pane Sizes", "", "equal.square") { $0.equalize() },
            command("View: Reset Layout", "", "arrow.counterclockwise") { $0.resetLayout() },
            command("AI: Ask Claude or Codex…", "⌘K", "sparkles") { $0.openAI() },
            command("Web: New Tab", "", "globe") { $0.openWeb() },
            command("Markets: Open", "⇧⌘M", "tablecells") { $0.openMarkets() },
            command("Positions: Open", "⇧⌘O", "list.bullet.rectangle") { $0.openPositions() },
            command("History: Open", "⇧⌘Y", "clock.arrow.circlepath") { $0.openHistory() },
            command("Watchlist: Open", "", "star") { $0.openBoard(.watchlist) },
            command("Alerts: Open", "", "bell") { $0.openBoard(.alerts) },
            command("Liquidations: Open", "", "flame") { $0.openBoard(.liquidations) },
            command("Orders: Cancel All Resting Orders", "", "xmark.circle") { $0.cancelAllOrders() },
            command("Powder: Check for Updates…", "", "arrow.down.circle") { router in
                Task { await router.updater.check(userInitiated: true) }
            },
            command("Launchpad: Open", "⌘L", "square.stack.3d.up") { $0.openLaunchpad() },
            command("Preferences: Light Theme", theme == .light ? "current" : "", "sun.max") { $0.setTheme(.light) },
            command("Preferences: Dark Theme", theme == .dark ? "current" : "", "moon") { $0.setTheme(.dark) },
            command("Preferences: Wallets…", "⌘,", "wallet.pass") { $0.openSettings?() },
            command("Preferences: Codex Settings…", "⌘,", "slider.horizontal.3") { $0.openSettings?() },
        ]
        items += wallets.wallets.map { wallet in
            command("Wallet: Use \(wallet.name)", wallet.id == wallets.selectedID ? "current" : wallet.shortAddress, "wallet.pass") {
                $0.wallets.selectedID = wallet.id
            }
        }
        if activeMarket != nil {
            items.append(command("Order: Focus Size", "o", "arrow.left.arrow.right") { $0.activeMarket?.ticketFocusRequest += 1 })
            items.append(command("Order: Buy / Long", "⇧B", "arrow.up.right") { $0.activeMarket?.requestOrder(isBuy: true) })
            items.append(command("Order: Sell / Short", "⇧S", "arrow.down.right") { $0.activeMarket?.requestOrder(isBuy: false) })
            items += (activeMarket?.intervals ?? []).map { interval in
                command("Chart: \(interval.rawValue) Candles", "", "chart.bar") { $0.activeMarket?.setInterval(interval) }
            }
            items += ChartStyle.allCases.map { style in
                command("Chart Type: \(style.title)", "", "chart.xyaxis.line") { $0.activeMarket?.setStyle(style) }
            }
            items += ChartIndicator.allCases.map { indicator in
                command("Indicator: \(indicator.title)", "", "waveform.path.ecg") { $0.activeMarket?.toggle(indicator) }
            }
            items += [
                command("Chart: Zoom In", "=", "plus.magnifyingglass") { $0.activeMarket?.zoom(1) },
                command("Chart: Zoom Out", "-", "minus.magnifyingglass") { $0.activeMarket?.zoom(-1) },
                command("Chart: Return to Live Candle", "esc", "forward.end") { $0.activeMarket?.goLive() },
                command("Chart: Auto Price Scale", "", "arrow.up.and.down") { $0.activeMarket?.resetPriceScale() },
                command("Chart: Toggle Log Scale", "", "function") { $0.activeMarket?.chartSettings.logScale.toggle() },
                command("Chart: Toggle Percent Scale", "", "percent") { $0.activeMarket?.chartSettings.percentScale.toggle() },
                command("Chart: Toggle Inverted Scale", "", "arrow.up.arrow.down") { $0.activeMarket?.chartSettings.invertScale.toggle() },
                command("Chart: Copy Image", "", "camera") { $0.activeMarket?.copyChartImage() },
                command("Replay: Start From Here", "", "backward.end") { $0.activeMarket?.startReplay() },
                command("Replay: Play / Pause", "space", "playpause") { $0.activeMarket?.toggleReplayPlayback() },
                command("Replay: Return to Live", "esc", "forward.end") { $0.activeMarket?.stopReplay() },
            ]
            items += DrawTool.allCases.map { tool in
                command("Draw: \(tool.title)", tool == .trend ? "d" : "", "pencil.line") { $0.activeMarket?.setDrawTool(tool) }
            }
            items += [
                command("Draw: Toggle Magnet", "m", "scope") { $0.activeMarket?.chartSettings.magnet.toggle() },
                command("Draw: Lock Drawings", "", "lock") { $0.activeMarket?.chartSettings.lockDrawings.toggle() },
                command("Draw: Hide Drawings", "", "eye.slash") { $0.activeMarket?.chartSettings.hideDrawings.toggle() },
                command("Draw: Undo", "⌘Z", "arrow.uturn.backward") { $0.activeMarket?.undoDrawing() },
                command("Draw: Redo", "⇧⌘Z", "arrow.uturn.forward") { $0.activeMarket?.redoDrawing() },
                command("Draw: Clear All Drawings", "", "trash") { $0.activeMarket?.clearDrawings() },
                command("Order Book: Cycle Grouping", "g", "list.number") { $0.activeMarket?.cycleGrouping() },
                command("Market: Reconnect and Reload", "⌘R", "arrow.clockwise") { $0.activeMarket?.reconnect() },
                command("Help: Keyboard Shortcuts", "?", "keyboard") { $0.activeMarket?.isHelpOpen = true },
            ]
        }
        return items
    }

    /// Opens the market behind a position, trading with the wallet that holds it.
    func openMarket(for row: PositionRow) {
        if let token = row.solana {
            wallets.selectedID = row.walletID
            open(solana: token)
            return
        }
        guard row.kind == .perp else { return }
        wallets.selectedID = row.walletID
        open(coin: row.coin)
    }

    func close(_ row: PositionRow, in table: PositionsModel) {
        Task { await table.close(row, wallets: wallets, directory: directory) }
    }

    /// Brings the launchpad forward, opening its tab in the active pane if it was closed.
    func openLaunchpad() {
        Track.event("board_opened", ["board": "launchpad"])
        openSingleton(where: \.isLaunchpad) { WorkspaceTab() }
    }

    /// Brings the all-markets table forward, opening its tab in the active pane if it was closed.
    func openMarkets() {
        Track.event("board_opened", ["board": "markets"])
        openSingleton(where: { $0.list != nil }) { WorkspaceTab(list: MarketsModel()) }
    }

    /// Brings the watchlist, alerts or liquidations forward, opening its tab in the active pane if it was closed.
    func openBoard(_ board: WorkspaceTab.Board) {
        Track.event("board_opened", ["board": board.rawValue])
        openSingleton(where: { $0.board == board }) { WorkspaceTab(board: board) }
    }

    func open(_ market: MarketRef) {
        if let token = market.solana { open(solana: token) } else if let coin = market.coin { open(coin: coin) }
    }

    /// The market in the active tab, for watching it.
    var activeMarketRef: MarketRef? {
        guard let market = activeMarket else { return nil }
        return market.solana.map(MarketRef.solana) ?? .perp(market.coin)
    }

    /// Cancels every resting order in every wallet. The result is shown on the active market tab.
    func cancelAllOrders() {
        Task {
            let result = await wallets.cancelAll()
            activeMarket?.notify(result)
        }
    }

    /// Brings the trade history forward, opening its tab in the active pane if it was closed.
    func openHistory() {
        Track.event("board_opened", ["board": "history"])
        openSingleton(where: { $0.history != nil }) { WorkspaceTab(history: HistoryModel()) }
    }

    /// Opens the market a past trade was in.
    func openMarket(for record: TradeRecord) {
        wallets.selectedID = record.walletID
        if let token = record.solana {
            open(solana: token)
        } else if directory.markets[record.market] != nil {
            open(coin: record.market)
        }
    }

    /// Brings the all-wallets positions table forward, opening its tab in the active pane if it was closed.
    func openPositions() {
        Track.event("board_opened", ["board": "positions"])
        openSingleton(where: { $0.positions != nil }) { WorkspaceTab(positions: PositionsModel()) }
    }

    private func openSingleton(where matches: (WorkspaceTab) -> Bool, make: () -> WorkspaceTab) {
        for group in groups {
            if let existing = group.tabs.first(where: matches) {
                select(existing.id, in: group)
                return
            }
        }
        let group = activeGroup
        let tab = make()
        change {
            group.tabs.append(tab)
            group.selectedID = tab.id
        }
    }

    /// Closes a tab. A pane that loses its last tab closes with it; the final tab stays.
    func close(_ id: UUID, in group: PaneGroup) {
        guard tabCount > 1, let index = group.tabs.firstIndex(where: { $0.id == id }) else { return }
        group.tabs[index].market?.shutdown()
        group.tabs[index].web?.shutdown()
        change {
            group.tabs.remove(at: index)
            if group.tabs.isEmpty {
                // Hand focus to a neighbour before the empty pane is pruned.
                let all = groups
                let position = all.firstIndex { $0.id == group.id } ?? 0
                root = Self.pruned(root) ?? root
                let remaining = groups
                if activeGroupID == group.id {
                    activeGroupID = remaining[min(max(position - 1, 0), remaining.count - 1)].id
                }
            } else if group.selectedID == id {
                group.selectedID = group.tabs[min(index, group.tabs.count - 1)].id
            }
        }
    }

    // MARK: Drag and drop

    /// SwiftUI can report a hover after the drop has landed, and reports nothing at all when a drag
    /// is cancelled or released outside a pane. So the preview only shows while the mouse button is
    /// down, and a watcher clears it once the button is up.
    func setDropTarget(_ target: DropTarget) {
        guard NSEvent.pressedMouseButtons & 1 != 0 else {
            clearDropTarget()
            return
        }
        if dropTarget != target { dropTarget = target }
        guard dropWatch == nil else { return }
        dropWatch = Task { [weak self] in
            while !Task.isCancelled, NSEvent.pressedMouseButtons & 1 != 0 {
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard !Task.isCancelled else { return }
            self?.dropWatch = nil
            self?.dropTarget = nil
        }
    }

    func clearDropTarget(for group: UUID? = nil) {
        guard group == nil || dropTarget?.group == group else { return }
        dropTarget = nil
        dropWatch?.cancel()
        dropWatch = nil
    }

    private var dropWatch: Task<Void, Never>?

    /// Lands a drag payload on `target`.
    func drop(_ payload: String, on target: PaneGroup, zone: DropZone, index: Int? = nil) {
        if payload.hasPrefix(WorkspaceDrag.tabPrefix), let id = UUID(uuidString: String(payload.dropFirst(WorkspaceDrag.tabPrefix.count))) {
            move(tab: id, to: target, zone: zone, index: index)
        } else if payload.hasPrefix(WorkspaceDrag.panePrefix), let id = UUID(uuidString: String(payload.dropFirst(WorkspaceDrag.panePrefix.count))) {
            move(pane: id, to: target, zone: zone)
        }
    }

    /// Moves a tab into `target` (`.center`, optionally before position `index`) or into a new pane on one of its sides.
    func move(tab id: UUID, to target: PaneGroup, zone: DropZone, index: Int? = nil) {
        guard groups.contains(where: { $0 === target }),
              let source = groups.first(where: { group in group.tabs.contains { $0.id == id } }),
              let from = source.tabs.firstIndex(where: { $0.id == id })
        else { return }
        let tab = source.tabs[from]

        guard let axis = zone.axis else {
            if source === target {
                // Reorder within the strip. `index` counts positions before the tab is lifted out.
                guard let index else { return }
                let destination = min(from < index ? index - 1 : index, source.tabs.count - 1)
                guard destination != from else { return }
                change {
                    source.tabs.remove(at: from)
                    source.tabs.insert(tab, at: destination)
                    source.selectedID = id
                    activeGroupID = source.id
                }
            } else {
                change {
                    Self.detach(from, from: source)
                    target.tabs.insert(tab, at: min(index ?? target.tabs.count, target.tabs.count))
                    target.selectedID = id
                    activeGroupID = target.id
                    root = Self.pruned(root) ?? root
                }
            }
            return
        }

        // Splitting a pane off its own only tab would leave nothing behind.
        if source === target, source.tabs.count == 1 { return }
        let group = PaneGroup(tabs: [tab])
        change {
            Self.detach(from, from: source)
            root = Self.inserting(group, beside: target, axis: axis, before: zone.isBefore, in: root)
            root = Self.pruned(root) ?? root
            activeGroupID = group.id
        }
    }

    /// Moves a whole pane to one side of `target`, or merges its tabs into `target` (`.center`).
    func move(pane id: UUID, to target: PaneGroup, zone: DropZone) {
        guard let source = groups.first(where: { $0.id == id }), source !== target,
              groups.contains(where: { $0 === target })
        else { return }
        change {
            root = Self.pruned(root, dropping: source.id) ?? root
            if let axis = zone.axis {
                root = Self.inserting(source, beside: target, axis: axis, before: zone.isBefore, in: root)
                activeGroupID = source.id
            } else {
                target.tabs.append(contentsOf: source.tabs)
                target.selectedID = source.selectedID ?? target.selectedID
                activeGroupID = target.id
            }
        }
    }

    private static func detach(_ index: Int, from group: PaneGroup) {
        let id = group.tabs[index].id
        group.tabs.remove(at: index)
        if group.selectedID == id, !group.tabs.isEmpty {
            group.selectedID = group.tabs[min(index, group.tabs.count - 1)].id
        }
    }

    // MARK: Tree helpers

    private func change(_ body: () -> Void) {
        objectWillChange.send()
        body()
        persist()
        syncFocus()
    }

    /// Tells each market tab whether it is the one the trade keys act on, so only that one keeps a swap priced.
    private func syncFocus() {
        for group in groups {
            for tab in group.tabs {
                let focused = group.id == activeGroupID && tab.id == group.selectedID
                if tab.market?.isFocusedPane != focused { tab.market?.isFocusedPane = focused }
            }
        }
    }

    private static func groups(in node: LayoutNode) -> [PaneGroup] {
        switch node {
        case let .group(group): [group]
        case let .split(box): box.children.flatMap(groups(in:))
        }
    }

    /// Places `group` beside `anchor`: as a sibling when the enclosing split already runs along `axis`,
    /// otherwise by wrapping `anchor` in a new split.
    private static func inserting(
        _ group: PaneGroup,
        beside anchor: PaneGroup,
        axis: Axis,
        before: Bool,
        in node: LayoutNode
    ) -> LayoutNode {
        switch node {
        case let .group(candidate):
            guard candidate.id == anchor.id else { return node }
            return .split(SplitBox(axis: axis, children: before ? [.group(group), node] : [node, .group(group)]))

        case let .split(box):
            if box.axis == axis, let index = box.children.firstIndex(where: { $0.id == anchor.id }) {
                let half = box.fractions[index] / 2
                box.fractions[index] = half
                box.children.insert(.group(group), at: before ? index : index + 1)
                box.fractions.insert(half, at: before ? index : index + 1)
            } else {
                box.children = box.children.map { inserting(group, beside: anchor, axis: axis, before: before, in: $0) }
            }
            return node
        }
    }

    /// Drops empty panes (and the pane `dropping`, if given), hands their space to the survivors,
    /// and collapses single-child splits.
    private static func pruned(_ node: LayoutNode, dropping: UUID? = nil) -> LayoutNode? {
        switch node {
        case let .group(group):
            return group.tabs.isEmpty || group.id == dropping ? nil : node

        case let .split(box):
            let kept = zip(box.children, box.fractions).compactMap { child, fraction in
                pruned(child, dropping: dropping).map { ($0, fraction) }
            }
            guard let first = kept.first else { return nil }
            if kept.count == 1 { return first.0 }
            let total = kept.reduce(0) { $0 + $1.1 }
            box.children = kept.map(\.0)
            box.fractions = kept.map { $0.1 / total }
            return node
        }
    }

    private static func equalize(_ node: LayoutNode) {
        guard case let .split(box) = node else { return }
        box.fractions = Array(repeating: 1 / CGFloat(box.children.count), count: box.children.count)
        box.children.forEach(equalize)
    }

    private static func frames(of node: LayoutNode, in rect: CGRect) -> [(group: PaneGroup, frame: CGRect)] {
        switch node {
        case let .group(group):
            return [(group, rect)]

        case let .split(box):
            var offset: CGFloat = 0
            return zip(box.children, box.fractions).flatMap { child, fraction in
                defer { offset += fraction }
                let frame = box.axis == .horizontal
                    ? CGRect(x: rect.minX + offset * rect.width, y: rect.minY, width: fraction * rect.width, height: rect.height)
                    : CGRect(x: rect.minX, y: rect.minY + offset * rect.height, width: rect.width, height: fraction * rect.height)
                return frames(of: child, in: frame)
            }
        }
    }

    // MARK: Persistence

    private func makeWebTab(url: URL?) -> WorkspaceTab {
        let model = WebTabModel(url: url)
        model.onChange = { [weak self] in self?.persist() }
        return WorkspaceTab(web: model)
    }

    /// Opens a web tab in the active pane: at `address` (a URL, a bare domain, or a search), or blank with the address bar ready.
    func openWeb(_ address: String? = nil) {
        // That a web tab was opened, never where it went.
        Track.event("web_tab_opened")
        let group = activeGroup
        let tab = makeWebTab(url: address.flatMap(WebTabModel.resolve))
        let index = group.tabs.firstIndex { $0.id == group.selectedID }.map { $0 + 1 } ?? group.tabs.count
        change {
            group.tabs.insert(tab, at: index)
            group.selectedID = tab.id
        }
    }

    var activeWeb: WebTabModel? { activeGroup.selectedTab?.web }

    private func makeMarketTab(coin: String) -> WorkspaceTab {
        let model = PerpsModel(coin: coin)
        model.onCoinChange = { [weak self] in self?.persist() }
        model.onFindMarket = { [weak self] in self?.openPalette() }
        return WorkspaceTab(market: model)
    }

    /// Only one Markets tab is restored, like the launchpad.
    private var hasMarkets = false
    private var hasPositions = false
    private var hasHistory = false
    private var boards: Set<WorkspaceTab.Board> = []

    private func install(_ saved: SavedLayout) {
        hasMarkets = false
        hasPositions = false
        hasHistory = false
        boards = []
        var hasLaunchpad = false
        var active: UUID?
        let built = build(saved, hasLaunchpad: &hasLaunchpad, active: &active).flatMap { Self.pruned($0) }
        root = built ?? .group(PaneGroup(tabs: [makeMarketTab(coin: "ETH")]))
        activeGroupID = active.flatMap { id in groups.first { $0.id == id }?.id } ?? groups[0].id
    }

    private func build(_ saved: SavedLayout, hasLaunchpad: inout Bool, active: inout UUID?) -> LayoutNode? {
        switch saved {
        case let .group(entries, selected, isActive):
            var tabs: [WorkspaceTab] = []
            for entry in entries {
                if entry.hasPrefix("perp:") {
                    tabs.append(makeMarketTab(coin: String(entry.dropFirst(5))))
                } else if let token = SolanaToken(savedName: entry) {
                    tabs.append(makeSolanaTab(token))
                } else if entry.hasPrefix("web:") {
                    tabs.append(makeWebTab(url: URL(string: String(entry.dropFirst(4)))))
                } else if entry == "launchpad", !hasLaunchpad {
                    hasLaunchpad = true
                    tabs.append(WorkspaceTab())
                } else if entry == "markets", !hasMarkets {
                    hasMarkets = true
                    tabs.append(WorkspaceTab(list: MarketsModel()))
                } else if entry == "positions", !hasPositions {
                    hasPositions = true
                    tabs.append(WorkspaceTab(positions: PositionsModel()))
                } else if entry == "history", !hasHistory {
                    hasHistory = true
                    tabs.append(WorkspaceTab(history: HistoryModel()))
                } else if let board = WorkspaceTab.Board(rawValue: entry), !boards.contains(board) {
                    boards.insert(board)
                    tabs.append(WorkspaceTab(board: board))
                }
            }
            let group = PaneGroup(tabs: tabs, selectedIndex: selected)
            if isActive { active = group.id }
            return .group(group)

        case let .split(horizontal, fractions, children):
            let nodes = children.compactMap { build($0, hasLaunchpad: &hasLaunchpad, active: &active) }
            guard !nodes.isEmpty else { return nil }
            let usable = fractions.count == nodes.count && fractions.allSatisfy { $0 > 0 }
            return .split(SplitBox(
                axis: horizontal ? .horizontal : .vertical,
                children: nodes,
                fractions: usable ? fractions.map { CGFloat($0) } : nil
            ))
        }
    }

    private func snapshot(_ node: LayoutNode) -> SavedLayout {
        switch node {
        case let .group(group):
            .group(
                tabs: group.tabs.map(\.savedName),
                selected: group.tabs.firstIndex { $0.id == group.selectedID } ?? 0,
                active: group.id == activeGroupID
            )
        case let .split(box):
            .split(
                horizontal: box.axis == .horizontal,
                fractions: box.fractions.map { Double($0) },
                children: box.children.map(snapshot)
            )
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(snapshot(root)) {
            defaults.set(data, forKey: Self.layoutKey)
        }
    }

    // MARK: Keys

    private func handle(_ key: KeyPress, isTyping: Bool) -> Bool {
        if key.keyCode == KeyCode.escape, let dismiss = DropdownCenter.dismiss {
            dismiss()
            return true
        }

        if isAIOpen {
            switch (key.keyCode, key.characters) {
            case (KeyCode.escape, _): if ai.isRunning { ai.cancel() } else { closeAI() }
            case (KeyCode.return, _), (KeyCode.enter, _): ai.submit()
            case (KeyCode.tab, _): ai.toggleProvider()
            case (_, "k") where key.command: closeAI()
            case (_, "p") where key.command, (_, "P") where key.command, (_, "t") where key.command:
                openPalette(commands: key.characters == "P")
            // Everything else is typing; pane and tab shortcuts wait until the panel is closed.
            default: return false
            }
            return true
        }

        if isPaletteOpen {
            switch (key.keyCode, key.characters) {
            case (KeyCode.down, _): movePalette(1)
            case (KeyCode.up, _): movePalette(-1)
            case (_, "n") where key.control: movePalette(1)
            case (_, "p") where key.control: movePalette(-1)
            case (121, _): movePalette(10, wraps: false)
            case (116, _): movePalette(-10, wraps: false)
            case (KeyCode.escape, _): closePalette()
            case (KeyCode.return, _), (KeyCode.enter, _): runPalette()
            case (_, "p") where key.command: closePalette()
            case (_, "k") where key.command: openAI()
            default: return false
            }
            return true
        }

        // A web page has the keyboard: only ⌘ shortcuts are Powder's, everything else is the page's.
        if keys.isInWeb, !key.command { return false }

        if key.control { return false }

        // ⌥ + arrows (or h j k l) moves between panes.
        if key.option {
            guard !key.command else { return false }
            switch (key.keyCode, key.characters) {
            case (KeyCode.left, _), (_, "h"): focus(.left)
            case (KeyCode.right, _), (_, "l"): focus(.right)
            case (KeyCode.up, _), (_, "k"): focus(.up)
            case (KeyCode.down, _), (_, "j"): focus(.down)
            default: return false
            }
            return true
        }

        // Tab and pane management works everywhere, including while a text field is focused.
        if key.command {
            switch key.characters {
            case "t", "p": openPalette()
            case "k": openAI()
            case "P": openPalette(commands: true)
            case "d": split(.horizontal)
            case "D": split(.vertical)
            case "w":
                // With one tab left, let ⌘W close the window as usual.
                guard tabCount > 1, let selected = activeGroup.selectedID else { return false }
                close(selected, in: activeGroup)
            case "{": step(-1)
            case "}": step(1)
            case "z":
                // ⌘Z takes back the last change to the chart's drawings; a text field keeps its own undo.
                guard !isTyping, let market = activeMarket, market.canUndoDrawing else { return false }
                market.undoDrawing()
            case "Z":
                guard !isTyping, let market = activeMarket, market.canRedoDrawing else { return false }
                market.redoDrawing()
            case "[":
                guard let web = activeWeb else { return false }
                web.back()
            case "]":
                guard let web = activeWeb else { return false }
                web.forward()
            case "l":
                // In a web tab ⌘L is the address bar, as in a browser; elsewhere it stays the Launchpad.
                guard let web = activeWeb else { return false }
                web.addressFocusRequest += 1
            default:
                guard let number = Int(key.characters), number >= 1 else { return false }
                select(index: number - 1)
            }
            return true
        }

        let perps = activeMarket

        if isTyping {
            // A search or filter field has the keyboard. Esc and Return hand it back; in the Markets
            // table the arrows keep moving the selection while the filter is being typed.
            switch key.keyCode {
            case KeyCode.return, KeyCode.enter:
                // In a web tab the field with the keyboard is the address bar.
                activeWeb?.go()
                keys.stopTyping()
                return true
            case KeyCode.escape:
                keys.stopTyping()
                return true
            case KeyCode.down:
                guard let list = activeGroup.selectedTab?.list else { return false }
                list.move(1, in: directory)
                return true
            case KeyCode.up:
                guard let list = activeGroup.selectedTab?.list else { return false }
                list.move(-1, in: directory)
                return true
            default:
                return false
            }
        }

        if key.keyCode == KeyCode.tab {
            step(key.shift ? -1 : 1)
            return true
        }
        if let number = Int(key.characters), number >= 1 {
            select(index: number - 1)
            return true
        }
        switch key.characters {
        case "t", "/": openPalette(); return true
        case "s": split(.horizontal); return true
        // ⇧B buys and ⇧S sells what the order ticket shows. They need Shift so a stray key cannot trade.
        case "B": if let market = activeMarket { market.requestOrder(isBuy: true); return true }
        case "S": if let market = activeMarket { market.requestOrder(isBuy: false); return true }
        default: break
        }

        if let list = activeGroup.selectedTab?.list {
            switch (key.keyCode, key.characters) {
            case (KeyCode.down, _), (_, "j"): list.move(key.shift ? 10 : 1, in: directory)
            case (KeyCode.up, _), (_, "k"): list.move(key.shift ? -10 : -1, in: directory)
            case (KeyCode.right, _), (_, "l"): list.stepSort(1)
            case (KeyCode.left, _), (_, "h"): list.stepSort(-1)
            case (_, "r"): list.reverseSort()
            case (KeyCode.escape, _): list.select(nil)
            case (_, "f"):
                // F stars the selected market into the watchlist, or takes it back out.
                guard let coin = list.selection else { return false }
                watchlist.toggle(.perp(coin))
            case (KeyCode.return, _), (KeyCode.enter, _):
                guard let coin = list.selection else { return false }
                open(coin: coin)
            default: return false
            }
            return true
        }

        if let board = activeGroup.selectedTab?.board {
            switch board {
            case .watchlist:
                switch (key.keyCode, key.characters) {
                case (KeyCode.down, _), (_, "j"): watchlist.move(key.shift ? 10 : 1)
                case (KeyCode.up, _), (_, "k"): watchlist.move(key.shift ? -10 : -1)
                case (KeyCode.delete, _), (_, "x"):
                    guard let id = watchlist.selection else { return false }
                    watchlist.remove(id)
                case (KeyCode.return, _), (KeyCode.enter, _), (_, "o"):
                    guard let market = watchlist.items.first(where: { $0.id == watchlist.selection }) else { return false }
                    open(market)
                case (KeyCode.escape, _): watchlist.selection = nil
                default: return false
                }
            case .alerts:
                switch (key.keyCode, key.characters) {
                case (KeyCode.down, _), (_, "j"): alerts.move(key.shift ? 10 : 1)
                case (KeyCode.up, _), (_, "k"): alerts.move(key.shift ? -10 : -1)
                case (_, "a"): alerts.entryFocusRequest += 1
                case (_, "c"): alerts.clearTriggered()
                case (KeyCode.delete, _), (_, "x"):
                    guard let id = alerts.selection else { return false }
                    alerts.remove(id)
                case (KeyCode.return, _), (KeyCode.enter, _), (_, "o"):
                    guard let alert = alerts.alerts.first(where: { $0.id == alerts.selection }) else { return false }
                    open(alert.market)
                case (KeyCode.escape, _): alerts.selection = nil
                default: return false
                }
            case .liquidations:
                switch (key.keyCode, key.characters) {
                case (KeyCode.down, _), (_, "j"): liquidations.move(key.shift ? 10 : 1)
                case (KeyCode.up, _), (_, "k"): liquidations.move(key.shift ? -10 : -1)
                case (_, "m"): liquidations.cycleMinimum()
                case (KeyCode.return, _), (KeyCode.enter, _), (_, "o"):
                    guard let coin = liquidations.selected?.coin, directory.markets[coin] != nil else { return false }
                    open(coin: coin)
                case (KeyCode.escape, _): liquidations.selection = nil
                default: return false
                }
            }
            return true
        }

        if let history = activeGroup.selectedTab?.history {
            switch (key.keyCode, key.characters) {
            case (KeyCode.down, _), (_, "j"): history.move(key.shift ? 10 : 1)
            case (KeyCode.up, _), (_, "k"): history.move(key.shift ? -10 : -1)
            case (_, "r"): Task { await history.load(wallets: wallets) }
            case (_, "o"), (KeyCode.return, _), (KeyCode.enter, _):
                guard let record = history.selected else { return false }
                openMarket(for: record)
            case (KeyCode.escape, _): history.select(nil)
            default: return false
            }
            return true
        }

        if let table = activeGroup.selectedTab?.positions {
            let rows = table.rows(wallets: wallets, directory: directory)
            switch (key.keyCode, key.characters) {
            case (KeyCode.down, _), (_, "j"): table.move(key.shift ? 10 : 1, in: rows)
            case (KeyCode.up, _), (_, "k"): table.move(key.shift ? -10 : -1, in: rows)
            case (KeyCode.right, _), (_, "l"): table.stepSort(1)
            case (KeyCode.left, _), (_, "h"): table.stepSort(-1)
            case (_, "r"): table.reverseSort()
            case (_, "o"):
                guard let row = rows.first(where: { $0.id == table.selection }) else { return false }
                openMarket(for: row)
            case (KeyCode.escape, _):
                if table.armed != nil { table.cancelClose() } else { table.select(nil) }
            case (KeyCode.return, _), (KeyCode.enter, _):
                // ⏎ arms the close, a second ⏎ sends it.
                if let row = table.pressEnter(in: rows) { close(row, in: table) }
            default: return false
            }
            return true
        }

        guard let perps else { return false }

        if perps.isHelpOpen {
            perps.isHelpOpen = false
            return true
        }

        let step = key.shift ? 10 : 1
        switch key.keyCode {
        case KeyCode.left: perps.moveCursor(-step)
        case KeyCode.right: perps.moveCursor(step)
        case KeyCode.delete:
            guard perps.removeSelectedDrawing() else { return false }
        case KeyCode.escape:
            // Esc first puts a drawing tool down, then lets go of a selected drawing, then leaves a replay;
            // only then does it reset the view.
            if perps.drawTool != nil {
                perps.setDrawTool(nil)
            } else if perps.selectedDrawing != nil {
                perps.selectDrawing(nil)
            } else if perps.replayTime != nil {
                perps.stopReplay()
            } else {
                perps.goLive()
            }
        default:
            switch key.characters {
            case "[": perps.stepInterval(-1)
            case "]": perps.stepInterval(1)
            case "h": perps.moveCursor(-1)
            case "l": perps.moveCursor(1)
            case "H": perps.moveCursor(-10)
            case "L": perps.moveCursor(10)
            case "g": perps.cycleGrouping()
            case "c": perps.cycleStyle()
            case "d": perps.setDrawTool(perps.drawTool == .trend ? nil : .trend)
            case "m":
                perps.chartSettings.magnet.toggle()
                perps.notify(perps.chartSettings.magnet ? "Magnet on: drawing points snap to open, high, low and close" : "Magnet off")
            // While candles are replayed: step back, step on, play or pause.
            case ",": guard perps.replayTime != nil else { return false }; perps.stepReplay(-1)
            case ".": guard perps.replayTime != nil else { return false }; perps.stepReplay(1)
            case " ": guard perps.replayTime != nil else { return false }; perps.toggleReplayPlayback()
            case "o": perps.ticketFocusRequest += 1
            case "w":
                // W stars this market into the watchlist, or takes it back out.
                guard let market = activeMarketRef else { return false }
                perps.notify(watchlist.toggle(market) ? "Added \(market.symbol) to the watchlist" : "Removed \(market.symbol) from the watchlist")
            case "-", "_": perps.zoom(-1)
            case "=", "+": perps.zoom(1)
            case "?": perps.isHelpOpen = true
            default: return false
            }
        }
        return true
    }
}
