import SwiftUI

// MARK: - Shared Swarm styling helpers

enum SwarmTheme {
    static let style = AgentStyle(family: .amber, symbol: "circle.hexagongrid.fill")

    /// Amber-to-indigo flagship gradient for launching multi-agent swarms.
    static let launchGradient = LinearGradient(
        colors: [Color(hex: 0xF3BE6E), Color(hex: 0xD98B2B), Color(hex: 0x6E73F0)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static func stateColor(for member: SwarmMember, agentStyle: AgentStyle) -> Color {
        if member.isKilled { return Palette.textTertiary }
        if member.isWorking { return agentStyle.tint }
        if member.isDone { return Palette.success }
        if member.isError { return Palette.danger }
        return Palette.textSecondary
    }
}

// MARK: - Top Swarm status bar inside ChatView

struct SwarmBarView: View {
    let swarm: SwarmSummary
    let currentSession: SessionSummary
    var onOpenOverview: () -> Void
    var onSelectSession: (String) -> Void

    @Environment(AppStore.self) private var store

    private var isCoordinatorView: Bool {
        currentSession.isSwarmCoordinator || currentSession.id == swarm.coordinatorSessionId
    }

    private var currentMember: SwarmMember? {
        swarm.member(forSessionId: currentSession.id)
    }

    var body: some View {
        GlassGroup(spacing: 8) {
            VStack(alignment: .leading, spacing: 8) {
                if isCoordinatorView {
                    coordinatorBar
                } else {
                    workerBar
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .glassRounded(20, tint: SwarmTheme.style.glow)
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 6)
        .animation(.spring(response: 0.36, dampingFraction: 0.86), value: swarm.members)
        .animation(.spring(response: 0.36, dampingFraction: 0.86), value: swarm.headSeq)
    }

    // MARK: Coordinator perspective

    @ViewBuilder
    private var coordinatorBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: SwarmTheme.style.symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(SwarmTheme.style.tint)
                if swarm.isAnyRunning {
                    PulseDot(color: SwarmTheme.style.tint, size: 6)
                }
                Text(coordinatorSummary)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            if swarm.totalCredits > 0 {
                Text("\(RelayFormat.credits(swarm.totalCredits)) 积分")
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Palette.textSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule(style: .continuous).fill(Palette.fieldFill))
            }

            overviewButton
        }

        if !swarm.workers.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    ForEach(swarm.workers) { worker in
                        workerChip(worker)
                    }
                }
                .padding(.vertical, 1)
            }
        }
    }

    private var coordinatorSummary: String {
        if swarm.isAnyRunning {
            return "蜂群 · \(swarm.runningCount)/\(swarm.liveMemberCount) 运行中"
        }
        let active = swarm.activeWorkers.count
        if active > 0 {
            return "蜂群 · \(active) 位工人"
        }
        return "蜂群总控 · 待派单"
    }

    private func workerChip(_ worker: SwarmMember) -> some View {
        let memberStyle = store.style(for: worker.agentId)
        let dotColor = SwarmTheme.stateColor(for: worker, agentStyle: memberStyle)

        return Button {
            Haptics.selection()
            onSelectSession(worker.sessionId)
        } label: {
            HStack(spacing: 5) {
                if worker.isWorking {
                    PulseDot(color: dotColor, size: 5)
                } else {
                    Circle()
                        .fill(dotColor)
                        .frame(width: 6, height: 6)
                }
                Text("@\(worker.name)")
                    .font(RelayFont.mono(12, weight: .semibold))
                    .foregroundStyle(worker.isKilled ? Palette.textTertiary : Palette.textPrimary)
                    .strikethrough(worker.isKilled)
                if worker.usesWorktree {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(Palette.textTertiary)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(
                Capsule(style: .continuous)
                    .fill(worker.isWorking ? memberStyle.wash : Palette.fieldFill)
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(worker.isWorking ? memberStyle.tint.opacity(0.45) : Palette.hairline, lineWidth: 0.6)
            )
            .opacity(worker.isKilled ? 0.6 : 1)
        }
        .buttonStyle(.pressable)
    }

    // MARK: Worker perspective

    @ViewBuilder
    private var workerBar: some View {
        let memberName = currentSession.swarmMemberName ?? currentMember?.name ?? "worker"
        let branch = currentSession.worktreeBranch ?? currentMember?.worktreeBranch
        let memberStyle = store.style(for: currentSession.agentId)

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    if currentSession.isRunning || (currentMember?.isWorking ?? false) {
                        PulseDot(color: memberStyle.tint, size: 6)
                    } else {
                        Image(systemName: SwarmTheme.style.symbol)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(SwarmTheme.style.tint)
                    }
                    Text("蜂群成员 · @\(memberName)")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Palette.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer(minLength: 6)

                overviewButton

                Button {
                    Haptics.tap(.soft)
                    onSelectSession(swarm.coordinatorSessionId)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 10, weight: .bold))
                        Text("回总控")
                    }
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(SwarmTheme.style.tint)
                    .padding(.horizontal, 10)
                    .frame(height: 27)
                    .background(Capsule(style: .continuous).fill(SwarmTheme.style.wash))
                    .overlay(Capsule(style: .continuous).stroke(SwarmTheme.style.tint.opacity(0.35), lineWidth: 0.6))
                }
                .buttonStyle(.pressable)
            }

            if let branch, !branch.isEmpty {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 10, weight: .semibold))
                    Text(branch)
                        .font(RelayFont.mono(11, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .foregroundStyle(Palette.textSecondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(Capsule(style: .continuous).fill(Palette.fieldFill))
                .overlay(Capsule(style: .continuous).stroke(Palette.hairline, lineWidth: 0.5))
            }
        }
    }

    private var overviewButton: some View {
        Button {
            Haptics.tap()
            onOpenOverview()
        } label: {
            HStack(spacing: 4) {
                Text("总览")
                if swarm.headSeq > 0 {
                    Text("#\(swarm.headSeq)")
                        .font(RelayFont.mono(10.5, weight: .semibold))
                        .foregroundStyle(SwarmTheme.style.tint)
                }
            }
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(Palette.textPrimary)
            .padding(.horizontal, 10)
            .frame(height: 27)
            .background(Capsule(style: .continuous).fill(Palette.fieldFill))
            .overlay(Capsule(style: .continuous).stroke(Palette.hairlineStrong, lineWidth: 0.6))
        }
        .buttonStyle(.pressable)
    }
}
