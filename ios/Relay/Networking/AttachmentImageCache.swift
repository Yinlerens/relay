import SwiftUI
import UIKit

/// Authenticated attachment image cache (`NSCache` + Bearer). Not `AsyncImage`, which can't send auth headers.
@MainActor
final class AttachmentImageCache {
    static let shared = AttachmentImageCache()

    private let cache = NSCache<NSString, UIImage>()
    private var inflight: [String: Task<UIImage?, Never>] = [:]

    private init() {
        cache.countLimit = 160
        cache.totalCostLimit = 128 * 1024 * 1024
    }

    func cached(_ id: String) -> UIImage? {
        cache.object(forKey: id as NSString)
    }

    /// Seed with the locally-picked image so freshly sent thumbnails render instantly.
    func store(_ image: UIImage, for id: String) {
        cache.setObject(image, forKey: id as NSString, cost: Self.cost(of: image))
    }

    func clear() {
        cache.removeAllObjects()
        for (_, task) in inflight { task.cancel() }
        inflight.removeAll()
    }

    func image(for id: String, api: RelayAPI) async -> UIImage? {
        if let hit = cached(id) { return hit }
        if let running = inflight[id] { return await running.value }

        let diskKey = "att:\(id)"
        let task = Task.detached(priority: .userInitiated) { () async -> UIImage? in
            if let disk = await RelayDiskCache.shared.loadAsset(key: diskKey),
               let img = UIImage(data: disk.data) {
                return await img.byPreparingForDisplay() ?? img
            }
            guard let data = try? await api.uploadData(id: id), let image = UIImage(data: data) else {
                return nil
            }
            await RelayDiskCache.shared.saveAsset(key: diskKey, data: data, mimeType: nil)
            return await image.byPreparingForDisplay() ?? image
        }
        inflight[id] = task
        let result = await task.value
        if inflight[id] == task {
            inflight[id] = nil
        }
        if let result {
            store(result, for: id)
        }
        return result
    }

    private static func cost(of image: UIImage) -> Int {
        let pixels = image.size.width * image.size.height * image.scale * image.scale
        return Int(pixels * 4)
    }
}

/// Thumbnail / full image view backed by `AttachmentImageCache`.
struct AuthImageView: View {
    @Environment(AppStore.self) private var store
    var attachmentId: String
    var contentMode: ContentMode = .fill

    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .transition(.opacity)
            } else if failed {
                ZStack {
                    Palette.fieldFill
                    Image(systemName: "photo.badge.exclamationmark")
                        .font(.system(size: 18))
                        .foregroundStyle(Palette.textTertiary)
                }
            } else {
                ZStack {
                    Palette.fieldFill
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
        .task(id: attachmentId) {
            if let hit = AttachmentImageCache.shared.cached(attachmentId) {
                image = hit
                return
            }
            guard let api = store.api else { return }
            let loaded = await AttachmentImageCache.shared.image(for: attachmentId, api: api)
            withAnimation(.easeOut(duration: 0.25)) {
                image = loaded
                failed = loaded == nil
            }
        }
    }
}
