import SwiftUI

struct WuwaRootView: View {
    @Environment(WuwaStore.self) private var wuwa
    @Binding var showSettings: Bool

    @State private var path = NavigationPath()
    @State private var showAccountSheet = false
    @State private var showLoginSheet = false
    @State private var showGachaImport = false

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                sectionSwitcher
                    .padding(.horizontal, 16)
                    .padding(.top, 2)
                    .padding(.bottom, 10)

                switch wuwa.section {
                case .roles:
                    WuwaRolesView(onRequestLogin: { showLoginSheet = true })
                case .gacha:
                    WuwaGachaView(onOpenImport: { showGachaImport = true })
                case .calc:
                    WuwaCalcLabView(
                        onOpenResonator: { roleId in path.append(WuwaRoute.resonator(roleId)) },
                        onRequestLogin: { showLoginSheet = true }
                    )
                }
            }
            .background(AmbientBackground(tint: Color(hex: 0x2B93CF)))
            .navigationTitle("鸣潮")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showSettings = true
                        Haptics.tap()
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("设置")
                }

                ToolbarItem(placement: .topBarTrailing) {
                    if wuwa.section == .gacha {
                        Button {
                            showGachaImport = true
                            Haptics.tap()
                        } label: {
                            Image(systemName: "square.and.arrow.down")
                        }
                        .accessibilityLabel("导入唤取记录")
                    } else if wuwa.session != nil {
                        Button {
                            Haptics.tap()
                            Task { await wuwa.refreshCommunity(forceDetails: true) }
                        } label: {
                            if wuwa.isSyncing {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                        }
                        .disabled(wuwa.isSyncing)
                        .accessibilityLabel("同步面板")
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showAccountSheet = true
                        Haptics.tap()
                    } label: {
                        Image(systemName: wuwa.session == nil ? "person.crop.circle.badge.exclamationmark" : "person.crop.circle")
                    }
                    .accessibilityLabel("库街区账号")
                }
            }
            .navigationDestination(for: WuwaRoute.self) { route in
                switch route {
                case .resonator(let roleId):
                    WuwaResonatorDetailView(roleId: roleId)
                        .toolbar(.hidden, for: .tabBar)
                }
            }
        }
        .task {
            await wuwa.bootstrapIfNeeded()
        }
        .sheet(isPresented: $showAccountSheet) {
            WuwaAccountSheet(
                onOpenLogin: {
                    showAccountSheet = false
                    showLoginSheet = true
                },
                onOpenGachaImport: {
                    showAccountSheet = false
                    showGachaImport = true
                }
            )
        }
        .sheet(isPresented: $showLoginSheet) {
            WuwaLoginSheet()
        }
        .sheet(isPresented: $showGachaImport) {
            WuwaGachaImportSheet()
        }
    }

    private var sectionSwitcher: some View {
        @Bindable var bindable = wuwa
        return Picker("鸣潮模块", selection: $bindable.section) {
            ForEach(WuwaSection.allCases) { item in
                Text(item.title).tag(item)
            }
        }
        .pickerStyle(.segmented)
        .onChange(of: wuwa.section) { _, _ in
            Haptics.selection()
        }
    }
}
