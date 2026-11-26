import SwiftUI
import UniformTypeIdentifiers
import WebKit

// MARK: - Account Sheet

struct WuwaAccountSheet: View {
    @Environment(WuwaStore.self) private var wuwa
    @Environment(\.dismiss) private var dismiss

    var onOpenLogin: () -> Void
    var onOpenGachaImport: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section("库街区账号") {
                    if let session = wuwa.session {
                        LabeledContent("用户", value: wuwa.snapshot.profile?.userName.isEmpty == false ? wuwa.snapshot.profile!.userName : session.userId)
                        LabeledContent("手机", value: session.mobileMasked)
                        if let role = wuwa.activeGameRole {
                            LabeledContent("鸣潮 UID", value: role.roleId)
                            LabeledContent("服务器", value: role.serverName)
                        }
                        if wuwa.snapshot.roles.count > 1 {
                            Picker("切换区服角色", selection: Binding(
                                get: { wuwa.snapshot.selectedRoleId ?? "" },
                                set: { nextId in
                                    Task { await wuwa.refreshCommunity(roleId: nextId, forceDetails: true) }
                                }
                            )) {
                                ForEach(wuwa.snapshot.roles) { r in
                                    Text("\(r.roleName) · \(r.roleId)").tag(r.roleId)
                                }
                            }
                        }
                        Button(role: .destructive) {
                            Task {
                                await wuwa.logout()
                                dismiss()
                            }
                        } label: {
                            Text("退出库街区登录")
                        }
                    } else {
                        Text("未登录库街区账号")
                            .foregroundStyle(Palette.textSecondary)
                        Button("登录 / 导入 Token") {
                            onOpenLogin()
                        }
                    }
                }

                Section("本地与云端历史数据") {
                    LabeledContent("已缓存角色面板", value: "\(wuwa.detailsByRoleId.count) 位")
                    LabeledContent("声骸历史快照", value: "\(wuwa.historyByRoleId.values.reduce(0) { $0 + $1.count }) 条")
                    LabeledContent("本地唤取记录", value: "\(wuwa.pulls.count) 条")
                    if wuwa.relayAPIProvider?() != nil {
                        Button {
                            Task { await wuwa.syncFromRelayServer(showToast: true) }
                        } label: {
                            HStack {
                                Text("从 Relay 服务端同步 PC 历史")
                                Spacer()
                                if wuwa.isSyncingCloud {
                                    ProgressView().controlSize(.small)
                                }
                            }
                        }
                        .disabled(wuwa.isSyncingCloud)
                    }
                    Button("导入 / 导出唤取备份") {
                        onOpenGachaImport()
                    }
                }
            }
            .navigationTitle("鸣潮账号与数据")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Login Sheet (SMS + Geetest OR Token Direct Import)

struct WuwaLoginSheet: View {
    @Environment(WuwaStore.self) private var wuwa
    @Environment(\.dismiss) private var dismiss

    enum LoginMode: String, CaseIterable, Identifiable {
        case sms = "短信验证码"
        case token = "Token 导入"
        var id: String { rawValue }
    }

    @State private var mode: LoginMode = .sms
    @State private var mobile = ""
    @State private var smsCode = ""
    @State private var cooldown = 0
    @State private var showGeetest = false
    @State private var rawToken = ""
    @State private var customDeviceId = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("登录方式", selection: $mode) {
                        ForEach(LoginMode.allCases) { item in
                            Text(item.rawValue).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                if mode == .sms {
                    Section("国服库街区登录") {
                        TextField("中国大陆手机号", text: $mobile)
                            .keyboardType(.numberPad)
                        HStack {
                            TextField("短信验证码", text: $smsCode)
                                .keyboardType(.numberPad)
                            Button(cooldown > 0 ? "\(cooldown)s" : "获取验证码") {
                                showGeetest = true
                            }
                            .disabled(cooldown > 0 || wuwa.authBusy != nil || mobile.count < 11)
                        }
                    }
                    Section {
                        Button {
                            Task {
                                if await wuwa.loginWithSms(mobile: mobile, code: smsCode) {
                                    dismiss()
                                }
                            }
                        } label: {
                            HStack {
                                Spacer()
                                if wuwa.authBusy == "login" {
                                    ProgressView()
                                } else {
                                    Text("登录并同步角色面板").fontWeight(.semibold)
                                }
                                Spacer()
                            }
                        }
                        .disabled(wuwa.authBusy != nil || mobile.isEmpty || smsCode.isEmpty)
                    }
                } else {
                    Section("直接导入凭证") {
                        TextField("粘贴库街区 Token", text: $rawToken, axis: .vertical)
                            .lineLimit(2...4)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("devcode / did (可选)", text: $customDeviceId)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    Section {
                        Button {
                            Task {
                                if await wuwa.loginWithToken(rawToken, deviceId: customDeviceId) {
                                    dismiss()
                                }
                            }
                        } label: {
                            HStack {
                                Spacer()
                                if wuwa.authBusy == "login" {
                                    ProgressView()
                                } else {
                                    Text("验证并保存至钥匙串").fontWeight(.semibold)
                                }
                                Spacer()
                            }
                        }
                        .disabled(wuwa.authBusy != nil || rawToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .navigationTitle("登录库街区")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
            }
            .sheet(isPresented: $showGeetest) {
                WuwaGeetestSheet { payload in
                    showGeetest = false
                    Task {
                        if await wuwa.sendSmsCode(mobile: mobile, captcha: payload) {
                            startCooldown()
                        }
                    }
                } onError: { msg in
                    showGeetest = false
                    wuwa.onBanner?(msg, true)
                }
            }
        }
    }

    private func startCooldown() {
        cooldown = 60
        Task {
            while cooldown > 0 {
                try? await Task.sleep(for: .seconds(1))
                cooldown -= 1
            }
        }
    }
}

// MARK: - Geetest v4 Minimal Verification Sheet (Only invoked momentarily during SMS request)

struct WuwaGeetestSheet: View {
    @Environment(\.dismiss) private var dismiss
    var onSuccess: (WuwaCaptchaPayload) -> Void
    var onError: (String) -> Void

    var body: some View {
        NavigationStack {
            GeetestWebView(onSuccess: onSuccess, onError: onError)
                .navigationTitle("安全验证")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("取消") { dismiss() }
                    }
                }
        }
        .presentationDetents([.medium])
    }
}

private struct GeetestWebView: UIViewRepresentable {
    var onSuccess: (WuwaCaptchaPayload) -> Void
    var onError: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onSuccess: onSuccess, onError: onError)
    }

    func makeUIView(context: Context) -> WKWebView {
        let controller = WKUserContentController()
        controller.add(context.coordinator, name: "geetest")
        let config = WKWebViewConfiguration()
        config.userContentController = controller
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.loadHTMLString(Self.html, baseURL: URL(string: "https://static.geetest.com"))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKScriptMessageHandler {
        var onSuccess: (WuwaCaptchaPayload) -> Void
        var onError: (String) -> Void

        init(onSuccess: @escaping (WuwaCaptchaPayload) -> Void, onError: @escaping (String) -> Void) {
            self.onSuccess = onSuccess
            self.onError = onError
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let dict = message.body as? [String: Any],
                  let type = dict["type"] as? String else { return }
            if type == "success", let p = dict["payload"] as? [String: Any] {
                let payload = WuwaCaptchaPayload(
                    captchaId: (p["captcha_id"] as? String) ?? "",
                    lotNumber: (p["lot_number"] as? String) ?? "",
                    passToken: (p["pass_token"] as? String) ?? "",
                    genTime: (p["gen_time"] as? String) ?? "",
                    captchaOutput: (p["captcha_output"] as? String) ?? ""
                )
                Task { @MainActor in onSuccess(payload) }
            } else if type == "error" {
                let msg = (dict["message"] as? String) ?? "人机验证未完成，请重试。"
                Task { @MainActor in onError(msg) }
            }
        }
    }

    private static let html = """
    <!doctype html>
    <html lang="zh-CN">
      <head>
        <meta charset="UTF-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1.0" />
        <style>
          :root { color-scheme: light dark; font-family: -apple-system, sans-serif; }
          html, body { margin: 0; height: 100%; display: grid; place-items: center; background: transparent; }
          #captcha { width: min(340px, 92vw); min-height: 48px; }
          #status { font-size: 13px; color: #888; text-align: center; }
        </style>
      </head>
      <body>
        <div id="captcha"><p id="status">正在加载极验安全验证…</p></div>
        <script src="https://static.geetest.com/v4/gt4.js"></script>
        <script>
          (() => {
            const send = (type, extra) => window.webkit?.messageHandlers?.geetest?.postMessage({ type, ...extra });
            const st = document.getElementById("status");
            if (typeof window.initGeetest4 !== "function") {
              send("error", { message: "无法加载人机验证组件，请检查网络。" });
              return;
            }
            window.initGeetest4({
              captchaId: "3f7e2d848ce0cb7e7d019d621e556ce2",
              product: "popup",
              https: true,
              nativeButton: { width: "100%", height: "44px" }
            }, (captcha) => {
              st?.remove();
              captcha.appendTo("#captcha")
                .onReady(() => captcha.showCaptcha?.())
                .onSuccess(() => send("success", { payload: captcha.getValidate() }))
                .onError(() => send("error", { message: "人机验证没有完成，请重试。" }));
            });
          })();
        </script>
      </body>
    </html>
    """
}

// MARK: - Gacha Import / Export Sheet

struct WuwaGachaImportSheet: View {
    @Environment(WuwaStore.self) private var wuwa
    @Environment(\.dismiss) private var dismiss

    @State private var conveneUrl = ""
    @State private var showFileImporter = false
    @State private var exportURL: URL? = nil

    var body: some View {
        NavigationStack {
            Form {
                Section("国服唤取记录链接抓取") {
                    TextField("粘贴 https://aki-gm-resources.aki-game.com/aki/gacha/index.html...", text: $conveneUrl, axis: .vertical)
                        .lineLimit(3...6)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button {
                        Task {
                            if await wuwa.importConveneURL(conveneUrl) {
                                dismiss()
                            }
                        }
                    } label: {
                        HStack {
                            Spacer()
                            if wuwa.isImportingGacha {
                                ProgressView()
                            } else {
                                Text("读取全卡池记录").fontWeight(.semibold)
                            }
                            Spacer()
                        }
                    }
                    .disabled(wuwa.isImportingGacha || conveneUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                Section("WaveShelf 备份 JSON 互通") {
                    Button("从文件导入备份 JSON") {
                        showFileImporter = true
                    }
                    if !wuwa.pulls.isEmpty {
                        if let exportURL {
                            ShareLink("分享 / 导出当前唤取备份", item: exportURL)
                        } else {
                            Button("生成唤取备份 JSON") {
                                Task {
                                    if let data = try? await wuwa.exportBackupData() {
                                        let tmp = FileManager.default.temporaryDirectory
                                            .appendingPathComponent("waveshelf-gacha-backup.json")
                                        try? data.write(to: tmp, options: [.atomic])
                                        exportURL = tmp
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("导入唤取记录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                }
            }
            .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.json]) { result in
                guard case .success(let url) = result else { return }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                if let data = try? Data(contentsOf: url) {
                    Task {
                        if await wuwa.importBackupJSON(data) {
                            dismiss()
                        }
                    }
                }
            }
        }
    }
}
