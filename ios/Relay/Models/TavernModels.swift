import Foundation

// MARK: - Optional Int flexible decoding

extension KeyedDecodingContainer {
    func flexOptionalInt(_ key: Key) -> Int? {
        if let i = try? decodeIfPresent(Int.self, forKey: key) { return i }
        if let d = try? decodeIfPresent(Double.self, forKey: key) { return Int(d) }
        if let s = try? decodeIfPresent(String.self, forKey: key), let i = Int(s) { return i }
        return nil
    }
}

// MARK: - Generic JSON value (for SillyTavern variables)

enum JSONAnyValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONAnyValue])
    case object([String: JSONAnyValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? container.decode(Int.self) {
            self = .int(i)
        } else if let d = try? container.decode(Double.self) {
            self = .double(d)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let arr = try? container.decode([JSONAnyValue].self) {
            self = .array(arr)
        } else if let obj = try? container.decode([String: JSONAnyValue].self) {
            self = .object(obj)
        } else {
            self = .null
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let b): try container.encode(b)
        case .int(let i): try container.encode(i)
        case .double(let d): try container.encode(d)
        case .string(let s): try container.encode(s)
        case .array(let arr): try container.encode(arr)
        case .object(let obj): try container.encode(obj)
        }
    }

    static func encodeVariablesJSON(_ variables: [String: JSONAnyValue]) -> String {
        guard !variables.isEmpty else { return "{}" }
        guard let data = try? JSONEncoder().encode(variables),
              let str = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return str
    }
}

// MARK: - Navigation route

struct TavernRoute: Hashable, Sendable {
    let characterId: Int
}

enum TavernSwipeDirection: String, Sendable {
    case left
    case right
    case new
}

// MARK: - Core Tavern DTOs

struct TavernGenerationError: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var characterId: Int?
    var characterName: String?
    var chatFile: String?
    var code: Int?
    var kind: String
    var message: String
    var occurredAt: Double

    enum CodingKeys: String, CodingKey {
        case id, characterId, characterName, chatFile, code, kind, message, occurredAt
    }

    init(
        id: String = UUID().uuidString,
        characterId: Int? = nil,
        characterName: String? = nil,
        chatFile: String? = nil,
        code: Int? = nil,
        kind: String = "unknown",
        message: String,
        occurredAt: Double = Date().timeIntervalSince1970 * 1000
    ) {
        self.id = id
        self.characterId = characterId
        self.characterName = characterName
        self.chatFile = chatFile
        self.code = code
        self.kind = kind
        self.message = message
        self.occurredAt = occurredAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.flexString(.id, default: UUID().uuidString)
        characterId = c.flexOptionalInt(.characterId)
        characterName = c.flexOptionalString(.characterName)
        chatFile = c.flexOptionalString(.chatFile)
        code = c.flexOptionalInt(.code)
        kind = c.flexString(.kind, default: "unknown")
        message = c.flexString(.message)
        occurredAt = c.flexDouble(.occurredAt)
    }

    var occurredDate: Date? {
        guard occurredAt > 0 else { return nil }
        let seconds = occurredAt > 10_000_000_000 ? occurredAt / 1000 : occurredAt
        return Date(timeIntervalSince1970: seconds)
    }

    var badgeTitle: String {
        switch kind {
        case "rate_limit": return code == 429 ? "429 限流" : "请求限流"
        case "safety": return "安全拦截"
        case "auth": return "鉴权失败"
        case "server": return code != nil ? "服务异常 \(code!)" : "服务异常"
        case "network": return "网络异常"
        default: return code != nil ? "报错 \(code!)" : "生成失败"
        }
    }
}

struct TavernStatus: Codable, Hashable, Sendable {
    var enabled: Bool
    var ready: Bool
    var needsLogin: Bool
    var handle: String?
    var publicUrl: String
    var currentCharacterId: Int?
    var currentCharacterName: String?
    var currentChatFile: String?
    var isGenerating: Bool
    var lastError: String?
    var lastGenerationError: TavernGenerationError?

    enum CodingKeys: String, CodingKey {
        case enabled, ready, needsLogin, handle, publicUrl
        case currentCharacterId, currentCharacterName, currentChatFile
        case isGenerating, lastError, lastGenerationError
    }

    init(
        enabled: Bool = true,
        ready: Bool = false,
        needsLogin: Bool = false,
        handle: String? = nil,
        publicUrl: String = "",
        currentCharacterId: Int? = nil,
        currentCharacterName: String? = nil,
        currentChatFile: String? = nil,
        isGenerating: Bool = false,
        lastError: String? = nil,
        lastGenerationError: TavernGenerationError? = nil
    ) {
        self.enabled = enabled
        self.ready = ready
        self.needsLogin = needsLogin
        self.handle = handle
        self.publicUrl = publicUrl
        self.currentCharacterId = currentCharacterId
        self.currentCharacterName = currentCharacterName
        self.currentChatFile = currentChatFile
        self.isGenerating = isGenerating
        self.lastError = lastError
        self.lastGenerationError = lastGenerationError
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = c.flexBool(.enabled, default: true)
        ready = c.flexBool(.ready)
        needsLogin = c.flexBool(.needsLogin)
        handle = c.flexOptionalString(.handle)
        publicUrl = c.flexString(.publicUrl)
        currentCharacterId = c.flexOptionalInt(.currentCharacterId)
        currentCharacterName = c.flexOptionalString(.currentCharacterName)
        currentChatFile = c.flexOptionalString(.currentChatFile)
        isGenerating = c.flexBool(.isGenerating)
        lastError = c.flexOptionalString(.lastError)
        lastGenerationError = try? c.decodeIfPresent(TavernGenerationError.self, forKey: .lastGenerationError)
    }

    var publicURL: URL? {
        guard !publicUrl.isEmpty else { return nil }
        return URL(string: publicUrl)
    }
}

struct TavernLoginUser: Codable, Identifiable, Hashable, Sendable {
    var handle: String
    var name: String
    var id: String { handle }

    enum CodingKeys: String, CodingKey { case handle, name }

    init(handle: String, name: String) {
        self.handle = handle
        self.name = name
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        handle = c.flexString(.handle)
        name = c.flexString(.name, default: handle)
    }
}

struct TavernCharacter: Codable, Identifiable, Hashable, Sendable {
    var id: Int
    var name: String
    var avatar: String
    var avatarUrl: String
    var chat: String?
    var lastChatAt: Double
    var tags: [String]
    var tagline: String

    enum CodingKeys: String, CodingKey {
        case id, name, avatar, avatarUrl, chat, lastChatAt, tags, tagline
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.flexInt(.id)
        name = c.flexString(.name, default: "未命名角色")
        avatar = c.flexString(.avatar)
        avatarUrl = c.flexString(.avatarUrl)
        chat = c.flexOptionalString(.chat)
        lastChatAt = c.flexDouble(.lastChatAt)
        tags = c.flexArray(String.self, .tags)
        tagline = c.flexString(.tagline)
    }

    var lastChatDate: Date? {
        guard lastChatAt > 0 else { return nil }
        let seconds = lastChatAt > 10_000_000_000 ? lastChatAt / 1000 : lastChatAt
        return Date(timeIntervalSince1970: seconds)
    }
}

struct TavernChatFile: Codable, Identifiable, Hashable, Sendable {
    var fileName: String
    var displayName: String
    var lastMessage: String
    var messageCount: Int
    var updatedAt: Double
    var isCurrent: Bool
    var id: String { fileName }

    enum CodingKeys: String, CodingKey {
        case fileName, displayName, lastMessage, messageCount, updatedAt, isCurrent
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fileName = c.flexString(.fileName)
        displayName = c.flexString(.displayName, default: fileName)
        lastMessage = c.flexString(.lastMessage)
        messageCount = c.flexInt(.messageCount)
        updatedAt = c.flexDouble(.updatedAt)
        isCurrent = c.flexBool(.isCurrent)
    }

    var updatedDate: Date? {
        guard updatedAt > 0 else { return nil }
        let seconds = updatedAt > 10_000_000_000 ? updatedAt / 1000 : updatedAt
        return Date(timeIntervalSince1970: seconds)
    }
}

struct TavernRenderBlock: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var kind: String
    var markdown: String?
    var summary: String?
    var html: String?
    var imageUrl: String?
    var imageAlt: String?
    var estimatedHeight: Double?

    enum CodingKeys: String, CodingKey {
        case id, kind, markdown, summary, html, imageUrl, imageAlt, estimatedHeight
    }

    init(
        id: String,
        kind: String,
        markdown: String? = nil,
        summary: String? = nil,
        html: String? = nil,
        imageUrl: String? = nil,
        imageAlt: String? = nil,
        estimatedHeight: Double? = nil
    ) {
        self.id = id
        self.kind = kind
        self.markdown = markdown
        self.summary = summary
        self.html = html
        self.imageUrl = imageUrl
        self.imageAlt = imageAlt
        self.estimatedHeight = estimatedHeight
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.flexString(.id, default: UUID().uuidString)
        kind = c.flexString(.kind, default: "markdown")
        markdown = c.flexOptionalString(.markdown)
        summary = c.flexOptionalString(.summary)
        html = c.flexOptionalString(.html)
        imageUrl = c.flexOptionalString(.imageUrl)
        imageAlt = c.flexOptionalString(.imageAlt)
        estimatedHeight = c.flexOptionalDouble(.estimatedHeight)
    }
}

struct TavernMessage: Codable, Identifiable, Hashable, Sendable {
    var mesId: Int
    var name: String
    var avatarUrl: String?
    var isUser: Bool
    var isSystem: Bool
    var sendDate: String
    var rawText: String
    var reasoning: String
    var swipeId: Int
    var swipeCount: Int
    var blocks: [TavernRenderBlock]
    var renderedHash: String
    var isStreaming: Bool
    var mvuData: [String: JSONAnyValue]?

    var id: Int { mesId }

    enum CodingKeys: String, CodingKey {
        case mesId, name, avatarUrl, isUser, isSystem, sendDate
        case rawText, reasoning, swipeId, swipeCount, blocks, renderedHash, isStreaming, mvuData
    }

    init(
        mesId: Int,
        name: String,
        avatarUrl: String? = nil,
        isUser: Bool = false,
        isSystem: Bool = false,
        sendDate: String = "",
        rawText: String = "",
        reasoning: String = "",
        swipeId: Int = 0,
        swipeCount: Int = 1,
        blocks: [TavernRenderBlock] = [],
        renderedHash: String = "",
        isStreaming: Bool = false,
        mvuData: [String: JSONAnyValue]? = nil
    ) {
        self.mesId = mesId
        self.name = name
        self.avatarUrl = avatarUrl
        self.isUser = isUser
        self.isSystem = isSystem
        self.sendDate = sendDate
        self.rawText = rawText
        self.reasoning = reasoning
        self.swipeId = swipeId
        self.swipeCount = swipeCount
        self.blocks = blocks
        self.renderedHash = renderedHash
        self.isStreaming = isStreaming
        self.mvuData = mvuData
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mesId = c.flexInt(.mesId)
        name = c.flexString(.name)
        avatarUrl = c.flexOptionalString(.avatarUrl)
        isUser = c.flexBool(.isUser)
        isSystem = c.flexBool(.isSystem)
        sendDate = c.flexString(.sendDate)
        rawText = c.flexString(.rawText)
        reasoning = c.flexString(.reasoning)
        swipeId = c.flexInt(.swipeId)
        swipeCount = c.flexInt(.swipeCount, default: 1)
        blocks = c.flexArray(TavernRenderBlock.self, .blocks)
        renderedHash = c.flexString(.renderedHash)
        isStreaming = c.flexBool(.isStreaming)
        mvuData = try? c.decodeIfPresent([String: JSONAnyValue].self, forKey: .mvuData)
    }

    var mvuDataJSON: String {
        guard let mvuData, !mvuData.isEmpty else { return "{}" }
        return JSONAnyValue.encodeVariablesJSON(mvuData)
    }
}

struct TavernChatState: Codable, Hashable, Sendable {
    var status: TavernStatus
    var character: TavernCharacter?
    var chatFile: String?
    var userName: String
    var messages: [TavernMessage]
    var variables: [String: JSONAnyValue]
    var totalMessageCount: Int?
    var hasMore: Bool?
    var unchangedMesIds: [Int]?

    enum CodingKeys: String, CodingKey {
        case status, character, chatFile, userName, messages, variables
        case totalMessageCount, hasMore, unchangedMesIds
    }

    init(
        status: TavernStatus,
        character: TavernCharacter?,
        chatFile: String?,
        userName: String,
        messages: [TavernMessage],
        variables: [String: JSONAnyValue] = [:],
        totalMessageCount: Int? = nil,
        hasMore: Bool? = nil,
        unchangedMesIds: [Int]? = nil
    ) {
        self.status = status
        self.character = character
        self.chatFile = chatFile
        self.userName = userName
        self.messages = messages
        self.variables = variables
        self.totalMessageCount = totalMessageCount
        self.hasMore = hasMore
        self.unchangedMesIds = unchangedMesIds
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = (try? c.decodeIfPresent(TavernStatus.self, forKey: .status)) ?? TavernStatus()
        character = try? c.decodeIfPresent(TavernCharacter.self, forKey: .character)
        chatFile = c.flexOptionalString(.chatFile)
        userName = c.flexString(.userName, default: "You")
        messages = c.flexArray(TavernMessage.self, .messages)
        variables = (try? c.decodeIfPresent([String: JSONAnyValue].self, forKey: .variables)) ?? [:]
        totalMessageCount = c.flexOptionalInt(.totalMessageCount)
        hasMore = try? c.decodeIfPresent(Bool.self, forKey: .hasMore)
        unchangedMesIds = try? c.decodeIfPresent([Int].self, forKey: .unchangedMesIds)
    }

    var variablesJSON: String {
        JSONAnyValue.encodeVariablesJSON(variables)
    }
}

// MARK: - Tavern REST envelopes

struct TavernStatusResponse: Decodable, Sendable {
    var status: TavernStatus
    var loginUsers: [TavernLoginUser]?

    enum CodingKeys: String, CodingKey { case status, loginUsers }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = (try? c.decodeIfPresent(TavernStatus.self, forKey: .status)) ?? TavernStatus()
        loginUsers = try? c.decodeIfPresent([TavernLoginUser].self, forKey: .loginUsers)
    }
}

struct TavernCharactersResponse: Decodable, Sendable {
    var status: TavernStatus
    var characters: [TavernCharacter]

    enum CodingKeys: String, CodingKey { case status, characters }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = (try? c.decodeIfPresent(TavernStatus.self, forKey: .status)) ?? TavernStatus()
        characters = c.flexArray(TavernCharacter.self, .characters)
    }
}

struct TavernChatsResponse: Decodable, Sendable {
    var characterId: Int
    var chats: [TavernChatFile]

    enum CodingKeys: String, CodingKey { case characterId, chats }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        characterId = c.flexInt(.characterId)
        chats = c.flexArray(TavernChatFile.self, .chats)
    }
}

struct TavernStateResponse: Decodable, Sendable {
    var state: TavernChatState
}

struct TavernActionStateResponse: Decodable, Sendable {
    var ok: Bool?
    var state: TavernChatState
}

struct TavernMessageMutationResponse: Decodable, Sendable {
    var message: TavernMessage?
    var state: TavernChatState
}

struct TavernStopResponse: Decodable, Sendable {
    var stopped: Bool

    enum CodingKeys: String, CodingKey { case stopped }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        stopped = c.flexBool(.stopped)
    }
}

struct TavernSlashResponse: Decodable, Sendable {
    var ok: Bool?
    var result: String?
    var state: TavernChatState
}

struct TavernReloadResponse: Decodable, Sendable {
    var status: TavernStatus
    var characters: [TavernCharacter]

    enum CodingKeys: String, CodingKey { case status, characters }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = (try? c.decodeIfPresent(TavernStatus.self, forKey: .status)) ?? TavernStatus()
        characters = c.flexArray(TavernCharacter.self, .characters)
    }
}

// MARK: - Tavern WebSocket payloads

struct WSTavernStatusPayload: Decodable, Sendable {
    var status: TavernStatus?
}

struct WSTavernStreamDeltaPayload: Decodable, Sendable {
    var characterId: Int?
    var chatFile: String?
    var mesId: Int
    var text: String
    var reasoning: String

    enum CodingKeys: String, CodingKey { case characterId, chatFile, mesId, text, reasoning }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        characterId = c.flexOptionalInt(.characterId)
        chatFile = c.flexOptionalString(.chatFile)
        mesId = c.flexInt(.mesId)
        text = c.flexString(.text)
        reasoning = c.flexString(.reasoning)
    }
}

struct WSTavernMessageFinalizedPayload: Decodable, Sendable {
    var characterId: Int?
    var chatFile: String?
    var message: TavernMessage?
    var variables: [String: JSONAnyValue]?
    var isGenerating: Bool?

    enum CodingKeys: String, CodingKey { case characterId, chatFile, message, variables, isGenerating }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        characterId = c.flexOptionalInt(.characterId)
        chatFile = c.flexOptionalString(.chatFile)
        message = try? c.decodeIfPresent(TavernMessage.self, forKey: .message)
        variables = try? c.decodeIfPresent([String: JSONAnyValue].self, forKey: .variables)
        isGenerating = try? c.decodeIfPresent(Bool.self, forKey: .isGenerating)
    }
}

struct WSTavernChatUpdatedPayload: Decodable, Sendable {
    var state: TavernChatState?
}

struct WSTavernErrorPayload: Decodable, Sendable {
    var id: String?
    var characterId: Int?
    var characterName: String?
    var chatFile: String?
    var code: Int?
    var kind: String?
    var message: String
    var occurredAt: Double?

    enum CodingKeys: String, CodingKey {
        case id, characterId, characterName, chatFile, code, kind, message, occurredAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.flexOptionalString(.id)
        characterId = c.flexOptionalInt(.characterId)
        characterName = c.flexOptionalString(.characterName)
        chatFile = c.flexOptionalString(.chatFile)
        code = c.flexOptionalInt(.code)
        kind = c.flexOptionalString(.kind)
        message = c.flexString(.message)
        occurredAt = c.flexOptionalDouble(.occurredAt)
    }

    func toGenerationError() -> TavernGenerationError {
        TavernGenerationError(
            id: (id?.isEmpty == false) ? id! : UUID().uuidString,
            characterId: characterId,
            characterName: characterName,
            chatFile: chatFile,
            code: code,
            kind: kind ?? "unknown",
            message: message,
            occurredAt: occurredAt ?? (Date().timeIntervalSince1970 * 1000)
        )
    }
}
