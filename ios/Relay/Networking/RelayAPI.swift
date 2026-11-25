import Foundation

enum RelayAPIError: LocalizedError {
    case invalidURL
    case unauthorized
    case server(status: Int, message: String)
    case decoding(String)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "服务端地址无效"
        case .unauthorized:
            return "令牌无效或已过期（401）"
        case .server(let status, let message):
            return message.isEmpty ? "服务端错误（\(status)）" : message
        case .decoding(let detail):
            return "无法解析服务端响应：\(detail)"
        case .transport(let detail):
            return detail
        }
    }
}

/// Stateless REST client for the Relay control plane. Every `/api/*` call carries `Authorization: Bearer`.
struct RelayAPI: Sendable {
    let baseURL: URL
    let token: String

    static func normalizedBaseURL(from raw: String) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.lowercased().hasPrefix("http://") && !text.lowercased().hasPrefix("https://") {
            text = "https://" + text
        }
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text), url.host != nil else { return nil }
        return url
    }

    // MARK: Request plumbing

    private static var decoder: JSONDecoder { JSONDecoder() }

    func url(_ path: String) -> URL {
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        return baseURL.appendingPathComponent(trimmed)
    }

    func authorizedRequest(_ path: String, method: String = "GET") -> URLRequest {
        var request = URLRequest(url: url(path))
        request.httpMethod = method
        request.timeoutInterval = 60
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func send<T: Decodable & Sendable>(_ request: URLRequest, as type: T.Type) async throws -> T {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError {
            throw RelayAPIError.transport(Self.describe(error))
        } catch {
            throw RelayAPIError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw RelayAPIError.transport("无效的响应")
        }
        if http.statusCode == 401 { throw RelayAPIError.unauthorized }
        guard (200..<300).contains(http.statusCode) else {
            let body = try? Self.decoder.decode(ServerErrorBody.self, from: data)
            let message = body?.message ?? body?.error ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw RelayAPIError.server(status: http.statusCode, message: message)
        }
        do {
            return try Self.decoder.decode(T.self, from: data)
        } catch {
            throw RelayAPIError.decoding(String(describing: error).prefix(240).description)
        }
    }

    private func json<T: Decodable & Sendable>(
        _ path: String,
        method: String = "GET",
        body: [String: Any]? = nil,
        as type: T.Type
    ) async throws -> T {
        var request = authorizedRequest(path, method: method)
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return try await send(request, as: type)
    }

    static func describe(_ error: URLError) -> String {
        switch error.code {
        case .notConnectedToInternet: return "网络不可用"
        case .timedOut: return "连接超时"
        case .cannotFindHost, .dnsLookupFailed: return "找不到服务器"
        case .cannotConnectToHost: return "无法连接到服务器"
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate:
            return "TLS 安全连接失败"
        case .cancelled: return "请求已取消"
        default: return error.localizedDescription
        }
    }

    // MARK: Endpoints

    func health() async throws -> HealthResponse {
        var request = URLRequest(url: url("/healthz"))
        request.timeoutInterval = 12
        return try await send(request, as: HealthResponse.self)
    }

    func bootstrap() async throws -> BootstrapResponse {
        try await json("/api/bootstrap", as: BootstrapResponse.self)
    }

    func workspaces() async throws -> [String] {
        try await json("/api/workspaces", as: WorkspacesResponse.self).workspaces
    }

    func createSession(agentId: String, cwd: String? = nil, title: String? = nil) async throws -> SessionSummary {
        var body: [String: Any] = ["agentId": agentId]
        if let cwd, !cwd.isEmpty { body["cwd"] = cwd }
        if let title, !title.isEmpty { body["title"] = title }
        var request = authorizedRequest("/api/sessions", method: "POST")
        request.timeoutInterval = 120
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return try await send(request, as: SessionEnvelope.self).session
    }

    func session(id: String) async throws -> SessionDetailResponse {
        try await json("/api/sessions/\(id)", as: SessionDetailResponse.self)
    }

    func renameSession(id: String, title: String) async throws -> SessionSummary {
        try await json("/api/sessions/\(id)", method: "PATCH", body: ["title": title], as: SessionEnvelope.self).session
    }

    func deleteSession(id: String) async throws {
        _ = try await json("/api/sessions/\(id)", method: "DELETE", as: OkResponse.self)
    }

    func setConfig(sessionId: String, kind: ConfigKind, configId: String?, value: ConfigValue) async throws -> SessionSummary {
        var body: [String: Any] = ["kind": kind.rawValue]
        if let configId { body["configId"] = configId }
        switch value {
        case .string(let s): body["value"] = s
        case .bool(let b): body["value"] = b
        }
        var request = authorizedRequest("/api/sessions/\(sessionId)/config", method: "POST")
        request.timeoutInterval = 90
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return try await send(request, as: SessionEnvelope.self).session
    }

    func prompt(sessionId: String, text: String, attachmentIds: [String]) async throws -> PromptResponse {
        var body: [String: Any] = ["text": text]
        if !attachmentIds.isEmpty { body["attachmentIds"] = attachmentIds }
        return try await json("/api/sessions/\(sessionId)/prompt", method: "POST", body: body, as: PromptResponse.self)
    }

    func cancel(sessionId: String) async throws -> Bool {
        var request = authorizedRequest("/api/sessions/\(sessionId)/cancel", method: "POST")
        request.httpBody = Data("{}".utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return try await send(request, as: CancelResponse.self).cancelled
    }

    func upload(data: Data, filename: String, mimeType: String) async throws -> Attachment {
        let boundary = "RelayBoundary-\(UUID().uuidString)"
        var request = authorizedRequest("/api/uploads", method: "POST")
        request.timeoutInterval = 180
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let safeName = filename.replacingOccurrences(of: "\"", with: "_")
        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"\(safeName)\"\r\n".utf8))
        body.append(Data("Content-Type: \(mimeType)\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        request.httpBody = body

        return try await send(request, as: Attachment.self)
    }

    func uploadData(id: String) async throws -> Data {
        let request = authorizedRequest("/api/uploads/\(id)")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw RelayAPIError.server(status: (response as? HTTPURLResponse)?.statusCode ?? 0, message: "附件加载失败")
        }
        return data
    }

    func settings() async throws -> ServerSettings {
        try await json("/api/settings", as: ServerSettings.self)
    }

    /// `GET /api/quotas[?refresh=1]` — Antigravity model limits + CodeBuddy credit consumption.
    func fetchQuotas(refresh: Bool = false) async throws -> QuotaOverview {
        var request = authorizedRequest("/api/quotas")
        request.timeoutInterval = 45
        if refresh, let base = request.url, var components = URLComponents(url: base, resolvingAgainstBaseURL: false) {
            components.queryItems = [URLQueryItem(name: "refresh", value: "1")]
            request.url = components.url ?? base
        }
        return try await send(request, as: QuotaOverview.self)
    }

    func updateSettings(barkUrl: String, testBark: Bool) async throws -> ServerSettings {
        try await json(
            "/api/settings",
            method: "PUT",
            body: ["barkUrl": barkUrl, "testBark": testBark],
            as: ServerSettings.self
        )
    }

    // MARK: Swarm endpoints

    func agentModels(agentId: String) async throws -> AgentModelsResponse {
        var request = authorizedRequest("/api/agents/\(agentId)/models")
        request.timeoutInterval = 45
        return try await send(request, as: AgentModelsResponse.self)
    }

    func swarms() async throws -> [SwarmSummary] {
        try await json("/api/swarms", as: SwarmListResponse.self).swarms
    }

    func createSwarm(
        title: String? = nil,
        cwd: String? = nil,
        coordinatorAgentId: String? = nil,
        coordinatorModelId: String? = nil,
        defaultWorkerAgentId: String? = nil,
        defaultWorkerModelId: String? = nil
    ) async throws -> CreateSwarmResponse {
        var body: [String: Any] = [:]
        if let title, !title.isEmpty { body["title"] = title }
        if let cwd, !cwd.isEmpty { body["cwd"] = cwd }
        if let coordinatorAgentId, !coordinatorAgentId.isEmpty { body["coordinatorAgentId"] = coordinatorAgentId }
        if let coordinatorModelId, !coordinatorModelId.isEmpty { body["coordinatorModelId"] = coordinatorModelId }
        if let defaultWorkerAgentId, !defaultWorkerAgentId.isEmpty { body["defaultWorkerAgentId"] = defaultWorkerAgentId }
        if let defaultWorkerModelId, !defaultWorkerModelId.isEmpty { body["defaultWorkerModelId"] = defaultWorkerModelId }
        var request = authorizedRequest("/api/swarms", method: "POST")
        request.timeoutInterval = 120
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return try await send(request, as: CreateSwarmResponse.self)
    }

    func swarmDetail(id: String) async throws -> SwarmDetailResponse {
        try await json("/api/swarms/\(id)", as: SwarmDetailResponse.self)
    }

    func addSwarmWorker(
        swarmId: String,
        name: String,
        brief: String,
        agentId: String? = nil,
        modelId: String? = nil,
        workspace: String = "inherit"
    ) async throws -> SwarmWorkerCreatedResponse {
        var body: [String: Any] = [
            "name": name,
            "brief": brief,
            "workspace": workspace,
        ]
        if let agentId, !agentId.isEmpty { body["agentId"] = agentId }
        if let modelId, !modelId.isEmpty { body["modelId"] = modelId }
        var request = authorizedRequest("/api/swarms/\(swarmId)/workers", method: "POST")
        request.timeoutInterval = 120
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return try await send(request, as: SwarmWorkerCreatedResponse.self)
    }

    func postSwarmBoard(swarmId: String, text: String) async throws -> SwarmBoardPostResponse {
        try await json(
            "/api/swarms/\(swarmId)/board",
            method: "POST",
            body: ["text": text],
            as: SwarmBoardPostResponse.self
        )
    }

    func killSwarmWorker(swarmId: String, name: String, removeWorktree: Bool = true) async throws -> SwarmSummary {
        try await json(
            "/api/swarms/\(swarmId)/workers/\(name)/kill",
            method: "POST",
            body: ["removeWorktree": removeWorktree],
            as: SwarmEnvelopeResponse.self
        ).swarm
    }

    func deleteSwarm(id: String) async throws {
        _ = try await json("/api/swarms/\(id)", method: "DELETE", as: OkResponse.self)
    }

    // MARK: Tavern (SillyTavern Bridge) endpoints

    func tavernStatus() async throws -> TavernStatusResponse {
        var request = authorizedRequest("/api/tavern/status")
        request.timeoutInterval = 30
        return try await send(request, as: TavernStatusResponse.self)
    }

    func tavernLogin(handle: String, password: String) async throws -> TavernStatusResponse {
        var request = authorizedRequest("/api/tavern/login", method: "POST")
        request.timeoutInterval = 60
        request.httpBody = try JSONSerialization.data(withJSONObject: ["handle": handle, "password": password])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return try await send(request, as: TavernStatusResponse.self)
    }

    func tavernReload() async throws -> TavernReloadResponse {
        var request = authorizedRequest("/api/tavern/reload", method: "POST")
        request.timeoutInterval = 90
        request.httpBody = Data("{}".utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return try await send(request, as: TavernReloadResponse.self)
    }

    func tavernCharacters() async throws -> TavernCharactersResponse {
        var request = authorizedRequest("/api/tavern/characters")
        request.timeoutInterval = 60
        return try await send(request, as: TavernCharactersResponse.self)
    }

    func tavernCharacterChats(characterId: Int) async throws -> TavernChatsResponse {
        var request = authorizedRequest("/api/tavern/characters/\(characterId)/chats")
        request.timeoutInterval = 60
        return try await send(request, as: TavernChatsResponse.self)
    }

    func tavernSelect(
        characterId: Int,
        chatFile: String? = nil,
        createNew: Bool = false,
        knownChatFile: String? = nil,
        knownHashes: [String: String]? = nil
    ) async throws -> TavernStateResponse {
        var body: [String: Any] = ["characterId": characterId]
        if let chatFile, !chatFile.isEmpty { body["chatFile"] = chatFile }
        if createNew { body["createNew"] = true }
        if let knownChatFile, !knownChatFile.isEmpty { body["knownChatFile"] = knownChatFile }
        if let knownHashes, !knownHashes.isEmpty { body["knownHashes"] = knownHashes }
        var request = authorizedRequest("/api/tavern/select", method: "POST")
        request.timeoutInterval = 90
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return try await send(request, as: TavernStateResponse.self)
    }

    func tavernCurrent(limit: Int? = nil, before: Int? = nil) async throws -> TavernStateResponse {
        var request = authorizedRequest("/api/tavern/current")
        var queryItems: [URLQueryItem] = []
        if let limit { queryItems.append(URLQueryItem(name: "limit", value: String(limit))) }
        if let before { queryItems.append(URLQueryItem(name: "before", value: String(before))) }
        if !queryItems.isEmpty,
           let base = request.url,
           var comps = URLComponents(url: base, resolvingAgainstBaseURL: false) {
            comps.queryItems = queryItems
            request.url = comps.url ?? base
        }
        return try await send(request, as: TavernStateResponse.self)
    }

    func tavernSend(text: String) async throws -> TavernActionStateResponse {
        var request = authorizedRequest("/api/tavern/send", method: "POST")
        request.timeoutInterval = 60
        request.httpBody = try JSONSerialization.data(withJSONObject: ["text": text])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return try await send(request, as: TavernActionStateResponse.self)
    }

    func tavernStop() async throws -> TavernStopResponse {
        var request = authorizedRequest("/api/tavern/stop", method: "POST")
        request.httpBody = Data("{}".utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return try await send(request, as: TavernStopResponse.self)
    }

    func tavernRegenerate() async throws -> OkResponse {
        var request = authorizedRequest("/api/tavern/regenerate", method: "POST")
        request.timeoutInterval = 60
        request.httpBody = Data("{}".utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return try await send(request, as: OkResponse.self)
    }

    func tavernContinue() async throws -> OkResponse {
        var request = authorizedRequest("/api/tavern/continue", method: "POST")
        request.timeoutInterval = 60
        request.httpBody = Data("{}".utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return try await send(request, as: OkResponse.self)
    }

    func tavernSwipe(mesId: Int, direction: TavernSwipeDirection) async throws -> TavernMessageMutationResponse {
        var request = authorizedRequest("/api/tavern/swipe", method: "POST")
        request.timeoutInterval = 60
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "mesId": mesId,
            "direction": direction.rawValue,
        ])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return try await send(request, as: TavernMessageMutationResponse.self)
    }

    func tavernEditMessage(mesId: Int, text: String) async throws -> TavernMessageMutationResponse {
        try await json(
            "/api/tavern/messages/\(mesId)",
            method: "PATCH",
            body: ["text": text],
            as: TavernMessageMutationResponse.self
        )
    }

    func tavernDeleteMessage(mesId: Int) async throws -> TavernActionStateResponse {
        try await json(
            "/api/tavern/messages/\(mesId)",
            method: "DELETE",
            as: TavernActionStateResponse.self
        )
    }

    func tavernSlash(command: String) async throws -> TavernSlashResponse {
        var request = authorizedRequest("/api/tavern/slash", method: "POST")
        request.timeoutInterval = 60
        request.httpBody = try JSONSerialization.data(withJSONObject: ["command": command])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return try await send(request, as: TavernSlashResponse.self)
    }

    /// Fetches a SillyTavern asset via `/api/tavern/asset?path=...` (Bearer auth) or external HTTP(S) URL (no Bearer).
    /// Accepts:
    /// - `relay-st://asset?path=...`
    /// - `/api/tavern/asset?path=...`
    /// - Raw relative ST path (`/thumbnail?type=avatar&file=...`, `/characters/...`)
    /// - External `https://...` / `http://...` or `data:` URI
    func tavernAssetData(pathOrRelativeUrl raw: String) async throws -> (data: Data, mimeType: String?) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw RelayAPIError.invalidURL }

        if trimmed.hasPrefix("data:"), let dataURL = URL(string: trimmed) {
            let data = try Data(contentsOf: dataURL)
            let header = trimmed.dropFirst(5).split(separator: ",").first.map(String.init)
            let mime = header?.split(separator: ";").first.map(String.init)
            return (data, mime)
        }

        if trimmed.lowercased().hasPrefix("http://") || trimmed.lowercased().hasPrefix("https://") {
            guard let externalURL = URL(string: trimmed) else { throw RelayAPIError.invalidURL }
            var req = URLRequest(url: externalURL)
            req.timeoutInterval = 30
            // Never attach Relay Bearer token to external hosts.
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw RelayAPIError.server(status: (response as? HTTPURLResponse)?.statusCode ?? 0, message: "图片加载失败")
            }
            return (data, http.value(forHTTPHeaderField: "Content-Type"))
        }

        let extractedPath: String
        if trimmed.lowercased().hasPrefix("relay-st://") {
            guard let comps = URLComponents(string: trimmed) else {
                throw RelayAPIError.invalidURL
            }
            if let pathVal = comps.queryItems?.first(where: { $0.name == "path" })?.value, !pathVal.isEmpty {
                extractedPath = pathVal
            } else if !comps.path.isEmpty && comps.path != "/" {
                if let q = comps.percentEncodedQuery, !q.isEmpty {
                    extractedPath = "\(comps.path)?\(q)"
                } else {
                    extractedPath = comps.path
                }
            } else {
                throw RelayAPIError.invalidURL
            }
        } else if trimmed.hasPrefix("/api/tavern/asset") {
            guard let comps = URLComponents(string: trimmed),
                  let pathVal = comps.queryItems?.first(where: { $0.name == "path" })?.value,
                  !pathVal.isEmpty else {
                throw RelayAPIError.invalidURL
            }
            extractedPath = pathVal
        } else {
            extractedPath = trimmed.hasPrefix("/") ? trimmed : "/" + trimmed
        }

        guard var comps = URLComponents(url: url("/api/tavern/asset"), resolvingAgainstBaseURL: false) else {
            throw RelayAPIError.invalidURL
        }
        comps.queryItems = [URLQueryItem(name: "path", value: extractedPath)]
        guard let targetURL = comps.url else { throw RelayAPIError.invalidURL }

        var request = URLRequest(url: targetURL)
        request.timeoutInterval = 30
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw RelayAPIError.transport("无效的响应")
        }
        if http.statusCode == 401 { throw RelayAPIError.unauthorized }
        guard (200..<300).contains(http.statusCode) else {
            throw RelayAPIError.server(status: http.statusCode, message: "酒馆资源加载失败")
        }
        return (data, http.value(forHTTPHeaderField: "Content-Type"))
    }

    /// `ws(s)://host/ws` request with Bearer auth header for `URLSessionWebSocketTask`.
    func webSocketRequest() -> URLRequest? {
        guard var components = URLComponents(url: url("/ws"), resolvingAgainstBaseURL: false) else { return nil }
        components.scheme = (components.scheme?.lowercased() == "https") ? "wss" : "ws"
        guard let wsURL = components.url else { return nil }
        var request = URLRequest(url: wsURL)
        request.timeoutInterval = 30
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }
}
