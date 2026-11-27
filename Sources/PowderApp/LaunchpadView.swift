/*
 THESIS: Powder turns every Codex-indexed Solana launchpad into one continuous lifecycle instrument.
 OWN-WORLD: Graphite native materials, porcelain labels, a single scope-blue trace, and green/amber state signals.
 STORY: Scan Bonding, Close to migrating, and Migrated at once; rows move between stages as Codex emits updates.
 FIRST VIEWPORT: Stream provenance and three equal, independently scrolling table columns remain visible together.
 FORM: “The Instruments Room,” assigned grounded direction 3; scope-led staging with compact table readouts; seed bf64a5c0.
*/

import SwiftUI

/// Which token a Launchpad tab is showing; `nil` is the lifecycle board. Kept per tab so the
/// tab navigates inside its own pane.
@MainActor
final class LaunchpadNavigation: ObservableObject {
    @Published var token: TokenSnapshot?
}

struct LaunchpadView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openSettings) private var openSettings
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var searchText = ""
    @State private var stageOrder: [LaunchStage: [String]] = [:]
    @State private var knownStages: [String: LaunchStage] = [:]

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                paneBar
                header

                if let notice = model.notice {
                    noticeBanner(notice)
                }

                lifecycleBoard(width: geometry.size.width)
            }
        }
        .onAppear {
            reconcileStageOrder()
        }
        .onChange(of: stageMembership) {
            reconcileStageOrder()
        }
    }

    /// Search and actions live inside the pane, so the tab never reaches into the window's title bar.
    private var paneBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField("Name, symbol, launchpad, or address", text: $searchText)
                .textFieldStyle(.plain)
                .font(Term.font(12))

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Clear search")
            }

            Button {
                Task { await model.refresh() }
            } label: {
                if model.loadState == .loading {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.plain)
            .help("Refresh the Codex snapshot and reconnect subscriptions")
            .disabled(model.loadState == .loading)

            Button {
                openSettings()
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .buttonStyle(.plain)
            .help("Configure the Codex API key")
        }
        .padding(.horizontal, 12)
        .frame(height: 28)
        .background(Term.chrome)
        .overlay(alignment: .bottom) { TermRule() }
    }

    private var filteredTokens: [TokenSnapshot] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return model.tokens }

        return model.tokens.filter { token in
            token.name.localizedCaseInsensitiveContains(query)
                || token.symbol.localizedCaseInsensitiveContains(query)
                || token.launchpadName.localizedCaseInsensitiveContains(query)
                || token.address.localizedCaseInsensitiveContains(query)
        }
    }

    private var stageMembership: Set<TokenStageMembership> {
        Set(model.tokens.map {
            TokenStageMembership(id: $0.id, stage: $0.launchStage)
        })
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 18) {
                    titleBlock
                    Spacer(minLength: 24)
                    streamReadout
                }

                VStack(alignment: .leading, spacing: 12) {
                    titleBlock
                    streamReadout
                }
            }

            HStack(spacing: 8) {
                Image(systemName: "square.stack.3d.up.fill")
                    .foregroundStyle(PowderPalette.scopeBlue)
                Text(scopeLabel)
                    .font(.caption.weight(.medium))
                Text("·")
                    .foregroundStyle(.tertiary)
                Text(scopeDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 17)
        .background(PowderPalette.surface(colorScheme))
        .overlay(alignment: .bottom) { Divider() }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 10) {
                Text("Launchpad")
                    .font(.largeTitle.weight(.semibold))
                DataModeBadge(mode: model.dataMode)
                RealtimeStatusBadge(state: model.realtimeState)
            }

            Text(headerSubtitle)
                .font(.body)
                .foregroundStyle(.secondary)
        }
    }

    private var streamReadout: some View {
        VStack(alignment: .trailing, spacing: 3) {
            switch model.realtimeState {
            case .demo:
                Text("Illustrative snapshot")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            case .unavailable:
                Text("Codex snapshot only")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            case .connecting, .reconnecting:
                Text("Waiting for the Codex stream")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(PowderPalette.cautionAmber)
            case .live:
                if model.streamedUpdateCount > 0 {
                    MonospacedValue(
                        text: "\(PowderFormat.count(model.streamedUpdateCount)) streamed updates",
                        color: PowderPalette.scopeBlue,
                        weight: .semibold
                    )
                    .font(.caption)
                } else {
                    Text("Connected · awaiting first event")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(PowderPalette.signalGreen)
                }
            }

            if model.realtimeState == .live, let eventDate = model.lastStreamEventAt {
                Text("Last event \(eventDate, style: .relative)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if let updated = model.lastUpdated {
                Text("Snapshot \(updated, style: .relative)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: model.realtimeState)
    }

    private var headerSubtitle: String {
        switch model.realtimeState {
        case .demo:
            "Explore the three-stage Solana lifecycle with illustrative market data."
        case .unavailable:
            "The latest Codex launchpad snapshot, arranged by migration stage."
        case .connecting, .reconnecting:
            "A unified Solana lifecycle table preparing its Codex subscriptions."
        case .live:
            "One live lifecycle table for every Solana launch venue."
        }
    }

    private var scopeLabel: String {
        model.realtimeState == .demo
            ? "Illustrative multi-launchpad sample"
            : "All Codex-supported Solana launchpads"
    }

    private var scopeDetail: String {
        switch model.realtimeState {
        case .demo:
            "Connect Codex in Settings to start subscriptions"
        case .unavailable:
            "Refresh reloads the latest snapshot"
        case .connecting, .reconnecting:
            "Rows will move when lifecycle events arrive"
        case .live:
            "Rows change columns as lifecycle events arrive"
        }
    }

    private func lifecycleBoard(width: CGFloat) -> some View {
        let minimumBoardWidth: CGFloat = 930

        return ScrollView(.horizontal) {
            HStack(spacing: 0) {
                ForEach(Array(LaunchStage.allCases.enumerated()), id: \.element) { index, stage in
                    LaunchStageColumn(
                        stage: stage,
                        tokens: tokens(in: stage)
                    )

                    if index < LaunchStage.allCases.count - 1 {
                        Divider()
                    }
                }
            }
            .frame(width: max(width, minimumBoardWidth))
        }
        .scrollIndicators(.visible)
        .background(PowderPalette.workspace(colorScheme))
    }

    private func tokens(in stage: LaunchStage) -> [TokenSnapshot] {
        let matching = filteredTokens.filter { $0.launchStage == stage }
        let byID = Dictionary(uniqueKeysWithValues: matching.map { ($0.id, $0) })
        let ordered = (stageOrder[stage] ?? []).compactMap { byID[$0] }
        let orderedIDs = Set(ordered.map(\.id))
        let untracked = matching.filter { !orderedIDs.contains($0.id) }
        return ordered + Self.defaultOrder(untracked, for: stage)
    }

    private func reconcileStageOrder() {
        let nextKnownStages = Dictionary(
            uniqueKeysWithValues: model.tokens.map { ($0.id, $0.launchStage) }
        )
        let nextOrder = Self.reconciledStageOrder(
            tokens: model.tokens,
            currentOrder: stageOrder,
            knownStages: knownStages
        )

        if nextOrder != stageOrder {
            stageOrder = nextOrder
        }
        if nextKnownStages != knownStages {
            knownStages = nextKnownStages
        }
    }

    static func reconciledStageOrder(
        tokens: [TokenSnapshot],
        currentOrder: [LaunchStage: [String]],
        knownStages: [String: LaunchStage]
    ) -> [LaunchStage: [String]] {
        var nextOrder = currentOrder

        for stage in LaunchStage.allCases {
            let stageTokens = tokens.filter { $0.launchStage == stage }
            let currentIDs = Set(stageTokens.map(\.id))
            let retained = (currentOrder[stage] ?? []).filter(currentIDs.contains)
            let retainedIDs = Set(retained)
            let additions = defaultOrder(
                stageTokens.filter { !retainedIDs.contains($0.id) },
                for: stage
            )

            let newArrivals = additions.filter { knownStages[$0.id] == nil }
            let lifecycleArrivals = additions.filter { token in
                guard let previous = knownStages[token.id] else { return false }
                return previous != stage
            }
            let returningRows = additions.filter { knownStages[$0.id] == stage }

            nextOrder[stage] =
                newArrivals.map(\.id)
                + lifecycleArrivals.map(\.id)
                + retained
                + returningRows.map(\.id)
        }

        return nextOrder
    }

    private static func defaultOrder(
        _ tokens: [TokenSnapshot],
        for stage: LaunchStage
    ) -> [TokenSnapshot] {
        tokens.sorted { lhs, rhs in
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

    private func noticeBanner(_ notice: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(PowderPalette.cautionAmber)
            Text(notice)
                .font(.callout)
                .textSelection(.enabled)
            Spacer()
            Button("Settings") {
                openSettings()
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
        .background(PowderPalette.cautionAmber.opacity(0.1))
        .overlay(alignment: .bottom) { Divider() }
    }
}

private struct TokenStageMembership: Hashable {
    let id: String
    let stage: LaunchStage
}

private struct LaunchStageColumn: View {
    @EnvironmentObject private var navigation: LaunchpadNavigation
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let stage: LaunchStage
    let tokens: [TokenSnapshot]

    var body: some View {
        VStack(spacing: 0) {
            stageHeader
            tableHeader

            if tokens.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(tokens) { token in
                            VStack(spacing: 0) {
                                Button {
                                    navigation.token = token
                                } label: {
                                    LifecycleTokenRow(token: token, stage: stage)
                                        .equatable()
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("\(token.name), \(token.symbol)")
                                .accessibilityValue(accessibilityValue(for: token))
                                .accessibilityHint("Open token details")

                                Divider()
                                    .padding(.leading, 18)
                            }
                            .transition(rowTransition)
                        }
                    }
                    .animation(layoutAnimation, value: tokens.map(\.id))
                }
            }
        }
        .frame(maxWidth: .infinity)
        .background(PowderPalette.workspace(colorScheme))
    }

    private var stageHeader: some View {
        HStack(spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(stageColor.opacity(0.13))
                Image(systemName: stage.systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(stageColor)
            }
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 1) {
                Text(stage.title)
                    .font(.headline)
                Text(stage.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(tokens.count.formatted())
                .font(.system(.callout, design: .monospaced, weight: .semibold))
                .foregroundStyle(stageColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(stageColor.opacity(0.1), in: Capsule())
                .contentTransition(.numericText())
                .accessibilityLabel("\(tokens.count) tokens")
                .animation(valueAnimation, value: tokens.count)
        }
        .padding(.horizontal, 18)
        .frame(height: 62)
        .background(PowderPalette.surface(colorScheme))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(stageColor)
                .frame(height: 2)
        }
    }

    private var tableHeader: some View {
        HStack {
            Text("TOKEN / VENUE")
            Spacer()
            Text("PRICE / 5M")
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 18)
        .frame(height: 32)
        .background(PowderPalette.surface(colorScheme).opacity(0.72))
        .overlay(alignment: .bottom) { Divider() }
    }

    private var emptyState: some View {
        VStack(spacing: 9) {
            Image(systemName: stage.systemImage)
                .font(.title3)
                .foregroundStyle(stageColor)
            Text("No \(stage.title.lowercased()) tokens")
                .font(.callout.weight(.medium))
            Text("Matching launches will appear here as Codex emits them.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 210)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(28)
    }

    private var stageColor: Color {
        switch stage {
        case .bonding: PowderPalette.scopeBlue
        case .closeToMigration: PowderPalette.cautionAmber
        case .migrated: PowderPalette.signalGreen
        }
    }

    private var layoutAnimation: Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.16)
    }

    private var valueAnimation: Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.22)
    }

    private var rowTransition: AnyTransition {
        guard !reduceMotion else { return .identity }
        return .opacity
    }

    private func accessibilityValue(for token: TokenSnapshot) -> String {
        [
            stage.title,
            token.launchpadName,
            "price \(PowderFormat.currency(token.priceUSD, precise: true))",
            "5 minute change \(PowderFormat.percent(token.change5m))",
            "liquidity \(PowderFormat.currency(token.liquidityUSD))",
            "24 hour volume \(PowderFormat.currency(token.volume24h))",
            "market cap \(PowderFormat.currency(token.marketCapUSD))",
            "migration progress \(PowderFormat.wholePercent(token.graduationPercent))"
        ]
        .joined(separator: ", ")
    }
}

private struct LifecycleTokenRow: View, Equatable {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let token: TokenSnapshot
    let stage: LaunchStage

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 10) {
                TokenMark(token: token, size: 34)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(token.symbol)
                            .font(.callout.weight(.semibold))
                            .lineLimit(1)
                        Text(token.name)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    HStack(spacing: 5) {
                        Text(token.launchpadName)
                            .lineLimit(1)
                        Text("·")
                        Text(PowderFormat.age(since: token.createdAt))
                    }
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                }

                Spacer(minLength: 5)

                VStack(alignment: .trailing, spacing: 2) {
                    MonospacedValue(
                        text: PowderFormat.currency(token.priceUSD, precise: true),
                        weight: .semibold,
                        animatesChanges: false
                    )
                    .font(.caption)
                    .lineLimit(1)

                    Text(PowderFormat.percent(token.change5m))
                        .font(.system(.caption2, design: .monospaced, weight: .semibold))
                        .foregroundStyle(PowderPalette.market(token.change5m))
                }

                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }

            HStack(spacing: 8) {
                CompactMetric(label: "LIQ", value: PowderFormat.currency(token.liquidityUSD))
                Divider()
                    .frame(height: 24)
                CompactMetric(label: "24H VOL", value: PowderFormat.currency(token.volume24h))
                Divider()
                    .frame(height: 24)
                CompactMetric(label: "MCAP", value: PowderFormat.currency(token.marketCapUSD))
            }

            lifecycleTrace
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
        .contentShape(Rectangle())
        .background(
            isHovering
                ? PowderPalette.surface(colorScheme)
                : Color.primary.opacity(0.0001)
        )
        .onHover { isHovering = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isHovering)
    }

    @ViewBuilder
    private var lifecycleTrace: some View {
        if stage == .migrated {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(PowderPalette.signalGreen)
                Text("DEX liquidity live")
                    .font(.caption2.weight(.medium))
                Spacer()
                Text(token.shortAddress)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        } else {
            VStack(spacing: 5) {
                HStack {
                    Text(stage == .closeToMigration ? "Migration readiness" : "Bonding progress")
                    Spacer()
                    Text(PowderFormat.wholePercent(token.graduationPercent))
                        .font(.system(.caption2, design: .monospaced, weight: .semibold))
                }
                .font(.caption2)
                .foregroundStyle(.secondary)

                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.secondary.opacity(0.14))
                        Capsule()
                            .fill(
                                stage == .closeToMigration
                                    ? PowderPalette.cautionAmber
                                    : PowderPalette.scopeBlue
                            )
                            .frame(
                                width: geometry.size.width
                                    * min(max(token.graduationPercent / 100, 0), 1)
                            )
                    }
                }
                .frame(height: 4)
                .accessibilityHidden(true)
            }
        }
    }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.stage == rhs.stage
            && lhs.token.address == rhs.token.address
            && lhs.token.name == rhs.token.name
            && lhs.token.symbol == rhs.token.symbol
            && lhs.token.imageURL == rhs.token.imageURL
            && lhs.token.launchpadName == rhs.token.launchpadName
            && lhs.token.createdAt == rhs.token.createdAt
            && lhs.token.migrated == rhs.token.migrated
            && PowderFormat.wholePercent(lhs.token.graduationPercent)
                == PowderFormat.wholePercent(rhs.token.graduationPercent)
            && PowderFormat.currency(lhs.token.priceUSD, precise: true)
                == PowderFormat.currency(rhs.token.priceUSD, precise: true)
            && PowderFormat.percent(lhs.token.change5m)
                == PowderFormat.percent(rhs.token.change5m)
            && PowderFormat.currency(lhs.token.volume24h)
                == PowderFormat.currency(rhs.token.volume24h)
            && PowderFormat.currency(lhs.token.liquidityUSD)
                == PowderFormat.currency(rhs.token.liquidityUSD)
            && PowderFormat.currency(lhs.token.marketCapUSD)
                == PowderFormat.currency(rhs.token.marketCapUSD)
    }
}

private struct CompactMetric: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.caption2, design: .monospaced, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
