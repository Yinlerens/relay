import SwiftUI

struct NewSwarmSheet: View {
    var onCreated: (CreateSwarmResponse) -> Void

    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var coordinatorAgentId: String?
    @State private var workerAgentId: String?
    @State private var workerModels: [ModelInfo] = []
    @State private var workerDefaultModelId: String?
    @State private var selectedWorkerModelId: String? = nil
    @State private var loadingModels = false
    @State private var expandAllModels = false
    @State private var workspaces: [String] = []
    @State private var selectedCwd = ""
    @State private var customCwd = ""
    @State private var creating = false

    private var effectiveCwd: String {
        let custom = customCwd.trimmingCharacters(in: .whitespacesAndNewlines)
        return custom.isEmpty ? selectedCwd : custom
    }

    private var workerStyle: AgentStyle {
        store.style(for: workerAgentId ?? "codebuddy")
    }

    private var visibleModels: [ModelInfo] {
        guard !expandAllModels, workerModels.count > 5 else { return workerModels }
        var top = Array(workerModels.prefix(5))
        if let sel = selectedWorkerModelId,
           !top.contains(where: { $0.modelId == sel }),
           let match = workerModels.first(where: { $0.modelId == sel }) {
            top.append(match)
        }
        return top
    }

    private var defaultModelHint: String? {
        guard let defId = workerDefaultModelId, !defId.isEmpty else {
            return "由工人 Agent 按自身配置决定"
        }
        let name = workerModels.first(where: { $0.modelId == defId })?.name ?? defId
        return "当前默认：\(name)"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    heroHeader

                    VStack(alignment: .leading, spacing: 10) {
                        Eyebrow(text: "蜂群主题（可选）")
                            .padding(.leading, 4)
                        HStack(spacing: 10) {
                            Image(systemName: "text.quote")
                                .foregroundStyle(SwarmTheme.style.tint)
                            TextField("例如：重构登录模块与测试", text: $title)
                                .font(.system(size: 15.5))
                        }
                        .padding(.horizontal, 16)
                        .frame(height: 50)
                        .cardSurface(radius: 16)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Eyebrow(text: "总控 Agent · 负责规划与调度")
                            .padding(.leading, 4)
                        VStack(spacing: 10) {
                            ForEach(store.agents) { agent in
                                agentCard(agent, selected: coordinatorAgentId == agent.id) {
                                    withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) {
                                        coordinatorAgentId = agent.id
                                    }
                                    Haptics.selection()
                                }
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Eyebrow(text: "协作工人 Agent · 默认执行者")
                            .padding(.leading, 4)
                        VStack(spacing: 10) {
                            ForEach(store.agents) { agent in
                                agentCard(agent, selected: workerAgentId == agent.id) {
                                    withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) {
                                        workerAgentId = agent.id
                                        selectedWorkerModelId = nil
                                        expandAllModels = false
                                    }
                                    Haptics.selection()
                                }
                            }
                        }
                    }

                    workerModelSection

                    workspaceSection
                }
                .padding(20)
                .padding(.bottom, 96)
            }
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom) {
                launchButton
                    .padding(.horizontal, 20)
                    .padding(.bottom, 10)
            }
            .navigationTitle("新建蜂群协作")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .relaySheetBackground()
        .task {
            if coordinatorAgentId == nil {
                coordinatorAgentId = store.agents.first(where: { $0.id == "agy" })?.id ?? store.agents.first?.id
            }
            if workerAgentId == nil {
                workerAgentId = store.agents.first(where: { $0.id == "codebuddy" })?.id
                    ?? store.agents.first(where: { $0.id != coordinatorAgentId })?.id
                    ?? store.agents.first?.id
            }
            if selectedCwd.isEmpty { selectedCwd = store.defaultCwd }
            let list = await store.fetchWorkspaces()
            withAnimation(.easeOut(duration: 0.25)) {
                workspaces = list.isEmpty ? [store.defaultCwd].filter { !$0.isEmpty } : list
            }
        }
        .task(id: workerAgentId) {
            guard let agentId = workerAgentId else { return }
            loadingModels = true
            workerModels = []
            workerDefaultModelId = nil
            let res = await store.fetchAgentModels(agentId: agentId)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) {
                workerModels = res?.models ?? []
                workerDefaultModelId = res?.defaultModelId
                loadingModels = false
            }
        }
    }

    // MARK: Sections

    private var heroHeader: some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        return HStack(spacing: 14) {
            AgentGlyph(style: SwarmTheme.style, size: 46)
            VStack(alignment: .leading, spacing: 4) {
                Text("跨 Agent 蜂群协作")
                    .font(RelayFont.display(19))
                    .foregroundStyle(Palette.textPrimary)
                Text("总控负责拆解任务并调度工人，共享留言板与独立 Worktree 并行推进。")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background {
            ZStack {
                shape.fill(Palette.surface)
                RadialGradient(
                    colors: [SwarmTheme.style.glow.opacity(0.20), .clear],
                    center: .topLeading,
                    startRadius: 4,
                    endRadius: 240
                )
                .clipShape(shape)
            }
        }
        .overlay(shape.stroke(SwarmTheme.style.tint.opacity(0.28), lineWidth: 0.7))
    }

    private var workerModelSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Eyebrow(text: "默认工人模型")
                if loadingModels {
                    ProgressView().controlSize(.mini)
                }
            }
            .padding(.leading, 4)

            VStack(spacing: 0) {
                SelectionRow(
                    title: "跟随默认",
                    subtitle: defaultModelHint,
                    badge: nil,
                    isSelected: selectedWorkerModelId == nil,
                    isPending: false,
                    tint: workerStyle.tint
                ) {
                    selectedWorkerModelId = nil
                    Haptics.selection()
                }

                ForEach(visibleModels) { model in
                    Divider().overlay(Palette.hairline).padding(.leading, 16)
                    let selected = selectedWorkerModelId == model.modelId
                    let badge = model.description.flatMap { $0.count <= 26 ? $0 : nil }
                    let subtitle = model.description.flatMap { $0.count > 26 ? $0 : nil }
                    SelectionRow(
                        title: model.name,
                        subtitle: subtitle,
                        badge: badge,
                        isSelected: selected,
                        isPending: false,
                        tint: workerStyle.tint
                    ) {
                        selectedWorkerModelId = model.modelId
                        Haptics.selection()
                    }
                }

                if workerModels.count > 5 {
                    Divider().overlay(Palette.hairline).padding(.leading, 16)
                    Button {
                        withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                            expandAllModels.toggle()
                        }
                        Haptics.selection()
                    } label: {
                        HStack(spacing: 6) {
                            Text(expandAllModels ? "收起模型列表" : "展开全部 \(workerModels.count) 个模型")
                            Image(systemName: expandAllModels ? "chevron.up" : "chevron.down")
                                .font(.system(size: 11, weight: .bold))
                        }
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(workerStyle.tint)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                if loadingModels && workerModels.isEmpty {
                    Divider().overlay(Palette.hairline).padding(.leading, 16)
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("正在读取可用模型…")
                            .font(.system(size: 13))
                            .foregroundStyle(Palette.textSecondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                }
            }
            .cardSurface(radius: 20)
        }
    }

    private var workspaceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow(text: "工作区")
                .padding(.leading, 4)

            VStack(spacing: 0) {
                ForEach(Array(workspaces.enumerated()), id: \.element) { index, path in
                    if index > 0 {
                        Divider().overlay(Palette.hairline).padding(.leading, 16)
                    }
                    SelectionRow(
                        title: (path as NSString).lastPathComponent,
                        subtitle: path,
                        badge: path == store.defaultCwd ? "默认" : nil,
                        isSelected: customCwd.isEmpty && selectedCwd == path,
                        isPending: false,
                        tint: SwarmTheme.style.tint
                    ) {
                        selectedCwd = path
                        customCwd = ""
                        Haptics.selection()
                    }
                }
                if workspaces.isEmpty {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("正在读取工作区…")
                            .font(.system(size: 13.5))
                            .foregroundStyle(Palette.textSecondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                }
            }
            .cardSurface(radius: 20)

            HStack(spacing: 10) {
                Image(systemName: "folder.badge.plus")
                    .foregroundStyle(Palette.textTertiary)
                TextField("自定义路径（可选）", text: $customCwd)
                    .font(RelayFont.mono(14))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            .padding(.horizontal, 16)
            .frame(height: 50)
            .cardSurface(radius: 16)
        }
    }

    private func agentCard(_ agent: AgentInfo, selected: Bool, action: @escaping () -> Void) -> some View {
        let agentStyle = store.style(for: agent.id)
        return Button(action: action) {
            HStack(spacing: 14) {
                AgentGlyph(style: agentStyle, size: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text(agent.name)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Palette.textPrimary)
                    if !agent.subtitle.isEmpty {
                        Text(agent.subtitle)
                            .font(.system(size: 12.5))
                            .foregroundStyle(Palette.textSecondary)
                    }
                }
                Spacer()
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 21))
                    .foregroundStyle(selected ? agentStyle.tint : Palette.textTertiary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(selected ? agentStyle.wash : Palette.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(selected ? agentStyle.tint.opacity(0.55) : Palette.hairline, lineWidth: selected ? 1.2 : 0.6)
            )
        }
        .buttonStyle(.pressable)
    }

    private var launchButton: some View {
        Button {
            guard let coordId = coordinatorAgentId, !creating else { return }
            creating = true
            let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            Task {
                let created = await store.createSwarm(
                    title: cleanTitle.isEmpty ? nil : cleanTitle,
                    cwd: effectiveCwd.isEmpty ? nil : effectiveCwd,
                    coordinatorAgentId: coordId,
                    coordinatorModelId: nil,
                    defaultWorkerAgentId: workerAgentId,
                    defaultWorkerModelId: selectedWorkerModelId
                )
                creating = false
                if let created {
                    dismiss()
                    onCreated(created)
                }
            }
        } label: {
            HStack(spacing: 8) {
                if creating {
                    ProgressView().tint(.white)
                    Text("正在启动蜂群…")
                } else {
                    Image(systemName: SwarmTheme.style.symbol)
                    Text("启动蜂群")
                }
            }
            .font(.system(size: 16.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .background(Capsule(style: .continuous).fill(SwarmTheme.launchGradient))
            .overlay(Capsule(style: .continuous).stroke(Color.white.opacity(0.24), lineWidth: 0.6))
            .shadow(color: SwarmTheme.style.glow.opacity(0.4), radius: 16, y: 6)
        }
        .buttonStyle(.pressable)
        .disabled(coordinatorAgentId == nil || creating)
    }
}
