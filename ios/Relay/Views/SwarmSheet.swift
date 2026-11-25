import SwiftUI

struct SwarmSheet: View {
    let swarmId: String
    let currentSessionId: String

    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    private enum SheetTab: String, CaseIterable, Identifiable {
        case members
        case board
        var id: String { rawValue }
    }

    @State private var tab: SheetTab = .members
    @State private var killTarget: SwarmMember? = nil

    // Add worker panel
    @State private var showAddWorker = false
    @State private var workerName = ""
    @State private var workerBrief = ""
    @State private var workerAgentId: String = ""
    @State private var workerModelId: String? = nil
    @State private var workerWorkspace: String = "inherit"
    @State private var workerModels: [ModelInfo] = []
    @State private var loadingWorkerModels = false
    @State private var addingWorker = false

    // Board composer
    @State private var boardDraft = ""
    @State private var postingBoard = false

    private var swarm: SwarmSummary? { store.swarm(id: swarmId) }
    private var boardMessages: [SwarmBoardMessage] { store.boardMessages(for: swarmId) }
    private var isLoading: Bool { store.loadingSwarms.contains(swarmId) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("视图", selection: $tab) {
                    Text("成员").tag(SheetTab.members)
                    Text((swarm?.headSeq ?? 0) > 0 ? "留言板 · \(swarm?.headSeq ?? 0)" : "留言板").tag(SheetTab.board)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 10)
                .onChange(of: tab) { _, _ in Haptics.selection() }

                if let swarm {
                    Group {
                        switch tab {
                        case .members:
                            membersTab(swarm)
                        case .board:
                            boardTab(swarm)
                        }
                    }
                } else if isLoading {
                    Spacer()
                    ProgressView()
                    Spacer()
                } else {
                    Spacer()
                    Text("蜂群不存在或已删除")
                        .font(.system(size: 14.5))
                        .foregroundStyle(Palette.textSecondary)
                    Spacer()
                }
            }
            .navigationTitle(swarm?.title ?? "蜂群总览")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Haptics.tap()
                        Task { await store.loadSwarm(swarmId) }
                    } label: {
                        if isLoading {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .disabled(isLoading)
                    .accessibilityLabel("刷新蜂群")
                }
            }
            .confirmationDialog(
                "终止工人 @\(killTarget?.name ?? "")？",
                isPresented: Binding(
                    get: { killTarget != nil },
                    set: { if !$0 { killTarget = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("终止工人", role: .destructive) {
                    if let target = killTarget {
                        killTarget = nil
                        Task {
                            await store.killSwarmWorker(
                                swarmId: swarmId,
                                name: target.name,
                                removeWorktree: target.usesWorktree
                            )
                        }
                    }
                }
                Button("取消", role: .cancel) { killTarget = nil }
            } message: {
                if killTarget?.usesWorktree == true {
                    Text("将停止该工人的进程并清理其临时 Git Worktree。已合并或已提交到分支的成果不受影响。")
                } else {
                    Text("将停止该工人的进程并标记为已终止。")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .task(id: swarmId) {
            await store.loadSwarm(swarmId)
            if workerAgentId.isEmpty, let sw = store.swarm(id: swarmId) {
                workerAgentId = sw.defaultWorkerAgentId
                workerModelId = sw.defaultWorkerModelId
            }
        }
        .task(id: workerAgentId) {
            guard !workerAgentId.isEmpty, showAddWorker else { return }
            await reloadWorkerModels(for: workerAgentId)
        }
    }

    // MARK: - Tab 1: Members

    private func membersTab(_ swarm: SwarmSummary) -> some View {
        let sortedMembers = orderedMembers(swarm.members)
        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                overviewCard(swarm)

                VStack(alignment: .leading, spacing: 10) {
                    Eyebrow(text: "全员状态 · \(swarm.members.count)")
                        .padding(.leading, 4)

                    VStack(spacing: 10) {
                        ForEach(sortedMembers) { member in
                            memberCard(member, swarm: swarm)
                        }
                    }
                }

                addWorkerCard(swarm)
            }
            .padding(.horizontal, 20)
            .padding(.top, 6)
            .padding(.bottom, 32)
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .refreshable {
            await store.loadSwarm(swarmId)
        }
    }

    private func orderedMembers(_ members: [SwarmMember]) -> [SwarmMember] {
        members.sorted { a, b in
            if a.isCoordinator != b.isCoordinator { return a.isCoordinator }
            if a.isKilled != b.isKilled { return !a.isKilled }
            return a.createdAt < b.createdAt
        }
    }

    private func overviewCard(_ swarm: SwarmSummary) -> some View {
        let shape = RoundedRectangle(cornerRadius: 26, style: .continuous)
        return VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                AgentGlyph(style: SwarmTheme.style, size: 42, isRunning: swarm.isAnyRunning)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text(swarm.title)
                            .font(RelayFont.display(19))
                            .foregroundStyle(Palette.textPrimary)
                            .lineLimit(1)
                        Text(swarm.statusLabel)
                            .font(.system(size: 10.5, weight: .bold))
                            .foregroundStyle(SwarmTheme.style.tint)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(SwarmTheme.style.wash))
                    }
                    if !swarm.cwd.isEmpty {
                        Text(RelayFormat.shortPath(swarm.cwd))
                            .font(RelayFont.mono(11.5))
                            .foregroundStyle(Palette.textSecondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
            }

            HStack(spacing: 10) {
                metricTile(
                    title: "活跃成员",
                    value: "\(swarm.liveMemberCount)",
                    footnote: swarm.runningCount > 0 ? "\(swarm.runningCount) 运行中" : "全部待命",
                    emphasized: swarm.isAnyRunning
                )
                metricTile(
                    title: "留言板",
                    value: "#\(swarm.headSeq)",
                    footnote: "\(boardMessages.count) 条记录",
                    emphasized: false
                )
                metricTile(
                    title: "累计积分",
                    value: RelayFormat.credits(swarm.totalCredits),
                    footnote: "蜂群合计",
                    emphasized: false
                )
            }
        }
        .padding(18)
        .background {
            ZStack {
                shape.fill(Palette.surface)
                RadialGradient(
                    colors: [SwarmTheme.style.glow.opacity(0.22), .clear],
                    center: .topLeading,
                    startRadius: 4,
                    endRadius: 300
                )
                .clipShape(shape)
            }
        }
        .overlay(shape.stroke(SwarmTheme.style.tint.opacity(0.32), lineWidth: 0.7))
        .shadow(color: SwarmTheme.style.glow.opacity(0.12), radius: 20, y: 8)
    }

    private func metricTile(title: String, value: String, footnote: String, emphasized: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Palette.textSecondary)
            Text(value)
                .font(RelayFont.rounded(20, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(emphasized ? SwarmTheme.style.tint : Palette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .contentTransition(.numericText())
            Text(footnote)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Palette.textTertiary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(emphasized ? SwarmTheme.style.wash : Palette.fieldFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(emphasized ? SwarmTheme.style.tint.opacity(0.3) : Color.clear, lineWidth: 0.6)
        )
    }

    private func memberCard(_ member: SwarmMember, swarm: SwarmSummary) -> some View {
        let memberStyle = store.style(for: member.agentId)
        let agentName = store.agent(for: member.agentId)?.name ?? member.agentId
        let stateColor = SwarmTheme.stateColor(for: member, agentStyle: memberStyle)
        let isCurrent = member.sessionId == currentSessionId

        return VStack(alignment: .leading, spacing: 10) {
            Button {
                navigateToSession(member.sessionId)
            } label: {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        AgentGlyph(style: memberStyle, size: 38, isRunning: member.isWorking)

                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text("@\(member.name)")
                                    .font(RelayFont.mono(14.5, weight: .semibold))
                                    .foregroundStyle(member.isKilled ? Palette.textTertiary : Palette.textPrimary)
                                    .strikethrough(member.isKilled)
                                Text(member.isCoordinator ? "总控" : "工人")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(member.isCoordinator ? SwarmTheme.style.tint : memberStyle.tint)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill((member.isCoordinator ? SwarmTheme.style : memberStyle).wash))
                                if isCurrent {
                                    Text("当前")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(Palette.textSecondary)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Capsule().fill(Palette.fieldFill))
                                }
                            }

                            HStack(spacing: 5) {
                                Text(agentName)
                                    .foregroundStyle(memberStyle.tint)
                                    .fontWeight(.medium)
                                if let modelId = member.modelId, !modelId.isEmpty {
                                    Text("·").foregroundStyle(Palette.textTertiary)
                                    Text(modelId)
                                        .foregroundStyle(Palette.textSecondary)
                                        .lineLimit(1)
                                }
                            }
                            .font(.system(size: 12))
                        }

                        Spacer(minLength: 4)

                        HStack(spacing: 4) {
                            if member.isWorking {
                                PulseDot(color: stateColor, size: 5)
                            } else {
                                Circle().fill(stateColor).frame(width: 6, height: 6)
                            }
                            Text(member.stateLabel)
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(stateColor)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(stateColor.opacity(0.12)))
                    }

                    if let branch = member.worktreeBranch, !branch.isEmpty {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.triangle.branch")
                                .font(.system(size: 10, weight: .semibold))
                            Text(branch)
                                .font(RelayFont.mono(11))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .foregroundStyle(Palette.textSecondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Palette.fieldFill))
                    }

                    if !member.brief.isEmpty {
                        Text(member.brief)
                            .font(.system(size: 13))
                            .foregroundStyle(Palette.textSecondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)

            HStack(spacing: 10) {
                if member.totalCredits > 0 {
                    Text("\(RelayFormat.credits(member.totalCredits)) 积分")
                        .font(.system(size: 11.5, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Palette.textSecondary)
                }
                if member.lastPostSeq > 0 {
                    Text("最近发帖 #\(member.lastPostSeq)")
                        .font(RelayFont.mono(11))
                        .foregroundStyle(Palette.textTertiary)
                }
                Spacer(minLength: 4)
                if member.isWorker && !member.isKilled {
                    Button(role: .destructive) {
                        Haptics.tap()
                        killTarget = member
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "stop.circle")
                            Text("终止")
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Palette.danger)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Palette.danger.opacity(0.11)))
                    }
                    .buttonStyle(.pressable)
                }
                Button {
                    navigateToSession(member.sessionId)
                } label: {
                    HStack(spacing: 3) {
                        Text(isCurrent ? "返回对话" : "围观对话")
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .bold))
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(memberStyle.tint)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(memberStyle.wash))
                }
                .buttonStyle(.pressable)
            }
        }
        .padding(14)
        .cardSurface(radius: 20)
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(isCurrent ? memberStyle.tint.opacity(0.42) : Color.clear, lineWidth: 1)
        )
        .opacity(member.isKilled ? 0.65 : 1)
    }

    private func addWorkerCard(_ swarm: SwarmSummary) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.spring(response: 0.36, dampingFraction: 0.86)) {
                    showAddWorker.toggle()
                }
                Haptics.selection()
                if showAddWorker {
                    if workerAgentId.isEmpty {
                        workerAgentId = swarm.defaultWorkerAgentId
                        workerModelId = swarm.defaultWorkerModelId
                    }
                    Task { await reloadWorkerModels(for: workerAgentId) }
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "person.badge.plus")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(SwarmTheme.style.tint)
                    Text("手动添加协作工人")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Palette.textPrimary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Palette.textTertiary)
                        .rotationEffect(.degrees(showAddWorker ? 90 : 0))
                }
                .padding(16)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showAddWorker {
                Divider().overlay(Palette.hairline)
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        Eyebrow(text: "工人代号（小写字母/数字/-）")
                        TextField("例如：frontend / tester", text: $workerName)
                            .font(RelayFont.mono(14))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .padding(.horizontal, 12)
                            .frame(height: 42)
                            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.fieldFill))
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Eyebrow(text: "执行 Agent")
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(store.agents) { agent in
                                    let agStyle = store.style(for: agent.id)
                                    let selected = workerAgentId == agent.id
                                    Button {
                                        workerAgentId = agent.id
                                        workerModelId = (agent.id == swarm.defaultWorkerAgentId) ? swarm.defaultWorkerModelId : nil
                                        Haptics.selection()
                                    } label: {
                                        HStack(spacing: 6) {
                                            Image(systemName: agStyle.symbol)
                                                .font(.system(size: 12, weight: .semibold))
                                            Text(agent.name)
                                                .font(.system(size: 13, weight: .semibold))
                                        }
                                        .foregroundStyle(selected ? agStyle.tint : Palette.textSecondary)
                                        .padding(.horizontal, 12)
                                        .frame(height: 34)
                                        .background(Capsule().fill(selected ? agStyle.wash : Palette.fieldFill))
                                        .overlay(Capsule().stroke(selected ? agStyle.tint.opacity(0.5) : Palette.hairline, lineWidth: 0.7))
                                    }
                                    .buttonStyle(.pressable)
                                }
                            }
                        }
                    }

                    if !workerModels.isEmpty || loadingWorkerModels {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 6) {
                                Eyebrow(text: "模型")
                                if loadingWorkerModels { ProgressView().controlSize(.mini) }
                            }
                            Menu {
                                Button("跟随默认") { workerModelId = nil }
                                ForEach(workerModels) { model in
                                    Button {
                                        workerModelId = model.modelId
                                    } label: {
                                        let label = model.description.map { "\(model.name) (\($0))" } ?? model.name
                                        Text(label)
                                    }
                                }
                            } label: {
                                HStack {
                                    Text(selectedWorkerModelLabel)
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundStyle(Palette.textPrimary)
                                        .lineLimit(1)
                                    Spacer()
                                    Image(systemName: "chevron.up.chevron.down")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(Palette.textTertiary)
                                }
                                .padding(.horizontal, 12)
                                .frame(height: 42)
                                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.fieldFill))
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Eyebrow(text: "工作区隔离")
                        Picker("工作区隔离", selection: $workerWorkspace) {
                            Text("共享工作区").tag("inherit")
                            Text("独立 Worktree").tag("worktree")
                        }
                        .pickerStyle(.segmented)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Eyebrow(text: "任务说明（Brief）")
                        TextField("说明该工人负责的文件范围与完成标准…", text: $workerBrief, axis: .vertical)
                            .font(.system(size: 14.5))
                            .lineLimit(3...6)
                            .padding(12)
                            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.fieldFill))
                    }

                    let canAdd = !workerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        && !workerBrief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        && !addingWorker
                    Button {
                        submitAddWorker()
                    } label: {
                        HStack(spacing: 8) {
                            if addingWorker {
                                ProgressView().tint(.white)
                                Text("正在派发…")
                            } else {
                                Image(systemName: "paperplane.fill")
                                Text("派发并启动工人")
                            }
                        }
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                        .background(Capsule(style: .continuous).fill(SwarmTheme.launchGradient))
                        .opacity(canAdd ? 1 : 0.45)
                    }
                    .buttonStyle(.pressable)
                    .disabled(!canAdd)
                }
                .padding(16)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .cardSurface(radius: 20)
    }

    private var selectedWorkerModelLabel: String {
        guard let id = workerModelId, !id.isEmpty else { return "跟随默认" }
        return workerModels.first(where: { $0.modelId == id })?.name ?? id
    }

    private func reloadWorkerModels(for agentId: String) async {
        loadingWorkerModels = true
        let res = await store.fetchAgentModels(agentId: agentId)
        guard !Task.isCancelled else { return }
        workerModels = res?.models ?? []
        loadingWorkerModels = false
    }

    private func submitAddWorker() {
        addingWorker = true
        let name = workerName
        let brief = workerBrief
        let agent = workerAgentId.isEmpty ? nil : workerAgentId
        let model = workerModelId
        let ws = workerWorkspace
        Task {
            let member = await store.addSwarmWorker(
                swarmId: swarmId,
                name: name,
                brief: brief,
                agentId: agent,
                modelId: model,
                workspace: ws
            )
            addingWorker = false
            if member != nil {
                workerName = ""
                workerBrief = ""
                withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                    showAddWorker = false
                }
            }
        }
    }

    // MARK: - Tab 2: Board

    private func boardTab(_ swarm: SwarmSummary) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if boardMessages.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "bubble.left.and.exclamationmark.bubble.right")
                                .font(.system(size: 30, weight: .light))
                                .foregroundStyle(Palette.textTertiary)
                            Text("留言板暂无消息")
                                .font(RelayFont.display(18))
                                .foregroundStyle(Palette.textPrimary)
                            Text("总控派单与工人进度都会沉淀在这里；你也可以在下方直接 @成员名 发消息唤醒任意成员。")
                                .font(.system(size: 13))
                                .foregroundStyle(Palette.textSecondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 56)
                    } else {
                        ForEach(boardMessages, id: \.seq) { msg in
                            SwarmBoardCard(message: msg, swarm: swarm)
                                .id(msg.seq)
                        }
                    }
                    Color.clear.frame(height: 6).id("board-bottom")
                }
                .padding(.horizontal, 18)
                .padding(.top, 6)
                .padding(.bottom, 12)
                .frame(maxWidth: 680)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .refreshable {
                await store.loadSwarm(swarmId)
            }
            .onAppear {
                proxy.scrollTo("board-bottom", anchor: .bottom)
            }
            .onChange(of: boardMessages.last?.seq) { _, _ in
                withAnimation(.spring(response: 0.4, dampingFraction: 0.88)) {
                    proxy.scrollTo("board-bottom", anchor: .bottom)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                boardComposer(swarm)
            }
        }
    }

    private func boardComposer(_ swarm: SwarmSummary) -> some View {
        let mentionTargets: [String] = ["all", "coordinator"] + swarm.activeWorkers.map(\.name)
        let canPost = !boardDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !postingBoard

        return VStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(mentionTargets, id: \.self) { target in
                        Button {
                            insertMention(target)
                            Haptics.selection()
                        } label: {
                            Text("@\(target)")
                                .font(RelayFont.mono(11.5, weight: .semibold))
                                .foregroundStyle(SwarmTheme.style.tint)
                                .padding(.horizontal, 9)
                                .frame(height: 26)
                                .glassCapsule(interactive: true)
                        }
                        .buttonStyle(.pressable)
                    }
                }
                .padding(.horizontal, 14)
            }

            HStack(alignment: .bottom, spacing: 8) {
                TextField("向留言板发消息（输入 @成员名 唤醒）…", text: $boardDraft, axis: .vertical)
                    .font(.system(size: 15.5))
                    .lineLimit(1...5)
                    .padding(.leading, 10)
                    .padding(.vertical, 8)
                    .tint(SwarmTheme.style.tint)

                Button {
                    sendBoardPost()
                } label: {
                    ZStack {
                        if canPost {
                            Circle().fill(SwarmTheme.launchGradient)
                        } else {
                            Circle().fill(Palette.fieldFill)
                        }
                        if postingBoard {
                            ProgressView().controlSize(.small).tint(.white)
                        } else {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(canPost ? Color.white : Palette.textTertiary)
                        }
                    }
                    .frame(width: 34, height: 34)
                }
                .buttonStyle(.pressable)
                .disabled(!canPost)
                .accessibilityLabel("发送留言")
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 6)
            .glassRounded(24, tint: SwarmTheme.style.glow)
            .padding(.horizontal, 14)
        }
        .padding(.top, 6)
        .padding(.bottom, 10)
    }

    private func insertMention(_ target: String) {
        let token = "@\(target) "
        if boardDraft.isEmpty {
            boardDraft = token
        } else if boardDraft.hasSuffix(" ") || boardDraft.hasSuffix("\n") {
            boardDraft += token
        } else {
            boardDraft += " " + token
        }
    }

    private func sendBoardPost() {
        let outgoing = boardDraft
        boardDraft = ""
        postingBoard = true
        Task {
            let ok = await store.postSwarmBoard(swarmId: swarmId, text: outgoing)
            postingBoard = false
            if !ok { boardDraft = outgoing }
        }
    }

    private func navigateToSession(_ targetSessionId: String) {
        Haptics.tap(.soft)
        dismiss()
        guard targetSessionId != currentSessionId else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(180))
            store.requestOpenSession(targetSessionId)
        }
    }
}

// MARK: - Board message card

struct SwarmBoardCard: View {
    let message: SwarmBoardMessage
    let swarm: SwarmSummary

    @Environment(AppStore.self) private var store

    private var senderTint: Color {
        switch message.sender {
        case "coordinator":
            return store.style(for: swarm.coordinatorAgentId).tint
        case "user":
            return SwarmTheme.style.tint
        case "system":
            return Palette.textSecondary
        default:
            if let member = swarm.member(named: message.sender) {
                return store.style(for: member.agentId).tint
            }
            return AgentStyle(family: .emerald, symbol: "cpu").tint
        }
    }

    private var senderLabel: String {
        switch message.sender {
        case "user": return "你"
        case "system": return "系统"
        default: return "@\(message.sender)"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Text("#\(message.seq)")
                    .font(RelayFont.mono(11.5, weight: .bold))
                    .foregroundStyle(Palette.textSecondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2.5)
                    .background(Capsule().fill(Palette.fieldFill))

                Text(senderLabel)
                    .font(RelayFont.mono(12.5, weight: .semibold))
                    .foregroundStyle(senderTint)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2.5)
                    .background(Capsule().fill(senderTint.opacity(0.13)))

                if let kindLabel = message.kindLabel {
                    Text(kindLabel)
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(message.kind == "done" ? Palette.success : Palette.textSecondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule().fill((message.kind == "done" ? Palette.success : Palette.textTertiary).opacity(0.14))
                        )
                }

                Spacer(minLength: 4)

                Text(RelayFormat.relative(message.createdDate))
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(Palette.textTertiary)
            }

            Text(MentionHighlighter.attributed(message.text, tint: SwarmTheme.style.tint))
                .font(.system(size: 14.5))
                .lineSpacing(4)
                .foregroundStyle(Palette.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            if !message.mentions.isEmpty {
                HStack(spacing: 5) {
                    Spacer(minLength: 0)
                    ForEach(message.mentions, id: \.self) { m in
                        Text("@\(m)")
                            .font(RelayFont.mono(10.5, weight: .semibold))
                            .foregroundStyle(SwarmTheme.style.tint)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(SwarmTheme.style.wash))
                    }
                }
            }
        }
        .padding(14)
        .cardSurface(radius: 18)
    }
}

// MARK: - @mention AttributedString highlighter

@MainActor
enum MentionHighlighter {
    private static let regex = #/@[A-Za-z0-9_-]+/#

    static func attributed(_ text: String, tint: Color) -> AttributedString {
        var result = AttributedString(text)
        for match in text.matches(of: regex) {
            guard let lower = AttributedString.Index(match.range.lowerBound, within: result),
                  let upper = AttributedString.Index(match.range.upperBound, within: result) else {
                continue
            }
            let range = lower..<upper
            result[range].foregroundColor = tint
            result[range].font = Font.system(size: 14.5, weight: .semibold, design: .monospaced)
            result[range].backgroundColor = tint.opacity(0.12)
        }
        return result
    }
}
