import CryptoKit
import SwiftUI
import UIKit

/// Memory + disk cache for KuroBBS / WaveShelf remote artwork (avatars, portraits, weapons, echoes).
@MainActor
final class WuwaImageCache {
    static let shared = WuwaImageCache()

    private let memory = NSCache<NSString, UIImage>()
    private var inflight: [String: Task<UIImage?, Never>] = [:]
    private let diskDir: URL

    private init() {
        memory.countLimit = 220
        memory.totalCostLimit = 96 * 1024 * 1024
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        self.diskDir = caches.appendingPathComponent("WuwaArtCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: diskDir, withIntermediateDirectories: true)
    }

    func cached(_ urlString: String) -> UIImage? {
        memory.object(forKey: urlString as NSString)
    }

    func image(for urlString: String) async -> UIImage? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed) else { return nil }
        if let hit = cached(trimmed) { return hit }
        if let running = inflight[trimmed] { return await running.value }

        let fileURL = diskFileURL(for: trimmed)
        let task = Task.detached(priority: .userInitiated) { () async -> UIImage? in
            if let data = try? Data(contentsOf: fileURL),
               let img = UIImage(data: data) {
                return await img.byPreparingForDisplay() ?? img
            }
            var req = URLRequest(url: url)
            req.timeoutInterval = 18
            guard let (data, resp) = try? await URLSession.shared.data(for: req),
                  let http = resp as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let img = UIImage(data: data) else {
                return nil
            }
            try? data.write(to: fileURL, options: [.atomic])
            return await img.byPreparingForDisplay() ?? img
        }
        inflight[trimmed] = task
        let result = await task.value
        if inflight[trimmed] == task {
            inflight[trimmed] = nil
        }
        if let result {
            let pixels = result.size.width * result.size.height * result.scale * result.scale
            memory.setObject(result, forKey: trimmed as NSString, cost: Int(pixels * 4))
        }
        return result
    }

    func clear() {
        memory.removeAllObjects()
        for (_, task) in inflight { task.cancel() }
        inflight.removeAll()
        try? FileManager.default.removeItem(at: diskDir)
        try? FileManager.default.createDirectory(at: diskDir, withIntermediateDirectories: true)
    }

    private func diskFileURL(for key: String) -> URL {
        let hex = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return diskDir.appendingPathComponent("\(hex).img")
    }
}

struct WuwaRemoteImage: View {
    var urlString: String
    var fallbackText: String
    var tint: Color = Palette.textSecondary
    var contentMode: ContentMode = .fill

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                ZStack {
                    tint.opacity(0.18)
                    Text(String(fallbackText.prefix(1)))
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(tint)
                }
            }
        }
        .task(id: urlString) {
            if let hit = WuwaImageCache.shared.cached(urlString) {
                image = hit
                return
            }
            let loaded = await WuwaImageCache.shared.image(for: urlString)
            if let loaded {
                withAnimation(.easeOut(duration: 0.18)) {
                    image = loaded
                }
            }
        }
    }
}
