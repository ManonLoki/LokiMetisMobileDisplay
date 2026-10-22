import Foundation
import SharedLogic

/// 配套表身份独立于iPhone，信息只通过已配对应用的系统通道传递。
struct WatchDeviceInfo: Codable, Equatable {
    let deviceId: String
    let name: String
    let appVersion: String
    /// Codable 只提供字段，终端元信息的语义约束由共享协议维护。
    func validate() throws {
        guard WatchProtocolRules.shared.validDeviceInfo(deviceId: deviceId, name: name, appVersion: appVersion)
        else { throw WidgetSnapshotError.invalid }
    }
}

/// Watch只接收已通过桌面会话验证的完整展示，来源手机与桌面身份均明确。
struct WatchSnapshotEnvelope: Codable, Equatable {
    let version: Int
    let phoneId: String
    let sourceId: String
    let phoneReceivedAtMs: Int64
    let snapshot: LanDisplaySnapshot
    /// 历史时间不能用来续前台租约，数值和图文共用完整快照校验。
    func validate() throws {
        guard WatchProtocolRules.shared.validEnvelope(version: Int32(clamping: version), phoneId: phoneId,
            sourceId: sourceId, receivedAtMs: phoneReceivedAtMs,
            cachedImageTimes: snapshot.hooks.flatMap {
                [KotlinLong(value: $0.cachedImageReceivedAtMs ?? 0), KotlinLong(value: $0.cachedImageClearedAtMs ?? 0)]
            }) else { throw WidgetSnapshotError.invalid }
        try snapshot.validate()
    }

    /// 仅映射选择图片所需的元信息，正文、图片字节与文件路径不进入共享策略。
    func imageCacheState(summaryOnly: Bool) -> HookImageCacheState {
        HookImageCacheState(phoneId: phoneId, sourceId: sourceId, receivedAtMs: phoneReceivedAtMs,
            summaryOnly: summaryOnly, hooksAvailable: snapshot.hooksAvailable,
            facts: snapshot.hooks.map(\.imageCacheFact))
    }

    func cachePriority(summaryOnly: Bool) -> Int {
        Int(HookImageCachePolicy.shared.priority(summaryOnly: summaryOnly,
            facts: snapshot.hooks.map(\.imageCacheFact)))
    }

    /// SharedLogic 决定历史复用与清图；Swift 只映射原始 Hook 并组装仍被引用的资源清单。
    func preservingCachedHookImages(from previous: Self?, previousSummaryOnly: Bool = false) throws -> Self {
        try validate()
        guard let previous, (try? previous.validate()) != nil,
              HookImageCachePolicy.shared.mayMergeHistory(incoming: imageCacheState(summaryOnly: true),
                  previous: previous.imageCacheState(summaryOnly: previousSummaryOnly)) else { return self }
        let previousState = previous.imageCacheState(summaryOnly: previousSummaryOnly)
        let oldAssets = Dictionary(uniqueKeysWithValues: previous.snapshot.assets.map { ($0.hash, $0) })
        let currentAssets = Dictionary(uniqueKeysWithValues: snapshot.assets.map { ($0.hash, $0) })
        let availableImageHashes = Set(oldAssets.keys)
        var retainedAssets: [LanDisplaySnapshot.Asset] = []
        var hashes: Set<String> = []
        let hooks = snapshot.hooks.map { hook -> LanDisplaySnapshot.Hook in
            let decision = HookImageCachePolicy.shared.decide(incoming: hook.imageCacheFact,
                previous: previousState, availableImageHashes: availableImageHashes)
            var result = hook
            var asset = hook.image.flatMap { currentAssets[$0] }
            if decision.choice != .keepCurrent {
                let fact = decision.fact
                result = LanDisplaySnapshot.Hook(agent: hook.agent, slot: hook.slot, behavior: hook.behavior,
                    content: "", contentTruncated: false, image: fact.imageHash,
                    cachedImageReceivedAtMs: fact.receivedAtMs >= 0 ? fact.receivedAtMs : nil,
                    cachedImageClearedAtMs: fact.clearedAtMs >= 0 ? fact.clearedAtMs : nil)
                asset = decision.choice == .usePrevious ? fact.imageHash.flatMap { oldAssets[$0] } : nil
            }
            if let asset, hashes.insert(asset.hash).inserted { retainedAssets.append(asset) }
            return result
        }
        let merged = LanDisplaySnapshot(version: snapshot.version, tokens: snapshot.tokens,
            tokenError: snapshot.tokenError, hooksAvailable: snapshot.hooksAvailable, hooks: hooks,
            assets: retainedAssets, catalogError: snapshot.catalogError, providerQuota: snapshot.providerQuota, enabledAgents: snapshot.enabledAgents)
        let value = Self(version: version, phoneId: phoneId, sourceId: sourceId,
            phoneReceivedAtMs: phoneReceivedAtMs, snapshot: merged)
        try value.validate()
        return value
    }
}

/// 可空时间以 -1 跨语言传递；已校验的槽位不会在转换中丢失范围信息。
private extension LanDisplaySnapshot.Hook {
    var imageCacheFact: HookImageFact {
        HookImageFact(slot: Int32(clamping: slot), agent: agent, imageHash: image,
            receivedAtMs: cachedImageReceivedAtMs ?? -1, clearedAtMs: cachedImageClearedAtMs ?? -1,
            hasContent: !content.isEmpty)
    }
}

/// 单次即时RPC；仅使用小块sendMessageData，不建立系统后台文件传输队列。
struct WatchRPC: Codable {
    let version: Int
    let op: String
    var id: String?
    var session: String?
    var info: WatchDeviceInfo?
    var hash: String?
    var length: UInt64?
    var offset: UInt64?
    var data: Data?
    var asset: LanDisplaySnapshot.Asset?
    var configurationRevision: UInt64?
    var configurationHash: String?
    var snapshotSummaryOnly: Bool?
    /// 字段默认为缺省，具体操作在接收owner按阶段检查，不允许缺字段自动补真值。
    init(_ op: String) { version = 1; self.op = op }
}

/// 回执表示已校验/已落盘或明确失败；WC发送成功本身不产生同步证明。
struct WatchRPCReply: Codable {
    var status: String
    var id: String?
    var session: String?
    var info: WatchDeviceInfo?
    var offset: UInt64?
    var snapshotHash: String?
    /// 只读 HTTP 授权通过系统配套通道下发，nil target 表示明确撤销。
    var configuration: WatchHTTPConfiguration?
    /// 已持久化的手机展示缓存；回执放不下时可由有界应用上下文或即时分块传输补送。
    var snapshotCache: Data?
    var snapshotCacheCleared: Bool?
    var snapshotSummaryOnly: Bool?
    /// 稳定状态不携带系统路径、Hook正文或配对秘密。
    init(_ status: String) { self.status = status }
}

/// 原生传输负载枚举保持不变，选择与持续引用资格由共享策略决定。
enum WatchTransferPolicy {
    enum Payload { case asset(LanDisplaySnapshot.Asset), snapshot, idle }
    static func keepInFlight(asset: LanDisplaySnapshot.Asset?, latest: LanDisplaySnapshot) -> Bool {
        AssetTransferRules.shared.keepInFlight(asset: asset?.transferAsset, latest: latest.transferManifest)
    }
    static func nextPayload(committed: LanDisplaySnapshot?, latest: LanDisplaySnapshot, snapshotPending: Bool,
                            available: Set<String>, acknowledged: Set<String>, failed: Set<String>) -> Payload {
        let decision = WatchTransferRules.shared.nextPayload(committed: committed?.transferManifest,
            latest: latest.transferManifest, snapshotPending: snapshotPending, available: available,
            acknowledged: acknowledged, failed: failed)
        if decision.kind == .asset, let committed { return .asset(committed.assets[Int(decision.assetIndex)]) }
        return decision.kind == .snapshot ? .snapshot : .idle
    }
}

/// 配套通道的容量与摘要规则；系统没有固定公开配额，产品仍处理平台发送失败。
enum WatchProtocol {
    static let chunkSize = Int(WatchProtocolRules.shared.CHUNK_SIZE)
    static let maxRPCBytes = Int(WatchProtocolRules.shared.MAX_RPC_BYTES)
    static let maxSnapshotBytes = Int(WatchProtocolRules.shared.MAX_SNAPSHOT_BYTES)
    /// 单个物理 RPC 的逻辑超时；系统回调终态前仍占用槽位。
    static let rpcTimeout = TimeInterval(WatchProtocolRules.shared.RPC_TIMEOUT_SECONDS)
    /// 两端前台心跳：1 秒后首次检查，此后每 15 秒一次；调用方以弱引用传入 tick。
    static func heartbeat(on queue: DispatchQueue, tick: @escaping () -> Void) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 15, leeway: .seconds(1))
        timer.setEventHandler(handler: tick); timer.resume()
        return timer
    }
    /// SHA-256绑定完整传输正文，不把排队或分块ACK当作完整同步。
    static func hash(_ data: Data) -> String { SharedValidation.sha256Hex(data) }
    /// 编码后再次限制容量，包装和Base64开销也包含在32KiB RPC上限内。
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let data = try SharedJSON.encoder.encode(value)
        guard WatchProtocolRules.shared.validRpcByteCount(count: Int32(clamping: data.count)) else { throw WidgetSnapshotError.tooLarge }
        return data
    }
    /// 系统回调先做字节上限再解析，不接受未来版本或未知请求操作。
    static func request(_ data: Data) throws -> WatchRPC {
        guard WatchProtocolRules.shared.validRpcByteCount(count: Int32(clamping: data.count)) else { throw WidgetSnapshotError.tooLarge }
        let value = try SharedJSON.decoder.decode(WatchRPC.self, from: data)
        guard WatchProtocolRules.shared.validRequest(version: Int32(clamping: value.version), operation: value.op) else { throw WidgetSnapshotError.invalid }
        return value
    }
    /// 回执状态使用有界封闭集合，错误不能被默认为成功。
    static func reply(_ data: Data) throws -> WatchRPCReply {
        guard WatchProtocolRules.shared.validRpcByteCount(count: Int32(clamping: data.count)) else { throw WidgetSnapshotError.tooLarge }
        let value = try SharedJSON.decoder.decode(WatchRPCReply.self, from: data)
        guard WatchProtocolRules.shared.validReply(status: value.status) else { throw WidgetSnapshotError.invalid }
        try value.configuration?.validate()
        return value
    }
}

/// 完整传输原始字节与已解析投影绑定，保存时不因JSON重编码顺序改变摘要。
struct WatchAssembledSnapshot {
    let data: Data
    let envelope: WatchSnapshotEnvelope
    let hash: String
}

/// 一次只接收一份完整快照；精确偏移、长度及摘要均通过后才产生可保存投影。
/// 无内部锁，由接收宿主的串行队列独占。
final class WatchSnapshotAssembler {
    private var id: String?
    private var hash = ""
    private var length = 0
    private var bytes = Data()
    /// 新传输替换旧半成品，不替换已经成功提交的展示缓存。
    func begin(id: String, hash: String, length: UInt64) throws {
        guard WatchProtocolRules.shared.validSnapshotBegin(id: id, hash: hash, length: Int64(clamping: length))
        else { throw WidgetSnapshotError.invalid }
        self.id = id; self.hash = hash; self.length = Int(length); bytes = Data()
    }
    /// 每块恰好16KiB或最终余量；重复、跳号、空块和错误代次均失败。
    func accept(id: String, offset: UInt64, data: Data) throws -> (UInt64, WatchAssembledSnapshot?) {
        let decision = WatchProtocolRules.shared.chunk(transferId: self.id, incomingId: id,
            length: Int32(clamping: length), receivedBytes: Int32(clamping: bytes.count),
            offset: Int64(clamping: offset), byteCount: Int32(clamping: data.count))
        guard decision.valid else { throw WidgetSnapshotError.invalid }
        bytes.append(data)
        if !decision.complete { return (UInt64(decision.nextOffset), nil) }
        defer { cancel() }
        guard WatchProtocol.hash(bytes) == hash else { throw WidgetSnapshotError.invalid }
        let envelope = try SharedJSON.decoder.decode(WatchSnapshotEnvelope.self, from: bytes)
        try envelope.validate()
        return (UInt64(length), WatchAssembledSnapshot(data: bytes, envelope: envelope, hash: hash))
    }
    /// 退到后台、对端换代或协议失败只丢弃部分传输。
    func cancel() { id = nil; hash = ""; length = 0; bytes = Data() }
}

/// Swift 的 UInt64 纳秒时钟按高低位搬运，所有时间比较与租约决策在共享层执行。
private func sharedWatchTime(_ value: UInt64) -> WatchMonotonicTime {
    WatchMonotonicTime(highBits: Int32(bitPattern: UInt32(truncatingIfNeeded: value >> 32)),
        lowBits: Int32(bitPattern: UInt32(truncatingIfNeeded: value)))
}
private func unsignedWatchTime(_ value: WatchMonotonicTime) -> UInt64 {
    (UInt64(UInt32(bitPattern: value.highBits)) << 32) | UInt64(UInt32(bitPattern: value.lowBits))
}

/// 不可变 Kotlin 状态保留 struct 的值语义；复制给另一 owner 后不会被后续 ACK 改写。
struct WatchForegroundLease {
    private var sharedState = WatchCommunicationPolicy.shared.inactiveLease()
    var session: String? { sharedState.session }
    var lastContact: UInt64? { sharedState.lastContact.map(unsignedWatchTime) }
    mutating func activate(session: String) throws {
        guard let next = WatchCommunicationPolicy.shared.activateLease(session: session) else { throw WidgetSnapshotError.invalid }
        sharedState = next
    }
    mutating func deactivate() { sharedState = WatchCommunicationPolicy.shared.inactiveLease() }
    mutating func received(session: String, now: UInt64) throws {
        guard let next = WatchCommunicationPolicy.shared.receivedLease(current: sharedState, session: session,
            now: sharedWatchTime(now)) else { throw WidgetSnapshotError.invalid }
        sharedState = next
    }
    func reachable(now: UInt64) -> Bool {
        WatchCommunicationPolicy.shared.reachable(current: sharedState, now: sharedWatchTime(now))
    }
}

/// Swift 只将共享证明映射回既有 JSON 字段；序号、年龄、完整同步与清除规则均在 Kotlin。
struct WatchCompanionFacts {
    private var sharedState = WatchCommunicationPolicy.shared.emptyFacts()
    mutating func received(now: UInt64, synchronized: Bool = false) throws {
        guard let next = WatchCommunicationPolicy.shared.receivedFacts(current: sharedState, now: sharedWatchTime(now),
            synchronized: synchronized) else { throw WidgetSnapshotError.invalid }
        sharedState = next
    }
    mutating func clear() { sharedState = WatchCommunicationPolicy.shared.clearFacts(current: sharedState) }
    func report(info: WatchDeviceInfo, reachable: Bool, now: UInt64) throws -> [String: Any] {
        try info.validate()
        let report = WatchCommunicationPolicy.shared.report(current: sharedState, reachable: reachable, now: sharedWatchTime(now))
        func fields(_ observation: WatchContactObservation) -> [String: UInt64] {
            ["sequence": UInt64(observation.sequence), "ageMs": UInt64(observation.ageMs)]
        }
        var value: [String: Any] = ["info": ["deviceId": info.deviceId, "name": info.name, "appVersion": info.appVersion],
            "reachable": report.reachable]
        value["contact"] = report.contact.map(fields)
        value["sync"] = report.sync.map(fields)
        return value
    }
    static func hostSupports(_ message: [String: Any]) throws -> Bool {
        try LanHostCapabilities.supports(TerminalCapabilities.shared.WATCH_COMPANION, in: message)
    }
}

/// 扩展能力只从当前已认证快照读取；旧桌面缺省为空，格式混淆失败关闭。
enum LanHostCapabilities {
    /// 同一有界唯一能力表供形态与Watch协商复用，未知能力可安全忽略。
    static func supports(_ capability: String, in message: [String: Any]) throws -> Bool {
        let values: [String]?
        if let raw = message["capabilities"] { values = raw as? [String] }
        else { values = [] }
        guard TerminalCapabilities.shared.isValid(values: values) else { throw WidgetSnapshotError.invalid }
        return TerminalCapabilities.shared.supports(values: values, capability: capability)
    }
}
