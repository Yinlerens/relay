import SwiftUI
import UIKit
import WebKit

// MARK: - Authenticated Tavern image cache

@MainActor
final class TavernAssetCache {
    static let shared = TavernAssetCache()

    private let cache = NSCache<NSString, UIImage>()
    private var inflight: [String: Task<UIImage?, Never>] = [:]

    private init() {
        cache.countLimit = 220
        cache.totalCostLimit = 128 * 1024 * 1024
    }

    func cached(_ key: String) -> UIImage? {
        cache.object(forKey: key as NSString)
    }

    func store(_ image: UIImage, for key: String) {
        let pixels = image.size.width * image.size.height * image.scale * image.scale
        cache.setObject(image, forKey: key as NSString, cost: Int(pixels * 4))
    }

    func clear() {
        cache.removeAllObjects()
        for (_, task) in inflight { task.cancel() }
        inflight.removeAll()
    }

    func image(for pathOrUrl: String, api: RelayAPI) async -> UIImage? {
        let key = pathOrUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        if let hit = cached(key) { return hit }
        if let running = inflight[key] { return await running.value }

        let task = Task<UIImage?, Never> {
            guard let (data, _) = try? await api.tavernAssetData(pathOrRelativeUrl: key),
                  let decoded = UIImage(data: data) else {
                return nil
            }
            return await decoded.byPreparingForDisplay() ?? decoded
        }
        inflight[key] = task
        let result = await task.value
        inflight[key] = nil
        if let result {
            store(result, for: key)
        }
        return result
    }
}

// MARK: - Native SwiftUI Tavern image view

struct TavernAssetImageView: View {
    @Environment(AppStore.self) private var store
    var pathOrUrl: String?
    var fallbackText: String = ""
    var fallbackSymbol: String = "person.fill"
    var contentMode: ContentMode = .fill

    @State private var image: UIImage?
    @State private var failed = false

    private var cleanKey: String {
        (pathOrUrl ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .transition(.opacity)
            } else if failed || cleanKey.isEmpty {
                ZStack {
                    LinearGradient(
                        colors: [Color(hex: 0x2B283A).opacity(0.22), Color(hex: 0x6E73F0).opacity(0.16)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    if let first = fallbackText.trimmingCharacters(in: .whitespacesAndNewlines).first {
                        Text(String(first).uppercased())
                            .font(RelayFont.display(17, weight: .semibold))
                            .foregroundStyle(Palette.textSecondary)
                    } else {
                        Image(systemName: fallbackSymbol)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(Palette.textTertiary)
                    }
                }
            } else {
                ZStack {
                    Palette.fieldFill
                    ProgressView()
                        .controlSize(.mini)
                }
            }
        }
        .task(id: cleanKey) {
            guard !cleanKey.isEmpty else {
                image = nil
                failed = true
                return
            }
            if let hit = TavernAssetCache.shared.cached(cleanKey) {
                image = hit
                failed = false
                return
            }
            guard let api = store.api else { return }
            failed = false
            let loaded = await TavernAssetCache.shared.image(for: cleanKey, api: api)
            withAnimation(.easeOut(duration: 0.22)) {
                image = loaded
                failed = loaded == nil
            }
        }
    }
}

// MARK: - Full-screen Tavern image viewer

struct TavernImageItem: Identifiable, Hashable {
    let id = UUID()
    let url: String
    let alt: String
}

struct TavernImageViewer: View {
    let item: TavernImageItem

    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var scale: CGFloat = 1
    @State private var baseScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var baseOffset: CGSize = .zero
    @State private var dismissDrag: CGFloat = 0
    @State private var chromeVisible = true

    private var backdropOpacity: Double {
        1 - min(Double(abs(dismissDrag)) / 500, 0.7)
    }

    var body: some View {
        ZStack {
            Color.black
                .opacity(backdropOpacity)
                .ignoresSafeArea()

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(scale)
                    .offset(x: offset.width, y: offset.height + dismissDrag)
                    .gesture(magnify.simultaneously(with: drag))
                    .onTapGesture(count: 2) {
                        Haptics.tap(.soft)
                        withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
                            if scale > 1.01 {
                                resetZoom()
                            } else {
                                scale = 2.5
                                baseScale = 2.5
                            }
                        }
                    }
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.2)) { chromeVisible.toggle() }
                    }
                    .ignoresSafeArea()
                    .transition(.opacity)
            } else {
                ProgressView()
                    .tint(.white)
                    .controlSize(.large)
            }
        }
        .overlay(alignment: .topTrailing) {
            if chromeVisible {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 42, height: 42)
                        .glassCircle()
                }
                .buttonStyle(.pressable)
                .padding(.trailing, 18)
                .padding(.top, 8)
                .transition(.opacity)
                .accessibilityLabel("关闭")
            }
        }
        .overlay(alignment: .bottom) {
            if chromeVisible {
                HStack(spacing: 12) {
                    Text(item.alt.isEmpty ? "图片预览" : item.alt)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let image {
                        ShareLink(
                            item: Image(uiImage: image),
                            preview: SharePreview(item.alt.isEmpty ? "酒馆图片" : item.alt, image: Image(uiImage: image))
                        ) {
                            Image(systemName: "square.and.arrow.up")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                    }
                }
                .padding(.horizontal, 18)
                .frame(height: 44)
                .glassCapsule()
                .padding(.bottom, 16)
                .transition(.opacity)
            }
        }
        .environment(\.colorScheme, .dark)
        .statusBarHidden(!chromeVisible)
        .task(id: item.url) {
            if let cached = TavernAssetCache.shared.cached(item.url) {
                image = cached
                return
            }
            guard let api = store.api else { return }
            let loaded = await TavernAssetCache.shared.image(for: item.url, api: api)
            withAnimation(.easeOut(duration: 0.25)) { image = loaded }
        }
    }

    private var magnify: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                scale = min(max(baseScale * value.magnification, 1), 6)
            }
            .onEnded { _ in
                baseScale = scale
                if scale <= 1.01 {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.82)) { resetZoom() }
                }
            }
    }

    private var drag: some Gesture {
        DragGesture()
            .onChanged { value in
                if scale > 1.01 {
                    offset = CGSize(
                        width: baseOffset.width + value.translation.width,
                        height: baseOffset.height + value.translation.height
                    )
                } else {
                    dismissDrag = value.translation.height
                }
            }
            .onEnded { value in
                if scale > 1.01 {
                    baseOffset = offset
                } else if abs(value.translation.height) > 140 || abs(value.predictedEndTranslation.height) > 420 {
                    Haptics.tap(.soft)
                    dismiss()
                } else {
                    withAnimation(.spring(response: 0.36, dampingFraction: 0.8)) { dismissDrag = 0 }
                }
            }
    }

    private func resetZoom() {
        scale = 1
        baseScale = 1
        offset = .zero
        baseOffset = .zero
    }
}

// MARK: - WKURLSchemeHandler for `relay-st://asset?path=...`

/// Proxies SillyTavern assets inside `WKWebView` using Bearer auth without ever embedding tokens in HTML.
final class TavernAssetSchemeHandler: NSObject, WKURLSchemeHandler {
    private let api: RelayAPI
    private var activeTasks: [ObjectIdentifier: Task<Void, Never>] = [:]

    init(api: RelayAPI) {
        self.api = api
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let key = ObjectIdentifier(urlSchemeTask)
        let requestURL = urlSchemeTask.request.url ?? URL(string: "relay-st://asset")!
        let rawURL = requestURL.absoluteString
        let api = self.api

        let task = Task { [weak self] in
            do {
                let (data, serverMime) = try await api.tavernAssetData(pathOrRelativeUrl: rawURL)
                await MainActor.run {
                    guard let self, self.activeTasks.removeValue(forKey: key) != nil, !Task.isCancelled else {
                        return
                    }
                    let cleanMime = Self.resolvedMime(serverMime: serverMime, rawURL: rawURL)
                    let headers: [String: String] = [
                        "Content-Type": cleanMime,
                        "Content-Length": "\(data.count)",
                        "Cache-Control": "private, max-age=3600",
                        "Access-Control-Allow-Origin": "*",
                    ]
                    let response: URLResponse = HTTPURLResponse(
                        url: requestURL,
                        statusCode: 200,
                        httpVersion: "HTTP/1.1",
                        headerFields: headers
                    ) ?? URLResponse(
                        url: requestURL,
                        mimeType: cleanMime,
                        expectedContentLength: data.count,
                        textEncodingName: cleanMime.hasPrefix("text/") ? "utf-8" : nil
                    )
                    urlSchemeTask.didReceive(response)
                    urlSchemeTask.didReceive(data)
                    urlSchemeTask.didFinish()
                }
            } catch {
                await MainActor.run {
                    guard let self, self.activeTasks.removeValue(forKey: key) != nil, !Task.isCancelled else {
                        return
                    }
                    urlSchemeTask.didFailWithError(error)
                }
            }
        }
        activeTasks[key] = task
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        let key = ObjectIdentifier(urlSchemeTask)
        activeTasks.removeValue(forKey: key)?.cancel()
    }

    private static func resolvedMime(serverMime: String?, rawURL: String) -> String {
        if let serverMime {
            let trimmed = serverMime.split(separator: ";").first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
            if !trimmed.isEmpty && trimmed != "application/octet-stream" {
                return trimmed
            }
        }
        let target = URLComponents(string: rawURL)?.queryItems?.first(where: { $0.name == "path" })?.value ?? rawURL
        let pathOnly = target.split(separator: "?").first.map(String.init) ?? target
        let ext = (pathOnly as NSString).pathExtension.lowercased()
        switch ext {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "webp": return "image/webp"
        case "gif": return "image/gif"
        case "svg": return "image/svg+xml"
        case "css": return "text/css"
        case "js", "mjs": return "application/javascript"
        case "woff2": return "font/woff2"
        case "woff": return "font/woff"
        case "ttf": return "font/ttf"
        case "mp3": return "audio/mpeg"
        case "ogg": return "audio/ogg"
        default: return "application/octet-stream"
        }
    }
}
