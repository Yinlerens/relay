import SwiftUI

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
                                ForEach(chats) { chat in
                                    if chat.id != chats.first?.id {
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
        .onAppear {
            draft = message.rawText
        }
    }
}
