import SwiftUI
import UIKit
import WebKit

// MARK: - In-memory height cache for rendered Mermaid diagrams

@MainActor
final class MermaidHeightCache {
    static let shared = MermaidHeightCache()
    private var heights: [String: CGFloat] = [:]

    private init() {}

    static func cacheKey(code: String, isDark: Bool) -> String {
        "\(code.hashValue)|\(code.utf8.count)|\(isDark ? "d" : "l")"
    }

    func height(for key: String) -> CGFloat? {
        heights[key]
    }

    func store(_ height: CGFloat, for key: String) {
        if let existing = heights[key], abs(existing - height) < 1 {
            return
        }
        heights[key] = height
        if heights.count > 300 {
            let overflow = heights.count - 200
            for k in heights.keys.prefix(overflow) {
                heights.removeValue(forKey: k)
            }
        }
    }

    func clear() {
        heights.removeAll()
    }
}

// MARK: - Offline bundle scheme handler for `relay-mermaid://asset/mermaid.min.js`

@MainActor
final class MermaidAssetSchemeHandler: NSObject, WKURLSchemeHandler {
    private static let bundledScriptData: Data? = {
        let url =
            Bundle.main.url(forResource: "mermaid.min", withExtension: "js")
            ?? Bundle(for: MermaidAssetSchemeHandler.self).url(forResource: "mermaid.min", withExtension: "js")
        guard let url else {
            return nil
        }
        return try? Data(contentsOf: url)
    }()

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let requestURL = urlSchemeTask.request.url ?? URL(string: "relay-mermaid://asset/mermaid.min.js")!
        guard requestURL.lastPathComponent == "mermaid.min.js",
              let data = Self.bundledScriptData else {
            urlSchemeTask.didFailWithError(
                NSError(
                    domain: "MermaidAssetSchemeHandler",
                    code: 404,
                    userInfo: [NSLocalizedDescriptionKey: "Bundled mermaid.min.js not found"]
                )
            )
            return
        }

        let headers: [String: String] = [
            "Content-Type": "application/javascript; charset=utf-8",
            "Content-Length": "\(data.count)",
            "Cache-Control": "public, max-age=86400",
            "Access-Control-Allow-Origin": "*",
        ]
        let response: URLResponse = HTTPURLResponse(
            url: requestURL,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        ) ?? URLResponse(
            url: requestURL,
            mimeType: "application/javascript",
            expectedContentLength: data.count,
            textEncodingName: "utf-8"
        )
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}

// MARK: - Weak WKScriptMessageHandler wrapper

@MainActor
private final class WeakMermaidMessageHandler: NSObject, WKScriptMessageHandler {
    weak var delegate: WKScriptMessageHandler?

    init(_ delegate: WKScriptMessageHandler) {
        self.delegate = delegate
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        delegate?.userContentController(userContentController, didReceive: message)
    }
}

// MARK: - Inline Mermaid diagram card

struct MermaidDiagramCard: View {
    let code: String
    let tint: Color

    @Environment(\.colorScheme) private var colorScheme
    @State private var measuredHeight: CGFloat = 240
    @State private var isRendering = true
    @State private var renderError: String? = nil
    @State private var showSource = false
    @State private var showFullscreen = false
    @State private var copied = false

    private var cacheKey: String {
        MermaidHeightCache.cacheKey(code: code, isDark: colorScheme == .dark)
    }

    private var showsSourceMode: Bool {
        showSource || renderError != nil
    }

    private var isClippedVertically: Bool {
        measuredHeight > 680
    }

    private var displayCardHeight: CGFloat {
        min(max(measuredHeight, 140), 680)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBar

            if showsSourceMode {
                sourceView
            } else {
                diagramView
            }
        }
        .cardSurface(radius: 16)
        .onAppear {
            if let cached = MermaidHeightCache.shared.height(for: cacheKey) {
                measuredHeight = cached
            }
        }
        .onChange(of: cacheKey) { _, _ in
            renderError = nil
            isRendering = true
            if let cached = MermaidHeightCache.shared.height(for: cacheKey) {
                measuredHeight = cached
            }
        }
        .fullScreenCover(isPresented: $showFullscreen) {
            MermaidFullscreenSheet(code: code, tint: tint)
        }
    }

    private var headerBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 10.5, weight: .bold))
                Text("mermaid")
                    .font(RelayFont.mono(11, weight: .semibold))
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3.5)
            .background(Capsule().fill(tint.opacity(0.12)))

            if isRendering && !showsSourceMode {
                ProgressView()
                    .controlSize(.mini)
            }

            Spacer(minLength: 6)

            if renderError == nil {
                Button {
                    Haptics.selection()
                    withAnimation(.snappy(duration: 0.22)) {
                        showSource.toggle()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: showSource ? "rectangle.3.group" : "chevron.left.forwardslash.chevron.right")
                            .font(.system(size: 10.5, weight: .semibold))
                        Text(showSource ? "图表" : "源码")
                    }
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Palette.textSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Palette.fieldFill))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(showSource ? "切换到图表" : "查看源码")

                if !showSource {
                    Button {
                        Haptics.tap(.soft)
                        showFullscreen = true
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(Palette.textSecondary)
                            .frame(width: 28, height: 26)
                            .background(Capsule().fill(Palette.fieldFill))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("全屏查看图表")
                }
            }

            Button(action: copySource) {
                HStack(spacing: 4) {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .contentTransition(.symbolEffect(.replace))
                    Text(copied ? "已复制" : "复制")
                }
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(copied ? Palette.success : Palette.textSecondary)
                .padding(.vertical, 4)
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("复制 Mermaid 源码")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Palette.fieldFill.opacity(0.45))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Palette.hairline)
                .frame(height: 0.6)
        }
    }

    private var diagramView: some View {
        ZStack(alignment: .bottomTrailing) {
            MermaidWebViewRepresentable(
                code: code,
                isDark: colorScheme == .dark,
                interactive: false,
                onHeightChange: { newHeight in
                    let sanitized = min(max(newHeight, 120), 2800)
                    MermaidHeightCache.shared.store(sanitized, for: cacheKey)
                    if abs(sanitized - measuredHeight) >= 2 {
                        measuredHeight = sanitized
                    }
                },
                onRendered: {
                    isRendering = false
                    renderError = nil
                },
                onError: { err in
                    isRendering = false
                    renderError = err
                }
            )
            .frame(maxWidth: .infinity)
            .frame(height: displayCardHeight)

            Button {
                Haptics.tap(.soft)
                showFullscreen = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "viewfinder")
                        .font(.system(size: 10.5, weight: .semibold))
                    Text(isClippedVertically ? "放大查看全图" : "全屏查看")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(Palette.textPrimary)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(
                    Capsule().stroke(Palette.hairlineStrong, lineWidth: 0.6)
                )
            }
            .buttonStyle(.plain)
            .padding(10)
        }
    }

    private var sourceView: some View {
        VStack(alignment: .leading, spacing: 0) {
            if renderError != nil {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.warning)
                    Text("图表渲染失败，已切换至源码")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.78))
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.top, 10)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                Text(SyntaxHighlighter.highlight(code, language: "mermaid"))
                    .font(RelayFont.mono(13.5))
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .padding(14)
            }
        }
        .background(Palette.codeBackground)
        .environment(\.colorScheme, .dark)
    }

    private func copySource() {
        UIPasteboard.general.string = code
        Haptics.success()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { copied = true }
        Task {
            try? await Task.sleep(for: .milliseconds(1600))
            withAnimation(.easeOut(duration: 0.2)) { copied = false }
        }
    }
}

// MARK: - Fullscreen zoomable Mermaid sheet

private struct MermaidFullscreenSheet: View {
    let code: String
    let tint: Color

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var copied = false
    @State private var isRendering = true
    @State private var renderError: String? = nil

    var body: some View {
        ZStack(alignment: .top) {
            (colorScheme == .dark ? Color(hex: 0x0F1016) : Color(hex: 0xF7F6F2))
                .ignoresSafeArea()

            if let renderError {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("图表渲染失败：\(renderError)", systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(Palette.warning)
                        CodeBlockCard(language: "mermaid", code: code)
                    }
                    .padding(.top, 80)
                    .padding(.horizontal, 16)
                }
            } else {
                MermaidWebViewRepresentable(
                    code: code,
                    isDark: colorScheme == .dark,
                    interactive: true,
                    onHeightChange: { _ in },
                    onRendered: { isRendering = false },
                    onError: { err in
                        isRendering = false
                        renderError = err
                    }
                )
                .ignoresSafeArea(edges: .bottom)
            }

            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(tint)
                    Text("架构拓扑图")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Palette.textPrimary)
                    if isRendering && renderError == nil {
                        ProgressView()
                            .controlSize(.mini)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().stroke(Palette.hairline, lineWidth: 0.6))

                Spacer()

                Button {
                    UIPasteboard.general.string = code
                    Haptics.success()
                    withAnimation { copied = true }
                    Task {
                        try? await Task.sleep(for: .milliseconds(1500))
                        withAnimation { copied = false }
                    }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(copied ? Palette.success : Palette.textPrimary)
                        .frame(width: 36, height: 36)
                        .background(.ultraThinMaterial, in: Circle())
                        .overlay(Circle().stroke(Palette.hairline, lineWidth: 0.6))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("复制源码")

                Button {
                    Haptics.tap()
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Palette.textPrimary)
                        .frame(width: 36, height: 36)
                        .background(.ultraThinMaterial, in: Circle())
                        .overlay(Circle().stroke(Palette.hairline, lineWidth: 0.6))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭")
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
        }
    }
}

// MARK: - WKWebView representable

private struct MermaidWebViewRepresentable: UIViewRepresentable {
    let code: String
    let isDark: Bool
    let interactive: Bool
    var onHeightChange: (CGFloat) -> Void
    var onRendered: () -> Void
    var onError: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onHeightChange: onHeightChange,
            onRendered: onRendered,
            onError: onError
        )
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.setURLSchemeHandler(context.coordinator.schemeHandler, forURLScheme: "relay-mermaid")

        let weakHandler = WeakMermaidMessageHandler(context.coordinator)
        config.userContentController.add(weakHandler, name: "mermaidLayout")
        config.userContentController.add(weakHandler, name: "mermaidError")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear

        if interactive {
            webView.scrollView.isScrollEnabled = true
            webView.scrollView.bounces = true
            webView.scrollView.bouncesZoom = true
            webView.scrollView.minimumZoomScale = 0.5
            webView.scrollView.maximumZoomScale = 6.0
            webView.scrollView.showsVerticalScrollIndicator = true
            webView.scrollView.showsHorizontalScrollIndicator = true
            webView.scrollView.contentInsetAdjustmentBehavior = .always
        } else {
            webView.scrollView.isScrollEnabled = false
            webView.scrollView.bounces = false
            webView.scrollView.showsVerticalScrollIndicator = false
            webView.scrollView.showsHorizontalScrollIndicator = false
            webView.scrollView.contentInsetAdjustmentBehavior = .never
        }

        loadIfNeeded(into: webView, coordinator: context.coordinator)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.onHeightChange = onHeightChange
        context.coordinator.onRendered = onRendered
        context.coordinator.onError = onError
        loadIfNeeded(into: webView, coordinator: context.coordinator)
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        let controller = webView.configuration.userContentController
        controller.removeScriptMessageHandler(forName: "mermaidLayout")
        controller.removeScriptMessageHandler(forName: "mermaidError")
        webView.navigationDelegate = nil
        webView.stopLoading()
        webView.loadHTMLString("", baseURL: nil)
    }

    private func loadIfNeeded(into webView: WKWebView, coordinator: Coordinator) {
        let signature = "\(code.hashValue)|\(code.utf8.count)|\(isDark ? 1 : 0)|\(interactive ? 1 : 0)"
        guard coordinator.lastSignature != signature else { return }
        coordinator.lastSignature = signature
        let html = Self.buildHTML(code: code, isDark: isDark, interactive: interactive)
        let baseURL = URL(string: "relay-mermaid://asset/")!
        coordinator.lastLoadedHTML = html
        coordinator.lastBaseURL = baseURL
        webView.loadHTMLString(html, baseURL: baseURL)
    }

    private static func buildHTML(code: String, isDark: Bool, interactive: Bool) -> String {
        let b64 = Data(code.utf8).base64EncodedString()
        let viewport = interactive
            ? "width=device-width, initial-scale=1.0, minimum-scale=0.5, maximum-scale=6.0, user-scalable=yes"
            : "width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no"

        let themeJSON: String
        if isDark {
            themeJSON = """
            {
              "darkMode": true,
              "background": "transparent",
              "primaryColor": "#1E2233",
              "primaryTextColor": "#F2F1EE",
              "primaryBorderColor": "#6C7CFF",
              "secondaryColor": "#1B2826",
              "secondaryTextColor": "#F2F1EE",
              "secondaryBorderColor": "#45C49E",
              "tertiaryColor": "#272133",
              "tertiaryTextColor": "#F2F1EE",
              "tertiaryBorderColor": "#A588FF",
              "lineColor": "#8C93B0",
              "textColor": "#F2F1EE",
              "mainBkg": "#1E2233",
              "nodeBorder": "#6C7CFF",
              "clusterBkg": "rgba(255, 255, 255, 0.04)",
              "clusterBorder": "rgba(255, 255, 255, 0.16)",
              "edgeLabelBackground": "#161822",
              "fontSize": "13.5px"
            }
            """
        } else {
            themeJSON = """
            {
              "darkMode": false,
              "background": "transparent",
              "primaryColor": "#F2F4FF",
              "primaryTextColor": "#16161A",
              "primaryBorderColor": "#5458D8",
              "secondaryColor": "#ECF8F3",
              "secondaryTextColor": "#16161A",
              "secondaryBorderColor": "#1D9A72",
              "tertiaryColor": "#F6F1FF",
              "tertiaryTextColor": "#16161A",
              "tertiaryBorderColor": "#7B5CD6",
              "lineColor": "#676B7E",
              "textColor": "#16161A",
              "mainBkg": "#FFFFFF",
              "nodeBorder": "#5458D8",
              "clusterBkg": "rgba(84, 88, 216, 0.04)",
              "clusterBorder": "rgba(22, 22, 26, 0.15)",
              "edgeLabelBackground": "#FAF9F5",
              "fontSize": "13.5px"
            }
            """
        }

        let useMaxWidthJS = interactive ? "false" : "true"
        let stagePadding = interactive ? "72px 24px 36px 24px" : "14px 12px 24px 12px"
        let stageMinWidth = interactive ? "width: max-content; min-width: 100%;" : "width: 100%;"
        let svgRules = interactive
            ? "display: block; margin: 0 auto;"
            : "display: block; max-width: 100%; height: auto; margin: 0 auto;"

        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="\(viewport)">
        <style>
          html, body {
            margin: 0;
            padding: 0;
            background: transparent;
            font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "PingFang SC", sans-serif;
            -webkit-text-size-adjust: 100%;
          }
          #stage {
            box-sizing: border-box;
            padding: \(stagePadding);
            \(stageMinWidth)
          }
          #stage svg {
            \(svgRules)
          }
          .edgeLabel rect {
            rx: 4px;
            ry: 4px;
          }
        </style>
        <script src="relay-mermaid://asset/mermaid.min.js"></script>
        </head>
        <body>
        <div id="stage"></div>
        <script>
        (function() {
          function decodeBase64UTF8(b64) {
            var bin = atob(b64);
            var bytes = new Uint8Array(bin.length);
            for (var i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
            return new TextDecoder("utf-8").decode(bytes);
          }
          var lastReported = 0;
          function reportHeight() {
            var stage = document.getElementById("stage");
            if (!stage) return;
            var rect = stage.getBoundingClientRect();
            var h = Math.ceil(Math.max(rect.height || 0, stage.scrollHeight || 0));
            if (h > 0 && Math.abs(h - lastReported) >= 2) {
              lastReported = h;
              try {
                window.webkit.messageHandlers.mermaidLayout.postMessage({ height: h, rendered: true });
              } catch (e) {}
            }
          }
          async function start() {
            try {
              if (!window.mermaid) {
                throw new Error("mermaid library not loaded");
              }
              var source = decodeBase64UTF8("\(b64)");
              window.mermaid.initialize({
                startOnLoad: false,
                securityLevel: "strict",
                theme: "base",
                fontFamily: '-apple-system, BlinkMacSystemFont, "SF Pro Text", "PingFang SC", sans-serif',
                flowchart: {
                  htmlLabels: true,
                  curve: "basis",
                  useMaxWidth: \(useMaxWidthJS),
                  padding: 14,
                  nodeSpacing: 34,
                  rankSpacing: 42
                },
                sequence: { useMaxWidth: \(useMaxWidthJS) },
                state: { useMaxWidth: \(useMaxWidthJS) },
                er: { useMaxWidth: \(useMaxWidthJS) },
                gantt: { useMaxWidth: \(useMaxWidthJS) },
                themeVariables: \(themeJSON)
              });
              var renderId = "mmd-" + Date.now() + "-" + Math.floor(Math.random() * 10000);
              var result = await window.mermaid.render(renderId, source);
              var stage = document.getElementById("stage");
              stage.innerHTML = result.svg || "";
              if (typeof result.bindFunctions === "function") {
                result.bindFunctions(stage);
              }
              var svg = stage.querySelector("svg");
              if (svg && !\(interactive ? "true" : "false")) {
                svg.style.maxWidth = "100%";
                svg.style.height = "auto";
                svg.style.display = "block";
                svg.style.margin = "0 auto";
              }
              window.webkit.messageHandlers.mermaidLayout.postMessage({ height: Math.ceil(stage.getBoundingClientRect().height), rendered: true });
              if (typeof ResizeObserver !== "undefined") {
                var ro = new ResizeObserver(function() { reportHeight(); });
                ro.observe(stage);
              }
              requestAnimationFrame(reportHeight);
              setTimeout(reportHeight, 100);
            } catch (err) {
              var msg = (err && err.message) ? String(err.message) : String(err || "unknown error");
              try {
                window.webkit.messageHandlers.mermaidError.postMessage(msg);
              } catch (e2) {}
            }
          }
          if (document.readyState === "loading") {
            document.addEventListener("DOMContentLoaded", start);
          } else {
            start();
          }
        })();
        </script>
        </body>
        </html>
        """
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        let schemeHandler = MermaidAssetSchemeHandler()
        var onHeightChange: (CGFloat) -> Void
        var onRendered: () -> Void
        var onError: (String) -> Void
        var lastSignature = ""
        var lastLoadedHTML = ""
        var lastBaseURL: URL? = nil
        private var reloadTimestamps: [Date] = []

        init(
            onHeightChange: @escaping (CGFloat) -> Void,
            onRendered: @escaping () -> Void,
            onError: @escaping (String) -> Void
        ) {
            self.onHeightChange = onHeightChange
            self.onRendered = onRendered
            self.onError = onError
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            switch message.name {
            case "mermaidLayout":
                if let dict = message.body as? [String: Any] {
                    let rawHeight = (dict["height"] as? NSNumber)?.doubleValue
                    let rendered = (dict["rendered"] as? Bool) ?? false
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        if rendered { self.onRendered() }
                        if let rawHeight, rawHeight.isFinite, rawHeight > 0 {
                            self.onHeightChange(CGFloat(rawHeight))
                        }
                    }
                }
            case "mermaidError":
                let text = (message.body as? String) ?? "Mermaid 渲染异常"
                Task { @MainActor [weak self] in
                    self?.onError(text)
                }
            default:
                break
            }
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction
        ) async -> WKNavigationActionPolicy {
            if navigationAction.navigationType == .linkActivated {
                return .cancel
            }
            return .allow
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            guard !lastLoadedHTML.isEmpty else { return }
            let now = Date()
            reloadTimestamps.removeAll { now.timeIntervalSince($0) > 30 }
            guard reloadTimestamps.count < 3 else { return }
            reloadTimestamps.append(now)
            webView.loadHTMLString(lastLoadedHTML, baseURL: lastBaseURL)
        }
    }
}
