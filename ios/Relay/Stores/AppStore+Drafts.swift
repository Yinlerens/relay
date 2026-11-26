import Foundation

extension AppStore {
    // MARK: - Persistent Drafts (Agent & Tavern)

    func agentDraft(for sessionId: String) -> String {
        agentDrafts[sessionId] ?? ""
    }

    func hasAgentDraft(for sessionId: String) -> Bool {
        guard let text = agentDrafts[sessionId] else { return false }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func setAgentDraft(_ text: String, for sessionId: String) {
        if text.isEmpty {
            if agentDrafts.removeValue(forKey: sessionId) != nil {
                scheduleDraftsPersist()
            }
            return
        }
        if agentDrafts[sessionId] != text {
            agentDrafts[sessionId] = text
            scheduleDraftsPersist()
        }
    }

    func removeAgentDraft(for sessionId: String) {
        if agentDrafts.removeValue(forKey: sessionId) != nil {
            scheduleDraftsPersist()
        }
    }

    func tavernDraft(for characterId: Int) -> String {
        tavernDrafts[characterId] ?? ""
    }

    func hasTavernDraft(for characterId: Int) -> Bool {
        guard let text = tavernDrafts[characterId] else { return false }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func setTavernDraft(_ text: String, for characterId: Int) {
        if text.isEmpty {
            if tavernDrafts.removeValue(forKey: characterId) != nil {
                scheduleDraftsPersist()
            }
            return
        }
        if tavernDrafts[characterId] != text {
            tavernDrafts[characterId] = text
            scheduleDraftsPersist()
        }
    }

    func hydrateDraftsIfEmpty() async {
        guard agentDrafts.isEmpty && tavernDrafts.isEmpty,
              let cached = await RelayDiskCache.shared.loadDrafts() else { return }
        if agentDrafts.isEmpty {
            agentDrafts = cached.agent.filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
        if tavernDrafts.isEmpty {
            tavernDrafts = cached.tavern.filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
    }

    func clearDraftsState() {
        draftsSaveTask?.cancel()
        draftsSaveTask = nil
        agentDrafts = [:]
        tavernDrafts = [:]
    }

    private func scheduleDraftsPersist() {
        draftsSaveTask?.cancel()
        let snapshot = CachedDrafts(
            agent: agentDrafts.filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty },
            tavern: tavernDrafts.filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        )
        draftsSaveTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await RelayDiskCache.shared.saveDrafts(snapshot)
        }
    }
}
