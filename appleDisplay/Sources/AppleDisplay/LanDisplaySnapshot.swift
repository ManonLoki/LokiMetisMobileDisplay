import Foundation

/// 手机展示与缓存调度共用的完整展示投影，不重新计算桌面Token或Hook状态机。
struct LanDisplaySnapshot: Codable, Equatable {
    /// 图片元信息只接受内容摘要，不允许远端文件路径。
    struct Asset: Codable, Equatable {
        let hash: String
        let mime: String
        let length: UInt64
        /// 桥以同一元信息验证缓存与分块，JSON不进行浮点转换。
        var json: [String: Any] { ["hash": hash, "mime": mime, "length": length] }
    }
    /// 最终槽位内容保持桌面给出的四态与显式截断标记。
    struct Hook: Codable, Equatable {
        let agent: String
        let slot: Int
        let behavior: WidgetHook.Behavior
        let content: String
        let contentTruncated: Bool
        let image: String?
        /// HTTP 只更新状态时，沿用图片的原始接收时间，不冒充刚下载的新图片。
        var cachedImageReceivedAtMs: Int64? = nil
        /// 清图事实也保留观测时间，防止迟到的旧图片在下一次 HTTP 合并时复活。
        var cachedImageClearedAtMs: Int64? = nil
    }
    let version: Int
    let tokens: WidgetTokens?
    let tokenError: String?
    let hooksAvailable: Bool
    let hooks: [Hook]
    let assets: [Asset]
    let catalogError: String?
    var providerQuota: ProviderQuotaSnapshot? = nil
    /// nil 为旧桌面未声明；空数组表示明确停用所有 Agent。
    var enabledAgents: [String]? = nil
    var displayTokens: WidgetTokens? { tokens?.forDisplay(enabledAgents: enabledAgents) }
    var displayProviderQuota: ProviderQuotaSnapshot? { providerQuota?.forDisplay(enabledAgents: enabledAgents) }
    var displayUsageRows: [WidgetUsageRow] { WidgetUsageRow.project(tokens: tokens, quota: providerQuota, enabledAgents: enabledAgents) }

    /// 明文已经通过共享会话认证，此处只解析展示协议及宿主容量边界。
    static func decode(_ message: [String: Any]) throws -> Self {
        guard message["type"] as? String == "snapshot", let raw = message["snapshot"] else { throw WidgetSnapshotError.invalid }
        let data = try JSONSerialization.data(withJSONObject: raw)
        guard data.count <= 65536 else { throw WidgetSnapshotError.tooLarge }
        let value = try SharedJSON.decoder.decode(Self.self, from: data)
        try value.validate()
        return value
    }

    /// 网络与私有缓存共用同一展示语义，缓存不能绕过版本、质量和容量检查。
    func validate() throws {
        let value = self
        guard value.version == 1, value.hooks.count <= 12, value.assets.count <= 64,
              Set(value.hooks.map(\.slot)).count == value.hooks.count,
              Set(value.assets.map(\.hash)).count == value.assets.count,
              value.hooks.allSatisfy({ (1...12).contains($0.slot) && $0.content.utf8.count <= 512 &&
                  ($0.cachedImageReceivedAtMs.map { $0 >= 0 } ?? true) &&
                  ($0.cachedImageReceivedAtMs == nil || $0.image != nil) &&
                  ($0.cachedImageClearedAtMs.map { $0 >= 0 } ?? true) &&
                  ($0.cachedImageClearedAtMs == nil || ($0.image == nil && $0.cachedImageReceivedAtMs == nil)) }),
              value.assets.allSatisfy(\.isValid) else {
            throw WidgetSnapshotError.invalid
        }
        let summary = WidgetDisplaySnapshot(version: value.version, tokens: value.tokens, tokenError: value.tokenError,
            hooksAvailable: value.hooksAvailable, hooks: value.hooks.map { WidgetHook(agent: $0.agent, slot: $0.slot, behavior: $0.behavior) }, providerQuota: value.providerQuota, enabledAgents: value.enabledAgents)
        try summary.validate()
    }
}

/// 图片元信息与格式魔数在网络、手机缓存和 Watch 缓存间共用同一边界。
extension LanDisplaySnapshot.Asset {
    static let supportedMimes: Set<String> = ["image/bmp", "image/png", "image/jpeg", "image/webp", "image/gif"]
    /// 单张编码正文上限 32MiB。
    static let maxLength: UInt64 = 33_554_432
    /// 摘要、公开 MIME 与长度都在协议边界内。
    var isValid: Bool { SharedValidation.validHash(hash) && Self.supportedMimes.contains(mime) && (1...Self.maxLength).contains(length) }
    /// 摘要之外再核对公开 MIME 与实际文件头，防止格式混淆。
    static func validMagic(_ bytes: Data, mime: String) -> Bool {
        switch mime {
        case "image/bmp": return bytes.starts(with: [0x42, 0x4d])
        case "image/png": return bytes.starts(with: [137, 80, 78, 71, 13, 10, 26, 10])
        case "image/jpeg": return bytes.starts(with: [255, 216, 255])
        case "image/gif": return bytes.starts(with: Array("GIF87a".utf8)) || bytes.starts(with: Array("GIF89a".utf8))
        case "image/webp":
            return bytes.count >= 12 && bytes.starts(with: Array("RIFF".utf8))
                && bytes[bytes.startIndex + 8 ..< bytes.startIndex + 12].elementsEqual("WEBP".utf8)
        default: return false
        }
    }
}
