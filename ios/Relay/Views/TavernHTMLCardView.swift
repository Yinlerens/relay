import SwiftUI
import UIKit
import WebKit

// MARK: - Height cache to prevent scroll jitter

@MainActor
final class TavernHTMLHeightCache {
    static let shared = TavernHTMLHeightCache()
    private var heights: [String: CGFloat] = [:]

    private init() {}

    func height(for key: String) -> CGFloat? {
        heights[key]
    }

    func store(_ height: CGFloat, for key: String) {
        heights[key] = height
    }
}

// MARK: - Weak WKScriptMessageHandler wrapper (prevents retain cycles)

private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var delegate: WKScriptMessageHandler?

    init(_ delegate: WKScriptMessageHandler) {
        self.delegate = delegate
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        delegate?.userContentController(userContentController, didReceive: message)
    }
}

// MARK: - Native SwiftUI HTML / iframe card for SillyTavern blocks

struct TavernHTMLCardView: View {
    let blockId: String
    let renderedHash: String
    let html: String
    let estimatedHeight: Double?
    let variablesJSON: String
    var isIframe: Bool = false
    var onSlash: (String) -> Void
    var onSend: (String) -> Void

    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var colorScheme
    @State private var measuredHeight: CGFloat = 120

    private var cacheKey: String {
        "\(blockId)|\(renderedHash)|\(colorScheme == .dark ? "d" : "l")"
    }

    private var initialHeight: CGFloat {
        if let cached = TavernHTMLHeightCache.shared.height(for: cacheKey) {
            return cached
        }
        if let est = estimatedHeight, est.isFinite, est > 20 {
            return min(max(CGFloat(est), 40), 2400)
        }
        return isIframe ? 180 : 96
    }

    var body: some View {
        Group {
            if let api = store.api {
                TavernWebViewRepresentable(
                    api: api,
                    html: html,
                    renderedHash: renderedHash,
                    variablesJSON: variablesJSON,
                    isDark: colorScheme == .dark,
                    onHeightChange: { newHeight in
                        let clamped = min(max(newHeight, 32), 4000)
                        TavernHTMLHeightCache.shared.store(clamped, for: cacheKey)
                        if abs(clamped - measuredHeight) >= 2 {
                            measuredHeight = clamped
                        }
                    },
                    onSlash: onSlash,
                    onSend: onSend
                )
                .frame(maxWidth: .infinity)
                .frame(height: max(32, measuredHeight))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
        .onAppear {
            measuredHeight = initialHeight
        }
        .onChange(of: cacheKey) { _, _ in
            measuredHeight = initialHeight
        }
    }
}

// MARK: - UIViewRepresentable WKWebView wrapper

private struct TavernWebViewRepresentable: UIViewRepresentable {
    let api: RelayAPI
    let html: String
    let renderedHash: String
    let variablesJSON: String
    let isDark: Bool
    var onHeightChange: (CGFloat) -> Void
    var onSlash: (String) -> Void
    var onSend: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            api: api,
            onHeightChange: onHeightChange,
            onSlash: onSlash,
            onSend: onSend
        )
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.setURLSchemeHandler(context.coordinator.schemeHandler, forURLScheme: "relay-st")

        let weakHandler = WeakScriptMessageHandler(context.coordinator)
        config.userContentController.add(weakHandler, name: "relayHeight")
        config.userContentController.add(weakHandler, name: "relaySlash")
        config.userContentController.add(weakHandler, name: "relaySend")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.scrollView.showsVerticalScrollIndicator = false
        webView.scrollView.showsHorizontalScrollIndicator = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never

        loadDocumentIfNeeded(into: webView, coordinator: context.coordinator)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.onHeightChange = onHeightChange
        context.coordinator.onSlash = onSlash
        context.coordinator.onSend = onSend
        loadDocumentIfNeeded(into: webView, coordinator: context.coordinator)
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        let controller = webView.configuration.userContentController
        controller.removeScriptMessageHandler(forName: "relayHeight")
        controller.removeScriptMessageHandler(forName: "relaySlash")
        controller.removeScriptMessageHandler(forName: "relaySend")
        webView.navigationDelegate = nil
        webView.stopLoading()
    }

    private func loadDocumentIfNeeded(into webView: WKWebView, coordinator: Coordinator) {
        let signature = "\(renderedHash)|\(isDark ? 1 : 0)|\(html.hashValue)|\(variablesJSON.hashValue)"
        guard coordinator.lastSignature != signature else { return }
        coordinator.lastSignature = signature
        let document = Self.composeDocument(html: html, variablesJSON: variablesJSON, isDark: isDark)
        webView.loadHTMLString(document, baseURL: URL(string: "relay-st://asset/"))
    }

    // MARK: Document composition (ST CSS variables + JS shim + ResizeObserver)

    private static func composeDocument(html: String, variablesJSON: String, isDark: Bool) -> String {
        let safeVars = sanitizeJSONForScript(variablesJSON)
        let themeVars = isDark
            ? """
              :root {
                color-scheme: dark;
                --SmartThemeBodyColor: #F2F1EE;
                --SmartThemeEmColor: #B8B6C6;
                --SmartThemeQuoteColor: #9AA5FF;
                --SmartThemeUnderlineColor: #9AA5FF;
                --SmartThemeBlurTintColor: rgba(21, 21, 27, 0.86);
                --SmartThemeChatTintColor: rgba(28, 28, 36, 0.92);
                --SmartThemeUserMesBlurTintColor: rgba(28, 28, 36, 0.92);
                --SmartThemeBotMesBlurTintColor: rgba(21, 21, 27, 0.92);
                --SmartThemeBorderColor: rgba(255, 255, 255, 0.12);
                --SmartThemeShadowColor: rgba(0, 0, 0, 0.45);
              }
              """
            : """
              :root {
                color-scheme: light;
                --SmartThemeBodyColor: #16161A;
                --SmartThemeEmColor: #5F5E6B;
                --SmartThemeQuoteColor: #5458D8;
                --SmartThemeUnderlineColor: #5458D8;
                --SmartThemeBlurTintColor: rgba(255, 255, 255, 0.90);
                --SmartThemeChatTintColor: rgba(251, 250, 248, 0.96);
                --SmartThemeUserMesBlurTintColor: rgba(251, 250, 248, 0.96);
                --SmartThemeBotMesBlurTintColor: rgba(255, 255, 255, 0.96);
                --SmartThemeBorderColor: rgba(0, 0, 0, 0.10);
                --SmartThemeShadowColor: rgba(0, 0, 0, 0.10);
              }
              """

        let headInjection = """
        <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
        <style id="relay-st-theme">
        \(themeVars)
        html, body {
          margin: 0;
          padding: 0;
          background: transparent !important;
          color: var(--SmartThemeBodyColor);
          font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "PingFang SC", sans-serif;
          font-size: 15px;
          line-height: 1.55;
          overflow-x: hidden;
          word-wrap: break-word;
          -webkit-text-size-adjust: 100%;
        }
        img, video, svg { max-width: 100%; height: auto; }
        </style>
        <script id="relay-st-shim">
        (function() {
          var __vars = \(safeVars);
          window.__RELAY_VARS__ = __vars;
          function cloneVars() {
            try { return JSON.parse(JSON.stringify(window.__RELAY_VARS__ || {})); } catch (e) { return {}; }
          }
          function postSlash(cmd) {
            try {
              if (typeof cmd === 'string' && cmd.trim().length > 0) {
                window.webkit.messageHandlers.relaySlash.postMessage(cmd);
              }
            } catch (e) {}
            return Promise.resolve('');
          }
          function postSend(text) {
            try {
              if (typeof text === 'string' && text.trim().length > 0) {
                window.webkit.messageHandlers.relaySend.postMessage(text);
              }
            } catch (e) {}
            return Promise.resolve();
          }
          window.TavernHelper = Object.assign(window.TavernHelper || {}, {
            getVariables: function() { return cloneVars(); },
            getAllVariables: function() { return cloneVars(); },
            getChatMessages: function() { return []; },
            triggerSlash: postSlash,
            send: postSend
          });
          window.SillyTavern = Object.assign(window.SillyTavern || {}, {
            getContext: function() {
              return {
                chatMetadata: { variables: cloneVars() },
                extensionSettings: {},
                executeSlashCommandsWithOptions: postSlash
              };
            }
          });
          window.triggerSlash = window.triggerSlash || postSlash;
          window.getVariables = window.getVariables || function() { return cloneVars(); };
        })();
        </script>
        """

        let tailInjection = """
        <script id="relay-st-resize">
        (function() {
          var lastH = 0;
          var raf = 0;
          function report() {
            raf = 0;
            try {
              var body = document.body;
              var docEl = document.documentElement;
              var h = Math.ceil(Math.max(
                body ? body.scrollHeight : 0,
                body ? body.getBoundingClientRect().height : 0,
                docEl ? docEl.scrollHeight : 0
              ));
              if (h > 0 && Math.abs(h - lastH) >= 2) {
                lastH = h;
                window.webkit.messageHandlers.relayHeight.postMessage(h);
              }
            } catch (e) {}
          }
          function schedule() {
            if (!raf) raf = window.requestAnimationFrame(report);
          }
          if (typeof ResizeObserver !== 'undefined') {
            var ro = new ResizeObserver(schedule);
            if (document.documentElement) ro.observe(document.documentElement);
            if (document.body) ro.observe(document.body);
          }
          if (typeof MutationObserver !== 'undefined' && document.body) {
            var mo = new MutationObserver(schedule);
            mo.observe(document.body, { childList: true, subtree: true, attributes: true, characterData: true });
          }
          function watchImages() {
            var imgs = document.querySelectorAll('img');
            for (var i = 0; i < imgs.length; i++) {
              imgs[i].addEventListener('load', schedule);
              imgs[i].addEventListener('error', schedule);
            }
          }
          window.addEventListener('DOMContentLoaded', function() { watchImages(); schedule(); });
          window.addEventListener('load', function() { watchImages(); schedule(); });
          watchImages();
          schedule();
          setTimeout(schedule, 120);
          setTimeout(schedule, 420);
        })();
        </script>
        """

        let lower = html.lowercased()
        if lower.contains("<html") || lower.contains("<!doctype") {
            var doc = html
            if let headRange = doc.range(of: "<head>", options: .caseInsensitive) {
                doc.insert(contentsOf: "\n" + headInjection + "\n", at: headRange.upperBound)
            } else if let htmlRange = doc.range(of: "<html[^>]*>", options: [.regularExpression, .caseInsensitive]) {
                doc.insert(contentsOf: "\n<head>\(headInjection)</head>\n", at: htmlRange.upperBound)
            } else {
                doc = headInjection + "\n" + doc
            }
            if let bodyClose = doc.range(of: "</body>", options: [.caseInsensitive, .backwards]) {
                doc.insert(contentsOf: "\n" + tailInjection + "\n", at: bodyClose.lowerBound)
            } else {
                doc += "\n" + tailInjection
            }
            return doc
        }

        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        \(headInjection)
        </head>
        <body>
        \(html)
        \(tailInjection)
        </body>
        </html>
        """
    }

    private static func sanitizeJSONForScript(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = trimmed.isEmpty ? "{}" : trimmed
        return candidate
            .replacingOccurrences(of: "</", with: "<\\/")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }

    // MARK: Coordinator

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        let schemeHandler: TavernAssetSchemeHandler
        var onHeightChange: (CGFloat) -> Void
        var onSlash: (String) -> Void
        var onSend: (String) -> Void
        var lastSignature: String = ""

        init(
            api: RelayAPI,
            onHeightChange: @escaping (CGFloat) -> Void,
            onSlash: @escaping (String) -> Void,
            onSend: @escaping (String) -> Void
        ) {
            self.schemeHandler = TavernAssetSchemeHandler(api: api)
            self.onHeightChange = onHeightChange
            self.onSlash = onSlash
            self.onSend = onSend
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            switch message.name {
            case "relayHeight":
                if let num = message.body as? NSNumber {
                    let h = CGFloat(num.doubleValue)
                    DispatchQueue.main.async {
                        self.onHeightChange(h)
                    }
                }
            case "relaySlash":
                if let cmd = message.body as? String, !cmd.isEmpty {
                    DispatchQueue.main.async {
                        self.onSlash(cmd)
                    }
                }
            case "relaySend":
                if let text = message.body as? String, !text.isEmpty {
                    DispatchQueue.main.async {
                        self.onSend(text)
                    }
                }
            default:
                break
            }
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url,
               let scheme = url.scheme?.lowercased(),
               scheme == "http" || scheme == "https" {
                UIApplication.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }
}
