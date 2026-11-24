import SwiftUI
import UIKit

@main
struct RelayApp: App {
    @State private var store = AppStore()
    @AppStorage(SettingsKey.appearance) private var appearance: AppearanceMode = .system

    init() {
        UserDefaults.standard.register(defaults: [SettingsKey.haptics: true])
        // Editorial serif large titles (New York) for a calm, premium navigation feel.
        let large = UIFont.systemFont(ofSize: 34, weight: .bold)
        if let serif = large.fontDescriptor.withDesign(.serif) {
            UINavigationBar.appearance().largeTitleTextAttributes = [.font: UIFont(descriptor: serif, size: 34)]
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .preferredColorScheme(appearance.colorScheme)
                .onOpenURL { url in
                    store.handleDeepLink(url)
                }
        }
    }
}

struct RootView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            if store.isPaired {
                SessionListView()
                    .transition(.opacity.combined(with: .scale(scale: 1.02)))
            } else {
                ConnectView()
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .animation(.spring(response: 0.55, dampingFraction: 0.88), value: store.isPaired)
        .overlay(alignment: .top) {
            if let banner = store.banner {
                BannerView(banner: banner)
                    .padding(.top, 4)
                    .padding(.horizontal, 20)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .onTapGesture {
                        withAnimation(.easeOut(duration: 0.2)) { store.banner = nil }
                    }
            }
        }
        .task(id: store.isPaired) {
            if store.isPaired {
                await store.start()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            store.scenePhaseChanged(phase)
        }
        .alert(
            "连接到新的 Relay 服务端？",
            isPresented: Binding(
                get: { store.pendingPairing != nil },
                set: { presented in
                    if !presented { store.pendingPairing = nil }
                }
            ),
            presenting: store.pendingPairing
        ) { request in
            Button("连接") {
                Task { await store.confirmPairing(request) }
            }
            Button("取消", role: .cancel) {}
        } message: { request in
            Text("\(request.serverURL)\n令牌将安全保存在钥匙串中。")
        }
    }
}

struct BannerView: View {
    var banner: Banner

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: banner.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(banner.isError ? Palette.danger : Palette.success)
                .font(.system(size: 15, weight: .semibold))
            Text(banner.message)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .glassCapsule()
        .accessibilityElement(children: .combine)
    }
}
