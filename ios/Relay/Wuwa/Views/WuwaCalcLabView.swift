import Charts
import SwiftUI

struct WuwaCalcLabView: View {
    @Environment(WuwaStore.self) private var wuwa
    var onOpenResonator: (Int) -> Void
    var onRequestLogin: () -> Void

    enum LabTab: String, CaseIterable, Identifiable {
        case gold = "下一金建议"
        case sandbox = "配装沙盒"
        case sensitivity = "词条与弱声骸"
        case graduation = "毕业与充能"
        var id: String { rawValue }
    }

    @State private var activeLabTab: LabTab = .gold
    @State private var stepActorFilter: Int = -1
    @State private var selectedStep: WuwaStepDamageResult? = nil
    @State private var verifyMember: WuwaRebuiltMemberSummary? = nil
    @State private var showSteps = false

    private var currentPreset: WuwaTeamPresetSummary? {
        wuwa.presets.first(where: { $0.id == wuwa.selectedPresetId })
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                if !wuwa.snapshot.loggedIn {
                    missingPrompt(
                        title: "登录后解锁伤害计算实验室",
                        detail: "需使用你的真实角色面板、武器与声骸，通过本地引擎实算配队 DPR 与下一步提升路线。",
                        buttonTitle: "登录库街区",
                        action: onRequestLogin
                    )
                } else if wuwa.presets.isEmpty {
                    ProgressView("正在加载计算引擎预设…").padding(.vertical, 40)
                } else {
                    presetSelector
                    conditionBar

                    if let eval = wuwa.evalBundle?.result {
                        heroDamageCard(result: eval, baseResult: wuwa.evalBundle?.baseResult)
                        labWorkbenchCard(result: eval)
                        rotationStepsCard(result: eval)
                    } else if let preset = currentPreset {
                        missingTeamMembersCard(preset: preset)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 2)
            .padding(.bottom, 28)
        }
        .sheet(item: $selectedStep) { step in
            StepBreakdownSheet(step: step)
                .presentationDetents([.medium, .large])
        }
        .sheet(item: $verifyMember) { member in
            MemberVerificationSheet(member: member) {
                verifyMember = nil
                onOpenResonator(member.roleId)
            }
            .presentationDetents([.medium, .large])
        }
    }

    // MARK: - Preset & Condition Controls

    private var presetSelector: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(wuwa.presets) { preset in
                    let selected = preset.id == wuwa.selectedPresetId
                    let ready = preset.slots.allSatisfy { wuwa.detailsByRoleId[$0.roleId] != nil }
                    Button {
                        Haptics.selection()
                        wuwa.selectPreset(preset.id)
                    } label: {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(ready ? Palette.success : Palette.textTertiary)
                                .frame(width: 6, height: 6)
                            Text(preset.name)
                            if let variant = preset.variantLabel, !variant.isEmpty {
                                Text("· \(variant)")
                                    .opacity(0.78)
                            }
                        }
                        .font(.system(size: 12.5, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? .white : Palette.textPrimary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(selected ? Palette.textPrimary : Palette.surface))
                        .overlay(Capsule().stroke(Palette.hairline, lineWidth: 0.6))
                    }
                    .buttonStyle(.pressable)
                }
            }
        }
    }

    private var conditionBar: some View {
        @Bindable var bindable = wuwa
        return HStack(spacing: 8) {
            Picker("轴模式", selection: $bindable.calcOptions.mode) {
                Text("常规循环").tag("loop")
                Text("首轮爆发").tag("burst")
            }
            .pickerStyle(.segmented)
            .onChange(of: wuwa.calcOptions.mode) { _, _ in
                wuwa.scheduleCalcRecompute()
            }

            Menu {
                Section("敌方抗性") {
                    Button("抗性 0% · 满减抗") { setEnv(res: 0.0) }
                    Button("抗性 10% · 优势减抗") { setEnv(res: 0.1) }
                    Button("抗性 20% · 深塔默认") { setEnv(res: 0.2) }
                    Button("抗性 40% · 大世界") { setEnv(res: 0.4) }
                }
                Section("敌方等级") {
                    Button("Lv.100") { wuwa.calcOptions.enemyLevel = 100; wuwa.scheduleCalcRecompute() }
                    Button("Lv.90") { wuwa.calcOptions.enemyLevel = 90; wuwa.scheduleCalcRecompute() }
                }
                Section("深境场地增益") {
                    Button("无场地增益") { setStage(crit: 0, dmg: 0) }
                    Button("场地暴伤 +25%") { setStage(crit: 0.25, dmg: 0) }
                    Button("场地暴伤 +25% · 增伤 +30%") { setStage(crit: 0.25, dmg: 0.30) }
                }
            } label: {
                HStack(spacing: 4) {
                    Text("Lv.\(wuwa.calcOptions.enemyLevel) · 抗\(Int(wuwa.calcOptions.enemyBaseRes * 100))%")
                        .monospacedDigit()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Palette.textPrimary)
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .background(Capsule().fill(Palette.surface))
                .overlay(Capsule().stroke(Palette.hairlineStrong, lineWidth: 0.6))
            }
        }
    }

    private func setEnv(res: Double) {
        wuwa.calcOptions.enemyBaseRes = res
        wuwa.scheduleCalcRecompute()
    }

    private func setStage(crit: Double, dmg: Double) {
        wuwa.calcOptions.stageCritDmg = crit
        wuwa.calcOptions.stageDmgBonus = dmg
        wuwa.scheduleCalcRecompute()
    }

    // MARK: - Hero Damage Dashboard (Swift Charts)

    private func heroDamageCard(result: WuwaTeamCalcResult, baseResult: WuwaTeamCalcResult?) -> some View {
        let baseDpr = baseResult?.totalDpr ?? result.totalDpr
        let deltaDpr = result.totalDpr - baseDpr
        let deltaPct = baseDpr > 0 ? (deltaDpr / baseDpr) : 0
        let hasDelta = !wuwa.sandboxOverrides.isEmpty && abs(deltaDpr) >= 1

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(result.mode == "burst" ? "首轮爆发轮伤 DPR" : "整队循环轮伤 DPR")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.textSecondary)
                    Text(formatInt(result.totalDpr))
                        .font(RelayFont.display(34))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
                Spacer()
                if hasDelta {
                    let up = deltaDpr >= 0
                    HStack(spacing: 6) {
                        Text("\(up ? "+" : "")\(String(format: "%.1f%%", deltaPct * 100))")
                            .font(.system(size: 12, weight: .bold))
                            .monospacedDigit()
                            .foregroundStyle(up ? Palette.success : Palette.danger)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(Capsule().fill((up ? Palette.success : Palette.danger).opacity(0.14)))

                        Button("还原") {
                            wuwa.resetSandbox()
                            Haptics.tap()
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Palette.fieldFill))
                    }
                }
            }

            HStack(spacing: 10) {
                Text("整队 DPS \(formatInt(result.teamDps))/s")
                Text("·")
                Text("轴长 \(String(format: "%.1fs", result.cycleSeconds))")
                Text("·")
                Text("主 C \(String(format: "%.1f%%", (result.contributions.first?.share ?? 0) * 100))")
            }
            .font(.system(size: 12))
            .monospacedDigit()
            .foregroundStyle(Palette.textSecondary)

            // Swift Charts 整队伤害占比堆叠条
            Chart(result.contributions) { item in
                BarMark(
                    x: .value("占比", item.share * 100),
                    y: .value("整队", "占比")
                )
                .foregroundStyle(WuwaElementStyle.color(for: result.members[safe: item.slotIndex]?.element ?? ""))
            }
            .chartXScale(domain: 0...100)
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .frame(height: 14)
            .clipShape(Capsule())

            // 三人输出占比与实装配置（点按弹出面板对账 Sheet）
            HStack(alignment: .top, spacing: 8) {
                ForEach(result.contributions) { contrib in
                    if let m = result.members[safe: contrib.slotIndex] {
                        let elColor = WuwaElementStyle.color(for: m.element)
                        Button {
                            verifyMember = m
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 4) {
                                    Circle().fill(elColor).frame(width: 6, height: 6)
                                    Text(m.name)
                                        .font(.system(size: 12, weight: .semibold))
                                        .lineLimit(1)
                                }
                                Text("\(m.chain)链 R\(m.weaponRank ?? 1) · \(String(format: "%.1f%%", contrib.share * 100))")
                                    .font(.system(size: 10.5))
                                    .monospacedDigit()
                                    .foregroundStyle(Palette.textSecondary)
                                Text(formatWan(contrib.totalDamage))
                                    .font(.system(size: 12, weight: .semibold))
                                    .monospacedDigit()
                                    .foregroundStyle(Palette.textPrimary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.pressable)
                    }
                }
            }

            if let hist = wuwa.teamHistory, hist.chronological.count >= 2 {
                Divider().overlay(Palette.hairline)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("团队实战轮伤成长曲线")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Palette.textSecondary)
                        Spacer()
                        if let netPct = hist.netDprDeltaPct {
                            Text("累计 \(netPct >= 0 ? "+" : "")\(String(format: "%.1f%%", netPct * 100))")
                                .font(.system(size: 11, weight: .semibold))
                                .monospacedDigit()
                                .foregroundStyle(netPct >= 0 ? Palette.success : Palette.danger)
                        }
                    }
                    Chart {
                        ForEach(Array(hist.chronological.enumerated()), id: \.offset) { idx, pt in
                            LineMark(
                                x: .value("阶段", idx + 1),
                                y: .value("DPR", pt.dpr)
                            )
                            .foregroundStyle(Palette.success)
                            .lineStyle(StrokeStyle(lineWidth: 2))
                            PointMark(
                                x: .value("阶段", idx + 1),
                                y: .value("DPR", pt.dpr)
                            )
                            .foregroundStyle(Palette.success)
                            .symbolSize(26)
                        }
                    }
                    .chartXAxis(.hidden)
                    .chartYScale(domain: .automatic(includesZero: false))
                    .frame(height: 68)
                }
            }
        }
        .padding(16)
        .cardSurface()
    }

    // MARK: - 4-Tab Experimental Workbench

    private func labWorkbenchCard(result: WuwaTeamCalcResult) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(LabTab.allCases) { tab in
                        let selected = activeLabTab == tab
                        Button {
                            Haptics.selection()
                            activeLabTab = tab
                        } label: {
                            Text(tab.rawValue)
                                .font(.system(size: 12.5, weight: selected ? .semibold : .medium))
                                .foregroundStyle(selected ? .white : Palette.textSecondary)
                                .padding(.horizontal, 11)
                                .padding(.vertical, 6.5)
                                .background(Capsule().fill(selected ? Palette.textPrimary : Palette.fieldFill))
                        }
                        .buttonStyle(.pressable)
                    }
                }
            }

            switch activeLabTab {
            case .gold:
                goldAdvisorTab
            case .sandbox:
                sandboxTab(result: result)
            case .sensitivity:
                sensitivityTab(result: result)
            case .graduation:
                graduationTab(result: result)
            }
        }
        .padding(16)
        .cardSurface()
    }

    // Tab 1: 下一金建议
    @ViewBuilder
    private var goldAdvisorTab: some View {
        @Bindable var bindable = wuwa
        HStack {
            Text("抽卡预算")
                .font(.system(size: 12.5))
                .foregroundStyle(Palette.textSecondary)
            Spacer()
            HStack(spacing: 4) {
                ForEach(1...4, id: \.self) { g in
                    let selected = wuwa.multiGoldBudget == g
                    Button("+\(g)金") {
                        bindable.multiGoldBudget = g
                        wuwa.scheduleCalcRecompute()
                        Haptics.selection()
                    }
                    .font(.system(size: 12, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected ? .white : Palette.textSecondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(selected ? Palette.textPrimary : Palette.fieldFill))
                }
            }
        }

        if let multi = wuwa.multiGoldBundle?.multi {
            if let trap = multi.greedyTrap {
                Text(trap.message)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.textPrimary)
                    .padding(11)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.warning.opacity(0.14)))
            }

            if let best = multi.bestPlan {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("全局最优路径 · \(best.totalGold) 金")
                                .font(.system(size: 11))
                                .foregroundStyle(Palette.textSecondary)
                            Text(best.summaryTitle)
                                .font(.system(size: 15, weight: .semibold))
                        }
                        Spacer()
                        Text("+\(String(format: "%.1f%%", best.gainPct * 100))")
                            .font(.system(size: 13, weight: .bold))
                            .monospacedDigit()
                            .foregroundStyle(Palette.success)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Palette.success.opacity(0.14)))
                    }

                    HStack {
                        Text("均摊 +\(String(format: "%.1f%%", best.gainPctPerGold * 100)) / 金 · 预计 DPR \(formatWan(best.newDpr))")
                            .font(.system(size: 11.5))
                            .monospacedDigit()
                            .foregroundStyle(Palette.textSecondary)
                        Spacer()
                        Button("套入沙盒预览") {
                            wuwa.applyTeamOverrides(best.teamOverrides, message: "已套用「\(best.summaryTitle)」至沙盒")
                            Haptics.success()
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Palette.textPrimary))
                    }
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Palette.fieldFill)
                )
            }

            let alts = multi.topPlansForBudget.dropFirst().prefix(3)
            if !alts.isEmpty {
                ForEach(Array(alts)) { plan in
                    Divider().overlay(Palette.hairline)
                    HStack {
                        Text(plan.summaryTitle)
                            .font(.system(size: 12.5))
                        Spacer()
                        Text("+\(String(format: "%.1f%%", plan.gainPct * 100))")
                            .font(.system(size: 12.5, weight: .semibold))
                            .monospacedDigit()
                        Button("预览") {
                            wuwa.applyTeamOverrides(plan.teamOverrides)
                        }
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Color(hex: 0x2B93CF))
                    }
                }
            }
        } else {
            Text("正在运算多金全局最优组合…")
                .font(.system(size: 12.5))
                .foregroundStyle(Palette.textSecondary)
        }
    }

    // Tab 2: 配装沙盒
    private func sandboxTab(result: WuwaTeamCalcResult) -> some View {
        let slot = wuwa.selectedLabSlot
        let baseMember = wuwa.evalBundle?.baseResult?.members[safe: slot]
        let curMember = result.members[safe: slot]
        let origDetail = curMember.flatMap { wuwa.detailsByRoleId[$0.roleId] }
        let curChain = curMember?.chain ?? 0
        let baseChain = baseMember?.chain ?? curChain
        let curRank = curMember?.weaponRank ?? 1
        let weapons = origDetail.flatMap { wuwa.compatibleWeaponsByType[$0.role.weaponTypeId] } ?? []
        let curWeaponId = wuwa.sandboxOverrides[String(slot)]?.weaponId ?? origDetail?.weapon?.weaponId ?? 0

        return VStack(alignment: .leading, spacing: 12) {
            Picker("编辑槽位", selection: Binding(
                get: { wuwa.selectedLabSlot },
                set: {
                    wuwa.selectedLabSlot = $0
                    wuwa.scheduleCalcRecompute()
                }
            )) {
                ForEach(result.members.indices, id: \.self) { idx in
                    Text("\(idx + 1)号位 · \(result.members[idx].name)").tag(idx)
                }
            }
            .pickerStyle(.segmented)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("\(curMember?.name ?? "") · 共鸣链")
                        .font(.system(size: 13, weight: .medium))
                    Spacer()
                    Text("绿点为当前持有 (\(baseChain)链)")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.textSecondary)
                }
                HStack(spacing: 4) {
                    ForEach(0...6, id: \.self) { c in
                        let selected = c == curChain
                        let isBase = c == baseChain
                        Button {
                            Haptics.selection()
                            wuwa.updateSandboxOverride(slot: slot) {
                                $0.chain = (c == baseChain) ? nil : c
                            }
                        } label: {
                            VStack(spacing: 2) {
                                Text("\(c)链")
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .monospacedDigit()
                                Circle()
                                    .fill(isBase ? Palette.success : .clear)
                                    .frame(width: 4, height: 4)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .foregroundStyle(selected ? .white : Palette.textSecondary)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(selected ? Palette.textPrimary : Palette.fieldFill))
                        }
                        .buttonStyle(.pressable)
                    }
                }
            }

            if !weapons.isEmpty {
                HStack {
                    Text("更换武器")
                        .font(.system(size: 13))
                    Spacer()
                    Picker("武器", selection: Binding(
                        get: { curWeaponId },
                        set: { wid in
                            wuwa.updateSandboxOverride(slot: slot) {
                                $0.weaponId = (wid == origDetail?.weapon?.weaponId) ? nil : wid
                            }
                        }
                    )) {
                        ForEach(weapons) { w in
                            Text("\(w.name) (\(w.starLevel)★)").tag(w.id)
                        }
                    }
                    .labelsHidden()
                    .tint(Palette.textPrimary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("武器谐振阶数 · 当前 R\(curRank)")
                    .font(.system(size: 13))
                HStack(spacing: 6) {
                    ForEach(1...5, id: \.self) { r in
                        let selected = r == curRank
                        Button("R\(r)") {
                            Haptics.selection()
                            wuwa.updateSandboxOverride(slot: slot) {
                                $0.weaponRank = (r == baseMember?.weaponRank) ? nil : r
                            }
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .foregroundStyle(selected ? .white : Palette.textSecondary)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(selected ? Palette.textPrimary : Palette.fieldFill))
                    }
                }
            }

            Toggle("预览核心技能全满 Lv.10", isOn: Binding(
                get: { wuwa.sandboxOverrides[String(slot)]?.allSkillsLv10 ?? false },
                set: { on in
                    wuwa.updateSandboxOverride(slot: slot) { $0.allSkillsLv10 = on ? true : nil }
                }
            ))
            .font(.system(size: 13))
        }
    }

    // Tab 3: 词条灵敏度与弱声骸
    private func sensitivityTab(result: WuwaTeamCalcResult) -> some View {
        let elColor = WuwaElementStyle.color(for: result.members[safe: wuwa.selectedLabSlot]?.element ?? "")
        return VStack(alignment: .leading, spacing: 12) {
            if let sens = wuwa.sensitivityBundle {
                Text("每增加 1 条标准有效副词条的整队收益")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.textSecondary)

                let positiveSubs = sens.substats.filter { $0.gainPct > 0.0005 }.prefix(6)
                ForEach(Array(positiveSubs)) { item in
                    HStack(spacing: 8) {
                        Text("\(item.propName) \(item.rollValueText)")
                            .font(.system(size: 12))
                            .frame(width: 118, alignment: .leading)
                            .lineLimit(1)
                        GeometryReader { geo in
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Palette.fieldFill)
                                .overlay(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(elColor)
                                        .frame(width: geo.size.width * CGFloat(max(0.05, item.relativeWeight)))
                                }
                        }
                        .frame(height: 8)
                        Text("+\(String(format: "%.2f%%", item.gainPct * 100))")
                            .font(.system(size: 12, weight: .semibold))
                            .monospacedDigit()
                            .frame(width: 58, alignment: .trailing)
                    }
                }

                if let weakest = sens.weakestEchoes.first(where: \.isWeakest) {
                    Divider().overlay(Palette.hairline)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("最弱短板声骸 · \(weakest.echoName)")
                                .font(.system(size: 13, weight: .semibold))
                            Spacer()
                            Text("\(weakest.grade.uppercased()) · \(String(format: "%.1f", weakest.echoScore))")
                                .font(.system(size: 11.5, weight: .bold))
                                .monospacedDigit()
                                .foregroundStyle(WuwaElementStyle.gradeColor(weakest.grade))
                        }
                        Text("该件副词条当前仅贡献整队 +\(String(format: "%.2f%%", weakest.substatGainPct * 100)) DPR，是整套最优先重刷替换槽位。")
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.textSecondary)
                    }
                }
            } else {
                Text("正在分析词条边际收益与短板声骸…")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.textSecondary)
            }
        }
    }

    // Tab 4: 毕业基准与充能体检
    private func graduationTab(result: WuwaTeamCalcResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let grad = wuwa.graduationReport {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("\(grad.roleName) · \(grad.verdictTitle)")
                            .font(.system(size: 13, weight: .semibold))
                        Spacer()
                        Text("\(String(format: "%.1f", grad.currentEchoScore)) 分")
                            .font(.system(size: 12.5, weight: .bold))
                            .monospacedDigit()
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 5).fill(Palette.fieldFill)
                            RoundedRectangle(cornerRadius: 5)
                                .fill(Palette.success)
                                .frame(width: geo.size.width * CGFloat(min(1, max(0.04, grad.progressOnScale))))
                        }
                    }
                    .frame(height: 8)
                    Text(grad.verdictDetail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.textSecondary)

                    HStack {
                        Text("大毕业线 \(formatWan(grad.bigGrad.teamDpr))")
                            .font(.system(size: 11.5))
                            .monospacedDigit()
                            .foregroundStyle(Palette.textSecondary)
                        Spacer()
                        Button("套入大毕业声骸预览") {
                            wuwa.updateSandboxOverride(slot: grad.slotIndex) {
                                $0.customEchoes = grad.bigGrad.templateEchoes
                            }
                            Haptics.success()
                        }
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Color(hex: 0x2B93CF))
                    }
                }
            }

            if !wuwa.erCheckup.isEmpty {
                Divider().overlay(Palette.hairline)
                Text("共鸣效率循环体检")
                    .font(.system(size: 12.5, weight: .semibold))

                ForEach(wuwa.erCheckup) { er in
                    let stColor = erStatusColor(er.status)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text("\(er.roleName) · 实战 \(String(format: "%.1f%%", er.effectiveCombatEr * 100))")
                                .font(.system(size: 12.5, weight: .semibold))
                                .monospacedDigit()
                            Spacer()
                            Text(er.statusLabel)
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(stColor)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(stColor.opacity(0.14)))
                        }
                        Text(er.advice)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Palette.textSecondary)
                    }
                    .padding(.vertical, 3)
                }
            }
        }
    }

    private func erStatusColor(_ status: String) -> Color {
        switch status {
        case "capped", "ok": return Palette.success
        case "slightly_low": return Palette.warning
        default: return Palette.danger
        }
    }

    // MARK: - Expandable Rotation Steps

    private func rotationStepsCard(result: WuwaTeamCalcResult) -> some View {
        let filtered = stepActorFilter < 0 ? result.steps : result.steps.filter { $0.actorSlot == stepActorFilter }
        return DisclosureGroup("轮切动作伤害明细 (\(result.steps.count) 步)", isExpanded: $showSteps) {
            VStack(alignment: .leading, spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        filterPill("全部", idx: -1)
                        ForEach(result.members.indices, id: \.self) { idx in
                            filterPill(result.members[idx].name, idx: idx)
                        }
                    }
                    .padding(.top, 8)
                }

                ForEach(filtered) { step in
                    Divider().overlay(Palette.hairline)
                    Button {
                        selectedStep = step
                        Haptics.tap(.soft)
                    } label: {
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(step.actorName) · \(step.label)")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Palette.textPrimary)
                                    .multilineTextAlignment(.leading)
                                Text(step.breakdown.sources.prefix(2).joined(separator: " / "))
                                    .font(.system(size: 11))
                                    .foregroundStyle(Palette.textSecondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 1) {
                                Text(formatInt(step.expectedDamage))
                                    .font(.system(size: 13, weight: .bold))
                                    .monospacedDigit()
                                Text(String(format: "%.1f%%", step.share * 100))
                                    .font(.system(size: 11))
                                    .monospacedDigit()
                                    .foregroundStyle(Palette.textSecondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.pressable)
                }
            }
        }
        .font(.system(size: 14, weight: .semibold))
        .padding(16)
        .cardSurface()
    }

    private func filterPill(_ title: String, idx: Int) -> some View {
        let selected = stepActorFilter == idx
        return Button(title) {
            stepActorFilter = idx
        }
        .font(.system(size: 11.5, weight: selected ? .semibold : .medium))
        .foregroundStyle(selected ? .white : Palette.textSecondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Capsule().fill(selected ? Palette.textPrimary : Palette.fieldFill))
    }

    private func missingTeamMembersCard(preset: WuwaTeamPresetSummary) -> some View {
        let missing = preset.slots.filter { wuwa.detailsByRoleId[$0.roleId] == nil }
        return missingPrompt(
            title: "当前预设尚缺 \(missing.count) 位角色面板",
            detail: "缺失角色：\(missing.map(\.name).joined(separator: "、"))。请选择已持有的配队，或同步角色详情后重算。",
            buttonTitle: "同步角色面板"
        ) {
            Task { await wuwa.refreshCommunity(forceDetails: true) }
        }
    }

    private func missingPrompt(title: String, detail: String, buttonTitle: String, action: @escaping () -> Void) -> some View {
        VStack(spacing: 12) {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
            Text(detail)
                .font(.system(size: 13))
                .foregroundStyle(Palette.textSecondary)
                .multilineTextAlignment(.center)
            Button(buttonTitle, action: action)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 9)
                .background(Capsule().fill(Color(hex: 0x2B93CF)))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
        .padding(.horizontal, 18)
        .cardSurface()
    }

    private func formatInt(_ v: Double) -> String {
        Int(v.rounded()).formatted(.number)
    }

    private func formatWan(_ v: Double) -> String {
        if v < 10_000 { return formatInt(v) }
        return String(format: "%.2f 万", v / 10_000)
    }
}

// MARK: - Step 6-Multiplier Breakdown Sheet

private struct StepBreakdownSheet: View {
    @Environment(\.dismiss) private var dismiss
    var step: WuwaStepDamageResult

    var body: some View {
        let b = step.breakdown
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(step.actorName) · \(step.label)")
                            .font(RelayFont.display(20))
                        Text("期望伤害 \(Int(step.expectedDamage.rounded()).formatted()) · 占整队 \(String(format: "%.1f%%", step.share * 100))")
                            .font(.system(size: 13))
                            .monospacedDigit()
                            .foregroundStyle(Palette.textSecondary)
                    }

                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 12) {
                        cell("有效属性", "\(Int(b.effectiveStat.rounded()).formatted())")
                        cell("原始倍率", String(format: "%.1f%%", b.rawMultiplier * 100))
                        cell("增伤区", String(format: "%+.1f%%", b.dmgBonus * 100))
                        cell("加深区", String(format: "%+.1f%%", b.deepen * 100))
                        cell("双暴期望", "×\(String(format: "%.3f", b.critExpectedMult))")
                        cell("防抗乘区", "×\(String(format: "%.4f", b.defMult * b.resMult))")
                    }
                    .padding(14)
                    .cardSurface(radius: 16)

                    if let tail = step.tailHit {
                        HStack {
                            Text("尾刀单跳（共 \(tail.hitCount) 段）")
                            Spacer()
                            Text("暴击 \(Int(tail.critDamage.rounded()).formatted()) / 未暴击 \(Int(tail.nonCritDamage.rounded()).formatted())")
                                .monospacedDigit()
                                .foregroundStyle(Palette.textSecondary)
                        }
                        .font(.system(size: 12.5))
                        .padding(12)
                        .cardSurface(radius: 14)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("本步生效 Buff 来源")
                            .font(.system(size: 14, weight: .semibold))
                        if b.sources.isEmpty {
                            Text("无额外动态 Buff，按角色基础乘区结算。")
                                .font(.system(size: 12.5))
                                .foregroundStyle(Palette.textSecondary)
                        } else {
                            ForEach(Array(b.sources.enumerated()), id: \.offset) { idx, src in
                                if idx > 0 { Divider().overlay(Palette.hairline) }
                                Text(src)
                                    .font(.system(size: 12.5))
                                    .foregroundStyle(Palette.textPrimary)
                            }
                        }
                    }
                    .padding(14)
                    .cardSurface(radius: 16)
                }
                .padding(16)
            }
            .background(Palette.canvas)
            .navigationTitle("乘区拆解")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private func cell(_ label: String, _ val: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(Palette.textSecondary)
            Text(val)
                .font(.system(size: 14, weight: .semibold))
                .monospacedDigit()
        }
    }
}

// MARK: - Member Panel Verification Sheet

private struct MemberVerificationSheet: View {
    @Environment(\.dismiss) private var dismiss
    var member: WuwaRebuiltMemberSummary
    var onOpenDetail: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section("面板对账") {
                    ForEach(member.verification.items) { item in
                        HStack {
                            Text(item.label)
                            Spacer()
                            VStack(alignment: .trailing, spacing: 1) {
                                Text("局内 \(item.combatValue)")
                                    .font(.system(size: 12.5, weight: .semibold))
                                    .monospacedDigit()
                                Text("站街 \(item.kuroValue) / 重建 \(item.rebuiltValue)")
                                    .font(.system(size: 11))
                                    .monospacedDigit()
                                    .foregroundStyle(item.aligned ? Palette.textSecondary : Palette.warning)
                            }
                        }
                    }
                }
                if let bonus = member.mainEchoBonusSummary {
                    Section("首位声骸常驻补正") {
                        Text(bonus).font(.system(size: 13))
                    }
                }
                Section {
                    Button("进入 \(member.name) 角色详情") {
                        onOpenDetail()
                    }
                }
            }
            .navigationTitle("\(member.name) · \(member.chain)链")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
