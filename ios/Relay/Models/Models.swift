import Foundation

// MARK: - Flexible decoding helpers

extension KeyedDecodingContainer {
    func flexString(_ key: Key, default value: String = "") -> String {
        if let s = try? decodeIfPresent(String.self, forKey: key) { return s }
        if let i = try? decodeIfPresent(Int.self, forKey: key) { return String(i) }
        if let d = try? decodeIfPresent(Double.self, forKey: key) { return String(d) }
        return value
    }

    func flexOptionalString(_ key: Key) -> String? {
        if let s = try? decodeIfPresent(String.self, forKey: key) { return s }
        return nil
    }

    func flexDouble(_ key: Key, default value: Double = 0) -> Double {
        if let d = try? decodeIfPresent(Double.self, forKey: key) { return d }
        if let i = try? decodeIfPresent(Int.self, forKey: key) { return Double(i) }
        if let s = try? decodeIfPresent(String.self, forKey: key), let d = Double(s) { return d }
        return value
    }

    func flexOptionalDouble(_ key: Key) -> Double? {
        if let d = try? decodeIfPresent(Double.self, forKey: key) { return d }
        if let i = try? decodeIfPresent(Int.self, forKey: key) { return Double(i) }
        return nil
    }

    func flexInt(_ key: Key, default value: Int = 0) -> Int {
        Int(flexDouble(key, default: Double(value)))
    }

    func flexBool(_ key: Key, default value: Bool = false) -> Bool {
        if let b = try? decodeIfPresent(Bool.self, forKey: key) { return b }
        if let i = try? decodeIfPresent(Int.self, forKey: key) { return i != 0 }
        return value
    }

    func flexArray<T: Decodable>(_ type: T.Type, _ key: Key) -> [T] {
        (try? decodeIfPresent([T].self, forKey: key)) ?? []
    }
}

// MARK: - ConfigValue (String | Bool)

/// `ConfigOption.currentValue` is either a `String` (select) or a `Bool` (e.g. CodeBuddy `multitask: false`).
enum ConfigValue: Codable, Hashable, Sendable {
    case string(String)
    case bool(Bool)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .string("")
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let d = try? container.decode(Double.self) {
            self = .string(d == d.rounded() ? String(Int(d)) : String(d))
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "ConfigValue must be a String or a Bool"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .bool(let b): try container.encode(b)
        }
    }

    var stringValue: String {
        switch self {
        case .string(let s): return s
        case .bool(let b): return b ? "true" : "false"
        }
    }

    var boolValue: Bool {
        switch self {
        case .bool(let b): return b
        case .string(let s): return ["true", "1", "yes", "on"].contains(s.lowercased())
        }
    }
}

// MARK: - Agents

struct AgentInfo: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var subtitle: String
    var icon: String
    var accent: String

    enum CodingKeys: String, CodingKey { case id, name, subtitle, icon, accent }

    init(id: String, name: String, subtitle: String = "", icon: String = "", accent: String = "") {
        self.id = id
        self.name = name
        self.subtitle = subtitle
        self.icon = icon
        self.accent = accent
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.flexString(.id)
        name = c.flexString(.name, default: id)
        subtitle = c.flexString(.subtitle)
        icon = c.flexString(.icon)
        accent = c.flexString(.accent)
    }
}

// MARK: - Session metadata

struct ModelInfo: Codable, Identifiable, Hashable, Sendable {
    var modelId: String
    var name: String
    var description: String?
    var id: String { modelId }
}

struct ModeInfo: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var description: String?
}

struct ConfigChoice: Codable, Identifiable, Hashable, Sendable {
    var value: String
    var name: String
    var description: String?
    var id: String { value }
}

struct ConfigOption: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var description: String?
    var category: String?
    var type: String
    var currentValue: ConfigValue
    var options: [ConfigChoice]?

    enum CodingKeys: String, CodingKey { case id, name, description, category, type, currentValue, options }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.flexString(.id)
        name = c.flexString(.name, default: id)
        description = c.flexOptionalString(.description)
        category = c.flexOptionalString(.category)
        type = c.flexString(.type, default: "select")
        currentValue = (try? c.decodeIfPresent(ConfigValue.self, forKey: .currentValue)) ?? .string("")
        options = try? c.decodeIfPresent([ConfigChoice].self, forKey: .options)
    }

    var isBoolean: Bool { type == "boolean" }
    var choices: [ConfigChoice] { options ?? [] }
}

struct SlashCommand: Codable, Identifiable, Hashable, Sendable {
    var name: String
    var description: String
    var hint: String?
    var id: String { name }

    enum CodingKeys: String, CodingKey { case name, description, hint }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = c.flexString(.name)
        description = c.flexString(.description)
        hint = c.flexOptionalString(.hint)
    }
}

struct SessionSummary: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var agentId: String
    var acpSessionId: String?
    var title: String
    var cwd: String
    var currentModelId: String?
    var currentModeId: String?
    var availableModels: [ModelInfo]
    var availableModes: [ModeInfo]
    var configOptions: [ConfigOption]
    var availableCommands: [SlashCommand]
    var contextUsed: Int
    var contextSize: Int
    var isRunning: Bool
    var createdAt: Double
    var updatedAt: Double
    /// Sum of CodeBuddy credits charged across this session's assistant turns (server-computed, optional).
    var totalCredits: Double?
    /// Swarm membership metadata (nil for standalone sessions).
    var swarmId: String?
    var swarmRole: String?
    var swarmMemberName: String?
    var worktreeBranch: String?

    enum CodingKeys: String, CodingKey {
        case id, agentId, acpSessionId, title, cwd, currentModelId, currentModeId
        case availableModels, availableModes, configOptions, availableCommands
        case contextUsed, contextSize, isRunning, createdAt, updatedAt, totalCredits
        case swarmId, swarmRole, swarmMemberName, worktreeBranch
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        agentId = c.flexString(.agentId)
        acpSessionId = c.flexOptionalString(.acpSessionId)
        title = c.flexString(.title, default: "新对话")
        cwd = c.flexString(.cwd)
        currentModelId = c.flexOptionalString(.currentModelId)
        currentModeId = c.flexOptionalString(.currentModeId)
        availableModels = c.flexArray(ModelInfo.self, .availableModels)
        availableModes = c.flexArray(ModeInfo.self, .availableModes)
        configOptions = c.flexArray(ConfigOption.self, .configOptions)
        availableCommands = c.flexArray(SlashCommand.self, .availableCommands)
        contextUsed = c.flexInt(.contextUsed)
        contextSize = c.flexInt(.contextSize)
        isRunning = c.flexBool(.isRunning)
        createdAt = c.flexDouble(.createdAt)
        updatedAt = c.flexDouble(.updatedAt)
        totalCredits = c.flexOptionalDouble(.totalCredits)
        swarmId = c.flexOptionalString(.swarmId)
        swarmRole = c.flexOptionalString(.swarmRole)
        swarmMemberName = c.flexOptionalString(.swarmMemberName)
        worktreeBranch = c.flexOptionalString(.worktreeBranch)
    }

    var isSwarmCoordinator: Bool { swarmRole == "coordinator" }
    var isSwarmWorker: Bool { swarmRole == "worker" }

    var updatedDate: Date { Date(timeIntervalSince1970: updatedAt / 1000) }

    var currentModelName: String? {
        if let id = currentModelId {
            return availableModels.first(where: { $0.modelId == id })?.name ?? id
        }
        if let opt = configOptions.first(where: { $0.id == "model" }) {
            let v = opt.currentValue.stringValue
            return opt.choices.first(where: { $0.value == v })?.name ?? (v.isEmpty ? nil : v)
        }
        return nil
    }

    var currentModeName: String? {
        guard let id = currentModeId else { return nil }
        return availableModes.first(where: { $0.id == id })?.name ?? id
    }

    var contextFraction: Double {
        guard contextSize > 0 else { return 0 }
        return min(1, max(0, Double(contextUsed) / Double(contextSize)))
    }
}

// MARK: - Messages

struct ToolActivity: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var title: String
    var kind: String
    var status: String

    enum CodingKeys: String, CodingKey { case id, name, title, kind, status }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.flexString(.id, default: UUID().uuidString)
        name = c.flexString(.name, default: "tool")
        title = c.flexString(.title, default: name)
        kind = c.flexString(.kind, default: "other")
        status = c.flexString(.status, default: "in_progress")
    }

    var isActive: Bool { status == "pending" || status == "in_progress" }
    var isFailed: Bool { status == "failed" || status == "error" }
}

struct Attachment: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var filename: String
    var mimeType: String
    var sizeBytes: Int
    var isImage: Bool

    enum CodingKeys: String, CodingKey { case id, filename, mimeType, sizeBytes, isImage }

    init(id: String, filename: String, mimeType: String, sizeBytes: Int, isImage: Bool) {
        self.id = id
        self.filename = filename
        self.mimeType = mimeType
        self.sizeBytes = sizeBytes
        self.isImage = isImage
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        filename = c.flexString(.filename, default: "file")
        mimeType = c.flexString(.mimeType, default: "application/octet-stream")
        sizeBytes = c.flexInt(.sizeBytes)
        isImage = c.flexBool(.isImage, default: mimeType.hasPrefix("image/"))
    }
}

struct UsageStats: Codable, Hashable, Sendable {
    var inputTokens: Double?
    var outputTokens: Double?
    var cachedReadTokens: Double?
    var thoughtTokens: Double?
    var totalTokens: Double?
    /// CodeBuddy credits actually charged for this turn.
    var credits: Double?
    /// CodeBuddy list price before free-model discounts.
    var originalCredits: Double?

    enum CodingKeys: String, CodingKey {
        case inputTokens, outputTokens, cachedReadTokens, thoughtTokens, totalTokens, credits, originalCredits
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        inputTokens = c.flexOptionalDouble(.inputTokens)
        outputTokens = c.flexOptionalDouble(.outputTokens)
        cachedReadTokens = c.flexOptionalDouble(.cachedReadTokens)
        thoughtTokens = c.flexOptionalDouble(.thoughtTokens)
        totalTokens = c.flexOptionalDouble(.totalTokens)
        credits = c.flexOptionalDouble(.credits)
        originalCredits = c.flexOptionalDouble(.originalCredits)
    }

    var displayTotal: Double? {
        if let totalTokens { return totalTokens }
        let sum = (inputTokens ?? 0) + (outputTokens ?? 0)
        return sum > 0 ? sum : nil
    }

    /// Credits saved by free / discounted models on this turn.
    var savedCredits: Double {
        guard let credits, let originalCredits else { return 0 }
        return max(0, originalCredits - credits)
    }
}

enum MessageRole: String, Codable, Sendable {
    case user
    case assistant
}

struct Message: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var sessionId: String
    var role: MessageRole
    var content: String
    var thinking: String
    var attachments: [Attachment]
    var toolCalls: [ToolActivity]
    var usage: UsageStats?
    var status: String
    var createdAt: Double

    enum CodingKeys: String, CodingKey {
        case id, sessionId, role, content, thinking, attachments, toolCalls, usage, status, createdAt
    }

    init(
        id: String,
        sessionId: String,
        role: MessageRole,
        content: String,
        thinking: String = "",
        attachments: [Attachment] = [],
        toolCalls: [ToolActivity] = [],
        usage: UsageStats? = nil,
        status: String = "completed",
        createdAt: Double = Date().timeIntervalSince1970 * 1000
    ) {
        self.id = id
        self.sessionId = sessionId
        self.role = role
        self.content = content
        self.thinking = thinking
        self.attachments = attachments
        self.toolCalls = toolCalls
        self.usage = usage
        self.status = status
        self.createdAt = createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        sessionId = c.flexString(.sessionId)
        role = c.flexString(.role) == "user" ? .user : .assistant
        content = c.flexString(.content)
        thinking = c.flexString(.thinking)
        attachments = c.flexArray(Attachment.self, .attachments)
        toolCalls = c.flexArray(ToolActivity.self, .toolCalls)
        usage = try? c.decodeIfPresent(UsageStats.self, forKey: .usage)
        status = c.flexString(.status, default: "completed")
        createdAt = c.flexDouble(.createdAt)
    }

    var isStreaming: Bool { status == "streaming" }
    var isError: Bool { status == "error" }
    var isCancelled: Bool { status == "cancelled" }
}

// MARK: - REST envelopes

struct ServerSettings: Codable, Hashable, Sendable {
    var barkUrl: String

    enum CodingKeys: String, CodingKey { case barkUrl }

    init(barkUrl: String = "") { self.barkUrl = barkUrl }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        barkUrl = c.flexString(.barkUrl)
    }
}

struct BootstrapResponse: Codable, Sendable {
    var agents: [AgentInfo]
    var sessions: [SessionSummary]
    var swarms: [SwarmSummary]
    var defaultCwd: String
    var settings: ServerSettings

    enum CodingKeys: String, CodingKey { case agents, sessions, swarms, defaultCwd, settings }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        agents = c.flexArray(AgentInfo.self, .agents)
        sessions = c.flexArray(SessionSummary.self, .sessions)
        swarms = c.flexArray(SwarmSummary.self, .swarms)
        defaultCwd = c.flexString(.defaultCwd)
        settings = (try? c.decodeIfPresent(ServerSettings.self, forKey: .settings)) ?? ServerSettings()
    }
}

struct HealthResponse: Decodable, Sendable {
    var ok: Bool
    var service: String?
    var agents: [String]?
}

struct WorkspacesResponse: Decodable, Sendable {
    var workspaces: [String]
}

struct SessionEnvelope: Decodable, Sendable {
    var session: SessionSummary
}

struct SessionDetailResponse: Decodable, Sendable {
    var session: SessionSummary
    var messages: [Message]
}

struct PromptResponse: Decodable, Sendable {
    var userMessage: Message
    var assistantMessage: Message
}

struct CancelResponse: Decodable, Sendable {
    var cancelled: Bool
}

struct OkResponse: Decodable, Sendable {
    var ok: Bool?
}

struct ServerErrorBody: Decodable, Sendable {
    var error: String?
    var message: String?
}

// MARK: - WebSocket events

struct WSHeader: Decodable, Sendable {
    var type: String
    var sessionId: String?
}

struct WSPayload<P: Decodable & Sendable>: Decodable, Sendable {
    var payload: P
}

struct WSSessionPayload: Decodable, Sendable {
    var session: SessionSummary?
}

struct WSDeletedPayload: Decodable, Sendable {
    var sessionId: String?
}

struct WSCommandsPayload: Decodable, Sendable {
    var commands: [SlashCommand]
}

struct WSUsagePayload: Decodable, Sendable {
    var contextUsed: Int
    var contextSize: Int

    enum CodingKeys: String, CodingKey { case contextUsed, contextSize }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        contextUsed = c.flexInt(.contextUsed)
        contextSize = c.flexInt(.contextSize)
    }
}

struct WSTurnStartedPayload: Decodable, Sendable {
    var userMessage: Message?
    var assistantMessage: Message?
    var session: SessionSummary?
}

struct WSDeltaPayload: Decodable, Sendable {
    var messageId: String
    var delta: String
}

struct WSToolActivityPayload: Decodable, Sendable {
    var messageId: String
    var toolCalls: [ToolActivity]
}

struct WSTurnCompletedPayload: Decodable, Sendable {
    var messageId: String
    var stopReason: String?
    var status: String?
    var usage: UsageStats?
    var session: SessionSummary?
}

struct WSTurnErrorPayload: Decodable, Sendable {
    var messageId: String
    var error: String?
    var session: SessionSummary?
}

// MARK: - Config mutation

enum ConfigKind: String, Sendable {
    case model
    case mode
    case config
}
