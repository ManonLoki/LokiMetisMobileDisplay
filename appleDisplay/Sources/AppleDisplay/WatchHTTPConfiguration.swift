import Foundation

/// 通过系统配套通道下发的独立只读 HTTP 配置；target 为 nil 明确撤销先前授权。
struct WatchHTTPConfiguration: Codable, Equatable {
    static let maxBytes = 4096
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
        guard let previous, previous.phoneId == phoneId else { return true }
        return revision > previous.revision || self == previous
    }

    /// 凭据仍绑定授予它的手机身份，Watch 不得把其他手机的目标拼接到本配置。
    func validate() throws {
        guard version == 1, SharedValidation.validId(phoneId) else { throw WidgetSnapshotError.invalid }
        if let target {
            try target.validate()
            guard target.deviceId == phoneId else { throw WidgetSnapshotError.invalid }
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

extension WatchSnapshotEnvelope {
    /// HTTP 仅提供摘要：保留桌面精确数值、质量及槽位四态，旧正文和图片不混入新结果。
    static func fromHTTP(_ summary: WidgetSnapshot, configuration: WatchHTTPConfiguration) throws -> Self {
        try configuration.validate()
        try summary.validate()
        guard let target = configuration.target, summary.sourceId == target.sourceId else {
            throw WidgetSnapshotError.invalid
        }
        let snapshot = LanDisplaySnapshot(version: summary.snapshot.version, tokens: summary.snapshot.tokens,
            tokenError: summary.snapshot.tokenError, hooksAvailable: summary.snapshot.hooksAvailable,
            hooks: summary.snapshot.hooks.map {
                LanDisplaySnapshot.Hook(agent: $0.agent, slot: $0.slot, behavior: $0.behavior,
                    content: "", contentTruncated: false, image: nil)
            }, assets: [], catalogError: nil, providerQuota: summary.snapshot.providerQuota)
        let value = Self(version: 1, phoneId: configuration.phoneId, sourceId: summary.sourceId,
            phoneReceivedAtMs: summary.receivedAtMs, snapshot: snapshot)
        try value.validate()
        return value
    }
}
