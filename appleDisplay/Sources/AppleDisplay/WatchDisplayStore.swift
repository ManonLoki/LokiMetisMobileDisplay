import Foundation

/// Watch当前前台会话的内存快照包括实际接收时刻与原传输摘要，不含桌面配对秘密。
struct WatchDisplayRecord: Codable, Equatable {
    let schemaVersion: Int
    let envelopeData: Data
    let snapshotHash: String
    let receivedAtMs: Int64
    /// 保存来源和旧时刻是历史事实，不能让缓存建立前台可达状态。
    @discardableResult
    func validate() throws -> WatchSnapshotEnvelope {
        guard schemaVersion == 1, SharedValidation.validHash(snapshotHash), receivedAtMs >= 0,
              envelopeData.count <= WatchProtocol.maxSnapshotBytes, WatchProtocol.hash(envelopeData) == snapshotHash else { throw WidgetSnapshotError.invalid }
        let envelope = try SharedJSON.decoder.decode(WatchSnapshotEnvelope.self, from: envelopeData)
        try envelope.validate(); return envelope
    }
}

/// 仅清理旧Watch快照；新快照验证后只保留于当前前台会话内存。
struct WatchDisplayStore {
    let directory: URL
    /// 精确删除旧展示文件，不删除Watch身份和已校验图片。
    func discardLegacy() throws {
        try SharedFiles.removeIfPresent(directory.appendingPathComponent("watch-display-v1.json"))
    }
}
