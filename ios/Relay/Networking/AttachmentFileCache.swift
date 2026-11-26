import Foundation

/// Downloads and materializes non-image attachments to local temporary files for `QuickLook` preview.
@MainActor
final class AttachmentFileCache {
    static let shared = AttachmentFileCache()

    private var inflight: [String: Task<URL, Error>] = [:]

    private init() {}

    func localPreviewURL(for attachment: Attachment, api: RelayAPI) async throws -> URL {
        let previewRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("RelayPreviews", isDirectory: true)
            .appendingPathComponent(safeComponent(attachment.id), isDirectory: true)
        let safeFilename = Self.sanitizedFilename(attachment.filename, mimeType: attachment.mimeType)
        let targetURL = previewRoot.appendingPathComponent(safeFilename)

        if FileManager.default.fileExists(atPath: targetURL.path) {
            return targetURL
        }
        if let running = inflight[attachment.id] {
            return try await running.value
        }

        let task = Task.detached(priority: .userInitiated) { () async throws -> URL in
            let diskKey = "att:\(attachment.id)"
            let data: Data
            if let disk = await RelayDiskCache.shared.loadAsset(key: diskKey) {
                data = disk.data
            } else {
                data = try await api.uploadData(id: attachment.id)
                await RelayDiskCache.shared.saveAsset(key: diskKey, data: data, mimeType: attachment.mimeType)
            }
            try FileManager.default.createDirectory(at: previewRoot, withIntermediateDirectories: true)
            try data.write(to: targetURL, options: [.atomic])
            return targetURL
        }
        inflight[attachment.id] = task
        defer {
            if inflight[attachment.id] == task {
                inflight[attachment.id] = nil
            }
        }
        return try await task.value
    }

    func clear() {
        for (_, task) in inflight { task.cancel() }
        inflight.removeAll()
        let previewRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("RelayPreviews", isDirectory: true)
        try? FileManager.default.removeItem(at: previewRoot)
    }

    private func safeComponent(_ raw: String) -> String {
        let cleaned = raw.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "-" ? Character($0) : "_" }
        let s = String(cleaned)
        return s.isEmpty ? "file" : s
    }

    private nonisolated static func sanitizedFilename(_ raw: String, mimeType: String) -> String {
        let base = (raw as NSString).lastPathComponent
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !base.isEmpty {
            return base
        }
        if mimeType == "application/pdf" { return "attachment.pdf" }
        if mimeType.hasPrefix("text/") { return "attachment.txt" }
        return "attachment.bin"
    }
}
