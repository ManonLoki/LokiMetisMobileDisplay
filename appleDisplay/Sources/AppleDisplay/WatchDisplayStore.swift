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
        guard schemaVersion == 1, WatchProtocol.validHash(snapshotHash), receivedAtMs >= 0,
              envelopeData.count <= WatchProtocol.maxSnapshotBytes, WatchProtocol.hash(envelopeData) == snapshotHash else { throw WidgetSnapshotError.invalid }
        let envelope = try JSONDecoder().decode(WatchSnapshotEnvelope.self, from: envelopeData)
        try envelope.validate(); return envelope
    }
}

/// 仅清理旧Watch快照；新快照验证后只保留于当前前台会话内存。
struct WatchDisplayStore {
    let directory: URL
    /// 精确删除旧展示文件，不删除Watch身份和已校验图片。
    func discardLegacy() throws {
        let path = directory.appendingPathComponent("watch-display-v1.json")
        let manager = FileManager.default
        do {
            let attributes = try manager.attributesOfItem(atPath: path.path)
            guard attributes[.type] as? FileAttributeType != .typeDirectory else { throw WidgetSnapshotError.invalid }
            try manager.removeItem(at: path)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) {}
    }
}
