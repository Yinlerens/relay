import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import UIKit

// MARK: - Pending attachment model

struct PendingAttachment: Identifiable, Equatable {
    let id = UUID()
    var filename: String
    var mimeType: String
    var sizeBytes: Int
    var isImage: Bool
    var preview: UIImage?
    var uploaded: Attachment?
    var failed = false

    var isUploading: Bool { uploaded == nil && !failed }

    static func == (lhs: PendingAttachment, rhs: PendingAttachment) -> Bool {
        lhs.id == rhs.id && lhs.uploaded == rhs.uploaded && lhs.failed == rhs.failed
    }
}

enum ImageProcessing {
    /// Redraws (normalizing orientation) and caps the longest edge in pixels.
    static func resized(_ image: UIImage, maxEdge: CGFloat) -> UIImage {
        let pixelWidth = image.size.width * image.scale
        let pixelHeight = image.size.height * image.scale
        let longest = max(pixelWidth, pixelHeight)
        guard longest > 0 else { return image }
        let ratio = longest > maxEdge ? maxEdge / longest : 1
        let target = CGSize(width: (pixelWidth * ratio).rounded(), height: (pixelHeight * ratio).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }

    static func jpegPayload(from image: UIImage) -> (data: Data, image: UIImage)? {
        let scaled = Self.resized(image, maxEdge: 2048)
        guard let data = scaled.jpegData(compressionQuality: 0.82) else { return nil }
        return (data, scaled)
    }
}

// MARK: - Composer

struct ComposerView: View {
    let sessionId: String
    let style: AgentStyle
    let agentName: String
    @Binding var text: String

    @Environment(AppStore.self) private var store
    @State private var attachments: [PendingAttachment] = []
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showPhotoPicker = false
    @State private var showFileImporter = false
    @State private var isSending = false
    @FocusState private var focused: Bool

    private static let maxUploadBytes = 25 * 1024 * 1024

    private var session: SessionSummary? { store.session(sessionId) }
    private var isRunning: Bool { session?.isRunning ?? false }
    private var trimmedText: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var hasUploading: Bool { attachments.contains(where: \.isUploading) }
    private var canSend: Bool {
        !isSending && !hasUploading && (!trimmedText.isEmpty || attachments.contains { $0.uploaded != nil })
    }

    private var slashQuery: String? {
        guard text.hasPrefix("/") else { return nil }
        let afterSlash = text.dropFirst()
        if afterSlash.contains(where: { $0 == " " || $0 == "\n" }) { return nil }
        return String(afterSlash).lowercased()
    }

    private var slashMatches: [SlashCommand] {
        guard let query = slashQuery, let commands = session?.availableCommands, !commands.isEmpty else { return [] }
        guard !query.isEmpty else { return commands }
        let prefixed = commands.filter { $0.name.lowercased().hasPrefix(query) }
        let fuzzy = commands.filter {
            !$0.name.lowercased().hasPrefix(query)
                && ($0.name.lowercased().contains(query) || $0.description.lowercased().contains(query))
        }
        return prefixed + fuzzy
    }

    var body: some View {
        let matches = slashMatches

        VStack(spacing: 10) {
            if !matches.isEmpty {
                SlashCommandTray(commands: matches, style: style) { command in
                    text = "/\(command.name) "
                    Haptics.selection()
                }
                .transition(.move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.97, anchor: .bottom)))
            }

            GlassGroup(spacing: 10) {
                VStack(spacing: 0) {
                    if !attachments.isEmpty {
                        attachmentStrip
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }

                    HStack(alignment: .bottom, spacing: 8) {
                        attachMenu

                        TextField("给 \(agentName) 发消息…", text: $text, axis: .vertical)
                            .font(RelayFont.body)
                            .lineLimit(1...6)
                            .focused($focused)
                            .padding(.vertical, 9)
                            .tint(style.tint)

                        SendStopButton(isRunning: isRunning, canSend: canSend, isSending: isSending, style: style) {
                            primaryAction()
                        }
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 6)
                }
                .glassRounded(26, tint: focused ? style.glow : nil)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: matches.map(\.name))
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: attachments)
        .animation(.easeInOut(duration: 0.2), value: focused)
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoItems, maxSelectionCount: 6, matching: .images)
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            let picked = items
            photoItems = []
            Task { await importPhotos(picked) }
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            handleFiles(result)
        }
    }

    // MARK: Subviews

    private var attachMenu: some View {
        Menu {
            Button {
                showPhotoPicker = true
            } label: {
                Label("照片", systemImage: "photo.on.rectangle.angled")
            }
            Button {
                showFileImporter = true
            } label: {
                Label("文件", systemImage: "doc.badge.plus")
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Palette.textSecondary)
                .frame(width: 36, height: 36)
                .background(Circle().fill(Palette.fieldFill))
                .contentShape(Circle())
        }
        .accessibilityLabel("添加附件")
    }

    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { item in
                    AttachmentChip(item: item) {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            attachments.removeAll { $0.id == item.id }
                        }
                        Haptics.tap(.soft)
                    }
                    .transition(.scale(scale: 0.7).combined(with: .opacity))
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 2)
        }
    }

    // MARK: Actions

    private func primaryAction() {
        if isRunning {
            Task { await store.cancel(sessionId: sessionId) }
            return
        }
        guard canSend else { return }
        let outgoingText = text
        let outgoingAttachments = attachments
        let uploaded = attachments.compactMap(\.uploaded)
        text = ""
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            attachments = []
        }
        isSending = true
        Task {
            let ok = await store.send(sessionId: sessionId, text: outgoingText, attachments: uploaded)
            isSending = false
            if !ok {
                text = outgoingText
                attachments = outgoingAttachments
            }
        }
    }

    private func importPhotos(_ items: [PhotosPickerItem]) async {
        for (index, item) in items.enumerated() {
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data),
                  let payload = ImageProcessing.jpegPayload(from: image) else {
                store.showBanner("无法读取所选照片")
                continue
            }
            let stamp = Int(Date().timeIntervalSince1970)
            let pending = PendingAttachment(
                filename: "IMG_\(stamp)_\(index + 1).jpg",
                mimeType: "image/jpeg",
                sizeBytes: payload.data.count,
                isImage: true,
                preview: payload.image
            )
            startUpload(pending, data: payload.data)
        }
    }

    private func handleFiles(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            store.showBanner("无法打开文件：\(error.localizedDescription)")
        case .success(let urls):
            for url in urls {
                let accessing = url.startAccessingSecurityScopedResource()
                defer {
                    if accessing { url.stopAccessingSecurityScopedResource() }
                }
                guard let data = try? Data(contentsOf: url) else {
                    store.showBanner("无法读取 \(url.lastPathComponent)")
                    continue
                }
                let type = UTType(filenameExtension: url.pathExtension)
                var filename = url.lastPathComponent
                var mime = type?.preferredMIMEType ?? "application/octet-stream"
                if mime == "application/octet-stream", let type, type.conforms(to: .text) {
                    mime = "text/plain"
                }
                var payload = data
                var preview: UIImage?
                let isImage = type?.conforms(to: .image) ?? false

                if isImage, let image = UIImage(data: data), let jpeg = ImageProcessing.jpegPayload(from: image) {
                    payload = jpeg.data
                    preview = jpeg.image
                    mime = "image/jpeg"
                    filename = (filename as NSString).deletingPathExtension + ".jpg"
                }

                guard payload.count <= Self.maxUploadBytes else {
                    store.showBanner("\(filename) 超过 25 MB 上限")
                    continue
                }

                let pending = PendingAttachment(
                    filename: filename,
                    mimeType: mime,
                    sizeBytes: payload.count,
                    isImage: preview != nil,
                    preview: preview
                )
                startUpload(pending, data: payload)
            }
        }
    }

    private func startUpload(_ item: PendingAttachment, data: Data) {
        withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
            attachments.append(item)
        }
        Haptics.tap(.soft)
        Task {
            do {
                let uploaded = try await store.upload(data: data, filename: item.filename, mimeType: item.mimeType)
                if let preview = item.preview {
                    AttachmentImageCache.shared.store(preview, for: uploaded.id)
                }
                if let idx = attachments.firstIndex(where: { $0.id == item.id }) {
                    attachments[idx].uploaded = uploaded
                }
            } catch {
                if let idx = attachments.firstIndex(where: { $0.id == item.id }) {
                    attachments[idx].failed = true
                }
                Haptics.error()
                store.showBanner("上传失败：\(error.localizedDescription)")
            }
        }
    }
}

// MARK: - Attachment chip

struct AttachmentChip: View {
    let item: PendingAttachment
    var onRemove: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let preview = item.preview {
                    Image(uiImage: preview)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 58, height: 58)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                } else {
                    HStack(spacing: 8) {
                        Image(systemName: FileChip.symbol(for: item.mimeType, filename: item.filename))
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Palette.textSecondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.filename)
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(Palette.textPrimary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(RelayFormat.bytes(item.sizeBytes))
                                .font(.system(size: 10.5))
                                .foregroundStyle(Palette.textTertiary)
                        }
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 58)
                    .frame(maxWidth: 190)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.fieldFill))
                }
            }
            .overlay {
                if item.isUploading {
                    ZStack {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(.black.opacity(0.35))
                        ProgressView()
                            .tint(.white)
                    }
                } else if item.failed {
                    ZStack {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Palette.danger.opacity(0.35))
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.white)
                    }
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Palette.hairline, lineWidth: 0.6)
            )

            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8.5, weight: .heavy))
                    .foregroundStyle(.white)
                    .frame(width: 19, height: 19)
                    .background(Circle().fill(.black.opacity(0.72)))
                    .overlay(Circle().stroke(Color.white.opacity(0.35), lineWidth: 0.6))
            }
            .buttonStyle(.plain)
            .offset(x: 6, y: -6)
            .accessibilityLabel("移除附件")
        }
        .padding(.top, 6)
        .padding(.trailing, 6)
    }
}

// MARK: - Send / Stop morph button

struct SendStopButton: View {
    var isRunning: Bool
    var canSend: Bool
    var isSending: Bool
    var style: AgentStyle
    var action: () -> Void

    private var active: Bool { isRunning || canSend }

    var body: some View {
        Button(action: action) {
            ZStack {
                if isRunning {
                    Circle().fill(Palette.textPrimary)
                } else if canSend {
                    Circle().fill(style.gradient)
                } else {
                    Circle().fill(Palette.fieldFill)
                }
                if isSending && !isRunning {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                } else {
                    Image(systemName: isRunning ? "stop.fill" : "arrow.up")
                        .font(.system(size: isRunning ? 13 : 16, weight: .bold))
                        .foregroundStyle(isRunning ? Palette.canvas : (canSend ? Color.white : Palette.textTertiary))
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .frame(width: 36, height: 36)
            .shadow(color: canSend && !isRunning ? style.glow.opacity(0.45) : .clear, radius: 8, y: 3)
            .scaleEffect(active ? 1 : 0.92)
        }
        .buttonStyle(.pressable)
        .disabled(!active)
        .animation(.spring(response: 0.32, dampingFraction: 0.68), value: isRunning)
        .animation(.spring(response: 0.32, dampingFraction: 0.68), value: canSend)
        .accessibilityLabel(isRunning ? "停止生成" : "发送")
    }
}

// MARK: - Slash command tray

struct SlashCommandTray: View {
    let commands: [SlashCommand]
    let style: AgentStyle
    var onSelect: (SlashCommand) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(commands) { command in
                    Button {
                        onSelect(command)
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text("/\(command.name)")
                                .font(RelayFont.mono(14, weight: .semibold))
                                .foregroundStyle(style.tint)
                                .lineLimit(1)
                            VStack(alignment: .leading, spacing: 2) {
                                if !command.description.isEmpty {
                                    Text(command.description)
                                        .font(.system(size: 13))
                                        .foregroundStyle(Palette.textSecondary)
                                        .lineLimit(2)
                                }
                                if let hint = command.hint, !hint.isEmpty {
                                    Text(hint)
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(Palette.textTertiary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.pressable)
                }
            }
            .padding(.vertical, 6)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxHeight: min(CGFloat(commands.count) * 58 + 12, 270))
        .glassRounded(22)
    }
}
