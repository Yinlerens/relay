import SwiftUI
import UIKit
import WebKit

// MARK: - Persistent height cache to prevent scroll jitter across launches

@MainActor
final class TavernHTMLHeightCache {
    static let shared = TavernHTMLHeightCache()
    private var heights: [String: CGFloat] = [:]
    private var hasHydrated = false
    private var saveTask: Task<Void, Never>? = nil

    private init() {}

    func hydrateIfNeeded() {
        guard !hasHydrated else { return }
        hasHydrated = true
        Task { [weak self] in
            let saved = await RelayDiskCache.shared.loadHTMLHeights()
            guard let self, !saved.isEmpty else { return }
            for (k, v) in saved where self.heights[k] == nil && v.isFinite && v >= 32 {
                self.heights[k] = CGFloat(v)
            }
        }
    }

    func height(for key: String) -> CGFloat? {
        heights[key]
    }

    func store(_ height: CGFloat, for key: String) {
        if let existing = heights[key], abs(existing - height) < 1 { return }
        heights[key] = height
        if heights.count > 1600 {
            let overflow = heights.count - 1200
            for k in heights.keys.prefix(overflow) {
                heights.removeValue(forKey: k)
            }
        }
        scheduleSave()
    }

    func clear() {
        saveTask?.cancel()
        saveTask = nil
        heights.removeAll()
        hasHydrated = false
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard let self, !Task.isCancelled else { return }
            var snapshot: [String: Double] = [:]
            snapshot.reserveCapacity(self.heights.count)
            for (k, v) in self.heights {
                snapshot[k] = Double(v)
            }
            await RelayDiskCache.shared.saveHTMLHeights(snapshot)
        }
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
    let mvuDataJSON: String
    var isIframe: Bool = false
    var onSlash: (String) -> Void
    var onSend: (String) -> Void
    var onFillDraft: (String) -> Void

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
                    mvuDataJSON: mvuDataJSON,
                    isDark: colorScheme == .dark,
                    onHeightChange: { newHeight in
                        let clamped = min(max(newHeight, 32), 4000)
                        TavernHTMLHeightCache.shared.store(clamped, for: cacheKey)
                        if abs(clamped - measuredHeight) >= 2 {
                            measuredHeight = clamped
                        }
                    },
                    onSlash: onSlash,
                    onSend: onSend,
                    onFillDraft: onFillDraft
                )
                .frame(maxWidth: .infinity)
                .frame(height: max(32, measuredHeight))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
        .onAppear {
            TavernHTMLHeightCache.shared.hydrateIfNeeded()
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
    let mvuDataJSON: String
    let isDark: Bool
    var onHeightChange: (CGFloat) -> Void
    var onSlash: (String) -> Void
    var onSend: (String) -> Void
    var onFillDraft: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            api: api,
            onHeightChange: onHeightChange,
            onSlash: onSlash,
            onSend: onSend,
            onFillDraft: onFillDraft
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
        config.userContentController.add(weakHandler, name: "relayFillDraft")

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
        context.coordinator.onFillDraft = onFillDraft
        loadDocumentIfNeeded(into: webView, coordinator: context.coordinator)
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        let controller = webView.configuration.userContentController
        controller.removeScriptMessageHandler(forName: "relayHeight")
        controller.removeScriptMessageHandler(forName: "relaySlash")
        controller.removeScriptMessageHandler(forName: "relaySend")
        controller.removeScriptMessageHandler(forName: "relayFillDraft")
        webView.navigationDelegate = nil
        webView.stopLoading()
    }

    private func loadDocumentIfNeeded(into webView: WKWebView, coordinator: Coordinator) {
        let signature = "\(renderedHash)|\(isDark ? 1 : 0)|\(html.hashValue)|\(variablesJSON.hashValue)|\(mvuDataJSON.hashValue)"
        guard coordinator.lastSignature != signature else { return }
        coordinator.lastSignature = signature
        let document = Self.composeDocument(
            html: html,
            variablesJSON: variablesJSON,
            mvuDataJSON: mvuDataJSON,
            isDark: isDark
        )
        webView.loadHTMLString(document, baseURL: URL(string: "relay-st://asset/"))
    }

    // MARK: Document composition (ST CSS variables + Mvu/CatGodOracle/localStorage/parent shims + bidirectional resize)

    private static func composeDocument(
        html: String,
        variablesJSON: String,
        mvuDataJSON: String,
        isDark: Bool
    ) -> String {
        let safeVars = sanitizeJSONForScript(variablesJSON)
        let safeMvu = sanitizeJSONForScript(mvuDataJSON)
        let themeName = isDark ? "dark" : "light"
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
          var __theme = "\(themeName)";
          var __vars = \(safeVars);
          var __mvu = \(safeMvu);
          window.__RELAY_VARS__ = __vars;
          window.__RELAY_MVU__ = __mvu;

          // Safe localStorage fallback for custom relay-st:// scheme (avoids SecurityError)
          var __memMap = Object.create(null);
          __memMap["CatGod_Oracle_UI"] = JSON.stringify({ theme: __theme });
          var __memStorage = {
            getItem: function(k) { return Object.prototype.hasOwnProperty.call(__memMap, String(k)) ? __memMap[String(k)] : null; },
            setItem: function(k, v) { __memMap[String(k)] = String(v); },
            removeItem: function(k) { delete __memMap[String(k)]; },
            clear: function() { __memMap = Object.create(null); },
            key: function(i) { var keys = Object.keys(__memMap); return i >= 0 && i < keys.length ? keys[i] : null; },
            get length() { return Object.keys(__memMap).length; }
          };
          var __storageOk = false;
          try {
            window.localStorage.setItem("__relay_ls_probe__", "1");
            window.localStorage.removeItem("__relay_ls_probe__");
            __storageOk = true;
            try {
              var existingUI = JSON.parse(window.localStorage.getItem("CatGod_Oracle_UI") || "{}");
              existingUI.theme = __theme;
              window.localStorage.setItem("CatGod_Oracle_UI", JSON.stringify(existingUI));
            } catch (e2) {}
          } catch (e) {
            try {
              Object.defineProperty(window, "localStorage", {
                configurable: true,
                get: function() { return __memStorage; }
              });
            } catch (e3) {}
          }
          if (!__storageOk) {
            try {
              Object.defineProperty(window, "sessionStorage", {
                configurable: true,
                get: function() { return __memStorage; }
              });
            } catch (e4) {}
          }

          function deepClone(obj) {
            try { return JSON.parse(JSON.stringify(obj)); } catch (e) { return {}; }
          }
          function cloneVars() {
            return deepClone(window.__RELAY_VARS__ || {});
          }
          function resolveMvuObject() {
            var base = window.__RELAY_MVU__;
            if (!base || typeof base !== "object" || Object.keys(base).length === 0) {
              var latest = window.__RELAY_VARS__ && window.__RELAY_VARS__.__mvu_latest;
              base = (latest && typeof latest === "object") ? latest : { stat_data: {} };
            }
            var cloned = deepClone(base);
            if (!cloned || typeof cloned !== "object") cloned = { stat_data: {} };
            if (!cloned.stat_data || typeof cloned.stat_data !== "object") cloned.stat_data = {};
            return cloned;
          }
          function getByPath(root, pathStr) {
            if (root == null || typeof root !== "object") return undefined;
            var segs = String(pathStr).replace(/\\[(\\d+)\\]/g, ".$1").split(".").filter(function(s) { return s.length > 0; });
            var cur = root;
            for (var i = 0; i < segs.length; i++) {
              if (cur == null || typeof cur !== "object") return undefined;
              if (Object.prototype.hasOwnProperty.call(cur, segs[i])) {
                cur = cur[segs[i]];
              } else {
                return undefined;
              }
            }
            return cur;
          }

          function postSlash(cmd) {
            try {
              if (typeof cmd === "string" && cmd.trim().length > 0) {
                window.webkit.messageHandlers.relaySlash.postMessage(cmd);
              }
            } catch (e) {}
            return Promise.resolve("");
          }
          function postSend(text) {
            try {
              if (typeof text === "string" && text.trim().length > 0) {
                window.webkit.messageHandlers.relaySend.postMessage(text);
              }
            } catch (e) {}
            return Promise.resolve();
          }
          function postFillDraft(text) {
            try {
              if (typeof text === "string") {
                window.webkit.messageHandlers.relayFillDraft.postMessage(text);
              }
            } catch (e) {}
          }

          // Mvu extension shim
          window.Mvu = Object.assign(window.Mvu || {}, {
            getMvuData: function(opts) {
              return resolveMvuObject();
            },
            getVariable: function(data, path, fallback) {
              var source = (data && typeof data === "object") ? data : resolveMvuObject();
              if (typeof path !== "string" || !path) return source;
              var val;
              if (source.stat_data && typeof source.stat_data === "object" && path.indexOf("stat_data.") !== 0 && path !== "stat_data") {
                val = getByPath(source.stat_data, path);
              }
              if (val === undefined) {
                val = getByPath(source, path);
              }
              return val === undefined ? fallback : val;
            }
          });

          // CatGodOracle UI theme shim
          window.CatGodOracle = Object.assign(window.CatGodOracle || {}, {
            theme: __theme,
            version: "relay"
          });

          // TavernHelper & SillyTavern context shims
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
                characters: [],
                chat: [],
                saveSettingsDebounced: function() {},
                executeSlashCommandsWithOptions: postSlash
              };
            }
          });
          window.triggerSlash = window.triggerSlash || postSlash;
          window.getVariables = window.getVariables || function() { return cloneVars(); };

          // Virtual parent DOM proxy for send_textarea & send_but (cards often fill/click composer)
          var __draftBuffer = "";
          var __noopList = { add: function(){}, remove: function(){}, toggle: function(){}, contains: function(){ return false; } };
          var __virtualTextarea = {
            id: "send_textarea",
            tagName: "TEXTAREA",
            style: {},
            classList: __noopList,
            get value() { return __draftBuffer; },
            set value(v) {
              __draftBuffer = (v == null) ? "" : String(v);
              postFillDraft(__draftBuffer);
            },
            focus: function() {},
            blur: function() {},
            setSelectionRange: function() {},
            addEventListener: function() {},
            removeEventListener: function() {},
            dispatchEvent: function() { return true; }
          };
          var __virtualSendBtn = {
            id: "send_but",
            tagName: "DIV",
            style: {},
            classList: __noopList,
            click: function() {
              if (__draftBuffer.trim().length > 0) {
                var toSend = __draftBuffer;
                __draftBuffer = "";
                postSend(toSend);
              }
            },
            addEventListener: function() {},
            removeEventListener: function() {},
            dispatchEvent: function() { return true; }
          };

          var __origGetById = Document.prototype.getElementById;
          Document.prototype.getElementById = function(id) {
            var real = __origGetById.call(this, id);
            if (real) return real;
            if (id === "send_textarea") return __virtualTextarea;
            if (id === "send_but") return __virtualSendBtn;
            return null;
          };
          var __origQuerySelector = Document.prototype.querySelector;
          Document.prototype.querySelector = function(sel) {
            var real = __origQuerySelector.call(this, sel);
            if (real) return real;
            if (sel === "#send_textarea") return __virtualTextarea;
            if (sel === "#send_but") return __virtualSendBtn;
            return null;
          };

          // Listen for explicit resizeIframe postMessage calls from status cards
          window.addEventListener("message", function(ev) {
            try {
              var d = ev && ev.data;
              if (d && d.type === "resizeIframe" && typeof d.height === "number" && isFinite(d.height) && d.height > 0) {
                window.webkit.messageHandlers.relayHeight.postMessage(Math.ceil(d.height));
              }
            } catch (e) {}
          });
        })();
        </script>
        """

        let tailInjection = """
        <script id="relay-st-resize">
        (function() {
          var lastH = 0;
          var raf = 0;
          function measureHeight() {
            var body = document.body;
            var docEl = document.documentElement;
            if (!body) return Math.ceil(docEl ? docEl.scrollHeight : 0);
            var bodyTop = body.getBoundingClientRect().top;
            var maxBottom = 0;
            var children = body.children;
            for (var i = 0; i < children.length; i++) {
              var el = children[i];
              var tag = el.tagName;
              if (tag === "SCRIPT" || tag === "STYLE" || tag === "LINK" || tag === "META") continue;
              var cs = window.getComputedStyle(el);
              if (cs.display === "none" || cs.visibility === "hidden") continue;
              var rect = el.getBoundingClientRect();
              if (rect.height <= 0 && rect.width <= 0) continue;
              var mb = parseFloat(cs.marginBottom) || 0;
              var bottom = rect.bottom - bodyTop + mb;
              if (bottom > maxBottom) maxBottom = bottom;
            }
            var bodyCS = window.getComputedStyle(body);
            var padBottom = parseFloat(bodyCS.paddingBottom) || 0;
            var childH = Math.ceil(maxBottom + padBottom);
            var scrollH = Math.ceil(body.scrollHeight || 0);
            var vpH = Math.ceil(window.innerHeight || 0);
            if (childH > 0) {
              // Allow shrinking below viewport height when collapsible cards close, while growing cleanly on overflow.
              return scrollH > vpH + 2 ? Math.max(childH, scrollH) : childH;
            }
            return Math.max(scrollH, Math.ceil(docEl ? docEl.scrollHeight : 0));
          }
          function report() {
            raf = 0;
            try {
              var h = measureHeight();
              if (h > 0 && Math.abs(h - lastH) >= 2) {
                lastH = h;
                window.webkit.messageHandlers.relayHeight.postMessage(h);
              }
            } catch (e) {}
          }
          function schedule() {
            if (!raf) raf = window.requestAnimationFrame(report);
          }
          function scheduleAfterInteraction() {
            schedule();
            setTimeout(schedule, 50);
            setTimeout(schedule, 180);
            setTimeout(schedule, 380);
          }
          if (typeof ResizeObserver !== "undefined") {
            var ro = new ResizeObserver(schedule);
            if (document.documentElement) ro.observe(document.documentElement);
            if (document.body) ro.observe(document.body);
          }
          if (typeof MutationObserver !== "undefined" && document.body) {
            var mo = new MutationObserver(schedule);
            mo.observe(document.body, { childList: true, subtree: true, attributes: true, characterData: true });
          }
          document.addEventListener("click", scheduleAfterInteraction, true);
          document.addEventListener("toggle", scheduleAfterInteraction, true);
          document.addEventListener("transitionend", schedule, true);
          function watchImages() {
            var imgs = document.querySelectorAll("img");
            for (var i = 0; i < imgs.length; i++) {
              imgs[i].addEventListener("load", schedule);
              imgs[i].addEventListener("error", schedule);
            }
          }
          window.addEventListener("DOMContentLoaded", function() { watchImages(); schedule(); });
          window.addEventListener("load", function() { watchImages(); scheduleAfterInteraction(); });
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
        var onFillDraft: (String) -> Void
        var lastSignature: String = ""

        init(
            api: RelayAPI,
            onHeightChange: @escaping (CGFloat) -> Void,
            onSlash: @escaping (String) -> Void,
            onSend: @escaping (String) -> Void,
            onFillDraft: @escaping (String) -> Void
        ) {
            self.schemeHandler = TavernAssetSchemeHandler(api: api)
            self.onHeightChange = onHeightChange
            self.onSlash = onSlash
            self.onSend = onSend
            self.onFillDraft = onFillDraft
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
            case "relayFillDraft":
                if let text = message.body as? String {
                    DispatchQueue.main.async {
                        self.onFillDraft(text)
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
