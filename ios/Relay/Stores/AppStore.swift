import SwiftUI
import UIKit
import Observation

struct Banner: Identifiable, Equatable {
    let id = UUID()
    var message: String
    var isError: Bool = true
}

struct PairingRequest: Identifiable, Equatable {
    let id = UUID()
    var serverURL: String
    var token: String
}

/// Single source of truth for the app: pairing, sessions, messages, live streaming and config switching.
@MainActor
@Observable
final class AppStore {
    // MARK: Pairing
    var serverURLString: String
    var token: String
    var isPaired: Bool
    var isConnecting = false
    var connectError: String? = nil
    var pendingPairing: PairingRequest? = nil

    // MARK: Server state
    var agents: [AgentInfo] = []
    var sessions: [SessionSummary] = []
    var defaultCwd: String = ""
    var barkUrl: String = ""
    var hasBootstrapped = false
    var messages: [String: [Message]] = [:]

    // MARK: UI state
    var socketState: RelaySocket.State = .idle
    var loadingSessions: Set<String> = []
    var creatingAgentIds: Set<String> = []
    var pendingConfigKeys: Set<String> = []
    var banner: Banner? = nil
    var activeSessionId: String? = nil

    // MARK: Quotas & credits
    var quotas: QuotaOverview? = nil
    var isLoadingQuotas = false
    var quotaError: String? = nil

    // MARK: Private
    private let socket: RelaySocket
    @ObservationIgnored private var pendingDeltas: [String: PendingDelta] = [:]
    @ObservationIgnored private var flushScheduled = false
    @ObservationIgnored private var bannerTask: Task<Void, Never>? = nil

    private struct PendingDelta {
        var sessionId: String
        var text: String = ""
        var thought: String = ""
    }

    init() {
        let storedURL = KeychainStore.string(for: .serverURL) ?? ""
        let storedToken = KeychainStore.string(for: .bearerToken) ?? ""
        serverURLString = storedURL
        token = storedToken
        isPaired = !storedURL.isEmpty
        socket = RelaySocket()

        socket.onEvent = { [weak self] data in
            self?.handleSocketData(data)
        }
        socket.onStateChange = { [weak self] state in
            self?.socketState = state
        }
        socket.onReconnected = { [weak self] in
            guard let self else { return }
            Task { await self.resync() }
        }
    }

    // MARK: - Derived

    var api: RelayAPI? {
        guard isPaired, let url = RelayAPI.normalizedBaseURL(from: serverURLString) else { return nil }
        return RelayAPI(baseURL: url, token: token)
    }

    var serverHost: String {
        RelayAPI.normalizedBaseURL(from: serverURLString)?.host ?? serverURLString
    }

    func agent(for id: String) -> AgentInfo? {
        agents.first(where: { $0.id == id })
    }

    func session(_ id: String) -> SessionSummary? {
        sessions.first(where: { $0.id == id })
    }

    func messages(for sessionId: String) -> [Message] {
        messages[sessionId] ?? []
    }

    func configKey(_ sessionId: String, _ kind: ConfigKind, _ configId: String?) -> String {
        "\(sessionId)|\(kind.rawValue)|\(configId ?? "")"
    }

    // MARK: - Lifecycle

    func start() async {
        guard isPaired, let api else { return }
        if let request = api.webSocketRequest(), socket.state == .idle {
            socket.connect(request)
        }
        await refresh()
    }

    func refresh() async {
        guard let api else { return }
        do {
            let boot = try await api.bootstrap()
            apply(boot)
        } catch {
            if let apiError = error as? RelayAPIError, case .unauthorized = apiError {
                showBanner("令牌已失效，请重新连接")
            } else if !hasBootstrapped {
                showBanner(error.localizedDescription)
            }
        }
    }

    private func resync() async {
        await refresh()
        if let active = activeSessionId {
            await reloadMessages(active)
        }
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        guard isPaired else { return }
        if phase == .active {
            socket.ensureConnected()
            Task { await resync() }
        }
    }

    private func apply(_ boot: BootstrapResponse) {
        agents = boot.agents
        sessions = boot.sessions.sorted { $0.updatedAt > $1.updatedAt }
        defaultCwd = boot.defaultCwd
        barkUrl = boot.settings.barkUrl
        hasBootstrapped = true
        let known = Set(sessions.map(\.id))
        messages = messages.filter { known.contains($0.key) }
    }

    // MARK: - Pairing

    @discardableResult
    func connect(serverURL raw: String, token rawToken: String) async -> Bool {
        connectError = nil
        guard let url = RelayAPI.normalizedBaseURL(from: raw) else {
            connectError = "请输入有效的服务端地址，例如 https://relay.example.com"
            return false
        }
        let cleanToken = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = RelayAPI(baseURL: url, token: cleanToken)
        isConnecting = true
        defer { isConnecting = false }

        do {
            let boot = try await candidate.bootstrap()
            socket.disconnect()
            KeychainStore.set(url.absoluteString, for: .serverURL)
            KeychainStore.set(cleanToken, for: .bearerToken)
            serverURLString = url.absoluteString
            token = cleanToken
            messages = [:]
            apply(boot)
            withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) {
                isPaired = true
            }
            if let request = candidate.webSocketRequest() {
                socket.connect(request)
            }
            Haptics.success()
            return true
        } catch {
            connectError = error.localizedDescription
            Haptics.error()
            return false
        }
    }

    func signOut() {
        socket.disconnect()
        KeychainStore.delete(.serverURL)
        KeychainStore.delete(.bearerToken)
        withAnimation(.spring(response: 0.5, dampingFraction: 0.9)) {
            isPaired = false
            sessions = []
            agents = []
            messages = [:]
            hasBootstrapped = false
            activeSessionId = nil
            quotas = nil
            quotaError = nil
        }
        serverURLString = ""
        token = ""
        barkUrl = ""
    }

    /// `relay://connect?url=https://host&token=XXXX`
    func handleDeepLink(_ url: URL) {
        guard url.scheme?.lowercased() == "relay" else { return }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let target = (url.host ?? components?.path ?? "").lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard target == "connect" || target == "pair" else { return }
        let items = components?.queryItems ?? []
        let server = items.first(where: { $0.name == "url" || $0.name == "server" })?.value ?? ""
        let tok = items.first(where: { $0.name == "token" })?.value ?? ""
        guard !server.isEmpty else {
            showBanner("配对链接缺少 url 参数")
            return
        }
        pendingPairing = PairingRequest(serverURL: server, token: tok)
    }

    func confirmPairing(_ request: PairingRequest) async {
        pendingPairing = nil
        let ok = await connect(serverURL: request.serverURL, token: request.token)
        if ok {
            showBanner("已连接到 \(serverHost)", isError: false)
        } else if let err = connectError {
            showBanner(err)
        }
    }

    // MARK: - Banner

    func showBanner(_ message: String, isError: Bool = true) {
        bannerTask?.cancel()
        withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) {
            banner = Banner(message: message, isError: isError)
        }
        bannerTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_200_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.3)) {
                self?.banner = nil
            }
        }
    }

    // MARK: - Sessions

    func createSession(agentId: String, cwd: String? = nil) async -> SessionSummary? {
        guard let api else { return nil }
        creatingAgentIds.insert(agentId)
        defer { creatingAgentIds.remove(agentId) }
        do {
            let created = try await api.createSession(agentId: agentId, cwd: cwd)
            withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
                upsertSession(created)
            }
            if messages[created.id] == nil { messages[created.id] = [] }
            Haptics.success()
            return created
        } catch {
            Haptics.error()
            showBanner("新建会话失败：\(error.localizedDescription)")
            return nil
        }
    }

    func loadSession(_ id: String) async {
        guard api != nil else { return }
        if messages[id] == nil { loadingSessions.insert(id) }
        await reloadMessages(id)
        loadingSessions.remove(id)
    }

    private func reloadMessages(_ id: String) async {
        guard let api else { return }
        do {
            let detail = try await api.session(id: id)
            flushDeltas()
            upsertSession(detail.session)
            messages[id] = detail.messages.sorted { $0.createdAt < $1.createdAt }
        } catch {
            if let apiError = error as? RelayAPIError, case .server(let status, _) = apiError, status == 404 {
                removeSessionLocally(id)
            } else if messages[id] == nil {
                showBanner(error.localizedDescription)
            }
        }
    }

    func rename(_ id: String, to title: String) async {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let api, !trimmed.isEmpty else { return }
        let previous = session(id)
        if var s = previous {
            s.title = trimmed
            replaceSessionInPlace(s)
        }
        do {
            let updated = try await api.renameSession(id: id, title: trimmed)
            replaceSessionInPlace(updated)
            Haptics.success()
        } catch {
            if let previous { replaceSessionInPlace(previous) }
            showBanner("重命名失败：\(error.localizedDescription)")
        }
    }

    func delete(_ id: String) async {
        guard let api else { return }
        let snapshot = session(id)
        withAnimation(.spring(response: 0.4, dampingFraction: 0.9)) {
            sessions.removeAll { $0.id == id }
        }
        Haptics.tap(.medium)
        do {
            try await api.deleteSession(id: id)
            messages[id] = nil
        } catch {
            if let snapshot {
                withAnimation { upsertSession(snapshot) }
            }
            showBanner("删除失败：\(error.localizedDescription)")
        }
    }

    func fetchWorkspaces() async -> [String] {
        guard let api else { return [] }
        return (try? await api.workspaces()) ?? []
    }

    // MARK: - Quotas

    /// Loads Antigravity limits + CodeBuddy credit usage. `refresh` bypasses the server's 30s cache.
    func loadQuotas(refresh: Bool = false) async {
        guard let api, !isLoadingQuotas else { return }
        isLoadingQuotas = true
        defer { isLoadingQuotas = false }
        do {
            let overview = try await api.fetchQuotas(refresh: refresh)
            withAnimation(.spring(response: 0.5, dampingFraction: 0.86)) {
                quotas = overview
                quotaError = nil
            }
        } catch {
            quotaError = error.localizedDescription
        }
    }

    // MARK: - Config switching

    func setConfig(sessionId: String, kind: ConfigKind, configId: String? = nil, value: ConfigValue) async {
        guard let api, let previous = session(sessionId) else { return }
        let key = configKey(sessionId, kind, configId)
        guard !pendingConfigKeys.contains(key) else { return }

        var optimistic = previous
        switch kind {
        case .model:
            optimistic.currentModelId = value.stringValue
        case .mode:
            optimistic.currentModeId = value.stringValue
        case .config:
            if let idx = optimistic.configOptions.firstIndex(where: { $0.id == configId }) {
                optimistic.configOptions[idx].currentValue = value
            }
        }
        withAnimation(.snappy(duration: 0.25)) {
            replaceSessionInPlace(optimistic)
        }
        Haptics.selection()

        pendingConfigKeys.insert(key)
        defer { pendingConfigKeys.remove(key) }
        do {
            let updated = try await api.setConfig(sessionId: sessionId, kind: kind, configId: configId, value: value)
            withAnimation(.snappy(duration: 0.25)) {
                replaceSessionInPlace(updated)
            }
        } catch {
            withAnimation { replaceSessionInPlace(previous) }
            Haptics.error()
            showBanner("切换失败：\(error.localizedDescription)")
        }
    }

    // MARK: - Prompting

    @discardableResult
    func send(sessionId: String, text: String, attachments: [Attachment]) async -> Bool {
        guard let api else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return false }

        let localId = "local-\(UUID().uuidString)"
        let local = Message(
            id: localId,
            sessionId: sessionId,
            role: .user,
            content: trimmed.isEmpty ? "[附件]" : trimmed,
            attachments: attachments,
            status: "completed"
        )
        withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
            appendLocal(local)
            setRunning(sessionId, true)
        }
        Haptics.tap(.soft)

        do {
            let result = try await api.prompt(sessionId: sessionId, text: trimmed, attachmentIds: attachments.map(\.id))
            if var list = messages[sessionId] {
                list.removeAll { $0.id == localId }
                messages[sessionId] = list
            }
            insertIfAbsent(result.userMessage)
            insertIfAbsent(result.assistantMessage)
            return true
        } catch {
            withAnimation {
                if var list = messages[sessionId] {
                    list.removeAll { $0.id == localId }
                    messages[sessionId] = list
                }
                setRunning(sessionId, false)
            }
            Haptics.error()
            showBanner("发送失败：\(error.localizedDescription)")
            return false
        }
    }

    func cancel(sessionId: String) async {
        guard let api else { return }
        Haptics.tap(.rigid)
        do {
            _ = try await api.cancel(sessionId: sessionId)
        } catch {
            showBanner("停止失败：\(error.localizedDescription)")
        }
    }

    func upload(data: Data, filename: String, mimeType: String) async throws -> Attachment {
        guard let api else { throw RelayAPIError.invalidURL }
        return try await api.upload(data: data, filename: filename, mimeType: mimeType)
    }

    @discardableResult
    func saveSettings(barkUrl newValue: String, test: Bool) async -> Bool {
        guard let api else { return false }
        do {
            let saved = try await api.updateSettings(barkUrl: newValue.trimmingCharacters(in: .whitespacesAndNewlines), testBark: test)
            barkUrl = saved.barkUrl
            Haptics.success()
            showBanner(test ? "已保存，并发送测试推送" : "已保存推送设置", isError: false)
            return true
        } catch {
            Haptics.error()
            showBanner("保存失败：\(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Local mutation helpers

    private func upsertSession(_ s: SessionSummary) {
        if let idx = sessions.firstIndex(where: { $0.id == s.id }) {
            sessions[idx] = s
        } else {
            sessions.append(s)
        }
        sessions.sort { $0.updatedAt > $1.updatedAt }
    }

    /// Replace without reordering (used for config / rename so rows don't jump).
    private func replaceSessionInPlace(_ s: SessionSummary) {
        if let idx = sessions.firstIndex(where: { $0.id == s.id }) {
            sessions[idx] = s
        } else {
            upsertSession(s)
        }
    }

    private func removeSessionLocally(_ id: String) {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.9)) {
            sessions.removeAll { $0.id == id }
        }
        messages[id] = nil
    }

    private func setRunning(_ sessionId: String, _ running: Bool) {
        guard let idx = sessions.firstIndex(where: { $0.id == sessionId }) else { return }
        if sessions[idx].isRunning != running {
            sessions[idx].isRunning = running
        }
    }

    private func appendLocal(_ message: Message) {
        var list = messages[message.sessionId] ?? []
        list.append(message)
        messages[message.sessionId] = list
    }

    private func insertIfAbsent(_ message: Message) {
        guard var list = messages[message.sessionId] else { return }
        guard !list.contains(where: { $0.id == message.id }) else { return }
        list.append(message)
        list.sort { $0.createdAt < $1.createdAt }
        messages[message.sessionId] = list
    }

    private func mutateMessage(sessionId: String, messageId: String, _ body: (inout Message) -> Void) {
        guard var list = messages[sessionId], let idx = list.lastIndex(where: { $0.id == messageId }) else { return }
        body(&list[idx])
        messages[sessionId] = list
    }

    // MARK: - WebSocket events

    private static let decoder = JSONDecoder()

    private func decodePayload<P: Decodable & Sendable>(_ type: P.Type, from data: Data) -> P? {
        (try? Self.decoder.decode(WSPayload<P>.self, from: data))?.payload
    }

    private func handleSocketData(_ data: Data) {
        guard let header = try? Self.decoder.decode(WSHeader.self, from: data) else { return }
        let sid = header.sessionId ?? ""

        switch header.type {
        case "pong":
            return

        case "session_created", "session_updated", "config_updated":
            if let s = decodePayload(WSSessionPayload.self, from: data)?.session {
                if header.type == "session_created" {
                    withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) { upsertSession(s) }
                } else {
                    replaceSessionInPlace(s)
                }
            }

        case "session_deleted":
            let target = decodePayload(WSDeletedPayload.self, from: data)?.sessionId ?? sid
            removeSessionLocally(target)

        case "commands_updated":
            if let commands = decodePayload(WSCommandsPayload.self, from: data)?.commands,
               let idx = sessions.firstIndex(where: { $0.id == sid }) {
                sessions[idx].availableCommands = commands
            }

        case "usage_updated":
            if let usage = decodePayload(WSUsagePayload.self, from: data),
               let idx = sessions.firstIndex(where: { $0.id == sid }) {
                if usage.contextSize > 0 { sessions[idx].contextSize = usage.contextSize }
                sessions[idx].contextUsed = usage.contextUsed
            }

        case "turn_started":
            guard let p = decodePayload(WSTurnStartedPayload.self, from: data) else { return }
            if let s = p.session { upsertSession(s) }
            setRunning(sid, true)
            if let user = p.userMessage {
                // Swap out our optimistic local echo if present
                if var list = messages[sid], let localIdx = list.lastIndex(where: { $0.id.hasPrefix("local-") && $0.role == .user }) {
                    list.remove(at: localIdx)
                    messages[sid] = list
                }
                insertIfAbsent(user)
            }
            if let assistant = p.assistantMessage { insertIfAbsent(assistant) }

        case "thought_delta", "text_delta":
            guard let p = decodePayload(WSDeltaPayload.self, from: data) else { return }
            enqueueDelta(
                sessionId: sid,
                messageId: p.messageId,
                text: header.type == "text_delta" ? p.delta : "",
                thought: header.type == "thought_delta" ? p.delta : ""
            )

        case "tool_activity":
            guard let p = decodePayload(WSToolActivityPayload.self, from: data) else { return }
            flushDeltas()
            ensureAssistantPlaceholder(sessionId: sid, messageId: p.messageId)
            mutateMessage(sessionId: sid, messageId: p.messageId) { $0.toolCalls = p.toolCalls }

        case "turn_completed":
            guard let p = decodePayload(WSTurnCompletedPayload.self, from: data) else { return }
            flushDeltas()
            mutateMessage(sessionId: sid, messageId: p.messageId) { m in
                m.status = p.status ?? "completed"
                if let usage = p.usage { m.usage = usage }
            }
            if let s = p.session { upsertSession(s) }
            setRunning(sid, false)
            if activeSessionId == sid { Haptics.success() }
            if messages[sid] != nil {
                Task { await self.reloadMessages(sid) }
            }
            if quotas != nil {
                Task { await self.loadQuotas(refresh: true) }
            }

        case "turn_error":
            guard let p = decodePayload(WSTurnErrorPayload.self, from: data) else { return }
            flushDeltas()
            mutateMessage(sessionId: sid, messageId: p.messageId) { m in
                m.status = "error"
                if let err = p.error, !err.isEmpty, !m.content.contains(err) {
                    m.content += m.content.isEmpty ? "请求出错: \(err)" : "\n\n> 请求出错: \(err)"
                }
            }
            if let s = p.session { upsertSession(s) }
            setRunning(sid, false)
            if activeSessionId == sid { Haptics.error() }
            if messages[sid] != nil {
                Task { await self.reloadMessages(sid) }
            }

        default:
            break
        }
    }

    private func ensureAssistantPlaceholder(sessionId: String, messageId: String) {
        guard var list = messages[sessionId], !list.contains(where: { $0.id == messageId }) else { return }
        list.append(Message(id: messageId, sessionId: sessionId, role: .assistant, content: "", status: "streaming"))
        messages[sessionId] = list
    }

    private func enqueueDelta(sessionId: String, messageId: String, text: String, thought: String) {
        var pending = pendingDeltas[messageId] ?? PendingDelta(sessionId: sessionId)
        pending.text += text
        pending.thought += thought
        pendingDeltas[messageId] = pending
        guard !flushScheduled else { return }
        flushScheduled = true
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 40_000_000)
            self?.flushDeltas()
        }
    }

    private func flushDeltas() {
        flushScheduled = false
        guard !pendingDeltas.isEmpty else { return }
        let batch = pendingDeltas
        pendingDeltas = [:]
        var updated = messages
        var touchedSessions = Set<String>()
        for (messageId, delta) in batch {
            guard var list = updated[delta.sessionId] else { continue }
            if let idx = list.lastIndex(where: { $0.id == messageId }) {
                list[idx].content += delta.text
                list[idx].thinking += delta.thought
            } else {
                list.append(Message(
                    id: messageId,
                    sessionId: delta.sessionId,
                    role: .assistant,
                    content: delta.text,
                    thinking: delta.thought,
                    status: "streaming"
                ))
            }
            updated[delta.sessionId] = list
            touchedSessions.insert(delta.sessionId)
        }
        messages = updated
        for sid in touchedSessions { setRunning(sid, true) }
    }
}
