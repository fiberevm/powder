# Product

<!-- impeccable:product-schema 1 -->

## Platform

adaptive

## Users

**Working assumption:** Active Solana token traders who spend long sessions at a Mac and want to discover new launchpad tokens without using a browser-first trading dashboard.

## Product Purpose

Provide an Apple-native place to discover Solana launchpad tokens, assess market activity and token risk, and move from a launch feed into a focused token workspace. Success means a trader can identify a token worth investigating and understand its market state in seconds.

## Positioning

**Working assumption:** A trading terminal composed for the Mac—keyboard-aware, information-dense, calm, and legible—rather than a web dashboard wrapped in a desktop window.

## Operating Context

- Used on macOS during active token discovery and market monitoring.
- Launchpad feed → token detail is the primary first-release workflow.
- Codex (`https://graph.codex.io/graphql`) is the sole market-data source.
- Solana uses Codex network ID `1399811149`.

## Capabilities and Constraints

- Native SwiftUI macOS application.
- Launchpad discovery uses Codex `filterTokens` across Solana launchpads, then keeps the set and its values current with `onFilterTokensUpdated` and `onLaunchpadTokenEventBatch`.
- The launch surface groups tokens into Bonding, Close to migrating (80%+ while awaiting migration), and Migrated columns.
- The live dashboard keeps at most 30 current tokens per lifecycle column and coalesces subscription events into three-second render commits while preserving the full Codex WebSocket connection.
- Token detail loads bounded aggregate OHLCV history from `getTokenBars`, streams the open candle with `onTokenBarsUpdated`, and streams holder totals with `onHoldersUpdated`. The chart provides candlestick and close-line modes, volume, SMA 9, crosshair inspection, and 1H–30D ranges.
- A local sample-data fallback keeps the first-run experience useful without credentials.
- The Codex API key is supplied at runtime and is never committed.
- Codex WebSocket subscriptions require a Growth or Enterprise plan; when unavailable, the last successful HTTP snapshot remains visible.
- **Open decision:** wallet connection, signing, routing, and transaction execution are outside this first release.
- **Open decision:** iPhone and iPad surfaces may follow, but the current deliverable targets macOS.

## Evidence on Hand

No customer claims, performance benchmarks, token endorsements, or proprietary assets are available and none should be fabricated. Sample token content is illustrative and must be labeled as demo data in the interface.

## Product Principles

- Lead with market state, not promotional copy.
- Make risk and data provenance visible.
- Preserve native Apple navigation, keyboard behavior, accessibility, and system appearance.
- Let dense information remain calm through hierarchy and rhythm.
- Degrade gracefully when live credentials or network access are unavailable.

## Accessibility & Inclusion

Support VoiceOver labels, keyboard navigation, Reduce Motion, semantic system colors, and legible contrast in both system appearances.
