import Foundation
import WatchConnectivity
import CoreGraphics

/// Watch页面仅持有当前会话数据和独立通信事实，不借用手机IP或认证心跳。
struct WatchLinkView {
    var info: WatchDeviceInfo?
    var envelope: WatchSnapshotEnvelope?
    var receivedAt: Date?
    var images: [String: CGImage] = [:]
    var status = "等待 iPhone 同步…"
    var canSync = false
    var error: String?
    var nameFeedback: String?
}

/// Watch独立串行owner，前台代次约束所有RPC，私有身份/缓存和文件均不在主线程操作。
final class WatchLinkEngine: NSObject, WCSessionDelegate {
    private let queue = DispatchQueue(label: "LokiMetris.watch-link")
    private let changed: (WatchLinkView) -> Void
    private var view = WatchLinkView()
    private var session: WCSession?
    private var lease = WatchForegroundLease()
    private var active = false
    private var directory: URL?
    private var cache: WatchAssetCache?
    private var record: WatchDisplayRecord?
    private var assembler = WatchSnapshotAssembler()
    private var snapshotTransfer: String?
    private var snapshotHash: String?
    private var assetTransfer: String?
    private var assetDescriptor: LanDisplaySnapshot.Asset?
    private var timer: DispatchSourceTimer?
    private var physicalRPC: UUID?
    private var outgoingExpired = false
    private var timeout: DispatchWorkItem?

    /// 构造只安排后台初始化，真实数据加载后再激活系统配套会话。
    init(changed: @escaping (WatchLinkView) -> Void) {
        self.changed = changed; super.init()
        queue.async { self.initialize() }
    }
    /// 启动坏身份失败关闭，不生成新UUID覆盖；首次安装才创建独立应用身份。
    private func initialize() {
        do {
            let manager = FileManager.default
            var root = try manager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("WatchLink", isDirectory: true)
            try manager.createDirectory(at: root, withIntermediateDirectories: true)
            guard try root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw WidgetSnapshotError.invalid }
            var values = URLResourceValues(); values.isExcludedFromBackup = true; try root.setResourceValues(values)
            directory = root; try WatchDisplayStore(directory: root).discardLegacy()
            let identity = root.appendingPathComponent("watch-identity-v1.json")
            let info: WatchDeviceInfo
            if manager.fileExists(atPath: identity.path) {
                let properties = try identity.resourceValues(forKeys: [.isSymbolicLinkKey,.isRegularFileKey,.fileSizeKey])
                guard properties.isSymbolicLink != true, properties.isRegularFile == true, (properties.fileSize ?? 2048) <= 1024 else { throw WidgetSnapshotError.invalid }
                let saved = try JSONDecoder().decode(WatchDeviceInfo.self, from: Data(contentsOf: identity)); try saved.validate()
                info = WatchDeviceInfo(deviceId: saved.deviceId, name: saved.name, appVersion: appVersion)
            } else {
                info = WatchDeviceInfo(deviceId: UUID().uuidString.lowercased(), name: "Watch 显示端", appVersion: appVersion)
                try saveIdentity(info)
            }
            view.info = info
            var assets = root.appendingPathComponent("assets", isDirectory: true)
            try manager.createDirectory(at: assets, withIntermediateDirectories: true); try assets.setResourceValues(values)
            cache = try WatchAssetCache(directory: assets)

            guard WCSession.isSupported() else { throw WidgetSnapshotError.unavailable }
            let session = WCSession.default; self.session = session; session.delegate = self; session.activate()
            view.status = "等待 iPhone 前台同步"
        } catch { view.error = "本机身份或缓存不可用，请重新打开应用。"; view.status = "暂不可同步" }
        publish()
    }
    /// Watch失焦即撤销前台资格，系统高优先级后台回调也不能续租。
    func setActive(_ active: Bool) { queue.async {
        guard active != self.active else { return }; self.active = active
        if active {
            self.clearLiveDisplay()
            try? self.lease.activate(session: UUID().uuidString.lowercased())
            let timer = DispatchSource.makeTimerSource(queue: self.queue); timer.schedule(deadline: .now() + 1, repeating: 15)
            timer.setEventHandler { [weak owner = self] in owner?.tick() }; self.timer = timer; timer.resume()
            self.requestSync()
        } else {
            let oldSession = self.lease.session
            self.lease.deactivate(); self.clearLiveDisplay(); self.timer?.cancel(); self.timer = nil
            self.view.canSync = false; self.view.status = "已暂停，返回前台后重新同步"
            if let oldSession { self.sendPause(oldSession) }
        }
        self.publish()
    } }
    /// 设备管理中的明确请求只访问当前配套iPhone，不启动独立Watch局域网服务。
    func synchronize() { queue.async { self.requestSync() } }
    /// 名称只有真实原子保存成功后更新；保存不重开前台代次或网络会话。
    func saveName(_ name: String) { queue.async {
        guard let old = self.view.info else { return }
        let info = WatchDeviceInfo(deviceId: old.deviceId, name: name, appVersion: self.appVersion)
        do { try self.saveIdentity(info); self.view.info = info; self.view.nameFeedback = "名称已保存，下次通信生效。" }
        catch { self.view.nameFeedback = "名称未能保存，请重试。" }
        self.publish()
    } }
    /// 身份文件只属于Watch应用私有不备份目录，失败不能修改内存身份。
    private func saveIdentity(_ info: WatchDeviceInfo) throws {
        try info.validate(); guard let directory else { throw WidgetSnapshotError.unavailable }
        let path = directory.appendingPathComponent("watch-identity-v1.json")
        if FileManager.default.fileExists(atPath: path.path) {
            let values = try path.resourceValues(forKeys: [.isSymbolicLinkKey,.isRegularFileKey]); guard values.isSymbolicLink != true, values.isRegularFile == true else { throw WidgetSnapshotError.invalid }
        }
        let data = try JSONEncoder().encode(info); try data.write(to: path, options: [.atomic,.completeFileProtectionUntilFirstUserAuthentication])
        guard try Data(contentsOf: path) == data else { throw WidgetSnapshotError.unavailable }
    }
    /// 同步意图有一个物理请求槽；后台手机回复paused，Watch不借此启动手机LAN。
    private func requestSync() {
        guard active, physicalRPC == nil, view.info != nil, let session, session.activationState == .activated, session.isReachable else {
            if active && session?.isReachable != true { clearLiveDisplay(); view.status = "请保持 iPhone 应用在前台"; publish() }; return
        }
        var request = WatchRPC("requestSync"); request.session = lease.session
        send(request) { [weak self] reply in
            guard let self, self.active else { return }
            if reply.status == "paused" { self.invalidateDisplay(); self.view.status = "iPhone 尚未连接桌面或已暂停"; self.view.canSync = false }
            else if !self.view.canSync { self.view.status = "正在等待 iPhone 同步…" }
            self.publish()
        }
    }
    /// 离前台的pause只尽力告知，发送失败由手机自身45秒租约收敛。
    private func sendPause(_ oldSession: String) {
        guard physicalRPC == nil, let session, session.activationState == .activated, session.isReachable else { return }
        var request = WatchRPC("pause"); request.session = oldSession; send(request) { _ in }
    }
    /// 单调超时不把缓存显示时间当作通信，所有后台周期均已取消。
    private func tick() {
        guard active else { return }
        if lease.lastContact != nil && !lease.reachable(now: now) { invalidateDisplay(); view.status = "请保持两端应用在前台"; publish() }
        requestSync()
    }
    /// 仅接受当前前台代次，所有块按严格顺序保存后才回复下一偏移。
    private func receive(_ request: WatchRPC) throws -> WatchRPCReply {
        guard active, let info = view.info, let session = lease.session else { return WatchRPCReply("paused") }
        if lease.lastContact != nil && !lease.reachable(now: now) {
            invalidateDisplay(); view.status = "等待新的实时同步"; publish(); return WatchRPCReply("paused")
        }
        if request.op == "probe" {
            guard let id = request.id, WatchProtocol.validId(id) else { throw WidgetSnapshotError.invalid }
            try lease.received(session: session, now: now)
            var reply = WatchRPCReply("ready"); reply.id = id; reply.session = session; reply.info = info; reply.snapshotHash = record?.snapshotHash
            view.canSync = true; view.status = "可经 iPhone 同步"; publish(); return reply
        }
        guard request.session == session, let id = request.id, WatchProtocol.validId(id) else { throw WidgetSnapshotError.invalid }
        try lease.received(session: session, now: now)
        var reply = WatchRPCReply("accepted"); reply.id = id; reply.session = session
        switch request.op {
        case "pause":
            invalidateDisplay(); view.status = "iPhone 尚未连接桌面或已暂停"; publish()
            reply.status = "paused"; return reply
        case "snapshotBegin":
            guard let hash = request.hash, let length = request.length else { throw WidgetSnapshotError.invalid }
            cancelTransfers()
            try assembler.begin(id: id, hash: hash, length: length)
            if let record, record.snapshotHash == hash, (try? record.validate()) != nil {
                assembler.cancel(); reply.status = "cached"; reply.snapshotHash = hash
            } else { snapshotTransfer = id; snapshotHash = hash; reply.offset = 0 }
        case "snapshotChunk":
            guard snapshotTransfer == id, let offset = request.offset, let data = request.data else { throw WidgetSnapshotError.invalid }
            let (next, value) = try assembler.accept(id: id, offset: offset, data: data); reply.offset = next
            if let value {
                let record = WatchDisplayRecord(schemaVersion: 1, envelopeData: value.data, snapshotHash: value.hash, receivedAtMs: Int64(Date().timeIntervalSince1970 * 1000))
                try record.validate(); self.record = record; view.envelope = value.envelope
                view.receivedAt = Date(timeIntervalSince1970: Double(record.receivedAtMs) / 1000)
                snapshotTransfer = nil; snapshotHash = nil; reply.status = "complete"; reply.snapshotHash = record.snapshotHash
                let hashes = Set(value.envelope.snapshot.hooks.compactMap(\.image)); view.images = view.images.filter { hashes.contains($0.key) }
                cache?.prune(keeping: hashes); loadImages()
            } else { reply.status = "continue" }
        case "assetBegin":
            guard let asset = request.asset, let snapshot = view.envelope?.snapshot, let cache,
                  snapshot.assets.contains(asset), snapshot.hooks.contains(where: { $0.image == asset.hash }) else { throw WidgetSnapshotError.invalid }
            cache.cancel(); assetTransfer = nil; assetDescriptor = nil
            if let path = try cache.cached(asset) { reply.status = "cached"; view.images[asset.hash] = cache.thumbnail(path) }
            else { try cache.begin(asset, id: id); assetTransfer = id; assetDescriptor = asset; reply.offset = 0 }
        case "assetChunk":
            guard assetTransfer == id, let asset = assetDescriptor, let cache, let offset = request.offset, let data = request.data else { throw WidgetSnapshotError.invalid }
            let (next, path) = try cache.accept(id: id, offset: offset, data: data); reply.offset = next
            if let path { view.images[asset.hash] = cache.thumbnail(path); assetTransfer = nil; assetDescriptor = nil; reply.status = "complete"; cache.prune(keeping: Set(view.envelope?.snapshot.hooks.compactMap(\.image) ?? [])) }
            else { reply.status = "continue" }
        default: throw WidgetSnapshotError.invalid
        }
        view.canSync = true; view.status = "已通过 iPhone 同步"; view.error = nil; publish(); return reply
    }
    /// 加载时仍完整核验内容缓存，界面不会同步解码或访问图片正文。
    private func loadImages() {
        guard let snapshot = view.envelope?.snapshot, let cache else { return }
        let hashes = Set(snapshot.hooks.compactMap(\.image))
        for asset in snapshot.assets where hashes.contains(asset.hash) && view.images[asset.hash] == nil {
            if let path = try? cache.cached(asset) { view.images[asset.hash] = cache.thumbnail(path) }
        }
    }
    /// 失败、暂停和新快照只撤销未完成接收器，不删除已经完成的私有缓存。
    private func cancelTransfers() { assembler.cancel(); snapshotTransfer = nil; snapshotHash = nil; cache?.cancel(); assetTransfer = nil; assetDescriptor = nil }
    /// 物理请求终态前只保留一个槽，超时不反复创建系统排队请求。
    private func send(_ request: WatchRPC, completed: @escaping (WatchRPCReply) -> Void) {
        guard let session, physicalRPC == nil, let data = try? WatchProtocol.encode(request) else { return }
        let id = UUID(); let generation = lease.session
        physicalRPC = id; outgoingExpired = false
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.physicalRPC == id else { return }; self.outgoingExpired = true
            self.invalidateDisplay(); self.view.error = "iPhone 响应超时，等待系统结束上次请求。"; self.publish()
        }
        self.timeout = timeout; queue.asyncAfter(deadline: .now() + 8, execute: timeout)
        session.sendMessageData(data, replyHandler: { [weak self] data in self?.queue.async { self?.sent(id: id, generation: generation, data: data, completed: completed) } }, errorHandler: { [weak self] _ in self?.queue.async { self?.sent(id: id, generation: generation, data: nil, completed: completed) } })
    }
    /// 旧系统回调只释放自身槽，不能把已退出的Watch前台租约恢复。
    private func sent(id: UUID, generation: String?, data: Data?, completed: (WatchRPCReply) -> Void) {
        guard physicalRPC == id else { return }; physicalRPC = nil; timeout?.cancel(); timeout = nil
        guard !outgoingExpired, generation == lease.session else { outgoingExpired = false; return }
        if let data, let reply = try? WatchProtocol.reply(data) { completed(reply) }
        else { invalidateDisplay(); view.error = "iPhone 暂不可同步，请稍后重试。"; publish() }
    }
    /// 激活只允许尝试同步，不凭系统状态宣称桌面或手机已经可通信。
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) { queue.async { if error != nil { self.view.error = "配套会话暂不可用。"; self.publish() }; self.requestSync() } }
    /// 丢失即时可达时清空实时展示并撤销旧传输代次。
    func sessionReachabilityDidChange(_ session: WCSession) { queue.async { if !session.isReachable { self.invalidateDisplay(); self.publish() }; self.requestSync() } }
    /// 所有系统消息转入唯一串行owner，解析或IO失败回复invalid并清理部分文件。
    func session(_ session: WCSession, didReceiveMessageData data: Data, replyHandler: @escaping (Data) -> Void) {
        queue.async {
            let reply: WatchRPCReply
            do { reply = try self.receive(WatchProtocol.request(data)) }
            catch { self.invalidateDisplay(); self.view.error = "本次同步失败，等待新的完整数据。"; self.publish(); reply = WatchRPCReply("invalid") }
            replyHandler((try? WatchProtocol.encode(reply)) ?? Data())
        }
    }
    /// App版本只作公开元信息，不影响稳定安装UUID。
    private var appVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0" }
    /// 单调期限与墙钟显示时间各自独立。
    private var now: UInt64 { DispatchTime.now().uptimeNanoseconds }
    /// 只清当前展示与部分传输，图片磁盘缓存和安装身份不受影响。
    private func clearLiveDisplay() {
        cancelTransfers(); record = nil; view.envelope = nil; view.receivedAt = nil; view.images = [:]; view.canSync = false
    }
    /// 失联后更换前台接收代次，迟到的旧快照块不能恢复已失效的数字和状态。
    private func invalidateDisplay() {
        clearLiveDisplay(); lease.deactivate()
        if active { try? lease.activate(session: UUID().uuidString.lowercased()) }
    }
    /// UI仅收不可变投影，主线程由薄模型合并投递。
    private func publish() { changed(view) }
    deinit { timer?.cancel(); timeout?.cancel(); cache?.cancel() }
}
