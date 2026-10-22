import SwiftUI
import SharedLogic

/// 两个主入口共享同一应用连接；切页与面板配置都不改变连接生命周期。
@MainActor
struct ContentView: View {
    private enum Menu: Hashable { case panel, settings }
    @ObservedObject var settings: DeviceSettings
    @ObservedObject var link: LanLinkModel
    @StateObject private var displayState = WidgetDisplayState.shared
    @State private var selected: Menu = .panel
    @State private var nameDraft: String
    @State private var nameFeedback: String?
    @State private var forgetCandidate: LanHost?
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage("panel.showUsage") private var showUsage = PanelConfiguration.companion.defaults().showUsage
    @AppStorage("panel.showHooks") private var showHooks = PanelConfiguration.companion.defaults().showHooks
    @AppStorage("panel.usageDetail") private var usageDetail = PanelConfiguration.companion.defaults().usageDetail.key
    @AppStorage("panel.hookLayout") private var hookLayout = PanelConfiguration.companion.defaults().hookLayout.key

    /// AppStorage 负责系统持久化，未知选项恢复与默认布局由共享配置决定。
    private var panelConfiguration: PanelConfiguration {
        PanelConfiguration.companion.restore(showUsage: showUsage, showHooks: showHooks,
                                             detail: usageDetail, hookLayout: hookLayout)
    }

    private var appDisplayName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "LokiMetris"
    }

    init(settings: DeviceSettings, link: LanLinkModel) {
        self.settings = settings
        self.link = link
        _nameDraft = State(initialValue: settings.deviceName)
    }

    var body: some View {
        navigation
            .tint(DisplayStyle.accent)
            .preferredColorScheme(.dark)
    }

    @ViewBuilder private var navigation: some View {
        if horizontalSizeClass == .regular {
            NavigationSplitView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack(spacing: 10) {
                        Image(systemName: "square.stack.3d.up.fill").foregroundStyle(DisplayStyle.accent)
                        Text(appDisplayName).font(.headline)
                    }.padding(.horizontal, 24).padding(.top, 30)
                    VStack(spacing: 8) {
                        sidebarItem(.panel, title: "展示台", symbol: "square.grid.2x2")
                        sidebarItem(.settings, title: "设置", symbol: "slider.horizontal.3")
                    }.padding(.horizontal, 12)
                    Spacer()
                    Text(settings.deviceName).font(.caption).foregroundStyle(.secondary)
                        .padding(24)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(DisplayStyle.canvas)
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 260)
            } detail: {
                if selected == .panel { panelNavigation } else { settingsNavigation }
            }
            .navigationSplitViewStyle(.balanced)
            // 主入口切换时清空分栏容器保留的子导航，连接模型仍由 App 根实例持有。
            .id(selected)
        } else {
            TabView(selection: $selected) {
                panelNavigation
                    .tabItem { Label("展示台", systemImage: "square.grid.2x2") }
                    .tag(Menu.panel).accessibilityIdentifier("menu-panel")
                settingsNavigation
                    .tabItem { Label("设置", systemImage: "slider.horizontal.3") }
                    .tag(Menu.settings).accessibilityIdentifier("menu-settings")
            }
        }
    }

    private var panelNavigation: some View {
        NavigationStack {
            LanDisplayPage(state: panelState, snapshot: panelSnapshot,
                widgetSharingError: displayState.sharingError,
                configuration: panelConfiguration,
                openSettings: { selected = .settings },
                motionEnabled: selected == .panel)
                .navigationTitle("")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar(horizontalSizeClass == .regular ? .visible : .hidden, for: .navigationBar)
        }
    }

    private var settingsNavigation: some View {
        NavigationStack {
            settingsPage.navigationTitle("设置").navigationBarTitleDisplayMode(.large)
                .toolbarBackground(DisplayStyle.canvas, for: .navigationBar)
        }
    }

    /// iPad 侧边栏的一项菜单。
    private func sidebarItem(_ menu: Menu, title: String, symbol: String) -> some View {
        Button { selected = menu } label: {
            Label(title, systemImage: symbol).font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading).padding(14)
                .foregroundStyle(selected == menu ? DisplayStyle.accent : Color.primary)
                .background(selected == menu ? DisplayStyle.accent.opacity(0.09) : .clear,
                            in: RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(CyberPressStyle()).accessibilityIdentifier(menu == .panel ? "menu-panel" : "menu-settings")
            .accessibilityAddTraits(selected == menu ? .isSelected : [])
    }

    private var panelPreferences: some View {
        PanelPreferencesView(showUsage: $showUsage, showHooks: $showHooks,
                             usageDetail: $usageDetail, hookLayout: $hookLayout)
    }

    /// 离线也展示引擎校验过的最近缓存，连接状态仍由当前认证会话决定。
    private var panelSnapshot: LanDisplaySnapshot? { link.state.snapshot }
    private var panelState: LanLinkView { link.state }


    private var settingsPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                connectionSettings
                if let code = link.state.pairingCode { pairingSettings(code) }
                settingsSection("面板") {
                    NavigationLink { panelPreferences } label: {
                        SettingsCard {
                            HStack(spacing: 12) {
                                SettingsLabel(title: "自定义面板", subtitle: panelDescription, symbol: "slider.horizontal.3")
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                    }
                    .buttonStyle(CyberPressStyle()).foregroundStyle(.primary)
                    .accessibilityIdentifier("settings-panel")
                }
                deviceSettings
                extensionSettings
            }
            .frame(maxWidth: 680)
            .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 36)
            .frame(maxWidth: .infinity)
        }
        .background(DisplayStyle.canvas)
        .environment(\.cyberMotionEnabled, selected == .settings)
        .confirmationDialog("忘记此桌面的本机配对？", isPresented: Binding(
            get: { forgetCandidate != nil }, set: { if !$0 { forgetCandidate = nil } })) {
                if let host = forgetCandidate {
                    Button("忘记此桌面", role: .destructive) { link.forget(host.id); forgetCandidate = nil }
                }
                Button("取消", role: .cancel) { forgetCandidate = nil }
        } message: { Text("再次连接需要重新输入配对码。") }
    }

    private var connectionSettings: some View {
        settingsSection("桌面连接") {
            SettingsCard {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .top, spacing: 12) {
                        SettingsIconTile(symbol: link.state.connected ? "checkmark.circle" : "antenna.radiowaves.left.and.right")
                        VStack(alignment: .leading, spacing: 6) {
                            Text(link.state.connected ? "已连接桌面" : "正在查找桌面")
                                .font(.headline).foregroundStyle(.primary)
                            Text(link.state.status).font(.subheadline).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("devices-status")
                            if !link.state.connected, link.state.snapshot != nil, let received = link.state.receivedDate {
                                Text("显示缓存 · 上次同步 \(received.formatted(.dateTime.month(.twoDigits).day(.twoDigits).hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)))")
                                    .font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Spacer(minLength: 0)
                        Circle().fill(link.state.connected ? DisplayStyle.accent : Color.secondary.opacity(0.5))
                            .frame(width: 7, height: 7).padding(.top, 8).accessibilityHidden(true)
                    }
                    if let error = settings.identityError ?? link.state.error {
                        VStack(alignment: .leading, spacing: 12) {
                            Label(error, systemImage: "exclamationmark.circle")
                                .font(.footnote).foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("discoveryError")
                            if settings.identityError == nil {
                                Button("重试连接", action: link.discover)
                                    .font(.subheadline.weight(.semibold)).buttonStyle(.bordered).controlSize(.large)
                            }
                        }
                    }
                    if link.state.hosts.isEmpty {
                        Divider().overlay(Color.white.opacity(0.04))
                        Text("在同一 Wi-Fi 下打开桌面端，并允许本地网络访问。发现后会显示在这里。")
                            .font(.footnote).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        ForEach(link.state.hosts) { host in
                            Divider().overlay(Color.white.opacity(0.04))
                            desktopRow(host)
                        }
                    }
                }
            }
        }
    }

    /// 首次配对时展示四位码，只在配对窗口内存在。
    private func pairingSettings(_ code: String) -> some View {
        settingsSection("完成配对") {
            SettingsCard {
                VStack(alignment: .leading, spacing: 14) {
                    Label("在桌面输入配对码", systemImage: "keyboard")
                        .font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                    Text(code).font(.system(.largeTitle, design: .rounded).weight(.semibold).monospacedDigit())
                        .tracking(8).foregroundStyle(DisplayStyle.accent)
                        .lineLimit(1).minimumScaleFactor(0.5)
                        .privacySensitive().accessibilityIdentifier("pairing-code")
                    Text("60 秒内有效，请保持应用在前台。")
                        .font(.footnote).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var deviceSettings: some View {
        settingsSection("本机") {
            SettingsCard {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("设备名称").font(.subheadline.weight(.medium))
                        if dynamicTypeSize.isAccessibilitySize {
                            VStack(alignment: .leading, spacing: 10) { nameField; saveNameButton }
                        } else {
                            HStack(spacing: 12) { nameField; saveNameButton }
                        }
                        if let error = MdnsProtocol.shared.nameError(name: nameDraft) {
                            Text(error).font(.footnote).foregroundStyle(.red)
                        }
                        if let nameFeedback {
                            Text(nameFeedback).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    Divider().overlay(Color.white.opacity(0.04))
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 14) {
                            LabeledContent("设备 ID") {
                                Text(settings.deviceId).font(.caption.monospaced()).textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            LabeledContent("应用", value: appDisplayName)
                        }.font(.subheadline).padding(.top, 14)
                    } label: {
                        Label("设备信息", systemImage: "info.circle").font(.subheadline)
                    }
                }
            }
        }
    }

    private var nameField: some View {
        TextField("设备名称", text: $nameDraft)
            .font(.body).textInputAutocapitalization(.never).autocorrectionDisabled()
            .padding(.horizontal, 13).padding(.vertical, 12)
            .background(DisplayStyle.canvas.opacity(0.8), in: RoundedRectangle(cornerRadius: 11))
            .overlay { RoundedRectangle(cornerRadius: 11).strokeBorder(Color.white.opacity(0.08), lineWidth: 1) }
            .accessibilityLabel("设备名称").accessibilityIdentifier("settings-device-name")
            .onChange(of: nameDraft) { _, _ in nameFeedback = nil }
    }

    @ViewBuilder private var saveNameButton: some View {
        if nameDraft != settings.deviceName {
            Button("保存") {
                nameFeedback = settings.saveDeviceName(nameDraft)
                    ? "已保存，下次连接生效" : "保存失败，请重试"
            }
            .font(.subheadline.weight(.semibold)).buttonStyle(.borderedProminent).controlSize(.large)
            .disabled(MdnsProtocol.shared.nameError(name: nameDraft) != nil || settings.identityError != nil)
            .accessibilityIdentifier("settings-save-name")
        }
    }

    private var extensionSettings: some View {
        settingsSection("扩展") {
            SettingsCard {
                VStack(alignment: .leading, spacing: 18) {
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 12) { watchStatus }
                            .padding(.top, 14)
                    } label: {
                        SettingsLabel(title: "Apple Watch", subtitle: "自动同步手机数据", symbol: "applewatch")
                    }
                    Divider().overlay(Color.white.opacity(0.04))
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("在系统小组件列表添加“\(appDisplayName)”。").font(.subheadline)
                            Text("显示最近摘要与同步时间。连接新版桌面端后，小组件可按系统调度独立通过 HTTP 获取摘要；服务地址每次连通时自动更新。电脑需在同一局域网，申请约 \(Int(WidgetSnapshot.refreshInterval / 60)) 分钟后刷新，实际时间由系统安排。")
                                .font(.footnote).foregroundStyle(.secondary)
                            if let error = link.state.backgroundRefreshError {
                                Text(error).font(.footnote).foregroundStyle(.secondary)
                            }
                        }.fixedSize(horizontal: false, vertical: true).padding(.top, 14)
                    } label: {
                        SettingsLabel(title: "桌面与锁屏小组件", subtitle: "在主屏幕快速浏览", symbol: "rectangle.on.rectangle")
                    }
                }
            }
        }
    }

    /// 设置页分组：标题加内容卡片。
    private func settingsSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.leading, 4).accessibilityAddTraits(.isHeader)
            content()
        }
    }

    private var panelDescription: String {
        let configuration = panelConfiguration
        let cards = [configuration.showUsage ? "用量" : nil,
                     configuration.showHooks ? "Hooks \(HookLayout(shared: configuration.hookLayout).title)" : nil].compactMap { $0 }
        return cards.isEmpty ? "尚未选择卡片" : cards.joined(separator: " · ")
    }

    /// 一台已发现或已配对的桌面，包含连接与忘记操作。
    private func desktopRow(_ host: LanHost) -> some View {
        let connected = link.state.connected && link.state.selectedId == host.id
        return VStack(alignment: .leading, spacing: 12) {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 12) {
                    desktopIdentity(host, connected: connected)
                    desktopAction(host, connected: connected)
                }
            } else {
                HStack(alignment: .center, spacing: 12) {
                    desktopIdentity(host, connected: connected)
                    Spacer(minLength: 0)
                    desktopAction(host, connected: connected)
                }
            }
            if host.paired {
                Button("忘记此桌面", role: .destructive) { forgetCandidate = host }
                    .font(.footnote).buttonStyle(.borderless)
                    .frame(minHeight: 44, alignment: .leading)
                    .accessibilityIdentifier("host-forget-" + host.id)
            }
        }
    }

    /// 桌面名称与配对状态。
    private func desktopIdentity(_ host: LanHost, connected: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "desktopcomputer").font(.system(size: 20)).foregroundStyle(.secondary)
                .frame(width: 28).padding(.top, 2).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(host.name).font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(connected ? "当前桌面" : host.paired ? (host.available ? "已配对" : "已配对 · 暂未发现") : "可配对")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// 配对 / 连接按钮；当前已连接或暂未发现时禁用。
    private func desktopAction(_ host: LanHost, connected: Bool) -> some View {
        Button(connected ? "已连接" : host.paired ? "连接" : "配对") { link.select(host.id) }
            .font(.subheadline.weight(.semibold)).buttonStyle(.bordered).controlSize(.large)
            .disabled(!host.available || connected)
            .accessibilityIdentifier("host-connect-" + host.id)
    }

    @ViewBuilder
    private var watchStatus: some View {
        Text("用量、额度和 Hooks 默认显示。手表自动读取 iPhone 的缓存，应用内无需再次配对或设置。")
            .font(.subheadline).foregroundStyle(.secondary)
        if let watch = link.state.watch.info {
            LabeledContent("名称", value: watch.name)
            Text(link.state.watch.reachable ? "手表应用可通信" : "手表应用暂不可通信")
                .font(.subheadline).foregroundStyle(.secondary)
            if let date = link.state.watch.lastSync {
                Text("最近同步 " + date.formatted(date: .abbreviated, time: .shortened)).font(.caption)
            }
        } else { Text("在手表上打开\(appDisplayName)即可同步。").font(.subheadline).foregroundStyle(.secondary) }
        if let error = link.state.watch.error { Text(error).font(.caption).foregroundStyle(.secondary) }
        Button("重试手表同步", action: link.retryWatch)
            .font(.subheadline.weight(.semibold)).buttonStyle(.bordered).controlSize(.large)
            .disabled(!link.state.connected)
    }
}

#Preview {
    let settings = DeviceSettings()
    ContentView(settings: settings, link: LanLinkModel(settings: settings))
}
