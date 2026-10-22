import SwiftUI
import UIKit

/// 仅将应用级网络状态映射为Published，不在菜单render或按钮handler里执行文件/密码操作。
@MainActor
final class LanLinkModel: ObservableObject {
    @Published private(set) var state = LanLinkView()
    private let settings: DeviceSettings
    private var engine: LanLinkEngine?
    private var delivery: LanProjectionDelivery<LanLinkView>?
    private var generation: UInt64 = 0
    private var active = false
    private var recovering = false

    /// 同一App根视图拥有一份连接owner，多窗口与切菜单不会创建第二条会话。
    init(settings: DeviceSettings) {
        self.settings = settings
        createEngine()
    }
    /// 按当前身份创建网络引擎；身份不可用时不创建，界面显示错误。
    private func createEngine() {
        generation &+= 1
        guard settings.identityError == nil, SharedValidation.validId(settings.deviceId) else {
            engine = nil; delivery = nil; return
        }
        let token = generation
        let delivery = LanProjectionDelivery<LanLinkView> { [weak self] value in
            guard let self, self.generation == token, !self.recovering else { return }
            self.state = value
        }
        self.delivery = delivery
        let formFactor: LanDeviceFormFactor?
        switch UIDevice.current.userInterfaceIdiom {
        case .phone: formFactor = .phone
        case .pad: formFactor = .tablet
        default: formFactor = nil
        }
        engine = LanLinkEngine(deviceId: settings.deviceId, formFactor: formFactor) { value in delivery.submit(value) }
    }

    /// 导出加密的配对恢复材料，结果回到主线程。
    func exportPairingRecovery(completion: @escaping (Result<PairingRecovery.Exported, Error>) -> Void) {
        guard !recovering, let engine else { completion(.failure(WidgetSnapshotError.unavailable)); return }
        engine.exportPairingRecovery(completion: completion)
    }

    /// 停止旧连接后在后台提交恢复事务；完成前不允许生命周期或后台任务重连。
    func restorePairing(_ payload: PairingRecovery.Payload, completion: @escaping (Bool) -> Void) {
        guard !recovering else { completion(false); return }
        recovering = true; generation &+= 1
        let originalId = settings.deviceId
        let stopped = { [weak self] in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Result { try DeviceIdentityStore().restoreAndVerify(payload: payload, currentDeviceId: originalId) }
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.engine = nil; self.delivery = nil
                    self.settings.reloadIdentity()
                    self.state = LanLinkView()
                    self.recovering = false
                    let restored = (try? result.get()) == payload.deviceId && self.settings.deviceId == payload.deviceId && self.settings.identityError == nil
                    if restored { WidgetSnapshotPublisher.shared.invalidate(clearShared: true) }
                    self.createEngine()
                    self.engine?.setActive(self.active && self.settings.identityError == nil, name: self.settings.deviceName)
                    completion(restored)
                }
            }
        }
        if let engine { engine.stopForRecovery(completion: stopped) } else { stopped() }
    }

    /// 发现失败后重试，使用最近保存名称供下一次连接使用。
    func discover() {
        guard !recovering, settings.identityError == nil else { return }
        engine?.discover(name: settings.deviceName)
    }

    /// 候选自身的语义按钮拥有连接动作，页面与周围区域不代理。
    func select(_ id: String) { if !recovering { engine?.select(id, name: settings.deviceName) } }
    /// 忘记操作只影响用户明确选择的桌面身份。
    func forget(_ id: String) { if !recovering { engine?.forget(id) } }
    /// 只有应用前后台变化驱动暂停，普通菜单切换没有生命周期副作用。
    func setActive(_ active: Bool) { self.active = active; if !recovering { engine?.setActive(active && settings.identityError == nil, name: settings.deviceName) } }
    /// 完成回调固定返回主线程，系统任务不使用页面是否渲染来判断成功。
    func refreshInBackground(completion: @escaping (Bool) -> Void) {
        guard !recovering, settings.identityError == nil, let engine else { completion(false); return }
        engine.refreshInBackground(name: settings.deviceName) { success in
            DispatchQueue.main.async { completion(success) }
        }
    }
    /// 到期或前台接管时撤销后台连接代次，完成回调切回主线程。
    func cancelBackgroundRefresh(completion: @escaping () -> Void = {}) {
        guard let engine else { completion(); return }
        engine.cancelBackgroundRefresh { DispatchQueue.main.async { completion() } }
    }
    /// 手动获取当前桌面展示快照，不创建新的配对或提供商登录。
    func requestSnapshot() { if !recovering { engine?.requestSnapshot() } }
    /// 明确重试配套同步，不改变当前桌面会话。
    func retryWatch() { if !recovering { engine?.retryWatch() } }
    /// 名称保存通知只更新配置，现有连接继续原会话。
    func settingsChanged() { if !recovering { engine?.updateName(settings.deviceName) } }
}
