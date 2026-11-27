import SwiftUI

@main
struct PowderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()
    @StateObject private var router = AppRouter(defaults: Launch.defaults)

    var body: some Scene {
        WindowGroup {
            RootView(router: router)
                .environmentObject(model)
                .environmentObject(router.wallets)
                .environmentObject(router.alerts)
                .environmentObject(router.directory)
                .environmentObject(router.liquidations)
                .environmentObject(router.triggers)
                .tint(PowderPalette.scopeBlue)
                .preferredColorScheme(router.theme.colorScheme)
                .frame(minWidth: 980, minHeight: 680)
        }
        .defaultSize(width: 1_360, height: 860)
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Go to Market or Command…") {
                    router.openPalette()
                }
                .keyboardShortcut("p", modifiers: .command)
                Button("Show All Commands") {
                    router.openPalette(commands: true)
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                Button("Ask AI…") {
                    router.openAI()
                }
                .keyboardShortcut("k", modifiers: .command)
            }

            CommandGroup(after: .toolbar) {
                Button("Markets") {
                    router.openMarkets()
                }
                .keyboardShortcut("m", modifiers: [.command, .shift])

                Button("Positions") {
                    router.openPositions()
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])

                Button("History") {
                    router.openHistory()
                }
                .keyboardShortcut("y", modifiers: [.command, .shift])

                Button("Watchlist") { router.openBoard(.watchlist) }
                Button("Alerts") { router.openBoard(.alerts) }
                Button("Liquidations") { router.openBoard(.liquidations) }

                Button("Launchpad") {
                    router.openLaunchpad()
                }
                .keyboardShortcut("l", modifiers: .command)

                Button("Next Tab") { router.step(1) }
                    .keyboardShortcut("]", modifiers: [.command, .shift])
                Button("Previous Tab") { router.step(-1) }
                    .keyboardShortcut("[", modifiers: [.command, .shift])

                Divider()

                Button("Split Right") { router.split(.horizontal) }
                    .keyboardShortcut("d", modifiers: .command)
                Button("Split Down") { router.split(.vertical) }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                Button("Equalize Pane Sizes") { router.equalize() }
                Button(router.theme == .dark ? "Light Theme" : "Dark Theme") {
                    router.setTheme(router.theme == .dark ? .light : .dark)
                }
                Button("Reset Layout") { router.resetLayout() }

                Divider()

                Button("Reload") {
                    if let market = router.activeMarket {
                        market.reconnect()
                    } else if let web = router.activeWeb {
                        web.reload()
                    } else {
                        Task { await model.refresh() }
                    }
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(router.activeMarket == nil && model.loadState == .loading)

                Divider()
            }
        }

        Settings {
            SettingsView(router: router)
                .environmentObject(model)
                .environmentObject(router.wallets)
                .environmentObject(router.alerts)
                .environmentObject(router.directory)
                .environmentObject(router.liquidations)
                .environmentObject(router.triggers)
                .preferredColorScheme(router.theme.colorScheme)
        }
    }
}

/// `swift run` launches an unbundled executable; without this it never becomes the key app,
/// and keystrokes keep going to the terminal that started it.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Every window, sheet, and menu follows the saved theme, whatever the system setting.
        NSApp.appearance = AppTheme.saved().appearance
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct RootView: View {
    @ObservedObject var router: AppRouter
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        LayoutView(node: router.root, router: router)
            .background(Term.chrome)
            .dropdownHost()
            .overlay(alignment: .top) {
                if router.isAIOpen {
                    ZStack(alignment: .top) {
                        Color.black.opacity(0.001)
                            .onTapGesture { router.closeAI() }
                        AIView(assistant: router.ai)
                            .padding(.top, 34)
                    }
                }
            }
            .overlay(alignment: .top) {
                if router.isPaletteOpen {
                    ZStack(alignment: .top) {
                        // A click outside closes it.
                        Color.black.opacity(0.001)
                            .onTapGesture { router.closePalette() }
                        PaletteView(router: router)
                            .padding(.top, 34)
                    }
                }
            }
            .task {
                router.openSettings = { openSettings() }
                router.directory.start()
                router.ai.start(router: router)
            }
            .background(WindowReader { window in
                // The title bar shares the tab bars' chrome color, as in Studio.
                window?.titlebarAppearsTransparent = true
                window?.backgroundColor = Term.chromeNS
                router.keys.window = window
                router.keys.install()
                // macOS focuses the first text field it finds (a tab's search or filter box) when the
                // window opens, which would swallow every navigation key.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { window?.makeFirstResponder(nil) }
            })
    }
}
