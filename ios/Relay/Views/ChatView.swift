import SwiftUI
import UIKit

private struct BottomSentinelKey: PreferenceKey {
    static let defaultValue: CGFloat = .infinity
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = min(value, nextValue())
    }
}

struct ChatView: View {
    let sessionId: String

    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    @State private var showConfig = false
    @State private var showContextInfo = false
    @State private var showQuota = false
    @State private var showSwarm = false
    @State private var isAtBottom = true
    @State private var viewportHeight: CGFloat = 0
    @State private var lightbox: Attachment?

    private let bottomID = "chat-bottom"

    var body: some View {
        let session = store.session(sessionId)
        let swarm = store.swarm(forSessionId: sessionId)
        let style = store.style(for: session?.agentId ?? "")
        let agentName = session.flatMap { store.agent(for: $0.agentId)?.name } ?? session?.agentId ?? "Agent"
        let messages = store.messages(for: sessionId)
        let isLoading = store.loadingSessions.contains(sessionId) && messages.isEmpty
        let isRunning = session?.isRunning ?? false

        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 26) {
                    if isLoading {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                        .padding(.top, 80)
                    } else if messages.isEmpty, let session {
                        ChatEmptyState(session: session, swarm: swarm, agentName: agentName, style: style) { suggestion in
                            draft = suggestion
                        }
                        .padding(.top, 40)
                    }

                    ForEach(messages) { message in
                        MessageRow(message: message, style: style, agentName: agentName) { attachment in
                            lightbox = attachment
                        }
                        .equatable()
                        .id(message.id)
                        .transition(.asymmetric(
                            insertion: .move(edge: .bottom).combined(with: .opacity),
                            removal: .opacity
                        ))
                    }

                    Color.clear
                        .frame(height: 1)
                        .id(bottomID)
                        .background(
                            GeometryReader { geo in
                                Color.clear.preference(
                                    key: BottomSentinelKey.self,
                                    value: geo.frame(in: .named("chat-scroll")).minY
                                )
                            }
                        )
                }
                .padding(.horizontal, 18)
                .padding(.top, 14)
                .padding(.bottom, 8)
                .frame(maxWidth: 780)
                .frame(maxWidth: .infinity)
            }
            .coordinateSpace(name: "chat-scroll")
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { viewportHeight = geo.size.height }
                        .onChange(of: geo.size.height) { _, height in viewportHeight = height }
                }
            )
            .onPreferenceChange(BottomSentinelKey.self) { minY in
                let atBottom = minY <= viewportHeight + 90
                if atBottom != isAtBottom {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        isAtBottom = atBottom
                    }
                }
            }
            .onChange(of: messages.count) { oldCount, newCount in
                guard newCount > oldCount else { return }
                if oldCount == 0 {
                    proxy.scrollTo(bottomID, anchor: .bottom)
                } else {
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.9)) {
                        proxy.scrollTo(bottomID, anchor: .bottom)
                    }
                }
            }
            .onChange(of: streamSignature(messages)) { _, _ in
                if isAtBottom {
                    proxy.scrollTo(bottomID, anchor: .bottom)
                }
            }
            .overlay(alignment: .bottom) {
                if !isAtBottom && !messages.isEmpty {
                    ScrollToBottomPill(isStreaming: isRunning, tint: style.tint) {
                        Haptics.tap(.soft)
                        withAnimation(.spring(response: 0.5, dampingFraction: 0.88)) {
                            proxy.scrollTo(bottomID, anchor: .bottom)
                        }
                    }
                    .padding(.bottom, 12)
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if let swarm, let session {
                    SwarmBarView(
                        swarm: swarm,
                        currentSession: session,
                        onOpenOverview: {
                            showSwarm = true
                        },
                        onSelectSession: { targetId in
                            store.requestOpenSession(targetId)
                        }
                    )
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                ComposerView(sessionId: sessionId, style: style, agentName: agentName, text: $draft)
            }
        }
        .background(AmbientBackground(tint: style.glow))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Button {
                    showConfig = true
                    Haptics.tap()
                } label: {
                    VStack(spacing: 1) {
                        Text(session?.title ?? "会话")
                            .font(.system(size: 15.5, weight: .semibold))
                            .foregroundStyle(Palette.textPrimary)
                            .lineLimit(1)
                        HStack(spacing: 4) {
                            Circle()
                                .fill(style.tint)
                                .frame(width: 5, height: 5)
                            Text(subtitle(session: session, agentName: agentName))
                                .lineLimit(1)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 8, weight: .bold))
                        }
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Palette.textSecondary)
                    }
                    .frame(maxWidth: 230)
                }
                .buttonStyle(.plain)
                .accessibilityHint("打开模型与模式设置")
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                if let swarm {
                    Button {
                        showSwarm = true
                        Haptics.tap()
                    } label: {
                        Image(systemName: SwarmTheme.style.symbol)
                            .foregroundStyle(swarm.isAnyRunning ? SwarmTheme.style.tint : Palette.textPrimary)
                            .symbolEffect(.pulse, options: .repeating, isActive: swarm.isAnyRunning)
                    }
                    .accessibilityLabel("蜂群总览")
                }

                Button {
                    showContextInfo = true
                    Haptics.tap()
                } label: {
                    ContextRing(fraction: session?.contextFraction ?? 0, size: 26, lineWidth: 2.6)
                }
                .accessibilityLabel("上下文用量")
                .popover(isPresented: $showContextInfo) {
                    ContextInfoView(session: session, tint: style.tint) {
                        showContextInfo = false
                        Task {
                            try? await Task.sleep(nanoseconds: 380_000_000)
                            showQuota = true
                        }
                    }
                    .presentationCompactAdaptation(.popover)
                }

                Button {
                    showConfig = true
                    Haptics.tap()
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .accessibilityLabel("会话配置")
            }
        }
        .sheet(isPresented: $showConfig) {
            ConfigSheet(sessionId: sessionId)
        }
        .fullScreenCover(item: $lightbox) { attachment in
            LightboxView(attachment: attachment)
        }
        .sheet(isPresented: $showQuota) {
            QuotaSheet(focusAgent: session?.agentId)
        }
        .sheet(isPresented: $showSwarm) {
            if let sw = store.swarm(forSessionId: sessionId) {
                SwarmSheet(swarmId: sw.id, currentSessionId: sessionId)
            }
        }
        .task(id: sessionId) {
            store.activeSessionId = sessionId
            await store.loadSession(sessionId)
        }
        .task(id: swarm?.id ?? session?.swarmId) {
            if let swId = swarm?.id ?? session?.swarmId {
                await store.loadSwarm(swId)
            }
        }
        .onDisappear {
            if store.activeSessionId == sessionId {
                store.activeSessionId = nil
            }
        }
        .onChange(of: session == nil) { _, missing in
            if missing && store.hasBootstrapped && !store.loadingSessions.contains(sessionId) {
                dismiss()
            }
        }
    }

    private func subtitle(session: SessionSummary?, agentName: String) -> String {
        var parts = [agentName]
        if let model = session?.currentModelName { parts.append(model) }
        return parts.joined(separator: " · ")
    }

    /// Cheap O(1) signature that changes whenever the tail message streams.
    private func streamSignature(_ messages: [Message]) -> Int {
        guard let last = messages.last else { return 0 }
        return last.content.utf8.count &+ last.thinking.utf8.count &* 31 &+ last.toolCalls.count &* 7919
    }
}

// MARK: - Scroll-to-bottom pill

struct ScrollToBottomPill: View {
    var isStreaming: Bool
    var tint: Color
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if isStreaming {
                    Circle()
                        .fill(tint)
                        .frame(width: 6, height: 6)
                        .shadow(color: tint, radius: 3)
                }
                Image(systemName: "arrow.down")
                    .font(.system(size: 12, weight: .bold))
                Text(isStreaming ? "正在生成" : "回到底部")
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(Palette.textPrimary)
            .padding(.horizontal, 15)
            .frame(height: 38)
            .glassCapsule(interactive: true)
        }
        .buttonStyle(.pressable)
    }
}

// MARK: - Context info popover

struct ContextInfoView: View {
    var session: SessionSummary?
    var tint: Color
    var onOpenQuotas: () -> Void

    private var showsCredits: Bool {
        session?.agentId == "codebuddy" || (session?.totalCredits ?? 0) > 0
    }

    var body: some View {
        let used = Double(session?.contextUsed ?? 0)
        let size = Double(session?.contextSize ?? 0)
        VStack(alignment: .leading, spacing: 14) {
            Eyebrow(text: "上下文窗口")
            HStack(alignment: .center, spacing: 14) {
                ContextRing(fraction: session?.contextFraction ?? 0, size: 52, lineWidth: 5)
                VStack(alignment: .leading, spacing: 4) {
                    Text(size > 0 ? "\(RelayFormat.tokens(used)) / \(RelayFormat.tokens(size))" : "暂无数据")
                        .font(RelayFont.rounded(19, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Palette.textPrimary)
                    Text(size > 0 ? "已使用 \(Int(((session?.contextFraction ?? 0) * 100).rounded()))% tokens" : "Agent 尚未上报用量")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Palette.textSecondary)
                }
            }

            if showsCredits {
                Divider().overlay(Palette.hairline)
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Eyebrow(text: "本会话累计积分")
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(RelayFormat.credits(session?.totalCredits ?? 0))
                                .font(RelayFont.rounded(21, weight: .semibold))
                                .monospacedDigit()
                                .foregroundStyle(Palette.textPrimary)
                                .contentTransition(.numericText(value: session?.totalCredits ?? 0))
                            Text("积分")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Palette.textTertiary)
                        }
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "creditcard")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(tint)
                }
            }

            Button {
                Haptics.tap()
                onOpenQuotas()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "gauge.with.dots.needle.bottom.50percent")
                    Text("查看全部限额与积分")
                    Spacer(minLength: 6)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                }
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(tint)
                .padding(.horizontal, 12)
                .frame(height: 40)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(tint.opacity(0.11))
                )
            }
            .buttonStyle(.pressable)
        }
        .padding(18)
        .frame(minWidth: 260)
    }
}

// MARK: - Empty state

struct ChatEmptyState: View {
    var session: SessionSummary
    var swarm: SwarmSummary? = nil
    var agentName: String
    var style: AgentStyle
    var onSuggestion: (String) -> Void

    @Environment(AppStore.self) private var store

    private struct Suggestion: Hashable {
        let icon: String
        let text: String
    }

    private let normalSuggestions: [Suggestion] = [
        Suggestion(icon: "doc.text.magnifyingglass", text: "梳理一下当前项目的结构"),
        Suggestion(icon: "checklist", text: "帮我列一个今天的待办计划"),
        Suggestion(icon: "ladybug", text: "检查最近的报错并修复"),
    ]

    private let swarmSuggestions: [Suggestion] = [
        Suggestion(icon: "square.split.2x2", text: "拆解需求并分配前端与后端工人并行实现"),
        Suggestion(icon: "magnifyingglass.circle", text: "派两个工人分别排查性能瓶颈与测试覆盖率"),
        Suggestion(icon: "doc.text.magnifyingglass", text: "先调研代码库架构，再给出分工与验收方案"),
    ]

    private var isSwarmCoordinator: Bool {
        session.isSwarmCoordinator || (swarm != nil && swarm?.coordinatorSessionId == session.id)
    }

    private var suggestions: [Suggestion] {
        isSwarmCoordinator ? swarmSuggestions : normalSuggestions
    }

    private var accentStyle: AgentStyle {
        isSwarmCoordinator ? SwarmTheme.style : style
    }

    var body: some View {
        VStack(spacing: 22) {
            AgentGlyph(style: accentStyle, size: 64)
            VStack(spacing: 8) {
                Text(isSwarmCoordinator ? "蜂群总控已就绪" : "与 \(agentName) 对话")
                    .font(RelayFont.display(26))
                    .foregroundStyle(Palette.textPrimary)
                HStack(spacing: 6) {
                    if isSwarmCoordinator, let swarm {
                        let workerName = store.agent(for: swarm.defaultWorkerAgentId)?.name ?? swarm.defaultWorkerAgentId
                        Text("\(agentName) 统筹 · \(workerName) 协作")
                    } else if let model = session.currentModelName {
                        Text(model)
                    }
                    if !session.cwd.isEmpty {
                        Text("·")
                        Text(RelayFormat.shortPath(session.cwd))
                            .font(RelayFont.mono(12))
                    }
                }
                .font(.system(size: 13))
                .foregroundStyle(Palette.textSecondary)

                if isSwarmCoordinator {
                    Text("直接描述目标，总控会自动拆解任务、拉起工人与独立 Worktree，并在留言板实时协同。")
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.textTertiary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12)
                        .padding(.top, 2)
                }
            }

            VStack(spacing: 10) {
                ForEach(suggestions, id: \.text) { item in
                    Button {
                        Haptics.selection()
                        onSuggestion(item.text)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: item.icon)
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(accentStyle.tint)
                                .frame(width: 22)
                            Text(item.text)
                                .font(.system(size: 14.5, weight: .medium))
                                .foregroundStyle(Palette.textPrimary)
                                .multilineTextAlignment(.leading)
                            Spacer()
                            Image(systemName: "arrow.up.left")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Palette.textTertiary)
                        }
                        .padding(.horizontal, 16)
                        .frame(minHeight: 50)
                        .padding(.vertical, 6)
                        .cardSurface(radius: 16)
                    }
                    .buttonStyle(.pressable)
                }
                if !session.availableCommands.isEmpty {
                    Text("输入 / 查看 \(session.availableCommands.count) 个可用命令")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Palette.textTertiary)
                        .padding(.top, 4)
                }
            }
            .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity)
    }
}
