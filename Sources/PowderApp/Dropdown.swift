import SwiftUI

/// One row of a `TermDropdown`.
struct DropdownItem: Identifiable {
    let id: String
    let title: String
    var detail = ""
    var isSelected = false
    var isDisabled = false
    /// Draws a hairline above this row.
    var startsSection = false
    let action: @MainActor () -> Void

    init(
        _ title: String, id: String? = nil, detail: String = "", isSelected: Bool = false,
        isDisabled: Bool = false, startsSection: Bool = false, action: @escaping @MainActor () -> Void
    ) {
        self.id = id ?? title
        self.title = title
        self.detail = detail
        self.isSelected = isSelected
        self.isDisabled = isDisabled
        self.startsSection = startsSection
        self.action = action
    }
}

/// What an open dropdown asks its host to draw.
struct DropdownPresentation {
    let anchor: Anchor<CGRect>
    let items: [DropdownItem]
    let minWidth: CGFloat
    let close: @MainActor () -> Void
}

private struct DropdownKey: PreferenceKey {
    static let defaultValue: DropdownPresentation? = nil
    static func reduce(value: inout DropdownPresentation?, nextValue: () -> DropdownPresentation?) {
        value = value ?? nextValue()
    }
}

/// The open dropdown, so Esc can close it from the key monitor.
@MainActor
enum DropdownCenter {
    static var dismiss: (() -> Void)?
}

/// The app's own dropdown: a themed list that opens under its label, in place of the macOS menu.
/// The list is drawn by the nearest `dropdownHost()`, so it is never clipped by the panel it sits in.
struct TermDropdown<Label: View>: View {
    let items: [DropdownItem]
    var minWidth: CGFloat = 140
    @ViewBuilder let label: (_ isOpen: Bool) -> Label

    @State private var isOpen = false

    var body: some View {
        Button {
            isOpen.toggle()
        } label: {
            label(isOpen).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .anchorPreference(key: DropdownKey.self, value: .bounds) { anchor in
            isOpen ? DropdownPresentation(anchor: anchor, items: items, minWidth: minWidth, close: { isOpen = false }) : nil
        }
        .onChange(of: isOpen) { _, open in
            DropdownCenter.dismiss = open ? { isOpen = false } : nil
        }
        .onDisappear {
            if isOpen { DropdownCenter.dismiss = nil }
        }
    }
}

extension TermDropdown where Label == DropdownLabel {
    /// The standard label: the current value and a chevron.
    init(_ title: String, items: [DropdownItem], minWidth: CGFloat = 140) {
        self.init(items: items, minWidth: minWidth) { isOpen in
            DropdownLabel(title: title, isOpen: isOpen)
        }
    }
}

struct DropdownLabel: View {
    let title: String
    let isOpen: Bool

    var body: some View {
        HStack(spacing: 5) {
            Text(title)
                .foregroundStyle(isOpen ? Term.accent : Term.foreground)
            Text(isOpen ? "▴" : "▾")
                .font(Term.font(8))
                .foregroundStyle(isOpen ? Term.accent : Color.secondary)
        }
        .font(Term.font(11))
        .lineLimit(1)
        .padding(.horizontal, 7)
        .frame(height: 20)
        .background(isOpen ? Term.accent.opacity(0.12) : Term.faint)
        .overlay(Rectangle().stroke(isOpen ? Term.accent : Term.rule, lineWidth: 1))
    }
}

extension View {
    /// Draws the dropdowns opened anywhere inside this view, above everything else in it.
    func dropdownHost() -> some View {
        overlayPreferenceValue(DropdownKey.self) { presentation in
            GeometryReader { proxy in
                if let presentation {
                    let anchor = proxy[presentation.anchor]
                    let size = DropdownList.size(for: presentation)
                    // Open downward unless that would run off the bottom; keep the list inside the window.
                    let opensUp = anchor.maxY + size.height + 6 > proxy.size.height && anchor.minY > size.height
                    let x = min(max(anchor.minX, 4), max(proxy.size.width - size.width - 4, 4))
                    let y = opensUp ? anchor.minY - size.height - 2 : anchor.maxY + 2

                    ZStack(alignment: .topLeading) {
                        Color.black.opacity(0.001)
                            .onTapGesture { presentation.close() }
                        DropdownList(presentation: presentation)
                            .frame(width: size.width)
                            .offset(x: x, y: y)
                    }
                }
            }
        }
    }
}

private struct DropdownList: View {
    let presentation: DropdownPresentation

    private static let rowHeight: CGFloat = 24
    @State private var hovered: String?

    /// Sized from the text, since the list is positioned before it is laid out.
    static func size(for presentation: DropdownPresentation) -> CGSize {
        let longest = presentation.items.map { $0.title.count + ($0.detail.isEmpty ? 0 : $0.detail.count + 3) }.max() ?? 0
        let width = max(presentation.minWidth, CGFloat(longest) * 7 + 44)
        let dividers = presentation.items.filter(\.startsSection).count
        return CGSize(width: min(width, 360), height: min(CGFloat(presentation.items.count) * rowHeight + CGFloat(dividers) * 9 + 8, 420))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(presentation.items) { item in
                    if item.startsSection {
                        TermRule().padding(.vertical, 4)
                    }
                    HStack(spacing: 8) {
                        Text(item.isSelected ? "●" : " ")
                            .font(Term.font(7))
                            .foregroundStyle(Term.accent)
                            .frame(width: 8)
                        Text(item.title)
                            .foregroundStyle(item.isDisabled ? Color.secondary : (item.isSelected ? Term.accent : Term.foreground))
                        Spacer(minLength: 8)
                        if !item.detail.isEmpty {
                            Text(item.detail).foregroundStyle(.secondary)
                        }
                    }
                    .font(Term.font(11.5))
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .frame(height: Self.rowHeight)
                    .background(hovered == item.id && !item.isDisabled ? Color(dark: 0x37373D, light: 0xE4E6F1) : .clear)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { hovered = item.id } else if hovered == item.id { hovered = nil }
                    }
                    .onTapGesture {
                        guard !item.isDisabled else { return }
                        presentation.close()
                        item.action()
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .frame(height: Self.size(for: presentation).height)
        .background(Term.widget)
        .overlay(Rectangle().stroke(Term.rule, lineWidth: 1))
        .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
    }
}

extension View {
    /// Opens the themed list under this view, for menus that have no button of their own (a table row's options).
    func termMenu(isOpen: Bool, items: [DropdownItem], minWidth: CGFloat = 220, close: @escaping @MainActor () -> Void) -> some View {
        anchorPreference(key: DropdownKey.self, value: .bounds) { anchor in
            isOpen ? DropdownPresentation(anchor: anchor, items: items, minWidth: minWidth, close: close) : nil
        }
    }
}
