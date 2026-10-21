import Foundation
import WatchConnectivity

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
    private var parentGeneration: UInt64 = 0
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
            self.timer = WatchProtocol.heartbeat(on: self.queue) { [weak owner = self] in owner?.tick() }
        }
    }
    /// 只有当前iPhone认证连接可供同步，后台或断线撤销所有前台证明。
    func setParent(active: Bool, generation: UInt64) { queue.async { self.setParentNow(active: active, generation: generation); self.publish() } }
    /// 引擎只在完整验证snapshot后调用，图片URL也仅来自已验证私有缓存。
    func update(_ snapshot: LanDisplaySnapshot, sourceId: String, receivedAtMs: Int64, generation: UInt64, paths: [String: URL]) {
        queue.async {
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
    func retry() { queue.async { self.failedAssets = []; self.startSync() } }
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
        if watchSession != nil && !watchLease.reachable(now: now) { view.reachable = false; publish() }
        if parentActive && view.info != nil { publish() }
        startSync()
    }
    /// WC可达只是发送前提，probe还必须取到Watch当前前台代次和身份。
    private func startSync() {
        if flushPendingPause() { return }
        guard parentActive, job == nil, physicalRPC == nil, let session,
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
        cancelJob(); view.error = "手表同步中断，请保持两端应用在前台后重试。"; publish()
        // 当前失败图让位于待发快照，不能等下次更新清空失败标记后又永远优先重试同图。
        if assetFailed { startPayload() }
    }
    /// 释放精确传输读句柄，已发送的一块仍由系统终态回调收尾。
    private func cancelJob() { job = nil; jobData = nil; jobSnapshot = nil; try? jobFile?.close(); jobFile = nil; jobAsset = nil; jobLength = 0; jobOffset = 0 }
    /// 旧传输终态后优先通知Watch清空展示，新数据不能越过该失效通知。
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
            guard let self, self.physicalRPC == id else { return }
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
        let valid = !expiredRPC && self.epoch == epoch && (parentActive || allowInactive); expiredRPC = false
        if flushPendingPause() { return }
        guard valid else { if parentActive { startSync() }; return }
        guard let data, let reply = try? WatchProtocol.reply(data) else { failedJob(); view.reachable = false; publish(); return }
        completed(reply)
    }
    /// 激活成功只允许尝试probe，不能直接产生Watch在线状态。
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) { queue.async { if error != nil { self.view.error = "Watch配套会话暂不可用。"; self.publish() }; self.startSync() } }
    /// 可达变化只作为通信触发或撤销提示，不能代替Watch前台回复。
    func sessionReachabilityDidChange(_ session: WCSession) { queue.async { if !session.isReachable { self.view.reachable = false; self.publish() }; self.startSync() } }
    /// 系统安装清单或配套状态变化后重新探测；安装成功本身不能产生在线证明。
    func sessionWatchStateDidChange(_ session: WCSession) { queue.async { self.startSync() } }
    /// 换表中间态立即撤销旧表证明，不对新表复用任何缓存ACK。
    func sessionDidBecomeInactive(_ session: WCSession) { queue.async { self.epoch = UUID(); self.cancelJob(); self.watchLease.deactivate(); self.view.reachable = false; self.publish() } }
    /// 系统切换到新配对Watch后重新激活，旧请求结果仍受epoch守卫。
    func sessionDidDeactivate(_ session: WCSession) { queue.async { self.epoch = UUID(); self.cancelJob(); self.watchLease.deactivate(); self.acknowledgedSnapshot = nil; self.acknowledgedManifest = nil; self.acknowledgedAssets = []; self.view = PhoneWatchView(); self.facts.clear(); self.publish(); session.activate() } }
    /// Watch主动请求只触发新probe；手机后台回paused，绝不借此启动后台LAN。
    func session(_ session: WCSession, didReceiveMessageData data: Data, replyHandler: @escaping (Data) -> Void) {
        queue.async {
            guard let request = try? WatchProtocol.request(data) else { replyHandler((try? WatchProtocol.encode(WatchRPCReply("invalid"))) ?? Data()); return }
            guard ["requestSync", "pause"].contains(request.op) else {
                replyHandler((try? WatchProtocol.encode(WatchRPCReply("invalid"))) ?? Data()); return
            }
            if request.op == "pause", let stopped = request.session, SharedValidation.validId(stopped),
               self.watchSession == nil || self.watchSession == stopped {
                self.epoch = UUID(); self.watchLease.deactivate(); self.cancelJob(); self.view.reachable = false;  self.publish()
            }
            let reply = WatchRPCReply(self.parentActive ? "accepted" : "paused")
            replyHandler((try? WatchProtocol.encode(reply)) ?? Data())
            if request.op == "requestSync", self.parentActive { self.failedAssets = []; self.startSync() }
        }
    }
    /// 只有有界元信息进入页面，不发布传输正文、文件URL或秘密。
    private func publish() { view.facts = facts; changed(view, parentGeneration) }
    /// 所有前台通信租约使用本机单调时间。
    private var now: UInt64 { DispatchTime.now().uptimeNanoseconds }
    deinit { timer?.cancel(); timeout?.cancel(); try? jobFile?.close() }
}
