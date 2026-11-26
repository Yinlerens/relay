import Charts
import SwiftUI

struct WuwaGachaView: View {
    @Environment(WuwaStore.self) private var wuwa
    var onOpenImport: () -> Void

    enum TabMode: String, CaseIterable, Identifiable {
        case history = "出货记录"
        case planner = "星声规划"
        var id: String { rawValue }
    }

    @State private var mode: TabMode = .history

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                Picker("唤取功能", selection: $mode) {
                    ForEach(TabMode.allCases) { item in
                        Text(item.rawValue).tag(item)
                    }
                }
                .pickerStyle(.segmented)

                if mode == .history {
                    historySection
                } else {
                    plannerSection
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 2)
            .padding(.bottom, 28)
        }
        .onAppear {
            if wuwa.pulls.isEmpty {
                mode = .planner
            }
        }
    }

    // MARK: - History Section

    @ViewBuilder
    private var historySection: some View {
        if wuwa.pools.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(Palette.textSecondary)
                Text("还没有唤取记录")
                    .font(RelayFont.display(20))
                Text("支持直接粘贴国服唤取记录链接或导入 WaveShelf 备份 JSON。")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.textSecondary)
                    .multilineTextAlignment(.center)
                Button("导入唤取记录") {
                    onOpenImport()
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 9)
                .background(Capsule().fill(Color(hex: 0x2B93CF)))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 44)
            .padding(.horizontal, 18)
            .cardSurface()
        } else {
            let active = wuwa.pools.first(where: { $0.poolType == wuwa.selectedPoolType }) ?? wuwa.pools[0]

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(wuwa.pools) { pool in
                        let selected = pool.poolType == active.poolType
                        Button {
                            Haptics.selection()
                            wuwa.selectedPoolType = pool.poolType
                        } label: {
                            HStack(spacing: 5) {
                                Text(pool.shortName)
                                Text("\(pool.total)")
                                    .monospacedDigit()
                                    .opacity(0.75)
                            }
                            .font(.system(size: 12.5, weight: selected ? .semibold : .medium))
                            .foregroundStyle(selected ? .white : Palette.textSecondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Capsule().fill(selected ? Palette.textPrimary : Palette.surface))
                            .overlay(Capsule().stroke(Palette.hairline, lineWidth: 0.6))
                        }
                        .buttonStyle(.pressable)
                    }
                }
            }

            pitySummaryCard(pool: active)

            if active.limited.enabled && !active.limited.upCharacters.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("UP 角色出货")
                            .font(.system(size: 14, weight: .semibold))
                        Spacer()
                        Text("\(active.limited.upCount) 金 · 歪 \(active.limited.offCount)")
                            .font(.system(size: 12))
                            .monospacedDigit()
                            .foregroundStyle(Palette.textSecondary)
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(active.limited.upCharacters) { up in
                                HStack(spacing: 5) {
                                    Text(up.name)
                                    if up.count > 1 {
                                        Text("×\(up.count)")
                                            .fontWeight(.bold)
                                            .monospacedDigit()
                                            .foregroundStyle(Palette.warning)
                                    }
                                }
                                .font(.system(size: 12, weight: .medium))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Capsule().fill(Palette.fieldFill))
                            }
                        }
                    }
                }
                .padding(16)
                .cardSurface()
            }

            fiveStarListCard(pool: active)
        }
    }

    private func pitySummaryCard(pool: WuwaPoolHistory) -> some View {
        let ratio = min(1.0, Double(pool.currentPity) / 80.0)
        let color = pityColor(pool.currentPity)
        return HStack(spacing: 16) {
            ZStack {
                Circle()
                    .stroke(Palette.fieldFill, lineWidth: 8)
                Circle()
                    .trim(from: 0, to: max(0.01, ratio))
                    .stroke(color, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 1) {
                    Text("\(pool.currentPity)")
                        .font(RelayFont.display(24))
                        .monospacedDigit()
                    Text("/ 80 抽")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Palette.textSecondary)
                }
            }
            .frame(width: 92, height: 92)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 10) {
                statCell("累计抽数", "\(pool.total)")
                if pool.limited.enabled {
                    statCell("UP 均抽", pool.limited.averagePullsPerUp.map { String(format: "%.1f", $0) } ?? "—")
                    statCell("不歪率", pool.limited.smallPityWinRate.map { String(format: "%.1f%%", $0 * 100) } ?? "—")
                    statCell("当前保底", pool.guaranteed == true ? "大保底" : "小保底")
                } else {
                    statCell("五星总数", "\(pool.fiveStars.count)")
                    statCell("平均出金", pool.averagePity.map { String(format: "%.1f", $0) } ?? "—")
                    statCell("四星总数", "\(pool.fourStars)")
                }
            }
        }
        .padding(16)
        .cardSurface()
    }

    private func statCell(_ title: String, _ val: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(Palette.textSecondary)
            Text(val)
                .font(.system(size: 14.5, weight: .semibold))
                .monospacedDigit()
        }
    }

    private func fiveStarListCard(pool: WuwaPoolHistory) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("五星出货记录")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Text("\(pool.fiveStars.count) 次")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.textSecondary)
            }

            if pool.fiveStars.isEmpty {
                Text("该卡池暂无五星记录。")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.textSecondary)
            } else {
                ForEach(Array(pool.fiveStars.enumerated()), id: \.element.id) { idx, entry in
                    if idx > 0 { Divider().overlay(Palette.hairline) }
                    let pColor = pityColor(entry.pulls)
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.record.name)
                                .font(.system(size: 13, weight: .semibold))
                            Text(String(entry.record.pulledAt.prefix(10)))
                                .font(.system(size: 10.5))
                                .monospacedDigit()
                                .foregroundStyle(Palette.textTertiary)
                        }
                        .frame(width: 82, alignment: .leading)

                        GeometryReader { geo in
                            let w = max(CGFloat(26), geo.size.width * CGFloat(min(1, Double(entry.pulls) / 80.0)))
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Palette.fieldFill)
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(pColor)
                                    .frame(width: w)
                                Text("\(entry.pulls)")
                                    .font(.system(size: 11, weight: .bold))
                                    .monospacedDigit()
                                    .foregroundStyle(.white)
                                    .padding(.leading, max(CGFloat(6), w - 22))
                            }
                        }
                        .frame(height: 18)

                        if let outcome = entry.outcome {
                            outcomeBadge(outcome)
                        }
                    }
                    .padding(.vertical, 3)
                }
            }
        }
        .padding(16)
        .cardSurface()
    }

    private func outcomeBadge(_ outcome: String) -> some View {
        let (label, color): (String, Color) = {
            switch outcome {
            case "up-win": return ("不歪", Palette.success)
            case "up-guaranteed": return ("保底", Palette.warning)
            default: return ("歪", Palette.danger)
            }
        }()
        return Text(label)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(Capsule().fill(color.opacity(0.14)))
    }

    private func pityColor(_ pulls: Int) -> Color {
        if pulls <= 35 { return Palette.success }
        if pulls <= 65 { return Palette.warning }
        return Palette.danger
    }

    // MARK: - Planner Section

    private var plannerSection: some View {
        @Bindable var bindable = wuwa
        return VStack(spacing: 14) {
            if let res = wuwa.plannerResult {
                plannerGaugeCard(res: res)
            }

            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("资源与目标配置")
                        .font(.system(size: 15, weight: .semibold))
                    Spacer()
                    if !wuwa.pools.isEmpty {
                        Button("同步当前水位") {
                            wuwa.syncPlannerFromCurrentPools()
                            Haptics.tap()
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color(hex: 0x2B93CF))
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("现有星声")
                        Spacer()
                        Text("\(bindable.plannerInput.astrite)（\(bindable.plannerInput.astrite / 160) 抽）")
                            .fontWeight(.semibold)
                            .monospacedDigit()
                    }
                    .font(.system(size: 13))
                    Slider(
                        value: Binding(
                            get: { Double(bindable.plannerInput.astrite) },
                            set: {
                                bindable.plannerInput.astrite = Int($0 / 160) * 160
                                Task { await wuwa.recomputeGachaPlan() }
                            }
                        ),
                        in: 0...64000,
                        step: 160
                    )
                }

                HStack(spacing: 12) {
                    stepperBox(title: "浮金波纹", value: $bindable.plannerInput.radiantTide, range: 0...300)
                    stepperBox(title: "铸潮波纹", value: $bindable.plannerInput.forgingTide, range: 0...200)
                }

                HStack(spacing: 12) {
                    stepperBox(title: "通用珊瑚抽", value: $bindable.plannerInput.coralPulls, range: 0...200)
                    stepperBox(title: "海市直兑链", value: $bindable.plannerInput.coralDirectChains, range: 0...2)
                }

                HStack(spacing: 12) {
                    stepperBox(title: "角色已垫", value: $bindable.plannerInput.charPity, range: 0...79)
                    stepperBox(title: "武器已垫", value: $bindable.plannerInput.weaponPity, range: 0...79)
                }

                Toggle("角色池当前是大保底", isOn: $bindable.plannerInput.charGuaranteed)
                    .font(.system(size: 13.5))
                    .onChange(of: wuwa.plannerInput.charGuaranteed) { _, _ in
                        Task { await wuwa.recomputeGachaPlan() }
                    }

                HStack(spacing: 12) {
                    stepperBox(title: "目标 UP 角色金", value: $bindable.plannerInput.targetCharCopies, range: 0...7)
                    stepperBox(title: "目标 UP 武器金", value: $bindable.plannerInput.targetWeaponCopies, range: 0...5)
                }
            }
            .padding(16)
            .cardSurface()
        }
    }

    private func plannerGaugeCard(res: WuwaGachaPlanResult) -> some View {
        let pct = Int((res.successProbability * 100).rounded())
        let gaugeColor: Color = pct >= 75 ? Palette.success : (pct >= 45 ? Palette.warning : Palette.danger)
        let chartPoints = stride(from: 0, to: res.cdf.count, by: max(1, res.cdf.count / 40)).map { idx in
            (pulls: idx, pct: res.cdf[idx] * 100)
        }

        return VStack(spacing: 12) {
            HStack(spacing: 16) {
                ZStack {
                    Circle().stroke(Palette.fieldFill, lineWidth: 9)
                    Circle()
                        .trim(from: 0, to: max(0.01, res.successProbability))
                        .stroke(gaugeColor, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    VStack(spacing: 1) {
                        Text("\(pct)%")
                            .font(RelayFont.display(22))
                            .monospacedDigit()
                        Text("达成概率")
                            .font(.system(size: 10))
                            .foregroundStyle(Palette.textSecondary)
                    }
                }
                .frame(width: 90, height: 90)

                VStack(alignment: .leading, spacing: 5) {
                    Text("有效可用 \(res.resources.effectiveUsablePulls) 抽 · 期望 \(Int(res.expectedPulls.rounded())) 抽")
                        .font(.system(size: 13.5, weight: .semibold))
                        .monospacedDigit()
                    Text("P50 中位 \(res.p50) 抽 · P80 稳健 \(res.p80) 抽 · P95 \(res.p95) 抽")
                        .font(.system(size: 12))
                        .monospacedDigit()
                        .foregroundStyle(Palette.textSecondary)
                    if res.milestones.p80.missingPulls > 0 {
                        Text("距 P80 稳健线差 \(res.milestones.p80.missingPulls) 抽（约 \(res.milestones.p80.missingAstrite) 星声）")
                            .font(.system(size: 12, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(Palette.warning)
                    } else {
                        Text("当前资源已跨过 P80 稳健线")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Palette.success)
                    }
                }
                Spacer(minLength: 0)
            }

            if !chartPoints.isEmpty {
                Chart {
                    ForEach(chartPoints, id: \.pulls) { pt in
                        AreaMark(
                            x: .value("抽数", pt.pulls),
                            y: .value("概率", pt.pct)
                        )
                        .foregroundStyle(
                            LinearGradient(
                                colors: [gaugeColor.opacity(0.28), gaugeColor.opacity(0.02)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        LineMark(
                            x: .value("抽数", pt.pulls),
                            y: .value("概率", pt.pct)
                        )
                        .foregroundStyle(gaugeColor)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                    }
                    RuleMark(x: .value("当前资源", min(res.maxPulls, res.resources.totalNominalPulls)))
                        .foregroundStyle(Palette.textPrimary.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                }
                .chartYScale(domain: 0...100)
                .frame(height: 110)
            }
        }
        .padding(16)
        .cardSurface()
    }

    private func stepperBox(title: String, value: Binding<Int>, range: ClosedRange<Int>) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.textSecondary)
                Text("\(value.wrappedValue)")
                    .font(.system(size: 14, weight: .semibold))
                    .monospacedDigit()
            }
            Spacer()
            Stepper("", value: value, in: range)
                .labelsHidden()
                .onChange(of: value.wrappedValue) { _, _ in
                    Task { await wuwa.recomputeGachaPlan() }
                }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.fieldFill))
    }
}
