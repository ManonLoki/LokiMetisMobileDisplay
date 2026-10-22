import Foundation
import XCTest
@testable import AppleDisplay

/// 只构造图片引用与合法清单；所有磁盘读写位于用例自己的临时目录，不下载图片。
final class PhoneHookCacheTests: XCTestCase {
    private let phone = "10000000-0000-4000-8000-000000000001"
    private let otherPhone = "10000000-0000-4000-8000-000000000002"
    private let source = "20000000-0000-4000-8000-000000000001"
    private let otherSource = "20000000-0000-4000-8000-000000000002"
    private var image: LanDisplaySnapshot.Asset {
        .init(hash: String(repeating: "a", count: 64), mime: "image/gif", length: 123)
    }
    private var alternateImage: LanDisplaySnapshot.Asset {
        .init(hash: String(repeating: "b", count: 64), mime: "image/png", length: 456)
    }

    private func target(sourceId: String? = nil) throws -> WidgetRefreshTarget {
        try WidgetRefreshTarget(sourceId: sourceId ?? source, deviceId: phone,
            host: "192.168.1.12", port: 8123, key: Data(repeating: 17, count: 32).base64EncodedString())
    }

    private func hook(agent: String = "codex", slot: Int = 1, hasImage: Bool = true,
                      imageTime: Int64? = nil, asset: LanDisplaySnapshot.Asset? = nil) -> LanDisplaySnapshot.Hook {
        var value = LanDisplaySnapshot.Hook(agent: agent, slot: slot, behavior: .running,
            content: "旧正文不能混入HTTP摘要", contentTruncated: true, image: hasImage ? (asset ?? image).hash : nil)
        value.cachedImageReceivedAtMs = imageTime
        return value
    }

    private func full(at time: Int64 = 1000, phoneId: String? = nil, sourceId: String? = nil,
                      hooks: [LanDisplaySnapshot.Hook]? = nil,
                      assets: [LanDisplaySnapshot.Asset]? = nil) throws -> PhoneDisplayCache {
        let snapshot = LanDisplaySnapshot(version: 1, tokens: nil, tokenError: nil,
            hooksAvailable: true, hooks: hooks ?? [hook()], assets: assets ?? [image], catalogError: nil)
        let value = PhoneDisplayCache(envelope: WatchSnapshotEnvelope(version: 1, phoneId: phoneId ?? phone,
            sourceId: sourceId ?? source, phoneReceivedAtMs: time, snapshot: snapshot), summaryOnly: false)
        try value.validate()
        return value
    }

    private func summary(at time: Int64 = 3000, sourceId: String? = nil,
                         hooks: [WidgetHook]? = nil) throws -> WidgetSnapshot {
        let amount = WidgetAmount(total: "999", availability: .available, completeness: .complete, confidence: .exact)
        let tokens = WidgetTokens(day: .init(date: "2026-10-22", zone: "Asia/Shanghai", startMs: 0, endMs: 86400000),
            observedMs: 1000, all: amount, agents: [.init(agent: "codex", amount: amount)])
        let quota = ProviderQuotaSnapshot(observedAtUnix: 1234, providers: [
            .init(provider: "codex", plan: "Pro", fiveHour: .init(kind: "fiveHour", usedTenths: 321, resetAtUnix: nil), weekly: nil)
        ])
        let snapshot = WidgetDisplaySnapshot(version: 1, tokens: tokens, tokenError: nil,
            hooksAvailable: true, hooks: hooks ?? [.init(agent: "codex", slot: 1, behavior: .error)], providerQuota: quota)
        let value = WidgetSnapshot(schemaVersion: 2, sourceId: sourceId ?? source,
            receivedAtMs: time, snapshot: snapshot, validUntilMs: time + WidgetSnapshot.leaseMs)
        try value.validate()
        return value
    }

    private func commit(_ full: PhoneDisplayCache, to store: WidgetSnapshotStore) throws {
        let envelope = full.envelope
        let snapshot = envelope.snapshot
        let summary = WidgetSnapshot(schemaVersion: 2, sourceId: envelope.sourceId,
            receivedAtMs: envelope.phoneReceivedAtMs,
            snapshot: WidgetDisplaySnapshot(version: snapshot.version, tokens: snapshot.tokens,
                tokenError: snapshot.tokenError, hooksAvailable: snapshot.hooksAvailable,
                hooks: snapshot.hooks.map { .init(agent: $0.agent, slot: $0.slot, behavior: $0.behavior) },
                providerQuota: snapshot.providerQuota),
            validUntilMs: envelope.phoneReceivedAtMs + WidgetSnapshot.leaseMs)
        try store.saveAuthenticatedSnapshot(summary, refreshTarget: target(sourceId: envelope.sourceId), displayCache: full)
    }

    private func watchRecord(hooks: [LanDisplaySnapshot.Hook], assets: [LanDisplaySnapshot.Asset] = []) throws -> WatchDisplayRecord {
        let snapshot = LanDisplaySnapshot(version: 1, tokens: nil, tokenError: nil,
            hooksAvailable: true, hooks: hooks, assets: assets, catalogError: nil)
        let envelope = WatchSnapshotEnvelope(version: 1, phoneId: phone, sourceId: source,
            phoneReceivedAtMs: 5000, snapshot: snapshot)
        let bytes = try SharedJSON.sortedEncoder.encode(envelope)
        let record = WatchDisplayRecord(envelopeData: bytes, snapshotHash: WatchProtocol.hash(bytes),
            receivedAtMs: 5000, summaryOnly: assets.isEmpty)
        try record.validate()
        return record
    }

    private func mediaHook(slot: Int = 1, asset: LanDisplaySnapshot.Asset? = nil,
                           imageTime: Int64? = nil, clearedTime: Int64? = nil) -> LanDisplaySnapshot.Hook {
        var value = LanDisplaySnapshot.Hook(agent: "codex", slot: slot, behavior: .error,
            content: "", contentTruncated: false, image: asset?.hash)
        value.cachedImageReceivedAtMs = imageTime
        value.cachedImageClearedAtMs = clearedTime
        return value
    }

    func test_http_refresh_and_reopened_store_keep_image_but_use_latest_status_tokens_and_quota() throws {
        let directory = try temporaryFolder()
        let store = WidgetSnapshotStore(directory: directory)
        try commit(full(), to: store)
        let current = try summary()
        let authorized = try XCTUnwrap(store.loadRefreshTarget())
        XCTAssertTrue(try store.saveFetchedSnapshot(current, for: authorized, startedAtMs: 2000))

        let recovered = try XCTUnwrap(WidgetSnapshotStore(directory: directory).loadDisplayCache())
        let retained = try XCTUnwrap(recovered.envelope.snapshot.hooks.first)
        XCTAssertFalse(recovered.summaryOnly)
        XCTAssertEqual(recovered.envelope.phoneReceivedAtMs, 3000)
        XCTAssertEqual(retained.slot, 1)
        XCTAssertEqual(retained.agent, "codex")
        XCTAssertEqual(retained.behavior, .error)
        XCTAssertEqual(retained.image, image.hash)
        XCTAssertEqual(retained.cachedImageReceivedAtMs, 1000)
        XCTAssertEqual(recovered.envelope.snapshot.assets, [image])
        XCTAssertEqual(retained.content, "")
        XCTAssertFalse(retained.contentTruncated)
        XCTAssertEqual(recovered.envelope.snapshot.tokens, current.snapshot.tokens)
        XCTAssertEqual(recovered.envelope.snapshot.providerQuota, current.snapshot.providerQuota)
    }

    func test_repeated_http_refreshes_never_renew_original_image_time() throws {
        let directory = try temporaryFolder()
        let store = WidgetSnapshotStore(directory: directory)
        try commit(full(), to: store)
        let authorized = try XCTUnwrap(store.loadRefreshTarget())
        XCTAssertTrue(try store.saveFetchedSnapshot(summary(at: 3000), for: authorized))
        XCTAssertTrue(try store.saveFetchedSnapshot(summary(at: 5000), for: authorized))
        let reopened = WidgetSnapshotStore(directory: directory)
        XCTAssertEqual(try reopened.loadDisplayCache()?.envelope.snapshot.hooks.first?.cachedImageReceivedAtMs, 1000)
        XCTAssertEqual(try reopened.loadDisplayCache()?.envelope.phoneReceivedAtMs, 5000)

        let old = try full(at: 2000, hooks: [hook(imageTime: 500)])
        let merged = try PhoneDisplayCache.summary(summary(), phoneId: phone, preservingImagesFrom: old)
        XCTAssertEqual(merged.envelope.snapshot.hooks.first?.cachedImageReceivedAtMs, 500)
    }

    func test_two_file_recovery_merges_latest_summary_without_relabeling_image_or_restoring_old_content() throws {
        let directory = try temporaryFolder()
        let store = WidgetSnapshotStore(directory: directory)
        try commit(full(), to: store)
        // 模拟摘要已原子提交、展示文件尚未更新时进程结束。
        try WidgetStoreFixture.writeSnapshot(summary(at: 6000), to: store)
        let recovered = try XCTUnwrap(WidgetSnapshotStore(directory: directory).loadDisplayCache())
        XCTAssertEqual(recovered.envelope.phoneReceivedAtMs, 6000)
        XCTAssertEqual(recovered.envelope.snapshot.hooks.first?.behavior, .error)
        XCTAssertEqual(recovered.envelope.snapshot.hooks.first?.image, image.hash)
        XCTAssertEqual(recovered.envelope.snapshot.hooks.first?.cachedImageReceivedAtMs, 1000)
        XCTAssertEqual(recovered.envelope.snapshot.hooks.first?.content, "")
        XCTAssertFalse(recovered.summaryOnly)
    }

    func test_agent_replacement_and_slot_release_do_not_borrow_previous_image() throws {
        let previous = try full()
        for hooks in [
            [WidgetHook(agent: "cursor", slot: 1, behavior: .idle)],
            [WidgetHook(agent: "codex", slot: 2, behavior: .asking)],
            []
        ] {
            let merged = try PhoneDisplayCache.summary(summary(hooks: hooks), phoneId: phone, preservingImagesFrom: previous)
            XCTAssertTrue(merged.summaryOnly)
            XCTAssertTrue(merged.envelope.snapshot.assets.isEmpty)
            XCTAssertEqual(merged.envelope.snapshot.hooks.map(\.slot), hooks.map(\.slot))
            XCTAssertTrue(merged.envelope.snapshot.hooks.allSatisfy { $0.image == nil && $0.cachedImageReceivedAtMs == nil })
        }
    }

    func test_phone_source_and_time_boundaries_prevent_cross_record_image_reuse() throws {
        let current = try summary()
        for previous in [
            try full(phoneId: otherPhone),
            try full(sourceId: otherSource),
            try full(at: 4000)
        ] {
            let merged = try PhoneDisplayCache.summary(current, phoneId: phone, preservingImagesFrom: previous)
            XCTAssertTrue(merged.summaryOnly)
            XCTAssertNil(merged.envelope.snapshot.hooks.first?.image)
            XCTAssertNil(merged.envelope.snapshot.hooks.first?.cachedImageReceivedAtMs)
            XCTAssertTrue(merged.envelope.snapshot.assets.isEmpty)
        }
        let sameTime = try PhoneDisplayCache.summary(summary(at: 1000), phoneId: phone, preservingImagesFrom: full())
        XCTAssertEqual(sameTime.envelope.snapshot.hooks.first?.image, image.hash)
    }

    func test_image_requires_both_hook_reference_and_matching_descriptor() throws {
        for previous in [
            try full(assets: []),
            try full(hooks: [hook(hasImage: false)])
        ] {
            let merged = try PhoneDisplayCache.summary(summary(), phoneId: phone, preservingImagesFrom: previous)
            XCTAssertTrue(merged.summaryOnly)
            XCTAssertNil(merged.envelope.snapshot.hooks.first?.image)
            XCTAssertNil(merged.envelope.snapshot.hooks.first?.cachedImageReceivedAtMs)
            XCTAssertTrue(merged.envelope.snapshot.assets.isEmpty)
        }
        let noPrevious = try PhoneDisplayCache.summary(summary(), phoneId: phone)
        XCTAssertTrue(noPrevious.summaryOnly)
        XCTAssertTrue(noPrevious.envelope.snapshot.assets.isEmpty)
    }

    func test_envelope_image_merge_uses_current_facts_and_deduplicates_shared_descriptor() throws {
        let previous = try full(hooks: [hook(), hook(slot: 2)])
        let current = try PhoneDisplayCache.summary(summary(hooks: [
            .init(agent: "codex", slot: 1, behavior: .asking),
            .init(agent: "codex", slot: 2, behavior: .idle)
        ]), phoneId: phone).envelope
        let merged = try current.preservingCachedHookImages(from: previous.envelope)
        XCTAssertEqual(merged.snapshot.hooks.map(\.behavior), [.asking, .idle])
        XCTAssertEqual(merged.snapshot.hooks.map(\.image), [image.hash, image.hash])
        XCTAssertEqual(merged.snapshot.hooks.map(\.cachedImageReceivedAtMs), [1000, 1000])
        XCTAssertEqual(merged.snapshot.assets, [image])
        XCTAssertEqual(merged.phoneReceivedAtMs, current.phoneReceivedAtMs)
        XCTAssertEqual(merged.snapshot.tokens, current.snapshot.tokens)
        XCTAssertEqual(merged.snapshot.providerQuota, current.snapshot.providerQuota)
        XCTAssertTrue(merged.snapshot.hooks.allSatisfy { $0.content.isEmpty })
    }

    func test_explicit_complete_snapshot_removes_image_and_later_http_cannot_resurrect_it() throws {
        let directory = try temporaryFolder()
        let store = WidgetSnapshotStore(directory: directory)
        try commit(full(), to: store)
        let initialTarget = try XCTUnwrap(store.loadRefreshTarget())
        XCTAssertTrue(try store.saveFetchedSnapshot(summary(), for: initialTarget))
        let cleared = try full(at: 4000, hooks: [hook(hasImage: false)], assets: [])
        try commit(cleared, to: store)
        XCTAssertNil(try store.loadDisplayCache()?.envelope.snapshot.hooks.first?.image)
        let authorized = try XCTUnwrap(store.loadRefreshTarget())
        XCTAssertTrue(try store.saveFetchedSnapshot(summary(at: 5000), for: authorized))
        let recovered = try XCTUnwrap(WidgetSnapshotStore(directory: directory).loadDisplayCache())
        XCTAssertTrue(recovered.summaryOnly)
        XCTAssertNil(recovered.envelope.snapshot.hooks.first?.image)
        XCTAssertNil(recovered.envelope.snapshot.hooks.first?.cachedImageReceivedAtMs)
    }

    func test_delayed_http_and_changed_source_never_restore_old_image_or_status() throws {
        let directory = try temporaryFolder()
        let store = WidgetSnapshotStore(directory: directory)
        try commit(full(), to: store)
        let initialTarget = try XCTUnwrap(store.loadRefreshTarget())
        XCTAssertTrue(try store.saveFetchedSnapshot(summary(at: 5000), for: initialTarget))
        let latest = try XCTUnwrap(store.loadDisplayCache())
        XCTAssertFalse(try store.saveFetchedSnapshot(summary(at: 4000), for: initialTarget))
        XCTAssertFalse(try store.saveFetchedSnapshot(summary(at: 6000), for: initialTarget, startedAtMs: 3000))
        XCTAssertEqual(try store.loadDisplayCache(), latest)

        try store.selectSource(otherSource)
        XCTAssertNil(try store.loadDisplayCache())
        XCTAssertFalse(try store.saveFetchedSnapshot(summary(at: 7000), for: initialTarget))
        try store.saveAuthenticatedSnapshot(summary(at: 7000, sourceId: otherSource), refreshTarget: target(sourceId: otherSource))
        let newTarget = try XCTUnwrap(store.loadRefreshTarget())
        XCTAssertTrue(try store.saveFetchedSnapshot(summary(at: 8000, sourceId: otherSource), for: newTarget))
        let switched = try XCTUnwrap(store.loadDisplayCache())
        XCTAssertTrue(switched.summaryOnly)
        XCTAssertEqual(switched.envelope.sourceId, otherSource)
        XCTAssertNil(switched.envelope.snapshot.hooks.first?.image)
        try store.forgetSource(otherSource)
        XCTAssertNil(try WidgetSnapshotStore(directory: directory).loadDisplayCache())
    }

    func test_equal_time_complete_snapshot_wins_over_mixed_and_plain_http_cache() throws {
        for hasImage in [true, false] {
            let directory = try temporaryFolder()
            let store = WidgetSnapshotStore(directory: directory)
            let complete = try full(at: 3000, hooks: [hook(hasImage: hasImage)], assets: hasImage ? [image] : [])
            try commit(complete, to: store)
            let authorized = try XCTUnwrap(store.loadRefreshTarget())
            XCTAssertTrue(try store.saveFetchedSnapshot(summary(at: 3000), for: authorized))
            XCTAssertEqual(try store.loadDisplayCache(), complete)
        }

        // 相同时间反向提交：完整桌面清图必须覆盖先前HTTP混合缓存。
        let store = WidgetSnapshotStore(directory: try temporaryFolder())
        try commit(full(), to: store)
        let authorized = try XCTUnwrap(store.loadRefreshTarget())
        XCTAssertTrue(try store.saveFetchedSnapshot(summary(at: 3000), for: authorized))
        XCTAssertEqual(try store.loadDisplayCache()?.envelope.snapshot.hooks.first?.cachedImageReceivedAtMs, 1000)
        let cleared = try full(at: 3000, hooks: [hook(hasImage: false)], assets: [])
        try commit(cleared, to: store)
        XCTAssertEqual(try store.loadDisplayCache(), cleared)
    }

    func test_delayed_complete_publish_adds_image_to_newer_http_without_rolling_back_facts() throws {
        let directory = try temporaryFolder()
        let store = WidgetSnapshotStore(directory: directory)
        // 只读凭据已落盘但旧摘要缺失，HTTP 先补齐摘要，迟到的完整发布随后补图。
        try WidgetStoreFixture.writeTarget(target(), to: store)
        let authorized = try XCTUnwrap(store.loadRefreshTarget())
        XCTAssertThrowsError(try store.load())
        let current = try summary(at: 5000)
        XCTAssertTrue(try store.saveFetchedSnapshot(current, for: authorized))
        XCTAssertTrue(try XCTUnwrap(store.loadDisplayCache()).summaryOnly)

        // 模拟认证快照发布排队：较新的HTTP先提交，旧完整快照稍后才到发布器。
        try commit(full(at: 3000), to: store)
        let recovered = try XCTUnwrap(WidgetSnapshotStore(directory: directory).loadDisplayCache())
        XCTAssertFalse(recovered.summaryOnly)
        XCTAssertEqual(recovered.envelope.phoneReceivedAtMs, 5000)
        XCTAssertEqual(recovered.envelope.snapshot.hooks.first?.behavior, .error)
        XCTAssertEqual(recovered.envelope.snapshot.hooks.first?.image, image.hash)
        XCTAssertEqual(recovered.envelope.snapshot.hooks.first?.cachedImageReceivedAtMs, 3000)
        XCTAssertEqual(recovered.envelope.snapshot.hooks.first?.content, "")
        XCTAssertEqual(recovered.envelope.snapshot.tokens, current.snapshot.tokens)
        XCTAssertEqual(recovered.envelope.snapshot.providerQuota, current.snapshot.providerQuota)
        XCTAssertEqual(try store.load().receivedAtMs, 5000)
    }

    func test_late_image_merge_fills_missing_slot_without_replacing_existing_cached_image() throws {
        let otherImage = LanDisplaySnapshot.Asset(hash: String(repeating: "b", count: 64), mime: "image/png", length: 456)
        let existingHook = LanDisplaySnapshot.Hook(agent: "codex", slot: 1, behavior: .running,
            content: "", contentTruncated: false, image: otherImage.hash)
        var olderEmptySlot = LanDisplaySnapshot.Hook(agent: "codex", slot: 2, behavior: .idle,
            content: "", contentTruncated: false, image: nil)
        olderEmptySlot.cachedImageClearedAtMs = 1000
        // Slot1图片已到T4000；Slot2仅确认过T1000清图，仍允许迟到的T3000图片补齐。
        let earlier = try full(at: 4000, hooks: [existingHook, olderEmptySlot], assets: [otherImage])
        let current = try PhoneDisplayCache.summary(summary(at: 5000, hooks: [
            .init(agent: "codex", slot: 1, behavior: .error),
            .init(agent: "codex", slot: 2, behavior: .idle)
        ]), phoneId: phone, preservingImagesFrom: earlier)
        let late = try full(at: 3000, hooks: [hook(), hook(slot: 2)])
        let merged = try current.envelope.preservingCachedHookImages(from: late.envelope)
        XCTAssertEqual(merged.phoneReceivedAtMs, 5000)
        XCTAssertEqual(merged.snapshot.hooks.map(\.behavior), [.error, .idle])
        XCTAssertEqual(merged.snapshot.hooks.map(\.image), [otherImage.hash, image.hash])
        XCTAssertEqual(merged.snapshot.hooks.map(\.cachedImageReceivedAtMs), [4000, 3000])
        XCTAssertEqual(Set(merged.snapshot.assets.map(\.hash)), Set([otherImage.hash, image.hash]))
        XCTAssertTrue(merged.snapshot.hooks.allSatisfy { $0.content.isEmpty })
    }

    func test_delayed_newer_image_replaces_retained_old_image_without_reverting_http_facts() throws {
        let directory = try temporaryFolder()
        let store = WidgetSnapshotStore(directory: directory)
        try commit(full(at: 1000), to: store)
        let authorized = try XCTUnwrap(store.loadRefreshTarget())
        let latest = try summary(at: 5000)
        XCTAssertTrue(try store.saveFetchedSnapshot(latest, for: authorized))
        XCTAssertEqual(try store.loadDisplayCache()?.envelope.snapshot.hooks.first?.image, image.hash)
        try commit(full(at: 3000, hooks: [hook(asset: alternateImage)], assets: [alternateImage]), to: store)

        let recovered = try XCTUnwrap(WidgetSnapshotStore(directory: directory).loadDisplayCache())
        XCTAssertEqual(recovered.envelope.phoneReceivedAtMs, 5000)
        XCTAssertEqual(recovered.envelope.snapshot.hooks.first?.behavior, .error)
        XCTAssertEqual(recovered.envelope.snapshot.hooks.first?.image, alternateImage.hash)
        XCTAssertEqual(recovered.envelope.snapshot.hooks.first?.cachedImageReceivedAtMs, 3000)
        XCTAssertNil(recovered.envelope.snapshot.hooks.first?.cachedImageClearedAtMs)
        XCTAssertEqual(recovered.envelope.snapshot.assets, [alternateImage])
        XCTAssertEqual(recovered.envelope.snapshot.tokens, latest.snapshot.tokens)
        XCTAssertEqual(recovered.envelope.snapshot.providerQuota, latest.snapshot.providerQuota)
        XCTAssertEqual(recovered.envelope.snapshot.hooks.first?.content, "")
    }

    func test_delayed_clear_removes_old_image_and_prevents_older_image_resurrection_after_http_refresh() throws {
        let directory = try temporaryFolder()
        let store = WidgetSnapshotStore(directory: directory)
        try commit(full(at: 1000), to: store)
        let authorized = try XCTUnwrap(store.loadRefreshTarget())
        XCTAssertTrue(try store.saveFetchedSnapshot(summary(at: 5000), for: authorized))
        try commit(full(at: 3000, hooks: [hook(hasImage: false)], assets: []), to: store)
        let cleared = try XCTUnwrap(store.loadDisplayCache())
        XCTAssertEqual(cleared.envelope.phoneReceivedAtMs, 5000)
        XCTAssertEqual(cleared.envelope.snapshot.hooks.first?.behavior, .error)
        XCTAssertNil(cleared.envelope.snapshot.hooks.first?.image)
        XCTAssertNil(cleared.envelope.snapshot.hooks.first?.cachedImageReceivedAtMs)
        XCTAssertEqual(cleared.envelope.snapshot.hooks.first?.cachedImageClearedAtMs, 3000)
        XCTAssertTrue(cleared.envelope.snapshot.assets.isEmpty)

        XCTAssertTrue(try store.saveFetchedSnapshot(summary(at: 6000), for: authorized))
        try commit(full(at: 2000), to: store)
        let recovered = try XCTUnwrap(WidgetSnapshotStore(directory: directory).loadDisplayCache())
        XCTAssertEqual(recovered.envelope.phoneReceivedAtMs, 6000)
        XCTAssertEqual(recovered.envelope.snapshot.hooks.first?.behavior, .error)
        XCTAssertNil(recovered.envelope.snapshot.hooks.first?.image)
        XCTAssertNil(recovered.envelope.snapshot.hooks.first?.cachedImageReceivedAtMs)
        XCTAssertEqual(recovered.envelope.snapshot.hooks.first?.cachedImageClearedAtMs, 3000)
        XCTAssertTrue(recovered.envelope.snapshot.assets.isEmpty)
    }

    func test_older_clear_cannot_remove_newer_cached_image() throws {
        let directory = try temporaryFolder()
        let store = WidgetSnapshotStore(directory: directory)
        try commit(full(at: 4000, hooks: [hook(asset: alternateImage)], assets: [alternateImage]), to: store)
        let authorized = try XCTUnwrap(store.loadRefreshTarget())
        XCTAssertTrue(try store.saveFetchedSnapshot(summary(at: 5000), for: authorized))
        try commit(full(at: 3000, hooks: [hook(hasImage: false)], assets: []), to: store)

        let recovered = try XCTUnwrap(WidgetSnapshotStore(directory: directory).loadDisplayCache())
        XCTAssertEqual(recovered.envelope.phoneReceivedAtMs, 5000)
        XCTAssertEqual(recovered.envelope.snapshot.hooks.first?.behavior, .error)
        XCTAssertEqual(recovered.envelope.snapshot.hooks.first?.image, alternateImage.hash)
        XCTAssertEqual(recovered.envelope.snapshot.hooks.first?.cachedImageReceivedAtMs, 4000)
        XCTAssertNil(recovered.envelope.snapshot.hooks.first?.cachedImageClearedAtMs)
        XCTAssertEqual(recovered.envelope.snapshot.assets, [alternateImage])
    }

    func test_http_missing_image_is_unknown_and_cannot_be_treated_as_explicit_clear() throws {
        let current = try PhoneDisplayCache.summary(summary(at: 5000), phoneId: phone,
            preservingImagesFrom: full(at: 1000))
        let unknown = try PhoneDisplayCache.summary(summary(at: 3000), phoneId: phone)
        let merged = try current.envelope.preservingCachedHookImages(from: unknown.envelope, previousSummaryOnly: true)
        XCTAssertEqual(merged.snapshot.hooks.first?.image, image.hash)
        XCTAssertEqual(merged.snapshot.hooks.first?.cachedImageReceivedAtMs, 1000)
        XCTAssertNil(merged.snapshot.hooks.first?.cachedImageClearedAtMs)
        XCTAssertEqual(merged.snapshot.assets, [image])
        XCTAssertEqual(merged.phoneReceivedAtMs, 5000)
    }

    func test_slot_reassignment_or_confirmed_absence_blocks_images_older_than_previous_occupancy() throws {
        let scenarios: [(String, [LanDisplaySnapshot.Hook], [LanDisplaySnapshot.Asset])] = [
            ("同slot换Agent", [hook()], [image]),
            ("已确认slot缺席后重新出现", [], [])
        ]
        for (reason, oldHooks, oldAssets) in scenarios {
            let directory = try temporaryFolder()
            let store = WidgetSnapshotStore(directory: directory)
            let previous = try full(at: 1000, hooks: oldHooks, assets: oldAssets)
            try commit(previous, to: store)
            let authorized = try XCTUnwrap(store.loadRefreshTarget())
            let current = try summary(at: 3000, hooks: [.init(agent: "cursor", slot: 1, behavior: .asking)])
            XCTAssertTrue(try store.saveFetchedSnapshot(current, for: authorized), reason)
            let changed = try XCTUnwrap(store.loadDisplayCache())
            XCTAssertEqual(changed.envelope.snapshot.hooks.first?.agent, "cursor", reason)
            XCTAssertNil(changed.envelope.snapshot.hooks.first?.image, reason)
            XCTAssertEqual(changed.envelope.snapshot.hooks.first?.cachedImageClearedAtMs, 1000, reason)

            // 这张旧Cursor图早于已确认的Codex占用/空槽，不能因Agent恰好匹配而复活。
            try commit(full(at: 500, hooks: [hook(agent: "cursor")]), to: store)
            let blocked = try XCTUnwrap(WidgetSnapshotStore(directory: directory).loadDisplayCache())
            XCTAssertEqual(blocked.envelope.phoneReceivedAtMs, 3000, reason)
            XCTAssertEqual(blocked.envelope.snapshot.hooks.first?.behavior, .asking, reason)
            XCTAssertNil(blocked.envelope.snapshot.hooks.first?.image, reason)
            XCTAssertEqual(blocked.envelope.snapshot.hooks.first?.cachedImageClearedAtMs, 1000, reason)

            // 截止使用旧身份被确认的T1000，不能错用HTTP T3000阻止有效迟到的T2000图片。
            try commit(full(at: 2000, hooks: [hook(agent: "cursor")]), to: store)
            let accepted = try XCTUnwrap(WidgetSnapshotStore(directory: directory).loadDisplayCache())
            XCTAssertEqual(accepted.envelope.phoneReceivedAtMs, 3000, reason)
            XCTAssertEqual(accepted.envelope.snapshot.hooks.first?.behavior, .asking, reason)
            XCTAssertEqual(accepted.envelope.snapshot.hooks.first?.image, image.hash, reason)
            XCTAssertEqual(accepted.envelope.snapshot.hooks.first?.cachedImageReceivedAtMs, 2000, reason)
            XCTAssertNil(accepted.envelope.snapshot.hooks.first?.cachedImageClearedAtMs, reason)

            // 更早的另一身份/空槽记录也不能清掉已经确认较新的当前身份图片。
            let retained = try accepted.envelope.preservingCachedHookImages(from: previous.envelope)
            XCTAssertEqual(retained, accepted.envelope, reason)
        }
    }

    func test_equal_time_watch_mixed_record_rejects_older_images_and_prefers_clear_on_media_tie() throws {
        let cleared = try watchRecord(hooks: [mediaHook(clearedTime: 3000)])
        let oldImage = try watchRecord(hooks: [mediaHook(asset: image, imageTime: 1000)], assets: [image])
        let tiedImage = try watchRecord(hooks: [mediaHook(asset: image, imageTime: 3000)], assets: [image])
        let newerImage = try watchRecord(hooks: [mediaHook(asset: alternateImage, imageTime: 4000)], assets: [alternateImage])

        XCTAssertFalse(try oldImage.supersedes(cleared))
        XCTAssertFalse(try tiedImage.supersedes(cleared))
        XCTAssertTrue(try cleared.supersedes(oldImage))
        XCTAssertTrue(try cleared.supersedes(tiedImage))
        XCTAssertTrue(try newerImage.supersedes(oldImage))
        XCTAssertTrue(try newerImage.supersedes(cleared))
    }

    func test_equal_time_watch_mixed_record_cannot_erase_an_existing_slots_media_cutoff() throws {
        let oldClear = mediaHook(clearedTime: 3000)
        let previous = try watchRecord(hooks: [oldClear])
        let otherSlot = mediaHook(slot: 2, asset: alternateImage, imageTime: 4000)
        // 新记录仍为mixed，但缺少旧slot，不能移除其防止旧图复活的截止事实。
        let missingSlot = try watchRecord(hooks: [otherSlot], assets: [alternateImage])
        XCTAssertFalse(try missingSlot.supersedes(previous))

        let missingMarker = try watchRecord(hooks: [mediaHook(), otherSlot], assets: [alternateImage])
        XCTAssertFalse(try missingMarker.supersedes(previous))
        let preservedMarker = try watchRecord(hooks: [oldClear, otherSlot], assets: [alternateImage])
        XCTAssertTrue(try preservedMarker.supersedes(previous))
    }
}
