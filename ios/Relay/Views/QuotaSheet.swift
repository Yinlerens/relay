import SwiftUI

/// Antigravity model limits (查看限额) + CodeBuddy credit consumption (积分消耗与查看积分).
struct QuotaSheet: View {
    var focusAgent: String? = nil

    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    private var focusFamily: AgentStyle.Family? {
        guard let focusAgent, !focusAgent.isEmpty else { return nil }
        return store.style(for: focusAgent).family
    }

    private var codebuddyFirst: Bool { focusFamily == .emerald }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    statusLine

                    if let quotas = store.quotas {
                        if codebuddyFirst {
                            codebuddyCard(quotas.codebuddy)
                            antigravityCard(quotas.antigravity)
                        } else {
                            antigravityCard(quotas.antigravity)
                            codebuddyCard(quotas.codebuddy)
                        }
                    } else if let error = store.quotaError {
                        errorState(error)
                    } else {
                        loadingState
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 6)
                .padding(.bottom, 32)
                .frame(maxWidth: 680)
                .frame(maxWidth: .infinity)
            }
            .scrollEdgeEffectStyle(.soft, for: .all)
            .refreshable {
                await store.loadQuotas(refresh: true)
            }
            .navigationTitle("限额与积分")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Haptics.tap()
                        Task { await store.loadQuotas(refresh: true) }
                    } label: {
                        if store.isLoadingQuotas {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .disabled(store.isLoadingQuotas)
                    .accessibilityLabel("刷新")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .task {
            await store.loadQuotas(refresh: false)
        }
    }

    // MARK: - Status

    private var statusLine: some View {
        HStack(spacing: 6) {
            if store.isLoadingQuotas {
                ProgressView()
                    .controlSize(.mini)
                Text("正在刷新…")
            } else if let quotas = store.quotas {
                Image(systemName: "clock")
                Text("更新于 \(quotas.updatedDate.formatted(date: .omitted, time: .standard))")
                    .monospacedDigit()
            } else {
                Image(systemName: "gauge.with.dots.needle.bottom.50percent")
                Text("读取中")
            }
            Spacer()
            if let error = store.quotaError, store.quotas != nil {
                Label("刷新失败", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Palette.warning)
                    .help(error)
            }
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(Palette.textTertiary)
        .animation(.easeInOut(duration: 0.2), value: store.isLoadingQuotas)
    }

    // MARK: - Styles

    private func style(for family: AgentStyle.Family) -> AgentStyle {
        if let agent = store.agents.first(where: { store.style(for: $0.id).family == family }) {
            return store.style(for: agent.id)
        }
        return AgentStyle(family: family, symbol: family == .indigo ? "sparkles" : "cpu")
    }

    private func name(for family: AgentStyle.Family, fallback: String) -> String {
        store.agents.first(where: { store.style(for: $0.id).family == family })?.name ?? fallback
    }

    // MARK: - Antigravity

    @ViewBuilder
    private func antigravityCard(_ quota: AntigravityQuota?) -> some View {
        let agStyle = style(for: .indigo)
        QuotaCard(
            style: agStyle,
            title: name(for: .indigo, fallback: "Antigravity"),
            subtitle: "模型限额",
            highlighted: focusFamily == .indigo,
            badge: nil
        ) {
            if let quota {
                if !quota.available {
                    QuotaNotice(message: quota.error ?? "暂时无法读取 Antigravity 限额")
                }

                ForEach(quota.groups) { group in
                    VStack(alignment: .leading, spacing: 14) {
                        Eyebrow(text: group.name)
                        ForEach(group.buckets) { bucket in
                            QuotaBucketRow(bucket: bucket)
                        }
                    }
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Palette.fieldFill)
                    )
                }

                if quota.available && quota.groups.isEmpty {
                    Text("Antigravity 暂未上报模型限额。")
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.textSecondary)
                }

                if let url = quota.upgradeURL {
                    QuotaLinkButton(title: "升级 Antigravity 方案", systemImage: "arrow.up.forward.app", tint: agStyle.tint, url: url)
                }
            } else {
                QuotaNotice(message: "服务端未返回 Antigravity 限额数据")
            }
        }
    }

    // MARK: - CodeBuddy

    @ViewBuilder
    private func codebuddyCard(_ usage: CodeBuddyUsage?) -> some View {
        let cbStyle = style(for: .emerald)
        QuotaCard(
            style: cbStyle,
            title: name(for: .emerald, fallback: "CodeBuddy"),
            subtitle: "积分消耗",
            highlighted: focusFamily == .emerald,
            badge: (usage?.totalSavedCredits ?? 0) > 0 ? "已省 \(RelayFormat.credits(usage?.totalSavedCredits ?? 0))" : nil
        ) {
            if let usage {
                if !usage.available {
                    QuotaNotice(message: usage.error ?? "暂时无法读取 CodeBuddy 消耗记录")
                }

                HStack(spacing: 10) {
                    CreditMetricTile(title: "今日消耗", value: usage.todayCredits, tint: cbStyle.tint, emphasized: true)
                    CreditMetricTile(title: "本月消耗", value: usage.monthCredits, tint: cbStyle.tint)
                    CreditMetricTile(title: "累计消耗", value: usage.totalCredits, tint: cbStyle.tint)
                }

                if !usage.byModel.isEmpty {
                    let maxCredits = usage.byModel.map(\.credits).max() ?? 0
                    VStack(alignment: .leading, spacing: 10) {
                        Eyebrow(text: "按模型消耗")
                        VStack(spacing: 0) {
                            ForEach(usage.byModel) { model in
                                if model.id != usage.byModel.first?.id {
                                    Divider().overlay(Palette.hairline)
                                }
                                ModelCreditRow(model: model, maxCredits: maxCredits, tint: cbStyle.tint)
                                    .padding(.vertical, 11)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(Palette.fieldFill)
                        )
                    }
                }

                if !usage.rateQuotas.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Eyebrow(text: "限频状态")
                        VStack(spacing: 14) {
                            ForEach(usage.rateQuotas) { quota in
                                RateQuotaRow(quota: quota)
                            }
                        }
                        .padding(14)
                        .background(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(Palette.fieldFill)
                        )
                    }
                }
            } else {
                QuotaNotice(message: "服务端未返回 CodeBuddy 积分数据")
            }
        }
    }

    // MARK: - Empty / error

    private var loadingState: some View {
        VStack(spacing: 16) {
            ForEach([CGFloat(230), CGFloat(260)], id: \.self) { height in
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(Palette.fieldFill)
                    .frame(height: height)
                    .shimmer(true)
            }
        }
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "icloud.slash")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Palette.textTertiary)
            Text("暂时无法读取限额")
                .font(RelayFont.display(19))
                .foregroundStyle(Palette.textPrimary)
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(Palette.textSecondary)
                .multilineTextAlignment(.center)
            Button {
                Haptics.tap()
                Task { await store.loadQuotas(refresh: true) }
            } label: {
                Text("重试")
                    .font(.system(size: 15, weight: .semibold))
                    .padding(.horizontal, 22)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.capsule)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 50)
    }
}

// MARK: - Card shell with per-agent signature glow

struct QuotaCard<Content: View>: View {
    var style: AgentStyle
    var title: String
    var subtitle: String
    var highlighted: Bool
    var badge: String?
    @ViewBuilder var content: Content

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 26, style: .continuous)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                AgentGlyph(style: style, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(RelayFont.display(20))
                        .foregroundStyle(Palette.textPrimary)
                    Text(subtitle)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Palette.textSecondary)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 5) {
                    if highlighted {
                        capsule("当前会话", color: style.tint)
                    }
                    if let badge {
                        HStack(spacing: 4) {
                            Image(systemName: "leaf.fill")
                                .font(.system(size: 9, weight: .bold))
                            Text(badge)
                                .monospacedDigit()
                        }
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Palette.success)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Palette.success.opacity(0.13)))
                        .overlay(Capsule().stroke(Palette.success.opacity(0.25), lineWidth: 0.5))
                    }
                }
            }

            content
        }
        .padding(18)
        .background {
            ZStack {
                shape.fill(Palette.surface)
                RadialGradient(
                    colors: [style.glow.opacity(0.22), .clear],
                    center: .topLeading,
                    startRadius: 4,
                    endRadius: 300
                )
                .clipShape(shape)
            }
        }
        .overlay(
            shape.stroke(
                highlighted ? style.tint.opacity(0.55) : Palette.hairline,
                lineWidth: highlighted ? 1.1 : 0.6
            )
        )
        .shadow(color: style.glow.opacity(highlighted ? 0.2 : 0.07), radius: 22, y: 10)
    }

    private func capsule(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .bold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.13)))
    }
}

// MARK: - Building blocks

enum QuotaPalette {
    private struct RGB {
        let r: Double
        let g: Double
        let b: Double
    }

    private static let coral = RGB(r: 0.95, g: 0.40, b: 0.37)
    private static let amber = RGB(r: 0.94, g: 0.66, b: 0.23)
    private static let emerald = RGB(r: 0.17, g: 0.74, b: 0.55)

    /// Smoothly blends coral → amber → emerald as the remaining fraction rises.
    static func color(forRemaining fraction: Double) -> Color {
        let x = min(1, max(0, fraction))
        let from: RGB
        let to: RGB
        let t: Double
        if x < 0.35 {
            from = coral
            to = amber
            t = x / 0.35
        } else {
            from = amber
            to = emerald
            t = min(1, (x - 0.35) / 0.35)
        }
        return Color(
            red: from.r + (to.r - from.r) * t,
            green: from.g + (to.g - from.g) * t,
            blue: from.b + (to.b - from.b) * t
        )
    }

    static func color(forUsed fraction: Double) -> Color {
        color(forRemaining: 1 - fraction)
    }
}

/// Tactile capsule progress bar with a specular highlight.
struct QuotaBar: View {
    var fraction: Double
    var color: Color
    var height: CGFloat = 8

    var body: some View {
        GeometryReader { geo in
            let clamped = min(1, max(0, fraction))
            let width = clamped <= 0 ? 0 : max(height, geo.size.width * clamped)
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(Palette.hairline)
                Capsule(style: .continuous)
                    .fill(LinearGradient(colors: [color.opacity(0.72), color], startPoint: .leading, endPoint: .trailing))
                    .frame(width: width)
                    .overlay(alignment: .top) {
                        Capsule(style: .continuous)
                            .fill(Color.white.opacity(0.3))
                            .frame(height: max(1, height * 0.36))
                            .padding(.horizontal, height * 0.3)
                            .padding(.top, 1)
                    }
                    .shadow(color: color.opacity(0.4), radius: 4, y: 1)
            }
        }
        .frame(height: height)
        .animation(.spring(response: 0.7, dampingFraction: 0.85), value: fraction)
        .accessibilityValue("\(Int((min(1, max(0, fraction)) * 100).rounded()))%")
    }
}

struct QuotaBucketRow: View {
    let bucket: QuotaBucket

    var body: some View {
        let fraction = bucket.fraction
        let color = QuotaPalette.color(forRemaining: fraction ?? 1)

        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(bucket.name)
                    .font(.system(size: 14.5, weight: .medium))
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)
                if let window = bucket.windowLabel {
                    Text(window)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Palette.textSecondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Palette.hairline))
                }
                Spacer(minLength: 8)
                Text(fraction.map { "\(Int(($0 * 100).rounded()))%" } ?? "—")
                    .font(RelayFont.rounded(17, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(color)
                    .contentTransition(.numericText(value: fraction ?? 0))
            }

            QuotaBar(fraction: fraction ?? 0, color: color)

            HStack(spacing: 6) {
                if let reset = bucket.resetDate {
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        Label(QuotaDates.resetCountdown(to: reset, now: context.date), systemImage: "clock.arrow.circlepath")
                    }
                }
                Spacer(minLength: 0)
                if fraction != nil {
                    Text("剩余")
                }
            }
            .font(.system(size: 11.5))
            .foregroundStyle(Palette.textTertiary)
        }
    }
}

struct CreditMetricTile: View {
    var title: String
    var value: Double
    var tint: Color
    var emphasized: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Palette.textSecondary)
            Text(RelayFormat.credits(value))
                .font(RelayFont.rounded(22, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(emphasized ? tint : Palette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .contentTransition(.numericText(value: value))
            Text("积分")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Palette.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(emphasized ? tint.opacity(0.10) : Palette.fieldFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(emphasized ? tint.opacity(0.25) : Color.clear, lineWidth: 0.6)
        )
    }
}

struct ModelCreditRow: View {
    let model: CodeBuddyModelUsage
    let maxCredits: Double
    let tint: Color

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(model.modelId)
                    .font(RelayFont.mono(13.5, weight: .medium))
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(model.calls) 次调用 · \(RelayFormat.tokens(model.totalTokens)) tokens")
                    .font(.system(size: 11.5))
                    .monospacedDigit()
                    .foregroundStyle(Palette.textTertiary)
                QuotaBar(fraction: maxCredits > 0 ? model.credits / maxCredits : 0, color: tint, height: 4)
            }
            Spacer(minLength: 10)
            VStack(alignment: .trailing, spacing: 3) {
                Text(RelayFormat.credits(model.credits))
                    .font(RelayFont.rounded(16, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Palette.textPrimary)
                if model.savedCredits > 0 {
                    Text("省 \(RelayFormat.credits(model.savedCredits))")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Palette.success)
                } else {
                    Text("积分")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Palette.textTertiary)
                }
            }
        }
    }
}

struct RateQuotaRow: View {
    let quota: CodeBuddyRateQuota

    var body: some View {
        let color = QuotaPalette.color(forUsed: quota.usedFraction)
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(quota.model)
                    .font(RelayFont.mono(13, weight: .medium))
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Text("已用 \(quota.usedPercent)%")
                    .font(.system(size: 12.5, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(color)
            }
            QuotaBar(fraction: quota.usedFraction, color: color, height: 6)
            if let reset = quota.resetDate {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Label(QuotaDates.resetCountdown(to: reset, now: context.date), systemImage: "clock.arrow.circlepath")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.textTertiary)
                }
            }
        }
    }
}

struct QuotaNotice: View {
    var message: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Palette.warning)
            Text(message)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .font(.system(size: 12.5, weight: .medium))
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Palette.warning.opacity(0.1))
        )
    }
}

struct QuotaLinkButton: View {
    var title: String
    var systemImage: String
    var tint: Color
    var url: URL

    var body: some View {
        Link(destination: url) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                Text(title)
                Spacer(minLength: 6)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 11, weight: .bold))
            }
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 16)
            .frame(height: 46)
            .background(Capsule(style: .continuous).fill(tint.opacity(0.11)))
            .overlay(Capsule(style: .continuous).stroke(tint.opacity(0.24), lineWidth: 0.6))
        }
        .buttonStyle(.pressable)
    }
}
