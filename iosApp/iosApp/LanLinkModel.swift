import SwiftUI
import UIKit

/// 仅将应用级网络状态映射为Published，不在菜单render或按钮handler里执行文件/密码操作。
@MainActor
final class LanLinkModel: ObservableObject {
    @Published private(set) var state = LanLinkView()
    private let settings: DeviceSettings
    private var engine: LanLinkEngine?

    /// 同一App根视图拥有一份连接owner，多窗口与切菜单不会创建第二条会话。
    init(settings: DeviceSettings) {
        self.settings = settings
        guard settings.identityError == nil, SharedValidation.validId(settings.deviceId) else {
            return
        }
        let delivery = LanProjectionDelivery<LanLinkView> { [weak self] value in
            self?.state = value
        }
        let formFactor: LanDeviceFormFactor?
        switch UIDevice.current.userInterfaceIdiom {
        case .phone: formFactor = .phone
        case .pad: formFactor = .tablet
        default: formFactor = nil
        }
        engine = LanLinkEngine(deviceId: settings.deviceId, formFactor: formFactor) { value in delivery.submit(value) }
    }

    /// 发现失败后重试，使用最近保存名称供下一次连接使用。
    func discover() {
        guard settings.identityError == nil else { return }
        engine?.discover(name: settings.deviceName)
    }

    /// 候选自身的语义按钮拥有连接动作，页面与周围区域不代理。
    func select(_ id: String) { engine?.select(id, name: settings.deviceName) }
    /// 忘记操作只影响用户明确选择的桌面身份。
    func forget(_ id: String) { engine?.forget(id) }
    /// 只有应用前后台变化驱动暂停，普通菜单切换没有生命周期副作用。
    func setActive(_ active: Bool) { engine?.setActive(active && settings.identityError == nil, name: settings.deviceName) }
    /// 完成回调固定返回主线程，系统任务不使用页面是否渲染来判断成功。
    func refreshInBackground(completion: @escaping (Bool) -> Void) {
        guard settings.identityError == nil, let engine else { completion(false); return }
        engine.refreshInBackground(name: settings.deviceName) { success in
            DispatchQueue.main.async { completion(success) }
        }
    }
    /// 到期或前台接管时撤销后台连接代次，完成回调切回主线程。
    func cancelBackgroundRefresh(completion: @escaping () -> Void = {}) {
        guard let engine else { completion(); return }
        engine.cancelBackgroundRefresh { DispatchQueue.main.async { completion() } }
    }
    /// 明确重试配套同步，不改变当前桌面会话。
    func retryWatch() { engine?.retryWatch() }
    /// 名称保存通知只更新配置，现有连接继续原会话。
    func settingsChanged() { engine?.updateName(settings.deviceName) }
}
