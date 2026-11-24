import SwiftUI

struct NewSessionSheet: View {
    var onCreated: (SessionSummary) -> Void

    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var selectedAgent: String?
    @State private var workspaces: [String] = []
    @State private var selectedCwd = ""
    @State private var customCwd = ""
    @State private var creating = false

    private var effectiveCwd: String {
        let custom = customCwd.trimmingCharacters(in: .whitespacesAndNewlines)
        return custom.isEmpty ? selectedCwd : custom
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    VStack(alignment: .leading, spacing: 12) {
                        Eyebrow(text: "Agent")
                        VStack(spacing: 10) {
                            ForEach(store.agents) { agent in
                                agentCard(agent)
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Eyebrow(text: "工作区")
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
                                    tint: tint
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
                .padding(20)
                .padding(.bottom, 90)
            }
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom) {
                createButton
                    .padding(.horizontal, 20)
                    .padding(.bottom, 10)
            }
            .navigationTitle("新建会话")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .relaySheetBackground()
        .task {
            if selectedAgent == nil { selectedAgent = store.agents.first?.id }
            if selectedCwd.isEmpty { selectedCwd = store.defaultCwd }
            let list = await store.fetchWorkspaces()
            withAnimation(.easeOut(duration: 0.25)) {
                workspaces = list.isEmpty ? [store.defaultCwd].filter { !$0.isEmpty } : list
            }
        }
    }

    private var tint: Color {
        store.style(for: selectedAgent ?? "").tint
    }

    private func agentCard(_ agent: AgentInfo) -> some View {
        let style = store.style(for: agent.id)
        let selected = selectedAgent == agent.id
        return Button {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) {
                selectedAgent = agent.id
            }
            Haptics.selection()
        } label: {
            HStack(spacing: 14) {
                AgentGlyph(style: style, size: 42)
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
                    .foregroundStyle(selected ? style.tint : Palette.textTertiary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(selected ? style.wash : Palette.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(selected ? style.tint.opacity(0.55) : Palette.hairline, lineWidth: selected ? 1.2 : 0.6)
            )
        }
        .buttonStyle(.pressable)
    }

    private var createButton: some View {
        let style = store.style(for: selectedAgent ?? "")
        return Button {
            guard let agentId = selectedAgent, !creating else { return }
            creating = true
            Task {
                let created = await store.createSession(agentId: agentId, cwd: effectiveCwd)
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
                    Text("正在启动 Agent…")
                } else {
                    Image(systemName: "plus")
                    Text("创建会话")
                }
            }
            .font(.system(size: 16.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .background(Capsule(style: .continuous).fill(style.gradient))
            .overlay(Capsule(style: .continuous).stroke(Color.white.opacity(0.22), lineWidth: 0.6))
            .shadow(color: style.glow.opacity(0.4), radius: 16, y: 6)
        }
        .buttonStyle(.pressable)
        .disabled(selectedAgent == nil || creating)
    }
}
