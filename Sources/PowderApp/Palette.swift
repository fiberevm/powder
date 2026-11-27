import SwiftUI

/// One row of the ⌘P palette: a market, the launchpad, or a command.
struct PaletteItem: Identifiable {
    let id: String
    let title: String
    var subtitle = ""
    var detail = ""
    /// 24h change, shown coloured after the price on market rows.
    var change: Double?
    var icon = ""
    /// Where the market's logo may be found, tried in order. The icon shows until one loads.
    var logos: [URL] = []
    /// 24h volume in dollars, for ranking markets from different venues together.
    var volume = 0.0
    var section: String?
    let run: @MainActor () -> Void
}

/// Coin and token logos for the palette, fetched once and kept for the session.
@MainActor
final class LogoStore: ObservableObject {
    static let shared = LogoStore()

    @Published private var images: [URL: NSImage] = [:]
    private var requested: Set<URL> = []

    /// The logo if it has loaded; otherwise starts loading it and returns nil.
    func image(for candidates: [URL]) -> NSImage? {
        guard let key = candidates.first else { return nil }
        if let image = images[key] { return image }
        guard requested.insert(key).inserted else { return nil }
        Task {
            for url in candidates {
                guard let (data, response) = try? await URLSession.shared.data(from: url),
                      (response as? HTTPURLResponse)?.statusCode == 200,
                      // A missing logo can come back as a web page; only an image counts.
                      response.mimeType?.hasPrefix("image/") == true,
                      let image = NSImage(data: data), image.isValid else { continue }
                images[key] = image
                return
            }
        }
        return nil
    }

    /// Hyperliquid's own icon for a perp. "kPEPE" and the like are drawn with the base coin's.
    static func perp(_ coin: String) -> [URL] {
        var names = [coin]
        if coin.hasPrefix("k"), coin.count > 1 { names.append(String(coin.dropFirst())) }
        return names.compactMap { URL(string: "https://app.hyperliquid.xyz/coins/\($0).svg") }
    }
}

enum PaletteSearch {
    /// Title-prefix hits lead, then substring hits, then scattered-letter matches; order is kept within each.
    static func filter(_ items: [PaletteItem], by query: String) -> [PaletteItem] {
        let matched = matches(items, by: query)
        return matched.prefix + matched.exact + matched.fuzzy
    }

    static func matches(_ items: [PaletteItem], by query: String) -> (prefix: [PaletteItem], exact: [PaletteItem], fuzzy: [PaletteItem]) {
        let query = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return (items, [], []) }
        var prefix: [PaletteItem] = [], exact: [PaletteItem] = [], fuzzy: [PaletteItem] = []
        for item in items {
            let title = item.title.lowercased()
            let hay = title + " " + item.subtitle.lowercased()
            if title.hasPrefix(query) {
                prefix.append(item)
            } else if hay.contains(query) {
                exact.append(item)
            } else if isSubsequence(query, of: hay) {
                fuzzy.append(item)
            }
        }
        return (prefix, exact, fuzzy)
    }

    private static func isSubsequence(_ needle: String, of hay: String) -> Bool {
        var iterator = hay.makeIterator()
        for character in needle where character != " " {
            var found = false
            while let next = iterator.next() {
                if next == character { found = true; break }
            }
            if !found { return false }
        }
        return true
    }
}

/// Studio's quick pick: an accent-outlined field over a flat list, floating at the top of the window.
struct PaletteView: View {
    @ObservedObject var router: AppRouter
    @ObservedObject private var logos = LogoStore.shared
    @FocusState private var isFocused: Bool

    private static let rowHeight: CGFloat = 26
    private static let listSelection = Color(dark: 0x37373D, light: 0xE4E6F1)

    var body: some View {
        let items = router.paletteItems

        VStack(spacing: 0) {
            TextField("Search markets, or type > for commands", text: $router.paletteQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .autocorrectionDisabled()
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(Term.background)
                .overlay(Rectangle().stroke(Term.accent, lineWidth: 1))
                .padding(6)
                .focused($isFocused)

            if items.isEmpty {
                Text("No matching results")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .frame(height: Self.rowHeight)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                row(item, isSelected: index == router.paletteSelection)
                                    .id(item.id)
                                    .onTapGesture { router.runPalette(at: index) }
                            }
                        }
                    }
                    .frame(height: min(CGFloat(items.count), 14) * Self.rowHeight)
                    .onChange(of: router.paletteSelection) { _, selection in
                        if items.indices.contains(selection) { proxy.scrollTo(items[selection].id) }
                    }
                }
            }
        }
        .padding(.bottom, 4)
        .frame(width: 620)
        .background(Term.chrome)
        .overlay(Rectangle().stroke(Term.rule, lineWidth: 1))
        .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
        .foregroundStyle(Term.foreground)
        .onAppear { isFocused = true }
    }

    private func row(_ item: PaletteItem, isSelected: Bool) -> some View {
        HStack(spacing: 8) {
            Group {
                if let logo = logos.image(for: item.logos) {
                    Image(nsImage: logo)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 16, height: 16)
                        .clipShape(Circle())
                } else if item.icon.isEmpty {
                    Color.clear
                } else {
                    Image(systemName: item.icon)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 16)

            Text(item.title)
                .font(.system(size: 13))
                .lineLimit(1)
            if !item.subtitle.isEmpty {
                Text(item.subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if let section = item.section {
                Text(section)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            if !item.detail.isEmpty {
                Text(item.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if let change = item.change {
                Text(HLFormat.percent(change))
                    .font(.system(size: 11))
                    .foregroundStyle(PowderPalette.market(change))
                    .monospacedDigit()
                    .frame(width: 58, alignment: .trailing)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: Self.rowHeight)
        .background(isSelected ? Self.listSelection : .clear)
        .contentShape(Rectangle())
    }
}
