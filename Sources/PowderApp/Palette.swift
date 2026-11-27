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
    var section: String?
    let run: @MainActor () -> Void
}

enum PaletteSearch {
    /// Title-prefix hits lead, then substring hits, then scattered-letter matches; order is kept within each.
    static func filter(_ items: [PaletteItem], by query: String) -> [PaletteItem] {
        let query = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return items }
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
        return prefix + exact + fuzzy
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
                if item.icon.isEmpty {
                    Color.clear
                } else {
                    Image(systemName: item.icon)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 14)

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
