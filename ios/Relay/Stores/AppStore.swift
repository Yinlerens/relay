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

enum HomeSection: String, CaseIterable, Identifiable {
    case agent
    case tavern
    var id: String { rawValue }

    var title: String {
        switch self {
        case .agent: return "Agent"
        case .tavern: return "酒馆"
        }
    }
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
    var swarms: [SwarmSummary] = []
    var defaultCwd: String = ""
    var barkUrl: String = ""
    var hasBootstrapped = false
    var messages: [String: [Message]] = [:]
    var swarmBoardMessages: [String: [SwarmBoardMessage]] = [:]

    // MARK: UI state
    var homeSection: HomeSection = .agent
    var socketState: RelaySocket.State = .idle
    var loadingSessions: Set<String> = []
    var loadingSwarms: Set<String> = []
    var creatingAgentIds: Set<String> = []
    var creatingSwarm = false
    var pendingConfigKeys: Set<String> = []
    var banner: Banner? = nil
    var activeSessionId: String? = nil
    var pendingOpenSessionId: String? = nil

    // MARK: Quotas & credits
    var quotas: QuotaOverview? = nil
    var isLoadingQuotas = false
    var quotaError: String? = nil

    // MARK: Tavern (SillyTavern Bridge)
    var tavernStatus: TavernStatus? = nil
    var tavernLoginUsers: [TavernLoginUser] = []
    var tavernCharacters: [TavernCharacter] = []
    var tavernChats: [Int: [TavernChatFile]] = [:]
    var tavernState: TavernChatState? = nil
    var tavernVariablesJSON: String = "{}"
    var isLoadingTavern = false
    var isLoadingTavernChat = false
    var isLoadingOlderTavernMessages = false
    var isLoggingInTavern = false
    var isReloadingTavern = false
    var isMutatingTavern = false
    var tavernError: String? = nil
    var activeTavernCharacterId: Int? = nil

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

    var topLevelSessions: [SessionSummary] {
        sessions.filter { !$0.isSwarmWorker }
    }

    func swarm(id: String) -> SwarmSummary? {
        swarms.first(where: { $0.id == id })
    }

    func swarm(forSessionId sessionId: String) -> SwarmSummary? {
        if let direct = swarms.first(where: {
            $0.coordinatorSessionId == sessionId || $0.members.contains(where: { $0.sessionId == sessionId })
        }) {
            return direct
        }
        if let sid = session(sessionId)?.swarmId {
            return swarm(id: sid)
        }
        return nil
    }

    func boardMessages(for swarmId: String) -> [SwarmBoardMessage] {
        swarmBoardMessages[swarmId] ?? []
    }

    func requestOpenSession(_ sessionId: String) {
        pendingOpenSessionId = sessionId
    }

    var tavernMessages: [TavernMessage] {
        tavernState?.messages ?? []
    }

    var isTavernGenerating: Bool {
        (tavernState?.status.isGenerating ?? false) || (tavernStatus?.isGenerating ?? false)
    }

    func tavernChats(for characterId: Int) -> [TavernChatFile] {
        tavernChats[characterId] ?? []
    }

    func tavernCharacter(id: Int) -> TavernCharacter? {
        tavernCharacters.first(where: { $0.id == id })
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
            if let sw = swarm(forSessionId: active) {
                await loadSwarm(sw.id)
            }
        }
        if activeTavernCharacterId != nil {
            await loadTavernCurrent()
        } else if homeSection == .tavern {
            await loadTavernOverview()
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
        swarms = boot.swarms.sorted { $0.updatedAt > $1.updatedAt }
        defaultCwd = boot.defaultCwd
        barkUrl = boot.settings.barkUrl
        hasBootstrapped = true
        let known = Set(sessions.map(\.id))
        messages = messages.filter { known.contains($0.key) }
        let knownSwarms = Set(swarms.map(\.id))
        swarmBoardMessages = swarmBoardMessages.filter { knownSwarms.contains($0.key) }
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
            swarmBoardMessages = [:]
            pendingOpenSessionId = nil
            resetTavernState()
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
            swarms = []
            agents = []
            messages = [:]
            swarmBoardMessages = [:]
            hasBootstrapped = false
            activeSessionId = nil
            pendingOpenSessionId = nil
            creatingSwarm = false
            loadingSwarms = []
            quotas = nil
            quotaError = nil
            homeSection = .agent
            resetTavernState()
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

    // MARK: - Swarms

    func fetchAgentModels(agentId: String) async -> AgentModelsResponse? {
        guard let api else { return nil }
        return try? await api.agentModels(agentId: agentId)
    }

    func createSwarm(
        title: String? = nil,
        cwd: String? = nil,
        coordinatorAgentId: String? = nil,
        coordinatorModelId: String? = nil,
        defaultWorkerAgentId: String? = nil,
        defaultWorkerModelId: String? = nil
    ) async -> CreateSwarmResponse? {
        guard let api, !creatingSwarm else { return nil }
        creatingSwarm = true
        defer { creatingSwarm = false }
        do {
            let created = try await api.createSwarm(
                title: title,
                cwd: cwd,
                coordinatorAgentId: coordinatorAgentId,
                coordinatorModelId: coordinatorModelId,
                defaultWorkerAgentId: defaultWorkerAgentId,
                defaultWorkerModelId: defaultWorkerModelId
            )
            withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
                upsertSwarm(created.swarm)
                upsertSession(created.session)
            }
            if messages[created.session.id] == nil { messages[created.session.id] = [] }
            if swarmBoardMessages[created.swarm.id] == nil { swarmBoardMessages[created.swarm.id] = [] }
            Haptics.success()
            return created
        } catch {
            Haptics.error()
            showBanner("启动蜂群失败：\(error.localizedDescription)")
            return nil
        }
    }

    func loadSwarm(_ id: String) async {
        guard let api else { return }
        loadingSwarms.insert(id)
        defer { loadingSwarms.remove(id) }
        do {
            let detail = try await api.swarmDetail(id: id)
            upsertSwarm(detail.swarm)
            swarmBoardMessages[id] = detail.messages.sorted { $0.seq < $1.seq }
        } catch {
            if let apiError = error as? RelayAPIError, case .server(let status, _) = apiError, status == 404 {
                removeSwarmLocally(id)
            } else if swarm(id: id) == nil {
                showBanner(error.localizedDescription)
            }
        }
    }

    @discardableResult
    func addSwarmWorker(
        swarmId: String,
        name: String,
        brief: String,
        agentId: String? = nil,
        modelId: String? = nil,
        workspace: String = "inherit"
    ) async -> SwarmMember? {
        guard let api else { return nil }
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let cleanBrief = brief.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty, !cleanBrief.isEmpty else { return nil }
        do {
            let res = try await api.addSwarmWorker(
                swarmId: swarmId,
                name: cleanName,
                brief: cleanBrief,
                agentId: agentId,
                modelId: modelId,
                workspace: workspace
            )
            withAnimation(.spring(response: 0.4, dampingFraction: 0.86)) {
                upsertSwarm(res.swarm)
            }
            Task { await self.loadSwarm(swarmId) }
            Haptics.success()
            showBanner("已派发工人 @\(res.member.name)", isError: false)
            return res.member
        } catch {
            Haptics.error()
            showBanner("添加工人失败：\(error.localizedDescription)")
            return nil
        }
    }

    @discardableResult
    func postSwarmBoard(swarmId: String, text: String) async -> Bool {
        guard let api else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        do {
            let res = try await api.postSwarmBoard(swarmId: swarmId, text: trimmed)
            withAnimation(.spring(response: 0.36, dampingFraction: 0.86)) {
                upsertSwarm(res.swarm)
                insertBoardMessage(res.message, swarmId: swarmId)
            }
            Haptics.tap(.soft)
            return true
        } catch {
            Haptics.error()
            showBanner("发帖失败：\(error.localizedDescription)")
            return false
        }
    }

    @discardableResult
    func killSwarmWorker(swarmId: String, name: String, removeWorktree: Bool = true) async -> Bool {
        guard let api else { return false }
        do {
            let updated = try await api.killSwarmWorker(swarmId: swarmId, name: name, removeWorktree: removeWorktree)
            withAnimation(.spring(response: 0.36, dampingFraction: 0.88)) {
                upsertSwarm(updated)
            }
            Haptics.tap(.medium)
            showBanner("已终止工人 @\(name)", isError: false)
            return true
        } catch {
            Haptics.error()
            showBanner("终止工人失败：\(error.localizedDescription)")
            return false
        }
    }

    func deleteSwarm(_ id: String) async {
        guard let api else { return }
        let swarmSnapshot = swarm(id: id)
        let sessionSnapshots = sessions.filter { $0.swarmId == id || $0.id == swarmSnapshot?.coordinatorSessionId }
        let removedIds = Set(sessionSnapshots.map(\.id))
        withAnimation(.spring(response: 0.4, dampingFraction: 0.9)) {
            swarms.removeAll { $0.id == id }
            sessions.removeAll { removedIds.contains($0.id) }
        }
        swarmBoardMessages[id] = nil
        for sid in removedIds { messages[sid] = nil }
        Haptics.tap(.medium)
        do {
            try await api.deleteSwarm(id: id)
        } catch {
            withAnimation {
                if let swarmSnapshot { upsertSwarm(swarmSnapshot) }
                for s in sessionSnapshots { upsertSession(s) }
            }
            showBanner("删除蜂群失败：\(error.localizedDescription)")
        }
    }

    // MARK: - Tavern (SillyTavern Bridge)

    private func resetTavernState() {
        tavernStatus = nil
        tavernLoginUsers = []
        tavernCharacters = []
        tavernChats = [:]
        tavernState = nil
        tavernVariablesJSON = "{}"
        isLoadingTavern = false
        isLoadingTavernChat = false
        isLoadingOlderTavernMessages = false
        isLoggingInTavern = false
        isReloadingTavern = false
        isMutatingTavern = false
        tavernError = nil
        activeTavernCharacterId = nil
        TavernAssetCache.shared.clear()
    }

    private func applyTavernState(_ state: TavernChatState, rawVariablesJSON: String? = nil) {
        tavernState = state
        tavernStatus = state.status
        tavernVariablesJSON = rawVariablesJSON ?? state.variablesJSON
        if let char = state.character,
           let idx = tavernCharacters.firstIndex(where: { $0.id == char.id }) {
            tavernCharacters[idx] = char
        }
    }

    func loadTavernOverview() async {
        guard let api else { return }
        isLoadingTavern = true
        defer { isLoadingTavern = false }
        do {
            let statusRes = try await api.tavernStatus()
            tavernStatus = statusRes.status
            if let users = statusRes.loginUsers {
                tavernLoginUsers = users
            }
            tavernError = nil
            if statusRes.status.enabled && statusRes.status.ready && !statusRes.status.needsLogin {
                let charsRes = try await api.tavernCharacters()
                tavernStatus = charsRes.status
                withAnimation(.easeOut(duration: 0.22)) {
                    tavernCharacters = charsRes.characters
                }
            }
        } catch {
            tavernError = error.localizedDescription
        }
    }

    @discardableResult
    func loginTavern(handle: String, password: String) async -> Bool {
        guard let api, !isLoggingInTavern else { return false }
        let cleanHandle = handle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanHandle.isEmpty else {
            showBanner("请输入酒馆用户名")
            return false
        }
        isLoggingInTavern = true
        defer { isLoggingInTavern = false }
        do {
            let res = try await api.tavernLogin(handle: cleanHandle, password: password)
            tavernStatus = res.status
            if let users = res.loginUsers { tavernLoginUsers = users }
            if res.status.needsLogin {
                Haptics.error()
                showBanner(res.status.lastError ?? "酒馆登录失败，请检查账号密码")
                return false
            }
            Haptics.success()
            showBanner("已登录酒馆", isError: false)
            await loadTavernOverview()
            return true
        } catch {
            Haptics.error()
            showBanner("酒馆登录失败：\(error.localizedDescription)")
            return false
        }
    }

    func reloadTavern() async {
        guard let api, !isReloadingTavern else { return }
        isReloadingTavern = true
        defer { isReloadingTavern = false }
        do {
            let res = try await api.tavernReload()
            tavernStatus = res.status
            tavernCharacters = res.characters
            TavernAssetCache.shared.clear()
            Haptics.success()
            showBanner("已同步原版酒馆配置", isError: false)
            if activeTavernCharacterId != nil {
                await loadTavernCurrent()
            }
        } catch {
            Haptics.error()
            showBanner("同步失败：\(error.localizedDescription)")
        }
    }

    func loadTavernChats(characterId: Int) async {
        guard let api else { return }
        do {
            let res = try await api.tavernCharacterChats(characterId: characterId)
            tavernChats[characterId] = res.chats
        } catch {
            showBanner("读取历史聊天失败：\(error.localizedDescription)")
        }
    }

    func selectTavernCharacter(id: Int, chatFile: String? = nil, createNew: Bool = false) async {
        guard let api else { return }
        isLoadingTavernChat = true
        defer { isLoadingTavernChat = false }
        do {
            let res = try await api.tavernSelect(characterId: id, chatFile: chatFile, createNew: createNew)
            withAnimation(.easeOut(duration: 0.22)) {
                applyTavernState(res.state)
            }
            if createNew {
                Haptics.success()
                Task { await self.loadTavernChats(characterId: id) }
            }
        } catch {
            Haptics.error()
            showBanner("切换角色聊天失败：\(error.localizedDescription)")
        }
    }

    func loadTavernCurrent() async {
        guard let api else { return }
        do {
            let res = try await api.tavernCurrent()
            applyTavernState(res.state)
        } catch {
            if tavernState == nil {
                showBanner("读取当前酒馆会话失败：\(error.localizedDescription)")
            }
        }
    }

    func loadOlderTavernMessages() async {
        guard let api,
              !isLoadingOlderTavernMessages,
              let current = tavernState,
              current.hasMore == true,
              let oldestMesId = current.messages.map(\.mesId).min(),
              oldestMesId > 0 else { return }

        let anchorCharacterId = current.character?.id
        let anchorChatFile = current.chatFile
        isLoadingOlderTavernMessages = true
        defer { isLoadingOlderTavernMessages = false }

        do {
            let res = try await api.tavernCurrent(limit: 25, before: oldestMesId)
            guard var latest = tavernState,
                  latest.character?.id == anchorCharacterId,
                  latest.chatFile == anchorChatFile else { return }

            var byId: [Int: TavernMessage] = [:]
            for m in res.state.messages {
                byId[m.mesId] = m
            }
            for m in latest.messages {
                byId[m.mesId] = m
            }
            latest.messages = byId.values.sorted { $0.mesId < $1.mesId }
            latest.hasMore = res.state.hasMore
            if let total = res.state.totalMessageCount {
                latest.totalMessageCount = total
            }
            tavernState = latest
            Haptics.selection()
        } catch {
            showBanner("加载更早消息失败：\(error.localizedDescription)")
        }
    }

    @discardableResult
    func sendTavernMessage(text: String) async -> Bool {
        guard let api else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        tavernStatus?.isGenerating = true
        tavernState?.status.isGenerating = true
        Haptics.tap(.soft)
        do {
            let res = try await api.tavernSend(text: trimmed)
            withAnimation(.spring(response: 0.36, dampingFraction: 0.86)) {
                applyTavernState(res.state)
            }
            return true
        } catch {
            tavernStatus?.isGenerating = false
            tavernState?.status.isGenerating = false
            Haptics.error()
            showBanner("发送失败：\(error.localizedDescription)")
            return false
        }
    }

    func stopTavernGeneration() async {
        guard let api else { return }
        Haptics.tap(.rigid)
        do {
            _ = try await api.tavernStop()
            tavernStatus?.isGenerating = false
            tavernState?.status.isGenerating = false
        } catch {
            showBanner("停止生成失败：\(error.localizedDescription)")
        }
    }

    func regenerateTavern() async {
        guard let api else { return }
        tavernStatus?.isGenerating = true
        tavernState?.status.isGenerating = true
        Haptics.tap(.soft)
        do {
            _ = try await api.tavernRegenerate()
        } catch {
            tavernStatus?.isGenerating = false
            tavernState?.status.isGenerating = false
            Haptics.error()
            showBanner("重新生成失败：\(error.localizedDescription)")
        }
    }

    func continueTavern() async {
        guard let api else { return }
        tavernStatus?.isGenerating = true
        tavernState?.status.isGenerating = true
        Haptics.tap(.soft)
        do {
            _ = try await api.tavernContinue()
        } catch {
            tavernStatus?.isGenerating = false
            tavernState?.status.isGenerating = false
            Haptics.error()
            showBanner("继续生成失败：\(error.localizedDescription)")
        }
    }

    func swipeTavern(mesId: Int, direction: TavernSwipeDirection) async {
        guard let api, !isMutatingTavern else { return }
        isMutatingTavern = true
        defer { isMutatingTavern = false }
        Haptics.selection()
        do {
            let res = try await api.tavernSwipe(mesId: mesId, direction: direction)
            withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                applyTavernState(res.state)
            }
        } catch {
            Haptics.error()
            showBanner("切换回复失败：\(error.localizedDescription)")
        }
    }

    @discardableResult
    func editTavernMessage(mesId: Int, text: String) async -> Bool {
        guard let api else { return false }
        isMutatingTavern = true
        defer { isMutatingTavern = false }
        do {
            let res = try await api.tavernEditMessage(mesId: mesId, text: text)
            applyTavernState(res.state)
            Haptics.success()
            return true
        } catch {
            Haptics.error()
            showBanner("编辑消息失败：\(error.localizedDescription)")
            return false
        }
    }

    func deleteTavernMessage(mesId: Int) async {
        guard let api else { return }
        isMutatingTavern = true
        defer { isMutatingTavern = false }
        do {
            let res = try await api.tavernDeleteMessage(mesId: mesId)
            withAnimation(.spring(response: 0.36, dampingFraction: 0.88)) {
                applyTavernState(res.state)
            }
            Haptics.tap(.medium)
        } catch {
            Haptics.error()
            showBanner("删除楼层失败：\(error.localizedDescription)")
        }
    }

    @discardableResult
    func runTavernSlash(_ command: String) async -> String? {
        guard let api else { return nil }
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        do {
            let res = try await api.tavernSlash(command: trimmed)
            applyTavernState(res.state)
            if let result = res.result, !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                showBanner(result, isError: false)
            }
            return res.result
        } catch {
            Haptics.error()
            showBanner("指令执行失败：\(error.localizedDescription)")
            return nil
        }
    }

    /// Extracts raw `payload.variables` or `payload.state.variables` JSON string directly for lossless WebView injection.
    private static func extractRawVariablesJSON(from data: Data, nestedInState: Bool) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = root["payload"] as? [String: Any] else {
            return nil
        }
        let container: [String: Any]? = nestedInState ? (payload["state"] as? [String: Any]) : payload
        guard let vars = container?["variables"],
              JSONSerialization.isValidJSONObject(vars),
              let encoded = try? JSONSerialization.data(withJSONObject: vars, options: []),
              let str = String(data: encoded, encoding: .utf8) else {
            return nil
        }
        return str
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

    private func upsertSwarm(_ s: SwarmSummary) {
        if let idx = swarms.firstIndex(where: { $0.id == s.id }) {
            swarms[idx] = s
        } else {
            swarms.append(s)
        }
        swarms.sort { $0.updatedAt > $1.updatedAt }
    }

    private func removeSwarmLocally(_ id: String) {
        let coordId = swarm(id: id)?.coordinatorSessionId
        let removedIds = Set(sessions.filter { $0.swarmId == id || (coordId != nil && $0.id == coordId) }.map(\.id))
        withAnimation(.spring(response: 0.4, dampingFraction: 0.9)) {
            swarms.removeAll { $0.id == id }
            sessions.removeAll { removedIds.contains($0.id) }
        }
        swarmBoardMessages[id] = nil
        for sid in removedIds { messages[sid] = nil }
    }

    private func insertBoardMessage(_ message: SwarmBoardMessage, swarmId: String) {
        var list = swarmBoardMessages[swarmId] ?? []
        if let idx = list.firstIndex(where: { $0.seq == message.seq || ($0.id != 0 && $0.id == message.id) }) {
            list[idx] = message
        } else {
            list.append(message)
        }
        list.sort { $0.seq < $1.seq }
        swarmBoardMessages[swarmId] = list
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

        case "swarm_created":
            if let sw = decodePayload(WSSwarmPayload.self, from: data)?.swarm {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
                    upsertSwarm(sw)
                }
            }

        case "swarm_updated":
            if let sw = decodePayload(WSSwarmPayload.self, from: data)?.swarm {
                upsertSwarm(sw)
            }

        case "swarm_deleted":
            if let target = decodePayload(WSSwarmDeletedPayload.self, from: data)?.swarmId {
                removeSwarmLocally(target)
            }

        case "swarm_board_post":
            if let p = decodePayload(WSSwarmBoardPostPayload.self, from: data) {
                if let sw = p.swarm { upsertSwarm(sw) }
                if let msg = p.message {
                    let targetId = p.swarmId ?? msg.swarmId
                    if !targetId.isEmpty {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
                            insertBoardMessage(msg, swarmId: targetId)
                        }
                    }
                }
            }

        case "tavern_status":
            if let st = decodePayload(WSTavernStatusPayload.self, from: data)?.status {
                tavernStatus = st
                if var current = tavernState {
                    current.status = st
                    if !st.isGenerating {
                        for idx in current.messages.indices where current.messages[idx].isStreaming {
                            current.messages[idx].isStreaming = false
                        }
                    }
                    tavernState = current
                }
            }

        case "tavern_stream_delta":
            guard let p = decodePayload(WSTavernStreamDeltaPayload.self, from: data) else { return }
            guard var state = tavernState else {
                tavernStatus?.isGenerating = true
                return
            }
            if let cid = p.characterId, let currentId = state.character?.id, cid != currentId { return }
            if let cf = p.chatFile, let currentCf = state.chatFile, !cf.isEmpty, !currentCf.isEmpty, cf != currentCf { return }
            if let idx = state.messages.lastIndex(where: { $0.mesId == p.mesId }) {
                let existing = state.messages[idx]
                // Never overwrite a finalized rendered message when a stale identical delta arrives.
                if !existing.blocks.isEmpty && p.text == existing.rawText {
                    return
                }
                tavernStatus?.isGenerating = true
                state.status.isGenerating = true
                state.messages[idx].rawText = p.text
                if !p.reasoning.isEmpty {
                    state.messages[idx].reasoning = p.reasoning
                }
                state.messages[idx].isStreaming = true
            } else {
                tavernStatus?.isGenerating = true
                state.status.isGenerating = true
                let placeholder = TavernMessage(
                    mesId: p.mesId,
                    name: state.character?.name ?? "角色",
                    avatarUrl: state.character?.avatarUrl,
                    isUser: false,
                    isSystem: false,
                    sendDate: "",
                    rawText: p.text,
                    reasoning: p.reasoning,
                    swipeId: 0,
                    swipeCount: 1,
                    blocks: [],
                    renderedHash: "stream-\(p.mesId)",
                    isStreaming: true
                )
                state.messages.append(placeholder)
                state.messages.sort { $0.mesId < $1.mesId }
            }
            tavernState = state

        case "tavern_message_finalized":
            guard let p = decodePayload(WSTavernMessageFinalizedPayload.self, from: data) else { return }
            let stillGenerating = p.isGenerating ?? false
            tavernStatus?.isGenerating = stillGenerating
            if var state = tavernState {
                let matchesChar = p.characterId == nil || state.character?.id == p.characterId
                if matchesChar {
                    state.status.isGenerating = stillGenerating
                    if let msg = p.message {
                        if let idx = state.messages.lastIndex(where: { $0.mesId == msg.mesId }) {
                            state.messages[idx] = msg
                        } else {
                            state.messages.append(msg)
                            state.messages.sort { $0.mesId < $1.mesId }
                        }
                    }
                    if let vars = p.variables {
                        state.variables = vars
                    }
                    let rawJSON = Self.extractRawVariablesJSON(from: data, nestedInState: false)
                    applyTavernState(state, rawVariablesJSON: rawJSON ?? (p.variables != nil ? state.variablesJSON : tavernVariablesJSON))
                    if activeTavernCharacterId != nil && !stillGenerating {
                        Haptics.success()
                    }
                }
            }

        case "tavern_chat_updated":
            if let st = decodePayload(WSTavernChatUpdatedPayload.self, from: data)?.state {
                let rawJSON = Self.extractRawVariablesJSON(from: data, nestedInState: true)
                applyTavernState(st, rawVariablesJSON: rawJSON)
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
