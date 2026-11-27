import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Renders the layout tree: panes, and splits with draggable dividers between them.
struct LayoutView: View {
    let node: LayoutNode
    @ObservedObject var router: AppRouter

    var body: some View {
        switch node {
        case let .group(group): GroupView(group: group, router: router)
        case let .split(box): SplitBoxView(box: box, router: router)
        }
    }
}

private struct SplitBoxView: View {
    let box: SplitBox
    @ObservedObject var router: AppRouter
    @State private var dragStart: [CGFloat]?

    private static let dividerThickness: CGFloat = 1

    var body: some View {
        GeometryReader { geometry in
            let horizontal = box.axis == .horizontal
            let total = horizontal ? geometry.size.width : geometry.size.height
            let available = max(total - CGFloat(box.children.count - 1) * Self.dividerThickness, 1)
            let layout = horizontal ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))

            layout {
                ForEach(Array(box.children.enumerated()), id: \.element.id) { index, child in
                    LayoutView(node: child, router: router)
                        .frame(
                            width: horizontal ? available * box.fractions[index] : nil,
                            height: horizontal ? nil : available * box.fractions[index]
                        )
                    if index < box.children.count - 1 {
                        divider(after: index, available: available, horizontal: horizontal)
                    }
                }
            }
        }
    }

    /// A one-point line with a wider invisible grab area; dragging moves space between its two neighbours.
    private func divider(after index: Int, available: CGFloat, horizontal: Bool) -> some View {
        Rectangle()
            .fill(Term.paneDivider)
            .frame(width: horizontal ? Self.dividerThickness : nil, height: horizontal ? nil : Self.dividerThickness)
            .overlay(
                Color.clear
                    .frame(width: horizontal ? 7 : nil, height: horizontal ? nil : 7)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside {
                            (horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                let start = dragStart ?? box.fractions
                                if dragStart == nil { dragStart = start }
                                guard start.indices.contains(index + 1) else { return }
                                let delta = (horizontal ? value.translation.width : value.translation.height) / available
                                let minimum: CGFloat = 0.12
                                let pair = start[index] + start[index + 1]
                                var fractions = start
                                fractions[index] = min(max(start[index] + delta, minimum), pair - minimum)
                                fractions[index + 1] = pair - fractions[index]
                                router.resize(box, fractions: fractions)
                            }
                            .onEnded { _ in dragStart = nil }
                    )
            )
            .zIndex(1)
            .accessibilityHidden(true)
    }
}

/// One pane: its own tab strip above the selected tab's view.
private struct GroupView: View {
    let group: PaneGroup
    @ObservedObject var router: AppRouter

    var body: some View {
        let isActive = router.activeGroupID == group.id

        VStack(spacing: 0) {
            TabStrip(group: group, router: router, directory: router.directory, isActive: isActive)
                .frame(height: Term.tabBarHeight)
                .background(Term.chrome)
                .onDrop(of: [.text], delegate: WorkspaceDropDelegate(group: group, router: router, fixedZone: .center))
            TermRule()

            GeometryReader { geometry in
                Group {
                    if let tab = group.selectedTab {
                        if let market = tab.market {
                            PerpsView(model: market)
                        } else if let positions = tab.positions {
                            PositionsView(
                                model: positions, directory: router.directory, wallets: router.wallets,
                                onOpen: { router.openMarket(for: $0) },
                                onClose: { router.close($0, in: positions) }
                            )
                        } else if let board = tab.board {
                            switch board {
                            case .watchlist:
                                WatchlistView(store: router.watchlist, directory: router.directory, quotes: router.solanaQuotes, onOpen: { router.open($0) })
                            case .alerts:
                                AlertsView(store: router.alerts, directory: router.directory, quotes: router.solanaQuotes, onOpen: { router.open($0) })
                            case .liquidations:
                                LiquidationsView(model: router.liquidations, onOpen: { router.open(coin: $0) })
                            }
                        } else if let history = tab.history {
                            HistoryView(model: history, wallets: router.wallets, onOpen: { router.openMarket(for: $0) })
                        } else if let web = tab.web {
                            WebTabView(model: web)
                        } else if let list = tab.list {
                            MarketsView(model: list, directory: router.directory) { router.open(coin: $0) }
                        } else {
                            LaunchpadPane()
                        }
                    }
                }
                .id(group.selectedID)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Term.background)
                .overlay(alignment: .topLeading) {
                    if let target = router.dropTarget, target.group == group.id {
                        DropPreview(zone: target.zone, size: geometry.size)
                    }
                }
                .onDrop(of: [.text], delegate: WorkspaceDropDelegate(group: group, router: router, size: geometry.size))
            }
        }
        .clipped()
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { router.activate(group) })
    }
}

/// Shaded area showing where a dragged tab or pane will land.
private struct DropPreview: View {
    let zone: DropZone
    let size: CGSize

    var body: some View {
        let rect: CGRect = switch zone {
        case .center: CGRect(x: 0, y: 0, width: size.width, height: size.height)
        case .left: CGRect(x: 0, y: 0, width: size.width / 2, height: size.height)
        case .right: CGRect(x: size.width / 2, y: 0, width: size.width / 2, height: size.height)
        case .top: CGRect(x: 0, y: 0, width: size.width, height: size.height / 2)
        case .bottom: CGRect(x: 0, y: size.height / 2, width: size.width, height: size.height / 2)
        }
        Term.accent.opacity(0.18)
            .overlay(Rectangle().stroke(Term.accent.opacity(0.6), lineWidth: 1))
            .frame(width: rect.width, height: rect.height)
            .offset(x: rect.minX, y: rect.minY)
            .allowsHitTesting(false)
            .animation(.easeOut(duration: 0.1), value: zone)
    }
}

/// Accepts dragged tabs and panes. On the pane body the pointer picks a snap zone; the tab strip
/// always drops into the pane (`fixedZone`), optionally before a given tab (`index`).
private struct WorkspaceDropDelegate: DropDelegate {
    let group: PaneGroup
    let router: AppRouter
    var size: CGSize = .zero
    var fixedZone: DropZone?
    var index: Int?

    private func zone(_ info: DropInfo) -> DropZone {
        fixedZone ?? DropZone.at(info.location, in: size)
    }

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.text])
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        router.setDropTarget(DropTarget(group: group.id, zone: zone(info), index: index))
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        router.clearDropTarget(for: group.id)
    }

    func performDrop(info: DropInfo) -> Bool {
        let zone = zone(info)
        router.clearDropTarget()
        guard let provider = info.itemProviders(for: [.text]).first else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { [group, router, index] object, _ in
            guard let payload = object as? String else { return }
            Task { @MainActor in
                router.drop(payload, on: group, zone: zone, index: index)
            }
        }
        return true
    }
}

private struct LaunchpadPane: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var navigation = LaunchpadNavigation()

    /// No `NavigationStack`: it would put this tab's title, search and buttons in the window's title bar.
    var body: some View {
        Group {
            if let token = navigation.token {
                TokenDetailView(token: token)
                    .id(token.id)
            } else {
                LaunchpadView()
            }
        }
        .environmentObject(navigation)
        .task {
            if model.loadState == .idle { await model.refresh() }
        }
    }
}

// MARK: - Tab strip

private struct TabStrip: View {
    let group: PaneGroup
    @ObservedObject var router: AppRouter
    let directory: MarketDirectory
    let isActive: Bool

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(group.tabs.enumerated()), id: \.element.id) { index, tab in
                TabCell(
                    tab: tab,
                    directory: directory,
                    isSelected: tab.id == group.selectedID,
                    isGroupActive: isActive,
                    onSelect: { router.select(tab.id, in: group) },
                    onClose: { router.close(tab.id, in: group) }
                )
                // A drop on a tab lands just before it; the accent bar marks the slot.
                .overlay(alignment: .leading) {
                    if let target = router.dropTarget, target.group == group.id, target.index == index {
                        Term.accent.frame(width: 2)
                    }
                }
                .onDrag {
                    NSItemProvider(object: (WorkspaceDrag.tabPrefix + tab.id.uuidString) as NSString)
                }
                .onDrop(
                    of: [.text],
                    delegate: WorkspaceDropDelegate(group: group, router: router, fixedZone: .center, index: index)
                )
                .contextMenu {
                    Button("Split Right") {
                        router.select(tab.id, in: group)
                        router.split(.horizontal)
                    }
                    Button("Split Down") {
                        router.select(tab.id, in: group)
                        router.split(.vertical)
                    }
                    Divider()
                    Button("Close Tab") { router.close(tab.id, in: group) }
                }
                TermRule(vertical: true)
            }

            Button {
                router.newMarketTab(in: group)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: Term.tabBarHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("New market tab ( t )")
            .accessibilityLabel("New market tab")

            // The empty stretch of the strip is the pane's handle: drag it to move the whole pane.
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                // It reads as part of the title bar, so a double-click does what one does there.
                .onTapGesture(count: 2) { WindowChrome.titleBarDoubleClick(router.keys.window) }
                .onDrag {
                    NSItemProvider(object: (WorkspaceDrag.panePrefix + group.id.uuidString) as NSString)
                }
                .help("Drag to move this pane")
        }
        .lineLimit(1)
    }
}

/// A web tab's title, kept short so one long page name cannot crowd out the other tabs.
private struct WebTabLabel: View {
    @ObservedObject var model: WebTabModel

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "globe").font(.system(size: 10))
            Text(model.label).lineLimit(1).truncationMode(.tail)
        }
        .frame(maxWidth: 170, alignment: .leading)
    }
}

/// Studio-style tab: square and full height; the selected tab takes the pane color, with an accent
/// line along its top edge in the active pane.
private struct TabCell: View {
    let tab: WorkspaceTab
    let directory: MarketDirectory
    let isSelected: Bool
    let isGroupActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if let market = tab.market {
                    MarketTabLabel(model: market, directory: directory)
                } else if let web = tab.web {
                    WebTabLabel(model: web)
                } else {
                    Text(tab.board?.title ?? (tab.positions != nil ? "Positions" : tab.history != nil ? "History" : tab.list == nil ? "Launchpad" : "Markets"))
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(isSelected && isGroupActive ? Term.foreground : Color.secondary)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .opacity(isHovering || isSelected ? 1 : 0)
            .help("Close tab ( ⌘W )")
            .accessibilityLabel("Close tab")
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .frame(height: Term.tabBarHeight)
        .background(isSelected ? Term.background : (isHovering ? Term.faint : .clear))
        .overlay(alignment: .top) {
            if isSelected && isGroupActive {
                Term.accent.frame(height: 1)
            }
        }
        // The selected tab merges into the pane below it.
        .overlay(alignment: .bottom) {
            if isSelected {
                Term.background.frame(height: 1).offset(y: 1)
            }
        }
        .zIndex(isSelected ? 1 : 0)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// Coin and live mid for a market tab; observes the tab's model so a market switch retitles it.
private struct MarketTabLabel: View {
    @ObservedObject var model: PerpsModel
    @ObservedObject var directory: MarketDirectory

    var body: some View {
        // A Solana tab is quoted by its own model; a perp by the shared feed.
        let market = model.solana == nil ? directory.markets[model.coin] : nil
        let mid = model.solana == nil ? directory.mids[model.coin] ?? market?.ctx.midPx : model.lastPrice
        let change = model.solana == nil
            ? mid.flatMap { mid in market.flatMap { $0.ctx.prevDayPx > 0 ? mid / $0.ctx.prevDayPx - 1 : nil } }
            : model.dayChange

        HStack(spacing: 7) {
            Text(model.coin)
            if let mid {
                TickingPrice(
                    value: mid,
                    text: HLFormat.price(mid, decimals: model.solana == nil ? HLFormat.priceDecimals(for: mid, szDecimals: market?.szDecimals ?? 2) : model.priceDecimals),
                    font: Term.font(11),
                    color: change.map(PowderPalette.market) ?? Color.secondary
                )
            }
        }
        .accessibilityElement(children: .combine)
    }
}

enum WindowChrome {
    /// What a title bar double-click does, as chosen in System Settings: fill the screen unless set to minimize or nothing.
    @MainActor static func titleBarDoubleClick(_ window: NSWindow?) {
        switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
        case "Minimize": window?.performMiniaturize(nil)
        case "None": break
        default: window?.performZoom(nil)
        }
    }
}
