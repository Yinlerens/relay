import SwiftUI

extension AppStore {
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
        if messages[id] == nil {
            if let cached = await RelayDiskCache.shared.loadAgentSession(id: id) {
                messages[id] = cached.messages.sorted { $0.createdAt < $1.createdAt }
            } else {
                loadingSessions.insert(id)
            }
        }
        await reloadMessages(id)
        loadingSessions.remove(id)
    }

    func reloadMessages(_ id: String) async {
        guard let api else { return }
        do {
            let detail = try await api.session(id: id)
            flushDeltas()
            upsertSession(detail.session)
            let sorted = detail.messages.sorted { $0.createdAt < $1.createdAt }
            messages[id] = sorted
            let snapshot = CachedAgentSession(
                session: detail.session,
                messages: sorted,
                updatedAt: Date().timeIntervalSince1970 * 1000
            )
            Task { await RelayDiskCache.shared.saveAgentSession(snapshot) }
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

    func setPinned(_ id: String, pinned: Bool) async {
        guard let api else { return }
        let previous = session(id)
        if var s = previous {
            s.pinned = pinned
            withAnimation(.spring(response: 0.36, dampingFraction: 0.86)) {
                upsertSession(s)
            }
        }
        Haptics.selection()
        do {
            let updated = try await api.setSessionPinned(id: id, pinned: pinned)
            withAnimation(.spring(response: 0.36, dampingFraction: 0.86)) {
                upsertSession(updated)
            }
        } catch {
            if let previous {
                withAnimation { upsertSession(previous) }
            }
            Haptics.error()
            showBanner("\(pinned ? "置顶" : "取消置顶")失败：\(error.localizedDescription)")
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
            removeAgentDraft(for: id)
            Task { await RelayDiskCache.shared.deleteAgentSession(id: id) }
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

    // MARK: - Local session & message helpers

    func upsertSession(_ s: SessionSummary) {
        if let idx = sessions.firstIndex(where: { $0.id == s.id }) {
            sessions[idx] = s
        } else {
            sessions.append(s)
        }
        sessions.sort { ($0.pinned ? 1 : 0, $0.updatedAt) > ($1.pinned ? 1 : 0, $1.updatedAt) }
    }

    /// Replace without reordering (used for config / rename so rows don't jump).
    func replaceSessionInPlace(_ s: SessionSummary) {
        if let idx = sessions.firstIndex(where: { $0.id == s.id }) {
            sessions[idx] = s
        } else {
            upsertSession(s)
        }
    }

    func removeSessionLocally(_ id: String) {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.9)) {
            sessions.removeAll { $0.id == id }
        }
        messages[id] = nil
        removeAgentDraft(for: id)
    }

    func setRunning(_ sessionId: String, _ running: Bool) {
        guard let idx = sessions.firstIndex(where: { $0.id == sessionId }) else { return }
        if sessions[idx].isRunning != running {
            sessions[idx].isRunning = running
        }
    }

    func appendLocal(_ message: Message) {
        var list = messages[message.sessionId] ?? []
        list.append(message)
        messages[message.sessionId] = list
    }

    func insertIfAbsent(_ message: Message) {
        guard var list = messages[message.sessionId] else { return }
        guard !list.contains(where: { $0.id == message.id }) else { return }
        list.append(message)
        list.sort { $0.createdAt < $1.createdAt }
        messages[message.sessionId] = list
    }

    func mutateMessage(sessionId: String, messageId: String, _ body: (inout Message) -> Void) {
        guard var list = messages[sessionId], let idx = list.lastIndex(where: { $0.id == messageId }) else { return }
        body(&list[idx])
        messages[sessionId] = list
    }
}
