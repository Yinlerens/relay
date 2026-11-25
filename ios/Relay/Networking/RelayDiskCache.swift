import CryptoKit
import Foundation

// MARK: - Disk cache DTOs & stats

struct RelayCacheStats: Sendable, Equatable {
    let historyBytes: Int64
    let assetsBytes: Int64
    let agentBytes: Int64
    var totalBytes: Int64 { historyBytes + assetsBytes + agentBytes }
    let fileCount: Int

    static let empty = RelayCacheStats(historyBytes: 0, assetsBytes: 0, agentBytes: 0, fileCount: 0)
}

struct CachedTavernOverview: Codable, Sendable {
    var status: TavernStatus
    var characters: [TavernCharacter]
    var updatedAt: Double
}

struct CachedTavernConversation: Codable, Sendable {
    var characterId: Int
    var chatFile: String
    var character: TavernCharacter?
    var userName: String
    var messages: [TavernMessage]
    var variablesJSON: String
    var totalMessageCount: Int?
    var hasMore: Bool?
    var updatedAt: Double
}

struct CachedBootstrap: Codable, Sendable {
    var agents: [AgentInfo]
    var sessions: [SessionSummary]
    var swarms: [SwarmSummary]
    var defaultCwd: String
    var settings: ServerSettings
    var updatedAt: Double
}

struct CachedAgentSession: Codable, Sendable {
    var session: SessionSummary
    var messages: [Message]
    var updatedAt: Double
}

struct CachedSwarmDetail: Codable, Sendable {
    var swarm: SwarmSummary
    var messages: [SwarmBoardMessage]
    var updatedAt: Double
}

// MARK: - Unified per-server disk cache with LRU pruning

actor RelayDiskCache {
    static let shared = RelayDiskCache()

    private static let assetsSoftLimit: Int64 = 150 * 1024 * 1024
    private static let metadataSoftLimit: Int64 = 70 * 1024 * 1024

    private let fm = FileManager.default
    private let rootDir: URL
    private var serverKey: String = "default"
    private var writesSincePrune = 0

    private let encoder: JSONEncoder = {
        let enc = JSONEncoder()
        return enc
    }()

    private let decoder: JSONDecoder = {
        let dec = JSONDecoder()
        return dec
    }()

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        self.rootDir = caches.appendingPathComponent("RelayCache", isDirectory: true)
    }

    // MARK: Canonical helpers

    nonisolated static func sha256Hex(_ input: String) -> String {
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func normalizeChatFile(_ raw: String?) -> String {
        var s = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if s.lowercased().hasSuffix(".jsonl") {
            s = String(s.dropLast(6))
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Normalizes `relay-st://asset?path=...`, `/api/tavern/asset?path=...`, and raw relative ST paths
    /// onto a single cache key so native avatars and WebView cards share one disk file.
    nonisolated static func normalizeAssetKey(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("att:") || trimmed.hasPrefix("st:") || trimmed.hasPrefix("url:") || trimmed.hasPrefix("raw:") {
            return trimmed
        }
        if trimmed.lowercased().hasPrefix("http://") || trimmed.lowercased().hasPrefix("https://") {
            return "url:\(trimmed)"
        }
        if trimmed.lowercased().hasPrefix("relay-st://") {
            if let comps = URLComponents(string: trimmed) {
                if let p = comps.queryItems?.first(where: { $0.name == "path" })?.value, !p.isEmpty {
                    return "st:\(p.hasPrefix("/") ? p : "/" + p)"
                }
                if !comps.path.isEmpty && comps.path != "/" {
                    let full = (comps.percentEncodedQuery?.isEmpty == false)
                        ? "\(comps.path)?\(comps.percentEncodedQuery!)"
                        : comps.path
                    return "st:\(full)"
                }
            }
        }
        if trimmed.hasPrefix("/api/tavern/asset"),
           let comps = URLComponents(string: trimmed),
           let p = comps.queryItems?.first(where: { $0.name == "path" })?.value,
           !p.isEmpty {
            return "st:\(p.hasPrefix("/") ? p : "/" + p)"
        }
        if trimmed.hasPrefix("/") {
            return "st:\(trimmed)"
        }
        return "raw:\(trimmed)"
    }

    nonisolated static func conversationMemoryKey(characterId: Int, chatFile: String?) -> String {
        "\(characterId)|\(normalizeChatFile(chatFile))"
    }

    // MARK: Server scoping

    func setServerURL(_ rawURL: String) {
        let normalized = RelayAPI.normalizedBaseURL(from: rawURL)?.absoluteString
            ?? rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        serverKey = normalized.isEmpty ? "default" : Self.sha256Hex(normalized.lowercased())
    }

    private var serverDir: URL {
        rootDir.appendingPathComponent(serverKey, isDirectory: true)
    }

    private var tavernDir: URL { serverDir.appendingPathComponent("tavern", isDirectory: true) }
    private var tavernChatsDir: URL { tavernDir.appendingPathComponent("chats", isDirectory: true) }
    private var tavernHistoryDir: URL { tavernDir.appendingPathComponent("history", isDirectory: true) }
    private var assetsDir: URL { serverDir.appendingPathComponent("assets", isDirectory: true) }
    private var agentDir: URL { serverDir.appendingPathComponent("agent", isDirectory: true) }
    private var agentSessionsDir: URL { agentDir.appendingPathComponent("sessions", isDirectory: true) }
    private var agentSwarmsDir: URL { agentDir.appendingPathComponent("swarms", isDirectory: true) }

    // MARK: Tavern cache

    func loadTavernOverview() -> CachedTavernOverview? {
        readJSON(CachedTavernOverview.self, from: tavernDir.appendingPathComponent("characters.json"))
    }

    func saveTavernOverview(_ overview: CachedTavernOverview) {
        writeJSON(overview, to: tavernDir.appendingPathComponent("characters.json"))
    }

    func loadTavernChats(characterId: Int) -> [TavernChatFile]? {
        readJSON([TavernChatFile].self, from: tavernChatsDir.appendingPathComponent("\(characterId).json"))
    }

    func saveTavernChats(_ chats: [TavernChatFile], characterId: Int) {
        writeJSON(chats, to: tavernChatsDir.appendingPathComponent("\(characterId).json"))
    }

    func loadLatestChatByChar() -> [Int: String] {
        readJSON([Int: String].self, from: tavernDir.appendingPathComponent("latest_chat_by_char.json")) ?? [:]
    }

    func saveLatestChatByChar(_ map: [Int: String]) {
        writeJSON(map, to: tavernDir.appendingPathComponent("latest_chat_by_char.json"))
    }

    func loadTavernConversation(characterId: Int, chatFile: String) -> CachedTavernConversation? {
        let norm = Self.normalizeChatFile(chatFile)
        guard !norm.isEmpty else { return nil }
        let file = tavernHistoryDir.appendingPathComponent("\(Self.sha256Hex("\(characterId)|\(norm)")).json")
        return readJSON(CachedTavernConversation.self, from: file)
    }

    func saveTavernConversation(_ conversation: CachedTavernConversation) {
        let norm = Self.normalizeChatFile(conversation.chatFile)
        guard !norm.isEmpty else { return }
        let file = tavernHistoryDir.appendingPathComponent("\(Self.sha256Hex("\(conversation.characterId)|\(norm)")).json")
        writeJSON(conversation, to: file)
    }

    func loadHTMLHeights() -> [String: Double] {
        readJSON([String: Double].self, from: tavernDir.appendingPathComponent("html_heights.json")) ?? [:]
    }

    func saveHTMLHeights(_ heights: [String: Double]) {
        writeJSON(heights, to: tavernDir.appendingPathComponent("html_heights.json"))
    }

    // MARK: Asset cache (Tavern assets + Agent attachment images)

    func loadAsset(key rawKey: String) -> (data: Data, mimeType: String?)? {
        let hash = Self.sha256Hex(Self.normalizeAssetKey(rawKey))
        let binURL = assetsDir.appendingPathComponent("\(hash).bin")
        guard let data = try? Data(contentsOf: binURL), !data.isEmpty else { return nil }
        touch(binURL)
        let mimeURL = assetsDir.appendingPathComponent("\(hash).mime")
        let mime = (try? String(contentsOf: mimeURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (data, (mime?.isEmpty == false) ? mime : nil)
    }

    func saveAsset(key rawKey: String, data: Data, mimeType: String?) {
        guard !data.isEmpty else { return }
        let hash = Self.sha256Hex(Self.normalizeAssetKey(rawKey))
        let binURL = assetsDir.appendingPathComponent("\(hash).bin")
        let mimeURL = assetsDir.appendingPathComponent("\(hash).mime")
        writeRaw(data, to: binURL)
        if let mimeType, !mimeType.isEmpty, let mimeData = mimeType.data(using: .utf8) {
            writeRaw(mimeData, to: mimeURL, countForPrune: false)
        }
    }

    // MARK: Agent & Swarm cache

    func loadBootstrap() -> CachedBootstrap? {
        readJSON(CachedBootstrap.self, from: agentDir.appendingPathComponent("bootstrap.json"))
    }

    func saveBootstrap(_ boot: CachedBootstrap) {
        writeJSON(boot, to: agentDir.appendingPathComponent("bootstrap.json"))
    }

    func loadAgentSession(id: String) -> CachedAgentSession? {
        let file = agentSessionsDir.appendingPathComponent("\(safeFileComponent(id)).json")
        return readJSON(CachedAgentSession.self, from: file)
    }

    func saveAgentSession(_ cached: CachedAgentSession) {
        let file = agentSessionsDir.appendingPathComponent("\(safeFileComponent(cached.session.id)).json")
        writeJSON(cached, to: file)
    }

    func deleteAgentSession(id: String) {
        let file = agentSessionsDir.appendingPathComponent("\(safeFileComponent(id)).json")
        try? fm.removeItem(at: file)
    }

    func loadSwarmDetail(id: String) -> CachedSwarmDetail? {
        let file = agentSwarmsDir.appendingPathComponent("\(safeFileComponent(id)).json")
        return readJSON(CachedSwarmDetail.self, from: file)
    }

    func saveSwarmDetail(_ cached: CachedSwarmDetail) {
        let file = agentSwarmsDir.appendingPathComponent("\(safeFileComponent(cached.swarm.id)).json")
        writeJSON(cached, to: file)
    }

    func deleteSwarmDetail(id: String) {
        let file = agentSwarmsDir.appendingPathComponent("\(safeFileComponent(id)).json")
        try? fm.removeItem(at: file)
    }

    // MARK: Stats & Cleanup

    func computeStats() -> RelayCacheStats {
        let tavern = directoryUsage(tavernDir)
        let assets = directoryUsage(assetsDir)
        let agent = directoryUsage(agentDir)
        return RelayCacheStats(
            historyBytes: tavern.bytes,
            assetsBytes: assets.bytes,
            agentBytes: agent.bytes,
            fileCount: tavern.count + assets.count + agent.count
        )
    }

    func clearCurrentServer() {
        try? fm.removeItem(at: serverDir)
        writesSincePrune = 0
    }

    func clearAll() {
        try? fm.removeItem(at: rootDir)
        writesSincePrune = 0
    }

    // MARK: Low-level atomic IO & LRU pruning

    private func safeFileComponent(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let cleaned = raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let str = String(cleaned)
        return str.isEmpty ? Self.sha256Hex(raw) : str
    }

    private func readJSON<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        touch(url)
        return try? decoder.decode(T.self, from: data)
    }

    private func writeJSON<T: Encodable>(_ value: T, to url: URL) {
        guard let data = try? encoder.encode(value) else { return }
        writeRaw(data, to: url)
    }

    private func writeRaw(_ data: Data, to url: URL, countForPrune: Bool = true) {
        let dir = url.deletingLastPathComponent()
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try? data.write(to: url, options: [.atomic])
        guard countForPrune else { return }
        writesSincePrune += 1
        if writesSincePrune >= 24 {
            writesSincePrune = 0
            pruneIfNeeded()
        }
    }

    private func touch(_ url: URL) {
        try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    private func directoryUsage(_ dir: URL) -> (bytes: Int64, count: Int) {
        guard let enumerator = fm.enumerator(
            at: dir,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return (0, 0)
        }
        var bytes: Int64 = 0
        var count = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else { continue }
            bytes += Int64(values.fileSize ?? 0)
            count += 1
        }
        return (bytes, count)
    }

    private func pruneIfNeeded() {
        pruneBucket(directories: [assetsDir], limit: Self.assetsSoftLimit, pairMime: true)
        pruneBucket(directories: [tavernHistoryDir, tavernChatsDir, agentSessionsDir, agentSwarmsDir], limit: Self.metadataSoftLimit, pairMime: false)
    }

    private func pruneBucket(directories: [URL], limit: Int64, pairMime: Bool) {
        struct Entry {
            let url: URL
            let size: Int64
            let mtime: Date
        }
        var entries: [Entry] = []
        var total: Int64 = 0

        for dir in directories {
            guard let enumerator = fm.enumerator(
                at: dir,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for case let fileURL as URL in enumerator {
                if pairMime && fileURL.pathExtension == "mime" { continue }
                guard let vals = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]),
                      vals.isRegularFile == true else { continue }
                let size = Int64(vals.fileSize ?? 0)
                total += size
                entries.append(Entry(url: fileURL, size: size, mtime: vals.contentModificationDate ?? .distantPast))
            }
        }

        guard total > limit else { return }
        let target = Int64(Double(limit) * 0.82)
        entries.sort { $0.mtime < $1.mtime }

        for entry in entries {
            guard total > target else { break }
            try? fm.removeItem(at: entry.url)
            if pairMime && entry.url.pathExtension == "bin" {
                let mimeURL = entry.url.deletingPathExtension().appendingPathExtension("mime")
                try? fm.removeItem(at: mimeURL)
            }
            total -= entry.size
        }
    }
}
