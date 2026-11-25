import SwiftUI

/// Brand mark rendered directly from the unified AI App Icon artwork (`RelayBrandIcon`).
struct RelayMark: View {
    var size: CGFloat = 88

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
        Image("RelayBrandIcon")
            .resizable()
            .interpolation(.high)
            .scaledToFill()
            .frame(width: size, height: size)
            .clipShape(shape)
            .overlay(
                shape.stroke(Palette.hairlineStrong, lineWidth: 0.6)
            )
            .shadow(color: .black.opacity(0.18), radius: size * 0.14, y: size * 0.06)
            .accessibilityHidden(true)
    }
}

struct ConnectView: View {
    @Environment(AppStore.self) private var store
    @State private var serverURL = ""
    @State private var token = ""
    @State private var revealToken = false
    @State private var appeared = false
    @FocusState private var focus: Field?

    private enum Field: Hashable {
        case url
        case token
    }

    private var canConnect: Bool {
        !serverURL.trimmingCharacters(in: .whitespaces).isEmpty && !store.isConnecting
    }

    var body: some View {
        ZStack {
            AmbientBackground(tint: Color(hex: 0x6E73F0))

            ScrollView {
                VStack(spacing: 30) {
                    Spacer(minLength: 56)

                    RelayMark(size: 96)
                        .scaleEffect(appeared ? 1 : 0.86)
                        .opacity(appeared ? 1 : 0)

                    VStack(spacing: 10) {
                        Text("Relay")
                            .font(RelayFont.display(46))
                            .foregroundStyle(Palette.textPrimary)
                        Text("你的私有 Agent 控制台")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(Palette.textSecondary)
                        HStack(spacing: 8) {
                            ForEach(["零遥测", "自托管", "原生"], id: \.self) { tag in
                                Text(tag)
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .tracking(0.6)
                                    .foregroundStyle(Palette.textSecondary)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(Capsule().fill(Palette.fieldFill))
                            }
                        }
                        .padding(.top, 4)
                    }
                    .offset(y: appeared ? 0 : 12)
                    .opacity(appeared ? 1 : 0)

                    VStack(spacing: 0) {
                        fieldRow(icon: "server.rack", label: "服务端地址") {
                            TextField("https://relay.example.com", text: $serverURL)
                                .keyboardType(.URL)
                                .textContentType(.URL)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .focused($focus, equals: .url)
                                .submitLabel(.next)
                                .onSubmit { focus = .token }
                        }
                        Divider().overlay(Palette.hairline).padding(.leading, 52)
                        fieldRow(icon: "key.horizontal", label: "访问令牌") {
                            HStack {
                                Group {
                                    if revealToken {
                                        TextField("RELAY_TOKEN", text: $token)
                                    } else {
                                        SecureField("RELAY_TOKEN", text: $token)
                                    }
                                }
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .focused($focus, equals: .token)
                                .submitLabel(.go)
                                .onSubmit(connect)

                                Button {
                                    revealToken.toggle()
                                    Haptics.selection()
                                } label: {
                                    Image(systemName: revealToken ? "eye.slash" : "eye")
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundStyle(Palette.textTertiary)
                                        .contentTransition(.symbolEffect(.replace))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .glassRounded(26)
                    .offset(y: appeared ? 0 : 20)
                    .opacity(appeared ? 1 : 0)

                    if let error = store.connectError {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.circle.fill")
                            Text(error)
                                .multilineTextAlignment(.leading)
                        }
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(Palette.danger)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                    Button(action: connect) {
                        ZStack {
                            if store.isConnecting {
                                ProgressView()
                                    .tint(.white)
                            } else {
                                HStack(spacing: 8) {
                                    Text("连接")
                                    Image(systemName: "arrow.right")
                                }
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(.white)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                        .background(
                            Capsule(style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: [Color(hex: 0x7C83FF), Color(hex: 0x4B4FCF)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                        )
                        .overlay(Capsule(style: .continuous).stroke(Color.white.opacity(0.25), lineWidth: 0.6))
                        .shadow(color: Color(hex: 0x5B5FE0).opacity(0.45), radius: 18, y: 8)
                        .opacity(canConnect ? 1 : 0.5)
                    }
                    .buttonStyle(.pressable)
                    .disabled(!canConnect)

                    VStack(spacing: 6) {
                        Text("也可以在 iPhone 上打开配对链接一键连接")
                        Text("relay://connect?url=…&token=…")
                            .font(RelayFont.mono(12))
                            .foregroundStyle(Palette.textTertiary)
                    }
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 4)

                    Spacer(minLength: 40)
                }
                .padding(.horizontal, 24)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: store.connectError)
        .onAppear {
            if serverURL.isEmpty { serverURL = store.serverURLString }
            withAnimation(.spring(response: 0.8, dampingFraction: 0.82).delay(0.05)) {
                appeared = true
            }
        }
    }

    private func fieldRow<Content: View>(icon: String, label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color(hex: 0x8E9BFF))
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 4) {
                Text(label)
                    .font(RelayFont.eyebrow)
                    .tracking(0.8)
                    .foregroundStyle(Palette.textTertiary)
                content()
                    .font(.system(size: 16))
                    .foregroundStyle(Palette.textPrimary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private func connect() {
        guard canConnect else { return }
        focus = nil
        Task {
            await store.connect(serverURL: serverURL, token: token)
        }
    }
}
