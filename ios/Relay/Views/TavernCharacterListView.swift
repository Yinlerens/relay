import SwiftUI

// MARK: - Tavern signature aesthetic

enum TavernTheme {
    /// Warm literary rose-amber accent that feels distinct from Agent indigo/emerald yet native to Relay.
    static let tint = Color.adaptive(light: 0xA84B6E, dark: 0xE68FB2)
    static let wash = Color.adaptive(light: 0xA84B6E, dark: 0xE68FB2, lightAlpha: 0.10, darkAlpha: 0.15)
    static let glow = Color(hex: 0xC95C87)

    static let gradient = LinearGradient(
        colors: [Color(hex: 0xF0A6C4), Color(hex: 0xB9527B), Color(hex: 0x6F3A68)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let markdownStyle = AgentStyle(family: .amber, symbol: "book.closed.fill")
}

// MARK: - Tavern character list (used inside SessionListView when HomeSection == .tavern)

struct TavernCharacterListView<Header: View>: View {
    let search: String
    @ViewBuilder var header: () -> Header
    var onSelectCharacter: (Int) -> Void

    @Environment(AppStore.self) private var store
    @State private var handle = ""
    @State private var password = ""
    @State private var revealPassword = false

    private var filteredCharacters: [TavernCharacter] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return store.tavernCharacters }
        return store.tavernCharacters.filter { c in
            c.name.lowercased().contains(query)
                || c.tagline.lowercased().contains(query)
                || (c.chat?.lowercased().contains(query) ?? false)
                || c.tags.contains(where: { $0.lowercased().contains(query) })
        }
    }

    var body: some View {
        List {
            header()
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 10, trailing: 20))

            if let status = store.tavernStatus {
                if !status.enabled {
                    disabledState
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                } else if status.needsLogin {
                    loginCard
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 12, leading: 20, bottom: 20, trailing: 20))
                } else if !status.ready {
                    startingState(status)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                } else {
                    readyContent
                }
            } else if let error = store.tavernError {
                errorState(error)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            } else {
                loadingState
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            Color.clear
                .frame(height: 36)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .refreshable {
            await store.loadTavernOverview()
        }
        .task {
            if store.tavernStatus == nil || (store.tavernStatus?.ready == true && store.tavernCharacters.isEmpty) {
                await store.loadTavernOverview()
            }
            if handle.isEmpty, let first = store.tavernLoginUsers.first {
                handle = first.handle
            }
        }
        .onChange(of: store.tavernLoginUsers) { _, users in
            if handle.isEmpty, let first = users.first {
                handle = first.handle
            }
        }
    }

    // MARK: Ready character rows

    @ViewBuilder
    private var readyContent: some View {
        if store.tavernCharacters.isEmpty && store.isLoadingTavern {
            loadingState
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        } else if store.tavernCharacters.isEmpty {
            emptyCharactersState
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        } else {
            Section {
                ForEach(filteredCharacters) { character in
                    let isCurrent = store.tavernStatus?.currentCharacterId == character.id
                    let isGenerating = isCurrent && store.isTavernGenerating
                    Button {
                        Haptics.tap(.soft)
                        onSelectCharacter(character.id)
                    } label: {
                        TavernCharacterRow(
                            character: character,
                            isCurrent: isCurrent,
                            isGenerating: isGenerating
                        )
                    }
                    .buttonStyle(.pressable)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 7, leading: 20, bottom: 7, trailing: 20))
                    .listRowSeparatorTint(Palette.hairline)
                    .alignmentGuide(.listRowSeparatorLeading) { _ in 72 }
                }
            } header: {
                Eyebrow(text: "角色卡 · \(filteredCharacters.count)")
                    .padding(.leading, 4)
                    .padding(.top, 6)
            }
            .listSectionSeparator(.hidden)

            if !search.isEmpty && filteredCharacters.isEmpty {
                Text("没有找到「\(search)」相关的角色")
                    .font(.system(size: 14))
                    .foregroundStyle(Palette.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 30)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
        }
    }

    // MARK: Login card

    private var loginCard: some View {
        let shape = RoundedRectangle(cornerRadius: 26, style: .continuous)
        let canLogin = !handle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !store.isLoggingInTavern

        return VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(TavernTheme.gradient)
                    Image(systemName: "book.pages.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 46, height: 46)
                .shadow(color: TavernTheme.glow.opacity(0.35), radius: 10, y: 4)

                VStack(alignment: .leading, spacing: 3) {
                    Text("登录你的 SillyTavern")
                        .font(RelayFont.display(20))
                        .foregroundStyle(Palette.textPrimary)
                    Text("凭证以 AES-256-GCM 加密保存在 140 本机")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Palette.textSecondary)
                }
            }

            if !store.tavernLoginUsers.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Eyebrow(text: "选择账号")
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(store.tavernLoginUsers) { user in
                                let selected = handle == user.handle
                                Button {
                                    handle = user.handle
                                    Haptics.selection()
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: selected ? "checkmark.circle.fill" : "person.circle")
                                            .font(.system(size: 13, weight: .semibold))
                                        Text(user.name)
                                            .font(.system(size: 13.5, weight: .semibold))
                                    }
                                    .foregroundStyle(selected ? TavernTheme.tint : Palette.textSecondary)
                                    .padding(.horizontal, 12)
                                    .frame(height: 34)
                                    .background(Capsule().fill(selected ? TavernTheme.wash : Palette.fieldFill))
                                    .overlay(Capsule().stroke(selected ? TavernTheme.tint.opacity(0.5) : Palette.hairline, lineWidth: 0.7))
                                }
                                .buttonStyle(.pressable)
                            }
                        }
                    }
                }
            }

            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Image(systemName: "person")
                        .foregroundStyle(TavernTheme.tint)
                        .frame(width: 20)
                    TextField("用户名 / Handle", text: $handle)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(size: 15.5))
                }
                .padding(.horizontal, 14)
                .frame(height: 48)

                Divider().overlay(Palette.hairline).padding(.leading, 46)

                HStack(spacing: 12) {
                    Image(systemName: "key.horizontal")
                        .foregroundStyle(TavernTheme.tint)
                        .frame(width: 20)
                    Group {
                        if revealPassword {
                            TextField("密码（若未设置可留空）", text: $password)
                        } else {
                            SecureField("密码（若未设置可留空）", text: $password)
                        }
                    }
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(size: 15.5))

                    Button {
                        revealPassword.toggle()
                        Haptics.selection()
                    } label: {
                        Image(systemName: revealPassword ? "eye.slash" : "eye")
                            .font(.system(size: 14))
                            .foregroundStyle(Palette.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 14)
                .frame(height: 48)
            }
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Palette.fieldFill))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Palette.hairline, lineWidth: 0.6))

            if let err = store.tavernStatus?.lastError, !err.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill")
                    Text(err)
                }
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Palette.danger)
            }

            Button {
                let h = handle
                let p = password
                Task {
                    let ok = await store.loginTavern(handle: h, password: p)
                    if ok { password = "" }
                }
            } label: {
                HStack(spacing: 8) {
                    if store.isLoggingInTavern {
                        ProgressView().tint(.white)
                        Text("正在登录无头酒馆…")
                    } else {
                        Image(systemName: "arrow.right.circle.fill")
                        Text("登录酒馆")
                    }
                }
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(Capsule(style: .continuous).fill(TavernTheme.gradient))
                .shadow(color: TavernTheme.glow.opacity(0.38), radius: 14, y: 6)
                .opacity(canLogin ? 1 : 0.45)
            }
            .buttonStyle(.pressable)
            .disabled(!canLogin)
        }
        .padding(20)
        .background {
            ZStack {
                shape.fill(Palette.surface)
                RadialGradient(
                    colors: [TavernTheme.glow.opacity(0.18), .clear],
                    center: .topLeading,
                    startRadius: 4,
                    endRadius: 280
                )
                .clipShape(shape)
            }
        }
        .overlay(shape.stroke(TavernTheme.tint.opacity(0.26), lineWidth: 0.7))
        .shadow(color: .black.opacity(0.08), radius: 16, y: 8)
    }

    // MARK: Empty / Starting / Error states

    private var loadingState: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.regular)
            Text("正在连接酒馆…")
                .font(.system(size: 14.5, weight: .medium))
                .foregroundStyle(Palette.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 64)
    }

    private func startingState(_ status: TavernStatus) -> some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(TavernTheme.wash)
                    .frame(width: 82, height: 82)
                ProgressView()
                    .tint(TavernTheme.tint)
            }
            Text("酒馆无头引擎启动中")
                .font(RelayFont.display(20))
                .foregroundStyle(Palette.textPrimary)
            Text(status.lastError ?? "首次加载 SillyTavern 与扩展脚本通常需要数秒，请稍候。")
                .font(.system(size: 13.5))
                .foregroundStyle(Palette.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
            Button {
                Haptics.tap()
                Task { await store.loadTavernOverview() }
            } label: {
                Text("重新检查")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(TavernTheme.tint)
                    .padding(.horizontal, 22)
                    .frame(height: 40)
                    .glassCapsule(interactive: true, tint: TavernTheme.glow)
            }
            .buttonStyle(.pressable)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }

    private var emptyCharactersState: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(TavernTheme.wash)
                    .frame(width: 86, height: 86)
                Image(systemName: "person.2.slash")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(TavernTheme.tint)
            }
            Text("还没有角色卡")
                .font(RelayFont.display(21))
                .foregroundStyle(Palette.textPrimary)
            Text("在原版 SillyTavern 导入角色卡后，点右上角「同步原版配置」即可出现。")
                .font(.system(size: 14))
                .foregroundStyle(Palette.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 54)
    }

    private var disabledState: some View {
        VStack(spacing: 12) {
            Image(systemName: "moon.zzz")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(Palette.textTertiary)
            Text("酒馆桥接未启用")
                .font(RelayFont.display(20))
                .foregroundStyle(Palette.textPrimary)
            Text("请在服务端启用 TAVERN_ENABLED 后重试。")
                .font(.system(size: 13.5))
                .foregroundStyle(Palette.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.icloud")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Palette.textTertiary)
            Text("无法连接酒馆桥接")
                .font(RelayFont.display(19))
                .foregroundStyle(Palette.textPrimary)
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(Palette.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
            Button {
                Haptics.tap()
                Task { await store.loadTavernOverview() }
            } label: {
                Text("重试")
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(Palette.textPrimary)
                    .padding(.horizontal, 24)
                    .frame(height: 40)
                    .glassCapsule(interactive: true)
            }
            .buttonStyle(.pressable)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 52)
    }
}

// MARK: - Character row

struct TavernCharacterRow: View {
    let character: TavernCharacter
    let isCurrent: Bool
    let isGenerating: Bool

    private var subtitleText: String {
        if let chat = character.chat, !chat.isEmpty {
            let clean = chat.replacingOccurrences(of: ".jsonl", with: "")
            return clean
        }
        if !character.tagline.isEmpty {
            return character.tagline
        }
        return "点击开始对话"
    }

    var body: some View {
        HStack(spacing: 14) {
            ZStack(alignment: .bottomTrailing) {
                TavernAssetImageView(
                    pathOrUrl: character.avatarUrl,
                    fallbackText: character.name,
                    fallbackSymbol: "person.fill"
                )
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(isCurrent ? TavernTheme.tint.opacity(0.6) : Palette.hairline, lineWidth: isCurrent ? 1.3 : 0.6)
                )
                .shadow(color: .black.opacity(0.14), radius: 8, y: 3)

                if isGenerating {
                    PulseDot(color: TavernTheme.tint, size: 7)
                        .offset(x: 5, y: 5)
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(character.name)
                        .font(.system(size: 16.5, weight: .semibold))
                        .foregroundStyle(Palette.textPrimary)
                        .lineLimit(1)
                    if isCurrent {
                        Text(isGenerating ? "生成中" : "当前")
                            .font(.system(size: 10.5, weight: .bold))
                            .foregroundStyle(TavernTheme.tint)
                            .padding(.horizontal, 6.5)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(TavernTheme.wash))
                    }
                    Spacer(minLength: 6)
                    if let date = character.lastChatDate {
                        Text(RelayFormat.relative(date))
                            .font(.system(size: 12, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(Palette.textTertiary)
                    }
                }

                Text(subtitleText)
                    .font(.system(size: 13.5))
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if !character.tags.isEmpty {
                    HStack(spacing: 5) {
                        ForEach(character.tags.prefix(3), id: \.self) { tag in
                            Text(tag)
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(Palette.textTertiary)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Palette.fieldFill))
                                .lineLimit(1)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
    }
}
