import AppKit
import SwiftUI
import WebKit

// MARK: - Theme

/// Studio's "Dark Modern" chrome (and "Light Modern" for the light theme): flat panes, a slightly
/// different tab-bar tone, hairline borders, one gold accent. Every colour carries both values and
/// follows the app's appearance, so switching theme needs no per-view work.
enum Term {
    static let rowHeight: CGFloat = 18
    static let tabBarHeight: CGFloat = 35

    /// Pane content and the selected tab.
    static let background = Color(dark: 0x1F1F1F, light: 0xFFFFFF)
    /// Tab bars, status bars, and the title bar.
    static let chromeNS = NSColor.adaptive(dark: 0x181818, light: 0xF3F3F3)
    static let chrome = Color(nsColor: chromeNS)
    /// Floating surfaces: the market picker and key list.
    static let widget = Color(dark: 0x222222, light: 0xF8F8F8)
    static let foreground = Color(dark: 0xCCCCCC, light: 0x3B3B3B)
    static let rule = Color(dark: 0x2B2B2B, light: 0xE0E0E0)
    /// Divider between split panes, a step brighter than `rule` so the grab line is findable.
    static let paneDivider = Color(dark: 0x424242, light: 0xC4C4C4)
    /// Fills: the active tab's top line, selected rows, reverse-video labels.
    /// Gold; deeper on white so it still reads as text.
    static let accent = Color(dark: 0xF0B429, light: 0xB07D00)
    static let faint = Color.primary.opacity(0.04)

    static func font(_ size: CGFloat = 12, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }

    /// One colour with a value per appearance.
    static func adaptive(dark: UInt32, light: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(hex: dark) : NSColor(hex: light)
        }
    }
}

enum AppTheme: String, CaseIterable {
    case dark, light

    var title: String { self == .dark ? "Dark" : "Light" }
    var appearance: NSAppearance? { NSAppearance(named: self == .dark ? .darkAqua : .aqua) }
    var colorScheme: ColorScheme { self == .dark ? .dark : .light }

    static let key = "theme"
    static func saved(in defaults: UserDefaults = .standard) -> AppTheme {
        defaults.string(forKey: key).flatMap(AppTheme.init) ?? .dark
    }
}

extension Color {
    init(dark: UInt32, light: UInt32) {
        self.init(nsColor: .adaptive(dark: dark, light: light))
    }

    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

/// A one-point separator in the chrome border color.
struct TermRule: View {
    var vertical = false

    var body: some View {
        Rectangle()
            .fill(Term.rule)
            .frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
    }
}

/// Reverse-video label, the terminal's selection idiom.
struct InverseLabel: View {
    let text: String
    var isActive = true
    var color: Color = Term.accent
    var textColor: Color = PowderPalette.graphite

    var body: some View {
        Text(text)
            .font(Term.font(11, isActive ? .bold : .regular))
            .foregroundStyle(isActive ? textColor : Color.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(isActive ? color : .clear)
    }
}

// MARK: - Keyboard

struct KeyPress: Sendable {
    let keyCode: UInt16
    let characters: String
    let command: Bool
    let control: Bool
    let option: Bool
    let shift: Bool
}

enum KeyCode {
    static let `return`: UInt16 = 36
    static let enter: UInt16 = 76
    static let escape: UInt16 = 53
    static let delete: UInt16 = 51
    static let tab: UInt16 = 48
    static let left: UInt16 = 123
    static let right: UInt16 = 124
    static let down: UInt16 = 125
    static let up: UInt16 = 126
}

/// Sees key-downs for the main window before the responder chain, so navigation never depends on
/// which SwiftUI view happens to hold focus.
@MainActor
final class KeyMonitor {
    /// Returns `true` to consume the key. `isTyping` is set while a text field is being edited.
    var handler: ((KeyPress, _ isTyping: Bool) -> Bool)?
    weak var window: NSWindow?

    private var token: Any?
    private var clickToken: Any?

    func install() {
        installClickMonitor()
        guard token == nil else { return }
        token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let flags = event.modifierFlags
            let key = KeyPress(
                keyCode: event.keyCode,
                characters: event.charactersIgnoringModifiers ?? "",
                command: flags.contains(.command),
                control: flags.contains(.control),
                option: flags.contains(.option),
                shift: flags.contains(.shift)
            )
            let windowID = event.window.map(ObjectIdentifier.init)
            let consumed = MainActor.assumeIsolated {
                self?.dispatch(key, windowID: windowID) ?? false
            }
            return consumed ? nil : event
        }
    }

    /// A click anywhere but a text field ends typing; SwiftUI content does not take focus on its own,
    /// so the field would otherwise keep swallowing navigation keys.
    private func installClickMonitor() {
        guard clickToken == nil else { return }
        clickToken = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            let location = event.locationInWindow
            let windowID = event.window.map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                guard let self, let window = self.window, windowID == ObjectIdentifier(window),
                      window.firstResponder is NSTextView, let content = window.contentView else { return }
                var hit = content.hitTest(content.convert(location, from: nil))
                while let view = hit {
                    if view is NSTextView || view is NSTextField { return }
                    hit = view.superview
                }
                window.makeFirstResponder(nil)
            }
            return event
        }
    }

    /// Takes the keyboard away from whichever text field has it, so plain keys navigate again.
    func stopTyping() {
        guard let window, window.firstResponder is NSTextView else { return }
        window.makeFirstResponder(nil)
    }

    /// True while a web page has keyboard focus, so typing into it is never read as a shortcut.
    var isInWeb: Bool {
        var view = window?.firstResponder as? NSView
        while let current = view {
            if current is WKWebView { return true }
            view = current.superview
        }
        return false
    }

    private func dispatch(_ key: KeyPress, windowID: ObjectIdentifier?) -> Bool {
        guard let window, windowID == ObjectIdentifier(window), window.attachedSheet == nil else { return false }
        let isTyping = window.firstResponder is NSTextView
        return handler?(key, isTyping) ?? false
    }
}

/// Reports the hosting `NSWindow` once the view is installed.
struct WindowReader: NSViewRepresentable {
    let onWindow: @MainActor (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = ProbeView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ProbeView: NSView {
        var onWindow: (@MainActor (NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindow?(window)
        }
    }
}
