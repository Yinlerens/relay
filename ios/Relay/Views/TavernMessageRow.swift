import SwiftUI
import UIKit

// MARK: - Tavern message row

struct TavernMessageRow: View {
    let message: TavernMessage
    let isLastAssistant: Bool
    let variablesJSON: String
    let imageNamespace: Namespace.ID
    var onOpenImage: (TavernImageItem) -> Void
    var onEdit: () -> Void
    var onDelete: () -> Void
    var onSwipe: (TavernSwipeDirection) -> Void
    var onRegenerate: () -> Void
    var onContinue: () -> Void
    var onSlash: (String) -> Void
    var onSendFromCard: (String) -> Void
    var onFillDraft: (String) -> Void

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
                let sourceId = "tavern-img-\(message.mesId)-\(block.id)"
                Button {
                    Haptics.tap(.soft)
                    onOpenImage(TavernImageItem(url: url, alt: block.imageAlt ?? "", sourceId: sourceId))
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
                .matchedTransitionSource(id: sourceId, in: imageNamespace)
            }

        case "html", "iframe":
            if let html = block.html, !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                TavernHTMLCardView(
                    blockId: block.id,
                    renderedHash: message.renderedHash,
                    html: html,
                    estimatedHeight: block.estimatedHeight,
                    variablesJSON: variablesJSON,
                    mvuDataJSON: message.mvuDataJSON,
                    isIframe: block.kind == "iframe",
                    onSlash: onSlash,
                    onSend: onSendFromCard,
                    onFillDraft: onFillDraft
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
                    try? await Task.sleep(for: .milliseconds(1500))
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
