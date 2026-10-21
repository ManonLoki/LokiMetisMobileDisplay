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
    }
    let version: Int
    let tokens: WidgetTokens?
    let tokenError: String?
    let hooksAvailable: Bool
    let hooks: [Hook]
    let assets: [Asset]
    let catalogError: String?

    /// 明文已经通过共享会话认证，此处只解析展示协议及宿主容量边界。
    static func decode(_ message: [String: Any]) throws -> Self {
        guard message["type"] as? String == "snapshot", let raw = message["snapshot"] else { throw WidgetSnapshotError.invalid }
        let data = try JSONSerialization.data(withJSONObject: raw)
        guard data.count <= 65536 else { throw WidgetSnapshotError.tooLarge }
        let value = try JSONDecoder().decode(Self.self, from: data)
        try value.validate()
        return value
    }

    /// 网络与私有缓存共用同一展示语义，缓存不能绕过版本、质量和容量检查。
    func validate() throws {
        let value = self
        guard value.version == 1, value.hooks.count <= 12, value.assets.count <= 64,
              Set(value.hooks.map(\.slot)).count == value.hooks.count,
              Set(value.assets.map(\.hash)).count == value.assets.count,
              value.hooks.allSatisfy({ (1...12).contains($0.slot) && $0.content.utf8.count <= 512 }),
              value.assets.allSatisfy({ $0.hash.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil &&
                  ["image/bmp", "image/png", "image/jpeg", "image/webp", "image/gif"].contains($0.mime) && (1...33_554_432).contains($0.length) }) else {
            throw WidgetSnapshotError.invalid
        }
        let summary = WidgetDisplaySnapshot(version: value.version, tokens: value.tokens, tokenError: value.tokenError,
            hooksAvailable: value.hooksAvailable, hooks: value.hooks.map { WidgetHook(agent: $0.agent, slot: $0.slot, behavior: $0.behavior) })
        try summary.validate()
    }
}
