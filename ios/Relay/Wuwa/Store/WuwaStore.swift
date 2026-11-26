import Foundation
import Observation

@MainActor
@Observable
final class WuwaStore {
    // MARK: - Navigation & Chrome
    var section: WuwaSection = .roles
    var hasBootstrapped = false
    @ObservationIgnored var onBanner: ((String, Bool) -> Void)? = nil

    // MARK: - Account & Community
    var session: WuwaSecureSession? = nil
    var snapshot: WuwaCommunitySnapshot = .signedOut
    var isSyncing = false
    var authBusy: String? = nil

    // MARK: - Resonators, Scores & Echo History
    var detailsByRoleId: [Int: WuwaResonatorDetail] = [:]
    var scoresByRoleId: [Int: WuwaEchoLoadoutScore] = [:]
    var historyByRoleId: [Int: [WuwaResonatorHistoryEntry]] = [:]
    var timelineByRoleId: [Int: [WuwaComputedTimelineItem]] = [:]
    var weightTablesByRoleId: [Int: WuwaEchoWeightTable] = [:]
    var loadingDetailIds: Set<Int> = []
    var detailErrors: [Int: String] = [:]

    // MARK: - Gacha & Planner
    var pulls: [WuwaPullRecord] = []
    var pools: [WuwaPoolHistory] = []
    var selectedPoolType: Int = 1
    var isImportingGacha = false
    var plannerInput = WuwaGachaPlannerInput()
    var plannerResult: WuwaGachaPlanResult? = nil

    // MARK: - Calc Lab
    var presets: [WuwaTeamPresetSummary] = []
    var selectedPresetId: String = ""
    var calcOptions = WuwaCalcOptions()
    var sandboxOverrides: [String: WuwaSlotSandboxOverride] = [:]
    var evalBundle: WuwaTeamEvalBundle? = nil
    var multiGoldBudget: Int = 2
    var multiGoldBundle: WuwaMultiGoldBundle? = nil
    var selectedLabSlot: Int = 0
    var compatibleWeaponsByType: [Int: [WuwaCompatibleWeapon]] = [:]
    var sandboxLadders: WuwaSandboxLadders? = nil
    var sensitivityBundle: WuwaSensitivityBundle? = nil
    var graduationReport: WuwaGraduationReport? = nil
    var erCheckup: [WuwaMemberErCheckup] = []
    var teamHistory: WuwaTeamDamageHistorySummary? = nil
    var isEvaluatingCalc = false
    var isEvaluatingLabExtras = false

    @ObservationIgnored private var calcTask: Task<Void, Never>? = nil

    init() {
        loadKeychainSession()
    }

    var activeGameRole: WuwaCommunityRole? {
        snapshot.roles.first(where: { $0.roleId == snapshot.selectedRoleId })
            ?? snapshot.roles.first(where: \.isDefault)
            ?? snapshot.roles.first
    }

    // MARK: - Bootstrap

    func bootstrapIfNeeded() async {
        guard !hasBootstrapped else { return }
        hasBootstrapped = true

        if let saved = await WuwaStorage.shared.loadSnapshot() {
            snapshot = saved
        }
        snapshot.loggedIn = (session != nil)

        if let roleId = activeGameRole?.roleId {
            detailsByRoleId = await WuwaStorage.shared.loadAllDetails(gameRoleId: roleId)
            historyByRoleId = await WuwaStorage.shared.loadAllHistories(gameRoleId: roleId)
            await recomputeAllScoresAndTimelines()
        }

        pulls = await WuwaStorage.shared.loadPulls()
        await recomputeGachaPools()
        await recomputeGachaPlan()

        if let loadedPresets = try? await WuwaJSEngine.shared.listTeamPresets(), !loadedPresets.isEmpty {
            presets = loadedPresets
            pickBestInitialPreset()
        }
        await recomputeCalcLab()
    }

    // MARK: - Auth

    private func loadKeychainSession() {
        guard let raw = KeychainStore.string(for: .kuroSession),
              let data = raw.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(WuwaSecureSession.self, from: data) else {
            session = nil
            return
        }
        session = decoded
    }

    private func saveKeychainSession(_ newSession: WuwaSecureSession) {
        if let data = try? JSONEncoder().encode(newSession),
           let raw = String(data: data, encoding: .utf8) {
            KeychainStore.set(raw, for: .kuroSession)
        }
        session = newSession
    }

    func getOrCreateDeviceId() -> String {
        if let existing = KeychainStore.string(for: .kuroDeviceId), !existing.isEmpty {
            return existing
        }
        let fresh = UUID().uuidString.lowercased()
        KeychainStore.set(fresh, for: .kuroDeviceId)
        return fresh
    }

    func sendSmsCode(mobile: String, captcha: WuwaCaptchaPayload) async -> Bool {
        authBusy = "code"
        defer { authBusy = nil }
        do {
            try await WuwaKuroAPI.requestSmsCode(mobile: mobile, captcha: captcha, deviceId: getOrCreateDeviceId())
            onBanner?("验证码已发送，请查看短信", false)
            return true
        } catch {
            onBanner?(error.localizedDescription, true)
            return false
        }
    }

    func loginWithSms(mobile: String, code: String) async -> Bool {
        authBusy = "login"
        defer { authBusy = nil }
        do {
            let newSession = try await WuwaKuroAPI.loginWithSms(mobile: mobile, code: code, deviceId: getOrCreateDeviceId())
            saveKeychainSession(newSession)
            await refreshCommunity(forceDetails: true)
            return true
        } catch {
            onBanner?(error.localizedDescription, true)
            return false
        }
    }

    func loginWithToken(_ rawToken: String, deviceId customDeviceId: String?) async -> Bool {
        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            onBanner?("请输入有效的库街区 Token", true)
            return false
        }
        let devId = customDeviceId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? customDeviceId!.trimmingCharacters(in: .whitespacesAndNewlines)
            : getOrCreateDeviceId()
        KeychainStore.set(devId, for: .kuroDeviceId)

        authBusy = "login"
        defer { authBusy = nil }
        let candidate = WuwaSecureSession(
            token: token,
            deviceId: devId,
            mobileMasked: "Token 导入",
            userId: "",
            userName: "",
            signature: ""
        )
        do {
            let fetched = try await WuwaKuroAPI.fetchSnapshot(session: candidate)
            saveKeychainSession(fetched.resolvedSession)
            snapshot = fetched.snapshot
            await WuwaStorage.shared.saveSnapshot(fetched.snapshot)
            await hydrateAllResonatorDetails()
            onBanner?("已绑定库街区账号", false)
            return true
        } catch {
            onBanner?(error.localizedDescription, true)
            return false
        }
    }

    func logout() async {
        KeychainStore.delete(.kuroSession)
        session = nil
        snapshot = .signedOut
        detailsByRoleId = [:]
        scoresByRoleId = [:]
        historyByRoleId = [:]
        timelineByRoleId = [:]
        weightTablesByRoleId = [:]
        evalBundle = nil
        multiGoldBundle = nil
        sandboxLadders = nil
        sensitivityBundle = nil
        graduationReport = nil
        erCheckup = []
        teamHistory = nil
        await WuwaStorage.shared.clearCommunityData()
        onBanner?("已退出库街区账号", false)
    }

    // MARK: - Sync & Details

    func refreshCommunity(roleId: String? = nil, forceDetails: Bool = true) async {
        guard let session else { return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            let fetched = try await WuwaKuroAPI.fetchSnapshot(session: session, requestedRoleId: roleId ?? snapshot.selectedRoleId)
            saveKeychainSession(fetched.resolvedSession)
            snapshot = fetched.snapshot
            await WuwaStorage.shared.saveSnapshot(fetched.snapshot)
            if let gid = activeGameRole?.roleId {
                detailsByRoleId = await WuwaStorage.shared.loadAllDetails(gameRoleId: gid)
                historyByRoleId = await WuwaStorage.shared.loadAllHistories(gameRoleId: gid)
            }
            if forceDetails {
                await hydrateAllResonatorDetails()
            } else {
                await recomputeAllScoresAndTimelines()
                await recomputeCalcLab()
            }
            onBanner?("已同步鸣潮角色面板", false)
        } catch {
            onBanner?(error.localizedDescription, true)
        }
    }

    func hydrateAllResonatorDetails() async {
        guard let session, let role = activeGameRole, !snapshot.resonators.isEmpty else { return }
        let ids = snapshot.resonators.map(\.roleId)
        do {
            let details = try await WuwaKuroAPI.fetchResonatorDetails(session: session, role: role, resonatorIds: ids)
            for detail in details {
                detailsByRoleId[detail.role.roleId] = detail
                let hist = await WuwaStorage.shared.saveDetail(gameRoleId: role.roleId, detail: detail)
                historyByRoleId[detail.role.roleId] = hist
            }
            await recomputeAllScoresAndTimelines()
            pickBestInitialPresetIfUnset()
            await recomputeCalcLab()
        } catch {
            if let gid = activeGameRole?.roleId {
                detailsByRoleId = await WuwaStorage.shared.loadAllDetails(gameRoleId: gid)
                historyByRoleId = await WuwaStorage.shared.loadAllHistories(gameRoleId: gid)
                await recomputeAllScoresAndTimelines()
                await recomputeCalcLab()
            }
        }
    }

    func loadResonatorDetail(_ resonatorId: Int, forceRefresh: Bool = false) async {
        if !forceRefresh, detailsByRoleId[resonatorId] != nil {
            if weightTablesByRoleId[resonatorId] == nil || timelineByRoleId[resonatorId] == nil {
                await computeScoreAndTimeline(for: resonatorId)
            }
            return
        }
        guard let session, let role = activeGameRole else {
            detailErrors[resonatorId] = "请先登录库街区账号。"
            return
        }
        loadingDetailIds.insert(resonatorId)
        detailErrors[resonatorId] = nil
        defer { loadingDetailIds.remove(resonatorId) }

        do {
            let detail = try await WuwaKuroAPI.fetchResonatorDetail(session: session, role: role, resonatorId: resonatorId)
            detailsByRoleId[resonatorId] = detail
            let hist = await WuwaStorage.shared.saveDetail(gameRoleId: role.roleId, detail: detail)
            historyByRoleId[resonatorId] = hist
            await computeScoreAndTimeline(for: resonatorId)
            await recomputeCalcLab()
        } catch {
            if let cached = await WuwaStorage.shared.loadDetail(gameRoleId: role.roleId, resonatorId: resonatorId) {
                detailsByRoleId[resonatorId] = cached
                historyByRoleId[resonatorId] = await WuwaStorage.shared.loadHistory(gameRoleId: role.roleId, resonatorId: resonatorId)
                await computeScoreAndTimeline(for: resonatorId)
            } else {
                detailErrors[resonatorId] = error.localizedDescription
            }
        }
    }

    private func computeScoreAndTimeline(for resonatorId: Int) async {
        guard let detail = detailsByRoleId[resonatorId] else { return }
        if let scored = try? await WuwaJSEngine.shared.scoreEchoLoadout(roleId: resonatorId, echoes: detail.echoes) {
            scoresByRoleId[resonatorId] = scored
        }
        if let table = try? await WuwaJSEngine.shared.echoWeightTable(roleId: resonatorId, attributeName: detail.role.attributeName) {
            weightTablesByRoleId[resonatorId] = table
        }
        let entries = historyByRoleId[resonatorId] ?? []
        if let timeline = try? await WuwaJSEngine.shared.buildResonatorTimeline(detail: detail, history: entries) {
            timelineByRoleId[resonatorId] = timeline
        }
    }

    private func recomputeAllScoresAndTimelines() async {
        for rid in detailsByRoleId.keys {
            await computeScoreAndTimeline(for: rid)
        }
    }

    // MARK: - Gacha

    func importConveneURL(_ rawURL: String) async -> Bool {
        isImportingGacha = true
        defer { isImportingGacha = false }
        do {
            let res = try await WuwaKuroAPI.fetchConvenePulls(from: rawURL)
            let merged = await WuwaStorage.shared.mergePulls(res.records)
            pulls = merged.all
            await recomputeGachaPools()
            syncPlannerFromCurrentPools()
            onBanner?("已读取 \(res.records.count) 条记录，新增 \(merged.added) 条", false)
            return true
        } catch {
            onBanner?(error.localizedDescription, true)
            return false
        }
    }

    func importBackupJSON(_ data: Data) async -> Bool {
        isImportingGacha = true
        defer { isImportingGacha = false }
        do {
            let merged = try await WuwaStorage.shared.importBackupData(data)
            pulls = merged.all
            await recomputeGachaPools()
            syncPlannerFromCurrentPools()
            onBanner?("已导入备份，新增 \(merged.added) 条唤取记录", false)
            return true
        } catch {
            onBanner?(error.localizedDescription, true)
            return false
        }
    }

    func exportBackupData() async throws -> Data {
        try await WuwaStorage.shared.exportBackupData()
    }

    func recomputeGachaPools() async {
        guard !pulls.isEmpty else {
            pools = []
            return
        }
        if let built = try? await WuwaJSEngine.shared.buildAllPools(pulls: pulls) {
            pools = built
            if !built.contains(where: { $0.poolType == selectedPoolType }), let first = built.first {
                selectedPoolType = first.poolType
            }
        }
    }

    func syncPlannerFromCurrentPools() {
        if let charPool = pools.first(where: { $0.poolType == 1 }) {
            plannerInput.charPity = min(79, max(0, charPool.currentPity))
            if let guaranteed = charPool.guaranteed {
                plannerInput.charGuaranteed = guaranteed
            }
        }
        if let weapPool = pools.first(where: { $0.poolType == 2 }) {
            plannerInput.weaponPity = min(79, max(0, weapPool.currentPity))
        }
        Task { await recomputeGachaPlan() }
    }

    func recomputeGachaPlan() async {
        if let res = try? await WuwaJSEngine.shared.calculateGachaPlan(input: plannerInput) {
            plannerResult = res
        }
    }

    // MARK: - Calc Lab

    func presetForRole(_ roleId: Int) -> WuwaTeamPresetSummary? {
        presets.first(where: { preset in
            preset.slots.contains(where: { $0.roleId == roleId }) &&
            preset.slots.allSatisfy { detailsByRoleId[$0.roleId] != nil }
        }) ?? presets.first(where: { preset in
            preset.slots.contains(where: { $0.roleId == roleId })
        })
    }

    func openInCalcLab(roleId: Int) {
        if let target = presetForRole(roleId) {
            selectPreset(target.id)
        }
        section = .calc
    }

    private func pickBestInitialPreset() {
        let ready = presets.first(where: { p in
            p.slots.allSatisfy { detailsByRoleId[$0.roleId] != nil }
        })
        selectedPresetId = ready?.id ?? presets.first?.id ?? ""
    }

    private func pickBestInitialPresetIfUnset() {
        if let cur = presets.first(where: { $0.id == selectedPresetId }),
           cur.slots.allSatisfy({ detailsByRoleId[$0.roleId] != nil }) {
            return
        }
        pickBestInitialPreset()
    }

    func selectPreset(_ id: String) {
        guard selectedPresetId != id else { return }
        selectedPresetId = id
        sandboxOverrides = [:]
        selectedLabSlot = 0
        scheduleCalcRecompute()
    }

    func updateSandboxOverride(slot: Int, _ update: (inout WuwaSlotSandboxOverride) -> Void) {
        let key = String(slot)
        var current = sandboxOverrides[key] ?? WuwaSlotSandboxOverride()
        update(&current)
        if current.isEmpty {
            sandboxOverrides.removeValue(forKey: key)
        } else {
            sandboxOverrides[key] = current
        }
        scheduleCalcRecompute()
    }

    func applyTeamOverrides(_ next: [String: WuwaSlotSandboxOverride], message: String? = nil) {
        sandboxOverrides = next.filter { !$0.value.isEmpty }
        scheduleCalcRecompute()
        if let message {
            onBanner?(message, false)
        }
    }

    func resetSandbox() {
        sandboxOverrides = [:]
        scheduleCalcRecompute()
    }

    func scheduleCalcRecompute() {
        calcTask?.cancel()
        calcTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(40))
            guard !Task.isCancelled else { return }
            await self?.recomputeCalcLab()
        }
    }

    func recomputeCalcLab() async {
        guard let preset = presets.first(where: { $0.id == selectedPresetId }) else {
            evalBundle = nil
            return
        }
        var stringDetails: [String: WuwaResonatorDetail] = [:]
        for slot in preset.slots {
            guard let detail = detailsByRoleId[slot.roleId] else {
                evalBundle = nil
                multiGoldBundle = nil
                sandboxLadders = nil
                sensitivityBundle = nil
                graduationReport = nil
                erCheckup = []
                teamHistory = nil
                return
            }
            stringDetails[String(slot.roleId)] = detail
        }

        isEvaluatingCalc = true
        defer { isEvaluatingCalc = false }

        do {
            let bundle = try await WuwaJSEngine.shared.evaluateTeam(
                presetId: preset.id,
                detailsByRoleId: stringDetails,
                options: calcOptions,
                overrides: sandboxOverrides
            )
            evalBundle = bundle
        } catch {
            evalBundle = nil
        }

        // Load compatible weapons for current sandbox slot
        if let slotRoleId = preset.slots[safe: selectedLabSlot]?.roleId,
           let wTypeId = detailsByRoleId[slotRoleId]?.role.weaponTypeId,
           compatibleWeaponsByType[wTypeId] == nil {
            if let weapons = try? await WuwaJSEngine.shared.listCompatibleWeapons(weaponTypeId: wTypeId) {
                compatibleWeaponsByType[wTypeId] = weapons
            }
        }

        isEvaluatingLabExtras = true
        defer { isEvaluatingLabExtras = false }

        let budget = multiGoldBudget
        let slot = selectedLabSlot
        let opts = calcOptions
        let overrides = sandboxOverrides
        let pid = preset.id

        var stringHistories: [String: [WuwaResonatorHistoryEntry]] = [:]
        for s in preset.slots {
            if let h = historyByRoleId[s.roleId] {
                stringHistories[String(s.roleId)] = h
            }
        }

        async let goldRes = try? WuwaJSEngine.shared.evaluateMultiGold(
            presetId: pid,
            detailsByRoleId: stringDetails,
            budgetGold: budget,
            options: opts,
            overrides: overrides
        )
        async let ladderRes = try? WuwaJSEngine.shared.evaluateSandboxLadders(
            presetId: pid,
            detailsByRoleId: stringDetails,
            slotIndex: slot,
            options: opts,
            overrides: overrides
        )
        async let sensRes = try? WuwaJSEngine.shared.evaluateSensitivity(
            presetId: pid,
            detailsByRoleId: stringDetails,
            slotIndex: slot,
            options: opts,
            overrides: overrides
        )
        async let gradRes = try? WuwaJSEngine.shared.evaluateGraduation(
            presetId: pid,
            detailsByRoleId: stringDetails,
            slotIndex: slot,
            options: opts,
            overrides: overrides
        )
        async let erRes = try? WuwaJSEngine.shared.evaluateErCheckup(
            presetId: pid,
            detailsByRoleId: stringDetails,
            options: opts,
            overrides: overrides
        )
        async let histRes = try? WuwaJSEngine.shared.evaluateTeamHistory(
            presetId: pid,
            detailsByRoleId: stringDetails,
            historiesByRoleId: stringHistories,
            options: opts
        )

        multiGoldBundle = await goldRes
        sandboxLadders = await ladderRes
        sensitivityBundle = await sensRes
        graduationReport = await gradRes
        erCheckup = (await erRes) ?? []
        teamHistory = await histRes
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
