import AppKit
import SwiftUI

// MARK: - Controls

/// A text field in the terminal's own style: flat, hairline border, gold when focused.
struct TermTextField: View {
    let placeholder: String
    @Binding var text: String
    var isSecure = false
    var width: CGFloat?

    @FocusState private var isFocused: Bool

    var body: some View {
        Group {
            if isSecure {
                SecureField(placeholder, text: $text)
            } else {
                TextField(placeholder, text: $text)
            }
        }
        .textFieldStyle(.plain)
        .font(Term.font(12))
        .autocorrectionDisabled()
        .focused($isFocused)
        .padding(.horizontal, 8)
        .frame(width: width, height: 26)
        .frame(maxWidth: width == nil ? .infinity : nil)
        .background(Term.background)
        .overlay(Rectangle().stroke(isFocused ? Term.accent : Term.rule, lineWidth: 1))
    }
}

/// A number typed as text; it is written back only while it parses and is in range.
struct TermNumberField: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1_000_000_000
    var width: CGFloat = 90

    @State private var text = ""

    var body: some View {
        TermTextField(placeholder: "0", text: $text, width: width)
            .onAppear { text = HLWire.number(value) }
            .onChange(of: text) { _, new in
                if let parsed = Double(new.replacingOccurrences(of: ",", with: "")), range.contains(parsed), parsed != value {
                    value = parsed
                }
            }
            .onChange(of: value) { _, new in
                if Double(text.replacingOccurrences(of: ",", with: "")) != new { text = HLWire.number(new) }
            }
    }
}

struct TermButton: View {
    enum Kind { case plain, primary, danger }

    let title: String
    var kind = Kind.plain
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    init(_ title: String, kind: Kind = .plain, action: @escaping () -> Void) {
        self.title = title
        self.kind = kind
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Term.font(11, .semibold))
                .foregroundStyle(foreground)
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(background)
                .overlay(Rectangle().stroke(border, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.4)
        .onHover { isHovering = $0 }
    }

    private var foreground: Color {
        switch kind {
        case .plain: Term.foreground
        case .primary: PowderPalette.graphite
        case .danger: PowderPalette.riskCoral
        }
    }

    private var background: Color {
        switch kind {
        case .plain: isHovering ? Color.primary.opacity(0.08) : Term.faint
        case .primary: Term.accent.opacity(isHovering ? 0.85 : 1)
        case .danger: PowderPalette.riskCoral.opacity(isHovering ? 0.16 : 0.06)
        }
    }

    private var border: Color {
        switch kind {
        case .plain: Term.rule
        case .primary: Term.accent
        case .danger: PowderPalette.riskCoral.opacity(0.6)
        }
    }
}

/// A checkbox drawn as the terminal draws them: a filled or empty square.
struct TermCheck: View {
    let label: String
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(spacing: 8) {
                Text(isOn ? "■" : "□")
                    .foregroundStyle(isOn ? Term.accent : Color.secondary)
                Text(label)
            }
            .font(Term.font(12))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct TermStepper: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    var suffix = ""

    var body: some View {
        HStack(spacing: 0) {
            step("−", by: -1)
            Text("\(value)\(suffix)")
                .font(Term.font(12, .semibold))
                .frame(width: 52, height: 24)
                .background(Term.background)
            step("+", by: 1)
        }
        .overlay(Rectangle().stroke(Term.rule, lineWidth: 1))
    }

    private func step(_ symbol: String, by delta: Int) -> some View {
        Button {
            value = min(max(value + delta, range.lowerBound), range.upperBound)
        } label: {
            Text(symbol)
                .font(Term.font(13, .semibold))
                .frame(width: 26, height: 24)
                .background(Term.faint)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Settings window

/// ⌘, : settings in the terminal's own style, with the sections in a sidebar on the left.
struct SettingsView: View {
    @ObservedObject var router: AppRouter

    private enum Section: String, CaseIterable {
        case wallets = "Wallets"
        case appearance = "Appearance"
        case data = "Data"

        var icon: String {
            switch self {
            case .wallets: "wallet.pass"
            case .appearance: "circle.lefthalf.filled"
            case .data: "point.3.connected.trianglepath.dotted"
            }
        }
    }

    @State private var section = Section.wallets

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Text("SETTINGS")
                    .font(Term.font(10.5, .bold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .frame(height: 34)
                ForEach(Section.allCases, id: \.self) { item in
                    let isSelected = item == section
                    HStack(spacing: 9) {
                        Image(systemName: item.icon)
                            .font(.system(size: 11))
                            .frame(width: 16)
                        Text(item.rawValue)
                            .font(.system(size: 12.5, weight: isSelected ? .semibold : .regular))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(isSelected ? Term.foreground : Color.secondary)
                    .padding(.horizontal, 14)
                    .frame(height: 30)
                    .background(isSelected ? Term.background : .clear)
                    .overlay(alignment: .leading) {
                        if isSelected { Term.accent.frame(width: 2) }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { section = item }
                }
                Spacer(minLength: 0)
            }
            .frame(width: 168)
            .background(Term.chrome)

            TermRule(vertical: true)

            Group {
                switch section {
                case .wallets: WalletSettingsPane()
                case .appearance: AppearancePane(router: router)
                case .data: CodexSettingsPane()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Term.background)
        }
        .foregroundStyle(Term.foreground)
        .frame(width: 880, height: 560)
        .background(Term.chrome)
        .dropdownHost()
        .background(WindowReader { window in
            window?.titlebarAppearsTransparent = true
            window?.backgroundColor = Term.chromeNS
            window?.title = "Settings"
        })
    }
}

/// A label on the left, the control (and an optional note under it) on the right.
private struct SettingRow<Content: View>: View {
    let label: String
    var note = ""
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Text(label.uppercased())
                .font(Term.font(10.5, .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 128, alignment: .leading)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 6) {
                content
                if !note.isEmpty {
                    Text(note)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

private struct PaneTitle: View {
    let title: String
    var subtitle = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(Term.font(15, .bold))
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Wallets

private struct WalletSettingsPane: View {
    @EnvironmentObject private var wallets: WalletProvider

    @State private var editingID: UUID?
    @State private var isImporting = false
    @State private var importName = ""
    @State private var importKey = ""
    @State private var revealedKey: String?
    @State private var isConfirmingDelete = false
    @State private var errorMessage: String?

    private var editing: Wallet? {
        (editingID ?? wallets.selectedID).flatMap(wallets.wallet) ?? wallets.wallets.first
    }

    var body: some View {
        HStack(spacing: 0) {
            list
                .frame(width: 210)
            TermRule(vertical: true)
            Group {
                if isImporting {
                    importForm
                } else if let wallet = editing {
                    detail(wallet)
                } else {
                    emptyState
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .onChange(of: editing?.id) {
            revealedKey = nil
            isConfirmingDelete = false
        }
    }

    private var list: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(wallets.wallets.count) WALLET\(wallets.wallets.count == 1 ? "" : "S")")
                    .font(Term.font(10.5, .bold))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            TermRule()

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(wallets.wallets) { wallet in
                        let isEditing = wallet.id == editing?.id && !isImporting
                        HStack(spacing: 8) {
                            Text(wallet.id == wallets.selectedID ? "●" : " ")
                                .font(Term.font(7))
                                .foregroundStyle(Term.accent)
                                .frame(width: 8)
                                .help("The wallet the order ticket trades with")
                            VStack(alignment: .leading, spacing: 3) {
                                Text(wallet.name)
                                    .font(.system(size: 12.5, weight: .medium))
                                Text(wallet.shortAddress + (wallet.isAgent ? " · API" : ""))
                                    .font(Term.font(10.5))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .lineLimit(1)
                        .padding(.horizontal, 12)
                        .frame(height: 44)
                        .background(isEditing ? Term.accent.opacity(0.14) : .clear)
                        .overlay(alignment: .leading) {
                            if isEditing { Term.accent.frame(width: 2) }
                        }
                        .overlay(alignment: .bottom) { TermRule() }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            isImporting = false
                            errorMessage = nil
                            editingID = wallet.id
                        }
                    }
                }
            }

            TermRule()
            HStack(spacing: 8) {
                TermButton("+ NEW", kind: .primary) {
                    isImporting = false
                    perform { editingID = try wallets.create().id }
                }
                TermButton("IMPORT") {
                    importName = ""
                    importKey = ""
                    errorMessage = nil
                    isImporting = true
                }
                Spacer(minLength: 0)
            }
            .padding(10)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 14) {
            PaneTitle(
                title: "No wallets yet",
                subtitle: "Create a new wallet to generate a key on this Mac, or import a private key you already have. Keys are stored in your macOS Keychain and never leave this computer; only signed orders are sent."
            )
            if let errorMessage { errorText(errorMessage) }
        }
        .padding(24)
    }

    private var importForm: some View {
        VStack(alignment: .leading, spacing: 16) {
            PaneTitle(
                title: "Import a wallet",
                subtitle: "To trade an existing Hyperliquid account without exposing its main key, create an API wallet at app.hyperliquid.xyz/API, import that key here, then enter the main account's address under “Trades for account”. An API wallet can trade but cannot withdraw."
            )
            SettingRow(label: "Name") {
                TermTextField(placeholder: "Wallet \(wallets.wallets.count + 1)", text: $importName)
            }
            SettingRow(label: "Private key") {
                TermTextField(placeholder: "64 hex characters, with or without 0x", text: $importKey, isSecure: true)
            }
            if let errorMessage { errorText(errorMessage) }
            HStack(spacing: 8) {
                TermButton("IMPORT", kind: .primary) {
                    perform {
                        editingID = try wallets.importWallet(name: importName, privateKey: importKey).id
                        importKey = ""
                        isImporting = false
                    }
                }
                .disabled(importKey.trimmingCharacters(in: .whitespaces).isEmpty)
                TermButton("CANCEL") { isImporting = false }
            }
        }
        .padding(24)
    }

    private func detail(_ original: Wallet) -> some View {
        let wallet = wallets.wallet(original.id) ?? original
        // Each control writes straight back to the provider, which saves it.
        func binding<Value>(_ keyPath: WritableKeyPath<Wallet, Value>) -> Binding<Value> {
            Binding(
                get: { (wallets.wallet(wallet.id) ?? wallet)[keyPath: keyPath] },
                set: { value in
                    var changed = wallets.wallet(wallet.id) ?? wallet
                    changed[keyPath: keyPath] = value
                    wallets.update(changed)
                }
            )
        }

        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    PaneTitle(title: wallet.name)
                    Spacer()
                    if wallet.id == wallets.selectedID {
                        InverseLabel(text: "IN USE")
                    } else {
                        TermButton("USE IN ORDER TICKET") { wallets.selectedID = wallet.id }
                    }
                }

                SettingRow(label: "Name") {
                    TermTextField(placeholder: "Name", text: binding(\.name))
                }

                SettingRow(label: "Address") {
                    HStack(spacing: 8) {
                        Text(wallet.address)
                            .font(Term.font(11.5))
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        TermButton("COPY") { copy(wallet.address) }
                    }
                }

                SettingRow(label: "Trades for account", note: accountNote(wallet)) {
                    TermTextField(placeholder: "empty = this wallet's own account", text: binding(\.accountAddress))
                }

                TermRule()

                SettingRow(label: "Leverage", note: "Set on a market before this wallet's first order there; capped at each market's maximum.") {
                    HStack(spacing: 10) {
                        TermStepper(value: binding(\.settings.leverage), range: 1...50, suffix: "x")
                        TermDropdown(
                            wallet.settings.isCross ? "Cross margin" : "Isolated margin",
                            items: [
                                DropdownItem("Cross margin", isSelected: wallet.settings.isCross) {
                                    binding(\.settings.isCross).wrappedValue = true
                                },
                                DropdownItem("Isolated margin", isSelected: !wallet.settings.isCross) {
                                    binding(\.settings.isCross).wrappedValue = false
                                },
                            ]
                        )
                    }
                }

                SettingRow(label: "Default size", note: "What the order ticket's size starts at, in USD.") {
                    HStack(spacing: 6) {
                        Text("$").font(Term.font(12)).foregroundStyle(.secondary)
                        TermNumberField(value: binding(\.settings.defaultSizeUSD))
                    }
                }

                SettingRow(label: "Market slippage", note: "The furthest from the mid price a market order may fill.") {
                    HStack(spacing: 6) {
                        TermNumberField(value: binding(\.settings.slippagePercent), range: 0.01...50, width: 70)
                        Text("%").font(Term.font(12)).foregroundStyle(.secondary)
                    }
                }

                TermRule()

                SettingRow(
                    label: "Private key",
                    note: "Back this up. It is the only copy: if the key is lost, so is access to the funds, and anyone who has it controls them."
                ) {
                    if let revealedKey {
                        Text(revealedKey)
                            .font(Term.font(11))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Term.chrome)
                            .overlay(Rectangle().stroke(Term.rule, lineWidth: 1))
                        HStack(spacing: 8) {
                            TermButton("COPY") { copy(revealedKey) }
                            TermButton("HIDE") { self.revealedKey = nil }
                        }
                    } else {
                        TermButton("REVEAL PRIVATE KEY") {
                            revealedKey = wallets.exportPrivateKey(wallet.id)
                            if revealedKey == nil { errorMessage = WalletError.missingKey.localizedDescription }
                        }
                    }
                }

                if let errorMessage { errorText(errorMessage) }

                SettingRow(
                    label: "Delete",
                    note: isConfirmingDelete
                        ? "The private key is removed from the Keychain and cannot be recovered. Funds stay on Hyperliquid, reachable only with a backup of the key."
                        : ""
                ) {
                    if isConfirmingDelete {
                        HStack(spacing: 8) {
                            TermButton("DELETE WALLET AND ITS KEY", kind: .danger) {
                                wallets.delete(wallet.id)
                                editingID = nil
                                isConfirmingDelete = false
                            }
                            TermButton("KEEP") { isConfirmingDelete = false }
                        }
                    } else {
                        TermButton("DELETE WALLET…", kind: .danger) { isConfirmingDelete = true }
                    }
                }
            }
            .padding(24)
        }
    }

    private func accountNote(_ wallet: Wallet) -> String {
        let text = wallet.accountAddress.trimmingCharacters(in: .whitespaces)
        if text.isEmpty { return "Set this when the key is an API wallet approved by another Hyperliquid account: orders then trade that account." }
        if !Wallet.isAddress(text.lowercased()) { return "Not a valid address yet (0x followed by 40 hex characters); the wallet's own account is used until it is." }
        return "Orders signed by this key trade \(Wallet.shorten(text.lowercased())). That account must have approved this key as an API wallet."
    }

    private func errorText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(PowderPalette.riskCoral)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func perform(_ work: () throws -> Void) {
        do {
            errorMessage = nil
            try work()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Appearance

private struct AppearancePane: View {
    @ObservedObject var router: AppRouter

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PaneTitle(title: "Appearance", subtitle: "Also in the palette: ⌘P, then “light theme” or “dark theme”.")
            SettingRow(label: "Theme") {
                HStack(spacing: 0) {
                    ForEach(AppTheme.allCases, id: \.self) { theme in
                        Button {
                            router.setTheme(theme)
                        } label: {
                            InverseLabel(text: theme.title.uppercased(), isActive: router.theme == theme)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .overlay(Rectangle().stroke(Term.rule, lineWidth: 1))
            }
        }
        .padding(24)
    }
}

// MARK: - Codex data

private struct CodexSettingsPane: View {
    @EnvironmentObject private var model: AppModel

    @State private var apiKey = ""
    @State private var statusMessage: String?
    @State private var isSaving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PaneTitle(title: "Codex data", subtitle: "Solana market and launchpad data for the Launchpad tab.")

            SettingRow(
                label: "API key",
                note: "Stored in your macOS Keychain. Powder sends it only to graph.codex.io using the raw Authorization header required by Codex."
            ) {
                TermTextField(placeholder: "Paste your Codex API key", text: $apiKey, isSecure: true)
            }

            if let statusMessage {
                Text(statusMessage)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                TermButton(isSaving ? "LOADING…" : "SAVE & LOAD", kind: .primary) { saveAndLoad() }
                    .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
                if model.hasAPIKey {
                    TermButton("REMOVE KEY", kind: .danger) {
                        model.removeAPIKey()
                        apiKey = ""
                        statusMessage = "The key was removed. Powder is using demo data."
                    }
                }
            }
        }
        .padding(24)
        .onAppear {
            if model.hasAPIKey {
                statusMessage = "A Codex API key is already stored. Enter a new value only to replace it."
            }
        }
    }

    private func saveAndLoad() {
        isSaving = true
        do {
            try model.saveAPIKey(apiKey)
            Task {
                await model.refresh()
                isSaving = false
                statusMessage = model.dataMode == .live
                    ? "Live Codex data is loading in the Launchpad tab."
                    : model.notice ?? "Powder could not load live data."
            }
        } catch {
            isSaving = false
            statusMessage = error.localizedDescription
        }
    }
}
