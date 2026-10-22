import Foundation
import SharedLogic

/// 通过系统配套通道下发的独立只读 HTTP 配置；target 为 nil 明确撤销先前授权。
struct WatchHTTPConfiguration: Codable, Equatable {
    static let maxBytes = Int(WatchConfigurationPolicy.shared.MAX_BYTES)
    let version: Int
    let phoneId: String
    let target: WidgetRefreshTarget?
    let revision: UInt64

    init(version: Int = 1, phoneId: String, target: WidgetRefreshTarget?, revision: UInt64 = 0) throws {
        self.version = version
        self.phoneId = phoneId
        self.target = target
        self.revision = revision
        try validate()
    }

    /// 同一手机只有更高修订号可改变授权；完全相等的重送可作无操作接收。
    /// 新手机身份由当前系统配套通道授权，不与旧手机的本机计数器比较。
    func supersedes(_ previous: Self?) -> Bool {
        acceptance(comparedTo: previous) != .reject
    }

    /// Codable 只映射字段；修订接纳、重复配置和同号冲突统一由共享层判定。
    func acceptance(comparedTo previous: Self?) -> WatchConfigurationAcceptance {
        guard let incoming = sharedConfiguration else { return .reject }
        if let previous, previous.sharedConfiguration == nil { return .reject }
        return WatchConfigurationPolicy.shared.acceptance(incoming: incoming, previous: previous?.sharedConfiguration)
    }

    static func stableTarget(_ proposed: WidgetRefreshTarget?, previous: Self?) -> WidgetRefreshTarget? {
        if WatchConfigurationPolicy.shared.reusePreviousTarget(previous: previous?.target?.watchConfigurationTarget,
                                                              incoming: proposed?.watchConfigurationTarget) {
            return previous?.target
        }
        return proposed
    }

    static func needsPublication(previous: Self?, target: WidgetRefreshTarget?, forceRevision: Bool) -> Bool {
        let incomingTarget = target?.watchConfigurationTarget
        guard target == nil || incomingTarget != nil else { return true }
        return WatchConfigurationPolicy.shared.needsPublication(previous: previous?.sharedConfiguration,
            incomingTarget: incomingTarget, forceRevision: forceRevision)
    }

    func keepsSnapshot(phoneId: String?, sourceId: String?) -> Bool {
        guard let configuration = sharedConfiguration else { return false }
        return WatchConfigurationPolicy.shared.keepSnapshot(configuration: configuration,
            cachedPhoneId: phoneId, cachedSourceId: sourceId)
    }

    func keepsTransfer(previous: Self?, hasTransfer: Bool) -> Bool {
        guard let incoming = sharedConfiguration else { return false }
        return WatchConfigurationPolicy.shared.keepTransfer(incoming: incoming,
            previous: previous?.sharedConfiguration, hasTransfer: hasTransfer)
    }

    func acceptsHTTPSource(_ sourceId: String) -> Bool {
        guard let configuration = sharedConfiguration else { return false }
        return WatchConfigurationPolicy.shared.acceptsHTTPSource(configuration: configuration, sourceId: sourceId)
    }

    private var sharedConfiguration: WatchConfigurationState? {
        guard let version = Int32(exactly: version) else { return nil }
        let projectedTarget = target?.watchConfigurationTarget
        guard target == nil || projectedTarget != nil else { return nil }
        return WatchConfigurationState(version: version, phoneId: phoneId, revision: String(revision), target: projectedTarget)
    }

    /// 凭据仍绑定授予它的手机身份，Watch 不得把其他手机的目标拼接到本配置。
    func validate() throws {
        try target?.validate()
        guard let configuration = sharedConfiguration, WatchConfigurationPolicy.shared.valid(configuration: configuration) else {
            throw WidgetSnapshotError.invalid
        }
        guard try SharedJSON.encoder.encode(self).count <= Self.maxBytes else { throw WidgetSnapshotError.tooLarge }
    }

    /// 下发和私有保存共用容量边界；不把未经校验的解码结果再次发送。
    func encoded() throws -> Data {
        try validate()
        return try SharedJSON.sortedEncoder.encode(self)
    }

    /// 原始输入先限长，避免无关字段或空白绕过规范编码后的容量检查。
    static func decode(_ data: Data) throws -> Self {
        guard data.count <= maxBytes else { throw WidgetSnapshotError.tooLarge }
        return try SharedJSON.decoder.decode(Self.self, from: data)
    }

    private enum CodingKeys: String, CodingKey { case version, phoneId, target, revision }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        phoneId = try values.decode(String.self, forKey: .phoneId)
        revision = try values.decode(UInt64.self, forKey: .revision)
        // 缺字段属于不完整消息，只有明确的 null 才撤销旧配置。
        guard values.contains(.target) else { throw WidgetSnapshotError.invalid }
        target = try values.decodeIfPresent(WidgetRefreshTarget.self, forKey: .target)
        try validate()
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(version, forKey: .version)
        try values.encode(phoneId, forKey: .phoneId)
        try values.encode(revision, forKey: .revision)
        if let target { try values.encode(target, forKey: .target) }
        else { try values.encodeNil(forKey: .target) }
    }
}

private extension WidgetRefreshTarget {
    var watchConfigurationTarget: WatchConfigurationTarget? {
        guard let version = Int32(exactly: version), let port = Int32(exactly: port) else { return nil }
        return WatchConfigurationTarget(sourceId: sourceId, deviceId: deviceId, generation: generation,
            connection: RefreshConnection(version: version, sourceId: sourceId, deviceId: deviceId,
                host: host, port: port, key: key))
    }
}

extension WatchSnapshotEnvelope {
    /// HTTP 仅提供摘要：保留桌面精确数值、质量及槽位四态，旧正文和图片不混入新结果。
    static func fromHTTP(_ summary: WidgetSnapshot, configuration: WatchHTTPConfiguration) throws -> Self {
        try configuration.validate()
        try summary.validate()
        guard configuration.acceptsHTTPSource(summary.sourceId) else {
            throw WidgetSnapshotError.invalid
        }
        let snapshot = LanDisplaySnapshot(version: summary.snapshot.version, tokens: summary.snapshot.tokens,
            tokenError: summary.snapshot.tokenError, hooksAvailable: summary.snapshot.hooksAvailable,
            hooks: summary.snapshot.hooks.map {
                LanDisplaySnapshot.Hook(agent: $0.agent, slot: $0.slot, behavior: $0.behavior,
                    content: "", contentTruncated: false, image: nil)
            }, assets: [], catalogError: nil, providerQuota: summary.snapshot.providerQuota, enabledAgents: summary.snapshot.enabledAgents)
        let value = Self(version: 1, phoneId: configuration.phoneId, sourceId: summary.sourceId,
            phoneReceivedAtMs: summary.receivedAtMs, snapshot: snapshot)
        try value.validate()
        return value
    }
}
