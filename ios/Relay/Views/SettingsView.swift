import SwiftUI

struct SettingsView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SettingsKey.appearance) private var appearance: AppearanceMode = .system
    @AppStorage(SettingsKey.haptics) private var hapticsEnabled = true
    @State private var barkDraft = ""
    @State private var savingBark = false
    @State private var confirmSignOut = false

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 14) {
                        RelayMark(size: 40)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(store.serverHost)
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(Palette.textPrimary)
                                .lineLimit(1)
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(store.socketState == .connected ? Palette.success : Palette.warning)
                                    .frame(width: 6, height: 6)
                                Text(store.socketState == .connected ? "实时通道已连接" : "实时通道重连中")
                                    .font(.system(size: 12.5))
                                    .foregroundStyle(Palette.textSecondary)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    LabeledContent("Agents", value: "\(store.agents.count)")
                    LabeledContent("会话", value: "\(store.sessions.count)")
                } header: {
                    Text("连接")
                }

                Section {
                    Picker("主题", selection: $appearance) {
                        ForEach(AppearanceMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))

                    Toggle(isOn: $hapticsEnabled) {
                        Label("触感反馈", systemImage: "hand.tap")
                    }
                    .onChange(of: hapticsEnabled) { _, enabled in
                        if enabled { Haptics.success() }
                    }
                } header: {
                    Text("外观与触感")
                }

                Section {
                    TextField("https://api.day.app/你的Key", text: $barkDraft)
                        .font(RelayFont.mono(14))
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button {
                        saveBark(test: false)
                    } label: {
                        Label("保存", systemImage: "tray.and.arrow.down")
                    }
                    .disabled(savingBark || barkDraft == store.barkUrl)
                    Button {
                        saveBark(test: true)
                    } label: {
                        Label("保存并发送测试推送", systemImage: "bell.badge")
                    }
                    .disabled(savingBark || barkDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                } header: {
                    HStack {
                        Text("Bark 推送")
                        if savingBark {
                            ProgressView().controlSize(.mini)
                        }
                    }
                } footer: {
                    Text("任务完成或出错时，服务端会通过 Bark 推送到你的 iPhone。留空并保存即可关闭。")
                }

                Section {
                    LabeledContent("版本", value: version)
                    LabeledContent("隐私", value: "零遥测 · 自托管")
                    LabeledContent("权限", value: "服务端自动批准")
                } header: {
                    Text("关于")
                }

                Section {
                    Button(role: .destructive) {
                        confirmSignOut = true
                    } label: {
                        Label("断开连接并退出", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(AmbientBackground(tint: nil))
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
            .confirmationDialog("断开与服务端的连接？", isPresented: $confirmSignOut, titleVisibility: .visible) {
                Button("断开连接", role: .destructive) {
                    dismiss()
                    store.signOut()
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("服务端地址与令牌将从钥匙串中移除，会话数据仍保留在服务端。")
            }
            .onAppear {
                barkDraft = store.barkUrl
            }
        }
        .presentationDragIndicator(.visible)
        .relaySheetBackground()
    }

    private func saveBark(test: Bool) {
        savingBark = true
        Task {
            await store.saveSettings(barkUrl: barkDraft, test: test)
            barkDraft = store.barkUrl
            savingBark = false
        }
    }
}
