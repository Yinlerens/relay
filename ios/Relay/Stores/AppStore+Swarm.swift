import SwiftUI

extension AppStore {
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
        if swarmBoardMessages[id] == nil, let cached = await RelayDiskCache.shared.loadSwarmDetail(id: id) {
            if swarm(id: id) == nil { upsertSwarm(cached.swarm) }
            swarmBoardMessages[id] = cached.messages.sorted { $0.seq < $1.seq }
        }
        loadingSwarms.insert(id)
        defer { loadingSwarms.remove(id) }
        do {
            let detail = try await api.swarmDetail(id: id)
            upsertSwarm(detail.swarm)
            let sorted = detail.messages.sorted { $0.seq < $1.seq }
            swarmBoardMessages[id] = sorted
            let snapshot = CachedSwarmDetail(
                swarm: detail.swarm,
                messages: sorted,
                updatedAt: Date().timeIntervalSince1970 * 1000
            )
            Task { await RelayDiskCache.shared.saveSwarmDetail(snapshot) }
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
        for sid in removedIds {
            messages[sid] = nil
            removeAgentDraft(for: sid)
        }
        Haptics.tap(.medium)
        do {
            try await api.deleteSwarm(id: id)
            Task { await RelayDiskCache.shared.deleteSwarmDetail(id: id) }
        } catch {
            withAnimation {
                if let swarmSnapshot { upsertSwarm(swarmSnapshot) }
                for s in sessionSnapshots { upsertSession(s) }
            }
            showBanner("删除蜂群失败：\(error.localizedDescription)")
        }
    }

    // MARK: - Local swarm helpers

    func upsertSwarm(_ s: SwarmSummary) {
        if let idx = swarms.firstIndex(where: { $0.id == s.id }) {
            swarms[idx] = s
        } else {
            swarms.append(s)
        }
        swarms.sort { $0.updatedAt > $1.updatedAt }
    }

    func removeSwarmLocally(_ id: String) {
        let coordId = swarm(id: id)?.coordinatorSessionId
        let removedIds = Set(sessions.filter { $0.swarmId == id || (coordId != nil && $0.id == coordId) }.map(\.id))
        withAnimation(.spring(response: 0.4, dampingFraction: 0.9)) {
            swarms.removeAll { $0.id == id }
            sessions.removeAll { removedIds.contains($0.id) }
        }
        swarmBoardMessages[id] = nil
        for sid in removedIds {
            messages[sid] = nil
            removeAgentDraft(for: sid)
        }
    }

    func insertBoardMessage(_ message: SwarmBoardMessage, swarmId: String) {
        var list = swarmBoardMessages[swarmId] ?? []
        if let idx = list.firstIndex(where: { $0.seq == message.seq || ($0.id != 0 && $0.id == message.id) }) {
            list[idx] = message
        } else {
            list.append(message)
        }
        list.sort { $0.seq < $1.seq }
        swarmBoardMessages[swarmId] = list
    }
}
