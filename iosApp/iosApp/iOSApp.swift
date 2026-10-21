import SwiftUI

@main
struct iOSApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var settings: DeviceSettings
    @StateObject private var link: LanLinkModel

    /// 本机设置和网络owner固定为同一根实例，显示与多窗口共享应用身份。
    init() {
        BackgroundRefreshScheduler.shared.register()
        let settings = DeviceSettings()
        let link = LanLinkModel(settings: settings)
        _settings = StateObject(wrappedValue: settings)
        _link = StateObject(wrappedValue: link)
        BackgroundRefreshScheduler.shared.configure(model: link)
    }

    var body: some Scene {
        WindowGroup {
            ContentView(settings: settings, link: link)
                .onChange(of: settings.deviceName) { _, _ in link.settingsChanged() }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            // App-level phase aggregates all windows, so iPad windows share one
            // advertisement and one inactive window cannot stop an active one.
            switch phase {
            case .active: link.setActive(true)
            case .background:
                link.setActive(false)
                BackgroundRefreshScheduler.shared.scheduleNextRefresh()
            case .inactive: break // 权限弹窗等短暂失焦不应关闭刚开启的配对窗口。
            @unknown default: break
            }
        }
    }
}
