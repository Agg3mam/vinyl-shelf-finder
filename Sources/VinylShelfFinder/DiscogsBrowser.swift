import SwiftUI
import AppKit
import WebKit
import VinylCore

// MARK: - Det indbyggede Discogs-vindue
//
// Discogs' API kan ikke købe, så købet sker på Discogs' egen side i dette vindue.
// SIKKERHED: Appen viser bare siden. Den injicerer ingen scripts, har ingen
// beskedkanaler til siden, læser ingen cookies eller formularfelter og gemmer intet
// om login eller betaling. Login huskes af WebKits eget, vedvarende standard-datalager
// (det samme princip som i Safari), ikke af appen.

enum DiscogsBrowser {
    static let windowID = "discogs"
    /// Gemmes i appens database, når brugeren har set den første forklaring.
    static let hintSetting = "discogs_browser_hint_seen"

    /// WebKits datalager. Standard er det vedvarende lager, så login huskes mellem gange.
    /// Kun test må skifte det ud (fx til et midlertidigt lager).
    @MainActor static var makeDataStore: () -> WKWebsiteDataStore = { .default() }
}

/// Tilstanden for ét Discogs-vindue (tilbage/frem, adresse, indlæsning).
@MainActor
@Observable
final class BrowserState {
    var canGoBack = false
    var canGoForward = false
    var isLoading = false
    var url: URL?
    var failure: String?

    let webView: WKWebView
    @ObservationIgnored private let delegate = BrowserDelegate()
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = DiscogsBrowser.makeDataStore()
        // Som Safari, så Discogs og betalingssider viser deres almindelige side.
        config.applicationNameForUserAgent = "Version/26.0 Safari/605.1.15"
        // Bevidst ingen `userContentController`-scripts eller beskedkanaler.
        webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        delegate.state = self
        webView.navigationDelegate = delegate
        webView.uiDelegate = delegate
        observations = [
            webView.observe(\.canGoBack, options: [.initial, .new]) { [weak self] wv, _ in
                MainActor.assumeIsolated { self?.canGoBack = wv.canGoBack }
            },
            webView.observe(\.canGoForward, options: [.initial, .new]) { [weak self] wv, _ in
                MainActor.assumeIsolated { self?.canGoForward = wv.canGoForward }
            },
            webView.observe(\.isLoading, options: [.initial, .new]) { [weak self] wv, _ in
                MainActor.assumeIsolated { self?.isLoading = wv.isLoading }
            },
            webView.observe(\.url, options: [.initial, .new]) { [weak self] wv, _ in
                MainActor.assumeIsolated { if let u = wv.url { self?.url = u } }
            },
        ]
    }

    func load(_ url: URL) {
        // Kun almindelige websider (Discogs' salgssider) – aldrig lokale filer.
        guard url.scheme?.lowercased() == "https" || url.scheme?.lowercased() == "http" else { return }
        failure = nil
        self.url = url
        webView.load(URLRequest(url: url))
    }

    func reloadOrStop() {
        if webView.isLoading { webView.stopLoading(); return }
        failure = nil
        if webView.url != nil { webView.reload() } else if let url { load(url) }
    }

    /// Åbner den viste side i Safari (eller standardbrowseren, hvis Safari mangler).
    func openInSafari() {
        guard let url = webView.url ?? url, url.scheme == "https" || url.scheme == "http" else { return }
        if let safari = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari") {
            NSWorkspace.shared.open([url], withApplicationAt: safari, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Navigation og vinduer fra siden. Læser intet fra siden.
@MainActor
private final class BrowserDelegate: NSObject, WKNavigationDelegate, WKUIDelegate {
    weak var state: BrowserState?

    /// Links med `target=_blank` og `window.open` indlæses i samme vindue.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.request.url != nil { webView.load(navigationAction.request) }
        return nil
    }

    /// Kun almindelige websider vises. Andre adresser (fx mailto:) gives videre til macOS.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url, let scheme = url.scheme?.lowercased() else { return .cancel }
        switch scheme {
        // Ingen file: – Discogs-vinduet må aldrig vise lokale filer fra Mac'en.
        case "http", "https", "about", "blob", "data":
            return .allow
        case "mailto":
            NSWorkspace.shared.open(url)
            return .cancel
        default:
            return .cancel
        }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        state?.failure = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        report(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        report(error)
    }

    private func report(_ error: Error) {
        let ns = error as NSError
        // Afbrudt af brugeren eller af en ny navigation: ikke en fejl.
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return }
        if ns.domain == "WebKitErrorDomain" && ns.code == 102 { return }
        let offline = ns.domain == NSURLErrorDomain && [NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost,
                                                        NSURLErrorCannotFindHost, NSURLErrorTimedOut].contains(ns.code)
        state?.failure = offline
            ? "Ingen forbindelse til internettet. Tjek forbindelsen, og prøv igen."
            : "Siden kunne ikke indlæses. Prøv igen om lidt."
    }

    // Almindelige dialoger fra siden (fx "Er du sikker?") vises som macOS-dialoger.
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async {
        let alert = NSAlert()
        alert.messageText = frame.request.url?.host() ?? "Discogs"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async -> Bool {
        let alert = NSAlert()
        alert.messageText = frame.request.url?.host() ?? "Discogs"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Annullér")
        return alert.runModal() == .alertFirstButtonReturn
    }
}

private struct WebViewHost: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

/// Indholdet i Discogs-vinduet: værktøjslinje, første-gangs-forklaring og selve siden.
struct DiscogsBrowserView: View {
    @Environment(AppModel.self) private var model
    /// Oprettes først, når vinduet vises (ét `WKWebView` pr. vindue).
    @ViewState private var state: BrowserState?
    @ViewState private var hintSeen = true
    @ViewState private var loadedRequest = 0

    var body: some View {
        let shop = model.findNew
        Group {
            if let state {
                content(state)
            } else {
                Color(nsColor: .windowBackgroundColor)
            }
        }
        .frame(minWidth: 640, minHeight: 480)
        .navigationTitle("Discogs")
        .onAppear {
            hintSeen = model.store.setting(DiscogsBrowser.hintSetting) == "1"
            // Ny side hver gang vinduet åbnes. Login huskes af datalageret, ikke af visningen.
            let fresh = BrowserState()
            state = fresh
            loadedRequest = 0
            loadRequested(shop, into: fresh)
        }
        .onDisappear { state = nil }
        .onChange(of: shop.browserRequestID) {
            if let state { loadRequested(shop, into: state) }
        }
    }

    private func content(_ state: BrowserState) -> some View {
        VStack(spacing: 0) {
            if !hintSeen {
                BrowserHint { dismissHint() }
                Divider()
            }
            ZStack {
                WebViewHost(webView: state.webView)
                if let failure = state.failure {
                    BrowserFailure(message: failure) { state.reloadOrStop() }
                }
            }
        }
        .toolbar { BrowserToolbar(state: state) }
    }

    private func loadRequested(_ shop: FindNewModel, into state: BrowserState) {
        guard shop.browserRequestID != loadedRequest, let url = shop.browserURL else { return }
        loadedRequest = shop.browserRequestID
        state.load(url)
    }

    private func dismissHint() {
        model.store.setSetting(DiscogsBrowser.hintSetting, "1")
        hintSeen = true
    }
}

private struct BrowserToolbar: ToolbarContent {
    let state: BrowserState

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { state.webView.goBack() } label: { Label("Tilbage", systemImage: "chevron.backward") }
                .disabled(!state.canGoBack)
                .keyboardShortcut("[", modifiers: .command)
                .help("Tilbage (⌘[)")
            Button { state.webView.goForward() } label: { Label("Frem", systemImage: "chevron.forward") }
                .disabled(!state.canGoForward)
                .keyboardShortcut("]", modifiers: .command)
                .help("Frem (⌘])")
        }
        ToolbarItem(placement: .principal) {
            AddressField(url: state.url, loading: state.isLoading)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { state.reloadOrStop() } label: {
                Label(state.isLoading ? "Stop" : "Genindlæs", systemImage: state.isLoading ? "xmark" : "arrow.clockwise")
            }
            .help(state.isLoading ? "Stop indlæsningen" : "Genindlæs siden")
            Button { state.openInSafari() } label: { Label("Åbn i Safari", systemImage: "safari") }
                .disabled(state.url.map { $0.scheme != "https" && $0.scheme != "http" } ?? true)
                .help("Åbn siden i Safari")
        }
    }
}

/// Værtsnavnet står tydeligt (fx "www.discogs.com"), så man kan se, hvor man er.
/// Hele adressen vises som hjælpetekst.
private struct AddressField: View {
    let url: URL?
    let loading: Bool

    var body: some View {
        let secure = url?.scheme == "https"
        let host = url?.host() ?? url?.absoluteString ?? ""
        HStack(spacing: Spacing.xs) {
            Image(systemName: secure ? "lock.fill" : "globe")
                .foregroundStyle(.secondary)
                .imageScale(.small)
                .accessibilityHidden(true)
            Text(host.isEmpty ? "Indlæser…" : host)
                .fontWeight(.medium)
                .lineLimit(1)
                .truncationMode(.middle)
            if let path = url?.path(), url?.host() != nil, path.count > 1 {
                Text(path)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(-1)
            }
            if loading {
                ProgressView().controlSize(.small).accessibilityLabel("Indlæser")
            }
        }
        .font(.callout)
        .padding(.horizontal, Spacing.s)
        .frame(minWidth: 260, idealWidth: 460, maxWidth: 560, minHeight: 26)
        .background(.quaternary.opacity(0.6), in: Capsule())
        .help(url?.absoluteString ?? "")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(secure ? "Sikker forbindelse til \(host)" : "Adresse: \(host)")
    }
}

/// Første gang: en kort, venlig forklaring øverst.
private struct BrowserHint: View {
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: Spacing.s) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(AppAccent.color)
                .accessibilityHidden(true)
            Text("Du køber direkte hos Discogs. Log ind på Discogs her første gang.")
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Spacing.s)
            Button("Forstået", action: dismiss)
        }
        .font(.callout)
        .padding(.horizontal, Spacing.m)
        .padding(.vertical, Spacing.s)
        .background(AppAccent.color.opacity(0.1))
    }
}

private struct BrowserFailure: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Siden kunne ikke vises", systemImage: "wifi.exclamationmark")
        } description: {
            Text(message)
        } actions: {
            Button("Prøv igen", action: retry)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
