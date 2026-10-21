import Foundation
import Network

/// 广告只提供候选身份，只有保存凭据认证和真实snapshot才能建立连接状态。
struct LanHost: Identifiable {
    let id: String
    let name: String
    let paired: Bool
    var available = true
}

/// 发布给主线程的展示状态不包含配对材料；四位码仅在当前显式窗口内存在。
struct LanLinkView {
    var hosts: [LanHost] = []
    var requested = false
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
final class LanLinkEngine {
    /// 只描述当前线协议阶段，密码判断与尝试预算仍唯一归共享Rust。
    private enum Phase { case idle, pairHello, pairConfirmation, pairClose, resumeReply, metadata, streaming, pausing }
    private let queue = DispatchQueue(label: "LokiMetris.lan-link")
    private let deviceId: String
    private let store: PairingStore
    private let backgroundTargets: BackgroundTargetStore
    private let changed: (LanLinkView) -> Void
    private var view = LanLinkView()
    private var active = false
    private struct BackgroundRun {
        let id: UUID
        let completion: (Bool) -> Void
        let timeout: DispatchWorkItem
    }
    private var backgroundRun: BackgroundRun?
    private var name = ""
    private var browser: NWBrowser?
    private var endpoints: [String: NWEndpoint] = [:]
    private var paired: Set<String> = []
    private var bridge: NativeLinkBridge?
    private var socket: LanSocket?
    private var phase: Phase = .idle
    private var generation: UInt64 = 0
    private var offer: [String: Any]?
    private var pairingDeadline: UInt64?
    private var deadline: UInt64?
    private var lastInbound: UInt64 = 0
    private var intent = LanConnectionPolicy()
    private var retry: DispatchWorkItem?
    private var timer: DispatchSourceTimer?
    private var cache: IOSAssetCache?
    private var currentAsset: LanDisplaySnapshot.Asset?
    private var assetDeadline: UInt64?
    private var failedAssets: Set<String> = []
    private var assetPaths: [String: URL] = [:]
    private var watch: PhoneWatchBridge?
    private var deviceType: LanDeviceFormFactorReport
    private var watchCapability = false
    private var watchNonce: NSNumber?
    private var watchProjectionGeneration: UInt64?

    /// 构造不读凭据、不发网络；UI回调由薄模型映射到主线程。
    init(deviceId: String, formFactor: LanDeviceFormFactor?, changed: @escaping (LanLinkView) -> Void) {
        self.deviceId = deviceId; store = PairingStore(deviceId: deviceId); self.changed = changed
        backgroundTargets = BackgroundTargetStore(deviceId: deviceId)
        deviceType = LanDeviceFormFactorReport(formFactor: formFactor)
        watch = PhoneWatchBridge(phoneId: deviceId) { [weak self] value, generation in
            self?.queue.async { [weak self] in
                guard let self, self.generation == generation else { return }
                self.watchProjectionGeneration = generation
                self.view.watch = value; self.publish()
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
    func retryWatch() { watch?.retry() }

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

    private func finishBackgroundRefresh(success: Bool) {
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
                do { try IOSDisplayCache.store().discardLegacy() }
                catch { self.view.assetWarning = "旧展示快照未能清理，当前不会恢复或使用其中的数据。" }
                do {
                    self.paired = try self.store.clientIds()
                    try self.store.prepareForBackgroundRefresh()
                    self.view.backgroundRefreshError = nil
                    if self.view.selectedId == nil, let target = try self.backgroundTargets.load(), self.paired.contains(target.id) {
                        self.view.selectedId = target.id
                    }
                }
                catch { self.view.backgroundRefreshError = "后台刷新准备失败，请解锁设备后重新打开 App。" }
                self.intent.enterForeground()
                self.startBrowser()
            } else {
                self.clearLiveDisplay()
                self.intent.leaveForeground()
                self.watch?.setParent(active: false, generation: self.generation)
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
            if self.view.selectedId == id { self.cancelSession(); self.view.selectedId = nil }
            do {
                do { try self.backgroundTargets.forget(id) }
                catch { try self.backgroundTargets.reset() }
                guard try self.store.forget(id) else { throw WidgetSnapshotError.unavailable }
                WidgetSnapshotPublisher.shared.forgetSource(id)
                self.paired.remove(id)
                self.view.hosts = self.view.hosts.filter { $0.id != id || $0.available }.map {
                    LanHost(id: $0.id, name: $0.name, paired: self.paired.contains($0.id), available: $0.available)
                }
                self.view.status = "已忘记，可重新配对"; self.view.error = nil
            } catch { self.view.error = "未能删除配对记录，请重试。" }
            self.publish()
        }
    }

    /// 只浏览局域网宿主服务，TXT没有授信作用，也不接受广告携带的URL或固定IP。
    private func startBrowser() {
        guard active, intent.requested, browser == nil else { return }
        let parameters = NWParameters.tcp; parameters.includePeerToPeer = false
        let source = NWBrowser(for: .bonjourWithTXTRecord(type: "_loki-host._tcp", domain: "local."), using: parameters)
        browser = source
        if socket == nil { view.status = "正在发现桌面端…" }
        source.stateUpdateHandler = { [weak self, weak source] state in
            guard let self, let source, self.browser === source else { return }
            if case .ready = state { self.view.error = nil; self.publish() }
            if case .failed = state { self.browser = nil; self.view.error = "发现失败，请检查本地网络权限和 Wi-Fi 后重试。"; self.publish() }
            if case .waiting = state { self.view.error = "本地网络暂不可用，请检查系统权限与 Wi-Fi。"; self.publish() }
        }
        source.browseResultsChangedHandler = { [weak self, weak source] results, changes in
            guard let self, let source, self.browser === source else { return }
            if let selected = self.view.selectedId, self.paired.contains(selected), self.socket == nil,
               changes.contains(where: { change in
                   switch change {
                   case .added(let result), .changed(_, let result, _):
                       if case .bonjour(let record) = result.metadata { return record["id"] == selected }
                       return false
                   default: return false
                   }
               }) { self.intent.renewedEndpoint() }
            self.browsed(results)
        }
        source.start(queue: queue)
        browsed(source.browseResults)
        if timer == nil {
            let clock = DispatchSource.makeTimerSource(queue: queue)
            clock.schedule(deadline: .now() + 1, repeating: 1)
            clock.setEventHandler { [weak self] in self?.tick() }
            timer = clock; clock.resume()
        }
    }

    /// 重复声明同一UUID的广告拒绝自动选取，防止错误广告替换正在认证的对端。
    private func browsed(_ results: Set<NWBrowser.Result>) {
        var found: [String: (String, NWEndpoint)] = [:]; var duplicates: Set<String> = []
        for result in results.prefix(128) {
            guard case .bonjour(let record) = result.metadata, record["v"] == "1", let id = record["id"],
                  UUID(uuidString: id)?.uuidString.lowercased() == id, id != deviceId,
                  id != "00000000-0000-0000-0000-000000000000", let name = record["name"],
                  !name.isEmpty, name.utf8.count <= 160, !name.unicodeScalars.contains(where: { $0.value < 32 || (127...159).contains($0.value) }) else { continue }
            if found[id] != nil { duplicates.insert(id) }
            found[id] = (name, result.endpoint)
        }
        for id in duplicates { found.removeValue(forKey: id) }
        endpoints = found.mapValues { $0.1 }
        view.hosts = found.keys.sorted().prefix(64).map { LanHost(id: $0, name: found[$0]!.0, paired: paired.contains($0)) }
        view.hosts += paired.subtracting(found.keys).sorted().map {
            LanHost(id: $0, name: "已配对桌面 · " + $0.prefix(8), paired: true, available: false)
        }
        if socket == nil, retry == nil, active,
           let id = intent.automaticSelection(selectedId: view.selectedId, paired: paired, available: view.hosts.filter(\.available).map(\.id)) {
            if view.selectedId == id { resumeSelected() } else { selectNow(id) }
        }
        publish()
    }

    /// 新的显式选择关闭旧窗口；相同窗口内的网络重试始终复用同一个bridge与offer。
    private func selectNow(_ id: String) {
        guard active, intent.requested, endpoints[id] != nil else { return }
        do {
            let previous: BackgroundTarget?
            do { previous = try backgroundTargets.load() }
            catch { try backgroundTargets.reset(); previous = nil }
            if let previous, previous.id != id { try backgroundTargets.forget(previous.id) }
        } catch {
            view.error = "未能更新后台刷新目标，请检查存储空间后重试。"; publish(); return
        }
        WidgetSnapshotPublisher.shared.selectSource(id)
        cancelSession(); view.selectedId = id; view.error = nil; intent.connected()
        do {
            bridge = try NativeLinkBridge(deviceId: deviceId, name: name)
            cache = try? IOSAssetCache()
            if try store.load(id) != nil { resumeSelected() }
            else {
                let opened = try bridge!.call(["op": "openPairing", "clientId": id])
                guard let code = opened["code"] as? String, let offer = opened["offer"] as? [String: Any] else { throw WidgetSnapshotError.invalid }
                self.offer = offer; view.pairingCode = code
                pairingDeadline = now + 60_000_000_000
                connect(pairing: true)
            }
        } catch { fail(retry: false, message: "无法开始连接，请检查设备身份或配对存储后重试。") }
        publish()
    }

    /// 保存后另建新socket认证；桌面保存尚在进行时用同一凭据有界退避。
    private func resumeSelected() {
        guard (active && intent.requested) || backgroundRun != nil,
              let id = view.selectedId, endpoints[id] != nil else { return }
        do {
            if bridge == nil { bridge = try NativeLinkBridge(deviceId: deviceId, name: name) }
            guard let material = try store.load(id), let secret = material["secret"] as? String else { throw WidgetSnapshotError.invalid }
            offer = try bridge!.call(["op": "resume", "clientId": id, "secret": secret])["introduction"] as? [String: Any]
            guard offer != nil else { throw WidgetSnapshotError.invalid }
            if active, cache == nil { cache = try? IOSAssetCache() }
            connect(pairing: false)
        } catch { fail(retry: false, message: "无法读取配对凭据，请解锁后重试，或忘记此桌面后重新配对。") }
    }

    /// 一次只拥有一个连接，代次过滤所有旧socket与迟到写入回调。
    private func connect(pairing: Bool) {
        clearLiveDisplay()
        guard let id = view.selectedId, let endpoint = endpoints[id], let offer else { return }
        socket?.close(); socket = nil; generation &+= 1; watchCapability = false; deviceType.reset(); watchNonce = nil; resetWatchProjection()
        failedAssets = []; view.assetWarning = cache == nil ? "图片缓存暂不可用，连接仍可同步文字与用量。" : nil
        let token = generation
        phase = pairing ? .pairHello : .resumeReply; deadline = now + 15_000_000_000
        view.status = pairing ? "等待在桌面输入手机配对码" : "正在认证桌面…"; view.connected = false
        let connection = LanSocket(endpoint: endpoint, queue: queue,
            limit: { [weak self] in (self?.phase == .streaming || self?.phase == .pausing) ? 98304 : 4096 },
            ready: { [weak self] in
                guard let self, self.generation == token else { return }
                do {
                    if pairing { self.deadline = self.pairingDeadline }
                    try self.socket?.send(offer, limit: 4096)
                } catch { self.fail(retry: true, message: "连接中断，正在重新发现桌面…") }
            }, frame: { [weak self] frame in
                guard let self, self.generation == token else { return }
                try self.received(frame)
            }, ended: { [weak self] reason in
                guard let self, self.generation == token else { return }
                if self.backgroundRun != nil, self.phase == .pausing { return }
                if self.phase == .pairClose { self.pairingCompleted(); return }
                self.fail(retry: reason != .invalid, message: reason == .invalid ? "认证或消息校验失败，请重试或重新配对。" : "连接中断，正在等待桌面恢复…")
            })
        socket = connection; connection.start(); publish()
    }

    /// 线帧只发送核心返回的内部对象，元信息没有type包装且不自报IP。
    private func received(_ json: [String: Any]) throws {
        guard let bridge, let socket else { throw WidgetSnapshotError.invalid }
        switch phase {
        case .pairHello:
            let reply = try bridge.call(["op": "pairHello", "hello": json])
            guard let value = reply["reply"] as? [String: Any] else { throw WidgetSnapshotError.invalid }
            phase = .pairConfirmation; deadline = min(pairingDeadline ?? now, now + 15_000_000_000)
            try socket.send(value, limit: 4096)
        case .pairConfirmation:
            let pending = try bridge.call(["op": "pairConfirmation", "confirmation": json])
            guard let material = pending["material"] as? [String: Any], let commit = pending["commitId"] as? String else { throw WidgetSnapshotError.invalid }
            _ = try bridge.call(["op": "checkCommit", "commitId": commit])
            let saved = (try? store.save(material)) == true
            if saved, let id = material["clientId"] as? String {
                paired.insert(id)
                view.hosts = view.hosts.map { LanHost(id: $0.id, name: $0.name, paired: paired.contains($0.id), available: $0.available) }
                publish() // 即使随后过期留下单边记录，用户也能显式忘记后重新配对。
            }
            let result = try bridge.call(["op": "pairingStored", "commitId": commit, "stored": saved])
            guard let ack = result["ack"] as? [String: Any] else { throw WidgetSnapshotError.invalid }
            phase = .pairClose; deadline = now + 3_000_000_000
            try socket.send(ack, limit: 4096)
        case .resumeReply:
            let result = try bridge.call(["op": "resumeReply", "reply": json])
            guard let confirmation = result["confirmation"] as? [String: Any] else { throw WidgetSnapshotError.invalid }
            phase = .metadata
            let token = generation
            try socket.send(confirmation, limit: 4096) { [weak self] in
                guard let self, self.generation == token else { return }
                do {
                    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
                    try self.sendSecure(["deviceId": self.deviceId, "name": self.name, "platform": "ios", "appVersion": version])
                    self.phase = .streaming; self.lastInbound = self.now
                } catch { self.fail(retry: false, message: "无法发送设备信息，请重试。") }
            }
        case .streaming:
            let result = try bridge.call(["op": "open", "packet": json])
            guard let message = result["message"] as? [String: Any], let type = message["type"] as? String else { throw WidgetSnapshotError.invalid }
            lastInbound = now
            switch type {
            case "ping":
                WidgetSnapshotPublisher.shared.renew()
                guard let nonce = message["nonce"] as? NSNumber, CFGetTypeID(nonce) != CFBooleanGetTypeID() else { throw WidgetSnapshotError.invalid }
                try sendSecure(["type": "pong", "nonce": nonce])
                watchNonce = nonce; try reportWatch()
            case "snapshot": try acceptSnapshot(message)
            case "assetChunk":
                guard let chunk = message["chunk"] as? [String: Any] else { throw WidgetSnapshotError.invalid }
                try acceptAsset(chunk)
            case "assetUnavailable":
                guard let hash = message["hash"] as? String, hash == currentAsset?.hash else { throw WidgetSnapshotError.invalid }
                failedAssets.insert(hash); cache?.cancel(); currentAsset = nil; assetDeadline = nil; try nextAsset()
            default: throw WidgetSnapshotError.invalid
            }
        case .pausing: break
        default: throw WidgetSnapshotError.invalid
        }
    }

    /// 首次配对socket收尾后才恢复；手机已保存不等于桌面已保存或当前已经在线。
    private func pairingCompleted() {
        if let id = view.selectedId { paired.insert(id) }
        offer = nil; pairingDeadline = nil; view.pairingCode = nil
        socket?.close(); socket = nil; phase = .idle; deadline = nil
        scheduleRetry()
    }

    /// 同一已认证通道序号仅由共享Rust消费，写失败不能在原socket重发。
    private func sendSecure(_ message: [String: Any], completion: @escaping () -> Void = {}) throws {
        guard let bridge, let socket,
              let packet = try bridge.call(["op": "seal", "message": message])["packet"] as? [String: Any] else { throw WidgetSnapshotError.invalid }
        try socket.send(packet, limit: 98304, completion: completion)
    }

    /// 单调期限覆盖配对、首次快照、心跳和单资源等待，不靠发送成功宣称在线。
    private func tick() {
        if let pairingDeadline, now >= pairingDeadline { fail(retry: false, message: "配对窗口已过期，请重新选择桌面开启新配对。"); return }
        if let deadline, now >= deadline {
            if phase == .pairClose { pairingCompleted() }
            else { fail(retry: true, message: "连接超时，正在等待桌面恢复…") }
            return
        }
        if phase == .streaming, now - lastInbound >= 45_000_000_000 { fail(retry: true, message: "桌面暂不可达，恢复网络后重新连接。"); return }
        if let assetDeadline, now >= assetDeadline, let currentAsset {
            failedAssets.insert(currentAsset.hash); cache?.cancel(); self.currentAsset = nil; self.assetDeadline = nil
            view.assetWarning = "部分图片接收超时，重新连接后可补取。"; publish()
            // 旧响应仍可能在途，关闭并重新认证，避免它与下一资源接收器混合。
            fail(retry: true, message: "图片响应超时，正在恢复连接…")
        }
    }

    /// 网络重试有限且不重开密码窗口，mDNS更新与前台恢复会重新获取最新地址。
    private func scheduleRetry() {
        guard active, let delay = intent.nextDelay() else { view.status = "暂未连接，请重新选择桌面重试"; publish(); return }
        retry?.cancel()
        let task = DispatchWorkItem { [weak self] in
            guard let self else { return }; self.retry = nil
            guard self.active, self.intent.requested else { return }
            if self.pairingDeadline != nil { self.connect(pairing: true) }
            else { self.resumeSelected() }
        }
        retry = task; queue.asyncAfter(deadline: .now() + delay, execute: task)
    }

    /// 协议/认证失败保留信任供用户显式处理，传输失败才在新socket进行恢复。
    private func fail(retry shouldRetry: Bool, message: String) {
        if backgroundRun != nil { finishBackgroundRefresh(success: false); return }
        clearLiveDisplay()
        retry?.cancel(); retry = nil
        watchCapability = false; deviceType.reset(); watchNonce = nil; resetWatchProjection()
        generation &+= 1; socket?.close(); socket = nil; cache?.cancel(); currentAsset = nil; assetDeadline = nil
        _ = try? bridge?.call(["op": "disconnect"])
        phase = .idle; deadline = nil; view.connected = false; view.error = message; view.status = "暂未连接"
        watch?.setParent(active: false, generation: generation)
        if shouldRetry { scheduleRetry() }
        else { _ = try? bridge?.call(["op": "cancelPairing"]); pairingDeadline = nil; view.pairingCode = nil; offer = nil }
        publish()
    }

    /// 后台或切换桌面关闭整个密码窗口，清空实时投影；图片缓存与配对关系继续保留。
    private func cancelSession() {
        clearLiveDisplay()
        watchCapability = false; deviceType.reset(); watchNonce = nil; resetWatchProjection()
        generation &+= 1; retry?.cancel(); retry = nil
        socket?.close(); socket = nil; _ = try? bridge?.call(["op": "cancelPairing"]); bridge?.close(); bridge = nil
        cache?.cancel(); currentAsset = nil; assetDeadline = nil; pairingDeadline = nil; deadline = nil; offer = nil
        failedAssets = []; phase = .idle; view.pairingCode = nil; view.connected = false
        watch?.setParent(active: false, generation: generation)
    }

    /// 只有App投影进入主线程，完整材料和FFI结果不记录到日志。
    private func publish() { view.requested = intent.requested; changed(view) }
    /// 所有超时使用本机单调时间，墙钟变化不返还配对期限。
    private var now: UInt64 { DispatchTime.now().uptimeNanoseconds }

    deinit {
        retry?.cancel(); timer?.cancel()
        let browser = browser, socket = socket, bridge = bridge, cache = cache
        queue.async { browser?.cancel(); socket?.close(); bridge?.close(); cache?.cancel() }
    }

    /// 接收完整快照后才报告在线，并只调度当前实际展示引用的缺失图片。
    private func acceptSnapshot(_ message: [String: Any]) throws {
        let snapshot = try LanDisplaySnapshot.decode(message)
        let refreshTarget = widgetRefreshTarget(message)
        if let run = backgroundRun, let source = view.selectedId {
            // 后台不投影在线状态、不取图片或同步Watch；完成必须等待共享文件真正提交。
            phase = .pausing
            deadline = nil
            try? sendSecure(["type": "pause"])
            WidgetSnapshotPublisher.shared.publishInBackground(message, sourceId: source, refreshTarget: refreshTarget) { [weak self] saved in
                self?.queue.async { [weak self] in
                    guard let self, self.backgroundRun?.id == run.id else { return }
                    self.finishBackgroundRefresh(success: saved)
                }
            }
            return
        }
        let supportsWatch = try WatchCompanionFacts.hostSupports(message)
        if let report = try deviceType.afterAuthenticatedSnapshot(message) { try sendSecure(report) }
        watchCapability = supportsWatch
        if let id = view.selectedId { WidgetSnapshotPublisher.shared.enqueue(message, sourceId: id, refreshTarget: refreshTarget) }
        view.snapshot = snapshot; view.receivedDate = Date(); view.connected = true; view.status = "已连接，正在同步"; view.error = nil
        if let id = view.selectedId, let endpoint = endpoints[id], case let .service(service, type, domain, _) = endpoint {
            do { try backgroundTargets.save(BackgroundTarget(id: id, name: service, type: type, domain: domain)) }
            catch { view.backgroundRefreshError = "后台刷新目标未能保存，打开 App 后仍可正常同步。" }
        }
        deadline = nil; intent.connected()
        let hashes = Set(snapshot.hooks.compactMap(\.image))
        view.images = view.images.filter { hashes.contains($0.key) }
        assetPaths = assetPaths.filter { hashes.contains($0.key) }
        cache?.prune(keeping: hashes)
        syncWatch(); try nextAsset(); publish()
    }

    /// 只有成功解密快照的能力字段与系统实际对端组合成读取地址；每次认证同步均更新。
    private func widgetRefreshTarget(_ message: [String: Any]) -> WidgetRefreshTarget? {
        guard let source = view.selectedId, let host = socket?.connectedHost,
              (message["capabilities"] as? [String])?.contains("widgetHttpV1") == true,
              let endpoint = message["widgetEndpoint"] as? [String: Any],
              let version = endpoint["version"] as? NSNumber, CFGetTypeID(version) != CFBooleanGetTypeID(), version.doubleValue == 1,
              let port = endpoint["port"] as? NSNumber, CFGetTypeID(port) != CFBooleanGetTypeID(),
              port.doubleValue == Double(port.intValue),
              let key = endpoint["key"] as? String else { return nil }
        return try? WidgetRefreshTarget(sourceId: source, deviceId: deviceId, host: host, port: port.intValue, key: key)
    }

    /// 一次只请求一个16KiB块，文件失败允许降级；所有消耗nonce后的发送失败必须向连接owner传播。
    private func nextAsset() throws {
        guard phase == .streaming, currentAsset == nil, let snapshot = view.snapshot, let bridge, let cache else { return }
        let hashes = Set(snapshot.hooks.compactMap(\.image))
        for asset in snapshot.assets where hashes.contains(asset.hash) && view.images[asset.hash] == nil && !failedAssets.contains(asset.hash) {
            do {
                if let path = try cache.cached(asset, bridge: bridge) {
                    assetPaths[asset.hash] = path
                    decodeImage(path, asset: asset, cache: cache)
                    continue
                }
                try cache.begin(asset, bridge: bridge)
            } catch {
                if error is NativeLinkBridge.Failure { throw error }
                failedAssets.insert(asset.hash); cache.cancel(); view.assetWarning = "部分图片缓存暂不可用，重新连接后可补取。"
                continue
            }
            currentAsset = asset
            syncWatch()
            try requestAsset(asset.hash, offset: 0)
            return
        }
        syncWatch()
    }

    /// 对已失效清单的在途块只排空一次，之后再创建新接收器，避免旧块混入新图片。
    private func acceptAsset(_ chunk: [String: Any]) throws {
        guard let asset = currentAsset, let bridge, let cache, chunk["hash"] as? String == asset.hash else { throw WidgetSnapshotError.invalid }
        let active = view.snapshot?.hooks.contains(where: { $0.image == asset.hash }) == true && view.snapshot?.assets.contains(asset) == true
        if !active { cache.cancel(); currentAsset = nil; assetDeadline = nil; try nextAsset(); publish(); return }
        let result: (UInt64, URL?)
        do { result = try cache.accept(chunk, bridge: bridge) }
        catch {
            if error is NativeLinkBridge.Failure { throw error }
            failedAssets.insert(asset.hash); cache.cancel(); currentAsset = nil; assetDeadline = nil
            view.assetWarning = "部分图片未能保存，重新连接后可补取。"; try nextAsset(); publish()
            return
        }
        let (offset, path) = result
        if let path {
            assetPaths[asset.hash] = path
            decodeImage(path, asset: asset, cache: cache)
            cache.prune(keeping: Set(view.snapshot?.hooks.compactMap(\.image) ?? []))
            currentAsset = nil; assetDeadline = nil; syncWatch(); try nextAsset(); publish()
        } else {
            // 发送位于磁盘catch之外，已消费的密码序号绝不能在同一socket跳过或补发。
            try requestAsset(asset.hash, offset: offset)
        }
    }

    /// 同一解码策略覆盖网络接收和冷启动缓存，失败明确披露而不静默显示首帧。
    private func decodeImage(_ path: URL, asset: LanDisplaySnapshot.Asset, cache: IOSAssetCache) {
        do { view.images[asset.hash] = try cache.image(path, mime: asset.mime) }
        catch {
            failedAssets.insert(asset.hash)
            view.assetWarning = (error as? LocalizedError)?.errorDescription ?? "图片无法解码。"
        }
    }

    /// 请求只包含当前内容摘要与核心给出的严格偏移，不发送远端文件路径。
    private func requestAsset(_ hash: String, offset: UInt64) throws {
        do {
            try sendSecure(["type": "assetRequest", "hash": hash, "offset": offset])
            assetDeadline = now + 10_000_000_000
        } catch {
            cache?.cancel(); currentAsset = nil; assetDeadline = nil
            throw error
        }
    }

    /// LAN切代同步撤销页面和上行证明，不能等待另一队列的Phone owner异步清理。
    private func resetWatchProjection() {
        watchProjectionGeneration = nil; view.watch.reachable = false; view.watch.facts.clear()
    }

    /// 已认证快照能力和本次ping共同允许上行；事实年龄在实际发送前重新计算。
    private func reportWatch() throws {
        guard active, phase == .streaming, view.connected, watchCapability, watchProjectionGeneration == generation, let nonce = watchNonce,
              let info = view.watch.info else { return }
        let report = try view.watch.facts.report(info: info, reachable: view.watch.reachable, now: now)
        try sendSecure(["type": "companionStatus", "nonce": nonce, "report": report])
    }

    /// 只把本代真实认证快照和已校验路径交配套owner，绝不传递配对凭据。
    private func syncWatch() {
        guard phase == .streaming, view.connected, let snapshot = view.snapshot,
              let source = view.selectedId, let date = view.receivedDate else { return }
        watch?.update(snapshot, sourceId: source, receivedAtMs: Int64(date.timeIntervalSince1970 * 1000), generation: generation, paths: assetPaths)
    }

    /// 失效立即丢弃Token、Hooks及解码图片；磁盘图片只由新快照重新引用后复用。
    private func clearLiveDisplay() {
        view.snapshot = nil; view.receivedDate = nil; view.images = [:]; view.assetWarning = nil
        assetPaths = [:]
        WidgetSnapshotPublisher.shared.invalidate()
    }
}
