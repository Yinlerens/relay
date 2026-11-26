import SwiftUI
import UIKit

// MARK: - Message row

struct MessageRow: View, Equatable {
    let message: Message
    let style: AgentStyle
    let agentName: String
    let imageNamespace: Namespace.ID
    var canRetry: Bool = false
    var isRunning: Bool = false
    var loadingFileId: String? = nil
    var onOpenImage: (Attachment) -> Void
    var onOpenFile: (Attachment) -> Void = { _ in }
    var onRetryAssistant: (() -> Void)? = nil
    var onEditResendUser: (() -> Void)? = nil
    var onResendUser: (() -> Void)? = nil

    nonisolated static func == (lhs: MessageRow, rhs: MessageRow) -> Bool {
        lhs.message == rhs.message
            && lhs.style == rhs.style
            && lhs.agentName == rhs.agentName
            && lhs.canRetry == rhs.canRetry
            && lhs.isRunning == rhs.isRunning
            && lhs.loadingFileId == rhs.loadingFileId
    }

    var body: some View {
        switch message.role {
        case .user:
            UserMessageView(
                message: message,
                style: style,
                imageNamespace: imageNamespace,
                isRunning: isRunning,
                loadingFileId: loadingFileId,
                onOpenImage: onOpenImage,
                onOpenFile: onOpenFile,
                onEditResend: onEditResendUser,
                onResend: onResendUser
            )
        case .assistant:
            AssistantMessageView(
                message: message,
                style: style,
                agentName: agentName,
                canRetry: canRetry,
                isRunning: isRunning,
                onRetry: onRetryAssistant
            )
        }
    }
}

// MARK: - User message

struct UserMessageView: View {
    let message: Message
    let style: AgentStyle
    let imageNamespace: Namespace.ID
    var isRunning: Bool = false
    var loadingFileId: String? = nil
    var onOpenImage: (Attachment) -> Void
    var onOpenFile: (Attachment) -> Void = { _ in }
    var onEditResend: (() -> Void)? = nil
    var onResend: (() -> Void)? = nil

    private var images: [Attachment] { message.attachments.filter(\.isImage) }
    private var files: [Attachment] { message.attachments.filter { !$0.isImage } }
    private var showsText: Bool {
        !message.content.isEmpty && !(message.content == "[附件]" && !message.attachments.isEmpty)
    }
    private var isPending: Bool { message.id.hasPrefix("local-") }

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            if !images.isEmpty {
                imageStack
            }
            if !files.isEmpty {
                VStack(alignment: .trailing, spacing: 6) {
                    ForEach(files) { file in
                        Button {
                            Haptics.tap(.soft)
                            onOpenFile(file)
                        } label: {
                            FileChip(
                                filename: file.filename,
                                mimeType: file.mimeType,
                                sizeBytes: file.sizeBytes,
                                isLoading: loadingFileId == file.id
                            )
                        }
                        .buttonStyle(.pressable)
                        .disabled(loadingFileId == file.id)
                        .accessibilityLabel("预览文件 \(file.filename)")
                    }
                }
            }
            if showsText {
                Text(message.content)
                    .font(RelayFont.body)
                    .lineSpacing(3)
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
                        .fill(style.wash)
                    )
                    .overlay(
                        UnevenRoundedRectangle(
                            topLeadingRadius: 20,
                            bottomLeadingRadius: 20,
                            bottomTrailingRadius: 6,
                            topTrailingRadius: 20,
                            style: .continuous
                        )
                        .stroke(style.tint.opacity(0.18), lineWidth: 0.6)
                    )
                    .contextMenu { userContextMenuItems }
            }
        }
        .opacity(isPending ? 0.7 : 1)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, 44)
        .contextMenu {
            if !showsText {
                userContextMenuItems
            }
        }
    }

    @ViewBuilder
    private var userContextMenuItems: some View {
        if showsText {
            Button {
                UIPasteboard.general.string = message.content
                Haptics.success()
            } label: {
                Label("拷贝", systemImage: "doc.on.doc")
            }
        }
        if showsText, let onEditResend {
            Button {
                onEditResend()
            } label: {
                Label("编辑并重发", systemImage: "square.and.pencil")
            }
        }
        if let onResend {
            Button {
                onResend()
            } label: {
                Label("重新发送", systemImage: "arrow.clockwise")
            }
            .disabled(isRunning)
        }
    }

    private var imageStack: some View {
        let side: CGFloat = images.count == 1 ? 188 : 104
        return HStack(spacing: 6) {
            ForEach(images.prefix(4)) { image in
                Button {
                    Haptics.tap(.soft)
                    onOpenImage(image)
                } label: {
                    AuthImageView(attachmentId: image.id)
                        .frame(width: side, height: side)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(Palette.hairline, lineWidth: 0.6)
                        )
                }
                .buttonStyle(.pressable)
                .matchedTransitionSource(id: image.id, in: imageNamespace)
            }
            if images.count > 4 {
                Text("+\(images.count - 4)")
                    .font(RelayFont.rounded(15, weight: .semibold))
                    .foregroundStyle(Palette.textSecondary)
                    .frame(width: 52, height: side)
                    .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Palette.fieldFill))
            }
        }
    }
}

struct FileChip: View {
    var filename: String
    var mimeType: String
    var sizeBytes: Int
    var isLoading: Bool = false

    static func symbol(for mimeType: String, filename: String) -> String {
        let ext = (filename as NSString).pathExtension.lowercased()
        if mimeType.hasPrefix("image/") { return "photo" }
        if mimeType == "application/pdf" || ext == "pdf" { return "doc.richtext" }
        if ["swift", "ts", "tsx", "js", "jsx", "py", "go", "rs", "java", "kt", "c", "cpp", "h", "sh", "rb"].contains(ext) {
            return "chevron.left.forwardslash.chevron.right"
        }
        if ["json", "yaml", "yml", "toml", "xml"].contains(ext) { return "curlybraces" }
        if ["zip", "gz", "tar", "rar", "7z"].contains(ext) { return "doc.zipper" }
        if mimeType.hasPrefix("text/") || ["md", "txt", "log", "csv"].contains(ext) { return "doc.plaintext" }
        return "doc"
    }

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Palette.fieldFill)
                if isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: Self.symbol(for: mimeType, filename: filename))
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Palette.textSecondary)
                }
            }
            .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(filename)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(isLoading ? "正在打开…" : RelayFormat.bytes(sizeBytes))
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.textTertiary)
            }
            Spacer(minLength: 4)
            Image(systemName: "eye")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Palette.textTertiary)
        }
        .padding(.leading, 8)
        .padding(.trailing, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: 270, alignment: .leading)
        .cardSurface(radius: 16)
    }
}

// MARK: - Assistant message

struct AssistantMessageView: View {
    let message: Message
    let style: AgentStyle
    let agentName: String
    var canRetry: Bool = false
    var isRunning: Bool = false
    var onRetry: (() -> Void)? = nil

    @State private var copied = false

    private var isStreaming: Bool { message.isStreaming }
    private var hasContent: Bool { !message.content.isEmpty }
    private var isThinkingPhase: Bool { isStreaming && !hasContent }
    private var showsRetryPill: Bool {
        !isStreaming && (message.isError || message.isCancelled) && canRetry && onRetry != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                AgentGlyph(style: style, size: 22, isRunning: isStreaming)
                Text(agentName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.textSecondary)
                if message.isCancelled {
                    statusBadge("已停止", color: Palette.warning)
                } else if message.isError {
                    statusBadge("出错", color: Palette.danger)
                }
                Spacer(minLength: 0)
            }

            if !message.thinking.isEmpty {
                ThinkingCapsule(text: message.thinking, isActive: isThinkingPhase, style: style)
            }

            if !message.toolCalls.isEmpty {
                ToolActivityPill(tools: message.toolCalls, isStreaming: isStreaming, style: style)
            }

            if hasContent {
                MarkdownView(text: message.content, style: style, isStreaming: isStreaming)
            } else if isStreaming && message.thinking.isEmpty && message.toolCalls.isEmpty {
                TypingDots(color: style.tint)
                    .padding(.vertical, 6)
            }

            if !isStreaming && (hasContent || showsRetryPill) {
                footer
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.spring(response: 0.4, dampingFraction: 0.86), value: message.status)
    }

    private func statusBadge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .bold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.14)))
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if showsRetryPill, let onRetry {
                Button {
                    Haptics.tap(.medium)
                    onRetry()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .bold))
                        Text("重试")
                    }
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(style.gradient))
                }
                .buttonStyle(.pressable)
                .disabled(isRunning)
                .accessibilityLabel("重试请求")
            }

            if hasContent {
                Button {
                    UIPasteboard.general.string = message.content
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
                        .frame(width: 28, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("拷贝回复")

                if !showsRetryPill, canRetry, let onRetry {
                    Button {
                        Haptics.tap(.soft)
                        onRetry()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(Palette.textTertiary)
                            .frame(width: 28, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isRunning)
                    .accessibilityLabel("重新生成")
                }
            }

            if let total = message.usage?.displayTotal {
                Text("\(RelayFormat.tokens(total)) tokens")
                    .font(.system(size: 11.5, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(Palette.textTertiary)
            }
            if let usage = message.usage, let credits = usage.credits {
                creditBadge(credits: credits, saved: usage.savedCredits)
            }
            Spacer()
        }
    }

    private func creditBadge(credits: Double, saved: Double) -> some View {
        let isFree = credits == 0 && saved > 0
        let text = isFree
            ? "免费 · 0 积分（省 \(RelayFormat.credits(saved))）"
            : "\(RelayFormat.credits(credits)) 积分"
        let color = isFree ? Palette.success : style.tint
        return HStack(spacing: 4) {
            Image(systemName: isFree ? "leaf.fill" : "creditcard.fill")
                .font(.system(size: 9, weight: .bold))
            Text(text)
                .monospacedDigit()
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule(style: .continuous).fill(color.opacity(0.12)))
        .overlay(Capsule(style: .continuous).stroke(color.opacity(0.22), lineWidth: 0.5))
        .accessibilityLabel(text)
    }
}

// MARK: - Thinking capsule

struct ThinkingCapsule: View {
    let text: String
    let isActive: Bool
    let style: AgentStyle

    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) {
                    expanded.toggle()
                }
                Haptics.selection()
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "brain")
                        .symbolEffect(.pulse, options: .repeating, isActive: isActive)
                        .foregroundStyle(style.tint)
                    Text(isActive ? "正在思考…" : "思考过程")
                        .shimmer(isActive)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .foregroundStyle(Palette.textTertiary)
                }
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Palette.textSecondary)
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(Capsule(style: .continuous).fill(Palette.fieldFill))
                .overlay(Capsule(style: .continuous).stroke(Palette.hairline, lineWidth: 0.6))
            }
            .buttonStyle(.pressable)

            if expanded {
                Text(text)
                    .font(.system(size: 13.5))
                    .lineSpacing(4)
                    .foregroundStyle(Palette.textSecondary)
                    .textSelection(.enabled)
                    .padding(.leading, 14)
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(style.tint.opacity(0.45))
                            .frame(width: 2)
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

// MARK: - Tool activity pill (expandable details)

struct ToolActivityPill: View {
    let tools: [ToolActivity]
    let isStreaming: Bool
    let style: AgentStyle

    @State private var expanded = false
    @State private var expandedToolIds: Set<String> = []

    private var isRunning: Bool { isStreaming && tools.contains(where: \.isActive) }
    private var failedCount: Int { tools.filter(\.isFailed).count }
    private var currentTitle: String {
        (tools.last(where: \.isActive) ?? tools.last)?.title ?? ""
    }

    private var label: String {
        if isRunning {
            return currentTitle.isEmpty ? "执行中…" : "执行中 · \(currentTitle)"
        }
        var text = "已完成 \(tools.count) 项操作"
        if failedCount > 0 { text += " · \(failedCount) 项失败" }
        return text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) {
                    expanded.toggle()
                }
                Haptics.selection()
            } label: {
                HStack(spacing: 8) {
                    ZStack {
                        if isRunning {
                            ProgressView()
                                .controlSize(.mini)
                        } else {
                            Image(systemName: failedCount > 0 ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                                .foregroundStyle(failedCount > 0 ? Palette.warning : style.tint)
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                    .frame(width: 14, height: 14)

                    Text(label)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .contentTransition(.opacity)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .foregroundStyle(Palette.textTertiary)
                }
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Palette.textSecondary)
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(Capsule(style: .continuous).fill(Palette.fieldFill))
                .overlay(Capsule(style: .continuous).stroke(Palette.hairline, lineWidth: 0.6))
            }
            .buttonStyle(.pressable)
            .animation(.easeInOut(duration: 0.25), value: isRunning)

            if expanded {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(tools) { tool in
                        let isDetailOpen = expandedToolIds.contains(tool.id)
                        let expandable = tool.hasDetails || tool.title.count > 28 || tool.name != tool.title
                        VStack(alignment: .leading, spacing: 6) {
                            Button {
                                guard expandable else { return }
                                withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                                    if isDetailOpen {
                                        expandedToolIds.remove(tool.id)
                                    } else {
                                        expandedToolIds.insert(tool.id)
                                    }
                                }
                                Haptics.selection()
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: Self.symbol(for: tool.kind))
                                        .font(.system(size: 11.5, weight: .medium))
                                        .foregroundStyle(tool.isFailed ? Palette.danger : Palette.textTertiary)
                                        .frame(width: 16)
                                    Text(tool.title)
                                        .font(.system(size: 12.5, weight: isDetailOpen ? .semibold : .regular))
                                        .foregroundStyle(isDetailOpen ? Palette.textPrimary : Palette.textSecondary)
                                        .lineLimit(isDetailOpen ? nil : 1)
                                        .truncationMode(.middle)
                                        .multilineTextAlignment(.leading)
                                    Spacer(minLength: 6)
                                    if expandable {
                                        Image(systemName: "chevron.right")
                                            .font(.system(size: 8.5, weight: .bold))
                                            .foregroundStyle(Palette.textTertiary)
                                            .rotationEffect(.degrees(isDetailOpen ? 90 : 0))
                                    }
                                    statusGlyph(tool)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            if isDetailOpen {
                                toolDetailPanel(tool)
                                    .padding(.leading, 26)
                                    .transition(.opacity.combined(with: .move(edge: .top)))
                            }
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Palette.fieldFill)
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    @ViewBuilder
    private func toolDetailPanel(_ tool: ToolActivity) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(tool.name)
                    .font(RelayFont.mono(10.5, weight: .semibold))
                    .foregroundStyle(style.tint)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(style.wash))
                Text(tool.status)
                    .font(RelayFont.mono(10.5))
                    .foregroundStyle(tool.isFailed ? Palette.danger : Palette.textTertiary)
            }

            if !tool.locations.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(tool.locations, id: \.self) { loc in
                        HStack(spacing: 5) {
                            Image(systemName: "mappin.and.ellipse")
                                .font(.system(size: 10))
                                .foregroundStyle(Palette.textTertiary)
                            Text(loc)
                                .font(RelayFont.mono(11))
                                .foregroundStyle(Palette.textSecondary)
                                .lineLimit(2)
                                .truncationMode(.middle)
                        }
                    }
                }
            }

            if let input = tool.inputPreview, !input.isEmpty {
                toolPayloadBox(title: "输入", content: input)
            }
            if let output = tool.outputPreview, !output.isEmpty {
                toolPayloadBox(title: "输出", content: output)
            }
        }
    }

    private func toolPayloadBox(title: String, content: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Palette.textTertiary)
                Spacer()
                Button {
                    UIPasteboard.general.string = content
                    Haptics.success()
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Palette.textTertiary)
                        .padding(4)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("拷贝\(title)")
            }
            ScrollView {
                Text(content)
                    .font(RelayFont.mono(11.5))
                    .foregroundStyle(Palette.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 160)
        }
        .padding(9)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Palette.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Palette.hairline, lineWidth: 0.6)
        )
    }

    @ViewBuilder
    private func statusGlyph(_ tool: ToolActivity) -> some View {
        if tool.isActive && isStreaming {
            ProgressView().controlSize(.mini)
        } else if tool.isFailed {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Palette.danger)
        } else {
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(style.tint)
        }
    }

    static func symbol(for kind: String) -> String {
        switch kind {
        case "read": return "doc.text"
        case "edit": return "pencil"
        case "delete": return "trash"
        case "move": return "arrow.right.doc.on.clipboard"
        case "search": return "magnifyingglass"
        case "execute": return "terminal"
        case "think": return "brain"
        case "fetch": return "globe"
        case "switch_mode": return "arrow.triangle.swap"
        default: return "gearshape"
        }
    }
}
