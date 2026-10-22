import Foundation
import Network

/// 广告只提供候选身份，只有保存凭据认证和真实snapshot才能建立连接状态。
struct LanHost: Identifiable, Equatable {
    let id: String
    let name: String
    var paired: Bool
    var available = true
}

/// 发布给主线程的展示状态不包含配对材料；四位码仅在当前显式窗口内存在。
/// 可比较：引擎只在内容真正变化时投递，心跳和重复回调不会让整页 SwiftUI 重算。
struct LanLinkView: Equatable {
    var hosts: [LanHost] = []
    var selectedId: String?
    var status = "正在发现桌面端…"
    var error: String?
    var pairingCode: String?
    var connected = false
    var snapshot: LanDisplaySnapshot?
    var receivedDate: Date?
    var images: [String: LanImageAsset] = [:]
    var assetWarning: String?
    var backgroundRefreshError: String?
    var watch = PhoneWatchView()
}

/// 应用级串行网络owner，浏览/握手/Keychain/缓存共用代次，离开菜单不会销毁连接。
/// 连接流程见 `LanLinkEngine+Connection.swift`，展示与图片接收见 `LanLinkEngine+Display.swift`；
/// 成员为跨文件扩展放宽到模块内可见，但只能在 `queue` 上访问。
final class LanLinkEngine {
    /// 只描述当前线协议阶段，密码判断与尝试预算仍唯一归共享Rust。
    enum Phase { case idle, pairHello, pairConfirmation, pairClose, resumeReply, metadata, streaming, pausing }
    let queue = DispatchQueue(label: "LokiMetris.lan-link")
    /// 多帧解码与冷启动缓存校验可能耗时数百毫秒，放到独立低优先级串行队列，
    /// 网络队列不必等待，心跳与认证回复不受影响；串行也限制同时解码的峰值内存。
    let decoder = DispatchQueue(label: "LokiMetris.lan-decode", qos: .utility)
    let deviceId: String
    let store: PairingStore
    let backgroundTargets: BackgroundTargetStore
    let changed: (LanLinkView) -> Void
    var view = LanLinkView()
    var active = false
    struct BackgroundRun {
        let id: UUID
        let completion: (Bool) -> Void
        let timeout: DispatchWorkItem
    }
    var backgroundRun: BackgroundRun?
    var name = ""
    var browser: NWBrowser?
    var endpoints: [String: NWEndpoint] = [:]
    var paired: Set<String> = []
    var bridge: NativeLinkBridge?
    var socket: LanSocket?
    var phase: Phase = .idle
    var generation: UInt64 = 0
    var offer: [String: Any]?
    var pairingDeadline: UInt64?
    var deadline: UInt64?
    var lastInbound: UInt64 = 0
    var intent = LanConnectionPolicy()
    var retry: DispatchWorkItem?
    var timer: DispatchSourceTimer?
    /// 空闲（无连接且无期限）时挂起每秒检查；挂起与恢复必须成对。
    var timerSuspended = false
    var cache: IOSAssetCache?
    var currentAsset: LanDisplaySnapshot.Asset?
    var assetDeadline: UInt64?
    var failedAssets: Set<String> = []
    /// 已交给解码队列、结果尚未返回的图片摘要，避免重复校验和重复解码。
    var decodingImages: Set<String> = []
    var assetPaths: [String: URL] = [:]
    /// init 末尾必定赋值；隐式解包只为让构造闭包可在其它属性就绪后捕获 self。
    var watch: PhoneWatchBridge!
    var deviceType: LanDeviceFormFactorReport
    var watchCapability = false
    var watchNonce: NSNumber?
    var watchProjectionGeneration: UInt64?
    /// Watch 通信事实只用于向桌面上报，不进入界面投影。
    var watchFacts = WatchCompanionFacts()
    /// 上次投递给主线程的状态；相同则跳过，减少无意义的主线程唤醒。
    var lastPublished: LanLinkView?

    /// 构造不读凭据、不发网络；UI回调由薄模型映射到主线程。
    init(deviceId: String, formFactor: LanDeviceFormFactor?, changed: @escaping (LanLinkView) -> Void) {
        self.deviceId = deviceId; store = PairingStore(deviceId: deviceId); self.changed = changed
        backgroundTargets = BackgroundTargetStore(deviceId: deviceId)
        deviceType = LanDeviceFormFactorReport(formFactor: formFactor)
        watch = PhoneWatchBridge(phoneId: deviceId) { [weak self] value, facts, generation in
            self?.queue.async { [weak self] in
                guard let self, self.generation == generation else { return }
                self.watchProjectionGeneration = generation
                self.view.watch = value; self.watchFacts = facts; self.publish()
                if !value.reachable {
                    do { try self.reportWatch() } catch { self.fail(retry: true, message: "手表状态发送中断，正在重新连接。") }
                }
            }
        }
    }

    /// 失败后的重试入口；首次发现由前台生命周期自动开始。
    func discover(name: String) {
        queue.async {
            self.name = name; self.intent.discover(); self.view.error = nil
            self.startBrowser()
            if self.socket == nil, self.active {
                self.retry?.cancel(); self.retry = nil
                if self.pairingDeadline != nil { self.connect(pairing: true) }
                else if let browser = self.browser { self.browsed(browser.browseResults) }
            }
            self.publish()
        }
    }

    /// 手表重试只影响系统配套通道，不重开桌面配对或LAN认证。
    func retryWatch() { watch.retry() }

    /// 用户选中候选才允许首次开码；可信候选使用已有秘密恢复，不重新显示密码。
    func select(_ id: String, name: String) { queue.async { self.name = name; self.selectNow(id) } }

    /// 保存名称只更新下一次握手的配置，不重启正在运行的连接或密码窗口。
    func updateName(_ value: String) { queue.async { self.name = value } }

    /// 系统授予后台时间后仅恢复已配对服务，收到一份摘要即关闭，不开新配对窗口。
    func refreshInBackground(name: String, completion: @escaping (Bool) -> Void) {
        queue.async { [self] in
            guard !self.active, self.backgroundRun == nil else { completion(false); return }
            do {
                guard let target = try self.backgroundTargets.load(), try self.store.load(target.id) != nil else {
                    completion(false); return
                }
                self.cancelSession()
                self.name = name; self.view.selectedId = target.id
                self.endpoints = [target.id: .service(name: target.name, type: target.type, domain: target.domain, interface: nil)]
                let id = UUID()
                let timeout = DispatchWorkItem { [weak self] in
                    guard let self, self.backgroundRun?.id == id else { return }
                    self.finishBackgroundRefresh(success: false)
                }
                self.backgroundRun = BackgroundRun(id: id, completion: completion, timeout: timeout)
                self.queue.asyncAfter(deadline: .now() + 25, execute: timeout)
                self.resumeSelected()
            } catch { completion(false) }
        }
    }

    /// 到期与前台接管先撤销连接代次，再向系统确认结束。
    func cancelBackgroundRefresh(completion: @escaping () -> Void = {}) {
        queue.async { self.finishBackgroundRefresh(success: false); completion() }
    }

    /// 结束本次后台刷新：撤销连接代次、清空端点，再回调系统任务。
    func finishBackgroundRefresh(success: Bool) {
        guard let run = backgroundRun else { return }
        backgroundRun = nil; run.timeout.cancel()
        cancelSession(); endpoints = [:]
        view.status = "已暂停，回到前台后恢复"; view.error = nil
        publish(); run.completion(success)
    }

    /// 前后台由App拥有；后台尽力pause后关闭，恢复时仅使用现有信任认证。
    func setActive(_ active: Bool, name: String) {
        queue.async { [self] in
            if active, self.backgroundRun != nil { self.finishBackgroundRefresh(success: false) }
            guard active != self.active else { return }
            self.active = active; self.name = name
            if active {
                if self.phase == .pausing { self.cancelSession() }
                do {
                    self.paired = try self.store.clientIds()
                    self.view.backgroundRefreshError = nil
                    if self.view.selectedId == nil, let target = try self.backgroundTargets.load(), self.paired.contains(target.id) {
                        self.view.selectedId = target.id
                    }
                }
                catch { self.view.backgroundRefreshError = "配对记录暂不可读取，请解锁设备后重新打开 App。" }
                self.restoreCachedDisplay()
                self.intent.enterForeground()
                self.startBrowser()
            } else {
                self.clearLiveDisplay()
                self.intent.leaveForeground()
                self.watch.setParent(active: false, generation: self.generation)
                self.browser?.cancel(); self.browser = nil; self.endpoints = [:]; self.view.hosts = []
                if self.phase == .streaming {
                    do {
                        let token = self.generation
                        self.phase = .pausing
                        try self.sendSecure(["type": "pause"], completion: { [weak self] in
                            guard let self, self.generation == token, !self.active else { return }
                            self.cancelSession()
                        })
                    } catch { self.cancelSession() }
                } else { self.cancelSession() }
                self.view.status = "已暂停，回到前台后恢复"
                self.view.connected = false
            }
            self.publish()
        }
    }

    /// 忘记只删除精确双端Keychain记录，失败不改变本地信任列表。
    func forget(_ id: String) {
        queue.async {
            if self.view.selectedId == id { self.cancelSession(); self.clearLiveDisplay(clearCached: true); self.view.selectedId = nil }
            do {
                do { try self.backgroundTargets.forget(id) }
                catch { try self.backgroundTargets.reset() }
                guard try self.store.forget(id) else { throw WidgetSnapshotError.unavailable }
                self.watch.forgetHTTPSource(id)
                WidgetSnapshotPublisher.shared.forgetSource(id)
                self.paired.remove(id)
                self.view.hosts.removeAll { $0.id == id && !$0.available }
                self.refreshPairedHosts()
                self.view.status = "已忘记，可重新配对"; self.view.error = nil
            } catch { self.view.error = "未能删除配对记录，请重试。" }
            self.publish()
        }
    }

    /// 只有App投影进入主线程，完整材料和FFI结果不记录到日志；内容未变时不投递。
    func publish() {
        guard view != lastPublished else { return }
        lastPublished = view; changed(view)
    }
    /// 所有超时使用本机单调时间，墙钟变化不返还配对期限。
    var now: UInt64 { DispatchTime.now().uptimeNanoseconds }

    /// 有连接或期限时才需要每秒检查；空闲时挂起计时器，避免离线时持续唤醒。
    func setTickActive(_ active: Bool) {
        guard let timer, timerSuspended == active else { return }
        if active { timer.resume() } else { timer.suspend() }
        timerSuspended = !active
    }

    deinit {
        // 释放挂起中的 dispatch source 会崩溃，先恢复再取消。
        if timerSuspended { timer?.resume() }
        retry?.cancel(); timer?.cancel()
        let browser = browser, socket = socket, bridge = bridge, cache = cache
        queue.async { browser?.cancel(); socket?.close(); bridge?.close(); cache?.cancel() }
    }
}
