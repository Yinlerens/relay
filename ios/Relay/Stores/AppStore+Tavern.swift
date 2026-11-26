import SwiftUI

/// Pure merge logic for incremental/windowed SillyTavern chat state updates.
enum TavernStateMerger {
    /// Merges an incremental/windowed server `TavernChatState` over a cached local conversation,
    /// preserving `unchangedMesIds` and any already-scrolled older history before the server's window.
    static func merge(
        incoming: TavernChatState,
        existing: CachedTavernConversation?,
        isReset: Bool
    ) -> TavernChatState {
        guard !isReset, let existing else {
            var clean = incoming
            clean.unchangedMesIds = nil
            return clean
        }
        let sameChar = incoming.character?.id == existing.characterId
        let incomingNorm = RelayDiskCache.normalizeChatFile(incoming.chatFile)
        let existingNorm = RelayDiskCache.normalizeChatFile(existing.chatFile)
        guard sameChar, !incomingNorm.isEmpty, incomingNorm == existingNorm else {
            var clean = incoming
            clean.unchangedMesIds = nil
            return clean
        }

        let unchangedSet = Set(incoming.unchangedMesIds ?? [])
        let serverIds = incoming.messages.map(\.mesId) + (incoming.unchangedMesIds ?? [])
        let serverWindowMin = serverIds.min()
        let totalCount = incoming.totalMessageCount

        var byId: [Int: TavernMessage] = [:]
        for msg in existing.messages {
            if let totalCount, msg.mesId >= totalCount { continue }
            let isUnchanged = unchangedSet.contains(msg.mesId)
            let isOlderHistory = serverWindowMin != nil && msg.mesId < serverWindowMin!
            if isUnchanged || isOlderHistory {
                byId[msg.mesId] = msg
            }
        }
        for msg in incoming.messages {
            byId[msg.mesId] = msg
        }

        let mergedMessages = byId.values.sorted { $0.mesId < $1.mesId }
        let computedHasMore: Bool
        if let firstId = mergedMessages.first?.mesId {
            computedHasMore = firstId > 0
        } else {
            computedHasMore = incoming.hasMore ?? false
        }

        var merged = incoming
        merged.messages = mergedMessages
        merged.hasMore = computedHasMore
        merged.unchangedMesIds = nil
        return merged
    }
}

extension AppStore {
    // MARK: - Tavern (SillyTavern Bridge)

    func resetTavernState() {
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
        tavernGenerationError = nil
        activeTavernCharacterId = nil
        tavernConversationMemory.removeAll()
        latestChatByChar.removeAll()
        latestChatHydrated = false
        TavernAssetCache.shared.clear()
    }

    func applyTavernState(_ state: TavernChatState, rawVariablesJSON: String? = nil, persist: Bool = true) {
        let varsJSON = rawVariablesJSON ?? state.variablesJSON
        tavernState = state
        tavernStatus = state.status
        tavernVariablesJSON = varsJSON
        syncGenerationError(from: state.status, notifyIfNew: false)
        if let char = state.character,
           let idx = tavernCharacters.firstIndex(where: { $0.id == char.id }) {
            tavernCharacters[idx] = char
        }
        if persist {
            persistTavernConversation(from: state, variablesJSON: varsJSON)
        }
    }

    func syncGenerationError(from status: TavernStatus?, notifyIfNew: Bool) {
        guard let status else { return }
        if let err = status.lastGenerationError {
            tavernGenerationError = err
            if notifyIfNew && err.id != lastNotifiedTavernErrorId {
                lastNotifiedTavernErrorId = err.id
                Haptics.error()
                showBanner(err.message, isError: true, tavernCharacterId: err.characterId)
                let charLabel = err.characterName ?? "角色"
                NotificationManager.shared.notifyError(
                    title: "酒馆 · \(charLabel) \(err.badgeTitle)",
                    body: err.message,
                    identifier: "tavern-err-\(err.id)",
                    tavernCharacterId: err.characterId
                )
            }
        } else {
            tavernGenerationError = nil
        }
    }

    func clearTavernGenerationError() async {
        withAnimation(.easeOut(duration: 0.2)) {
            tavernGenerationError = nil
        }
        tavernStatus?.lastGenerationError = nil
        tavernState?.status.lastGenerationError = nil
        guard let api else { return }
        if let res = try? await api.tavernClearError() {
            tavernStatus = res.status
            if tavernState != nil {
                tavernState?.status = res.status
            }
        }
    }

    func cachedTavernConversation(characterId: Int, chatFile: String?) async -> CachedTavernConversation? {
        if !latestChatHydrated {
            latestChatByChar = await RelayDiskCache.shared.loadLatestChatByChar()
            latestChatHydrated = true
        }
        let targetChat = chatFile ?? latestChatByChar[characterId] ?? tavernCharacter(id: characterId)?.chat
        guard let targetChat, !RelayDiskCache.normalizeChatFile(targetChat).isEmpty else { return nil }
        let memKey = RelayDiskCache.conversationMemoryKey(characterId: characterId, chatFile: targetChat)
        if let hit = tavernConversationMemory[memKey] {
            return hit
        }
        if let disk = await RelayDiskCache.shared.loadTavernConversation(characterId: characterId, chatFile: targetChat) {
            tavernConversationMemory[memKey] = disk
            return disk
        }
        return nil
    }

    func persistTavernConversation(from state: TavernChatState, variablesJSON: String) {
        guard let charId = state.character?.id,
              let chatFile = state.chatFile,
              !RelayDiskCache.normalizeChatFile(chatFile).isEmpty else { return }

        let sanitizedMessages: [TavernMessage] = state.messages.map { msg in
            var copy = msg
            copy.isStreaming = false
            return copy
        }
        let cached = CachedTavernConversation(
            characterId: charId,
            chatFile: chatFile,
            character: state.character,
            userName: state.userName,
            messages: sanitizedMessages,
            variablesJSON: variablesJSON,
            totalMessageCount: state.totalMessageCount,
            hasMore: state.hasMore,
            updatedAt: Date().timeIntervalSince1970 * 1000
        )
        let memKey = RelayDiskCache.conversationMemoryKey(characterId: charId, chatFile: chatFile)
        tavernConversationMemory[memKey] = cached
        latestChatByChar[charId] = chatFile
        let latestMap = latestChatByChar
        Task {
            await RelayDiskCache.shared.saveTavernConversation(cached)
            await RelayDiskCache.shared.saveLatestChatByChar(latestMap)
        }
    }

    func mergeTavernState(
        incoming: TavernChatState,
        existing: CachedTavernConversation?,
        isReset: Bool
    ) -> TavernChatState {
        TavernStateMerger.merge(incoming: incoming, existing: existing, isReset: isReset)
    }

    func loadTavernOverview() async {
        guard let api else { return }
        if tavernCharacters.isEmpty, let cached = await RelayDiskCache.shared.loadTavernOverview() {
            var st = cached.status
            st.isGenerating = false
            if tavernStatus == nil { tavernStatus = st }
            tavernCharacters = cached.characters
        }
        isLoadingTavern = tavernCharacters.isEmpty
        defer { isLoadingTavern = false }
        do {
            let statusRes = try await api.tavernStatus()
            tavernStatus = statusRes.status
            syncGenerationError(from: statusRes.status, notifyIfNew: false)
            if let users = statusRes.loginUsers {
                tavernLoginUsers = users
            }
            tavernError = nil
            if statusRes.status.enabled && statusRes.status.ready && !statusRes.status.needsLogin {
                let charsRes = try await api.tavernCharacters()
                tavernStatus = charsRes.status
                syncGenerationError(from: charsRes.status, notifyIfNew: false)
                withAnimation(.easeOut(duration: 0.22)) {
                    tavernCharacters = charsRes.characters
                }
                let snapshot = CachedTavernOverview(
                    status: charsRes.status,
                    characters: charsRes.characters,
                    updatedAt: Date().timeIntervalSince1970 * 1000
                )
                Task { await RelayDiskCache.shared.saveTavernOverview(snapshot) }
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
            tavernConversationMemory.removeAll()
            let overview = CachedTavernOverview(
                status: res.status,
                characters: res.characters,
                updatedAt: Date().timeIntervalSince1970 * 1000
            )
            Task { await RelayDiskCache.shared.saveTavernOverview(overview) }
            Haptics.success()
            showBanner("已同步原版酒馆配置", isError: false)
            if let activeCharId = activeTavernCharacterId {
                await selectTavernCharacter(id: activeCharId, forceFull: true)
            }
        } catch {
            Haptics.error()
            showBanner("同步失败：\(error.localizedDescription)")
        }
    }

    func loadTavernChats(characterId: Int) async {
        guard let api else { return }
        if tavernChats[characterId] == nil,
           let cached = await RelayDiskCache.shared.loadTavernChats(characterId: characterId) {
            tavernChats[characterId] = cached
        }
        do {
            let res = try await api.tavernCharacterChats(characterId: characterId)
            tavernChats[characterId] = res.chats
            let snapshot = res.chats
            Task { await RelayDiskCache.shared.saveTavernChats(snapshot, characterId: characterId) }
        } catch {
            if tavernChats[characterId] == nil {
                showBanner("读取历史聊天失败：\(error.localizedDescription)")
            }
        }
    }

    func selectTavernCharacter(
        id: Int,
        chatFile: String? = nil,
        createNew: Bool = false,
        forceFull: Bool = false
    ) async {
        guard let api else { return }
        if createNew || forceFull || (tavernGenerationError?.characterId != nil && tavernGenerationError?.characterId != id) {
            tavernGenerationError = nil
        }

        var cached: CachedTavernConversation? = nil
        if !createNew && !forceFull {
            cached = await cachedTavernConversation(characterId: id, chatFile: chatFile)
        }

        if let cached {
            let alreadyShowingSame =
                tavernState?.character?.id == id &&
                RelayDiskCache.normalizeChatFile(tavernState?.chatFile) == RelayDiskCache.normalizeChatFile(cached.chatFile) &&
                tavernState?.messages == cached.messages
            if !alreadyShowingSame {
                var baseStatus = tavernStatus ?? TavernStatus(enabled: true, ready: true)
                baseStatus.currentCharacterId = id
                baseStatus.currentCharacterName = cached.character?.name ?? tavernCharacter(id: id)?.name
                baseStatus.currentChatFile = cached.chatFile
                let hydrated = TavernChatState(
                    status: baseStatus,
                    character: cached.character ?? tavernCharacter(id: id),
                    chatFile: cached.chatFile,
                    userName: cached.userName,
                    messages: cached.messages,
                    variables: [:],
                    totalMessageCount: cached.totalMessageCount,
                    hasMore: cached.hasMore ?? ((cached.messages.first?.mesId ?? 0) > 0)
                )
                // Instant 0ms render from local cache with no spinner.
                tavernState = hydrated
                tavernVariablesJSON = cached.variablesJSON
            }
            isLoadingTavernChat = false
        } else {
            isLoadingTavernChat = true
        }
        defer { isLoadingTavernChat = false }

        var knownChatFile: String? = nil
        var knownHashes: [String: String]? = nil
        if !createNew && !forceFull, let cached, !cached.messages.isEmpty {
            let recent = cached.messages
                .filter { !$0.isStreaming && !$0.renderedHash.isEmpty }
                .suffix(45)
            if !recent.isEmpty {
                var hashes: [String: String] = [:]
                hashes.reserveCapacity(recent.count)
                for m in recent {
                    hashes[String(m.mesId)] = m.renderedHash
                }
                knownChatFile = cached.chatFile
                knownHashes = hashes
            }
        }

        do {
            let res = try await api.tavernSelect(
                characterId: id,
                chatFile: chatFile,
                createNew: createNew,
                knownChatFile: knownChatFile,
                knownHashes: knownHashes
            )
            let merged = mergeTavernState(
                incoming: res.state,
                existing: cached,
                isReset: createNew || forceFull
            )
            applyTavernState(merged, persist: true)
            if createNew {
                Haptics.success()
                Task { await self.loadTavernChats(characterId: id) }
            }
        } catch {
            Haptics.error()
            if cached == nil {
                showBanner("切换角色聊天失败：\(error.localizedDescription)")
            }
        }
    }

    func loadTavernCurrent() async {
        guard let api else { return }
        do {
            let res = try await api.tavernCurrent()
            let existing: CachedTavernConversation?
            if let charId = res.state.character?.id {
                existing = await cachedTavernConversation(characterId: charId, chatFile: res.state.chatFile)
            } else {
                existing = nil
            }
            let merged = mergeTavernState(incoming: res.state, existing: existing, isReset: false)
            applyTavernState(merged, persist: true)
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
            latest.hasMore = (latest.messages.first?.mesId ?? 0) > 0
            if let total = res.state.totalMessageCount {
                latest.totalMessageCount = total
            }
            tavernState = latest
            persistTavernConversation(from: latest, variablesJSON: tavernVariablesJSON)
            Haptics.selection()
        } catch {
            showBanner("加载更早消息失败：\(error.localizedDescription)")
        }
    }

    func mergeAndApplyTavernState(_ incoming: TavernChatState, rawVariablesJSON: String? = nil) {
        let existingMem: CachedTavernConversation?
        if let cid = incoming.character?.id {
            let key = RelayDiskCache.conversationMemoryKey(characterId: cid, chatFile: incoming.chatFile)
            existingMem = tavernConversationMemory[key]
        } else {
            existingMem = nil
        }
        let merged = mergeTavernState(incoming: incoming, existing: existingMem, isReset: false)
        applyTavernState(merged, rawVariablesJSON: rawVariablesJSON, persist: true)
    }

    @discardableResult
    func sendTavernMessage(text: String) async -> Bool {
        guard let api else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        tavernGenerationError = nil
        tavernStatus?.isGenerating = true
        tavernState?.status.isGenerating = true
        Haptics.tap(.soft)
        do {
            let res = try await api.tavernSend(text: trimmed)
            withAnimation(.spring(response: 0.36, dampingFraction: 0.86)) {
                mergeAndApplyTavernState(res.state)
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
        tavernGenerationError = nil
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
        tavernGenerationError = nil
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
                mergeAndApplyTavernState(res.state)
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
            mergeAndApplyTavernState(res.state)
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
        let priorState = tavernState
        do {
            let res = try await api.tavernDeleteMessage(mesId: mesId)
            // Deleting mesId shifts all subsequent mesIds down; discard cached entries >= mesId
            // while preserving any earlier scrolled history strictly below both mesId and server window.
            var nextState = res.state
            if let prior = priorState,
               prior.character?.id == res.state.character?.id,
               RelayDiskCache.normalizeChatFile(prior.chatFile) == RelayDiskCache.normalizeChatFile(res.state.chatFile),
               let serverMin = res.state.messages.map(\.mesId).min() {
                if mesId >= serverMin {
                    let keptOlder = prior.messages.filter { $0.mesId < serverMin }
                    if !keptOlder.isEmpty {
                        nextState.messages = (keptOlder + res.state.messages).sorted { $0.mesId < $1.mesId }
                        nextState.hasMore = (nextState.messages.first?.mesId ?? 0) > 0
                    }
                } else {
                    nextState.hasMore = serverMin > 0
                }
            }
            withAnimation(.spring(response: 0.36, dampingFraction: 0.88)) {
                applyTavernState(nextState, persist: true)
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
            mergeAndApplyTavernState(res.state)
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
}
