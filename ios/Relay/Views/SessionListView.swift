import SwiftUI
import UIKit

struct SessionGroup: Identifiable {
    let id: String
    let title: String
    let sessions: [SessionSummary]
}

struct SessionListView: View {
    @Environment(AppStore.self) private var store
    @State private var path = NavigationPath()
    @State private var sessionTrail: [String] = []
    @State private var search = ""
    @State private var showSettings = false
    @State private var showNewSession = false
    @State private var showNewSwarm = false
    @State private var showQuota = false
    @State private var renameTarget: SessionSummary?
    @State private var renameText = ""
    @State private var showRename = false
    @Namespace private var sectionSwitchNamespace

    private var filtered: [SessionSummary] {
        let base = store.topLevelSessions
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return base }
        return base.filter { s in
            if s.title.lowercased().contains(query) { return true }
            if store.agent(for: s.agentId)?.name.lowercased().contains(query) ?? false { return true }
            if s.currentModelName?.lowercased().contains(query) ?? false { return true }
            if let sw = store.swarm(forSessionId: s.id) {
                if sw.title.lowercased().contains(query) { return true }
                if sw.members.contains(where: { $0.name.lowercased().contains(query) }) { return true }
                if "蜂群".contains(query) || "swarm".contains(query) { return true }
            }
            return false
        }
    }

    private var groups: [SessionGroup] {
        let calendar = Calendar.current
        var today: [SessionSummary] = []
        var yesterday: [SessionSummary] = []
        var earlier: [SessionSummary] = []
        for s in filtered {
            let date = s.updatedDate
            if calendar.isDateInToday(date) {
                today.append(s)
            } else if calendar.isDateInYesterday(date) {
                yesterday.append(s)
            } else {
                earlier.append(s)
            }
        }
        return [
            SessionGroup(id: "today", title: "今天", sessions: today),
            SessionGroup(id: "yesterday", title: "昨天", sessions: yesterday),
            SessionGroup(id: "earlier", title: "更早", sessions: earlier),
        ].filter { !$0.sessions.isEmpty }
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if store.homeSection == .agent {
                    agentList
                } else {
                    TavernCharacterListView(search: search, header: { topHeader }) { characterId in
                        openTavern(characterId: characterId)
                    }
                }
            }
            .background(AmbientBackground(tint: store.homeSection == .tavern ? TavernTheme.glow : nil))
            .navigationTitle(store.homeSection == .agent ? "Relay" : "酒馆")
            .navigationBarTitleDisplayMode(.large)
            .searchable(
                text: $search,
                placement: .navigationBarDrawer(displayMode: .automatic),
                prompt: store.homeSection == .agent ? "搜索会话" : "搜索角色"
            )
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showSettings = true
                        Haptics.tap()
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("设置")
                }

                if store.homeSection == .agent {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showQuota = true
                            Haptics.tap()
                        } label: {
                            Image(systemName: "gauge.with.dots.needle.bottom.50percent")
                        }
                        .accessibilityLabel("限额与积分")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Section("快速新建") {
                                ForEach(store.agents) { agent in
                                    Button {
                                        quickCreate(agent.id)
                                    } label: {
                                        Label(agent.name, systemImage: store.style(for: agent.id).symbol)
                                    }
                                }
                            }
                            Button {
                                showNewSwarm = true
                            } label: {
                                Label("新建蜂群协作…", systemImage: SwarmTheme.style.symbol)
                            }
                            Button {
                                showNewSession = true
                            } label: {
                                Label("选择工作区…", systemImage: "folder")
                            }
                        } label: {
                            Image(systemName: "square.and.pencil")
                        }
                        .accessibilityLabel("新建会话")
                    }
                } else {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button {
                                Task { await store.reloadTavern() }
                            } label: {
                                Label("同步原版配置", systemImage: "arrow.triangle.2.circlepath")
                            }
                            .disabled(store.isReloadingTavern)

                            if let publicURL = store.tavernStatus?.publicURL {
                                Link(destination: publicURL) {
                                    Label("在浏览器打开原版网页", systemImage: "safari")
                                }
                            }

                            Divider()

                            Button {
                                Task { await store.loadTavernOverview() }
                            } label: {
                                Label("刷新角色列表", systemImage: "arrow.clockwise")
                            }
                        } label: {
                            if store.isReloadingTavern {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "ellipsis.circle")
                            }
                        }
                        .accessibilityLabel("酒馆菜单")
                    }
                }
            }
            .navigationDestination(for: String.self) { sessionId in
                ChatView(sessionId: sessionId)
            }
            .navigationDestination(for: TavernRoute.self) { route in
                TavernChatView(characterId: route.characterId)
            }
            .safeAreaInset(edge: .bottom) {
                if store.homeSection == .agent && !store.agents.isEmpty {
                    AgentDock(onCreate: quickCreate) {
                        Haptics.tap(.medium)
                        showNewSwarm = true
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .sheet(isPresented: $showNewSession) {
            NewSessionSheet { created in
                openSession(created.id)
            }
        }
        .sheet(isPresented: $showNewSwarm) {
            NewSwarmSheet { created in
                openSession(created.session.id)
            }
        }
        .sheet(isPresented: $showQuota) {
            QuotaSheet()
        }
        .onChange(of: store.pendingOpenSessionId) { _, targetId in
            guard let targetId else { return }
            store.pendingOpenSessionId = nil
            openSession(targetId)
        }
        .onChange(of: path.count) { _, newCount in
            if newCount < sessionTrail.count {
                sessionTrail = Array(sessionTrail.prefix(newCount))
            }
        }
        .task(id: store.hasBootstrapped) {
            if store.hasBootstrapped && store.quotas == nil {
                await store.loadQuotas()
            }
        }
        .alert("重命名会话", isPresented: $showRename) {
            TextField("会话标题", text: $renameText)
            Button("取消", role: .cancel) {}
            Button("保存") {
                if let target = renameTarget {
                    let title = renameText
                    Task { await store.rename(target.id, to: title) }
                }
            }
        }
    }

    private var agentList: some View {
        List {
            topHeader
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 10, trailing: 20))

            if store.topLevelSessions.isEmpty && store.hasBootstrapped {
                emptyState
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            } else if !store.hasBootstrapped {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .padding(.vertical, 40)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            ForEach(groups) { group in
                Section {
                    ForEach(group.sessions) { session in
                        row(for: session)
                    }
                } header: {
                    Eyebrow(text: group.title)
                        .padding(.leading, 4)
                        .padding(.top, 10)
                }
                .listSectionSeparator(.hidden)
            }

            if !search.isEmpty && filtered.isEmpty {
                Text("没有找到「\(search)」相关的会话")
                    .font(.system(size: 14))
                    .foregroundStyle(Palette.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 30)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            Color.clear
                .frame(height: 70)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .refreshable {
            await store.refresh()
        }
    }

    private var topHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            statusHeader
            sectionSwitcher
        }
    }

    private var sectionSwitcher: some View {
        HStack(spacing: 4) {
            ForEach(HomeSection.allCases) { section in
                let selected = store.homeSection == section
                Button {
                    guard store.homeSection != section else { return }
                    Haptics.selection()
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.84)) {
                        store.homeSection = section
                    }
                    if section == .tavern && store.tavernStatus == nil {
                        Task { await store.loadTavernOverview() }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: section == .agent ? "sparkles" : "book.pages.fill")
                            .font(.system(size: 12.5, weight: .semibold))
                        Text(section.title)
                            .font(.system(size: 13.5, weight: .semibold))
                        if section == .tavern && store.isTavernGenerating {
                            PulseDot(color: TavernTheme.tint, size: 5)
                        }
                    }
                    .foregroundStyle(selected ? Palette.textPrimary : Palette.textSecondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 34)
                    .background {
                        if selected {
                            Capsule(style: .continuous)
                                .fill(section == .tavern ? TavernTheme.wash : Palette.surface)
                                .overlay(
                                    Capsule(style: .continuous)
                                        .stroke(section == .tavern ? TavernTheme.tint.opacity(0.35) : Palette.hairlineStrong, lineWidth: 0.6)
                                )
                                .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
                                .matchedGeometryEffect(id: "home-section-pill", in: sectionSwitchNamespace)
                        }
                    }
                    .contentShape(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .glassCapsule()
    }

    // MARK: Rows

    @ViewBuilder
    private func row(for session: SessionSummary) -> some View {
        Button {
            Haptics.tap(.soft)
            openSession(session.id)
        } label: {
            SessionRow(session: session)
        }
        .buttonStyle(.pressable)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 6, leading: 20, bottom: 6, trailing: 20))
        .listRowSeparatorTint(Palette.hairline)
        .alignmentGuide(.listRowSeparatorLeading) { _ in 58 }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                deleteSessionOrSwarm(session)
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
        .swipeActions(edge: .leading) {
            Button {
                beginRename(session)
            } label: {
                Label("重命名", systemImage: "pencil")
            }
            .tint(store.style(for: session.agentId).glow)
        }
        .contextMenu {
            Button {
                beginRename(session)
            } label: {
                Label("重命名", systemImage: "pencil")
            }
            Button {
                UIPasteboard.general.string = session.cwd
                Haptics.success()
            } label: {
                Label("拷贝工作区路径", systemImage: "doc.on.doc")
            }
            Divider()
            Button(role: .destructive) {
                deleteSessionOrSwarm(session)
            } label: {
                Label(session.isSwarmCoordinator ? "删除蜂群" : "删除会话", systemImage: "trash")
            }
        }
    }

    private var statusHeader: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
                .shadow(color: statusColor.opacity(0.7), radius: 3)
            Text(statusText)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .contentTransition(.opacity)
            Spacer()
            if store.homeSection == .agent {
                let running = store.sessions.filter(\.isRunning).count
                if running > 0 {
                    Text("\(running) 个任务运行中")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Palette.textSecondary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Palette.fieldFill))
                }
                Button {
                    showQuota = true
                    Haptics.tap(.soft)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "gauge.with.dots.needle.bottom.50percent")
                            .font(.system(size: 10.5, weight: .semibold))
                        Text(quotaChipText)
                            .monospacedDigit()
                            .contentTransition(.numericText())
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8.5, weight: .bold))
                            .foregroundStyle(Palette.textTertiary)
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.textSecondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Palette.fieldFill))
                    .overlay(Capsule().stroke(Palette.hairline, lineWidth: 0.5))
                }
                .buttonStyle(.pressable)
                .accessibilityLabel("限额与积分")
            } else if store.isTavernGenerating {
                HStack(spacing: 4) {
                    PulseDot(color: TavernTheme.tint, size: 5)
                    Text("酒馆生成中")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(TavernTheme.tint)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Capsule().fill(TavernTheme.wash))
            } else if let handle = store.tavernStatus?.handle, !handle.isEmpty, store.tavernStatus?.ready == true {
                Text(handle)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.textSecondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Palette.fieldFill))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: store.socketState)
    }

    private var quotaChipText: String {
        if let usage = store.quotas?.codebuddy, usage.available {
            return "今日 \(RelayFormat.credits(usage.todayCredits)) 积分"
        }
        return "限额"
    }

    private var statusColor: Color {
        switch store.socketState {
        case .connected: return Palette.success
        case .connecting: return Palette.warning
        case .disconnected, .idle: return Palette.danger
        }
    }

    private var statusText: String {
        switch store.socketState {
        case .connected: return "已连接 · \(store.serverHost)"
        case .connecting: return "正在连接 · \(store.serverHost)"
        case .disconnected: return "连接中断，正在重试…"
        case .idle: return "未连接"
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Palette.fieldFill)
                    .frame(width: 96, height: 96)
                Image(systemName: "bubble.left.and.text.bubble.right")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(Palette.textSecondary)
            }
            Text("还没有会话")
                .font(RelayFont.display(22))
                .foregroundStyle(Palette.textPrimary)
            Text("从下方选择一个 Agent，开始你的第一段对话。")
                .font(.system(size: 14.5))
                .foregroundStyle(Palette.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    // MARK: Actions

    private func beginRename(_ session: SessionSummary) {
        renameTarget = session
        renameText = session.title
        showRename = true
    }

    private func quickCreate(_ agentId: String) {
        guard !store.creatingAgentIds.contains(agentId) else { return }
        Haptics.tap(.medium)
        Task {
            if let created = await store.createSession(agentId: agentId) {
                openSession(created.id)
            }
        }
    }

    private func deleteSessionOrSwarm(_ session: SessionSummary) {
        if session.isSwarmCoordinator, let sw = store.swarm(forSessionId: session.id) {
            Task { await store.deleteSwarm(sw.id) }
        } else {
            Task { await store.delete(session.id) }
        }
    }

    /// Safely navigates to `targetId` without pushing duplicates onto the stack.
    private func openSession(_ targetId: String) {
        if path.count == sessionTrail.count {
            if sessionTrail.last == targetId { return }
            if let existingIndex = sessionTrail.firstIndex(of: targetId) {
                let drop = sessionTrail.count - 1 - existingIndex
                if drop > 0 {
                    path.removeLast(drop)
                    sessionTrail.removeLast(drop)
                }
                return
            }
            if sessionTrail.count >= 2,
               let topId = sessionTrail.last,
               let topSwarm = store.swarm(forSessionId: topId),
               let targetSwarm = store.swarm(forSessionId: targetId),
               topSwarm.id == targetSwarm.id,
               topId != topSwarm.coordinatorSessionId {
                path.removeLast(1)
                sessionTrail.removeLast(1)
                path.append(targetId)
                sessionTrail.append(targetId)
                return
            }
        }
        path.append(targetId)
        sessionTrail.append(targetId)
    }

    private func openTavern(characterId: Int) {
        sessionTrail = []
        path.append(TavernRoute(characterId: characterId))
    }
}

// MARK: - Session row

struct SessionRow: View {
    @Environment(AppStore.self) private var store
    var session: SessionSummary

    var body: some View {
        let style = store.style(for: session.agentId)
        let agentName = store.agent(for: session.agentId)?.name ?? session.agentId
        let swarm = session.isSwarmCoordinator ? store.swarm(forSessionId: session.id) : nil
        let isRunning = session.isRunning || (swarm?.isAnyRunning ?? false)

        HStack(spacing: 14) {
            ZStack(alignment: .bottomTrailing) {
                AgentGlyph(style: style, size: 44, isRunning: isRunning)
                if swarm != nil {
                    Image(systemName: SwarmTheme.style.symbol)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 19, height: 19)
                        .background(Circle().fill(SwarmTheme.style.gradient))
                        .overlay(Circle().stroke(Palette.canvas, lineWidth: 1.8))
                        .offset(x: 4, y: 4)
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Text(swarm?.title.isEmpty == false ? (swarm?.title ?? session.title) : session.title)
                        .font(.system(size: 16.5, weight: .semibold))
                        .foregroundStyle(Palette.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(RelayFormat.relative(session.updatedDate))
                        .font(.system(size: 12, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(Palette.textTertiary)
                }

                if let swarm {
                    HStack(spacing: 6) {
                        HStack(spacing: 4) {
                            Image(systemName: SwarmTheme.style.symbol)
                                .font(.system(size: 9.5, weight: .bold))
                            Text("蜂群 · \(swarm.liveMemberCount) 成员")
                        }
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(SwarmTheme.style.tint)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2.5)
                        .background(Capsule().fill(SwarmTheme.style.wash))
                        .overlay(Capsule().stroke(SwarmTheme.style.tint.opacity(0.25), lineWidth: 0.5))

                        if swarm.totalCredits > 0 {
                            Text("\(RelayFormat.credits(swarm.totalCredits)) 积分")
                                .font(.system(size: 12, weight: .medium))
                                .monospacedDigit()
                                .foregroundStyle(Palette.textSecondary)
                                .lineLimit(1)
                        }

                        Spacer(minLength: 4)

                        if isRunning {
                            HStack(spacing: 2) {
                                PulseDot(color: SwarmTheme.style.tint, size: 6)
                                Text("\(max(1, swarm.runningCount)) 运行中")
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .foregroundStyle(SwarmTheme.style.tint)
                            }
                            .transition(.scale.combined(with: .opacity))
                        }
                    }
                } else {
                    HStack(spacing: 6) {
                        Text(agentName)
                            .foregroundStyle(style.tint)
                            .fontWeight(.semibold)
                        if let model = session.currentModelName {
                            Text("·").foregroundStyle(Palette.textTertiary)
                            Text(model)
                                .foregroundStyle(Palette.textSecondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        if session.isRunning {
                            HStack(spacing: 2) {
                                PulseDot(color: style.tint, size: 6)
                                Text("运行中")
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .foregroundStyle(style.tint)
                            }
                            .transition(.scale.combined(with: .opacity))
                        }
                    }
                    .font(.system(size: 13))
                }
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: isRunning)
    }
}

// MARK: - Agent dock (quick new session & swarm)

struct AgentDock: View {
    @Environment(AppStore.self) private var store
    var onCreate: (String) -> Void
    var onCreateSwarm: () -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            GlassGroup(spacing: 10) {
                HStack(spacing: 10) {
                    ForEach(store.agents) { agent in
                        let style = store.style(for: agent.id)
                        let creating = store.creatingAgentIds.contains(agent.id)
                        Button {
                            onCreate(agent.id)
                        } label: {
                            HStack(spacing: 9) {
                                ZStack {
                                    if creating {
                                        ProgressView()
                                            .controlSize(.small)
                                    } else {
                                        AgentGlyph(style: style, size: 26)
                                    }
                                }
                                .frame(width: 26, height: 26)
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(agent.name)
                                        .font(.system(size: 14.5, weight: .semibold))
                                        .foregroundStyle(Palette.textPrimary)
                                    Text(creating ? "正在启动…" : "新建会话")
                                        .font(.system(size: 10.5, weight: .medium))
                                        .foregroundStyle(Palette.textSecondary)
                                }
                            }
                            .padding(.leading, 10)
                            .padding(.trailing, 16)
                            .frame(height: 50)
                            .glassCapsule(interactive: true, tint: style.glow)
                        }
                        .buttonStyle(.pressable)
                        .disabled(creating)
                    }

                    Button(action: onCreateSwarm) {
                        HStack(spacing: 9) {
                            ZStack {
                                if store.creatingSwarm {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    AgentGlyph(style: SwarmTheme.style, size: 26)
                                }
                            }
                            .frame(width: 26, height: 26)
                            VStack(alignment: .leading, spacing: 0) {
                                Text("蜂群")
                                    .font(.system(size: 14.5, weight: .semibold))
                                    .foregroundStyle(Palette.textPrimary)
                                Text(store.creatingSwarm ? "正在启动…" : "多 Agent 协作")
                                    .font(.system(size: 10.5, weight: .medium))
                                    .foregroundStyle(Palette.textSecondary)
                            }
                        }
                        .padding(.leading, 10)
                        .padding(.trailing, 16)
                        .frame(height: 50)
                        .glassCapsule(interactive: true, tint: SwarmTheme.style.glow)
                    }
                    .buttonStyle(.pressable)
                    .disabled(store.creatingSwarm)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
            }
        }
        .scrollClipDisabled()
    }
}
