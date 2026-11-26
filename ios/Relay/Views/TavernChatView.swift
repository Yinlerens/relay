import SwiftUI
import UIKit

// MARK: - Tavern chat view

struct TavernChatView: View {
    let characterId: Int

    @Environment(AppStore.self) private var store
    @State private var isSending = false
    @State private var isAtBottom = true
    @State private var userInteractedWithScroll = false
    @State private var showHistory = false
    @State private var editingMessage: TavernMessage? = nil
    @State private var deletingMessage: TavernMessage? = nil
    @State private var viewerImage: TavernImageItem? = nil
    @FocusState private var composerFocused: Bool
    @Namespace private var tavernImageNamespace

    private let bottomID = "tavern-bottom"

    private var draftBinding: Binding<String> {
        Binding(
            get: { store.tavernDraft(for: characterId) },
            set: { store.setTavernDraft($0, for: characterId) }
        )
    }

    private var state: TavernChatState? {
        guard let current = store.tavernState else { return nil }
        if let cid = current.character?.id, cid != characterId { return nil }
        return current
    }

    private var character: TavernCharacter? {
        state?.character ?? store.tavernCharacter(id: characterId)
    }

    private var characterName: String {
        character?.name ?? "酒馆角色"
    }

    private var chatDisplayName: String {
        let raw = state?.chatFile ?? character?.chat ?? ""
        let clean = raw.replacingOccurrences(of: ".jsonl", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? "当前对话" : clean
    }

    private var messages: [TavernMessage] {
        state?.messages ?? []
    }

    private var lastAssistantMesId: Int? {
        messages.last(where: { !$0.isUser && !$0.isSystem })?.mesId
    }

    private var isGenerating: Bool {
        store.isTavernGenerating
    }

    private var canSend: Bool {
        !isSending && !store.tavernDraft(for: characterId).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    if store.isLoadingTavernChat && messages.isEmpty {
                        VStack(spacing: 14) {
                            ProgressView()
                            Text("正在加载 \(characterName) 的历史对话…")
                                .font(.system(size: 13.5))
                                .foregroundStyle(Palette.textSecondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 96)
                    } else if messages.isEmpty {
                        emptyChatView
                            .padding(.top, 54)
                    }

                    if state?.hasMore == true && !messages.isEmpty {
                        loadOlderButton
                    }

                    ForEach(messages) { message in
                        TavernMessageRow(
                            message: message,
                            isLastAssistant: message.mesId == lastAssistantMesId,
                            variablesJSON: store.tavernVariablesJSON,
                            imageNamespace: tavernImageNamespace,
                            onOpenImage: { item in viewerImage = item },
                            onEdit: { editingMessage = message },
                            onDelete: { deletingMessage = message },
                            onSwipe: { dir in
                                Task { await store.swipeTavern(mesId: message.mesId, direction: dir) }
                            },
                            onRegenerate: {
                                Task { await store.regenerateTavern() }
                            },
                            onContinue: {
                                Task { await store.continueTavern() }
                            },
                            onSlash: { cmd in
                                Task { await store.runTavernSlash(cmd) }
                            },
                            onSendFromCard: { text in
                                Haptics.tap(.medium)
                                Task { await store.sendTavernMessage(text: text) }
                            },
                            onFillDraft: { text in
                                store.setTavernDraft(text, for: characterId)
                                Haptics.selection()
                                composerFocused = true
                            }
                        )
                        .id(message.mesId)
                    }

                    if isGenerating && (messages.last?.isUser == true || messages.last?.isStreaming != true) {
                        pendingAssistantRow
                            .transition(.opacity)
                    } else if let genErr = store.tavernGenerationError,
                              (genErr.characterId == nil || genErr.characterId == characterId) {
                        generationErrorCard(genErr)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    } else if !isGenerating && messages.last?.isUser == true {
                        orphanRetryRow
                            .transition(.opacity)
                    }

                    Color.clear
                        .frame(height: 1)
                        .id(bottomID)
                }
                .padding(.horizontal, 18)
                .padding(.top, 14)
                .padding(.bottom, 10)
                .frame(maxWidth: 780)
                .frame(maxWidth: .infinity)
                .scrollTargetLayout()
            }
            .scrollEdgeEffectStyle(.soft, for: .all)
            .scrollDismissesKeyboard(.interactively)
            .onScrollPhaseChange { _, phase in
                if phase == .interacting {
                    userInteractedWithScroll = true
                }
            }
            .onScrollGeometryChange(for: Bool.self) { geo in
                geo.visibleRect.maxY >= geo.contentSize.height - 90
            } action: { _, atBottom in
                if atBottom != isAtBottom {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        isAtBottom = atBottom
                    }
                }
            }
            .onAppear {
                userInteractedWithScroll = false
                isAtBottom = true
                if !messages.isEmpty {
                    scrollToBottom(proxy)
                }
            }
            .task(id: characterId) {
                for delayMs in [0, 120, 220] {
                    if delayMs > 0 {
                        try? await Task.sleep(for: .milliseconds(delayMs))
                    } else {
                        await Task.yield()
                    }
                    guard !Task.isCancelled, !userInteractedWithScroll, isAtBottom, !messages.isEmpty else {
                        return
                    }
                    scrollToBottom(proxy)
                }
            }
            .onChange(of: messages.last?.mesId) { oldLast, newLast in
                guard newLast != nil else { return }
                scrollToBottom(proxy, animated: oldLast != nil)
            }
            .onChange(of: isGenerating) { _, active in
                if active && isAtBottom {
                    scrollToBottom(proxy, animated: true)
                }
            }
            .onChange(of: store.tavernGenerationError) { _, err in
                if err != nil && isAtBottom {
                    scrollToBottom(proxy, animated: true)
                }
            }
            .onChange(of: streamSignature) { _, _ in
                if isAtBottom {
                    proxy.scrollTo(bottomID, anchor: .bottom)
                }
            }
            .overlay(alignment: .bottom) {
                if !isAtBottom && !messages.isEmpty {
                    ScrollToBottomPill(isStreaming: isGenerating, tint: TavernTheme.tint) {
                        Haptics.tap(.soft)
                        scrollToBottom(proxy, animated: true)
                    }
                    .padding(.bottom, 12)
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                composerBar
            }
        }
        .background(AmbientBackground(tint: TavernTheme.glow))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Button {
                    Haptics.tap()
                    showHistory = true
                } label: {
                    VStack(spacing: 1) {
                        Text(characterName)
                            .font(.system(size: 15.5, weight: .semibold))
                            .foregroundStyle(Palette.textPrimary)
                            .lineLimit(1)
                        HStack(spacing: 4) {
                            Circle()
                                .fill(TavernTheme.tint)
                                .frame(width: 5, height: 5)
                            Text(chatDisplayName)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 8, weight: .bold))
                        }
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Palette.textSecondary)
                    }
                    .frame(maxWidth: 230)
                }
                .buttonStyle(.plain)
                .accessibilityHint("切换历史聊天或新建对话")
            }

            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    Haptics.tap()
                    showHistory = true
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                }
                .accessibilityLabel("历史聊天")

                Menu {
                    Button {
                        Task { await store.regenerateTavern() }
                    } label: {
                        Label("重新生成", systemImage: "arrow.clockwise")
                    }
                    .disabled(isGenerating || messages.isEmpty)

                    Button {
                        Task { await store.continueTavern() }
                    } label: {
                        Label("继续生成", systemImage: "text.append")
                    }
                    .disabled(isGenerating || messages.isEmpty)

                    Divider()

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
                } label: {
                    if store.isReloadingTavern {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "ellipsis.circle")
                    }
                }
                .accessibilityLabel("酒馆操作")
            }
        }
        .sheet(isPresented: $showHistory) {
            TavernChatHistorySheet(
                characterId: characterId,
                characterName: characterName,
                currentChatFile: state?.chatFile
            )
        }
        .sheet(item: $editingMessage) { msg in
            TavernEditMessageSheet(message: msg)
        }
        .fullScreenCover(item: $viewerImage) { item in
            TavernImageViewer(item: item)
                .navigationTransition(.zoom(sourceID: item.sourceId, in: tavernImageNamespace))
        }
        .confirmationDialog(
            "删除第 #\(deletingMessage?.mesId ?? 0) 楼？",
            isPresented: Binding(
                get: { deletingMessage != nil },
                set: { if !$0 { deletingMessage = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除楼层", role: .destructive) {
                if let target = deletingMessage {
                    deletingMessage = nil
                    Task { await store.deleteTavernMessage(mesId: target.mesId) }
                }
            }
            Button("取消", role: .cancel) { deletingMessage = nil }
        } message: {
            Text("该操作将直接同步到 SillyTavern 原版聊天记录且无法撤销。")
        }
        .task(id: characterId) {
            store.activeTavernCharacterId = characterId
            await store.selectTavernCharacter(id: characterId)
        }
        .onDisappear {
            if store.activeTavernCharacterId == characterId {
                store.activeTavernCharacterId = nil
            }
        }
    }

    private var streamSignature: Int {
        guard let last = messages.last else { return 0 }
        return last.rawText.utf8.count &+ last.reasoning.utf8.count &* 31 &+ last.renderedHash.hashValue
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = false) {
        let perform = {
            if let lastMesId = messages.last?.mesId,
               !isGenerating,
               store.tavernGenerationError == nil,
               messages.last?.isUser != true {
                proxy.scrollTo(lastMesId, anchor: .bottom)
            }
            proxy.scrollTo(bottomID, anchor: .bottom)
        }
        if animated {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.9), perform)
        } else {
            perform()
        }
    }

    private var pendingAssistantRow: some View {
        let avatar = messages.last(where: { !$0.isUser && !$0.isSystem })?.avatarUrl ?? character?.avatarUrl
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                TavernAssetImageView(pathOrUrl: avatar, fallbackText: characterName)
                    .frame(width: 28, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .stroke(Palette.hairline, lineWidth: 0.6)
                    )
                Text(characterName)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Palette.textSecondary)
                Spacer(minLength: 4)
                PulseDot(color: TavernTheme.tint, size: 5)
            }
            HStack(spacing: 8) {
                TypingDots(color: TavernTheme.tint)
                Text("正在等待回复…")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.textSecondary)
            }
            .padding(.vertical, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func generationErrorCard(_ err: TavernGenerationError) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Palette.danger)
                Text(err.badgeTitle)
                    .font(.system(size: 11.5, weight: .bold))
                    .foregroundStyle(Palette.danger)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Palette.danger.opacity(0.13)))
                if let date = err.occurredDate {
                    Text(RelayFormat.relative(date))
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.textTertiary)
                }
                Spacer(minLength: 4)
                Button {
                    Task { await store.clearTavernGenerationError() }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Palette.textTertiary)
                        .padding(6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭错误提示")
            }

            Text(err.message)
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(Palette.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button {
                    Haptics.tap(.medium)
                    Task { await store.regenerateTavern() }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11.5, weight: .bold))
                        Text("重试生成")
                    }
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(TavernTheme.gradient))
                }
                .buttonStyle(.pressable)

                Button {
                    UIPasteboard.general.string = err.message
                    Haptics.success()
                    store.showBanner("已复制报错内容", isError: false)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 11, weight: .medium))
                        Text("复制报错")
                    }
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Palette.textSecondary)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Palette.fieldFill))
                    .overlay(Capsule().stroke(Palette.hairline, lineWidth: 0.6))
                }
                .buttonStyle(.pressable)
            }
        }
        .padding(14)
        .cardSurface(radius: 16)
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Palette.danger.opacity(0.35), lineWidth: 0.8)
        )
    }

    private var orphanRetryRow: some View {
        HStack {
            Spacer()
            Button {
                Haptics.tap(.soft)
                Task { await store.regenerateTavern() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                    Text("尚未收到回复 · 点击重新生成")
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Palette.textSecondary)
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
                .background(Capsule().fill(Palette.fieldFill))
                .overlay(Capsule().stroke(Palette.hairline, lineWidth: 0.6))
            }
            .buttonStyle(.pressable)
        }
    }

    private var loadOlderButton: some View {
        let total = state?.totalMessageCount ?? 0
        let label = total > 0 ? "加载更早消息（共 \(total) 楼）" : "加载更早消息"
        return HStack {
            Spacer()
            Button {
                Haptics.tap(.soft)
                Task { await store.loadOlderTavernMessages() }
            } label: {
                HStack(spacing: 7) {
                    if store.isLoadingOlderTavernMessages {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.up.circle")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    Text(store.isLoadingOlderTavernMessages ? "正在加载…" : label)
                        .font(.system(size: 12.5, weight: .semibold))
                }
                .foregroundStyle(TavernTheme.tint)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.capsule)
            .tint(TavernTheme.tint)
            .disabled(store.isLoadingOlderTavernMessages)
            Spacer()
        }
        .padding(.bottom, 4)
    }

    // MARK: Empty state

    private var emptyChatView: some View {
        VStack(spacing: 18) {
            TavernAssetImageView(
                pathOrUrl: character?.avatarUrl,
                fallbackText: characterName
            )
            .frame(width: 78, height: 78)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(TavernTheme.tint.opacity(0.35), lineWidth: 1)
            )
            .shadow(color: TavernTheme.glow.opacity(0.28), radius: 14, y: 6)

            VStack(spacing: 6) {
                Text(characterName)
                    .font(RelayFont.display(25))
                    .foregroundStyle(Palette.textPrimary)
                if let tagline = character?.tagline, !tagline.isEmpty {
                    Text(tagline)
                        .font(.system(size: 13.5))
                        .foregroundStyle(Palette.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Bottom Liquid Glass composer

    private var composerBar: some View {
        let active = isGenerating || canSend
        return GlassGroup(spacing: 10) {
            HStack(alignment: .bottom, spacing: 8) {
                TextField("对 \(characterName) 说点什么…", text: draftBinding, axis: .vertical)
                    .font(RelayFont.body)
                    .lineLimit(1...6)
                    .focused($composerFocused)
                    .padding(.leading, 12)
                    .padding(.vertical, 9)
                    .tint(TavernTheme.tint)

                Button {
                    primaryAction()
                } label: {
                    ZStack {
                        if isGenerating {
                            Circle().fill(Palette.textPrimary)
                        } else if canSend {
                            Circle().fill(TavernTheme.gradient)
                        } else {
                            Circle().fill(Palette.fieldFill)
                        }
                        if isSending && !isGenerating {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.white)
                        } else {
                            Image(systemName: isGenerating ? "stop.fill" : "arrow.up")
                                .font(.system(size: isGenerating ? 13 : 16, weight: .bold))
                                .foregroundStyle(isGenerating ? Palette.canvas : (canSend ? Color.white : Palette.textTertiary))
                                .contentTransition(.symbolEffect(.replace))
                        }
                    }
                    .frame(width: 36, height: 36)
                    .shadow(color: canSend && !isGenerating ? TavernTheme.glow.opacity(0.45) : .clear, radius: 8, y: 3)
                    .scaleEffect(active ? 1 : 0.92)
                }
                .buttonStyle(.pressable)
                .disabled(!active)
                .animation(.spring(response: 0.32, dampingFraction: 0.68), value: isGenerating)
                .animation(.spring(response: 0.32, dampingFraction: 0.68), value: canSend)
                .accessibilityLabel(isGenerating ? "停止生成" : "发送")
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 6)
            .glassRounded(26, tint: composerFocused ? TavernTheme.glow : nil)
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .animation(.easeInOut(duration: 0.2), value: composerFocused)
    }

    private func primaryAction() {
        if isGenerating {
            Task { await store.stopTavernGeneration() }
            return
        }
        guard canSend else { return }
        let outgoing = store.tavernDraft(for: characterId)
        store.setTavernDraft("", for: characterId)
        isSending = true
        Task {
            let ok = await store.sendTavernMessage(text: outgoing)
            isSending = false
            if !ok && store.tavernDraft(for: characterId).isEmpty {
                store.setTavernDraft(outgoing, for: characterId)
            }
        }
    }
}
