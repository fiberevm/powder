---
name: Powder
description: An Apple-native Solana launchpad instrument
colors:
  graphite: "#17191C"
  graphite-raised: "#22252A"
  porcelain: "#F4F3EE"
  porcelain-muted: "#A7A9AE"
  scope-blue: "#65A9FF"
  signal-green: "#61C99D"
  caution-amber: "#E8B04A"
  risk-coral: "#F27D72"
typography:
  display:
    fontFamily: "SF Pro Display, -apple-system, sans-serif"
    fontSize: "34px"
    fontWeight: 600
    lineHeight: 1.08
    letterSpacing: "-0.02em"
  body:
    fontFamily: "SF Pro Text, -apple-system, sans-serif"
    fontSize: "13px"
    fontWeight: 400
    lineHeight: 1.4
    letterSpacing: "normal"
  measurement:
    fontFamily: "SF Mono, ui-monospace, monospace"
    fontSize: "12px"
    fontWeight: 500
    lineHeight: 1.25
    letterSpacing: "-0.01em"
rounded:
  control: "8px"
  surface: "12px"
  panel: "14px"
spacing:
  xxs: "4px"
  xs: "8px"
  sm: "12px"
  md: "16px"
  lg: "24px"
  xl: "32px"
components:
  action-primary:
    backgroundColor: "{colors.scope-blue}"
    textColor: "{colors.graphite}"
    typography: "{typography.body}"
    rounded: "{rounded.control}"
    padding: "9px 14px"
  instrument-panel:
    backgroundColor: "{colors.graphite-raised}"
    textColor: "{colors.porcelain}"
    rounded: "{rounded.panel}"
    padding: "16px"
---

# Design System: Powder

## Overview

**Creative North Star: "The Instruments Room"**

Powder borrows the focus and legibility of Apple’s performance instruments: a calm graphite workspace, continuous data traces, compact readouts, and a precise blue selection signal. Information feels measured rather than promoted. Native macOS materials, toolbar behavior, split views, keyboard focus, and SF Symbols keep the app unmistakably at home on a Mac.

The design rejects both the glowing cyber-casino trading terminal and the empty lifestyle dashboard. Market density lives in aligned rows, timelines, and inspector fields instead of stacks of decorative cards.

System appearance changes the material, not the identity: dark mode uses graphite and raised graphite; light mode uses warm porcelain, porcelain-raised instruments, and a slightly deeper inspector field. Scope Blue and the signal palette are unchanged.

**Key Characteristics:**

- Continuous instrument surfaces, not tiled dashboard chrome
- Restrained color reserved for state and market meaning
- System typography for interface text; monospaced numerals only for measurements
- Calm, keyboard-aware macOS composition

## Colors

Graphite neutrals provide long-session focus while blue, green, amber, and coral behave as instrument signals.

### Primary

- **Scope Blue** (`#65A9FF`): selection, primary actions, chart trace, and keyboard focus.

### Secondary

- **Signal Green** (`#61C99D`): positive market movement and healthy live state.
- **Caution Amber** (`#E8B04A`): incomplete launch lifecycle or caution requiring attention.
- **Risk Coral** (`#F27D72`): negative movement and material risk signals.

### Neutral

- **Graphite** (`#17191C`): principal dark workspace.
- **Raised Graphite** (`#22252A`): inspector and control regions.
- **Porcelain** (`#F4F3EE`): primary text.
- **Muted Porcelain** (`#A7A9AE`): supporting labels and metadata.

**The Signal Budget Rule.** A signal color must communicate selection, market direction, lifecycle, or risk. It is never decorative.

## Typography

**Display Font:** SF Pro Display  
**Body Font:** SF Pro Text  
**Measurement Font:** SF Mono

**Character:** Native, compact, and unforced. SF Mono appears only where character alignment helps compare values, timestamps, addresses, or measurements.

### Hierarchy

- **Display** (semibold, 34 pt): token symbol and singular screen-defining moments.
- **Headline** (semibold, native title style): section and token names.
- **Title** (medium, native headline style): row emphasis and inspector groups.
- **Body** (regular, native body style): descriptions and control labels.
- **Measurement** (medium, native caption/body size): prices, percentages, volumes, addresses, and time axes.

## Layout

The app uses a native `NavigationSplitView`: a compact source list, a flexible launchpad canvas, and an optional detail inspector. The launch feed is one table instrument divided into three equal lifecycle columns—Bonding, Close to migrating, and Migrated—with independent continuous row streams and fixed headers. Token detail gives the chart the dominant horizontal span and keeps trading/risk controls in a fixed-width trailing inspector. Spacing follows 4, 8, 12, 16, 24, and 32 pt steps.

At narrow window widths the inspector becomes a sheet and secondary table columns progressively hide. Primary content never requires horizontal scrolling.

## Motion

Motion explains live market state without turning the instrument into visual noise. The token-detail workspace interpolates its focused measurements and redraws the open candle at a bounded live cadence, while the high-density launchpad updates row values in place without animating every digit. Row order stays stable under metric updates; brand-new launches lead their column, followed by lifecycle arrivals and then retained rows. Actual arrivals, removals, and lifecycle transitions use a short 160 ms opacity handoff. Subscription events remain fully live but are coalesced into three-second dashboard commits, with ranked row membership rotating gradually instead of reflowing whole columns. Native Reduce Motion removes transitions while preserving immediate values and state feedback.

## Elevation & Depth

Depth comes from native macOS materials and tonal layering. Shadows are limited to transient popovers and sheets; persistent content regions remain flat so dense values do not appear individually elevated.

## Shapes

Controls use 8 pt corners, compact content surfaces use 12 pt, and large inspector regions use 14 pt. Pills are reserved for short lifecycle or filter states. Borders are hairline separators, never double-stacked with shadows.

## Components

### Buttons

- **Shape:** Native control silhouette with 8 pt corners.
- **Primary:** Scope Blue fill, Graphite label, semibold system text.
- **State:** Native hover, pressed, disabled, and focus behavior; destructive actions use Risk Coral only when consequence is real.

### Chips

- **Style:** Compact native capsule for mutually exclusive timeframe, launchpad, or lifecycle filters.
- **State:** Selected chips use a restrained blue tint; unselected chips remain tonal.

### Cards / Containers

- **Corner Style:** 12–14 pt only when content is meaningfully grouped.
- **Background:** Graphite or Raised Graphite; large chart regions remain continuous.
- **Shadow Strategy:** No persistent card shadows.
- **Border:** Hairline semantic separator when adjacent tones are insufficient.

### Inputs / Fields

- **Style:** Native search and text fields with system focus rings.
- **Error / Disabled:** State appears in both text and color.

### Navigation

Native source-list navigation, toolbar placement, split-view behavior, searchable token list, and keyboard commands. Selected rows receive one full-width tonal highlight rather than a decorative accent stripe.

### Market Trace

The token detail instrument defaults to aggregate OHLC candlesticks with a nine-bar simple moving average and a synchronized volume rail. Traders can switch to a continuous close trace and inspect any bar with linked price/volume crosshairs and a stable OHLC readout. Time ranges span 1H, 6H, 24H, 7D, and 30D using bounded Codex resolutions; live status and data provenance stay visible beside the title.

One continuous path with restrained area tint, sparse axes, a crosshair on hover, and a compact floating measurement. Positive and negative intervals use semantic signal colors without neon glow.

## Do's and Don'ts

### Do:

- **Do** use system controls, SF Symbols, semantic labels, and native focus behavior.
- **Do** align numeric columns and reserve SF Mono for measurable values.
- **Do** make sample versus live Codex data explicit.
- **Do** let one chart or feed surface dominate each screen.

### Don't:

- **Don't** use decorative glow, gradient text, or faux glass panels.
- **Don't** tile the screen into same-size metric cards.
- **Don't** use signal colors without a state meaning.
- **Don't** present a trade button as executable before wallet routing exists.
