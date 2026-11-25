import SwiftUI
import UIKit

private struct TavernBottomSentinelKey: PreferenceKey {
    static let defaultValue: CGFloat = .infinity
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = min(value, nextValue())
    }
}

// MARK: - Streaming <think> / <thought> splitter

enum TavernTextSplitter {
    private static let closedTagRegex = try? NSRegularExpression(
        pattern: "<(think|thought|thinking)>([\\s\\S]*?)</\\1>",
        options: [.caseInsensitive]
    )
    private static let openTagRegex = try? NSRegularExpression(
        pattern: "<(think|thought|thinking)>([\\s\\S]*)$",
        options: [.caseInsensitive]
    )

    static func split(rawText: String, explicitReasoning: String, isStreaming: Bool) -> (reasoning: String, visible: String) {
        var reasoningParts: [String] = []
        let trimmedExplicit = explicitReasoning.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedExplicit.isEmpty {
            reasoningParts.append(trimmedExplicit)
        }

        var working = rawText
        if let regex = closedTagRegex {
            let ns = working as NSString
            let matches = regex.matches(in: working, options: [], range: NSRange(location: 0, length: ns.length))
            if !matches.isEmpty {
                for match in matches {
                    if match.numberOfRanges > 2 {
                        let inner = ns.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
                        if !inner.isEmpty && !reasoningParts.contains(inner) {
                            reasoningParts.append(inner)
                        }
                    }
                }
                working = regex.stringByReplacingMatches(
                    in: working,
                    options: [],
                    range: NSRange(location: 0, length: ns.length),
                    withTemplate: ""
                )
            }
        }

        if isStreaming, let openRegex = openTagRegex {
            let ns = working as NSString
            if let match = openRegex.firstMatch(in: working, options: [], range: NSRange(location: 0, length: ns.length)) {
                if match.numberOfRanges > 2 {
                    let inner = ns.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !inner.isEmpty && !reasoningParts.contains(inner) {
                        reasoningParts.append(inner)
                    }
                }
                working = ns.substring(to: match.range.location)
            }
        }

        return (
            reasoning: reasoningParts.joined(separator: "\n\n"),
            visible: working.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}

// MARK: - Tavern chat view

struct TavernChatView: View {
    let characterId: Int

    @Environment(AppStore.self) private var store
    @State private var draft = ""
    @State private var isSending = false
    @State private var isAtBottom = true
    @State private var viewportHeight: CGFloat = 0
    @State private var showHistory = false
    @State private var editingMessage: TavernMessage? = nil
    @State private var deletingMessage: TavernMessage? = nil
    @State private var viewerImage: TavernImageItem? = nil
    @FocusState private var composerFocused: Bool

    private let bottomID = "tavern-bottom"

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
        !isSending && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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

                    ForEach(messages) { message in
                        TavernMessageRow(
                            message: message,
                            isLastAssistant: message.mesId == lastAssistantMesId,
                            variablesJSON: store.tavernVariablesJSON,
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
                                Task { await store.sendTavernMessage(text: text) }
                            }
                        )
                        .id(message.mesId)
                    }

                    Color.clear
                        .frame(height: 1)
                        .id(bottomID)
                        .background(
                            GeometryReader { geo in
                                Color.clear.preference(
                                    key: TavernBottomSentinelKey.self,
                                    value: geo.frame(in: .named("tavern-scroll")).minY
                                )
                            }
                        )
                }
                .padding(.horizontal, 18)
                .padding(.top, 14)
                .padding(.bottom, 10)
                .frame(maxWidth: 780)
                .frame(maxWidth: .infinity)
            }
            .coordinateSpace(name: "tavern-scroll")
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { viewportHeight = geo.size.height }
                        .onChange(of: geo.size.height) { _, h in viewportHeight = h }
                }
            )
            .onPreferenceChange(TavernBottomSentinelKey.self) { minY in
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
            .onChange(of: streamSignature) { _, _ in
                if isAtBottom {
                    proxy.scrollTo(bottomID, anchor: .bottom)
                }
            }
            .overlay(alignment: .bottom) {
                if !isAtBottom && !messages.isEmpty {
                    ScrollToBottomPill(isStreaming: isGenerating, tint: TavernTheme.tint) {
                        Haptics.tap(.soft)
                        withAnimation(.spring(response: 0.5, dampingFraction: 0.88)) {
                            proxy.scrollTo(bottomID, anchor: .bottom)
                        }
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
                TextField("对 \(characterName) 说点什么…", text: $draft, axis: .vertical)
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
        let outgoing = draft
        draft = ""
        isSending = true
        Task {
            let ok = await store.sendTavernMessage(text: outgoing)
            isSending = false
            if !ok { draft = outgoing }
        }
    }
}

// MARK: - Tavern message row

struct TavernMessageRow: View {
    let message: TavernMessage
    let isLastAssistant: Bool
    let variablesJSON: String
    var onOpenImage: (TavernImageItem) -> Void
    var onEdit: () -> Void
    var onDelete: () -> Void
    var onSwipe: (TavernSwipeDirection) -> Void
    var onRegenerate: () -> Void
    var onContinue: () -> Void
    var onSlash: (String) -> Void
    var onSendFromCard: (String) -> Void

    @Environment(AppStore.self) private var store
    @State private var copied = false

    var body: some View {
        Group {
            if message.isSystem {
                systemRow
            } else if message.isUser {
                userRow
            } else {
                characterRow
            }
        }
        .contextMenu {
            Button(action: onEdit) {
                Label("编辑楼层", systemImage: "pencil")
            }
            Button {
                UIPasteboard.general.string = message.rawText
                Haptics.success()
            } label: {
                Label("拷贝原文", systemImage: "doc.on.doc")
            }
            Divider()
            Button(role: .destructive, action: onDelete) {
                Label("删除楼层", systemImage: "trash")
            }
        }
    }

    // MARK: System message

    private var systemRow: some View {
        VStack(spacing: 6) {
            Text(message.rawText)
                .font(.system(size: 13))
                .foregroundStyle(Palette.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .cardSurface(radius: 14)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: User message

    private var userRow: some View {
        VStack(alignment: .trailing, spacing: 6) {
            Text(message.rawText)
                .font(RelayFont.body)
                .lineSpacing(3.5)
                .foregroundStyle(Palette.textPrimary)
                .padding(.horizontal, 15)
                .padding(.vertical, 11)
                .background(
                    UnevenRoundedRectangle(
                        topLeadingRadius: 20,
                        bottomLeadingRadius: 20,
                        bottomTrailingRadius: 6,
                        topTrailingRadius: 20,
                        style: .continuous
                    )
                    .fill(TavernTheme.wash)
                )
                .overlay(
                    UnevenRoundedRectangle(
                        topLeadingRadius: 20,
                        bottomLeadingRadius: 20,
                        bottomTrailingRadius: 6,
                        topTrailingRadius: 20,
                        style: .continuous
                    )
                    .stroke(TavernTheme.tint.opacity(0.24), lineWidth: 0.6)
                )
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, 44)
    }

    // MARK: Character message (hybrid block rendering)

    private var characterRow: some View {
        let parsed = TavernTextSplitter.split(
            rawText: message.rawText,
            explicitReasoning: message.reasoning,
            isStreaming: message.isStreaming
        )
        let isThinkingPhase = message.isStreaming && parsed.visible.isEmpty && !parsed.reasoning.isEmpty

        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                TavernAssetImageView(
                    pathOrUrl: message.avatarUrl,
                    fallbackText: message.name
                )
                .frame(width: 28, height: 28)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(Palette.hairline, lineWidth: 0.6)
                )

                Text(message.name)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Palette.textSecondary)

                if !message.sendDate.isEmpty {
                    Text(message.sendDate)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.textTertiary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                if message.isStreaming {
                    PulseDot(color: TavernTheme.tint, size: 5)
                }
            }

            if !parsed.reasoning.isEmpty {
                ThinkingCapsule(
                    text: parsed.reasoning,
                    isActive: isThinkingPhase,
                    style: TavernTheme.markdownStyle
                )
            }

            if message.isStreaming || message.blocks.isEmpty {
                if !parsed.visible.isEmpty {
                    MarkdownView(
                        text: parsed.visible,
                        style: TavernTheme.markdownStyle,
                        isStreaming: message.isStreaming
                    )
                } else if message.isStreaming && parsed.reasoning.isEmpty {
                    TypingDots(color: TavernTheme.tint)
                        .padding(.vertical, 6)
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(message.blocks) { block in
                        renderBlock(block)
                    }
                }
            }

            if isLastAssistant && !message.isStreaming {
                lastAssistantActionBar
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func renderBlock(_ block: TavernRenderBlock) -> some View {
        switch block.kind {
        case "markdown":
            if let md = block.markdown, !md.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                MarkdownView(text: md, style: TavernTheme.markdownStyle, isStreaming: false)
            }

        case "details":
            TavernDetailsCard(
                summary: block.summary ?? "展开详情",
                markdown: block.markdown ?? ""
            )

        case "image":
            if let url = block.imageUrl, !url.isEmpty {
                Button {
                    Haptics.tap(.soft)
                    onOpenImage(TavernImageItem(url: url, alt: block.imageAlt ?? ""))
                } label: {
                    TavernAssetImageView(
                        pathOrUrl: url,
                        fallbackSymbol: "photo",
                        contentMode: .fit
                    )
                    .frame(maxWidth: .infinity)
                    .frame(maxHeight: 380)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Palette.hairline, lineWidth: 0.6)
                    )
                }
                .buttonStyle(.pressable)
            }

        case "html", "iframe":
            if let html = block.html, !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                TavernHTMLCardView(
                    blockId: block.id,
                    renderedHash: message.renderedHash,
                    html: html,
                    estimatedHeight: block.estimatedHeight,
                    variablesJSON: variablesJSON,
                    isIframe: block.kind == "iframe",
                    onSlash: onSlash,
                    onSend: onSendFromCard
                )
            }

        default:
            if let md = block.markdown, !md.isEmpty {
                MarkdownView(text: md, style: TavernTheme.markdownStyle, isStreaming: false)
            }
        }
    }

    // MARK: Swipe & actions footer

    private var lastAssistantActionBar: some View {
        let total = max(1, message.swipeCount)
        let current = min(max(0, message.swipeId), total - 1)
        let hasPrev = current > 0
        let hasNext = current + 1 < total
        let busy = store.isMutatingTavern || store.isTavernGenerating

        return HStack(spacing: 10) {
            HStack(spacing: 2) {
                Button {
                    onSwipe(.left)
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(hasPrev ? Palette.textPrimary : Palette.textTertiary.opacity(0.45))
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!hasPrev || busy)
                .accessibilityLabel("上一条候选回复")

                Text("\(current + 1) / \(total)")
                    .font(RelayFont.mono(11.5, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Palette.textSecondary)
                    .padding(.horizontal, 4)

                Button {
                    onSwipe(hasNext ? .right : .new)
                } label: {
                    Image(systemName: hasNext ? "chevron.right" : "plus")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(hasNext ? Palette.textPrimary : TavernTheme.tint)
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(busy)
                .accessibilityLabel(hasNext ? "下一条候选回复" : "生成新候选回复")
            }
            .padding(.horizontal, 4)
            .background(Capsule(style: .continuous).fill(Palette.fieldFill))
            .overlay(Capsule(style: .continuous).stroke(Palette.hairline, lineWidth: 0.6))

            actionIconButton("arrow.clockwise", label: "重新生成", disabled: busy, action: onRegenerate)
            actionIconButton("text.append", label: "继续生成", disabled: busy, action: onContinue)

            Button {
                UIPasteboard.general.string = message.rawText
                Haptics.success()
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { copied = true }
                Task {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    withAnimation(.easeOut(duration: 0.2)) { copied = false }
                }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(copied ? Palette.success : Palette.textTertiary)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 28, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("拷贝回复")

            Spacer(minLength: 0)
        }
        .padding(.top, 2)
    }

    private func actionIconButton(_ symbol: String, label: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(disabled ? Palette.textTertiary.opacity(0.45) : Palette.textSecondary)
                .frame(width: 28, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityLabel(label)
    }
}

// MARK: - Native collapsible <details> card

struct TavernDetailsCard: View {
    let summary: String
    let markdown: String

    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.spring(response: 0.36, dampingFraction: 0.86)) {
                    expanded.toggle()
                }
                Haptics.selection()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(TavernTheme.tint)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Text(summary)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Palette.textPrimary)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 6)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                Divider().overlay(Palette.hairline)
                MarkdownView(text: markdown, style: TavernTheme.markdownStyle, isStreaming: false)
                    .padding(14)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .cardSurface(radius: 16)
    }
}

// MARK: - Chat history switcher sheet

struct TavernChatHistorySheet: View {
    let characterId: Int
    let characterName: String
    let currentChatFile: String?

    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var loading = false
    @State private var switching = false

    private var chats: [TavernChatFile] {
        store.tavernChats(for: characterId)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Button {
                        switchTo(chatFile: nil, createNew: true)
                    } label: {
                        HStack(spacing: 8) {
                            if switching {
                                ProgressView().tint(.white)
                            } else {
                                Image(systemName: "plus.bubble.fill")
                            }
                            Text("开启全新聊天")
                        }
                        .font(.system(size: 15.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(Capsule(style: .continuous).fill(TavernTheme.gradient))
                        .shadow(color: TavernTheme.glow.opacity(0.35), radius: 14, y: 6)
                    }
                    .buttonStyle(.pressable)
                    .disabled(switching)

                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 6) {
                            Eyebrow(text: "历史聊天 · \(chats.count)")
                            if loading { ProgressView().controlSize(.mini) }
                        }
                        .padding(.leading, 4)

                        if chats.isEmpty && !loading {
                            Text("暂无过往聊天记录")
                                .font(.system(size: 14))
                                .foregroundStyle(Palette.textSecondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 32)
                                .cardSurface(radius: 20)
                        } else {
                            VStack(spacing: 0) {
                                ForEach(Array(chats.enumerated()), id: \.element.id) { index, chat in
                                    if index > 0 {
                                        Divider().overlay(Palette.hairline).padding(.leading, 16)
                                    }
                                    let isSelected = chat.isCurrent || chat.fileName == currentChatFile
                                    Button {
                                        guard !isSelected else { dismiss(); return }
                                        switchTo(chatFile: chat.fileName, createNew: false)
                                    } label: {
                                        HStack(alignment: .top, spacing: 12) {
                                            VStack(alignment: .leading, spacing: 4) {
                                                HStack(spacing: 6) {
                                                    Text(chat.displayName)
                                                        .font(.system(size: 15, weight: isSelected ? .semibold : .medium))
                                                        .foregroundStyle(Palette.textPrimary)
                                                        .lineLimit(1)
                                                    if chat.messageCount > 0 {
                                                        Text("\(chat.messageCount) 楼")
                                                            .font(.system(size: 11, weight: .semibold))
                                                            .foregroundStyle(Palette.textTertiary)
                                                            .padding(.horizontal, 6)
                                                            .padding(.vertical, 2)
                                                            .background(Capsule().fill(Palette.fieldFill))
                                                    }
                                                }
                                                if !chat.lastMessage.isEmpty {
                                                    Text(chat.lastMessage)
                                                        .font(.system(size: 12.5))
                                                        .foregroundStyle(Palette.textSecondary)
                                                        .lineLimit(2)
                                                        .multilineTextAlignment(.leading)
                                                }
                                                if let date = chat.updatedDate {
                                                    Text(RelayFormat.relative(date))
                                                        .font(.system(size: 11))
                                                        .foregroundStyle(Palette.textTertiary)
                                                }
                                            }
                                            Spacer(minLength: 6)
                                            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                                .font(.system(size: 20))
                                                .foregroundStyle(isSelected ? TavernTheme.tint : Palette.textTertiary.opacity(0.55))
                                                .padding(.top, 2)
                                        }
                                        .padding(.horizontal, 16)
                                        .padding(.vertical, 13)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.pressable)
                                    .disabled(switching)
                                }
                            }
                            .cardSurface(radius: 20)
                        }
                    }
                }
                .padding(20)
            }
            .navigationTitle("\(characterName) · 历史聊天")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .relaySheetBackground()
        .task(id: characterId) {
            loading = true
            await store.loadTavernChats(characterId: characterId)
            loading = false
        }
    }

    private func switchTo(chatFile: String?, createNew: Bool) {
        switching = true
        Haptics.selection()
        Task {
            await store.selectTavernCharacter(id: characterId, chatFile: chatFile, createNew: createNew)
            switching = false
            dismiss()
        }
    }
}

// MARK: - Edit message sheet

struct TavernEditMessageSheet: View {
    let message: TavernMessage

    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    @State private var saving = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TextEditor(text: $draft)
                    .font(RelayFont.body)
                    .scrollContentBackground(.hidden)
                    .padding(14)
                    .background(Palette.fieldFill)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(Palette.hairline, lineWidth: 0.6)
                    )
                    .padding(18)
            }
            .navigationTitle("编辑第 #\(message.mesId) 楼")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        saving = true
                        let updated = draft
                        Task {
                            let ok = await store.editTavernMessage(mesId: message.mesId, text: updated)
                            saving = false
                            if ok { dismiss() }
                        }
                    } label: {
                        if saving {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("保存").fontWeight(.semibold)
                        }
                    }
                    .disabled(saving)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .relaySheetBackground()
        .onAppear {
            draft = message.rawText
        }
    }
}
