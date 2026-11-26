import Charts
import SwiftUI

struct WuwaResonatorDetailView: View {
    @Environment(WuwaStore.self) private var wuwa
    @Environment(\.dismiss) private var dismiss
    var roleId: Int

    @State private var selectedSkillKey: String? = nil
    @State private var selectedChainOrder: Int? = nil
    @State private var expandedHistoryId: Int? = nil
    @State private var showAllHistory = false
    @State private var showWeights = false

    private var detail: WuwaResonatorDetail? { wuwa.detailsByRoleId[roleId] }
    private var scoreObj: WuwaEchoLoadoutScore? { wuwa.scoresByRoleId[roleId] }
    private var timeline: [WuwaComputedTimelineItem] { wuwa.timelineByRoleId[roleId] ?? [] }
    private var historyEntries: [WuwaResonatorHistoryEntry] { wuwa.historyByRoleId[roleId] ?? [] }
    private var weightTable: WuwaEchoWeightTable? { wuwa.weightTablesByRoleId[roleId] }
    private var isLoading: Bool { wuwa.loadingDetailIds.contains(roleId) }
    private var errorText: String? { wuwa.detailErrors[roleId] }

    var body: some View {
        ScrollView {
            if let detail {
                let tint = WuwaElementStyle.color(for: detail.role.attributeName)
                LazyVStack(spacing: 14) {
                    heroCard(detail: detail, tint: tint)
                    attributesCard(detail: detail)
                    weaponCard(detail: detail, tint: tint)
                    echoesCard(detail: detail, tint: tint)
                    echoHistoryCard(detail: detail, tint: tint)
                    skillsCard(detail: detail, tint: tint)
                    chainsCard(detail: detail, tint: tint)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 32)
            } else if isLoading {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("正在读取角色完整面板与声骸…")
                        .font(.system(size: 13.5))
                        .foregroundStyle(Palette.textSecondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 60)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 28))
                        .foregroundStyle(Palette.warning)
                    Text(errorText ?? "没有获取到角色详情")
                        .font(.system(size: 14))
                        .foregroundStyle(Palette.textSecondary)
                    Button("重新读取") {
                        Task { await wuwa.loadResonatorDetail(roleId, forceRefresh: true) }
                    }
                    .font(.system(size: 14, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 50)
                .padding(.horizontal, 20)
                .cardSurface()
                .padding(16)
            }
        }
        .background(
            AmbientBackground(
                tint: detail.map { WuwaElementStyle.color(for: $0.role.attributeName) } ?? Color(hex: 0x2B93CF)
            )
        )
        .navigationTitle(detail?.role.name ?? "角色详情")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await wuwa.loadResonatorDetail(roleId, forceRefresh: true) }
                } label: {
                    if isLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(isLoading)
            }
        }
        .task(id: roleId) {
            await wuwa.loadResonatorDetail(roleId)
        }
    }

    // MARK: - Hero Card

    private func heroCard(detail: WuwaResonatorDetail, tint: Color) -> some View {
        let r = detail.role
        let artUrl = r.pictureUrl.isEmpty ? r.iconUrl : r.pictureUrl
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                WuwaRemoteImage(urlString: artUrl, fallbackText: r.name, tint: tint, contentMode: .fill)
                    .frame(width: 82, height: 98)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(tint.opacity(0.35), lineWidth: 1)
                    )

                VStack(alignment: .leading, spacing: 6) {
                    Text(String(repeating: "★", count: max(0, r.rarity)))
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color(hex: 0xE19A35))
                    Text(r.name)
                        .font(RelayFont.display(24))
                        .foregroundStyle(Palette.textPrimary)
                    HStack(spacing: 6) {
                        Circle().fill(tint).frame(width: 7, height: 7)
                        Text("\(r.attributeName) · \(r.weaponTypeName)")
                            .font(.system(size: 13))
                            .foregroundStyle(Palette.textSecondary)
                    }
                    HStack(spacing: 14) {
                        quickFact(label: "等级", value: "\(r.level)")
                        quickFact(label: "共鸣链", value: "\(r.chainLevel)/6")
                        quickFact(label: "技能", value: "\(r.totalSkillLevel)")
                    }
                    .padding(.top, 2)
                }
                Spacer(minLength: 0)
            }

            if let scoreObj, !detail.echoes.isEmpty {
                let gColor = WuwaElementStyle.gradeColor(scoreObj.grade)
                HStack(spacing: 10) {
                    Text(scoreObj.grade.uppercased())
                        .font(.system(size: 13, weight: .heavy))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(gColor))

                    VStack(alignment: .leading, spacing: 1) {
                        HStack(alignment: .firstTextBaseline, spacing: 3) {
                            Text(String(format: "%.2f", scoreObj.score))
                                .font(.system(size: 18, weight: .bold))
                                .monospacedDigit()
                            Text("/ 250")
                                .font(.system(size: 12))
                                .foregroundStyle(Palette.textSecondary)
                        }
                        Text("声骸总评 · \(scoreObj.template)")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Palette.textSecondary)
                    }
                    Spacer()
                }
                .padding(11)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(gColor.opacity(0.10))
                )
            }

            if wuwa.presetForRole(r.roleId) != nil {
                Button {
                    Haptics.tap(.medium)
                    wuwa.openInCalcLab(roleId: r.roleId)
                    dismiss()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "function")
                        Text("在伤害计算实验室中打开")
                    }
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(tint))
                }
                .buttonStyle(.pressable)
            }
        }
        .padding(16)
        .cardSurface()
    }

    private func quickFact(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 10.5))
                .foregroundStyle(Palette.textTertiary)
            Text(value)
                .font(.system(size: 13.5, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Palette.textPrimary)
        }
    }

    // MARK: - Attributes

    private func attributesCard(detail: WuwaResonatorDetail) -> some View {
        let cols = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)
        return VStack(alignment: .leading, spacing: 12) {
            Text("基础面板")
                .font(.system(size: 15, weight: .semibold))

            LazyVGrid(columns: cols, alignment: .leading, spacing: 12) {
                ForEach(Array(detail.attributes.enumerated()), id: \.offset) { _, attr in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(attr.name)
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.textSecondary)
                            .lineLimit(1)
                        Text(attr.value)
                            .font(.system(size: 14, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(Palette.textPrimary)
                    }
                }
            }

            if !detail.bonusAttributes.isEmpty {
                Divider().overlay(Palette.hairline)
                Text("声骸词条累计加成")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.textSecondary)
                FlowStatsWrap(items: detail.bonusAttributes.map { "\($0.name) +\($0.value)" })
            }
        }
        .padding(16)
        .cardSurface()
    }

    // MARK: - Weapon

    private func weaponCard(detail: WuwaResonatorDetail, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("装备武器")
                .font(.system(size: 15, weight: .semibold))

            if let w = detail.weapon {
                HStack(spacing: 12) {
                    WuwaRemoteImage(urlString: w.iconUrl, fallbackText: w.name, tint: tint, contentMode: .fit)
                        .frame(width: 54, height: 54)
                        .background(Palette.fieldFill)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(w.name)
                                .font(.system(size: 15, weight: .semibold))
                            Text(String(repeating: "★", count: max(0, w.rarity)))
                                .font(.system(size: 10.5))
                                .foregroundStyle(Color(hex: 0xE19A35))
                        }
                        Text("Lv.\(w.level) · 谐振 \(max(1, w.resonanceLevel)) 阶")
                            .font(.system(size: 12.5))
                            .monospacedDigit()
                            .foregroundStyle(Palette.textSecondary)
                        if !w.mainProps.isEmpty {
                            HStack(spacing: 10) {
                                ForEach(Array(w.mainProps.enumerated()), id: \.offset) { _, p in
                                    Text("\(p.name) \(p.value)")
                                        .font(.system(size: 11.5, weight: .medium))
                                        .monospacedDigit()
                                        .foregroundStyle(Palette.textPrimary)
                                }
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }

                if !w.effectDescription.isEmpty {
                    DisclosureGroup(w.effectName.isEmpty ? "武器特效说明" : w.effectName) {
                        Text(w.effectDescription)
                            .font(.system(size: 12.5))
                            .foregroundStyle(Palette.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 6)
                    }
                    .font(.system(size: 12.5, weight: .medium))
                    .tint(Palette.textSecondary)
                }
            } else {
                Text("当前未装备武器")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.textSecondary)
            }
        }
        .padding(16)
        .cardSurface()
    }

    // MARK: - Current Echoes & Weight Table

    private func echoesCard(detail: WuwaResonatorDetail, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("当前声骸")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Text("COST \(detail.totalEchoCost)")
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Palette.textSecondary)
            }

            if let scoreObj, !scoreObj.echoes.isEmpty {
                HStack(spacing: 12) {
                    legendDot(color: Palette.success, label: "核心")
                    legendDot(color: Color(hex: 0x2B93CF), label: "次要")
                    legendDot(color: Palette.textPrimary, label: "可用")
                    Text("▲ 满档")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Palette.warning)
                }

                ForEach(Array(scoreObj.echoes.enumerated()), id: \.offset) { idx, item in
                    if idx > 0 { Divider().overlay(Palette.hairline) }
                    echoItemBlock(item: item)
                }
            } else {
                Text("该角色当前未装备声骸。")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.textSecondary)
            }

            if let weightTable {
                DisclosureGroup("查看评分权重 · \(weightTable.template)", isExpanded: $showWeights) {
                    VStack(spacing: 6) {
                        HStack {
                            Text("词条").frame(maxWidth: .infinity, alignment: .leading)
                            Text("4C").frame(width: 42, alignment: .trailing)
                            Text("3C").frame(width: 42, alignment: .trailing)
                            Text("1C").frame(width: 42, alignment: .trailing)
                            Text("副词条").frame(width: 48, alignment: .trailing)
                        }
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Palette.textTertiary)
                        .padding(.top, 6)

                        ForEach(weightTable.rows) { row in
                            HStack {
                                Text(row.name)
                                    .foregroundStyle(WuwaElementStyle.importanceColor(row.importance))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text(row.cost4.map { String(format: "%.2f", $0) } ?? "—").frame(width: 42, alignment: .trailing)
                                Text(row.cost3.map { String(format: "%.2f", $0) } ?? "—").frame(width: 42, alignment: .trailing)
                                Text(row.cost1.map { String(format: "%.2f", $0) } ?? "—").frame(width: 42, alignment: .trailing)
                                Text(row.sub.map { String(format: "%.2f", $0) } ?? "—").frame(width: 48, alignment: .trailing)
                            }
                            .font(.system(size: 11))
                            .monospacedDigit()
                            .foregroundStyle(Palette.textSecondary)
                        }
                    }
                }
                .font(.system(size: 12.5, weight: .medium))
                .tint(tint)
            }
        }
        .padding(16)
        .cardSurface()
    }

    private func legendDot(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(Palette.textSecondary)
        }
    }

    private func echoItemBlock(item: WuwaEchoItemScore) -> some View {
        let ec = item.echo
        let gradeCol = WuwaElementStyle.gradeColor(item.grade)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                WuwaRemoteImage(urlString: ec.iconUrl, fallbackText: ec.name, tint: gradeCol, contentMode: .fit)
                    .frame(width: 40, height: 40)
                    .background(Palette.fieldFill)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(ec.name)
                        .font(.system(size: 13.5, weight: .semibold))
                    Text("\(ec.setName.isEmpty ? "散件" : ec.setName) · C\(ec.cost) · +\(ec.level)")
                        .font(.system(size: 11.5))
                        .monospacedDigit()
                        .foregroundStyle(Palette.textSecondary)
                }
                Spacer()
                HStack(spacing: 5) {
                    Text(item.grade.uppercased())
                        .font(.system(size: 10.5, weight: .heavy))
                        .foregroundStyle(gradeCol)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(gradeCol.opacity(0.14)))
                    Text(String(format: "%.1f", item.score))
                        .font(.system(size: 14, weight: .bold))
                        .monospacedDigit()
                }
            }

            VStack(spacing: 3) {
                ForEach(Array(item.mainProps.enumerated()), id: \.offset) { _, mp in
                    HStack {
                        Text(mp.prop.name)
                            .font(.system(size: 12, weight: .medium))
                        Spacer()
                        Text(mp.prop.value)
                            .font(.system(size: 12, weight: .semibold))
                            .monospacedDigit()
                        Text(mp.score > 0 ? String(format: "%.1f", mp.score) : "")
                            .font(.system(size: 11))
                            .monospacedDigit()
                            .foregroundStyle(Palette.textTertiary)
                            .frame(width: 34, alignment: .trailing)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.fieldFill))

            VStack(spacing: 4) {
                ForEach(Array(item.subProps.enumerated()), id: \.offset) { _, sp in
                    let impColor = WuwaElementStyle.importanceColor(sp.importance)
                    HStack(spacing: 6) {
                        Circle().fill(impColor).frame(width: 5, height: 5)
                        Text(sp.prop.name)
                            .foregroundStyle(impColor)
                        if sp.maxRoll {
                            Text("▲")
                                .font(.system(size: 9.5, weight: .bold))
                                .foregroundStyle(Palette.warning)
                        }
                        Spacer()
                        Text(sp.prop.value)
                            .monospacedDigit()
                            .foregroundStyle(impColor)
                        Text(sp.score > 0 ? String(format: "%.1f", sp.score) : "—")
                            .monospacedDigit()
                            .foregroundStyle(Palette.textTertiary)
                            .frame(width: 34, alignment: .trailing)
                    }
                    .font(.system(size: 12, weight: sp.importance == "s" ? .semibold : .regular))
                }
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Echo History & Progression Timeline (Requested Key Feature)

    private func echoHistoryCard(detail: WuwaResonatorDetail, tint: Color) -> some View {
        let netGain: Double? = timeline.count >= 2 ? (timeline.first!.score - timeline.last!.score) : nil
        let visible = showAllHistory ? timeline : Array(timeline.prefix(6))
        let chronoPoints = Array(timeline.reversed())

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("声骸历史与练度轨迹")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                if let netGain, abs(netGain) >= 0.05 {
                    let up = netGain >= 0
                    Text("累计 \(up ? "+" : "")\(String(format: "%.1f", netGain)) 分")
                        .font(.system(size: 11.5, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(up ? Palette.success : Palette.danger)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill((up ? Palette.success : Palette.danger).opacity(0.14)))
                }
                Text("\(timeline.count) 次快照")
                    .font(.system(size: 11.5))
                    .monospacedDigit()
                    .foregroundStyle(Palette.textSecondary)
            }

            if chronoPoints.count >= 2 {
                Chart {
                    ForEach(Array(chronoPoints.enumerated()), id: \.offset) { idx, pt in
                        AreaMark(
                            x: .value("次序", idx + 1),
                            y: .value("声骸分", pt.score)
                        )
                        .foregroundStyle(
                            LinearGradient(
                                colors: [tint.opacity(0.28), tint.opacity(0.02)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        LineMark(
                            x: .value("次序", idx + 1),
                            y: .value("声骸分", pt.score)
                        )
                        .foregroundStyle(tint)
                        .lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round))
                        PointMark(
                            x: .value("次序", idx + 1),
                            y: .value("声骸分", pt.score)
                        )
                        .foregroundStyle(tint)
                        .symbolSize(34)
                    }
                }
                .chartXAxis(.hidden)
                .chartYScale(domain: .automatic(includesZero: false))
                .frame(height: 115)
            }

            ForEach(Array(visible.enumerated()), id: \.element.id) { idx, item in
                if idx > 0 { Divider().overlay(Palette.hairline) }
                timelineItemRow(item: item, index: idx, tint: tint)
            }

            if timeline.count > 6 {
                Button(showAllHistory ? "收起较早记录" : "展开全部 \(timeline.count) 条声骸快照") {
                    withAnimation(.snappy(duration: 0.25)) {
                        showAllHistory.toggle()
                    }
                }
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(tint)
            }

            if timeline.count <= 1 {
                HStack(spacing: 6) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 13))
                    Text("已记录当前声骸基线，后续换装并同步时会自动保存每次变动快照。")
                        .font(.system(size: 12))
                }
                .foregroundStyle(Palette.textSecondary)
            }
        }
        .padding(16)
        .cardSurface()
    }

    private func timelineItemRow(item: WuwaComputedTimelineItem, index: Int, tint: Color) -> some View {
        let entry = historyEntries.first(where: { $0.id == item.id }) ?? historyEntries[safe: index]
        let prevEntry = historyEntries[safe: index + 1]
        let isExpanded = expandedHistoryId == item.id

        return VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Circle()
                    .fill(index == 0 ? tint : Palette.textTertiary)
                    .frame(width: 7, height: 7)
                Text(item.recordedAtLabel)
                    .font(.system(size: 12.5, weight: .semibold))
                    .monospacedDigit()
                Text("Lv.\(item.level) · \(item.chainLevel)链")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.textSecondary)
                Spacer()
                Text(item.grade.uppercased())
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(WuwaElementStyle.gradeColor(item.grade))
                Text(String(format: "%.1f", item.score))
                    .font(.system(size: 13.5, weight: .bold))
                    .monospacedDigit()
                if let delta = item.scoreDelta, abs(delta) >= 0.05 {
                    let up = delta > 0
                    Text("\(up ? "+" : "")\(String(format: "%.1f", delta))")
                        .font(.system(size: 11, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(up ? Palette.success : Palette.danger)
                } else if item.isBaseline {
                    Text(timeline.count == 1 ? "当前基线" : "初始基线")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Palette.textTertiary)
                }
            }

            if !item.milestones.isEmpty {
                FlowStatsWrap(items: item.milestones, accent: tint)
            }

            if !item.stats.isEmpty {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 6) {
                    ForEach(item.stats) { st in
                        HStack(spacing: 4) {
                            Text(st.label)
                                .foregroundStyle(Palette.textSecondary)
                            Text(st.valueText)
                                .fontWeight(.semibold)
                            if let diff = st.diffText {
                                Text(diff)
                                    .foregroundStyle(st.diffDir == "up" ? Palette.success : (st.diffDir == "down" ? Palette.danger : Palette.textSecondary))
                            }
                        }
                        .font(.system(size: 11.5))
                        .monospacedDigit()
                        .lineLimit(1)
                    }
                }
            }

            if let entry, !entry.echoes.isEmpty {
                Button {
                    withAnimation(.snappy(duration: 0.22)) {
                        expandedHistoryId = isExpanded ? nil : item.id
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(isExpanded ? "收起当期声骸" : "查看当期 \(entry.echoes.count) 件声骸")
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    }
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(tint)
                }
                .padding(.top, 2)

                if isExpanded {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(entry.echoes.enumerated()), id: \.offset) { slotIdx, ec in
                            let prevEcho = prevEntry?.echoes[safe: slotIdx]
                            let changed = prevEcho != nil && prevEcho != ec
                            HStack(alignment: .top, spacing: 8) {
                                Text("C\(ec.cost)")
                                    .font(.system(size: 10.5, weight: .bold))
                                    .monospacedDigit()
                                    .foregroundStyle(Palette.textSecondary)
                                    .frame(width: 24, alignment: .leading)
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(ec.name)
                                            .font(.system(size: 12, weight: .semibold))
                                        if let main = ec.mainProps.first {
                                            Text("\(main.name) \(main.value)")
                                                .font(.system(size: 11))
                                                .foregroundStyle(Palette.textSecondary)
                                        }
                                        if changed {
                                            Text("已更换")
                                                .font(.system(size: 10, weight: .semibold))
                                                .foregroundStyle(Palette.warning)
                                                .padding(.horizontal, 5)
                                                .padding(.vertical, 1)
                                                .background(Capsule().fill(Palette.warning.opacity(0.16)))
                                        }
                                    }
                                    Text(ec.subProps.map { "\($0.name) \($0.value)" }.joined(separator: " · "))
                                        .font(.system(size: 11))
                                        .monospacedDigit()
                                        .foregroundStyle(Palette.textSecondary)
                                }
                            }
                            .padding(.vertical, 4)
                            if slotIdx < entry.echoes.count - 1 {
                                Divider().overlay(Palette.hairline)
                            }
                        }
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.fieldFill))
                }
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Skills & Chains

    private func skillsCard(detail: WuwaResonatorDetail, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("技能等级")
                .font(.system(size: 15, weight: .semibold))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(detail.skills, id: \.id) { sk in
                        let key = "\(sk.id)-\(sk.skillType)"
                        let selected = selectedSkillKey == key
                        Button {
                            selectedSkillKey = selected ? nil : key
                        } label: {
                            VStack(spacing: 5) {
                                WuwaRemoteImage(urlString: sk.iconUrl, fallbackText: sk.skillType, tint: tint, contentMode: .fit)
                                    .frame(width: 40, height: 40)
                                    .background(Circle().fill(selected ? tint.opacity(0.24) : Palette.fieldFill))
                                    .clipShape(Circle())
                                Text(sk.skillType.isEmpty ? sk.name : sk.skillType)
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(Palette.textSecondary)
                                    .lineLimit(1)
                                Text("Lv.\(sk.level)")
                                    .font(.system(size: 11, weight: .semibold))
                                    .monospacedDigit()
                            }
                            .frame(width: 64)
                        }
                        .buttonStyle(.pressable)
                    }
                }
            }
            if let key = selectedSkillKey,
               let sk = detail.skills.first(where: { "\($0.id)-\($0.skillType)" == key }) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(sk.name) · Lv.\(sk.level)")
                        .font(.system(size: 13, weight: .semibold))
                    Text(sk.description.isEmpty ? "暂无说明" : sk.description)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.fieldFill))
            }
        }
        .padding(16)
        .cardSurface()
    }

    private func chainsCard(detail: WuwaResonatorDetail, tint: Color) -> some View {
        let unlocked = detail.chains.filter(\.unlocked).count
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("共鸣链")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Text("已解锁 \(unlocked)/\(max(6, detail.chains.count))")
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(Palette.textSecondary)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(detail.chains, id: \.order) { ch in
                        let selected = selectedChainOrder == ch.order
                        Button {
                            selectedChainOrder = selected ? nil : ch.order
                        } label: {
                            VStack(spacing: 5) {
                                WuwaRemoteImage(urlString: ch.iconUrl, fallbackText: "\(ch.order)", tint: tint, contentMode: .fit)
                                    .frame(width: 40, height: 40)
                                    .opacity(ch.unlocked ? 1 : 0.35)
                                    .background(Circle().fill(selected ? tint.opacity(0.24) : Palette.fieldFill))
                                    .clipShape(Circle())
                                Text("\(ch.order) 链")
                                    .font(.system(size: 11, weight: ch.unlocked ? .semibold : .regular))
                                    .foregroundStyle(ch.unlocked ? tint : Palette.textTertiary)
                            }
                            .frame(width: 56)
                        }
                        .buttonStyle(.pressable)
                    }
                }
            }
            if let order = selectedChainOrder,
               let ch = detail.chains.first(where: { $0.order == order }) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(ch.name.isEmpty ? "第 \(ch.order) 链" : ch.name) · \(ch.unlocked ? "已解锁" : "未解锁")")
                        .font(.system(size: 13, weight: .semibold))
                    Text(ch.description.isEmpty ? "暂无说明" : ch.description)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.fieldFill))
            }
        }
        .padding(16)
        .cardSurface()
    }
}

private struct FlowStatsWrap: View {
    var items: [String]
    var accent: Color = Palette.textSecondary

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, txt in
                    Text(txt)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(accent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Palette.fieldFill))
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
