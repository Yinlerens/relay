import Foundation

// MARK: - Swarm core models

struct SwarmMember: Codable, Identifiable, Hashable, Sendable {
    var swarmId: String
    var name: String
    var role: String
    var sessionId: String
    var agentId: String
    var modelId: String?
    var state: String
    var workspaceMode: String
    var worktreePath: String?
    var worktreeBranch: String?
    var brief: String
    var totalCredits: Double
    var isRunning: Bool
    var lastReadSeq: Int
    var lastPostSeq: Int
    var createdAt: Double
    var updatedAt: Double

    var id: String { "\(swarmId)-\(name)" }

    enum CodingKeys: String, CodingKey {
        case swarmId, name, role, sessionId, agentId, modelId, state
        case workspaceMode, worktreePath, worktreeBranch, brief
        case totalCredits, isRunning, lastReadSeq, lastPostSeq, createdAt, updatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        swarmId = c.flexString(.swarmId)
        name = c.flexString(.name)
        role = c.flexString(.role, default: "worker")
        sessionId = c.flexString(.sessionId)
        agentId = c.flexString(.agentId)
        modelId = c.flexOptionalString(.modelId)
        state = c.flexString(.state, default: "waiting")
        workspaceMode = c.flexString(.workspaceMode, default: "inherit")
        worktreePath = c.flexOptionalString(.worktreePath)
        worktreeBranch = c.flexOptionalString(.worktreeBranch)
        brief = c.flexString(.brief)
        totalCredits = c.flexDouble(.totalCredits)
        isRunning = c.flexBool(.isRunning)
        lastReadSeq = c.flexInt(.lastReadSeq)
        lastPostSeq = c.flexInt(.lastPostSeq)
        createdAt = c.flexDouble(.createdAt)
        updatedAt = c.flexDouble(.updatedAt)
    }

    var isCoordinator: Bool { role == "coordinator" }
    var isWorker: Bool { role == "worker" }
    var isKilled: Bool { state == "killed" }
    var isWorking: Bool { !isKilled && (state == "working" || isRunning) }
    var isDone: Bool { state == "done" }
    var isError: Bool { state == "error" }
    var usesWorktree: Bool { workspaceMode == "worktree" }
    var updatedDate: Date { Date(timeIntervalSince1970: updatedAt / 1000) }

    var stateLabel: String {
        if isKilled { return "已终止" }
        if isWorking { return "运行中" }
        switch state {
        case "done": return "已完成"
        case "error": return "出错"
        default: return "待命"
        }
    }
}

struct SwarmBoardMessage: Codable, Identifiable, Hashable, Sendable {
    var id: Int
    var swarmId: String
    var seq: Int
    var sender: String
    var mentions: [String]
    var text: String
    var kind: String
    var createdAt: Double

    enum CodingKeys: String, CodingKey {
        case id, swarmId, seq, sender, mentions, text, kind, createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.flexInt(.id)
        swarmId = c.flexString(.swarmId)
        seq = c.flexInt(.seq)
        sender = c.flexString(.sender, default: "system")
        mentions = c.flexArray(String.self, .mentions)
        text = c.flexString(.text)
        kind = c.flexString(.kind, default: "post")
        createdAt = c.flexDouble(.createdAt)
    }

    var createdDate: Date { Date(timeIntervalSince1970: createdAt / 1000) }

    var kindLabel: String? {
        switch kind {
        case "brief": return "派单"
        case "done": return "完成"
        case "status": return "状态"
        case "system": return "系统"
        default: return nil
        }
    }
}

struct SwarmSummary: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var cwd: String
    var coordinatorSessionId: String
    var coordinatorAgentId: String
    var defaultWorkerAgentId: String
    var defaultWorkerModelId: String?
    var status: String
    var headSeq: Int
    var totalCredits: Double
    var activeWorkerCount: Int
    var members: [SwarmMember]
    var createdAt: Double
    var updatedAt: Double

    enum CodingKeys: String, CodingKey {
        case id, title, cwd, coordinatorSessionId, coordinatorAgentId
        case defaultWorkerAgentId, defaultWorkerModelId, status
        case headSeq, totalCredits, activeWorkerCount, members, createdAt, updatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = c.flexString(.title, default: "蜂群协作")
        cwd = c.flexString(.cwd)
        coordinatorSessionId = c.flexString(.coordinatorSessionId)
        coordinatorAgentId = c.flexString(.coordinatorAgentId)
        defaultWorkerAgentId = c.flexString(.defaultWorkerAgentId)
        defaultWorkerModelId = c.flexOptionalString(.defaultWorkerModelId)
        status = c.flexString(.status, default: "active")
        headSeq = c.flexInt(.headSeq)
        totalCredits = c.flexDouble(.totalCredits)
        activeWorkerCount = c.flexInt(.activeWorkerCount)
        members = c.flexArray(SwarmMember.self, .members)
        createdAt = c.flexDouble(.createdAt)
        updatedAt = c.flexDouble(.updatedAt)
    }

    var updatedDate: Date { Date(timeIntervalSince1970: updatedAt / 1000) }
    var workers: [SwarmMember] { members.filter(\.isWorker) }
    var activeWorkers: [SwarmMember] { members.filter { $0.isWorker && !$0.isKilled } }
    var liveMemberCount: Int { max(1, members.filter { !$0.isKilled }.count) }
    var runningCount: Int { members.filter(\.isWorking).count }
    var isAnyRunning: Bool { runningCount > 0 }

    var statusLabel: String {
        switch status {
        case "completed": return "已完成"
        case "archived": return "已归档"
        default: return "进行中"
        }
    }

    func member(forSessionId sessionId: String) -> SwarmMember? {
        members.first(where: { $0.sessionId == sessionId })
    }

    func member(named name: String) -> SwarmMember? {
        members.first(where: { $0.name == name })
    }
}

// MARK: - Swarm REST envelopes

struct SwarmListResponse: Decodable, Sendable {
    var swarms: [SwarmSummary]

    enum CodingKeys: String, CodingKey { case swarms }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        swarms = c.flexArray(SwarmSummary.self, .swarms)
    }
}

struct CreateSwarmResponse: Decodable, Sendable {
    var swarm: SwarmSummary
    var session: SessionSummary
}

struct SwarmDetailResponse: Decodable, Sendable {
    var swarm: SwarmSummary
    var messages: [SwarmBoardMessage]

    enum CodingKeys: String, CodingKey { case swarm, messages }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        swarm = try c.decode(SwarmSummary.self, forKey: .swarm)
        messages = c.flexArray(SwarmBoardMessage.self, .messages)
    }
}

struct SwarmWorkerCreatedResponse: Decodable, Sendable {
    var member: SwarmMember
    var swarm: SwarmSummary
    var boardSeq: Int

    enum CodingKeys: String, CodingKey { case member, swarm, boardSeq }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        member = try c.decode(SwarmMember.self, forKey: .member)
        swarm = try c.decode(SwarmSummary.self, forKey: .swarm)
        boardSeq = c.flexInt(.boardSeq)
    }
}

struct SwarmBoardPostResponse: Decodable, Sendable {
    var message: SwarmBoardMessage
    var woke: [String]
    var swarm: SwarmSummary

    enum CodingKeys: String, CodingKey { case message, woke, swarm }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        message = try c.decode(SwarmBoardMessage.self, forKey: .message)
        woke = c.flexArray(String.self, .woke)
        swarm = try c.decode(SwarmSummary.self, forKey: .swarm)
    }
}

struct AgentModelsResponse: Decodable, Sendable {
    var agentId: String
    var models: [ModelInfo]
    var defaultModelId: String?

    enum CodingKeys: String, CodingKey { case agentId, models, defaultModelId }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        agentId = c.flexString(.agentId)
        models = c.flexArray(ModelInfo.self, .models)
        defaultModelId = c.flexOptionalString(.defaultModelId)
    }
}

struct SwarmEnvelopeResponse: Decodable, Sendable {
    var ok: Bool?
    var swarm: SwarmSummary
}

// MARK: - Swarm WebSocket payloads

struct WSSwarmPayload: Decodable, Sendable {
    var swarm: SwarmSummary?
}

struct WSSwarmDeletedPayload: Decodable, Sendable {
    var swarmId: String?
}

struct WSSwarmBoardPostPayload: Decodable, Sendable {
    var swarmId: String?
    var message: SwarmBoardMessage?
    var swarm: SwarmSummary?
}
