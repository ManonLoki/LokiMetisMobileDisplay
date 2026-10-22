import Foundation

/// 缓存保留真实数据时间与来源，恢复文件本身不能产生手机在线或新同步证明。
struct WatchDisplayRecord: Codable, Equatable {
    let schemaVersion: Int
    let envelopeData: Data
    let snapshotHash: String
    let receivedAtMs: Int64
    let summaryOnly: Bool

    /// 文件格式版本固定为 2；版本不符的文件按损坏处理并等待重新同步。
    init(envelopeData: Data, snapshotHash: String, receivedAtMs: Int64, summaryOnly: Bool = false) {
        schemaVersion = 2; self.envelopeData = envelopeData
        self.snapshotHash = snapshotHash; self.receivedAtMs = receivedAtMs; self.summaryOnly = summaryOnly
    }

    @discardableResult
    func validate() throws -> WatchSnapshotEnvelope {
        guard schemaVersion == 2, SharedValidation.validHash(snapshotHash), receivedAtMs >= 0,
              envelopeData.count <= WatchProtocol.maxSnapshotBytes, WatchProtocol.hash(envelopeData) == snapshotHash else { throw WidgetSnapshotError.invalid }
        let envelope = try SharedJSON.decoder.decode(WatchSnapshotEnvelope.self, from: envelopeData)
        try envelope.validate()
        if summaryOnly {
            guard envelope.snapshot.assets.isEmpty,
                  envelope.snapshot.hooks.allSatisfy({ $0.image == nil && $0.content.isEmpty }) else { throw WidgetSnapshotError.invalid }
        }
        return envelope
    }

    /// 同来源迟到的摘要不能覆盖新数据，同一时刻优先保留完整图文。
    func supersedes(_ previous: Self?) throws -> Bool {
        let incoming = try validate()
        guard let previous else { return true }
        let old = try previous.validate()
        guard incoming.phoneId == old.phoneId, incoming.sourceId == old.sourceId else { return true }
        if incoming.phoneReceivedAtMs != old.phoneReceivedAtMs { return incoming.phoneReceivedAtMs > old.phoneReceivedAtMs }
        let incomingPriority = incoming.cachePriority(summaryOnly: summaryOnly)
        let previousPriority = old.cachePriority(summaryOnly: previous.summaryOnly)
        if incomingPriority == 1, previousPriority == 1 {
            let incomingHooks = Dictionary(uniqueKeysWithValues: incoming.snapshot.hooks.map { ($0.slot, $0) })
            for oldHook in old.snapshot.hooks {
                guard let oldTime = oldHook.cachedImageReceivedAtMs ?? oldHook.cachedImageClearedAtMs else { continue }
                guard let hook = incomingHooks[oldHook.slot], hook.agent == oldHook.agent,
                      let incomingTime = hook.cachedImageReceivedAtMs ?? hook.cachedImageClearedAtMs,
                      incomingTime >= oldTime else { return false }
                if incomingTime == oldTime, oldHook.cachedImageClearedAtMs != nil, hook.image != nil { return false }
            }
        }
        return incomingPriority >= previousPriority
    }

    /// HTTP摘要只有以相同类型请求时才可命中，不能作为完整快照ACK。
    func matches(hash: String, summaryOnly: Bool) -> Bool {
        self.snapshotHash == hash && self.summaryOnly == summaryOnly && (try? validate()) != nil
    }
}

/// Watch私有原子缓存，允许离线、Always On、进程重启后立即显示上次结果。
struct WatchDisplayStore {
    let directory: URL
    private var file: URL { directory.appendingPathComponent("watch-display-v2.json") }
    private let maxBytes = WatchProtocol.maxSnapshotBytes * 2

    /// 冷启动读取上次展示；文件不存在返回 nil，格式或摘要不符则抛错。
    func load() throws -> WatchDisplayRecord? {
        do {
            try checkFile()
            let record = try SharedJSON.decoder.decode(WatchDisplayRecord.self, from: Data(contentsOf: file))
            try record.validate(); return record
        } catch where SharedFiles.isMissing(error) { return nil }
    }

    /// 只有验证和原子写入完成后才能回复完整提交；损坏文件不作为缓存命中。
    func save(_ record: WatchDisplayRecord) throws {
        try record.validate()
        let data = try SharedJSON.encoder.encode(record)
        guard data.count <= maxBytes else { throw WidgetSnapshotError.tooLarge }
        if FileManager.default.fileExists(atPath: file.path) { try checkFile() }
        var options: Data.WritingOptions = [.atomic]
        #if os(iOS) || os(watchOS)
        options.insert(.completeFileProtectionUntilFirstUserAuthentication)
        #endif
        try data.write(to: file, options: options)
        guard try Data(contentsOf: file) == data else { throw WidgetSnapshotError.unavailable }
    }

    /// 明确换来源或撤销时删除展示缓存；Watch 身份与图片缓存不受影响。
    func discard() throws { try SharedFiles.removeIfPresent(file) }

    private func checkFile() throws {
        let values = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
        guard values.isSymbolicLink != true, values.isRegularFile == true, let size = values.fileSize,
              (1...maxBytes).contains(size) else { throw WidgetSnapshotError.invalid }
    }
}

/// 前台与系统后台调度申请共用5分钟；watchOS可依据预算延后后台执行。
enum WatchRefreshPolicy {
    static let interval: TimeInterval = 5 * 60
    static let backgroundBudget: TimeInterval = 12
    /// 未来时间可能来自两端时钟偏差，应重新取数，不能永久阻止HTTP后备。
    static func shouldRefresh(receivedAtMs: Int64?, nowMs: Int64) -> Bool {
        guard let receivedAtMs, receivedAtMs >= 0, nowMs >= 0, receivedAtMs <= nowMs else { return true }
        return nowMs - receivedAtMs >= Int64(interval * 1000)
    }
}
