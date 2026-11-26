import SwiftUI

/// Minimalist 4-column resonator roster strictly preserving KuroBBS gallery order:
/// avatar + top-right chain badge only, tapping pushes directly into `WuwaResonatorDetailView`.
struct WuwaRolesView: View {
    @Environment(WuwaStore.self) private var wuwa
    var onRequestLogin: () -> Void

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 4)

    var body: some View {
        ScrollView {
            if !wuwa.snapshot.loggedIn {
                loggedOutState
                    .padding(20)
            } else if wuwa.snapshot.resonators.isEmpty {
                emptyState
                    .padding(20)
            } else {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(wuwa.snapshot.resonators) { resonator in
                        NavigationLink(value: WuwaRoute.resonator(resonator.roleId)) {
                            ResonatorAvatarTile(resonator: resonator)
                        }
                        .buttonStyle(.pressable)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 28)
            }
        }
        .refreshable {
            await wuwa.refreshCommunity(forceDetails: true)
        }
    }

    private var loggedOutState: some View {
        VStack(spacing: 14) {
            Image(systemName: "person.2.crop.square.stack")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(Palette.textSecondary)
            Text("登录库街区查看角色")
                .font(RelayFont.display(20))
                .foregroundStyle(Palette.textPrimary)
            Text("同步国服角色面板、声骸评分、成长历史并解锁原生伤害计算实验室。")
                .font(.system(size: 13.5))
                .foregroundStyle(Palette.textSecondary)
                .multilineTextAlignment(.center)
            Button {
                Haptics.tap(.medium)
                onRequestLogin()
            } label: {
                Text("登录库街区")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(Color(hex: 0x2B93CF)))
            }
            .buttonStyle(.pressable)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 44)
        .padding(.horizontal, 20)
        .cardSurface()
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            if wuwa.isSyncing {
                ProgressView()
                Text("正在读取库街区角色图鉴…")
                    .font(.system(size: 13.5))
                    .foregroundStyle(Palette.textSecondary)
            } else {
                Text("尚未同步到角色数据")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Palette.textPrimary)
                Button("立即同步") {
                    Task { await wuwa.refreshCommunity(forceDetails: true) }
                }
                .font(.system(size: 13.5, weight: .semibold))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 44)
        .cardSurface()
    }
}

private struct ResonatorAvatarTile: View {
    var resonator: WuwaResonator

    var body: some View {
        let elColor = WuwaElementStyle.color(for: resonator.attributeName)
        let avatarURL = resonator.iconUrl.isEmpty ? resonator.pictureUrl : resonator.iconUrl

        ZStack(alignment: .topTrailing) {
            WuwaRemoteImage(
                urlString: avatarURL,
                fallbackText: resonator.name,
                tint: elColor,
                contentMode: .fill
            )
            .frame(maxWidth: .infinity)
            .aspectRatio(1, contentMode: .fill)
            .background(
                LinearGradient(
                    colors: [elColor.opacity(0.22), Palette.surfaceRaised],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Palette.hairline, lineWidth: 0.7)
            )

            Text("\(resonator.chainLevel)链")
                .font(.system(size: 10.5, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2.5)
                .background(
                    Capsule(style: .continuous)
                        .fill(chainBadgeColor(chain: resonator.chainLevel, elColor: elColor))
                )
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(Color.white.opacity(0.32), lineWidth: 0.5)
                )
                .padding(5)
        }
        .accessibilityLabel("\(resonator.name)，\(resonator.chainLevel)链")
    }

    private func chainBadgeColor(chain: Int, elColor: Color) -> Color {
        if chain >= 6 { return Color(hex: 0xC27C12).opacity(0.92) }
        if chain >= 1 { return elColor.opacity(0.88) }
        return Color.black.opacity(0.62)
    }
}
