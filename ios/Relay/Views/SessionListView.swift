import SwiftUI
import UIKit

struct SessionGroup: Identifiable {
    let id: String
    let title: String
    let sessions: [SessionSummary]
}

struct SessionListView: View {
    @Environment(AppStore.self) private var store
    @State private var path: [String] = []
    @State private var search = ""
    @State private var showSettings = false
    @State private var showNewSession = false
    @State private var showQuota = false
    @State private var renameTarget: SessionSummary?
    @State private var renameText = ""
    @State private var showRename = false

    private var filtered: [SessionSummary] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return store.sessions }
        return store.sessions.filter { s in
            s.title.lowercased().contains(query)
                || (store.agent(for: s.agentId)?.name.lowercased().contains(query) ?? false)
                || (s.currentModelName?.lowercased().contains(query) ?? false)
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
            List {
                statusHeader
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 6, trailing: 20))

                if store.sessions.isEmpty && store.hasBootstrapped {
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
            .background(AmbientBackground(tint: nil))
            .navigationTitle("Relay")
            .navigationBarTitleDisplayMode(.large)
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "搜索会话")
            .refreshable {
                await store.refresh()
            }
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
                            showNewSession = true
                        } label: {
                            Label("选择工作区…", systemImage: "folder")
                        }
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .accessibilityLabel("新建会话")
                }
            }
            .navigationDestination(for: String.self) { sessionId in
                ChatView(sessionId: sessionId)
            }
            .safeAreaInset(edge: .bottom) {
                if !store.agents.isEmpty {
                    AgentDock(onCreate: quickCreate)
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .sheet(isPresented: $showNewSession) {
            NewSessionSheet { created in
                path.append(created.id)
            }
        }
        .sheet(isPresented: $showQuota) {
            QuotaSheet()
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

    // MARK: Rows

    @ViewBuilder
    private func row(for session: SessionSummary) -> some View {
        Button {
            Haptics.tap(.soft)
            path.append(session.id)
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
                Task { await store.delete(session.id) }
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
                Task { await store.delete(session.id) }
            } label: {
                Label("删除会话", systemImage: "trash")
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
                path.append(created.id)
            }
        }
    }
}

// MARK: - Session row

struct SessionRow: View {
    @Environment(AppStore.self) private var store
    var session: SessionSummary

    var body: some View {
        let style = store.style(for: session.agentId)
        let agentName = store.agent(for: session.agentId)?.name ?? session.agentId

        HStack(spacing: 14) {
            AgentGlyph(style: style, size: 44, isRunning: session.isRunning)

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Text(session.title)
                        .font(.system(size: 16.5, weight: .semibold))
                        .foregroundStyle(Palette.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(RelayFormat.relative(session.updatedDate))
                        .font(.system(size: 12, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(Palette.textTertiary)
                }

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
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: session.isRunning)
    }
}

// MARK: - Agent dock (quick new session)

struct AgentDock: View {
    @Environment(AppStore.self) private var store
    var onCreate: (String) -> Void

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
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
            }
        }
        .scrollClipDisabled()
    }
}
