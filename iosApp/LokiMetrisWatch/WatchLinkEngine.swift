import Foundation
import WatchConnectivity

/// Watch页面仅持有当前会话数据和独立通信事实，不借用手机IP或认证心跳。
struct WatchLinkView {
    var info: WatchDeviceInfo?
    var envelope: WatchSnapshotEnvelope?
    var receivedAt: Date?
    var images: [String: LanImageAsset] = [:]
    var status = "等待 iPhone 同步…"
    var canSync = false
    var connectionMode = "等待同步"
    var summaryOnly = false
    var error: String?
    var nameFeedback: String?
}

/// Watch独立串行owner，前台代次约束所有RPC，私有身份/缓存和文件均不在主线程操作。
// 所有可变状态均由 queue 拥有；异步 HTTP 只把不可变结果投回该队列。
final class WatchLinkEngine: NSObject, WCSessionDelegate, @unchecked Sendable {
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
    private var httpConfiguration: WatchHTTPConfiguration?
    private var configurationNeedsSave = false
    private var httpTask: Task<Void, Never>?
    private var httpAttempt: UUID?
    private var lastHTTPAttempt: UInt64?
    private var phoneRevision: UInt64 = 0
    private var lastPhoneProgress: UInt64?
    private var foregroundGeneration: UUID?
    private var fallback: DispatchWorkItem?

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
                let saved = try SharedJSON.decoder.decode(WatchDeviceInfo.self, from: Data(contentsOf: identity)); try saved.validate()
                info = WatchDeviceInfo(deviceId: saved.deviceId, name: saved.name, appVersion: appVersion)
            } else {
                info = WatchDeviceInfo(deviceId: UUID().uuidString.lowercased(), name: "Watch 显示端", appVersion: appVersion)
                try saveIdentity(info)
            }
            view.info = info
            var assets = root.appendingPathComponent("assets", isDirectory: true)
            try manager.createDirectory(at: assets, withIntermediateDirectories: true); try assets.setResourceValues(values)
            cache = try WatchAssetCache(directory: assets)
            do { httpConfiguration = try WatchHTTPConfigurationStore.load() }
            catch { view.error = "连接配置暂不可用，请在 iPhone 中重新同步。" }

            guard WCSession.isSupported() else { throw WidgetSnapshotError.unavailable }
            let session = WCSession.default; self.session = session; session.delegate = self; session.activate()
            view.status = "等待手机同步或 HTTP 刷新"
        } catch { view.error = "本机身份或缓存不可用，请重新打开应用。"; view.status = "暂不可同步" }
        publish()
    }
    /// Watch失焦即撤销前台资格，系统高优先级后台回调也不能续租。
    func setActive(_ active: Bool) { queue.async {
        guard active != self.active else { return }; self.active = active
        if active {
            self.foregroundGeneration = UUID()
            self.lastHTTPAttempt = nil
            self.clearLiveDisplay()
            try? self.lease.activate(session: UUID().uuidString.lowercased())
            self.timer = WatchProtocol.heartbeat(on: self.queue) { [weak owner = self] in owner?.tick() }
            self.requestSync()
        } else {
            self.foregroundGeneration = nil
            let oldSession = self.lease.session
            self.lease.deactivate(); self.cancelHTTP(); self.fallback?.cancel(); self.fallback = nil
            self.clearLiveDisplay(); self.timer?.cancel(); self.timer = nil
            self.view.canSync = false; self.view.status = "已暂停，返回前台后重新同步"
            if let oldSession { self.sendPause(oldSession) }
        }
        self.publish()
    } }
    /// 明确刷新仍先请求手机；手机不可用时允许立即重试一次 HTTP。
    func synchronize() { queue.async { self.lastHTTPAttempt = nil; self.requestSync() } }
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
        let data = try SharedJSON.encoder.encode(info); try data.write(to: path, options: [.atomic,.completeFileProtectionUntilFirstUserAuthentication])
        guard try Data(contentsOf: path) == data else { throw WidgetSnapshotError.unavailable }
    }
    /// 手机有实时数据时优先；不可达、后台或超过等待期限时自行通过 HTTP 读取。
    private func requestSync() {
        guard active, view.info != nil else { return }
        guard let session, session.activationState == .activated, session.isReachable else { startHTTP(); return }
        guard physicalRPC == nil else {
            if outgoingExpired { startHTTP() }
            return
        }
        let revision = phoneRevision
        var request = WatchRPC("requestSync"); request.session = lease.session
        request.configurationRevision = httpConfiguration?.revision
        if let configuration = httpConfiguration, let bytes = try? configuration.encoded() {
            request.configurationHash = WatchProtocol.hash(bytes)
        }
        send(request) { [weak self] reply in
            guard let self, self.active else { return }
            if let configuration = reply.configuration {
                do { try self.applyConfiguration(configuration) }
                catch { self.view.error = "手机连接配置未能保存，请重新同步。" }
            }
            if reply.status == "http" || reply.status == "paused" || reply.status == "unavailable" {
                // 回执可能晚于手机主动推送的新快照，旧不可用状态不能取消新传输。
                if self.phoneRevision == revision { self.invalidateDisplay(); self.startHTTP() }
            } else if reply.status == "accepted" {
                if self.phoneRevision == revision { self.waitForPhone() }
                if !self.view.canSync { self.view.status = "正在等待 iPhone 同步…" }
            } else if self.phoneRevision == revision { self.startHTTP() }
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
        if lease.lastContact != nil && !lease.reachable(now: now) { invalidateDisplay(); startHTTP(); publish() }
        requestSync()
    }

    private func waitForPhone() {
        guard fallback == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }; self.fallback = nil
            self.startHTTP()
        }
        fallback = work
        queue.asyncAfter(deadline: .now() + WatchProtocol.rpcTimeout, execute: work)
    }

    /// 真实手机快照或其已核验缓存 ACK 优先于尚未完成的 HTTP。
    private func phoneSnapshotReceived() {
        phoneRevision &+= 1
        cancelHTTP(); fallback?.cancel(); fallback = nil
        view.summaryOnly = false; view.connectionMode = "iPhone 同步"
    }

    private func cancelHTTP() {
        httpAttempt = nil; httpTask?.cancel(); httpTask = nil
    }

    /// 配置单独保存在本机 Keychain，永不保存主连接配对密钥或展示快照。
    private func applyConfiguration(_ configuration: WatchHTTPConfiguration) throws {
        try configuration.validate()
        if configuration == httpConfiguration {
            if configurationNeedsSave {
                try WatchHTTPConfigurationStore.save(configuration); configurationNeedsSave = false
            }
            return
        }
        guard configuration.supersedes(httpConfiguration) else { return }
        let keepPhoneSnapshot = record != nil && !view.summaryOnly &&
            view.envelope?.phoneId == configuration.phoneId &&
            configuration.target != nil && view.envelope?.sourceId == configuration.target?.sourceId
        let keepPhoneTransfer = snapshotTransfer != nil && configuration.target != nil &&
            (httpConfiguration == nil || httpConfiguration?.phoneId == configuration.phoneId) &&
            (httpConfiguration?.target == nil || httpConfiguration?.target?.sourceId == configuration.target?.sourceId)
        httpConfiguration = configuration
        configurationNeedsSave = true
        cancelHTTP(); lastHTTPAttempt = nil; fallback?.cancel(); fallback = nil
        if !keepPhoneSnapshot && !keepPhoneTransfer { clearLiveDisplay(); invalidateDisplay() }
        if keepPhoneTransfer { waitForPhone() }
        view.status = configuration.target == nil ? "请在 iPhone 中连接支持 HTTP 的桌面" : "连接配置已更新"
        publish()
        do { try WatchHTTPConfigurationStore.save(configuration); configurationNeedsSave = false }
        catch {
            // 即使磁盘不可写，撤销在本次进程内也立即生效，且尽力删除旧持久配置。
            try? WatchHTTPConfigurationStore.discard()
            throw error
        }
    }

    /// 单个有界请求；前台、目标代次、手机快照版本和请求身份共同拒绝迟到响应。
    private func startHTTP() {
        guard active, httpTask == nil else { return }
        if record != nil, !view.summaryOnly, session?.isReachable == true, lease.reachable(now: now) { return }
        if snapshotTransfer != nil || assetTransfer != nil {
            if let lastPhoneProgress, now >= lastPhoneProgress,
               now - lastPhoneProgress < UInt64(WatchProtocol.rpcTimeout * 1_000_000_000) { return }
            cancelTransfers()
        }
        guard let configuration = httpConfiguration, configuration.target != nil else {
            view.status = "请先在 iPhone 中连接桌面，获取 HTTP 配置"; publish(); return
        }
        if let lastHTTPAttempt, now >= lastHTTPAttempt, now - lastHTTPAttempt < 15_000_000_000 { return }
        let attempt = UUID(), foreground = foregroundGeneration, revision = phoneRevision
        httpAttempt = attempt; lastHTTPAttempt = now
        view.status = "正在通过 HTTP 刷新…"; publish()
        httpTask = Task { [weak self] in
            do {
                guard let target = configuration.target else { return }
                let summary = try await WidgetHTTPClient().fetch(target)
                let envelope = try WatchSnapshotEnvelope.fromHTTP(summary, configuration: configuration)
                self?.queue.async { [weak self] in
                    guard let self, self.httpAttempt == attempt else { return }
                    self.httpTask = nil; self.httpAttempt = nil
                    guard self.active, self.foregroundGeneration == foreground, self.httpConfiguration == configuration,
                          self.phoneRevision == revision else { return }
                    self.cancelTransfers(); self.record = nil
                    self.view.envelope = envelope; self.view.receivedAt = summary.receivedDate
                    self.view.images = [:]; self.view.summaryOnly = true; self.view.canSync = true
                    self.view.connectionMode = "HTTP 直连"; self.view.status = "已通过 HTTP 同步"; self.view.error = nil
                    self.publish()
                }
            } catch {
                self?.queue.async { [weak self] in
                    guard let self, self.httpAttempt == attempt else { return }
                    self.httpTask = nil; self.httpAttempt = nil
                    guard self.active, self.foregroundGeneration == foreground, self.httpConfiguration == configuration else { return }
                    self.view.canSync = false
                    self.view.connectionMode = self.view.envelope == nil ? "等待同步" : "上次同步"
                    self.view.status = "HTTP 暂不可用，请确认电脑在线且局域网可达"
                    self.view.error = "刷新失败，保留上次成功结果与时间。"; self.publish()
                }
            }
        }
    }

    private func applyContext(_ context: [String: Any]) {
        guard let data = context["watchHTTPConfiguration"] as? Data else { return }
        do { try applyConfiguration(WatchHTTPConfiguration.decode(data)) }
        catch { view.error = "手机连接配置无效或暂不可保存。"; publish() }
    }
    /// 仅接受当前前台代次，所有块按严格顺序保存后才回复下一偏移。
    private func receive(_ request: WatchRPC) throws -> WatchRPCReply {
        guard active, let info = view.info, let session = lease.session else { return WatchRPCReply("paused") }
        if lease.lastContact != nil && !lease.reachable(now: now) {
            invalidateDisplay(); startHTTP(); publish(); return WatchRPCReply("paused")
        }
        if request.op == "probe" {
            guard let id = request.id, SharedValidation.validId(id) else { throw WidgetSnapshotError.invalid }
            try lease.received(session: session, now: now)
            if record != nil, !view.summaryOnly { phoneSnapshotReceived() }
            var reply = WatchRPCReply("ready"); reply.id = id; reply.session = session; reply.info = info; reply.snapshotHash = record?.snapshotHash
            view.canSync = true; view.status = "可经 iPhone 同步"; publish(); return reply
        }
        guard request.session == session, let id = request.id, SharedValidation.validId(id) else { throw WidgetSnapshotError.invalid }
        try lease.received(session: session, now: now)
        var reply = WatchRPCReply("accepted"); reply.id = id; reply.session = session
        switch request.op {
        case "pause":
            invalidateDisplay(); startHTTP(); publish()
            reply.status = "paused"; return reply
        case "snapshotBegin":
            guard let hash = request.hash, let length = request.length else { throw WidgetSnapshotError.invalid }
            phoneRevision &+= 1; cancelHTTP()
            cancelTransfers()
            try assembler.begin(id: id, hash: hash, length: length)
            if let record, record.snapshotHash == hash, (try? record.validate()) != nil {
                assembler.cancel(); reply.status = "cached"; reply.snapshotHash = hash
                phoneSnapshotReceived()
            } else { snapshotTransfer = id; snapshotHash = hash; reply.offset = 0 }
        case "snapshotChunk":
            guard snapshotTransfer == id, let offset = request.offset, let data = request.data else { throw WidgetSnapshotError.invalid }
            let (next, value) = try assembler.accept(id: id, offset: offset, data: data); reply.offset = next
            if let value {
                if let configuration = httpConfiguration, let target = configuration.target {
                    guard value.envelope.phoneId == configuration.phoneId, value.envelope.sourceId == target.sourceId else {
                        throw WidgetSnapshotError.invalid
                    }
                }
                let record = WatchDisplayRecord(schemaVersion: 1, envelopeData: value.data, snapshotHash: value.hash, receivedAtMs: Date().epochMs)
                try record.validate(); self.record = record; view.envelope = value.envelope
                phoneSnapshotReceived()
                view.receivedAt = Date(epochMs: record.receivedAtMs)
                snapshotTransfer = nil; snapshotHash = nil; reply.status = "complete"; reply.snapshotHash = record.snapshotHash
                let hashes = Set(value.envelope.snapshot.hooks.compactMap(\.image)); view.images = view.images.filter { hashes.contains($0.key) }
                cache?.prune(keeping: hashes); loadImages()
            } else { reply.status = "continue" }
        case "assetBegin":
            guard let asset = request.asset, let snapshot = view.envelope?.snapshot, let cache,
                  snapshot.assets.contains(asset), snapshot.hooks.contains(where: { $0.image == asset.hash }) else { throw WidgetSnapshotError.invalid }
            cache.cancel(); assetTransfer = nil; assetDescriptor = nil
            if let path = try cache.cached(asset) { reply.status = "cached"; loadImage(path, asset: asset, cache: cache) }
            else { try cache.begin(asset, id: id); assetTransfer = id; assetDescriptor = asset; reply.offset = 0 }
        case "assetChunk":
            guard assetTransfer == id, let asset = assetDescriptor, let cache, let offset = request.offset, let data = request.data else { throw WidgetSnapshotError.invalid }
            let (next, path) = try cache.accept(id: id, offset: offset, data: data); reply.offset = next
            if let path { loadImage(path, asset: asset, cache: cache); assetTransfer = nil; assetDescriptor = nil; reply.status = "complete"; cache.prune(keeping: Set(view.envelope?.snapshot.hooks.compactMap(\.image) ?? [])) }
            else { reply.status = "continue" }
        default: throw WidgetSnapshotError.invalid
        }
        lastPhoneProgress = now
        fallback?.cancel(); fallback = nil
        if snapshotTransfer != nil || assetTransfer != nil { waitForPhone() }
        view.canSync = true; view.status = "已通过 iPhone 同步"; view.error = nil; publish(); return reply
    }
    /// 加载时仍完整核验内容缓存，界面不会同步解码或访问图片正文。
    private func loadImages() {
        guard let snapshot = view.envelope?.snapshot, let cache else { return }
        let hashes = Set(snapshot.hooks.compactMap(\.image))
        for asset in snapshot.assets where hashes.contains(asset.hash) && view.images[asset.hash] == nil {
            if let path = try? cache.cached(asset) { loadImage(path, asset: asset, cache: cache) }
        }
    }
    /// 相同摘要复用完整动画，重复缓存ACK不会更换播放身份并从头重播。
    private func loadImage(_ path: URL, asset: LanDisplaySnapshot.Asset, cache: WatchAssetCache) {
        guard view.images[asset.hash] == nil else { return }
        view.images[asset.hash] = try? cache.image(path, mime: asset.mime)
    }
    /// 失败、暂停和新快照只撤销未完成接收器，不删除已经完成的私有缓存。
    private func cancelTransfers() { assembler.cancel(); snapshotTransfer = nil; snapshotHash = nil; cache?.cancel(); assetTransfer = nil; assetDescriptor = nil }
    /// 物理请求终态前只保留一个槽，超时不反复创建系统排队请求。
    private func send(_ request: WatchRPC, completed: @escaping (WatchRPCReply) -> Void) {
        guard let session, physicalRPC == nil, let data = try? WatchProtocol.encode(request) else { return }
        let id = UUID(); let generation = lease.session; let revision = phoneRevision
        physicalRPC = id; outgoingExpired = false
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.physicalRPC == id else { return }; self.outgoingExpired = true
            if self.phoneRevision == revision { self.invalidateDisplay(); self.startHTTP(); self.publish() }
        }
        self.timeout = timeout; queue.asyncAfter(deadline: .now() + WatchProtocol.rpcTimeout, execute: timeout)
        session.sendMessageData(data, replyHandler: { [weak self] data in self?.queue.async { self?.sent(id: id, generation: generation, revision: revision, data: data, completed: completed) } }, errorHandler: { [weak self] _ in self?.queue.async { self?.sent(id: id, generation: generation, revision: revision, data: nil, completed: completed) } })
    }
    /// 旧系统回调只释放自身槽，不能把已退出的Watch前台租约恢复。
    private func sent(id: UUID, generation: String?, revision: UInt64, data: Data?, completed: (WatchRPCReply) -> Void) {
        guard physicalRPC == id else { return }; physicalRPC = nil; timeout?.cancel(); timeout = nil
        guard !outgoingExpired, generation == lease.session else { outgoingExpired = false; return }
        if let data, let reply = try? WatchProtocol.reply(data) { completed(reply) }
        else if phoneRevision == revision { invalidateDisplay(); startHTTP(); publish() }
    }
    /// 激活只允许尝试同步，不凭系统状态宣称桌面或手机已经可通信。
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) { queue.async { if error != nil { self.view.error = "配套会话暂不可用。"; self.publish() }; self.applyContext(session.receivedApplicationContext); self.requestSync() } }
    /// 失去手机通道后撤销传输代次，保留结果并请求 HTTP 后备。
    func sessionReachabilityDidChange(_ session: WCSession) { queue.async { if !session.isReachable { self.invalidateDisplay(); self.publish() }; self.requestSync() } }
    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        queue.async { self.applyContext(applicationContext); self.requestSync() }
    }
    /// 所有系统消息转入唯一串行owner，解析或IO失败回复invalid并清理部分文件。
    func session(_ session: WCSession, didReceiveMessageData data: Data, replyHandler: @escaping (Data) -> Void) {
        queue.async {
            let reply: WatchRPCReply
            do { reply = try self.receive(WatchProtocol.request(data)) }
            catch { self.invalidateDisplay(); self.startHTTP(); self.publish(); reply = WatchRPCReply("invalid") }
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
        view.summaryOnly = false; view.connectionMode = "等待同步"
    }
    /// 失联后撤销手机接收代次；已有结果仍是上次同步，不再声称实时可通信。
    private func invalidateDisplay() {
        cancelTransfers(); lease.deactivate(); view.canSync = false
        view.connectionMode = view.envelope == nil ? "等待同步" : "上次同步"
        if active { try? lease.activate(session: UUID().uuidString.lowercased()) }
    }
    /// UI仅收不可变投影，主线程由薄模型合并投递。
    private func publish() { changed(view) }
    deinit { timer?.cancel(); timeout?.cancel(); fallback?.cancel(); httpTask?.cancel(); cache?.cancel() }
}
