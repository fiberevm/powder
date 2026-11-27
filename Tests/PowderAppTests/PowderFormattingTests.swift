import Foundation
import Testing
@testable import PowderApp

@Test func currencyFormattingUsesReadableMagnitude() {
    #expect(PowderFormat.currency(1_250_000) == "$1.25M")
    #expect(PowderFormat.currency(84_200) == "$84.2K")
}

@Test func ageFormattingUsesCompactUnits() {
    let now = Date(timeIntervalSince1970: 10_000)
    #expect(PowderFormat.age(since: now.addingTimeInterval(-90), relativeTo: now) == "1m")
    #expect(PowderFormat.age(since: now.addingTimeInterval(-7_200), relativeTo: now) == "2h")
}

@Test func riskSignalsEscalateFromCodexConcentrationFields() {
    let clear = SampleData.tokens[0]
    let elevated = SampleData.tokens[4]
    #expect(clear.riskLevel == .clear)
    #expect(elevated.riskLevel == .elevated)
}

@Test func illustrativeChartEndsAtTheDisplayedPrice() {
    let token = SampleData.tokens[0]
    let chart = SampleData.chart(for: token)
    #expect(abs((chart.last?.close ?? 0) - token.priceUSD) < 0.000_000_001)
}

@Test func chartTimeframesUseBoundedCodexResolutions() {
    #expect(ChartTimeframe.allCases.map(\.resolution) == ["1", "5", "15", "60", "240"])
    #expect(ChartTimeframe.allCases.map(\.countback) == [60, 72, 96, 168, 180])
    #expect(ChartTimeframe.allCases.map(\.subscriptionField) == ["r1", "r5", "r15", "r60", "r240"])
}

@Test func tokenRouteIdentitySurvivesLiveMetricChanges() {
    var updated = SampleData.tokens[0]
    updated.priceUSD *= 2
    updated.holders += 10

    #expect(TokenRoute(token: SampleData.tokens[0]) == TokenRoute(token: updated))
    #expect(
        Set([TokenRoute(token: SampleData.tokens[0]), TokenRoute(token: updated)]).count == 1
    )
}

@Test func illustrativeChartHonorsRequestedCadence() {
    let chart = SampleData.chart(
        for: SampleData.tokens[0],
        count: 60,
        interval: 60
    )
    #expect(chart.count == 60)
    #expect(
        chart.last!.timestamp.timeIntervalSince(chart.first!.timestamp) == 59 * 60
    )
}

@Test func launchStagesFollowCodexLifecycleThresholds() {
    var token = SampleData.tokens[0]
    token.migrated = false
    token.graduationPercent = 79.9
    #expect(token.launchStage == .bonding)

    token.graduationPercent = 80
    #expect(token.launchStage == .closeToMigration)

    token.graduationPercent = 100
    token.migrated = true
    #expect(token.launchStage == .migrated)
}

@Test @MainActor func dashboardCapsEveryLifecycleColumnAtThirtyTokens() {
    let candidates = LaunchStage.allCases.flatMap { stage in
        (0..<45).map { index in
            var token = SampleData.tokens[0]
            token.address = "\(stage.rawValue)-\(index)"
            token.createdAt = Date(timeIntervalSince1970: TimeInterval(index))

            switch stage {
            case .bonding:
                token.migrated = false
                token.graduationPercent = 25
            case .closeToMigration:
                token.migrated = false
                token.graduationPercent = 90
            case .migrated:
                token.migrated = true
                token.graduationPercent = 100
            }

            return token
        }
    }

    let limited = AppModel.limitedDashboardTokens(candidates)

    for stage in LaunchStage.allCases {
        #expect(limited.count { $0.launchStage == stage } == 30)
    }
    #expect(limited.count == 90)
}

@Test @MainActor func newLaunchesLeadStableColumnRows() {
    var retained = SampleData.tokens[0]
    retained.address = "retained"
    retained.createdAt = Date(timeIntervalSince1970: 100)
    retained.migrated = false
    retained.graduationPercent = 25

    var lifecycleArrival = retained
    lifecycleArrival.address = "lifecycle-arrival"
    lifecycleArrival.createdAt = Date(timeIntervalSince1970: 300)

    var newLaunch = retained
    newLaunch.address = "new-launch"
    newLaunch.createdAt = Date(timeIntervalSince1970: 200)

    let order = LaunchpadView.reconciledStageOrder(
        tokens: [retained, lifecycleArrival, newLaunch],
        currentOrder: [.bonding: [retained.id]],
        knownStages: [
            retained.id: .bonding,
            lifecycleArrival.id: .closeToMigration
        ]
    )

    #expect(
        order[.bonding] == [
            newLaunch.id,
            lifecycleArrival.id,
            retained.id
        ]
    )
}
