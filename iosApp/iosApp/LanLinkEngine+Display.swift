import Foundation

/// 快照投影、图片接收与 Watch 同步：所有方法都在引擎串行队列上执行。
extension LanLinkEngine {
    /// 接收完整快照后才报告在线，并只调度当前实际展示引用的缺失图片。
    func acceptSnapshot(_ message: [String: Any]) throws {
        let snapshot = try LanDisplaySnapshot.decode(message)
        let receivedAt = Date()
        let refreshTarget = widgetRefreshTarget(message)
        watch.configureHTTP(refreshTarget)
        if let run = backgroundRun, let source = view.selectedId {
            // 后台结果也写同一缓存并推送手表；不创建手机前台在线证明。
            watch.cache(snapshot, sourceId: source, receivedAtMs: receivedAt.epochMs)
            view.snapshot = snapshot; view.receivedDate = receivedAt
            view.images = view.images.filter { image in snapshot.hooks.contains { $0.image == image.key } }
            // 后台不取图片，完成必须等待共享文件真正提交。
            phase = .pausing
            deadline = nil
            try? sendSecure(["type": "pause"])
            WidgetSnapshotPublisher.shared.publishInBackground(message, sourceId: source, phoneId: deviceId, receivedAtMs: receivedAt.epochMs, refreshTarget: refreshTarget) { [weak self] saved in
                self?.queue.async { [weak self] in
                    guard let self, self.backgroundRun?.id == run.id else { return }
                    self.finishBackgroundRefresh(success: saved)
                }
            }
            return
        }
        let supportsWatch = try WatchCompanionFacts.hostSupports(message)
        if let report = try deviceType.afterAuthenticatedSnapshot(message) { try sendSecure(report) }
        watchCapability = supportsWatch
        view.canQuerySnapshot = (message["capabilities"] as? [String])?.contains("snapshotQueryV1") == true
        if let id = view.selectedId { WidgetSnapshotPublisher.shared.enqueue(message, sourceId: id, phoneId: deviceId, receivedAtMs: receivedAt.epochMs, refreshTarget: refreshTarget) }
        view.snapshot = snapshot; view.receivedDate = receivedAt; view.connected = true; view.status = "已连接，正在同步"; view.error = nil
        if let id = view.selectedId, let endpoint = endpoints[id], case let .service(service, type, domain, _) = endpoint {
            do { try backgroundTargets.save(BackgroundTarget(id: id, name: service, type: type, domain: domain)) }
            catch { view.backgroundRefreshError = "后台刷新目标未能保存，打开 App 后仍可正常同步。" }
        }
        deadline = nil; intent.connected()
        let hashes = Set(snapshot.hooks.compactMap(\.image))
        view.images = view.images.filter { hashes.contains($0.key) }
        assetPaths = assetPaths.filter { hashes.contains($0.key) }
        cache?.prune(keeping: hashes)
        syncWatch(); try nextAsset(); publish()
    }

    /// 只有成功解密快照的能力字段与系统实际对端组合成读取地址；每次认证同步均更新。
    func widgetRefreshTarget(_ message: [String: Any]) -> WidgetRefreshTarget? {
        guard let source = view.selectedId, let host = socket?.connectedHost,
              (message["capabilities"] as? [String])?.contains("widgetHttpV1") == true,
              let endpoint = message["widgetEndpoint"] as? [String: Any],
              let version = endpoint["version"] as? NSNumber, CFGetTypeID(version) != CFBooleanGetTypeID(), version.doubleValue == 1,
              let port = endpoint["port"] as? NSNumber, CFGetTypeID(port) != CFBooleanGetTypeID(),
              port.doubleValue == Double(port.intValue),
              let key = endpoint["key"] as? String else { return nil }
        return try? WidgetRefreshTarget(sourceId: source, deviceId: deviceId, host: host, port: port.intValue, key: key)
    }

    /// 一次只请求一个16KiB块，文件失败允许降级；所有消耗nonce后的发送失败必须向连接owner传播。
    func nextAsset() throws {
        guard phase == .streaming, currentAsset == nil, let snapshot = view.snapshot, let bridge, let cache else { return }
        let hashes = Set(snapshot.hooks.compactMap(\.image))
        for asset in snapshot.assets where hashes.contains(asset.hash) && view.images[asset.hash] == nil
            && !failedAssets.contains(asset.hash) && !decodingImages.contains(asset.hash) {
            do {
                if let path = cache.cached(asset) {
                    assetPaths[asset.hash] = path
                    decodeImage(path, asset: asset)
                    continue
                }
                try cache.begin(asset, bridge: bridge)
            } catch {
                if error is NativeLinkBridge.Failure { throw error }
                failedAssets.insert(asset.hash); cache.cancel(); view.assetWarning = "部分图片缓存暂不可用，重新连接后可补取。"
                continue
            }
            currentAsset = asset
            syncWatch()
            try requestAsset(asset.hash, offset: 0)
            return
        }
        syncWatch()
    }

    /// 对已失效清单的在途块只排空一次，之后再创建新接收器，避免旧块混入新图片。
    func acceptAsset(_ chunk: [String: Any]) throws {
        guard let asset = currentAsset, let bridge, let cache, chunk["hash"] as? String == asset.hash else { throw WidgetSnapshotError.invalid }
        let active = view.snapshot?.hooks.contains(where: { $0.image == asset.hash }) == true && view.snapshot?.assets.contains(asset) == true
        if !active { dropCurrentAsset(); try nextAsset(); publish(); return }
        let result: (UInt64, URL?)
        do { result = try cache.accept(chunk, bridge: bridge) }
        catch {
            if error is NativeLinkBridge.Failure { throw error }
            failedAssets.insert(asset.hash); dropCurrentAsset()
            view.assetWarning = "部分图片未能保存，重新连接后可补取。"; try nextAsset(); publish()
            return
        }
        let (offset, path) = result
        if let path {
            assetPaths[asset.hash] = path
            decodeImage(path, asset: asset)
            cache.prune(keeping: Set(view.snapshot?.hooks.compactMap(\.image) ?? []))
            currentAsset = nil; assetDeadline = nil; syncWatch(); try nextAsset(); publish()
        } else {
            // 发送位于磁盘catch之外，已消费的密码序号绝不能在同一socket跳过或补发。
            try requestAsset(asset.hash, offset: offset)
        }
    }

    /// 已校验的文件交给解码队列；结果回到网络队列后，仅在仍被当前快照引用时才展示。
    func decodeImage(_ path: URL, asset: LanDisplaySnapshot.Asset) {
        let hash = asset.hash
        guard view.images[hash] == nil, decodingImages.insert(hash).inserted else { return }
        decoder.async { [weak self] in
            let result = Result { try IOSAssetCache.image(path, asset: asset) }
            self?.queue.async { self?.imageDecoded(result, path: path, hash: hash) }
        }
    }

    /// 冷启动缓存只知道摘要：校验文件内容与解码一并放到解码队列，不阻塞发现与认证。
    func loadCachedImages(_ assets: [LanDisplaySnapshot.Asset], directory: URL) {
        let pending = assets.filter { view.images[$0.hash] == nil && decodingImages.insert($0.hash).inserted }
        guard !pending.isEmpty else { return }
        decoder.async { [weak self] in
            for asset in pending {
                // 未命中或已损坏的缓存不算解码失败：连接后仍会按正常流程重新下载。
                let path = IOSAssetCache.verifiedPath(asset, in: directory)
                let result = path.map { path in Result { try IOSAssetCache.image(path, asset: asset) } }
                self?.queue.async { [weak self] in
                    guard let self else { return }
                    guard let path, let result else {
                        // 校验期间可能已连上桌面并跳过了此图；放开占位后补一次调度，确保能重新下载。
                        self.decodingImages.remove(asset.hash)
                        do { try self.nextAsset() } catch { self.fail(retry: true, message: "图片同步中断，正在重新连接。") }
                        return
                    }
                    self.imageDecoded(result, path: path, hash: asset.hash)
                }
            }
        }
    }

    /// 解码结果统一入口：失败明确披露而不静默显示首帧；成功后路径同时供 Watch 传输。
    func imageDecoded(_ result: Result<LanImageAsset, Error>, path: URL, hash: String) {
        decodingImages.remove(hash)
        guard view.snapshot?.hooks.contains(where: { $0.image == hash }) == true else { return }
        switch result {
        case .success(let image):
            view.images[hash] = image
            if assetPaths[hash] == nil { assetPaths[hash] = path; syncWatch() }
        case .failure(let error):
            failedAssets.insert(hash)
            view.assetWarning = (error as? LocalizedError)?.errorDescription ?? "图片无法解码。"
        }
        publish()
    }

    /// 请求只包含当前内容摘要与核心给出的严格偏移，不发送远端文件路径。
    func requestAsset(_ hash: String, offset: UInt64) throws {
        do {
            try sendSecure(["type": "assetRequest", "hash": hash, "offset": offset])
            assetDeadline = now + 10_000_000_000
        } catch {
            dropCurrentAsset()
            throw error
        }
    }

    /// 放弃当前在途图片接收器；磁盘部分文件由缓存自行回收。
    func dropCurrentAsset() {
        cache?.cancel(); currentAsset = nil; assetDeadline = nil
    }

    /// LAN切代同步撤销页面和上行证明，不能等待另一队列的Phone owner异步清理。
    func resetWatchProjection() {
        watchCapability = false; deviceType.reset(); watchNonce = nil
        watchProjectionGeneration = nil; view.watch.reachable = false; watchFacts.clear()
    }

    /// 已认证快照能力和本次ping共同允许上行；事实年龄在实际发送前重新计算。
    func reportWatch() throws {
        guard active, phase == .streaming, view.connected, watchCapability, watchProjectionGeneration == generation, let nonce = watchNonce,
              let info = view.watch.info else { return }
        let report = try watchFacts.report(info: info, reachable: view.watch.reachable, now: now)
        try sendSecure(["type": "companionStatus", "nonce": nonce, "report": report])
    }

    /// 只把本代真实认证快照和已校验路径交配套owner，绝不传递配对凭据。
    func syncWatch() {
        guard phase == .streaming, view.connected, let snapshot = view.snapshot,
              let source = view.selectedId, let date = view.receivedDate else { return }
        watch.update(snapshot, sourceId: source, receivedAtMs: date.epochMs, generation: generation, paths: assetPaths)
    }

    /// 冷启动和回前台读取组件也会更新的同一份缓存，不恢复认证或在线状态。
    func restoreCachedDisplay() {
        do {
            guard let record = try WidgetContainer.store().loadDisplayCache(),
                  record.envelope.phoneId == deviceId,
                  view.selectedId == nil || view.selectedId == record.envelope.sourceId,
                  try store.load(record.envelope.sourceId) != nil,
                  record.envelope.phoneReceivedAtMs <= Date().epochMs else { return }
            if let receivedDate = view.receivedDate, receivedDate.epochMs > record.envelope.phoneReceivedAtMs { return }
            view.selectedId = record.envelope.sourceId
            let snapshot = record.envelope.snapshot
            let hashes = Set(snapshot.hooks.compactMap(\.image))
            view.snapshot = snapshot; view.receivedDate = Date(epochMs: record.envelope.phoneReceivedAtMs)
            view.images = view.images.filter { hashes.contains($0.key) }
            assetPaths = assetPaths.filter { hashes.contains($0.key) }
            watch.selectSource(record.envelope.sourceId)
            guard !record.summaryOnly else { return }
            if cache == nil { cache = try IOSAssetCache() }
            guard let cache else { return }
            loadCachedImages(snapshot.assets.filter { hashes.contains($0.hash) }, directory: cache.directory)
        } catch { /* 缓存缺失或设备尚未解锁时继续发现，不把历史数据错误投影为在线。 */ }
    }

    /// 断线只撤销实时查询资格；同源旧画面继续显示，显式换源/忘记才移除。
    func clearLiveDisplay(clearCached: Bool = false) {
        view.canQuerySnapshot = false; lastSnapshotQueryAt = nil
        if clearCached {
            view.snapshot = nil; view.receivedDate = nil; view.images = [:]; view.assetWarning = nil
            assetPaths = [:]
        }
        WidgetSnapshotPublisher.shared.invalidate()
    }
}
