import AppKit
import StillFilterKit
import WebKit

/// Führt Safari-Content-Blocker mit echtem WebKit aus: dieselbe Engine wie in Safari.
@MainActor
final class WebKitRunner: NSObject, WKNavigationDelegate {
    private let store: WKContentRuleListStore
    private var navigation: CheckedContinuation<Void, Never>?
    /// Nur Meldungen der gerade ladenden Seite zählen; alte, gestoppte Seiten dürfen nichts beenden
    private var currentWebView: WKWebView?
    private var loadID = 0

    override init() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("still-check-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = WKContentRuleListStore(url: dir)
        super.init()
    }

    func compile(_ json: String, id: String) async throws -> WKContentRuleList {
        try await withCheckedThrowingContinuation { continuation in
            store.compileContentRuleList(forIdentifier: id, encodedContentRuleList: json) { list, error in
                if let list {
                    continuation.resume(returning: list)
                } else {
                    continuation.resume(throwing: error ?? CocoaError(.featureUnsupported))
                }
            }
        }
    }

    /// Kompiliert die Regeln; scheitert WebKit, werden die schuldigen Regeln per Halbierung gefunden und entfernt.
    func validate(_ rules: [SafariRule], id: String) async -> (valid: [SafariRule], removed: [SafariRule]) {
        if (try? await compile(encode(rules), id: id)) != nil { return (rules, []) }
        if rules.count == 1 { return ([], rules) }
        let mid = rules.count / 2
        let left = await validate(Array(rules[..<mid]), id: id)
        let right = await validate(Array(rules[mid...]), id: id)
        return (left.valid + right.valid, left.removed + right.removed)
    }

    func encode(_ rules: [SafariRule]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return String(decoding: (try? encoder.encode(rules)) ?? Data("[]".utf8), as: UTF8.self)
    }

    /// Lädt eine Seite mit den angegebenen Regellisten und liefert das Ergebnis eines Skripts danach.
    func load(html: String? = nil, url: URL, lists: [WKContentRuleList], settle: Duration, script: String,
              pageScripts: [String] = [], cookies: [HTTPCookie] = [], userAgent: String? = nil) async -> Any? {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        // Videos sollen wie bei echten Nutzern losspielen, sonst lädt YouTube keine Werbung
        config.mediaTypesRequiringUserActionForPlayback = []
        for list in lists { config.userContentController.add(list) }
        // Wie ein Content-Script mit world: MAIN zum Dokumentstart
        for source in pageScripts {
            config.userContentController.addUserScript(
                WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))
        }
        for cookie in cookies { await config.websiteDataStore.httpCookieStore.setCookie(cookie) }
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 900), configuration: config)
        webView.customUserAgent = userAgent ?? "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
        webView.navigationDelegate = self
        currentWebView = webView
        loadID += 1
        let id = loadID

        await withCheckedContinuation { continuation in
            navigation = continuation
            if let html {
                webView.loadHTMLString(html, baseURL: url)
            } else {
                webView.load(URLRequest(url: url, timeoutInterval: 30))
            }
            // Sicherheitsnetz, falls die Seite nie fertig wird
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(30))
                if self.loadID == id { self.finishNavigation() }
            }
        }
        try? await Task.sleep(for: settle)
        // Eine eingefrorene Seite darf die Prüfung nicht blockieren
        let result = await Self.firstOf(.seconds(40)) {
            try? await webView.callAsyncJavaScript(script, contentWorld: .page)
        }
        webView.stopLoading()
        return result
    }

    enum MainFrameResult { case allowed, blocked, unknown }

    /// Ruft eine Adresse als Hauptseite auf und meldet, ob der Content-Blocker den Abruf gestoppt hat.
    /// Der Seiteninhalt wird nicht geladen: Sobald eine Antwort kommt, ist klar, dass nichts geblockt wurde.
    func probeMainFrame(_ url: URL, lists: [WKContentRuleList], timeout: Duration = .seconds(20)) async -> MainFrameResult {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        for list in lists { config.userContentController.add(list) }
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
        let probe = MainFrameProbe()
        webView.navigationDelegate = probe
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<MainFrameResult, Never>) in
            probe.finish = { continuation.resume(returning: $0) }
            webView.load(URLRequest(url: url, timeoutInterval: 15))
            Task { @MainActor in
                try? await Task.sleep(for: timeout)
                probe.complete(.unknown)
            }
        }
        webView.stopLoading()
        webView.navigationDelegate = nil
        return result
    }

    /// Ergebnis der Operation oder nil nach Ablauf der Zeit. Anders als eine TaskGroup wartet das nicht
    /// auf eine hängende Operation, die sich nicht abbrechen lässt.
    static func firstOf<T>(_ timeout: Duration, _ operation: @escaping @MainActor () async -> T?) async -> T? {
        await withCheckedContinuation { continuation in
            var finished = false
            Task { @MainActor in
                let value = await operation()
                if !finished { finished = true; continuation.resume(returning: value) }
            }
            Task { @MainActor in
                try? await Task.sleep(for: timeout)
                if !finished { finished = true; continuation.resume(returning: nil) }
            }
        }
    }

    private func finishNavigation() {
        navigation?.resume()
        navigation = nil
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in if webView === self.currentWebView { self.finishNavigation() } }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in if webView === self.currentWebView { self.finishNavigation() } }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in if webView === self.currentWebView { self.finishNavigation() } }
    }
}

/// Navigations-Delegate für `probeMainFrame`: beendet genau einmal.
@MainActor
final class MainFrameProbe: NSObject, WKNavigationDelegate {
    var finish: ((WebKitRunner.MainFrameResult) -> Void)?

    func complete(_ result: WebKitRunner.MainFrameResult) {
        guard let finish else { return }
        self.finish = nil
        finish(result)
    }

    nonisolated static func isContentBlocked(_ error: Error) -> Bool {
        let error = error as NSError
        // WebKitErrorFrameLoadBlockedByContentBlocker
        return error.domain == "WebKitErrorDomain" && error.code == 104
    }

    nonisolated func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                             decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        MainActor.assumeIsolated {
            decisionHandler(.cancel)
            complete(.allowed)
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let blocked = Self.isContentBlocked(error)
        MainActor.assumeIsolated { complete(blocked ? .blocked : .allowed) }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        let blocked = Self.isContentBlocked(error)
        MainActor.assumeIsolated { complete(blocked ? .blocked : .allowed) }
    }
}
