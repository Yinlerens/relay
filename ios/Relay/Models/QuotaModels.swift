import Foundation

// MARK: - GET /api/quotas

/// `{ updatedAt, antigravity, codebuddy }`
struct QuotaOverview: Decodable, Sendable {
    var updatedAt: Double
    var antigravity: AntigravityQuota?
    var codebuddy: CodeBuddyUsage?

    enum CodingKeys: String, CodingKey { case updatedAt, antigravity, codebuddy }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        updatedAt = c.flexDouble(.updatedAt, default: Date().timeIntervalSince1970 * 1000)
        antigravity = try? c.decodeIfPresent(AntigravityQuota.self, forKey: .antigravity)
        codebuddy = try? c.decodeIfPresent(CodeBuddyUsage.self, forKey: .codebuddy)
    }

    var updatedDate: Date { Date(timeIntervalSince1970: updatedAt / 1000) }
}

// MARK: Antigravity

struct AntigravityQuota: Decodable, Sendable {
    var available: Bool
    var error: String?
    var description: String
    var remainingCredits: Double
    var upgradeUri: String?
    var groups: [QuotaGroup]

    enum CodingKeys: String, CodingKey { case available, error, description, remainingCredits, upgradeUri, groups }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        available = c.flexBool(.available)
        error = c.flexOptionalString(.error)
        description = c.flexString(.description)
        remainingCredits = c.flexDouble(.remainingCredits)
        upgradeUri = c.flexOptionalString(.upgradeUri)
        groups = c.flexArray(QuotaGroup.self, .groups)
    }

    var upgradeURL: URL? {
        guard let upgradeUri, !upgradeUri.isEmpty else { return nil }
        return URL(string: upgradeUri)
    }
}

struct QuotaGroup: Decodable, Identifiable, Sendable {
    var name: String
    var description: String
    var buckets: [QuotaBucket]
    var id: String { name }

    enum CodingKeys: String, CodingKey { case name, description, buckets }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = c.flexString(.name, default: "模型")
        description = c.flexString(.description)
        buckets = c.flexArray(QuotaBucket.self, .buckets)
    }
}

struct QuotaBucket: Decodable, Identifiable, Sendable {
    var id: String
    var name: String
    var description: String
    var window: String
    var remainingFraction: Double?
    var resetTime: String?

    enum CodingKeys: String, CodingKey { case id, name, description, window, remainingFraction, resetTime }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = c.flexString(.name, default: "限额")
        id = c.flexString(.id, default: name)
        description = c.flexString(.description)
        window = c.flexString(.window)
        remainingFraction = c.flexOptionalDouble(.remainingFraction)
        resetTime = c.flexOptionalString(.resetTime)
    }

    /// Clamped 0...1 remaining fraction (nil when the CLI did not report one).
    var fraction: Double? {
        guard let remainingFraction else { return nil }
        return min(1, max(0, remainingFraction))
    }

    var resetDate: Date? {
        guard let resetTime, !resetTime.isEmpty else { return nil }
        return QuotaDates.parseISO8601(resetTime)
    }

    /// Human window label: `5h` → 5 小时, `weekly` → 每周 …
    var windowLabel: String? {
        let w = window.lowercased()
        switch w {
        case "": return nil
        case "daily", "day", "1d", "24h": return "每日"
        case "weekly", "week", "7d": return "每周"
        case "monthly", "month", "30d": return "每月"
        default:
            if w.hasSuffix("h"), let hours = Int(w.dropLast()) { return "\(hours) 小时" }
            if w.hasSuffix("m"), let minutes = Int(w.dropLast()) { return "\(minutes) 分钟" }
            return window
        }
    }
}

// MARK: CodeBuddy

struct CodeBuddyUsage: Decodable, Sendable {
    var available: Bool
    var error: String?
    var todayCredits: Double
    var monthCredits: Double
    var totalCredits: Double
    var totalSavedCredits: Double
    var byModel: [CodeBuddyModelUsage]
    var rateQuotas: [CodeBuddyRateQuota]
    var consoleUrl: String?
    var note: String?

    enum CodingKeys: String, CodingKey {
        case available, error, todayCredits, monthCredits, totalCredits, totalSavedCredits
        case byModel, rateQuotas, consoleUrl, note
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        available = c.flexBool(.available)
        error = c.flexOptionalString(.error)
        todayCredits = c.flexDouble(.todayCredits)
        monthCredits = c.flexDouble(.monthCredits)
        totalCredits = c.flexDouble(.totalCredits)
        totalSavedCredits = c.flexDouble(.totalSavedCredits)
        byModel = c.flexArray(CodeBuddyModelUsage.self, .byModel)
        rateQuotas = c.flexArray(CodeBuddyRateQuota.self, .rateQuotas)
        consoleUrl = c.flexOptionalString(.consoleUrl)
        note = c.flexOptionalString(.note)
    }

    var consoleURL: URL {
        if let consoleUrl, let url = URL(string: consoleUrl), url.scheme != nil { return url }
        return URL(string: "https://copilot.tencent.com/console")!
    }
}

struct CodeBuddyModelUsage: Decodable, Identifiable, Sendable {
    var modelId: String
    var credits: Double
    var savedCredits: Double
    var calls: Int
    var totalTokens: Double
    var id: String { modelId }

    enum CodingKeys: String, CodingKey { case modelId, credits, savedCredits, calls, totalTokens }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        modelId = c.flexString(.modelId, default: "unknown")
        credits = c.flexDouble(.credits)
        savedCredits = c.flexDouble(.savedCredits)
        calls = c.flexInt(.calls)
        totalTokens = c.flexDouble(.totalTokens)
    }
}

struct CodeBuddyRateQuota: Decodable, Identifiable, Sendable {
    var model: String
    /// Usage percent of the current rate window (0–100).
    var percent: Double
    /// Reset time in epoch milliseconds.
    var resetAt: Double?
    var id: String { model }

    enum CodingKeys: String, CodingKey { case model, percent, resetAt }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        model = c.flexString(.model, default: "unknown")
        percent = c.flexDouble(.percent)
        resetAt = c.flexOptionalDouble(.resetAt)
    }

    /// Tolerates both a 0–100 percent and a 0–1 fraction coming straight from the CodeBuddy CLI.
    var usedFraction: Double {
        let fraction = (percent > 0 && percent < 1) ? percent : percent / 100
        return min(1, max(0, fraction))
    }

    var usedPercent: Int { Int((usedFraction * 100).rounded()) }

    var resetDate: Date? {
        guard let resetAt, resetAt > 0 else { return nil }
        // Tolerate seconds as well as milliseconds.
        let seconds = resetAt > 10_000_000_000 ? resetAt / 1000 : resetAt
        return Date(timeIntervalSince1970: seconds)
    }
}

// MARK: - Date helpers

enum QuotaDates {
    static func parseISO8601(_ text: String) -> Date? {
        if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text) {
            return date
        }
        return try? Date.ISO8601FormatStyle().parse(text)
    }

    /// `4小时41分后重置` / `2天3小时后重置` / `12分钟后重置`
    static func resetCountdown(to date: Date, now: Date = Date()) -> String {
        let seconds = Int(date.timeIntervalSince(now))
        guard seconds > 0 else { return "即将重置" }
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        if days > 0 {
            return hours > 0 ? "\(days)天\(hours)小时后重置" : "\(days)天后重置"
        }
        if hours > 0 {
            return minutes > 0 ? "\(hours)小时\(minutes)分后重置" : "\(hours)小时后重置"
        }
        return "\(max(1, minutes))分钟后重置"
    }
}
