import CryptoKit
import Foundation

/// Persistent local store in `Application Support/RelayWuwa/` for snapshots, resonator details,
/// echo history timelines (SHA-256 fingerprinted), and Convene pull history + backup JSON compatibility.
actor WuwaStorage {
    static let shared = WuwaStorage()

    private let fm = FileManager.default
    private let rootDir: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(directory: URL? = nil) {
        if let directory {
            self.rootDir = directory
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.rootDir = base.appendingPathComponent("RelayWuwa", isDirectory: true)
        }
    }

    private var detailsDir: URL { rootDir.appendingPathComponent("details", isDirectory: true) }
    private var historyDir: URL { rootDir.appendingPathComponent("history", isDirectory: true) }

    // MARK: - Community Snapshot & Details

    func loadSnapshot() -> WuwaCommunitySnapshot? {
        readJSON(WuwaCommunitySnapshot.self, from: rootDir.appendingPathComponent("snapshot.json"))
    }

    func saveSnapshot(_ snapshot: WuwaCommunitySnapshot) {
        writeJSON(snapshot, to: rootDir.appendingPathComponent("snapshot.json"))
    }

    func clearCommunityData() {
        try? fm.removeItem(at: rootDir.appendingPathComponent("snapshot.json"))
        try? fm.removeItem(at: detailsDir)
    }

    func loadAllDetails(gameRoleId: String) -> [Int: WuwaResonatorDetail] {
        let dir = detailsDir.appendingPathComponent(safeComponent(gameRoleId), isDirectory: true)
        guard let urls = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return [:]
        }
        var out: [Int: WuwaResonatorDetail] = [:]
        for url in urls where url.pathExtension == "json" {
            if let detail = readJSON(WuwaResonatorDetail.self, from: url) {
                out[detail.role.roleId] = detail
            }
        }
        return out
    }

    func loadDetail(gameRoleId: String, resonatorId: Int) -> WuwaResonatorDetail? {
        let file = detailURL(gameRoleId: gameRoleId, resonatorId: resonatorId)
        return readJSON(WuwaResonatorDetail.self, from: file)
    }

    @discardableResult
    func saveDetail(
        gameRoleId: String,
        detail: WuwaResonatorDetail,
        recordedAt: String? = nil
    ) -> [WuwaResonatorHistoryEntry] {
        let resonatorId = detail.role.roleId
        let timestamp = recordedAt ?? ISO8601DateFormatter().string(from: Date())
        let detailFile = detailURL(gameRoleId: gameRoleId, resonatorId: resonatorId)

        var history = loadHistory(gameRoleId: gameRoleId, resonatorId: resonatorId)
        let newFingerprint = Self.computeFingerprint(for: detail)

        if history.isEmpty, let oldDetail = readJSON(WuwaResonatorDetail.self, from: detailFile) {
            let oldFp = Self.computeFingerprint(for: oldDetail)
            history.insert(makeHistoryEntry(
                id: nextHistoryId(from: history),
                gameRoleId: gameRoleId,
                detail: oldDetail,
                fingerprint: oldFp,
                recordedAt: timestamp
            ), at: 0)
        }

        if history.first?.fingerprint != newFingerprint {
            let entry = makeHistoryEntry(
                id: nextHistoryId(from: history),
                gameRoleId: gameRoleId,
                detail: detail,
                fingerprint: newFingerprint,
                recordedAt: timestamp
            )
            history.insert(entry, at: 0)
            if history.count > 50 {
                history = Array(history.prefix(50))
            }
            writeJSON(history, to: historyURL(gameRoleId: gameRoleId, resonatorId: resonatorId))
        }

        writeJSON(detail, to: detailFile)
        return history
    }

    // MARK: - Echo History

    func loadHistory(gameRoleId: String, resonatorId: Int) -> [WuwaResonatorHistoryEntry] {
        let file = historyURL(gameRoleId: gameRoleId, resonatorId: resonatorId)
        return readJSON([WuwaResonatorHistoryEntry].self, from: file) ?? []
    }

    func loadAllHistories(gameRoleId: String) -> [Int: [WuwaResonatorHistoryEntry]] {
        let dir = historyDir.appendingPathComponent(safeComponent(gameRoleId), isDirectory: true)
        guard let urls = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return [:]
        }
        var out: [Int: [WuwaResonatorHistoryEntry]] = [:]
        for url in urls where url.pathExtension == "json" {
            if let rid = Int(url.deletingPathExtension().lastPathComponent),
               let entries = readJSON([WuwaResonatorHistoryEntry].self, from: url),
               !entries.isEmpty {
                out[rid] = entries
            }
        }
        return out
    }

    nonisolated static func computeFingerprint(for detail: WuwaResonatorDetail) -> String {
        let weaponPart: String
        if let w = detail.weapon {
            weaponPart = "\(w.weaponId):\(w.level):\(w.resonanceLevel)"
        } else {
            weaponPart = "0:0:0"
        }
        let echoParts = detail.echoes.map { echo in
            let mains = echo.mainProps.map { "\($0.name.trimmingCharacters(in: .whitespaces))=\($0.value.trimmingCharacters(in: .whitespaces))" }.joined(separator: ",")
            let subs = echo.subProps.map { "\($0.name.trimmingCharacters(in: .whitespaces))=\($0.value.trimmingCharacters(in: .whitespaces))" }.joined(separator: ",")
            return "\(echo.phantomId):\(echo.cost):\(echo.level):[\(mains)]:[\(subs)]"
        }.joined(separator: ";")
        let material = "lv=\(detail.role.level)|ch=\(detail.role.chainLevel)|wp=\(weaponPart)|ec=\(echoParts)"
        return SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func makeHistoryEntry(
        id: Int,
        gameRoleId: String,
        detail: WuwaResonatorDetail,
        fingerprint: String,
        recordedAt: String
    ) -> WuwaResonatorHistoryEntry {
        WuwaResonatorHistoryEntry(
            id: id,
            gameRoleId: gameRoleId,
            resonatorId: detail.role.roleId,
            fingerprint: fingerprint,
            recordedAt: recordedAt,
            level: detail.role.level,
            chainLevel: detail.role.chainLevel,
            weaponName: detail.weapon?.name ?? "",
            weaponLevel: detail.weapon?.level ?? 0,
            weaponResonanceLevel: detail.weapon?.resonanceLevel ?? 0,
            attributes: detail.attributes,
            echoes: detail.echoes,
            detail: detail
        )
    }

    private func nextHistoryId(from entries: [WuwaResonatorHistoryEntry]) -> Int {
        (entries.map(\.id).max() ?? 0) + 1
    }

    // MARK: - Pulls & Backup Import/Export

    func loadPulls() -> [WuwaPullRecord] {
        readJSON([WuwaPullRecord].self, from: rootDir.appendingPathComponent("pulls.json")) ?? []
    }

    @discardableResult
    func mergePulls(_ incoming: [WuwaPullRecord]) -> (all: [WuwaPullRecord], added: Int) {
        var byId: [String: WuwaPullRecord] = [:]
        for existing in loadPulls() {
            byId[existing.id] = existing
        }
        var added = 0
        for rec in incoming where byId[rec.id] == nil {
            byId[rec.id] = rec
            added += 1
        }
        let sorted = byId.values.sorted {
            if $0.pulledAt != $1.pulledAt { return $0.pulledAt > $1.pulledAt }
            if $0.occurrence != $1.occurrence { return $0.occurrence > $1.occurrence }
            return $0.id > $1.id
        }
        writeJSON(sorted, to: rootDir.appendingPathComponent("pulls.json"))
        return (sorted, added)
    }

    func exportBackupData() throws -> Data {
        let bundle = WuwaBackupBundle(
            schemaVersion: 1,
            exportedAt: ISO8601DateFormatter().string(from: Date()),
            pulls: loadPulls(),
            settings: [:],
            catalogStates: []
        )
        return try encoder.encode(bundle)
    }

    func importBackupData(_ data: Data) throws -> (all: [WuwaPullRecord], added: Int) {
        if let bundle = try? decoder.decode(WuwaBackupBundle.self, from: data) {
            return mergePulls(bundle.pulls)
        }
        if let rawPulls = try? decoder.decode([WuwaPullRecord].self, from: data) {
            return mergePulls(rawPulls)
        }
        throw WuwaAPIError.decodeError("备份文件不是有效的 WaveShelf 唤取 JSON 格式。")
    }

    // MARK: - Helpers

    private func detailURL(gameRoleId: String, resonatorId: Int) -> URL {
        detailsDir
            .appendingPathComponent(safeComponent(gameRoleId), isDirectory: true)
            .appendingPathComponent("\(resonatorId).json")
    }

    private func historyURL(gameRoleId: String, resonatorId: Int) -> URL {
        historyDir
            .appendingPathComponent(safeComponent(gameRoleId), isDirectory: true)
            .appendingPathComponent("\(resonatorId).json")
    }

    private func safeComponent(_ raw: String) -> String {
        let cleaned = raw.filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
        return cleaned.isEmpty ? "default" : cleaned
    }

    private func readJSON<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(T.self, from: data)
    }

    private func writeJSON<T: Encodable>(_ value: T, to url: URL) {
        let dir = url.deletingLastPathComponent()
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        if let data = try? encoder.encode(value) {
            try? data.write(to: url, options: [.atomic])
        }
    }
}
