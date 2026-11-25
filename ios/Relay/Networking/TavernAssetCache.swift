import SwiftUI
import UIKit
import WebKit

// MARK: - Authenticated Tavern image & raw asset L1+L2 cache

final class CachedRawAsset: NSObject, @unchecked Sendable {
    let data: Data
    let mimeType: String?

    init(data: Data, mimeType: String?) {
        self.data = data
        self.mimeType = mimeType
    }
}

@MainActor
final class TavernAssetCache {
    static let shared = TavernAssetCache()

    private let cache = NSCache<NSString, UIImage>()
    private let rawCache = NSCache<NSString, CachedRawAsset>()
    private var inflight: [String: Task<UIImage?, Never>] = [:]
    private var inflightRaw: [String: Task<(Data, String?), Error>] = [:]

    private init() {
        cache.countLimit = 220
        cache.totalCostLimit = 128 * 1024 * 1024
        rawCache.countLimit = 320
        rawCache.totalCostLimit = 48 * 1024 * 1024
    }

    func cached(_ key: String) -> UIImage? {
        let canonical = RelayDiskCache.normalizeAssetKey(key)
        return cache.object(forKey: canonical as NSString)
    }

    func store(_ image: UIImage, for key: String) {
        let canonical = RelayDiskCache.normalizeAssetKey(key)
        let pixels = image.size.width * image.size.height * image.scale * image.scale
        cache.setObject(image, forKey: canonical as NSString, cost: Int(pixels * 4))
    }

    func clear() {
        cache.removeAllObjects()
        rawCache.removeAllObjects()
        for (_, task) in inflight { task.cancel() }
        inflight.removeAll()
        for (_, task) in inflightRaw { task.cancel() }
        inflightRaw.removeAll()
    }

    /// Two-tier raw asset loader (48MB memory NSCache -> RelayDiskCache -> network) with concurrent deduplication.
    func rawAsset(for pathOrUrl: String, api: RelayAPI) async throws -> (data: Data, mimeType: String?) {
        let trimmed = pathOrUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw RelayAPIError.invalidURL }
        let canonical = RelayDiskCache.normalizeAssetKey(trimmed)

        if let hit = rawCache.object(forKey: canonical as NSString) {
            return (hit.data, hit.mimeType)
        }
        if let running = inflightRaw[canonical] {
            let value = try await running.value
            return (value.0, value.1)
        }

        let task = Task.detached(priority: .userInitiated) { () async throws -> (Data, String?) in
            if let disk = await RelayDiskCache.shared.loadAsset(key: canonical) {
                return (disk.data, disk.mimeType)
            }
            let fetched = try await api.tavernAssetData(pathOrRelativeUrl: trimmed)
            await RelayDiskCache.shared.saveAsset(key: canonical, data: fetched.data, mimeType: fetched.mimeType)
            return (fetched.data, fetched.mimeType)
        }
        inflightRaw[canonical] = task
        defer {
            if inflightRaw[canonical] == task {
                inflightRaw[canonical] = nil
            }
        }
        let result = try await task.value
        rawCache.setObject(CachedRawAsset(data: result.0, mimeType: result.1), forKey: canonical as NSString, cost: result.0.count)
        return (result.0, result.1)
    }

    func image(for pathOrUrl: String, api: RelayAPI) async -> UIImage? {
        let trimmed = pathOrUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let canonical = RelayDiskCache.normalizeAssetKey(trimmed)

        if let hit = cache.object(forKey: canonical as NSString) { return hit }
        if let running = inflight[canonical] { return await running.value }

        let task = Task.detached(priority: .userInitiated) { () async -> UIImage? in
            guard let (data, _) = try? await TavernAssetCache.shared.rawAsset(for: trimmed, api: api),
                  let decoded = UIImage(data: data) else {
                return nil
            }
            return await decoded.byPreparingForDisplay() ?? decoded
        }
        inflight[canonical] = task
        let result = await task.value
        if inflight[canonical] == task {
            inflight[canonical] = nil
        }
        if let result {
            store(result, for: canonical)
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

struct TavernImageItem: Identifiable, Hashable, Sendable {
    let id = UUID()
    let url: String
    let alt: String
    let sourceId: String

    init(url: String, alt: String, sourceId: String? = nil) {
        self.url = url
        self.alt = alt
        self.sourceId = sourceId ?? url
    }
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
    @State private var chromeVisible = true

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(scale)
                    .offset(offset)
                    .gesture(magnify)
                    .gesture(panDrag, isEnabled: scale > 1.01)
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
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
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

    private var panDrag: some Gesture {
        DragGesture()
            .onChanged { value in
                offset = CGSize(
                    width: baseOffset.width + value.translation.width,
                    height: baseOffset.height + value.translation.height
                )
            }
            .onEnded { _ in
                baseOffset = offset
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
@MainActor
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

        let task = Task { @MainActor [weak self] in
            do {
                let (data, serverMime) = try await TavernAssetCache.shared.rawAsset(for: rawURL, api: api)
                guard let self, self.activeTasks.removeValue(forKey: key) != nil, !Task.isCancelled else {
                    return
                }
                let resolved = Self.resolvedMime(serverMime: serverMime, rawURL: rawURL)
                let headers: [String: String] = [
                    "Content-Type": resolved.headerValue,
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
                    mimeType: resolved.mimeType,
                    expectedContentLength: data.count,
                    textEncodingName: resolved.isUTF8 ? "utf-8" : nil
                )
                urlSchemeTask.didReceive(response)
                urlSchemeTask.didReceive(data)
                urlSchemeTask.didFinish()
            } catch {
                guard let self, self.activeTasks.removeValue(forKey: key) != nil, !Task.isCancelled else {
                    return
                }
                urlSchemeTask.didFailWithError(error)
            }
        }
        activeTasks[key] = task
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        let key = ObjectIdentifier(urlSchemeTask)
        activeTasks.removeValue(forKey: key)?.cancel()
    }

    private static func resolvedMime(serverMime: String?, rawURL: String) -> (mimeType: String, headerValue: String, isUTF8: Bool) {
        let target = URLComponents(string: rawURL)?.queryItems?.first(where: { $0.name == "path" })?.value ?? rawURL
        let pathOnly = target.split(separator: "?").first.map(String.init) ?? target
        let ext = (pathOnly as NSString).pathExtension.lowercased()

        // Enforce strict web MIME types by extension so scripts/styles/SVGs/fonts execute cleanly in WKWebView.
        switch ext {
        case "js", "mjs":
            return ("application/javascript", "application/javascript; charset=utf-8", true)
        case "css":
            return ("text/css", "text/css; charset=utf-8", true)
        case "svg":
            return ("image/svg+xml", "image/svg+xml", true)
        case "woff2":
            return ("font/woff2", "font/woff2", false)
        case "woff":
            return ("font/woff", "font/woff", false)
        case "ttf":
            return ("font/ttf", "font/ttf", false)
        default:
            break
        }

        if let serverMime {
            let trimmed = serverMime.split(separator: ";").first.map { String($0).trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
            if !trimmed.isEmpty && trimmed != "application/octet-stream" && trimmed != "text/plain" {
                let utf8 = trimmed.hasPrefix("text/") || trimmed.contains("javascript") || trimmed.contains("json") || trimmed.contains("xml")
                return (trimmed, utf8 ? "\(trimmed); charset=utf-8" : trimmed, utf8)
            }
        }

        switch ext {
        case "png": return ("image/png", "image/png", false)
        case "jpg", "jpeg": return ("image/jpeg", "image/jpeg", false)
        case "webp": return ("image/webp", "image/webp", false)
        case "gif": return ("image/gif", "image/gif", false)
        case "json": return ("application/json", "application/json; charset=utf-8", true)
        case "mp3": return ("audio/mpeg", "audio/mpeg", false)
        case "ogg": return ("audio/ogg", "audio/ogg", false)
        default: return ("application/octet-stream", "application/octet-stream", false)
        }
    }
}
