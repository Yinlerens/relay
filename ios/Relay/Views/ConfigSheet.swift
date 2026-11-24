import SwiftUI

struct ConfigSheet: View {
    let sessionId: String

    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                if let session = store.session(sessionId) {
                    let style = store.style(for: session.agentId)
                    VStack(alignment: .leading, spacing: 26) {
                        header(session: session, style: style)

                        if !session.availableModels.isEmpty {
                            section("模型") {
                                let pending = store.pendingConfigKeys.contains(store.configKey(sessionId, .model, nil))
                                ForEach(Array(session.availableModels.enumerated()), id: \.element.id) { index, model in
                                    if index > 0 { rowDivider }
                                    let selected = model.modelId == session.currentModelId
                                    let badge = model.description.flatMap { $0.count <= 26 ? $0 : nil }
                                    let subtitle = model.description.flatMap { $0.count > 26 ? $0 : nil }
                                    SelectionRow(
                                        title: model.name,
                                        subtitle: subtitle,
                                        badge: badge,
                                        isSelected: selected,
                                        isPending: pending && selected,
                                        tint: style.tint
                                    ) {
                                        guard !selected else { return }
                                        Task {
                                            await store.setConfig(sessionId: sessionId, kind: .model, value: .string(model.modelId))
                                        }
                                    }
                                }
                            }
                        }

                        if !session.availableModes.isEmpty {
                            section("模式") {
                                let pending = store.pendingConfigKeys.contains(store.configKey(sessionId, .mode, nil))
                                ForEach(Array(session.availableModes.enumerated()), id: \.element.id) { index, mode in
                                    if index > 0 { rowDivider }
                                    let selected = mode.id == session.currentModeId
                                    SelectionRow(
                                        title: mode.name,
                                        subtitle: mode.description,
                                        badge: nil,
                                        isSelected: selected,
                                        isPending: pending && selected,
                                        tint: style.tint
                                    ) {
                                        guard !selected else { return }
                                        Task {
                                            await store.setConfig(sessionId: sessionId, kind: .mode, value: .string(mode.id))
                                        }
                                    }
                                }
                            }
                        }

                        ForEach(visibleOptions(session)) { option in
                            ConfigOptionCard(sessionId: sessionId, option: option, style: style)
                        }

                        if session.availableModels.isEmpty && session.availableModes.isEmpty && visibleOptions(session).isEmpty {
                            VStack(spacing: 10) {
                                Image(systemName: "slider.horizontal.below.square.filled.and.square")
                                    .font(.system(size: 28, weight: .light))
                                    .foregroundStyle(Palette.textTertiary)
                                Text("该 Agent 暂未提供可切换的模型或配置")
                                    .font(.system(size: 14))
                                    .foregroundStyle(Palette.textSecondary)
                                Text("发送第一条消息后，Agent 通常会上报可用选项。")
                                    .font(.system(size: 12.5))
                                    .foregroundStyle(Palette.textTertiary)
                            }
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 30)
                        }
                    }
                    .padding(20)
                } else {
                    Text("会话不存在")
                        .foregroundStyle(Palette.textSecondary)
                        .padding(.top, 60)
                        .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("会话配置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationContentInteraction(.scrolls)
        .relaySheetBackground()
    }

    /// Hide `model` / `mode` config options when dedicated model/mode lists already cover them.
    private func visibleOptions(_ session: SessionSummary) -> [ConfigOption] {
        session.configOptions.filter { option in
            if option.id == "model" && !session.availableModels.isEmpty { return false }
            if option.id == "mode" && !session.availableModes.isEmpty { return false }
            return option.isBoolean || !option.choices.isEmpty
        }
    }

    private var rowDivider: some View {
        Divider()
            .overlay(Palette.hairline)
            .padding(.leading, 16)
    }

    private func header(session: SessionSummary, style: AgentStyle) -> some View {
        let agent = store.agent(for: session.agentId)
        return HStack(spacing: 14) {
            AgentGlyph(style: style, size: 48, isRunning: session.isRunning)
            VStack(alignment: .leading, spacing: 4) {
                Text(session.title)
                    .font(RelayFont.display(19))
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text(agent?.name ?? session.agentId)
                        .fontWeight(.semibold)
                        .foregroundStyle(style.tint)
                    if !session.cwd.isEmpty {
                        Text(session.cwd)
                            .font(RelayFont.mono(11.5))
                            .foregroundStyle(Palette.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .font(.system(size: 12.5))
            }
            Spacer(minLength: 0)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow(text: title)
                .padding(.leading, 4)
            VStack(spacing: 0) {
                content()
            }
            .cardSurface(radius: 20)
        }
    }
}

// MARK: - Config option card (segmented / list / toggle)

struct ConfigOptionCard: View {
    let sessionId: String
    let option: ConfigOption
    let style: AgentStyle

    @Environment(AppStore.self) private var store

    private var isPending: Bool {
        store.pendingConfigKeys.contains(store.configKey(sessionId, .config, option.id))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !option.isBoolean {
                HStack(spacing: 6) {
                    Eyebrow(text: option.name)
                    if isPending {
                        ProgressView().controlSize(.mini)
                    }
                }
                .padding(.leading, 4)
            }

            if option.isBoolean {
                toggleCard
            } else if (2...4).contains(option.choices.count) {
                segmentedCard
            } else {
                listCard
            }
        }
    }

    private var toggleCard: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(option.name)
                    .font(.system(size: 15.5, weight: .medium))
                    .foregroundStyle(Palette.textPrimary)
                if let description = option.description, !description.isEmpty {
                    Text(description)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(3)
                }
            }
            Spacer(minLength: 8)
            if isPending {
                ProgressView().controlSize(.small)
            }
            Toggle(
                option.name,
                isOn: Binding(
                    get: { option.currentValue.boolValue },
                    set: { newValue in
                        Task {
                            await store.setConfig(sessionId: sessionId, kind: .config, configId: option.id, value: .bool(newValue))
                        }
                    }
                )
            )
            .labelsHidden()
            .tint(style.tint)
            .disabled(isPending)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .cardSurface(radius: 20)
    }

    private var segmentedCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker(
                option.name,
                selection: Binding(
                    get: { option.currentValue.stringValue },
                    set: { newValue in
                        guard newValue != option.currentValue.stringValue else { return }
                        Task {
                            await store.setConfig(sessionId: sessionId, kind: .config, configId: option.id, value: .string(newValue))
                        }
                    }
                )
            ) {
                ForEach(option.choices) { choice in
                    Text(choice.name).tag(choice.value)
                }
            }
            .pickerStyle(.segmented)
            .disabled(isPending)

            if let detail = selectedChoiceDescription ?? option.description, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.textSecondary)
                    .padding(.horizontal, 4)
                    .contentTransition(.opacity)
            }
        }
        .padding(14)
        .cardSurface(radius: 20)
    }

    private var listCard: some View {
        VStack(spacing: 0) {
            ForEach(Array(option.choices.enumerated()), id: \.element.id) { index, choice in
                if index > 0 {
                    Divider().overlay(Palette.hairline).padding(.leading, 16)
                }
                let selected = choice.value == option.currentValue.stringValue
                SelectionRow(
                    title: choice.name,
                    subtitle: choice.description,
                    badge: nil,
                    isSelected: selected,
                    isPending: isPending && selected,
                    tint: style.tint
                ) {
                    guard !selected else { return }
                    Task {
                        await store.setConfig(sessionId: sessionId, kind: .config, configId: option.id, value: .string(choice.value))
                    }
                }
            }
        }
        .cardSurface(radius: 20)
    }

    private var selectedChoiceDescription: String? {
        option.choices.first(where: { $0.value == option.currentValue.stringValue })?.description
    }
}

// MARK: - Selection row

struct SelectionRow: View {
    var title: String
    var subtitle: String?
    var badge: String?
    var isSelected: Bool
    var isPending: Bool
    var tint: Color
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 15.5, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(Palette.textPrimary)
                        .lineLimit(1)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 12.5))
                            .foregroundStyle(Palette.textSecondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 8)
                if let badge, !badge.isEmpty {
                    Text(badge)
                        .font(RelayFont.mono(11, weight: .semibold))
                        .foregroundStyle(tint)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(tint.opacity(0.12)))
                        .overlay(Capsule().stroke(tint.opacity(0.22), lineWidth: 0.5))
                        .lineLimit(1)
                        .fixedSize()
                }
                ZStack {
                    if isPending {
                        ProgressView().controlSize(.small)
                    } else if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(tint)
                            .transition(.scale.combined(with: .opacity))
                    } else {
                        Image(systemName: "circle")
                            .foregroundStyle(Palette.textTertiary.opacity(0.6))
                    }
                }
                .font(.system(size: 20))
                .frame(width: 24, height: 24)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: isSelected)
    }
}
