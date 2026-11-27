import SwiftUI
import WebKit

/// One web tab: a page, its address bar text and its history. The web view lives here, not in the
/// SwiftUI view, so the page survives switching tabs and moving the tab between panes.
@MainActor
final class WebTabModel: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    @Published var address: String
    @Published private(set) var title = ""
    @Published private(set) var url: URL?
    @Published private(set) var isLoading = false
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var failure: String?
    /// Bumped to put the cursor in the address bar.
    @Published var addressFocusRequest = 0

    let webView: WKWebView
    /// Called when the address changes, so the layout is saved with it.
    var onChange: (() -> Void)?
    private var observations: [NSKeyValueObservation] = []

    init(url: URL? = nil) {
        let configuration = WKWebViewConfiguration()
        // The default store keeps cookies between launches, so sign-ins last.
        configuration.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: configuration)
        // Some sites turn away an unknown browser; this is Safari's own string.
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Safari/605.1.15"
        webView.allowsBackForwardNavigationGestures = true
        self.url = url
        address = url?.absoluteString ?? ""
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        // Single-page sites change address and title without a navigation, so these are observed directly.
        observations = [
            webView.observe(\.url) { [weak self] _, _ in MainActor.assumeIsolated { self?.sync() } },
            webView.observe(\.title) { [weak self] _, _ in MainActor.assumeIsolated { self?.sync() } },
            webView.observe(\.isLoading) { [weak self] _, _ in MainActor.assumeIsolated { self?.sync() } },
            webView.observe(\.canGoBack) { [weak self] _, _ in MainActor.assumeIsolated { self?.sync() } },
            webView.observe(\.canGoForward) { [weak self] _, _ in MainActor.assumeIsolated { self?.sync() } },
        ]
        if let url { webView.load(URLRequest(url: url)) }
    }

    /// What the tab strip shows.
    var label: String {
        if !title.isEmpty { return title }
        return url?.host?.replacingOccurrences(of: "www.", with: "") ?? "New Web Tab"
    }

    /// An address as typed: `x.com/someone` gets `https://`; anything that is not an address is searched for.
    static func resolve(_ text: String) -> URL? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.hasPrefix("http://") || text.hasPrefix("https://") { return URL(string: text) }
        if !text.contains(" "), text.contains("."), let url = URL(string: "https://" + text), url.host != nil { return url }
        var search = URLComponents(string: "https://duckduckgo.com/")
        search?.queryItems = [URLQueryItem(name: "q", value: text)]
        return search?.url
    }

    static func looksLikeAddress(_ text: String) -> Bool {
        let text = text.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("http://") || text.hasPrefix("https://") { return true }
        guard !text.contains(" "), let dot = text.lastIndex(of: "."), dot != text.startIndex else { return false }
        let suffix = text[text.index(after: dot)...].prefix { $0 != "/" }
        return suffix.count >= 2 && suffix.allSatisfy(\.isLetter)
    }

    func go() {
        guard let target = Self.resolve(address) else { return }
        failure = nil
        webView.load(URLRequest(url: target))
    }

    func open(_ target: URL) {
        address = target.absoluteString
        go()
    }

    func reload() {
        if webView.url == nil { go() } else { webView.reload() }
    }

    func back() { webView.goBack() }
    func forward() { webView.goForward() }

    /// Stops the page (and anything it is playing) when the tab closes.
    func shutdown() {
        webView.stopLoading()
        webView.loadHTMLString("", baseURL: nil)
    }

    private func sync() {
        if let current = webView.url, current.absoluteString != "about:blank", current != url {
            url = current
            address = current.absoluteString
            onChange?()
        }
        if title != webView.title ?? "" { title = webView.title ?? "" }
        if isLoading != webView.isLoading { isLoading = webView.isLoading }
        if canGoBack != webView.canGoBack { canGoBack = webView.canGoBack }
        if canGoForward != webView.canGoForward { canGoForward = webView.canGoForward }
    }

    // MARK: Delegates

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        // A cancelled load (the user went somewhere else) is not a failure.
        if (error as NSError).code != NSURLErrorCancelled { failure = error.localizedDescription }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        failure = nil
    }

    /// Links that ask for a new window open in this tab.
    func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
        return nil
    }
}

/// A web page in a tab: back, forward, reload, an address bar, and the page.
struct WebTabView: View {
    @ObservedObject var model: WebTabModel
    @FocusState private var isAddressFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                control("‹", help: "Back ( ⌘[ )", isEnabled: model.canGoBack) { model.back() }
                control("›", help: "Forward ( ⌘] )", isEnabled: model.canGoForward) { model.forward() }
                control(model.isLoading ? "×" : "↻", help: model.isLoading ? "Stop" : "Reload ( ⌘R )", isEnabled: true) {
                    if model.isLoading { model.webView.stopLoading() } else { model.reload() }
                }
                TextField("Address or search", text: $model.address)
                    .textFieldStyle(.plain)
                    .font(Term.font(11.5))
                    .autocorrectionDisabled()
                    .focused($isAddressFocused)
                    .onSubmit { model.go() }
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(Term.chrome)
                    .overlay(Rectangle().stroke(isAddressFocused ? Term.accent : Term.rule, lineWidth: 1))
            }
            .padding(.horizontal, 8)
            .frame(height: 32)
            .overlay(alignment: .bottom) {
                // A thin gold line while the page loads.
                if model.isLoading { Term.accent.frame(height: 1) }
            }
            TermRule()

            if model.url == nil, !model.isLoading {
                Text("TYPE AN ADDRESS OR A SEARCH AND PRESS ⏎")
                    .font(Term.font(11.5))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let failure = model.failure {
                Text(failure)
                    .font(Term.font(11.5))
                    .foregroundStyle(PowderPalette.riskCoral)
                    .multilineTextAlignment(.center)
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                WebViewHost(webView: model.webView)
            }
        }
        .foregroundStyle(Term.foreground)
        .onAppear { if model.url == nil { isAddressFocused = true } }
        .onChange(of: model.addressFocusRequest) { isAddressFocused = true }
    }

    private func control(_ glyph: String, help: String, isEnabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(glyph)
                .font(.system(size: 15))
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isEnabled ? Term.foreground : Color.secondary.opacity(0.4))
        .disabled(!isEnabled)
        .help(help)
    }
}

/// Hosts the model's long-lived web view. It sits inside a plain container so SwiftUI can throw the
/// container away on a tab switch without tearing the page down.
private struct WebViewHost: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        if webView.superview !== container { attach(to: container) }
    }

    private func attach(to container: NSView) {
        webView.removeFromSuperview()
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)
    }
}
