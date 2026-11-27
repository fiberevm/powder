import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var tokens = SampleData.tokens
    @Published private(set) var dataMode: DataMode = .demo
    @Published private(set) var loadState: LoadState = .idle
    @Published private(set) var realtimeState: RealtimeConnectionState = .demo
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var lastStreamEventAt: Date?
    @Published private(set) var streamedUpdateCount = 0
    @Published var notice: String?

    private let client: CodexClient
    private let keychain: KeychainStore
    private var chartCache: [String: ChartLoadResult] = [:]
    private var realtimeTask: Task<Void, Never>?
    private var streamFlushTask: Task<Void, Never>?
    private var pendingStreamEvents: [CodexStreamEvent] = []
    private var liveTokenCandidates: [String: TokenSnapshot] = [:]
    private var lastDashboardMembershipRefreshAt: Date?
    private var pinnedDetailTokenIDs: Set<String> = []

    private static let maximumTokensPerStage = 30
    private static let maximumCandidatesPerStage = 120
    private static let streamCommitInterval = Duration.milliseconds(3_000)
    private static let dashboardMembershipRefreshInterval: TimeInterval = 5

    init(
        client: CodexClient = CodexClient(),
        keychain: KeychainStore = KeychainStore()
    ) {
        self.client = client
        self.keychain = keychain
    }

    var hasAPIKey: Bool {
        keychain.readAPIKey() != nil
    }

    func refresh() async {
        guard loadState != .loading else { return }
        stopRealtime()
        lastStreamEventAt = nil
        streamedUpdateCount = 0
        loadState = .loading
        defer { loadState = .loaded }

        guard let apiKey = keychain.readAPIKey() else {
            tokens = SampleData.tokens
            liveTokenCandidates.removeAll(keepingCapacity: false)
            lastDashboardMembershipRefreshAt = nil
            pinnedDetailTokenIDs.removeAll(keepingCapacity: false)
            dataMode = .demo
            realtimeState = .demo
            notice = nil
            lastUpdated = Date()
            return
        }

        do {
            realtimeState = .connecting
            let snapshot = try await client.fetchLaunchpadTokens(apiKey: apiKey)
            liveTokenCandidates = Dictionary(
                uniqueKeysWithValues: snapshot.map { ($0.id, $0) }
            )
            tokens = Self.limitedDashboardTokens(snapshot)
            lastDashboardMembershipRefreshAt = Date()
            dataMode = .live
            notice = nil
            lastUpdated = Date()
            chartCache.removeAll()
            startRealtime(apiKey: apiKey)
        } catch {
            tokens = SampleData.tokens
            liveTokenCandidates.removeAll(keepingCapacity: false)
            lastDashboardMembershipRefreshAt = nil
            pinnedDetailTokenIDs.removeAll(keepingCapacity: false)
            dataMode = .demo
            realtimeState = .demo
            notice = "\(error.localizedDescription) Showing demo data instead."
            lastUpdated = Date()
        }
    }

    func chart(
        for token: TokenSnapshot,
        timeframe: ChartTimeframe
    ) async -> ChartLoadResult {
        let cacheKey = "\(token.id)|\(timeframe.rawValue)"
        if let cached = chartCache[cacheKey] {
            return cached
        }

        guard dataMode == .live, let apiKey = keychain.readAPIKey() else {
            let sample = SampleData.chart(
                for: token,
                count: timeframe.countback,
                interval: timeframe.seconds / Double(timeframe.countback)
            )
            let result = ChartLoadResult(points: sample, source: .illustrative)
            chartCache[cacheKey] = result
            return result
        }

        do {
            let points = try await client.fetchBars(
                for: token.address,
                timeframe: timeframe,
                apiKey: apiKey
            )
            let result = ChartLoadResult(points: points, source: .codexSnapshot)
            chartCache[cacheKey] = result
            return result
        } catch {
            let sample = SampleData.chart(
                for: token,
                count: timeframe.countback,
                interval: timeframe.seconds / Double(timeframe.countback)
            )
            let result = ChartLoadResult(points: sample, source: .illustrative)
            chartCache[cacheKey] = result
            return result
        }
    }

    func token(withID id: String) -> TokenSnapshot? {
        tokens.first { $0.id == id }
    }

    func liveTokenDetailStream(
        for token: TokenSnapshot,
        timeframe: ChartTimeframe
    ) -> AsyncThrowingStream<TokenDetailStreamEvent, Error>? {
        guard dataMode == .live, let apiKey = keychain.readAPIKey() else {
            return nil
        }
        return client.tokenDetailStream(
            for: token.address,
            timeframe: timeframe,
            apiKey: apiKey
        )
    }

    func setDetailToken(_ id: String, isPinned: Bool) {
        if isPinned {
            pinnedDetailTokenIDs.insert(id)
        } else {
            pinnedDetailTokenIDs.remove(id)
        }
    }

    func saveAPIKey(_ value: String) throws {
        stopRealtime()
        try keychain.saveAPIKey(value)
        liveTokenCandidates.removeAll(keepingCapacity: false)
        lastDashboardMembershipRefreshAt = nil
        pinnedDetailTokenIDs.removeAll(keepingCapacity: false)
        chartCache.removeAll()
    }

    func removeAPIKey() {
        stopRealtime()
        keychain.deleteAPIKey()
        tokens = SampleData.tokens
        dataMode = .demo
        realtimeState = .demo
        lastStreamEventAt = nil
        streamedUpdateCount = 0
        liveTokenCandidates.removeAll(keepingCapacity: false)
        lastDashboardMembershipRefreshAt = nil
        pinnedDetailTokenIDs.removeAll(keepingCapacity: false)
        chartCache.removeAll()
        notice = nil
    }

    private func startRealtime(apiKey: String) {
        realtimeTask?.cancel()
        realtimeTask = Task { [weak self, client] in
            var reconnectAttempt = 0

            while !Task.isCancelled {
                guard let self else { return }
                self.realtimeState = reconnectAttempt == 0
                    ? .connecting
                    : .reconnecting(attempt: reconnectAttempt)

                do {
                    for try await event in client.launchpadStream(apiKey: apiKey) {
                        try Task.checkCancellation()
                        self.enqueue(event)
                        reconnectAttempt = 0
                    }

                    if Task.isCancelled { return }
                    throw CodexError.webSocket(nil, "The stream ended unexpectedly.")
                } catch is CancellationError {
                    return
                } catch CodexError.subscriptionUnavailable {
                    self.flushPendingStreamEvents()
                    self.realtimeState = .unavailable
                    self.notice = "Codex subscriptions require a Growth or Enterprise plan. The latest HTTP snapshot remains visible."
                    return
                } catch {
                    self.flushPendingStreamEvents()
                    reconnectAttempt += 1
                    self.realtimeState = .reconnecting(attempt: reconnectAttempt)
                    self.notice = "\(error.localizedDescription) Powder is reconnecting while the last values remain visible."

                    let delay = min(pow(2, Double(reconnectAttempt)), 30)
                    try? await Task.sleep(for: .seconds(delay))
                }
            }
        }
    }

    private func enqueue(_ event: CodexStreamEvent) {
        if case .connected = event {
            if realtimeState != .live {
                realtimeState = .live
                notice = nil
            }
            return
        }

        pendingStreamEvents.append(event)
        guard streamFlushTask == nil else { return }

        streamFlushTask = Task { [weak self] in
            do {
                try await Task.sleep(for: Self.streamCommitInterval)
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            self.flushPendingStreamEvents()
        }
    }

    private func flushPendingStreamEvents() {
        streamFlushTask?.cancel()
        streamFlushTask = nil

        guard !pendingStreamEvents.isEmpty else { return }
        let events = pendingStreamEvents
        pendingStreamEvents.removeAll(keepingCapacity: true)

        var byAddress = liveTokenCandidates.isEmpty
            ? Dictionary(uniqueKeysWithValues: tokens.map { ($0.id, $0) })
            : liveTokenCandidates
        var updateCount = 0

        for event in events {
            switch event {
            case .connected:
                continue

            case let .filter(updates, removedTokenIDs, replacesCurrentSet):
                if replacesCurrentSet {
                    byAddress = Dictionary(uniqueKeysWithValues: updates.map { ($0.id, $0) })
                } else {
                    for id in removedTokenIDs {
                        byAddress.removeValue(forKey: Self.address(fromTokenID: id))
                    }
                    for token in updates {
                        byAddress[token.id] = token
                    }
                }
                updateCount += updates.count + removedTokenIDs.count

            case let .launchpad(patches):
                for patch in patches {
                    byAddress[patch.address] = patch.applying(to: byAddress[patch.address])
                }
                updateCount += patches.count
            }
        }

        liveTokenCandidates = Self.trimmedCandidateCache(
            Array(byAddress.values),
            retaining: Set(tokens.map(\.id))
        )

        let now = Date()
        let shouldRefreshMembership = lastDashboardMembershipRefreshAt.map {
            now.timeIntervalSince($0) >= Self.dashboardMembershipRefreshInterval
        } ?? true

        tokens = Self.stabilizedDashboardTokens(
            Array(liveTokenCandidates.values),
            retaining: tokens,
            protectedTokenIDs: pinnedDetailTokenIDs,
            maximumRankedReplacementsPerStage: shouldRefreshMembership ? 1 : 0
        )
        if shouldRefreshMembership {
            lastDashboardMembershipRefreshAt = now
        }
        recordStreamEvent(updateCount: updateCount)
    }

    private func recordStreamEvent(updateCount: Int) {
        if realtimeState != .live {
            realtimeState = .live
        }
        lastStreamEventAt = Date()
        lastUpdated = Date()
        streamedUpdateCount += updateCount
    }

    private func stopRealtime() {
        realtimeTask?.cancel()
        realtimeTask = nil
        streamFlushTask?.cancel()
        streamFlushTask = nil
        pendingStreamEvents.removeAll(keepingCapacity: false)
    }

    private static func address(fromTokenID id: String) -> String {
        id.split(separator: ":", maxSplits: 1).first.map(String.init) ?? id
    }

    static func limitedDashboardTokens(
        _ candidates: [TokenSnapshot]
    ) -> [TokenSnapshot] {
        LaunchStage.allCases.flatMap { stage in
            rankedTokens(candidates, for: stage)
                .prefix(maximumTokensPerStage)
        }
    }

    private static func stabilizedDashboardTokens(
        _ candidates: [TokenSnapshot],
        retaining current: [TokenSnapshot],
        protectedTokenIDs: Set<String>,
        maximumRankedReplacementsPerStage: Int
    ) -> [TokenSnapshot] {
        let byID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
        let previousStageByID = Dictionary(
            uniqueKeysWithValues: current.map { ($0.id, $0.launchStage) }
        )

        return LaunchStage.allCases.flatMap { stage in
            let ranked = rankedTokens(candidates, for: stage)
            let rankByID = Dictionary(
                uniqueKeysWithValues: ranked.enumerated().map { ($0.element.id, $0.offset) }
            )
            let promoted = ranked.filter { token in
                guard let previousStage = previousStageByID[token.id] else {
                    return false
                }
                return previousStage != stage
            }
            let promotedIDs = Set(promoted.map(\.id))
            let protectedIDs = promotedIDs.union(protectedTokenIDs)
            let retained = current.compactMap { token -> TokenSnapshot? in
                guard token.launchStage == stage,
                      let updated = byID[token.id],
                      updated.launchStage == stage else {
                    return nil
                }
                return updated
            }

            var selected = promoted + retained.filter { !promotedIDs.contains($0.id) }
            while selected.count > maximumTokensPerStage {
                let removableIndex = selected.indices
                    .filter { !protectedIDs.contains(selected[$0].id) }
                    .max {
                        (rankByID[selected[$0].id] ?? .max)
                            < (rankByID[selected[$1].id] ?? .max)
                    }
                    ?? selected.index(before: selected.endIndex)
                selected.remove(at: removableIndex)
            }

            var selectedIDs = Set(selected.map(\.id))
            for token in ranked where selected.count < maximumTokensPerStage {
                guard selectedIDs.insert(token.id).inserted else { continue }
                selected.append(token)
            }

            for _ in 0..<maximumRankedReplacementsPerStage {
                let worstIndex = selected.indices
                    .filter { index in
                        !protectedIDs.contains(selected[index].id)
                    }
                    .max { lhs, rhs in
                        (rankByID[selected[lhs].id] ?? .max)
                            < (rankByID[selected[rhs].id] ?? .max)
                    }

                guard selected.count == maximumTokensPerStage,
                      let bestNewcomer = ranked.first(where: { !selectedIDs.contains($0.id) }),
                      let worstIndex,
                      (rankByID[bestNewcomer.id] ?? .max)
                        < (rankByID[selected[worstIndex].id] ?? .max) else {
                    break
                }

                selectedIDs.remove(selected[worstIndex].id)
                selected[worstIndex] = bestNewcomer
                selectedIDs.insert(bestNewcomer.id)
            }

            return selected
        }
    }

    private static func trimmedCandidateCache(
        _ candidates: [TokenSnapshot],
        retaining retainedIDs: Set<String>
    ) -> [String: TokenSnapshot] {
        let retained = candidates.filter { retainedIDs.contains($0.id) }
        let ranked = LaunchStage.allCases.flatMap { stage in
            rankedTokens(candidates, for: stage)
                .prefix(maximumCandidatesPerStage)
        }

        return Dictionary(
            (retained + ranked).map { ($0.id, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
    }

    private static func rankedTokens(
        _ candidates: [TokenSnapshot],
        for stage: LaunchStage
    ) -> [TokenSnapshot] {
        candidates
            .filter { $0.launchStage == stage }
            .sorted { lhs, rhs in
                if stage == .closeToMigration,
                   lhs.graduationPercent != rhs.graduationPercent {
                    return lhs.graduationPercent > rhs.graduationPercent
                }
                if lhs.createdAt != rhs.createdAt {
                    return lhs.createdAt > rhs.createdAt
                }
                return lhs.id < rhs.id
            }
    }
}
