import Foundation
import WatchConnectivity

/// 历史展示和实时通信资格独立；缓存始终携带原始时间与来源。
/// 可比较：手机逐块传输时引擎每块都会调用 publish，只有内容变化才真正驱动表盘重绘。
struct WatchLinkView: Equatable {
    var info: WatchDeviceInfo?
    var envelope: WatchSnapshotEnvelope?
    var images: [String: LanImageAsset] = [:]
    var summaryOnly = false
}

/// Watch独立串行owner，前台代次约束所有RPC，私有身份/缓存和文件均不在主线程操作。
// 所有可变状态均由 queue 拥有；异步 HTTP 只把不可变结果投回该队列。
final class WatchLinkEngine: NSObject, WCSessionDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "LokiMetris.watch-link")
    /// 多帧解码可能较慢，串行放在独立队列，RPC回执不必等待；串行也约束Watch峰值内存。
    private let decoder = DispatchQueue(label: "LokiMetris.watch-decode", qos: .utility)
    private let changed: (WatchLinkView) -> Void
    private var view = WatchLinkView()
    /// 上次投递给主线程的视图，相同内容不再唤醒 SwiftUI。
    private var lastPublished: WatchLinkView?
    private var session: WCSession?
    private var lease = WatchForegroundLease()
    private var active = false
    private var directory: URL?
    private var cache: WatchAssetCache?
    /// 正在解码与已确认无法解码的摘要；后者在换快照来源前不再反复读盘重试。
    private var decodingImages: Set<String> = []
    private var failedImages: Set<String> = []
    private var record: WatchDisplayRecord?
    private var assembler = WatchSnapshotAssembler()
    private var snapshotTransfer: String?
    private var snapshotHash: String?
    private var snapshotSummaryOnly = false
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
    private var backgroundRefreshID: UUID?
    private var backgroundCompletions: [() -> Void] = []
    private var backgroundDeadline: DispatchWorkItem?
    private var canRefresh: Bool { active || backgroundRefreshID != nil }

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
            directory = root
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
            catch { NSLog("连接配置暂不可用，请在 iPhone 中重新同步。") }

            do {
                if let saved = try WatchDisplayStore(directory: root).load() {
                    let envelope = try saved.validate()
                    if let configuration = httpConfiguration,
                       envelope.phoneId != configuration.phoneId ||
                        (configuration.target != nil && envelope.sourceId != configuration.target?.sourceId) {
                        try WatchDisplayStore(directory: root).discard()
                    } else {
                        record = saved; view.envelope = envelope; view.summaryOnly = saved.summaryOnly
                        loadImages()
                    }
                }
            } catch { NSLog("上次缓存暂不可读取，保留连接配置并重新同步。") }

            guard WCSession.isSupported() else { throw WidgetSnapshotError.unavailable }
            let session = WCSession.default; self.session = session; session.delegate = self; session.activate()
        } catch { NSLog("本机身份或缓存不可用，请重新打开应用。") }
        publish()
    }
    /// inactive包含Always On/frontmost；只有真正退到后台才撤销实时资格。
    func setActive(_ active: Bool) { queue.async {
        guard active != self.active else { return }; self.active = active
        if active {
            self.foregroundGeneration = UUID()
            self.lastHTTPAttempt = nil
            try? self.lease.activate(session: UUID().uuidString.lowercased())
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + WatchRefreshPolicy.interval,
                           repeating: WatchRefreshPolicy.interval, leeway: .seconds(5))
            timer.setEventHandler { [weak owner = self] in owner?.tick() }; timer.resume(); self.timer = timer
            self.requestSync()
        } else {
            self.foregroundGeneration = nil
            let oldSession = self.lease.session
            self.lease.deactivate(); self.cancelHTTP(); self.fallback?.cancel(); self.fallback = nil
            self.cancelTransfers(); self.timer?.cancel(); self.timer = nil
            if let oldSession { self.sendPause(oldSession) }
        }
        self.publish()
    } }
    /// 抬腕不重置图片、缓存或前台代次，立即检查手机的最新缓存。
    func resume() { queue.async { guard self.active else { return }; self.requestSync() } }

    /// 系统只给短暂执行窗口，先读手机缓存，不可达时用有界HTTP后备。
    func refreshInBackground(completion: @escaping () -> Void) { queue.async {
        self.backgroundCompletions.append(completion)
        guard self.backgroundRefreshID == nil else { return }
        self.backgroundRefreshID = UUID(); self.lastHTTPAttempt = nil
        if self.lease.session == nil, let background = self.backgroundRefreshID {
            try? self.lease.activate(session: background.uuidString.lowercased())
        }
        let deadline = DispatchWorkItem { [weak owner = self] in owner?.finishBackgroundRefresh() }
        self.backgroundDeadline = deadline
        self.queue.asyncAfter(deadline: .now() + WatchRefreshPolicy.backgroundBudget, execute: deadline)
        if let session = self.session { self.applyContext(session.receivedApplicationContext, finishRefresh: false) }
        self.requestSync()
    } }

    /// WC后台任务仅在系统待收内容处理结束后完成；激活失败也有明确截止。
    /// 每 1 秒检查一次系统是否还有待收内容，在有界窗口内少唤醒 CPU。
    func processBackgroundConnectivity(completion: @escaping () -> Void) { queue.async {
        if let session = self.session { self.applyContext(session.receivedApplicationContext, finishRefresh: false) }
        self.drainConnectivity(until: self.now + UInt64(WatchRefreshPolicy.backgroundBudget * 1_000_000_000), completion: completion)
    } }
    /// 轮询直到系统没有待收内容或到达截止时间。
    private func drainConnectivity(until deadline: UInt64, completion: @escaping () -> Void) {
        if now >= deadline || (session?.activationState == .activated && session?.hasContentPending == false) {
            completion(); return
        }
        queue.asyncAfter(deadline: .now() + 1) { self.drainConnectivity(until: deadline, completion: completion) }
    }
    /// 结束后台刷新窗口：不在前台时撤销所有在途工作，再回调系统。
    private func finishBackgroundRefresh() {
        guard backgroundRefreshID != nil else { return }
        backgroundRefreshID = nil; backgroundDeadline?.cancel(); backgroundDeadline = nil
        if !active { cancelHTTP(); fallback?.cancel(); fallback = nil; cancelTransfers(); lease.deactivate() }
        let callbacks = backgroundCompletions; backgroundCompletions = []
        callbacks.forEach { $0() }
    }
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
        guard canRefresh, view.info != nil else { return }
        guard let session, session.activationState == .activated, session.isReachable else { startHTTP(); return }
        guard physicalRPC == nil else {
            if outgoingExpired { startHTTP() }
            return
        }
        let revision = phoneRevision
        var request = WatchRPC("requestSync"); request.session = lease.session ?? backgroundRefreshID?.uuidString.lowercased()
        request.configurationRevision = httpConfiguration?.revision
        if let configuration = httpConfiguration, let bytes = try? configuration.encoded() {
            request.configurationHash = WatchProtocol.hash(bytes)
        }
        send(request) { [weak self] reply in
            guard let self, self.canRefresh else { return }
            if let configuration = reply.configuration {
                guard configuration.supersedes(self.httpConfiguration) else { self.finishCacheRead(); return }
                do { try self.applyConfiguration(configuration) }
                catch { NSLog("手机连接配置未能保存，请重新同步。") }
            }
            // 新context或分块已经推进展示后，旧RPC缓存/撤销不能回退来源。
            guard self.phoneRevision == revision else { self.finishCacheRead(); return }
            if reply.snapshotCacheCleared == true, reply.configuration == self.httpConfiguration, reply.configuration != nil {
                self.clearSnapshotCache(); self.startHTTP()
            } else if let bytes = reply.snapshotCache, let summaryOnly = reply.snapshotSummaryOnly {
                do {
                    try self.applyCachedEnvelope(bytes, summaryOnly: summaryOnly)
                    self.finishCacheRead()
                } catch { NSLog("手机缓存无效，保留上次结果。"); self.startHTTP() }
            } else if reply.status == "http" || reply.status == "paused" || reply.status == "unavailable" {
                // 回执可能晚于手机主动推送的新快照，旧不可用状态不能取消新传输。
                if self.phoneRevision == revision { self.invalidateDisplay(); self.startHTTP() }
            } else if reply.status == "accepted" {
                if self.phoneRevision == revision { self.waitForPhone() }
            } else if self.phoneRevision == revision { self.startHTTP() }
            self.publish()
        }
    }
    /// 离前台的pause只尽力告知，发送失败由手机自身45秒租约收敛。
    private func sendPause(_ oldSession: String) {
        guard physicalRPC == nil, let session, session.activationState == .activated, session.isReachable else { return }
        var request = WatchRPC("pause"); request.session = oldSession; send(request) { _ in }
    }
    /// 仅在系统允许前台/frontmost运行时每5分钟读取一次手机缓存。
    private func tick() {
        guard active else { return }
        if lease.lastContact != nil && !lease.reachable(now: now) { invalidateDisplay(); publish() }
        requestSync()
    }

    /// 手机答应推送后等待一个 RPC 超时（后台只等 2 秒），过期仍无进展就改走 HTTP。
    private func waitForPhone() {
        guard fallback == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }; self.fallback = nil
            self.startHTTP()
        }
        fallback = work
        queue.asyncAfter(deadline: .now() + (backgroundRefreshID == nil ? WatchProtocol.rpcTimeout : 2), execute: work)
    }

    /// 真实手机快照或其已核验缓存 ACK 优先于尚未完成的 HTTP。
    private func phoneSnapshotReceived() {
        phoneRevision &+= 1
        cancelHTTP(); fallback?.cancel(); fallback = nil
        view.summaryOnly = record?.summaryOnly ?? false
    }

    /// 取消在途 HTTP 请求；迟到结果因 attempt 不匹配被丢弃。
    private func cancelHTTP() {
        httpAttempt = nil; httpTask?.cancel(); httpTask = nil
    }

    /// HTTP授权单独存Keychain；换来源丢弃旧展示，暂时离线保留缓存。
    private func applyConfiguration(_ configuration: WatchHTTPConfiguration) throws {
        try configuration.validate()
        if configuration == httpConfiguration {
            if configurationNeedsSave {
                try WatchHTTPConfigurationStore.save(configuration); configurationNeedsSave = false
            }
            return
        }
        guard configuration.supersedes(httpConfiguration) else { return }
        let keepPhoneSnapshot = view.envelope?.phoneId == configuration.phoneId &&
            (configuration.target == nil || view.envelope?.sourceId == configuration.target?.sourceId)
        let keepPhoneTransfer = snapshotTransfer != nil && configuration.target != nil &&
            (httpConfiguration == nil || httpConfiguration?.phoneId == configuration.phoneId) &&
            (httpConfiguration?.target == nil || httpConfiguration?.target?.sourceId == configuration.target?.sourceId)
        httpConfiguration = configuration
        configurationNeedsSave = true
        cancelHTTP(); lastHTTPAttempt = nil; fallback?.cancel(); fallback = nil
        if !keepPhoneSnapshot && !keepPhoneTransfer {
            clearLiveDisplay(); invalidateDisplay()
            if let directory { try? WatchDisplayStore(directory: directory).discard() }
        }
        if keepPhoneTransfer { waitForPhone() }

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
        guard canRefresh, httpTask == nil else { return }
        if snapshotTransfer != nil || assetTransfer != nil {
            if let lastPhoneProgress, now >= lastPhoneProgress,
               now - lastPhoneProgress < UInt64(WatchProtocol.rpcTimeout * 1_000_000_000) { return }
            cancelTransfers()
        }
        guard let configuration = httpConfiguration, configuration.target != nil else {
            publish(); finishBackgroundRefresh(); return
        }
        if let lastHTTPAttempt, now >= lastHTTPAttempt, now - lastHTTPAttempt < 15_000_000_000 { return }
        let attempt = UUID(), foreground = foregroundGeneration, revision = phoneRevision
        httpAttempt = attempt; lastHTTPAttempt = now
        publish()
        httpTask = Task { [weak self] in
            do {
                guard let target = configuration.target else { return }
                let summary = try await WidgetHTTPClient().fetch(target)
                let envelope = try WatchSnapshotEnvelope.fromHTTP(summary, configuration: configuration)
                self?.queue.async { [weak self] in
                    guard let self, self.httpAttempt == attempt else { return }
                    self.httpTask = nil; self.httpAttempt = nil
                    guard self.canRefresh, self.foregroundGeneration == foreground, self.httpConfiguration == configuration,
                          self.phoneRevision == revision else { return }
                    do {
                        let envelope = try envelope.preservingCachedHookImages(from: self.view.envelope,
                            previousSummaryOnly: self.view.summaryOnly)
                        let bytes = try SharedJSON.sortedEncoder.encode(envelope)
                        let summaryOnly = !envelope.snapshot.hooks.contains(where: { $0.image != nil })
                        try self.applyCachedEnvelope(bytes, summaryOnly: summaryOnly)
                    } catch { NSLog("更新未能保存，保留上次缓存。") }
                    self.publish(); self.finishBackgroundRefresh()
                }
            } catch {
                self?.queue.async { [weak self] in
                    guard let self, self.httpAttempt == attempt else { return }
                    self.httpTask = nil; self.httpAttempt = nil
                    guard self.canRefresh, self.foregroundGeneration == foreground, self.httpConfiguration == configuration else { return }
                    NSLog("HTTP 暂不可用；刷新失败，保留上次成功结果与时间。"); self.publish(); self.finishBackgroundRefresh()
                }
            }
        }
    }

    /// 手机context可在后台送达，只更新持久展示，绝不续实时通信租约。
    private func applyContext(_ context: [String: Any], finishRefresh: Bool = true) {
        do {
            if let data = context["watchHTTPConfiguration"] as? Data {
                let configuration = try WatchHTTPConfiguration.decode(data)
                guard configuration.supersedes(httpConfiguration) else { return }
                try applyConfiguration(configuration)
            }
            if context["watchSnapshotCacheCleared"] as? Bool == true, context["watchHTTPConfiguration"] is Data {
                clearSnapshotCache()
                if finishRefresh { finishCacheRead() }
            } else if let data = context["watchSnapshotCache"] as? Data,
               let summaryOnly = context["watchSnapshotSummaryOnly"] as? Bool {
                try applyCachedEnvelope(data, summaryOnly: summaryOnly)
                if finishRefresh { finishCacheRead() }
            }
        } catch { NSLog("手机缓存或连接配置无效，保留上次合法结果。"); publish() }
    }

    /// 旧手机缓存先展示，再尝试HTTP；否则手机休眠时会永远只读同一份旧结果。
    private func finishCacheRead() {
        if canRefresh, WatchRefreshPolicy.shouldRefresh(receivedAtMs: view.envelope?.phoneReceivedAtMs, nowMs: Date().epochMs) {
            startHTTP()
        } else { finishBackgroundRefresh() }
    }

    /// 完整验证、来源/时间校验和落盘完成后才替换屏幕；相同缓存不重置动画。
    private func applyCachedEnvelope(_ data: Data, summaryOnly: Bool) throws {
        let candidate = WatchDisplayRecord(envelopeData: data, snapshotHash: WatchProtocol.hash(data),
                                          receivedAtMs: Date().epochMs, summaryOnly: summaryOnly)
        let envelope = try candidate.validate()
        if let configuration = httpConfiguration {
            guard envelope.phoneId == configuration.phoneId,
                  configuration.target == nil || envelope.sourceId == configuration.target?.sourceId else { throw WidgetSnapshotError.invalid }
        }
        guard try candidate.supersedes(record) else { return }
        if candidate.snapshotHash != record?.snapshotHash || candidate.summaryOnly != record?.summaryOnly {
            guard let directory else { throw WidgetSnapshotError.unavailable }
            try WatchDisplayStore(directory: directory).save(candidate)
            cancelTransfers(); record = candidate
            view.envelope = envelope
            view.summaryOnly = summaryOnly
            let hashes = Set(envelope.snapshot.hooks.compactMap(\.image))
            view.images = view.images.filter { hashes.contains($0.key) }; failedImages.formIntersection(hashes)
            cache?.prune(keeping: hashes)
            if !summaryOnly { loadImages() }
            phoneRevision &+= 1; cancelHTTP(); fallback?.cancel(); fallback = nil
        }
        publish()
    }
    /// 仅接受当前前台代次，所有块按严格顺序保存后才回复下一偏移。
    private func receive(_ request: WatchRPC) throws -> WatchRPCReply {
        guard canRefresh, let info = view.info, let session = lease.session else { return WatchRPCReply("paused") }
        if lease.lastContact != nil && !lease.reachable(now: now) {
            invalidateDisplay(); startHTTP(); publish(); return WatchRPCReply("paused")
        }
        if request.op == "probe" {
            guard let id = request.id, SharedValidation.validId(id) else { throw WidgetSnapshotError.invalid }
            try lease.received(session: session, now: now)
            var reply = WatchRPCReply("ready"); reply.id = id; reply.session = session; reply.info = info; reply.snapshotHash = view.summaryOnly ? nil : record?.snapshotHash
            publish(); return reply
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
            snapshotSummaryOnly = request.snapshotSummaryOnly ?? false
            if let record, record.matches(hash: hash, summaryOnly: snapshotSummaryOnly) {
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
                try applyCachedEnvelope(value.data, summaryOnly: snapshotSummaryOnly)
                guard let record = self.record, record.snapshotHash == value.hash else { throw WidgetSnapshotError.invalid }
                phoneSnapshotReceived()
                snapshotTransfer = nil; snapshotHash = nil; reply.status = "complete"; reply.snapshotHash = record.snapshotHash
                let hashes = Set(value.envelope.snapshot.hooks.compactMap(\.image)); view.images = view.images.filter { hashes.contains($0.key) }
                failedImages.formIntersection(hashes)
                cache?.prune(keeping: hashes); loadImages()
            } else { reply.status = "continue" }
        case "assetBegin":
            guard let asset = request.asset, let snapshot = view.envelope?.snapshot, let cache,
                  snapshot.assets.contains(asset), snapshot.hooks.contains(where: { $0.image == asset.hash }) else { throw WidgetSnapshotError.invalid }
            cache.cancel(); assetTransfer = nil; assetDescriptor = nil
            if let path = try cache.cached(asset) { reply.status = "cached"; loadImage(path, asset: asset) }
            else { try cache.begin(asset, id: id); assetTransfer = id; assetDescriptor = asset; reply.offset = 0 }
        case "assetChunk":
            guard assetTransfer == id, let asset = assetDescriptor, let cache, let offset = request.offset, let data = request.data else { throw WidgetSnapshotError.invalid }
            let (next, path) = try cache.accept(id: id, offset: offset, data: data); reply.offset = next
            if let path { loadImage(path, asset: asset); assetTransfer = nil; assetDescriptor = nil; reply.status = "complete"; cache.prune(keeping: Set(view.envelope?.snapshot.hooks.compactMap(\.image) ?? [])) }
            else { reply.status = "continue" }
        default: throw WidgetSnapshotError.invalid
        }
        lastPhoneProgress = now
        fallback?.cancel(); fallback = nil
        if snapshotTransfer != nil || assetTransfer != nil { waitForPhone() }
        publish()
        if reply.status == "complete" || reply.status == "cached" { finishCacheRead() }
        return reply
    }
    /// 加载时仍完整核验内容缓存，界面不会同步解码或访问图片正文。
    private func loadImages() {
        guard let snapshot = view.envelope?.snapshot, let cache else { return }
        let hashes = Set(snapshot.hooks.compactMap(\.image))
        for asset in snapshot.assets where hashes.contains(asset.hash) {
            if let path = try? cache.cached(asset) { loadImage(path, asset: asset) }
        }
    }
    /// 已加载、解码中或已知失败的摘要直接跳过；结果回到owner队列后仅在仍被当前快照引用时发布。
    private func loadImage(_ path: URL, asset: LanDisplaySnapshot.Asset) {
        let hash = asset.hash
        guard view.images[hash] == nil, !decodingImages.contains(hash), !failedImages.contains(hash) else { return }
        decodingImages.insert(hash)
        decoder.async { [weak self] in
            let image = try? WatchAssetCache.image(path, asset: asset)
            self?.queue.async { self?.imageDecoded(image, hash: hash) }
        }
    }
    /// 解码结果回到 owner 队列：只有仍被当前快照引用的图片才发布。
    private func imageDecoded(_ image: LanImageAsset?, hash: String) {
        decodingImages.remove(hash)
        guard !view.summaryOnly, view.envelope?.snapshot.hooks.contains(where: { $0.image == hash }) == true else { return }
        guard let image else { failedImages.insert(hash); return }
        view.images[hash] = image; publish()
    }
    /// 换来源或清空展示时同时放弃失败记录，下次同步可重新尝试。
    private func clearImages() { view.images = [:]; failedImages = [] }
    /// 失败、暂停和新快照只撤销未完成接收器，不删除已经完成的私有缓存。
    private func cancelTransfers() { assembler.cancel(); snapshotTransfer = nil; snapshotHash = nil; snapshotSummaryOnly = false; cache?.cancel(); assetTransfer = nil; assetDescriptor = nil }
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
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) { queue.async { if error != nil { NSLog("配套会话暂不可用。"); self.publish() }; self.applyContext(session.receivedApplicationContext); self.requestSync() } }
    /// 失去手机通道后撤销传输代次，保留结果并请求 HTTP 后备。
    func sessionReachabilityDidChange(_ session: WCSession) { queue.async { if !session.isReachable { self.invalidateDisplay(); self.publish() }; self.requestSync() } }
    /// 手机更新的应用上下文（HTTP 配置、缓存快照），可能在 Watch 后台时送达。
    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        queue.async { self.applyContext(applicationContext) }
    }
    /// 所有系统消息转入唯一串行owner，解析或IO失败回复invalid并清理部分文件。
    func session(_ session: WCSession, didReceiveMessageData data: Data, replyHandler: @escaping (Data) -> Void) {
        queue.async {
            let reply: WatchRPCReply
            do { reply = try self.receive(WatchProtocol.request(data)) }
            catch { NSLog("手机同步消息无效或未能保存。"); self.invalidateDisplay(); self.startHTTP(); self.publish(); reply = WatchRPCReply("invalid") }
            replyHandler((try? WatchProtocol.encode(reply)) ?? Data())
        }
    }
    /// App版本只作公开元信息，不影响稳定安装UUID。
    private var appVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0" }
    /// 单调期限与墙钟显示时间各自独立。
    private var now: UInt64 { DispatchTime.now().uptimeNanoseconds }
    /// 显式忘记/换来源的撤销同时清历史文件；普通离线不会走这里。
    private func clearSnapshotCache() {
        phoneRevision &+= 1; cancelHTTP()
        clearLiveDisplay(); invalidateDisplay()
        if let directory { try? WatchDisplayStore(directory: directory).discard() }
        publish()
    }
    /// 只清当前展示与部分传输，图片磁盘缓存和安装身份不受影响。
    private func clearLiveDisplay() {
        cancelTransfers(); record = nil; view.envelope = nil; clearImages()
        view.summaryOnly = false
    }
    /// 失联后撤销手机接收代次；已有结果仍是上次同步，不再声称实时可通信。
    private func invalidateDisplay() {
        cancelTransfers(); lease.deactivate()
        if active { try? lease.activate(session: UUID().uuidString.lowercased()) }
        else if let backgroundRefreshID { try? lease.activate(session: backgroundRefreshID.uuidString.lowercased()) }
    }
    /// UI仅收不可变投影，主线程由薄模型合并投递；内容未变时直接跳过。
    private func publish() {
        guard view != lastPublished else { return }
        lastPublished = view; changed(view)
    }
    deinit { timer?.cancel(); timeout?.cancel(); fallback?.cancel(); backgroundDeadline?.cancel(); httpTask?.cancel(); cache?.cancel() }
}
