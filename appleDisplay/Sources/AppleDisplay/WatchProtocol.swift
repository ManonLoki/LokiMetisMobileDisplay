import Foundation
import CryptoKit

/// 配套表身份独立于iPhone，信息只通过已配对应用的系统通道传递。
struct WatchDeviceInfo: Codable, Equatable {
    let deviceId: String
    let name: String
    let appVersion: String
    /// 名称可编辑但不能改变UUID，拒绝无界文本和控制字符。
    func validate() throws {
        guard WatchProtocol.validId(deviceId), !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.utf8.count <= 160, !name.unicodeScalars.contains(where: { $0.value < 32 || (127...159).contains($0.value) }),
              !appVersion.isEmpty, appVersion.utf8.count <= 64,
              !appVersion.unicodeScalars.contains(where: { $0.value < 32 || (127...159).contains($0.value) }) else { throw WidgetSnapshotError.invalid }
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
        guard version == 1, WatchProtocol.validId(phoneId), WatchProtocol.validId(sourceId), phoneId != sourceId,
              phoneReceivedAtMs >= 0 else { throw WidgetSnapshotError.invalid }
        try snapshot.validate()
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
    /// 稳定状态不携带系统路径、Hook正文或配对秘密。
    init(_ status: String) { self.status = status }
}

/// 快照采用最新值合并，正在传输的有限作业保留进度；失去引用的图片立即撤销。
enum WatchTransferPolicy {
    /// 已提交清单里的有效图片先补齐，再取单份最新快照，避免连续快照让图片永远无法开始。
    enum Payload { case asset(LanDisplaySnapshot.Asset), snapshot, idle }
    /// 旧快照可完整提交后再补最新快照；图片必须仍被引用且元数据完全相同。
    static func keepInFlight(asset: LanDisplaySnapshot.Asset?, latest: LanDisplaySnapshot) -> Bool {
        guard let asset else { return true }
        return latest.hooks.contains(where: { $0.image == asset.hash }) && latest.assets.contains(asset)
    }
    /// 只挑手机有本地文件、Watch已获授权清单且最新状态仍引用的图片；失败资源等待显式重试。
    static func nextPayload(committed: LanDisplaySnapshot?, latest: LanDisplaySnapshot, snapshotPending: Bool,
                            available: Set<String>, acknowledged: Set<String>, failed: Set<String>) -> Payload {
        if let committed, let asset = committed.assets.first(where: { candidate in
            available.contains(candidate.hash) && !acknowledged.contains(candidate.hash) && !failed.contains(candidate.hash)
                && committed.hooks.contains(where: { $0.image == candidate.hash })
                && keepInFlight(asset: candidate, latest: latest)
        }) { return .asset(asset) }
        return snapshotPending ? .snapshot : .idle
    }
}

/// 配套通道的容量与摘要规则；系统没有固定公开配额，产品仍处理平台发送失败。
enum WatchProtocol {
    static let chunkSize = 16 * 1024
    static let maxRPCBytes = 32 * 1024
    static let maxSnapshotBytes = 96 * 1024
    /// 稳定身份和前台/传输代次统一使用规范非零UUID。
    static func validId(_ id: String) -> Bool { UUID(uuidString: id)?.uuidString.lowercased() == id && id != "00000000-0000-0000-0000-000000000000" }
    /// 内容摘要不接受大小写变体或远端路径。
    static func validHash(_ hash: String) -> Bool { hash.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil }
    /// SHA-256绑定完整传输正文，不把排队或分块ACK当作完整同步。
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    /// 编码后再次限制容量，包装和Base64开销也包含在32KiB RPC上限内。
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let data = try JSONEncoder().encode(value)
        guard data.count <= maxRPCBytes else { throw WidgetSnapshotError.tooLarge }
        return data
    }
    /// 系统回调先做字节上限再解析，不接受未来版本或未知请求操作。
    static func request(_ data: Data) throws -> WatchRPC {
        guard data.count <= maxRPCBytes else { throw WidgetSnapshotError.tooLarge }
        let value = try JSONDecoder().decode(WatchRPC.self, from: data)
        guard value.version == 1, ["probe", "requestSync", "pause", "snapshotBegin", "snapshotChunk", "assetBegin", "assetChunk"].contains(value.op) else { throw WidgetSnapshotError.invalid }
        return value
    }
    /// 回执状态使用有界封闭集合，错误不能被默认为成功。
    static func reply(_ data: Data) throws -> WatchRPCReply {
        guard data.count <= maxRPCBytes else { throw WidgetSnapshotError.tooLarge }
        let value = try JSONDecoder().decode(WatchRPCReply.self, from: data)
        guard ["ready", "accepted", "continue", "complete", "cached", "paused", "unavailable", "invalid"].contains(value.status) else { throw WidgetSnapshotError.invalid }
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
final class WatchSnapshotAssembler {
    private var id: String?
    private var hash = ""
    private var length = 0
    private var bytes = Data()
    /// 新传输替换旧半成品，不替换已经成功提交的展示缓存。
    func begin(id: String, hash: String, length: UInt64) throws {
        guard WatchProtocol.validId(id), WatchProtocol.validHash(hash), (1...UInt64(WatchProtocol.maxSnapshotBytes)).contains(length) else { throw WidgetSnapshotError.invalid }
        self.id = id; self.hash = hash; self.length = Int(length); bytes = Data()
    }
    /// 每块恰好16KiB或最终余量；重复、跳号、空块和错误代次均失败。
    func accept(id: String, offset: UInt64, data: Data) throws -> (UInt64, WatchAssembledSnapshot?) {
        guard id == self.id, offset == UInt64(bytes.count), !data.isEmpty,
              data.count == min(WatchProtocol.chunkSize, length - bytes.count) else { throw WidgetSnapshotError.invalid }
        bytes.append(data)
        if bytes.count < length { return (UInt64(bytes.count), nil) }
        defer { cancel() }
        guard WatchProtocol.hash(bytes) == hash else { throw WidgetSnapshotError.invalid }
        let envelope = try JSONDecoder().decode(WatchSnapshotEnvelope.self, from: bytes)
        try envelope.validate()
        return (UInt64(length), WatchAssembledSnapshot(data: bytes, envelope: envelope, hash: hash))
    }
    /// 退到后台、对端换代或协议失败只丢弃部分传输。
    func cancel() { id = nil; hash = ""; length = 0; bytes = Data() }
}

/// 前台代次与最近实际通信属于本地状态，后台系统回调不能维持“前台可同步”。
struct WatchForegroundLease {
    private(set) var session: String?
    private(set) var lastContact: UInt64?
    /// 每次真正回前台产生新代次，防止后台前的迟到RPC或ACK续租。
    mutating func activate(session: String) throws { guard WatchProtocol.validId(session) else { throw WidgetSnapshotError.invalid }; self.session = session; lastContact = nil }
    /// 离开前台立即撤销，不能依赖bye一定发送成功。
    mutating func deactivate() { session = nil; lastContact = nil }
    /// 接收必须匹配本次前台代次；旧或倒退时钟不能恢复同步资格。
    mutating func received(session: String, now: UInt64) throws {
        guard self.session == session, lastContact.map({ now >= $0 }) ?? true else { throw WidgetSnapshotError.invalid }
        lastContact = now
    }
    /// 在线语义仅为45秒内的应用通信，未收到消息或时钟倒退均不可达。
    func reachable(now: UInt64) -> Bool { guard session != nil, let lastContact, now >= lastContact else { return false }; return now - lastContact < 45_000_000_000 }
}

/// 向桌面报告的事实使用实际ACK序号与单调时间，不从UI日期或手机心跳生成证明。
struct WatchCompanionFacts {
    private var sequence: UInt64 = 0
    private var contact: (sequence: UInt64, time: UInt64)?
    private var sync: (sequence: UInt64, time: UInt64)?
    /// 只有通过当前前台代次校验的回执调用；完整持久化ACK同时确认同步。
    mutating func received(now: UInt64, synchronized: Bool = false) throws {
        guard sequence < 9_007_199_254_740_991, contact.map({ now >= $0.time }) ?? true else { throw WidgetSnapshotError.invalid }
        sequence += 1; contact = (sequence, now)
        if synchronized { sync = contact }
    }
    /// 父连接或系统Watch切换后丢弃正向证明，计数不回退。
    mutating func clear() { contact = nil; sync = nil }
    /// 年龄向上取整，不把旧事件截成刚刚收到；超过七天的历史省略。
    private func observation(_ value: (sequence: UInt64, time: UInt64)?, now: UInt64) -> [String: UInt64]? {
        guard let value, now >= value.time else { return nil }
        let nanos = now - value.time
        let age = nanos / 1_000_000 + (nanos % 1_000_000 == 0 ? 0 : 1)
        guard age <= 604_800_000 else { return nil }
        return ["sequence": value.sequence, "ageMs": age]
    }
    /// 仅输出有界Watch元信息和实际事实；nonce由当前已认证桌面ping提供。
    func report(info: WatchDeviceInfo, reachable: Bool, now: UInt64) throws -> [String: Any] {
        try info.validate()
        let contact = observation(contact, now: now)
        var value: [String: Any] = ["info": ["deviceId": info.deviceId, "name": info.name, "appVersion": info.appVersion],
            "reachable": reachable && contact.map({ $0["ageMs"]! < 45_000 }) == true]
        value["contact"] = contact ?? nil
        if contact != nil { value["sync"] = observation(sync, now: now) }
        return value
    }
    /// 只有实时认证快照外壳可以启用扩展；缓存内容不能开启新上行消息。
    static func hostSupports(_ message: [String: Any]) throws -> Bool {
        try LanHostCapabilities.supports("watchCompanionV1", in: message)
    }
}

/// 扩展能力只从当前已认证快照读取；旧桌面缺省为空，格式混淆失败关闭。
enum LanHostCapabilities {
    /// 同一有界唯一能力表供形态与Watch协商复用，未知能力可安全忽略。
    static func supports(_ capability: String, in message: [String: Any]) throws -> Bool {
        guard let raw = message["capabilities"] else { return false }
        guard let values = raw as? [String], values.count <= 16,
              values.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 64 }), Set(values).count == values.count else { throw WidgetSnapshotError.invalid }
        return values.contains(capability)
    }
}
