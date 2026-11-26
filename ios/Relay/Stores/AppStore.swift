import SwiftUI
import UIKit
import Observation

struct Banner: Identifiable, Equatable, Sendable {
    let id = UUID()
    var message: String
    var isError: Bool = true
    var sessionId: String? = nil
    var tavernCharacterId: Int? = nil
}

struct PairingRequest: Identifiable, Equatable, Sendable {
    let id = UUID()
    var serverURL: String
    var token: String
}

enum HomeSection: String, CaseIterable, Identifiable, Sendable {
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

/// Single source of truth for the app: pairing, sessions, messages, drafts, live streaming and config switching.
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
    var agentDrafts: [String: String] = [:]
    var tavernDrafts: [Int: String] = [:]

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
    var tavernGenerationError: TavernGenerationError? = nil
    var activeTavernCharacterId: Int? = nil
    var pendingOpenTavernCharacterId: Int? = nil

    // MARK: Internal state shared across extension files
    let socket: RelaySocket
    @ObservationIgnored var pendingDeltas: [String: PendingDelta] = [:]
    @ObservationIgnored var flushScheduled = false
    @ObservationIgnored var bannerTask: Task<Void, Never>? = nil
    @ObservationIgnored var tavernConversationMemory: [String: CachedTavernConversation] = [:]
    @ObservationIgnored var latestChatByChar: [Int: String] = [:]
    @ObservationIgnored var latestChatHydrated = false
    @ObservationIgnored var lastNotifiedTavernErrorId: String? = nil
    @ObservationIgnored var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    @ObservationIgnored var draftsSaveTask: Task<Void, Never>? = nil

    struct PendingDelta {
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

        if !storedURL.isEmpty {
            Task { await RelayDiskCache.shared.setServerURL(storedURL) }
        }

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
        NotificationManager.shared.onSelectTarget = { [weak self] target in
            guard let self else { return }
            if let cid = target.tavernCharacterId {
                self.pendingOpenTavernCharacterId = cid
            } else if let sid = target.sessionId {
                self.requestOpenSession(sid)
            }
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
        await RelayDiskCache.shared.setServerURL(serverURLString)
        TavernHTMLHeightCache.shared.hydrateIfNeeded()
        await hydrateFromDiskCache()
        if let request = api.webSocketRequest(), socket.state == .idle {
            socket.connect(request)
        }
        await refresh()
    }

    private func hydrateFromDiskCache() async {
        if !hasBootstrapped, let cachedBoot = await RelayDiskCache.shared.loadBootstrap() {
            agents = cachedBoot.agents
            sessions = cachedBoot.sessions.sorted { ($0.pinned ? 1 : 0, $0.updatedAt) > ($1.pinned ? 1 : 0, $1.updatedAt) }
            swarms = cachedBoot.swarms.sorted { $0.updatedAt > $1.updatedAt }
            defaultCwd = cachedBoot.defaultCwd
            barkUrl = cachedBoot.settings.barkUrl
            hasBootstrapped = true
        }
        await hydrateDraftsIfEmpty()
        if !latestChatHydrated {
            latestChatByChar = await RelayDiskCache.shared.loadLatestChatByChar()
            latestChatHydrated = true
        }
        if tavernCharacters.isEmpty, let overview = await RelayDiskCache.shared.loadTavernOverview() {
            var st = overview.status
            st.isGenerating = false
            if tavernStatus == nil { tavernStatus = st }
            tavernCharacters = overview.characters
        }
    }

    func clearLocalCache() async {
        TavernAssetCache.shared.clear()
        AttachmentImageCache.shared.clear()
        AttachmentFileCache.shared.clear()
        TavernHTMLHeightCache.shared.clear()
        tavernConversationMemory.removeAll()
        latestChatByChar.removeAll()
        latestChatHydrated = false
        clearDraftsState()
        await RelayDiskCache.shared.clearCurrentServer()
        Haptics.success()
        showBanner("已清空本地缓存", isError: false)
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
        switch phase {
        case .active:
            endBackgroundTaskIfNeeded()
            socket.ensureConnected()
            Task { await resync() }
        case .background:
            if isTavernGenerating || sessions.contains(where: \.isRunning) {
                beginBackgroundGraceTask()
            }
        default:
            break
        }
    }

    private func beginBackgroundGraceTask() {
        guard backgroundTaskID == .invalid else { return }
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "RelayErrorWatch") { [weak self] in
            Task { @MainActor [weak self] in
                self?.endBackgroundTaskIfNeeded()
            }
        }
    }

    func endBackgroundTaskIfNeeded() {
        guard backgroundTaskID != .invalid else { return }
        let taskId = backgroundTaskID
        backgroundTaskID = .invalid
        UIApplication.shared.endBackgroundTask(taskId)
    }

    private func apply(_ boot: BootstrapResponse) {
        agents = boot.agents
        sessions = boot.sessions.sorted { ($0.pinned ? 1 : 0, $0.updatedAt) > ($1.pinned ? 1 : 0, $1.updatedAt) }
        swarms = boot.swarms.sorted { $0.updatedAt > $1.updatedAt }
        defaultCwd = boot.defaultCwd
        barkUrl = boot.settings.barkUrl
        hasBootstrapped = true
        let known = Set(sessions.map(\.id))
        messages = messages.filter { known.contains($0.key) }
        agentDrafts = agentDrafts.filter { known.contains($0.key) }
        let knownSwarms = Set(swarms.map(\.id))
        swarmBoardMessages = swarmBoardMessages.filter { knownSwarms.contains($0.key) }
        let snapshot = CachedBootstrap(
            agents: agents,
            sessions: sessions,
            swarms: swarms,
            defaultCwd: defaultCwd,
            settings: boot.settings,
            updatedAt: Date().timeIntervalSince1970 * 1000
        )
        Task { await RelayDiskCache.shared.saveBootstrap(snapshot) }
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
            await RelayDiskCache.shared.setServerURL(url.absoluteString)
            messages = [:]
            swarmBoardMessages = [:]
            pendingOpenSessionId = nil
            clearDraftsState()
            AttachmentImageCache.shared.clear()
            AttachmentFileCache.shared.clear()
            TavernHTMLHeightCache.shared.clear()
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
            clearDraftsState()
            AttachmentImageCache.shared.clear()
            AttachmentFileCache.shared.clear()
            TavernHTMLHeightCache.shared.clear()
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

    func showBanner(
        _ message: String,
        isError: Bool = true,
        sessionId: String? = nil,
        tavernCharacterId: Int? = nil
    ) {
        bannerTask?.cancel()
        withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) {
            banner = Banner(
                message: message,
                isError: isError,
                sessionId: sessionId,
                tavernCharacterId: tavernCharacterId
            )
        }
        let durationMs = isError ? 6000 : 3200
        bannerTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(durationMs))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.3)) {
                self?.banner = nil
            }
        }
    }
}
