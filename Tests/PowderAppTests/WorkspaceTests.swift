import Foundation
import Testing
@testable import PowderApp

@MainActor
private func makeRouter() -> (AppRouter, UserDefaults) {
    let name = "powder.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return (AppRouter(defaults: defaults), defaults)
}

@MainActor
private func coins(_ group: PaneGroup) -> [String] {
    group.tabs.map { $0.market?.coin ?? $0.savedName }
}

@Test @MainActor
func freshInstallOpensTheStandardLayout() {
    let (router, _) = makeRouter()
    #expect(router.groups.map(coins) == [["ETH", "SOL", "HYPE", "markets", "positions", "launchpad"], ["BTC"]])
    #expect(router.activeMarket?.coin == "ETH")
}

@Test @MainActor
func splittingAddsAPaneAndFocusFollowsDirection() {
    let (router, _) = makeRouter()
    router.split(.vertical)
    // ETH pane now sits above a new ETH pane, both left of BTC.
    #expect(router.groups.map(coins) == [["ETH", "SOL", "HYPE", "markets", "positions", "launchpad"], ["ETH"], ["BTC"]])
    #expect(router.activeGroup.id == router.groups[1].id)

    router.focus(.up)
    #expect(router.activeGroup.id == router.groups[0].id)
    router.focus(.right)
    #expect(coins(router.activeGroup) == ["BTC"])
    router.focus(.right)
    #expect(coins(router.activeGroup) == ["BTC"])
    // BTC spans both left-hand panes; either is a valid landing spot.
    router.focus(.left)
    #expect(coins(router.activeGroup) != ["BTC"])
}

@Test @MainActor
func closingAPanesLastTabRemovesThePane() {
    let (router, _) = makeRouter()
    let btc = router.groups[1]
    router.close(btc.tabs[0].id, in: btc)
    #expect(router.groups.map(coins) == [["ETH", "SOL", "HYPE", "markets", "positions", "launchpad"]])
    guard case .group = router.root else {
        Issue.record("a single remaining pane should become the root")
        return
    }
}

@Test @MainActor
func theFinalTabCannotBeClosed() {
    let (router, _) = makeRouter()
    for group in router.groups {
        for tab in group.tabs { router.close(tab.id, in: group) }
    }
    #expect(router.groups.count == 1)
    #expect(router.groups[0].tabs.count == 1)
}

@Test @MainActor
func layoutSurvivesARelaunch() {
    let (router, defaults) = makeRouter()
    router.split(.horizontal)
    router.activeMarket?.select(coin: "DOGE")
    router.select(index: 0)

    let relaunched = AppRouter(defaults: defaults)
    #expect(relaunched.groups.map(coins) == [["ETH", "SOL", "HYPE", "markets", "positions", "launchpad"], ["DOGE"], ["BTC"]])
    #expect(relaunched.activeMarket?.coin == "DOGE")
}

@Test @MainActor
func draggingATabReordersMergesAndSplits() {
    let (router, _) = makeRouter()
    let left = router.groups[0]
    let right = router.groups[1]

    // Reorder within the strip: HYPE dropped before ETH.
    router.move(tab: left.tabs[2].id, to: left, zone: .center, index: 0)
    #expect(coins(left) == ["HYPE", "ETH", "SOL", "markets", "positions", "launchpad"])

    // Into another pane's strip, before its first tab.
    router.move(tab: left.tabs[2].id, to: right, zone: .center, index: 0)
    #expect(router.groups.map(coins) == [["HYPE", "ETH", "markets", "positions", "launchpad"], ["SOL", "BTC"]])
    #expect(router.activeMarket?.coin == "SOL")

    // Onto a pane's top edge: a new pane above it.
    router.move(tab: right.tabs[1].id, to: right, zone: .top)
    #expect(router.groups.map(coins) == [["HYPE", "ETH", "markets", "positions", "launchpad"], ["BTC"], ["SOL"]])

    // A pane's only tab cannot be split off itself.
    let btc = router.groups[1]
    router.move(tab: btc.tabs[0].id, to: btc, zone: .left)
    #expect(router.groups.count == 3)

    // Moving a pane's last tab away removes the pane.
    router.move(tab: btc.tabs[0].id, to: left, zone: .center)
    #expect(router.groups.map(coins) == [["HYPE", "ETH", "markets", "positions", "launchpad", "BTC"], ["SOL"]])
}

@Test @MainActor
func draggingAPaneMovesOrMergesIt() {
    let (router, _) = makeRouter()
    let left = router.groups[0]
    let right = router.groups[1]

    router.move(pane: right.id, to: left, zone: .left)
    #expect(router.groups.map(coins) == [["BTC"], ["ETH", "SOL", "HYPE", "markets", "positions", "launchpad"]])

    router.move(pane: right.id, to: left, zone: .bottom)
    #expect(router.groups.map(coins) == [["ETH", "SOL", "HYPE", "markets", "positions", "launchpad"], ["BTC"]])
    guard case let .split(box) = router.root else {
        Issue.record("expected a split root")
        return
    }
    #expect(box.axis == .vertical)

    router.move(pane: right.id, to: left, zone: .center)
    #expect(router.groups.map(coins) == [["ETH", "SOL", "HYPE", "markets", "positions", "launchpad", "BTC"]])
    #expect(router.activeMarket?.coin == "BTC")
}

@Test @MainActor
func openingAMarketReusesItsTabOrAddsOne() {
    let (router, _) = makeRouter()

    // BTC is already open in the right pane: focus moves there and no tab is added.
    router.open(coin: "BTC")
    #expect(coins(router.activeGroup) == ["BTC"])
    #expect(router.groups.count == 2)

    // DOGE is not open: it becomes a new tab beside the selected one in the active pane.
    router.open(coin: "DOGE")
    #expect(coins(router.activeGroup) == ["BTC", "DOGE"])
    #expect(router.activeMarket?.coin == "DOGE")

    router.open(coin: "ETH")
    #expect(router.activeMarket?.coin == "ETH")
    #expect(router.groups.map(coins) == [["ETH", "SOL", "HYPE", "markets", "positions", "launchpad"], ["BTC", "DOGE"]])
}

@Test @MainActor
func marketsTableSortsAndIndicatorsCompute() {
    let model = MarketsModel()
    model.sort(by: .change)
    #expect(model.sort == .change && !model.ascending)
    model.sort(by: .change)
    #expect(model.ascending)
    model.sort(by: .ticker)
    #expect(model.sort == .ticker && model.ascending)

    #expect(ChartMath.sma([1, 2, 3, 4], 2) == [nil, 1.5, 2.5, 3.5])
    #expect(ChartMath.ema([2, 2, 2, 2], 3) == [nil, nil, 2, 2])
    let rising = ChartMath.rsi((0..<20).map(Double.init), 14)
    #expect(rising[13] == nil && rising[19] == 100)
}
