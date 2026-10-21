import Foundation
import WatchConnectivity
import Security

/// 仅表示配套应用实际通信，手机TCP/IP与系统isReachable都不能单独产生此投影。
struct PhoneWatchView {
    var info: WatchDeviceInfo?
    var reachable = false
    var lastContact: Date?
    var lastSync: Date?
    var error: String?
    var facts = WatchCompanionFacts()
}

/// 单个应用级WCSession owner；即时RPC逐块ACK，不排系统后台文件或context传输。
final class PhoneWatchBridge: NSObject, WCSessionDelegate {
    private let queue = DispatchQueue(label: "LokiMetris.phone-watch")
    private let phoneId: String
    private let changed: (PhoneWatchView, UInt64) -> Void
    private var session: WCSession?
    private var timer: DispatchSourceTimer?
    private var parentActive = false
    private var retiredForRecovery = false
    private var parentGeneration: UInt64 = 0
    private var httpConfiguration: WatchHTTPConfiguration?
    private var httpRevisionFloor: UInt64 = 0
    private var epoch = UUID()
    private var view = PhoneWatchView()
    private var watchLease = WatchForegroundLease()
    private var facts = WatchCompanionFacts()
    private var watchSession: String? { watchLease.session }
    private var latestData: Data?
    private var latestHash: String?
    private var latestSnapshot: LanDisplaySnapshot?
    private var paths: [String: URL] = [:]
    private var acknowledgedSnapshot: String?
    private var acknowledgedManifest: LanDisplaySnapshot?
    private var acknowledgedAssets: Set<String> = []
    private var failedAssets: Set<String> = []
    /// 父LAN失效时只保留一个待通知的旧Watch会话，仍遵守物理RPC单槽。
    private var pendingPause: String?
    private var physicalRPC: UUID?
    private var expiredRPC = false
    private var timeout: DispatchWorkItem?
    private var job: UUID?
    private var jobData: Data?
    private var jobSnapshot: LanDisplaySnapshot?
    private var jobFile: FileHandle?
    private var jobAsset: LanDisplaySnapshot.Asset?
    private var jobLength: UInt64 = 0
    private var jobOffset: UInt64 = 0

    /// 系统配套身份由OS保证，构造不访问局域网或桌面配对秘密。
    init(phoneId: String, changed: @escaping (PhoneWatchView, UInt64) -> Void) {
        self.phoneId = phoneId; self.changed = changed
        super.init()
        queue.async {
            guard WCSession.isSupported() else { self.view.error = "当前设备不支持Watch配套通信。"; self.publish(); return }
            let session = WCSession.default; self.session = session; session.delegate = self; session.activate()
            // 冷启动仍能向手表返回上次认证授予的只读配置，无需重开手机前台 LAN。
            do {
                let target = try WidgetContainer.store().loadRefreshTarget()
                let trusted: WidgetRefreshTarget? = try target.flatMap { value -> WidgetRefreshTarget? in
                    guard value.deviceId == phoneId else { return nil }
                    return try PairingStore(deviceId: phoneId).load(value.sourceId) == nil ? nil : value
                }
                self.configureHTTPNow(trusted)
            } catch { self.view.error = "手表连接配置暂不可读取，请解锁 iPhone 后重试。"; self.publish() }
            self.timer = WatchProtocol.heartbeat(on: self.queue) { [weak owner = self] in owner?.tick() }
        }
    }
    /// 排空旧 owner 的队列后永久退役；不撤销已授权配置，恢复被拒绝时仍可沿用。
    /// 旧系统终态回调不得在新 owner 建立后再次发布配置或重启传输。
    func retireForRecovery(completion: @escaping () -> Void) { queue.async {
        self.retiredForRecovery = true; self.parentActive = false; self.epoch = UUID()
        self.cancelJob(); self.pendingPause = nil; self.watchLease.deactivate()
        self.latestData = nil; self.latestHash = nil; self.latestSnapshot = nil; self.paths = [:]
        self.timer?.cancel(); self.timer = nil; self.timeout?.cancel(); self.timeout = nil
        if let session = self.session, session.delegate === self { session.delegate = nil }
        self.session = nil
        completion()
    } }
    /// 连接中断保留配置；换桌面、忘记配对或失去 HTTP 能力时显式传 nil 撤销。
    func configureHTTP(_ target: WidgetRefreshTarget?) { queue.async { self.configureHTTPNow(target) } }
    private func configureHTTPNow(_ target: WidgetRefreshTarget?, forceRevision: Bool = false) {
        guard !retiredForRecovery else { return }
        do {
            let stable: WidgetRefreshTarget?
            if let target, let previous = httpConfiguration?.target, previous.sameConnection(as: target) { stable = previous }
            else { stable = target }
            if !forceRevision, let current = httpConfiguration, current.target == stable { return }
            let revision = try PhoneWatchConfigurationRevisionStore.next(phoneId: phoneId, after: httpRevisionFloor)
            httpConfiguration = try WatchHTTPConfiguration(phoneId: phoneId, target: stable, revision: revision)
            httpRevisionFloor = revision
            publishHTTPConfiguration()
        } catch {
            // 存储失败不能继续向手表发送旧授权；本进程发布更高修订的撤销，后续持久修订从它之后继续。
            if httpRevisionFloor < UInt64.max {
                httpRevisionFloor += 1
                httpConfiguration = try? WatchHTTPConfiguration(phoneId: phoneId, target: nil, revision: httpRevisionFloor)
            } else { httpConfiguration = nil }
            publishHTTPConfiguration()
            view.error = "手表 HTTP 配置暂不可用，请解锁 iPhone 后重试。"; publish()
        }
    }
    func forgetHTTPSource(_ sourceId: String) { queue.async {
        if self.httpConfiguration?.target?.sourceId == sourceId { self.configureHTTPNow(nil) }
    } }
    private func publishHTTPConfiguration() {
        guard !retiredForRecovery, let session, session.activationState == .activated, session.isPaired,
              session.isWatchAppInstalled, let httpConfiguration else { return }
        do { try session.updateApplicationContext(["watchHTTPConfiguration": try httpConfiguration.encoded()]) }
        catch { view.error = "手表连接配置尚未送达，将在下次通信时重试。"; publish() }
    }
    /// 只有当前iPhone认证连接可供同步，后台或断线撤销所有前台证明。
    func setParent(active: Bool, generation: UInt64) { queue.async { guard !self.retiredForRecovery else { return }; self.setParentNow(active: active, generation: generation); self.publish() } }
    /// 引擎只在完整验证snapshot后调用，图片URL也仅来自已验证私有缓存。
    func update(_ snapshot: LanDisplaySnapshot, sourceId: String, receivedAtMs: Int64, generation: UInt64, paths: [String: URL]) {
        queue.async {
            guard !self.retiredForRecovery else { return }
            do {
                self.setParentNow(active: true, generation: generation)
                let value = WatchSnapshotEnvelope(version: 1, phoneId: self.phoneId, sourceId: sourceId, phoneReceivedAtMs: receivedAtMs, snapshot: snapshot)
                try value.validate()
                let data = try SharedJSON.sortedEncoder.encode(value)
                guard data.count <= WatchProtocol.maxSnapshotBytes else { throw WidgetSnapshotError.tooLarge }
                let hash = WatchProtocol.hash(data)
                if hash != self.latestHash {
                    // 新用量只合并待发快照；仍有效的有界作业必须完成，避免大图被频繁更新饿死。
                    if !WatchTransferPolicy.keepInFlight(asset: self.jobAsset, latest: snapshot) { self.cancelJob() }
                    self.latestData = data; self.latestHash = hash; self.failedAssets = []
                }
                self.latestSnapshot = snapshot
                let referenced = Set(snapshot.hooks.compactMap(\.image))
                // 离开引用集的旧ACK不能长期代表Watch仍有文件；以后重新引用必须再核验缓存。
                self.acknowledgedAssets.formIntersection(referenced)
                self.paths = paths.filter { referenced.contains($0.key) }
                self.startSync()
            } catch { self.view.error = "手表展示数据暂不可用。"; self.publish() }
        }
    }
    /// 用户显式重试可以重试失败资源，不改变桌面密码窗口或信任。
    func retry() { queue.async { guard !self.retiredForRecovery else { return }; self.failedAssets = []; self.startSync() } }
    /// 切代撤销逻辑请求，物理RPC仍等其终态，不能因超时另排无限系统请求。
    private func setParentNow(active: Bool, generation: UInt64) {
        if parentGeneration != generation || parentActive != active {
            if let watchSession { pendingPause = watchSession }
            latestData = nil; latestHash = nil; latestSnapshot = nil; paths = [:]
            parentGeneration = generation; parentActive = active; epoch = UUID(); cancelJob()
            view.reachable = false; watchLease.deactivate(); facts.clear()
            acknowledgedSnapshot = nil; acknowledgedManifest = nil; acknowledgedAssets = []
            _ = flushPendingPause()
        }
    }
    /// 真实Watch前台回复才续租，未响应或本地时钟倒退视作不可同步。
    private func tick() {
        guard !retiredForRecovery else { return }
        if watchSession != nil && !watchLease.reachable(now: now) { view.reachable = false; publish() }
        if parentActive && view.info != nil { publish() }
        startSync()
    }
    /// WC可达只是发送前提，probe还必须取到Watch当前前台代次和身份。
    private func startSync() {
        if flushPendingPause() { return }
        guard !retiredForRecovery, parentActive, job == nil, physicalRPC == nil, let session,
              session.activationState == .activated, session.isPaired, session.isWatchAppInstalled, session.isReachable else { return }
        var request = WatchRPC("probe"); let challenge = UUID().uuidString.lowercased(); request.id = challenge
        rpc(request) { [weak self] reply in
            guard let self else { return }
            guard reply.status == "ready", reply.id == challenge, let watchSession = reply.session,
                  SharedValidation.validId(watchSession), let info = reply.info, (try? info.validate()) != nil else {
                self.view.reachable = false; self.publish(); return
            }
            if self.watchSession != watchSession || self.view.info?.deviceId != info.deviceId {
                self.cancelJob(); self.acknowledgedSnapshot = nil; self.acknowledgedManifest = nil; self.acknowledgedAssets = []
                if self.view.info?.deviceId != info.deviceId { self.view.lastSync = nil; self.facts.clear() }
            }
            // Watch 可能已切到 HTTP 摘要；其内存不再有之前的完整图文，需要重新发送。
            if reply.snapshotHash != self.acknowledgedSnapshot {
                self.acknowledgedSnapshot = nil; self.acknowledgedManifest = nil; self.acknowledgedAssets = []
            }
            if self.watchSession != watchSession { try? self.watchLease.activate(session: watchSession) }
            self.view.info = info; self.view.error = nil; self.contacted(); self.publish()
            self.startPayload()
        }
    }
    /// 完成当前已提交清单的有效图片，再取最新快照；持续用量更新不能饿死大图。
    private func startPayload() {
        guard parentActive, physicalRPC == nil, job == nil, let watchSession,
              let data = latestData, let hash = latestHash, let snapshot = latestSnapshot else { return }
        let choice = WatchTransferPolicy.nextPayload(committed: acknowledgedManifest, latest: snapshot,
            snapshotPending: acknowledgedSnapshot != hash, available: Set(paths.keys),
            acknowledged: acknowledgedAssets, failed: failedAssets)
        switch choice {
        case .snapshot:
            let id = UUID(); job = id; jobData = data; jobSnapshot = snapshot; jobLength = UInt64(data.count); jobOffset = 0
            var request = WatchRPC("snapshotBegin"); request.id = id.uuidString.lowercased(); request.session = watchSession; request.hash = hash; request.length = jobLength
            rpc(request) { [weak self] reply in self?.began(reply, id: id, snapshotHash: hash) }
            return
        case .asset(let asset):
            guard let path = paths[asset.hash] else { return }
            do {
                let value = try path.resourceValues(forKeys: [.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey])
                guard value.isRegularFile == true, value.isSymbolicLink != true, value.fileSize == Int(asset.length) else { throw WidgetSnapshotError.invalid }
                jobFile = try FileHandle(forReadingFrom: path)
                let id = UUID(); job = id; jobAsset = asset; jobLength = asset.length; jobOffset = 0
                var request = WatchRPC("assetBegin"); request.id = id.uuidString.lowercased(); request.session = watchSession; request.asset = asset
                rpc(request) { [weak self] reply in self?.began(reply, id: id, snapshotHash: nil) }; return
            } catch { failedAssets.insert(asset.hash); view.error = "部分手表图片暂不可用，重新同步后可补取。"; startPayload() }
        case .idle: break
        }
        publish()
    }
    /// Begin命中只证明缓存通过核验，不把旧缓存命中当作新同步时刻。
    private func began(_ reply: WatchRPCReply, id: UUID, snapshotHash: String?) {
        guard job == id else { startSync(); return }
        guard reply.id == id.uuidString.lowercased(), reply.session == watchSession else { failedJob(); return }
        if reply.status == "cached" {
            if let snapshotHash { guard reply.snapshotHash == snapshotHash else { failedJob(); return }; acknowledgedSnapshot = snapshotHash; acknowledgedManifest = jobSnapshot }
            else if let asset = jobAsset { acknowledgedAssets.insert(asset.hash) }
            contacted(); cancelJob(); startPayload(); return
        }
        guard reply.status == "accepted", reply.offset == 0 else { failedJob(); return }
        contacted()
        sendChunk(id: id, snapshotHash: snapshotHash)
    }
    /// 单块发送后等待确切偏移ACK，不同时排队一整张32MiB图片。
    private func sendChunk(id: UUID, snapshotHash: String?) {
        guard job == id, let watchSession else { return }
        do {
            let count = min(WatchProtocol.chunkSize, Int(jobLength - jobOffset))
            let bytes: Data
            if let jobData { bytes = jobData.subdata(in: Int(jobOffset)..<Int(jobOffset) + count) }
            else { bytes = try jobFile?.read(upToCount: count) ?? Data() }
            guard bytes.count == count, count > 0 else { throw WidgetSnapshotError.invalid }
            var request = WatchRPC(snapshotHash == nil ? "assetChunk" : "snapshotChunk")
            request.id = id.uuidString.lowercased(); request.session = watchSession; request.offset = jobOffset; request.data = bytes
            let expected = jobOffset + UInt64(count)
            rpc(request) { [weak self] reply in
                guard let self else { return }
                guard self.job == id else { self.startSync(); return }
                guard reply.id == id.uuidString.lowercased(), reply.session == self.watchSession, reply.offset == expected else { self.failedJob(); return }
                self.jobOffset = expected
                if expected == self.jobLength {
                    guard reply.status == "complete" else { self.failedJob(); return }
                    if let snapshotHash {
                        guard reply.snapshotHash == snapshotHash else { self.failedJob(); return }
                        self.acknowledgedSnapshot = snapshotHash
                        self.acknowledgedManifest = self.jobSnapshot
                    } else if let asset = self.jobAsset { self.acknowledgedAssets.insert(asset.hash) }
                    self.contacted(synchronized: snapshotHash != nil)
                    self.cancelJob(); self.publish(); self.startPayload()
                } else if reply.status == "continue" { self.contacted(); self.sendChunk(id: id, snapshotHash: snapshotHash) }
                else { self.failedJob() }
            }
        } catch { failedJob() }
    }
    /// 每个有效前台回执续通信租约，大图长传输不能因尚未整体完成而被误报离线。
    private func contacted(synchronized: Bool = false) {
        let previouslyReachable = view.reachable
        guard let watchSession else { return }
        do {
            let time = now; try watchLease.received(session: watchSession, now: time)
            try facts.received(now: time, synchronized: synchronized)
        } catch { view.reachable = false; publish(); return }
        view.reachable = true; view.lastContact = Date()
        if synchronized { view.lastSync = Date() }
        if !previouslyReachable { publish() }
    }
    /// 失败资源只标记本轮失败，不无限重传；快照失败等待下一次明确探测。
    private func failedJob() {
        let assetFailed = jobAsset != nil
        if let asset = jobAsset { failedAssets.insert(asset.hash) }
        cancelJob(); view.error = "手表同步中断，可在手表请求刷新。"; publish()
        // 当前失败图让位于待发快照，不能等下次更新清空失败标记后又永远优先重试同图。
        if assetFailed { startPayload() }
    }
    /// 释放精确传输读句柄，已发送的一块仍由系统终态回调收尾。
    private func cancelJob() { job = nil; jobData = nil; jobSnapshot = nil; try? jobFile?.close(); jobFile = nil; jobAsset = nil; jobLength = 0; jobOffset = 0 }
    /// 旧传输终态后优先通知 Watch 手机通道已失效，再允许新代次同步。
    @discardableResult
    private func flushPendingPause() -> Bool {
        guard let stopped = pendingPause else { return false }
        guard physicalRPC == nil, let session, session.activationState == .activated, session.isReachable else { return true }
        pendingPause = nil
        var request = WatchRPC("pause"); request.id = UUID().uuidString.lowercased(); request.session = stopped
        rpc(request, allowInactive: true) { [weak self] _ in self?.startSync() }
        return true
    }
    /// 一个物理RPC槽位；超时只撤销逻辑资格，系统回调终态前不能创建第二个请求。
    private func rpc(_ request: WatchRPC, allowInactive: Bool = false, completed: @escaping (WatchRPCReply) -> Void) {
        guard physicalRPC == nil, let session, parentActive || allowInactive else { failedJob(); return }
        let bytes: Data
        do { bytes = try WatchProtocol.encode(request) } catch { failedJob(); return }
        let id = UUID(), token = epoch
        physicalRPC = id; expiredRPC = false
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, !self.retiredForRecovery, self.physicalRPC == id else { return }
            self.expiredRPC = true; self.cancelJob(); self.view.reachable = false
            self.view.error = "手表响应超时，等待系统结束上次请求后重试。"; self.publish()
        }
        self.timeout = timeout; queue.asyncAfter(deadline: .now() + WatchProtocol.rpcTimeout, execute: timeout)
        session.sendMessageData(bytes, replyHandler: { [weak self] data in
            self?.queue.async { [weak self] in self?.finished(id: id, epoch: token, data: data, allowInactive: allowInactive, completed: completed) }
        }, errorHandler: { [weak self] _ in
            self?.queue.async { [weak self] in self?.finished(id: id, epoch: token, data: nil, allowInactive: allowInactive, completed: completed) }
        })
    }
    /// 旧RPC先释放自己的物理槽，再按代次判断是否允许提交结果。
    private func finished(id: UUID, epoch: UUID, data: Data?, allowInactive: Bool, completed: (WatchRPCReply) -> Void) {
        guard physicalRPC == id else { return }
        physicalRPC = nil; timeout?.cancel(); timeout = nil
        guard !retiredForRecovery else { return }
        let valid = !expiredRPC && self.epoch == epoch && (parentActive || allowInactive); expiredRPC = false
        if flushPendingPause() { return }
        guard valid else { if parentActive { startSync() }; return }
        guard let data, let reply = try? WatchProtocol.reply(data) else { failedJob(); view.reachable = false; publish(); return }
        completed(reply)
    }
    /// 激活成功只允许尝试probe，不能直接产生Watch在线状态。
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) { queue.async { guard !self.retiredForRecovery else { return }; if error != nil { self.view.error = "Watch配套会话暂不可用。"; self.publish() }; self.publishHTTPConfiguration(); self.startSync() } }
    /// 可达变化只作为通信触发或撤销提示，不能代替Watch前台回复。
    func sessionReachabilityDidChange(_ session: WCSession) { queue.async { guard !self.retiredForRecovery else { return }; if !session.isReachable { self.view.reachable = false; self.publish() }; self.startSync() } }
    /// 系统安装清单或配套状态变化后重新探测；安装成功本身不能产生在线证明。
    func sessionWatchStateDidChange(_ session: WCSession) { queue.async { guard !self.retiredForRecovery else { return }; self.publishHTTPConfiguration(); self.startSync() } }
    /// 换表中间态立即撤销旧表证明，不对新表复用任何缓存ACK。
    func sessionDidBecomeInactive(_ session: WCSession) { queue.async { guard !self.retiredForRecovery else { return }; self.epoch = UUID(); self.cancelJob(); self.watchLease.deactivate(); self.view.reachable = false; self.publish() } }
    /// 系统切换到新配对Watch后重新激活，旧请求结果仍受epoch守卫。
    func sessionDidDeactivate(_ session: WCSession) { queue.async { guard !self.retiredForRecovery else { return }; self.epoch = UUID(); self.cancelJob(); self.watchLease.deactivate(); self.acknowledgedSnapshot = nil; self.acknowledgedManifest = nil; self.acknowledgedAssets = []; self.view = PhoneWatchView(); self.facts.clear(); self.publish(); session.activate() } }
    /// 手机有完整实时快照时优先同步；后台只返回只读配置，由 Watch 自行 HTTP 取数。
    func session(_ session: WCSession, didReceiveMessageData data: Data, replyHandler: @escaping (Data) -> Void) {
        queue.async {
            guard !self.retiredForRecovery else { replyHandler((try? WatchProtocol.encode(WatchRPCReply("paused"))) ?? Data()); return }
            guard let request = try? WatchProtocol.request(data) else { replyHandler((try? WatchProtocol.encode(WatchRPCReply("invalid"))) ?? Data()); return }
            guard ["requestSync", "pause"].contains(request.op) else {
                replyHandler((try? WatchProtocol.encode(WatchRPCReply("invalid"))) ?? Data()); return
            }
            if request.op == "pause", let stopped = request.session, SharedValidation.validId(stopped),
               self.watchSession == nil || self.watchSession == stopped {
                self.epoch = UUID(); self.watchLease.deactivate(); self.cancelJob(); self.view.reachable = false;  self.publish()
            }
            if request.op == "requestSync" {
                guard let requestedSession = request.session, SharedValidation.validId(requestedSession) else {
                    replyHandler((try? WatchProtocol.encode(WatchRPCReply("invalid"))) ?? Data()); return
                }
                if let revision = request.configurationRevision, let hash = request.configurationHash,
                   SharedValidation.validHash(hash) {
                    self.httpRevisionFloor = max(self.httpRevisionFloor, revision)
                    if let configuration = self.httpConfiguration, revision >= configuration.revision,
                       let encoded = try? configuration.encoded(), WatchProtocol.hash(encoded) != hash {
                        self.configureHTTPNow(configuration.target, forceRevision: true)
                    }
                }
            }
            let available = self.parentActive && self.latestData != nil
            var reply = WatchRPCReply(available ? "accepted" : "http")
            reply.configuration = self.httpConfiguration
            replyHandler((try? WatchProtocol.encode(reply)) ?? Data())
            if request.op == "requestSync", available { self.failedAssets = []; self.startSync() }
        }
    }
    /// 只有有界元信息进入页面，不发布传输正文、文件URL或秘密。
    private func publish() { guard !retiredForRecovery else { return }; view.facts = facts; changed(view, parentGeneration) }
    /// 所有前台通信租约使用本机单调时间。
    private var now: UInt64 { DispatchTime.now().uptimeNanoseconds }
    deinit { timer?.cancel(); timeout?.cancel(); try? jobFile?.close() }
}

/// 修订号独立于墙钟，并在发布前持久提交；重启后不能复活旧应用上下文的授权。
private enum PhoneWatchConfigurationRevisionStore {
    static func next(phoneId: String, after floor: UInt64) throws -> UInt64 {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "LokiMetris.watch-http-revision.v1", kSecAttrAccount as String: phoneId]
        var request = query; request[kSecReturnData as String] = true; request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        let previous: UInt64
        if status == errSecItemNotFound { previous = 0 }
        else {
            guard status == errSecSuccess, let data = result as? Data, data.count <= 20,
                  let text = String(data: data, encoding: .utf8), let value = UInt64(text) else { throw WidgetSnapshotError.unavailable }
            previous = value
        }
        let baseline = max(previous, floor)
        guard baseline < UInt64.max else { throw WidgetSnapshotError.unavailable }
        let next = baseline + 1
        let attributes: [String: Any] = [kSecValueData as String: Data(String(next).utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let updated = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updated == errSecItemNotFound {
            guard SecItemAdd(query.merging(attributes) { _, next in next } as CFDictionary, nil) == errSecSuccess else {
                throw WidgetSnapshotError.unavailable
            }
        } else if updated != errSecSuccess { throw WidgetSnapshotError.unavailable }
        return next
    }
}
