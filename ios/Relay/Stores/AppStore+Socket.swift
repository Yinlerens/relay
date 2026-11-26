import SwiftUI

extension AppStore {
    // MARK: - WebSocket events

    private static let socketDecoder = JSONDecoder()

    private func decodePayload<P: Decodable & Sendable>(_ type: P.Type, from data: Data) -> P? {
        (try? Self.socketDecoder.decode(WSPayload<P>.self, from: data))?.payload
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

    func handleSocketData(_ data: Data) {
        guard let header = try? Self.socketDecoder.decode(WSHeader.self, from: data) else { return }
        let sid = header.sessionId ?? ""

        switch header.type {
        case "pong":
            return

        case "session_created", "session_updated", "config_updated":
            if let s = decodePayload(WSSessionPayload.self, from: data)?.session {
                if header.type == "session_created" {
                    withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) { upsertSession(s) }
                } else if header.type == "session_updated" {
                    upsertSession(s)
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
            if let list = messages[sid], let sess = session(sid) {
                let snapshot = CachedAgentSession(
                    session: sess,
                    messages: list,
                    updatedAt: Date().timeIntervalSince1970 * 1000
                )
                Task { await RelayDiskCache.shared.saveAgentSession(snapshot) }
                Task { await self.reloadMessages(sid) }
            }
            if quotas != nil {
                Task { await self.loadQuotas(refresh: true) }
            }
            if !isTavernGenerating && !sessions.contains(where: \.isRunning) {
                endBackgroundTaskIfNeeded()
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
            if let err = p.error?.trimmingCharacters(in: .whitespacesAndNewlines), !err.isEmpty {
                let title = session(sid)?.title ?? "会话"
                showBanner("Agent 出错：\(err)", isError: true, sessionId: sid)
                NotificationManager.shared.notifyError(
                    title: "Agent · \(title) 出错",
                    body: err,
                    identifier: "agent-err-\(p.messageId)",
                    sessionId: sid
                )
            }
            if messages[sid] != nil {
                Task { await self.reloadMessages(sid) }
            }
            if !isTavernGenerating && !sessions.contains(where: \.isRunning) {
                endBackgroundTaskIfNeeded()
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
                        if let sw = p.swarm ?? swarm(id: targetId), let list = swarmBoardMessages[targetId] {
                            let snapshot = CachedSwarmDetail(
                                swarm: sw,
                                messages: list,
                                updatedAt: Date().timeIntervalSince1970 * 1000
                            )
                            Task { await RelayDiskCache.shared.saveSwarmDetail(snapshot) }
                        }
                    }
                }
            }

        case "tavern_status":
            if let st = decodePayload(WSTavernStatusPayload.self, from: data)?.status {
                tavernStatus = st
                syncGenerationError(from: st, notifyIfNew: true)
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
            tavernGenerationError = nil
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
            if !stillGenerating && p.message?.isUser != true {
                tavernGenerationError = nil
                tavernStatus?.lastGenerationError = nil
            }
            if var state = tavernState {
                let matchesChar = p.characterId == nil || state.character?.id == p.characterId
                if matchesChar {
                    state.status.isGenerating = stillGenerating
                    if let msg = p.message {
                        if !msg.isUser {
                            tavernGenerationError = nil
                            state.status.lastGenerationError = nil
                        }
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
                    if activeTavernCharacterId != nil && !stillGenerating && p.message?.isUser != true {
                        Haptics.success()
                    }
                }
            }
            if !isTavernGenerating && !sessions.contains(where: \.isRunning) {
                endBackgroundTaskIfNeeded()
            }

        case "tavern_error":
            guard let p = decodePayload(WSTavernErrorPayload.self, from: data),
                  !p.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            let err = p.toGenerationError()
            tavernStatus?.isGenerating = false
            tavernStatus?.lastGenerationError = err
            if var state = tavernState {
                state.status.isGenerating = false
                state.status.lastGenerationError = err
                for idx in state.messages.indices where state.messages[idx].isStreaming {
                    state.messages[idx].isStreaming = false
                }
                tavernState = state
            }
            tavernGenerationError = err
            if err.id != lastNotifiedTavernErrorId {
                lastNotifiedTavernErrorId = err.id
                Haptics.error()
                showBanner(err.message, isError: true, tavernCharacterId: err.characterId)
                let charLabel = err.characterName ?? tavernState?.character?.name ?? "角色"
                NotificationManager.shared.notifyError(
                    title: "酒馆 · \(charLabel) \(err.badgeTitle)",
                    body: err.message,
                    identifier: "tavern-err-\(err.id)",
                    tavernCharacterId: err.characterId
                )
            }
            if !isTavernGenerating && !sessions.contains(where: \.isRunning) {
                endBackgroundTaskIfNeeded()
            }

        case "tavern_chat_updated":
            if let st = decodePayload(WSTavernChatUpdatedPayload.self, from: data)?.state {
                let rawJSON = Self.extractRawVariablesJSON(from: data, nestedInState: true)
                let existingMem: CachedTavernConversation?
                if let cid = st.character?.id {
                    let key = RelayDiskCache.conversationMemoryKey(characterId: cid, chatFile: st.chatFile)
                    existingMem = tavernConversationMemory[key]
                } else {
                    existingMem = nil
                }
                let merged = mergeTavernState(incoming: st, existing: existingMem, isReset: false)
                applyTavernState(merged, rawVariablesJSON: rawJSON, persist: true)
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
            try? await Task.sleep(for: .milliseconds(40))
            self?.flushDeltas()
        }
    }

    func flushDeltas() {
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
