import XCTest
@testable import AppleDisplay

/// 配套传输只以完整校验和真实私有提交作为成功，隔离测试不替代WC实际互通。
final class WatchTransferTests: XCTestCase {
    private let phone = "12345678-1234-4abc-8def-123456789abc"
    private let desktop = "22345678-1234-4abc-8def-123456789abc"
    private let transfer = "32345678-1234-4abc-8def-123456789abc"
    private let foreground = "42345678-1234-4abc-8def-123456789abc"
    /// 合法完整投影可跨多个16KiB块，测试不注入用户设备或真实缓存。
    private func envelopeData(large: Bool = false) throws -> Data {
        let assets = (1...(large ? 64 : 1)).map { LanDisplaySnapshot.Asset(hash: String(format: "%064x", $0), mime: "image/png", length: 1) }
        let hooks = (1...(large ? 12 : 1)).map { LanDisplaySnapshot.Hook(agent: "codex", slot: $0, behavior: .running,
            content: large ? String(repeating: "\\", count: 512) : "内容", contentTruncated: false, image: assets[$0-1].hash) }
        let snapshot = LanDisplaySnapshot(version: 1, tokens: nil, tokenError: nil, hooksAvailable: true, hooks: hooks, assets: assets, catalogError: nil)
        return try JSONEncoder().encode(WatchSnapshotEnvelope(version: 1, phoneId: phone, sourceId: desktop, phoneReceivedAtMs: 1, snapshot: snapshot))
    }
    /// 多块完整后才产生可保存投影，原始传输字节不会因重编码改变哈希。
    func test_snapshot_blocks_produce_exact_bytes_only_after_final_hash() throws {
        let data = try envelopeData(large: true); XCTAssertGreaterThan(data.count, WatchProtocol.chunkSize)
        let receiver = WatchSnapshotAssembler(); try receiver.begin(id: transfer, hash: WatchProtocol.hash(data), length: UInt64(data.count))
        var offset = 0; var value: WatchAssembledSnapshot?
        while offset < data.count {
            let end = min(data.count, offset + WatchProtocol.chunkSize)
            let result = try receiver.accept(id: transfer, offset: UInt64(offset), data: data.subdata(in: offset..<end))
            XCTAssertEqual(result.0, UInt64(end)); if end < data.count { XCTAssertNil(result.1) }
            value = result.1; offset = end
        }
        XCTAssertEqual(value?.data, data); XCTAssertEqual(value?.hash, WatchProtocol.hash(data)); XCTAssertEqual(value?.envelope.phoneId, phone)
    }
    /// 重复块和旧传输代次不能进入新快照，最终摘要篡改也无法得到成功投影。
    func test_snapshot_rejects_old_generation_offsets_and_corrupt_hash() throws {
        let data = try envelopeData(); let receiver = WatchSnapshotAssembler()
        try receiver.begin(id: transfer, hash: String(repeating: "0", count: 64), length: UInt64(data.count))
        XCTAssertThrowsError(try receiver.accept(id: transfer, offset: 1, data: data))
        XCTAssertThrowsError(try receiver.accept(id: foreground, offset: 0, data: data))
        XCTAssertThrowsError(try receiver.accept(id: transfer, offset: 0, data: data))
        XCTAssertThrowsError(try receiver.begin(id: transfer, hash: WatchProtocol.hash(data), length: UInt64(WatchProtocol.maxSnapshotBytes + 1)))
    }
    /// 退出前台与新前台代次都撤销旧请求资格，45秒边界不能复活。
    func test_foreground_generation_and_timeout_are_independent_of_phone_online() throws {
        var lease = WatchForegroundLease(); try lease.activate(session: foreground)
        XCTAssertFalse(lease.reachable(now: 1)); try lease.received(session: foreground, now: 1)
        XCTAssertTrue(lease.reachable(now: 45_000_000_000)); XCTAssertFalse(lease.reachable(now: 45_000_000_001))
        lease.deactivate(); XCTAssertThrowsError(try lease.received(session: foreground, now: 50_000_000_000))
        try lease.activate(session: transfer); XCTAssertThrowsError(try lease.received(session: foreground, now: 50_000_000_000))
    }
    /// 缓存记录仍校验原始摘要，篡改不能进入本机展示。
    func test_cached_record_rejects_tampering() throws {
        let data = try envelopeData()
        let good = WatchDisplayRecord(envelopeData: data, snapshotHash: WatchProtocol.hash(data), receivedAtMs: 2)
        XCTAssertNoThrow(try good.validate())
        let changed = Data(String(data: data, encoding: .utf8)!.replacingOccurrences(of: "内容", with: "变更").utf8)
        let bad = WatchDisplayRecord(envelopeData: changed, snapshotHash: good.snapshotHash, receivedAtMs: 3)
        XCTAssertThrowsError(try bad.validate())
    }
    /// 冷启动恢复原始正文、真实来源时间和摘要。
    func test_watch_cache_survives_restart() throws {
        let directory = try temporaryFolder()
        let data = try envelopeData()
        let record = WatchDisplayRecord(envelopeData: data, snapshotHash: WatchProtocol.hash(data), receivedAtMs: 50)
        try WatchDisplayStore(directory: directory).save(record)
        let reopened = WatchDisplayStore(directory: directory)
        XCTAssertEqual(try reopened.load(), record)
        XCTAssertEqual(try reopened.load()?.validate().phoneReceivedAtMs, 1)
        try reopened.discard(); XCTAssertNil(try reopened.load())
    }

    /// 迟到完整手机数据不能覆盖更新HTTP摘要；相同时刻完整数据优先。
    func test_watch_cache_rejects_older_data_and_preserves_full_on_equal_timestamp() throws {
        let data = try envelopeData()
        let full = WatchDisplayRecord(envelopeData: data, snapshotHash: WatchProtocol.hash(data), receivedAtMs: 2)
        let envelope = try full.validate()
        let summary = LanDisplaySnapshot(version: 1, tokens: nil, tokenError: nil,
            hooksAvailable: true, hooks: [], assets: [], catalogError: nil)
        func summaryRecord(time: Int64) throws -> WatchDisplayRecord {
            let value = WatchSnapshotEnvelope(version: 1, phoneId: phone, sourceId: desktop,
                phoneReceivedAtMs: time, snapshot: summary)
            let data = try SharedJSON.sortedEncoder.encode(value)
            return WatchDisplayRecord(envelopeData: data, snapshotHash: WatchProtocol.hash(data),
                receivedAtMs: 99, summaryOnly: true)
        }
        XCTAssertFalse(try summaryRecord(time: envelope.phoneReceivedAtMs).supersedes(full))
        XCTAssertTrue(try full.supersedes(summaryRecord(time: envelope.phoneReceivedAtMs)))
        XCTAssertFalse(try full.supersedes(summaryRecord(time: envelope.phoneReceivedAtMs + 1)))
        XCTAssertTrue(try summaryRecord(time: envelope.phoneReceivedAtMs + 1).supersedes(full))
    }

    /// 无效文件与链接不作为恢复缓存，也不会覆盖链接指向的外部文件。
    func test_watch_cache_rejects_corruption_and_symlink() throws {
        let directory = try temporaryFolder(), store = WatchDisplayStore(directory: try temporaryFolder())
        let data = try envelopeData()
        let record = WatchDisplayRecord(envelopeData: data, snapshotHash: WatchProtocol.hash(data), receivedAtMs: 2)
        try store.save(record)
        let cacheFile = store.directory.appendingPathComponent("watch-display-v2.json")
        try Data("broken".utf8).write(to: cacheFile)
        XCTAssertThrowsError(try store.load())
        try FileManager.default.removeItem(at: cacheFile)
        let external = directory.appendingPathComponent("untouched.json")
        try Data("original".utf8).write(to: external)
        try FileManager.default.createSymbolicLink(at: cacheFile, withDestinationURL: external)
        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.save(record))
        XCTAssertEqual(try Data(contentsOf: external), Data("original".utf8))
    }

    /// HTTP摘要不能伪装完整图文缓存，刷新申请保持5分钟且后台有截止。
    func test_watch_cache_summary_validation_and_refresh_budget() throws {
        let data = try envelopeData()
        let invalid = WatchDisplayRecord(envelopeData: data, snapshotHash: WatchProtocol.hash(data), receivedAtMs: 2, summaryOnly: true)
        XCTAssertThrowsError(try invalid.validate())
        XCTAssertEqual(WatchRefreshPolicy.interval, 300)
        XCTAssertLessThan(WatchRefreshPolicy.backgroundBudget, 15)
        let full = WatchDisplayRecord(envelopeData: data, snapshotHash: WatchProtocol.hash(data), receivedAtMs: 2)
        XCTAssertTrue(full.matches(hash: full.snapshotHash, summaryOnly: false))
        XCTAssertFalse(full.matches(hash: full.snapshotHash, summaryOnly: true))
        XCTAssertFalse(invalid.matches(hash: invalid.snapshotHash, summaryOnly: true))
    }

    /// 新缓存暂不HTTP，恰好5分钟以及缺失/未来/异常时间都应重新读取。
    func test_watch_refresh_age_boundaries_and_extreme_clocks() {
        XCTAssertFalse(WatchRefreshPolicy.shouldRefresh(receivedAtMs: 100, nowMs: 100))
        XCTAssertFalse(WatchRefreshPolicy.shouldRefresh(receivedAtMs: 100, nowMs: 300_099))
        XCTAssertTrue(WatchRefreshPolicy.shouldRefresh(receivedAtMs: 100, nowMs: 300_100))
        XCTAssertTrue(WatchRefreshPolicy.shouldRefresh(receivedAtMs: 0, nowMs: Int64.max))
        XCTAssertTrue(WatchRefreshPolicy.shouldRefresh(receivedAtMs: Int64.max, nowMs: 100))
        XCTAssertTrue(WatchRefreshPolicy.shouldRefresh(receivedAtMs: 0, nowMs: Int64.min))
        XCTAssertTrue(WatchRefreshPolicy.shouldRefresh(receivedAtMs: -1, nowMs: 0))
        XCTAssertTrue(WatchRefreshPolicy.shouldRefresh(receivedAtMs: nil, nowMs: 0))
    }

    /// 图片ACK成功后可按相同摘要复用，正文损坏不能命中。
    func test_asset_commit_cache_hit_and_corruption_detection() throws {
        let root = try temporaryFolder(); let cache = try WatchAssetCache(directory: root)
        let data = Data(base64Encoded: "R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7")!
        let asset = LanDisplaySnapshot.Asset(hash: WatchProtocol.hash(data), mime: "image/gif", length: UInt64(data.count))
        XCTAssertNil(try cache.cached(asset)); try cache.begin(asset, id: transfer)
        let result = try cache.accept(id: transfer, offset: 0, data: data)
        XCTAssertEqual(result.0, UInt64(data.count)); XCTAssertNotNil(result.1); XCTAssertNotNil(try cache.cached(asset))
        try Data(repeating: 0, count: data.count).write(to: root.appendingPathComponent(asset.hash))
        XCTAssertNil(try cache.cached(asset))
    }
    /// 错偏移失败和取消不能把部分文件当缓存，也不能留下本次临时文件。
    func test_asset_cancel_discards_partial_without_overwriting_cached_body() throws {
        let root = try temporaryFolder(); let cache = try WatchAssetCache(directory: root)
        let data = Data(base64Encoded: "R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7")!
        let asset = LanDisplaySnapshot.Asset(hash: WatchProtocol.hash(data), mime: "image/gif", length: UInt64(data.count))
        try cache.begin(asset, id: transfer)
        XCTAssertThrowsError(try cache.accept(id: transfer, offset: 1, data: data)); cache.cancel()
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        try cache.begin(asset, id: transfer); _ = try cache.accept(id: transfer, offset: 0, data: data)
        try cache.begin(asset, id: foreground); cache.cancel(); XCTAssertNotNil(try cache.cached(asset))
    }
    /// 系统RPC按编码后容量受限，未知版本和未知操作不得误解为成功。
    func test_rpc_boundaries_and_unknown_operation_fail_closed() throws {
        XCTAssertThrowsError(try WatchProtocol.request(Data("{\"version\":1,\"op\":\"shell\"}".utf8)))
        XCTAssertThrowsError(try WatchProtocol.request(Data(repeating: 32, count: WatchProtocol.maxRPCBytes + 1)))
        var request = WatchRPC("snapshotChunk"); request.data = Data(repeating: 0, count: WatchProtocol.chunkSize)
        XCTAssertLessThan(try WatchProtocol.encode(request).count, WatchProtocol.maxRPCBytes)
        request.data = Data(repeating: 0, count: WatchProtocol.maxRPCBytes)
        XCTAssertThrowsError(try WatchProtocol.encode(request))
    }
    /// 大图超过45秒仍持续收到有效块ACK时保持可达，只有停止真实回执才超时。
    func test_long_asset_transfer_renews_contact_without_restarting_foreground() throws {
        var lease = WatchForegroundLease(); try lease.activate(session: foreground)
        for second in [0, 10, 20, 30, 40, 50, 60, 70] {
            let now = UInt64(second) * 1_000_000_000
            try lease.received(session: foreground, now: now)
            XCTAssertTrue(lease.reachable(now: now + 1))
        }
        XCTAssertTrue(lease.reachable(now: 114_999_999_999))
        XCTAssertFalse(lease.reachable(now: 115_000_000_000))
    }

    /// 每块到达前用量都变化时，仍被引用的大图必须累计进度并最终通过完整摘要校验。
    func test_frequent_snapshots_do_not_restart_referenced_asset() throws {
        let cache = try WatchAssetCache(directory: try temporaryFolder())
        let header = Data(base64Encoded: "R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7")!
        let data = header + Data(repeating: 0, count: 1_000_000)
        let asset = LanDisplaySnapshot.Asset(hash: WatchProtocol.hash(data), mime: "image/gif", length: UInt64(data.count))
        let committedHook = LanDisplaySnapshot.Hook(agent: "codex", slot: 1, behavior: .running,
            content: "首份快照", contentTruncated: false, image: asset.hash)
        let committed = LanDisplaySnapshot(version: 1, tokens: nil, tokenError: nil, hooksAvailable: true,
            hooks: [committedHook], assets: [asset], catalogError: nil)
        let first = WatchTransferPolicy.nextPayload(committed: nil, latest: committed, snapshotPending: true,
            available: [asset.hash], acknowledged: [], failed: [])
        guard case .snapshot = first else { return XCTFail("必须先提交授权图片清单的完整快照") }
        try cache.begin(asset, id: transfer)
        var offset = 0
        while offset < data.count {
            let hook = LanDisplaySnapshot.Hook(agent: "codex", slot: 1, behavior: .running,
                content: "变化中的用量 \(offset)", contentTruncated: false, image: asset.hash)
            let latest = LanDisplaySnapshot(version: 1, tokens: nil, tokenError: nil, hooksAvailable: true,
                hooks: [hook], assets: [asset], catalogError: nil)
            let next = WatchTransferPolicy.nextPayload(committed: committed, latest: latest, snapshotPending: true,
                available: [asset.hash], acknowledged: [], failed: [])
            guard case .asset(let selected) = next else { return XCTFail("持续更新不能阻止已提交清单里的图片开始传输") }
            XCTAssertEqual(selected, asset)
            if !WatchTransferPolicy.keepInFlight(asset: asset, latest: latest) { cache.cancel() }
            let end = min(data.count, offset + WatchProtocol.chunkSize)
            _ = try cache.accept(id: transfer, offset: UInt64(offset), data: data.subdata(in: offset..<end))
            offset = end
        }
        XCTAssertNotNil(try cache.cached(asset))
        let next = WatchTransferPolicy.nextPayload(committed: committed, latest: committed, snapshotPending: true,
            available: [asset.hash], acknowledged: [asset.hash], failed: [])
        guard case .snapshot = next else { return XCTFail("图片完成后必须恢复最新快照") }
        let failed = WatchTransferPolicy.nextPayload(committed: committed, latest: committed, snapshotPending: true,
            available: [asset.hash], acknowledged: [], failed: [asset.hash])
        guard case .snapshot = failed else { return XCTFail("失败图片必须让位于最新快照") }
        let removed = LanDisplaySnapshot(version: 1, tokens: nil, tokenError: nil, hooksAvailable: true,
            hooks: [], assets: [asset], catalogError: nil)
        XCTAssertFalse(WatchTransferPolicy.keepInFlight(asset: asset, latest: removed))
        XCTAssertTrue(WatchTransferPolicy.keepInFlight(asset: nil, latest: removed))
        let changed = LanDisplaySnapshot.Asset(hash: asset.hash, mime: "image/png", length: asset.length)
        let hook = LanDisplaySnapshot.Hook(agent: "codex", slot: 1, behavior: .running,
            content: "", contentTruncated: false, image: asset.hash)
        let replaced = LanDisplaySnapshot(version: 1, tokens: nil, tokenError: nil, hooksAvailable: true,
            hooks: [hook], assets: [changed], catalogError: nil)
        XCTAssertFalse(WatchTransferPolicy.keepInFlight(asset: asset, latest: replaced))
    }

    /// 图片目录可含尚未引用的图；Hook切图必须先更新Watch快照，不能重复发送未授权资源饿死新快照。
    func test_changed_hook_image_requires_committing_new_reference_first() {
        let first = LanDisplaySnapshot.Asset(hash: String(repeating: "a", count: 64), mime: "image/gif", length: 100)
        let second = LanDisplaySnapshot.Asset(hash: String(repeating: "b", count: 64), mime: "image/gif", length: 100)
        let oldHook = LanDisplaySnapshot.Hook(agent: "codex", slot: 1, behavior: .running, content: "", contentTruncated: false, image: first.hash)
        let newHook = LanDisplaySnapshot.Hook(agent: "codex", slot: 1, behavior: .running, content: "", contentTruncated: false, image: second.hash)
        let committed = LanDisplaySnapshot(version: 1, tokens: nil, tokenError: nil, hooksAvailable: true,
            hooks: [oldHook], assets: [first, second], catalogError: nil)
        let latest = LanDisplaySnapshot(version: 1, tokens: nil, tokenError: nil, hooksAvailable: true,
            hooks: [newHook], assets: [first, second], catalogError: nil)
        let next = WatchTransferPolicy.nextPayload(committed: committed, latest: latest, snapshotPending: true,
            available: [first.hash, second.hash], acknowledged: [], failed: [])
        guard case .snapshot = next else { return XCTFail("Watch必须先收到新Hook的引用授权") }
    }

    /// 只有实际ACK递增，图片通信不更新完整快照同步，父连接切换保持序号递增但清除证明。
    func test_companion_facts_preserve_ack_sequence_and_independent_sync_age() throws {
        var facts = WatchCompanionFacts()
        let info = WatchDeviceInfo(deviceId: foreground, name: "Watch", appVersion: "1.0")
        try facts.received(now: 1_000_000_000, synchronized: true)
        try facts.received(now: 3_000_000_000)
        let report = try facts.report(info: info, reachable: true, now: 4_000_000_001)
        XCTAssertEqual(report["reachable"] as? Bool, true)
        XCTAssertEqual(report["contact"] as? [String: UInt64], ["sequence": 2, "ageMs": 1_001])
        XCTAssertEqual(report["sync"] as? [String: UInt64], ["sequence": 1, "ageMs": 3_001])
        XCTAssertThrowsError(try facts.received(now: 1))
        XCTAssertEqual(try facts.report(info: info, reachable: true, now: 48_000_000_000)["reachable"] as? Bool, false)
        facts.clear()
        XCTAssertNil(try facts.report(info: info, reachable: true, now: 50_000_000_000)["contact"])
        try facts.received(now: 51_000_000_000)
        let next = try facts.report(info: info, reachable: true, now: 51_000_000_000)
        XCTAssertEqual((next["contact"] as? [String: UInt64])?["sequence"], 3)
        XCTAssertNil(next["sync"])
    }
    /// 旧主机和缓存没有实时扩展广告时不发送新消息，格式混淆也不能启用能力。
    func test_companion_capability_requires_bounded_live_host_advertisement() throws {
        XCTAssertFalse(try WatchCompanionFacts.hostSupports([:]))
        XCTAssertFalse(try WatchCompanionFacts.hostSupports(["capabilities": ["futureV1"]]))
        XCTAssertTrue(try WatchCompanionFacts.hostSupports(["capabilities": ["watchCompanionV1"]]))
        XCTAssertThrowsError(try WatchCompanionFacts.hostSupports(["capabilities": [true]]))
        XCTAssertThrowsError(try WatchCompanionFacts.hostSupports(["capabilities": ["watchCompanionV1", "watchCompanionV1"]]))
    }

}
