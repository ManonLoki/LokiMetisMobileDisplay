import Foundation
import Network

/// 发现、配对、认证与重试：所有方法都在引擎串行队列上执行。
extension LanLinkEngine {
    /// 信任列表变化后就地刷新候选的配对标记，不重建发现结果。
    func refreshPairedHosts() {
        for index in view.hosts.indices { view.hosts[index].paired = paired.contains(view.hosts[index].id) }
    }

    /// 只浏览局域网宿主服务，TXT没有授信作用，也不接受广告携带的URL或固定IP。
    func startBrowser() {
        guard active, intent.requested, browser == nil else { return }
        let parameters = NWParameters.tcp; parameters.includePeerToPeer = false
        let source = NWBrowser(for: .bonjourWithTXTRecord(type: "_loki-host._tcp", domain: "local."), using: parameters)
        browser = source
        if socket == nil { view.status = "正在发现桌面端…" }
        source.stateUpdateHandler = { [weak self, weak source] state in
            guard let self, let source, self.browser === source else { return }
            if case .ready = state { self.view.error = nil; self.publish() }
            if case .failed = state { self.browser = nil; self.view.error = "发现失败，请检查本地网络权限和 Wi-Fi 后重试。"; self.publish() }
            if case .waiting = state { self.view.error = "本地网络暂不可用，请检查系统权限与 Wi-Fi。"; self.publish() }
        }
        source.browseResultsChangedHandler = { [weak self, weak source] results, changes in
            guard let self, let source, self.browser === source else { return }
            if let selected = self.view.selectedId, self.paired.contains(selected), self.socket == nil,
               changes.contains(where: { change in
                   switch change {
                   case .added(let result), .changed(_, let result, _):
                       if case .bonjour(let record) = result.metadata { return record["id"] == selected }
                       return false
                   default: return false
                   }
               }) { self.intent.renewedEndpoint() }
            self.browsed(results)
        }
        source.start(queue: queue)
        browsed(source.browseResults)
        if timer == nil {
            let clock = DispatchSource.makeTimerSource(queue: queue)
            clock.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(250))
            clock.setEventHandler { [weak self] in self?.tick() }
            timer = clock; clock.resume()
        }
    }

    /// 重复声明同一UUID的广告拒绝自动选取，防止错误广告替换正在认证的对端。
    func browsed(_ results: Set<NWBrowser.Result>) {
        var found: [String: (String, NWEndpoint)] = [:]; var duplicates: Set<String> = []
        for result in results.prefix(128) {
            guard case .bonjour(let record) = result.metadata, record["v"] == "1", let id = record["id"],
                  SharedValidation.validId(id), id != deviceId, let name = record["name"],
                  !name.isEmpty, name.utf8.count <= 160, !SharedValidation.containsControl(name) else { continue }
            if found[id] != nil { duplicates.insert(id) }
            found[id] = (name, result.endpoint)
        }
        for id in duplicates { found.removeValue(forKey: id) }
        endpoints = found.mapValues { $0.1 }
        view.hosts = found.keys.sorted().prefix(64).map { LanHost(id: $0, name: found[$0]!.0, paired: paired.contains($0)) }
        view.hosts += paired.subtracting(found.keys).sorted().map {
            LanHost(id: $0, name: "已配对桌面 · " + $0.prefix(8), paired: true, available: false)
        }
        if socket == nil, retry == nil, active,
           let id = intent.automaticSelection(selectedId: view.selectedId, paired: paired, available: view.hosts.filter(\.available).map(\.id)) {
            if view.selectedId == id { resumeSelected() } else { selectNow(id) }
        }
        publish()
    }

    /// 新的显式选择关闭旧窗口；相同窗口内的网络重试始终复用同一个bridge与offer。
    func selectNow(_ id: String) {
        guard active, intent.requested, endpoints[id] != nil else { return }
        do {
            let previous: BackgroundTarget?
            do { previous = try backgroundTargets.load() }
            catch { try backgroundTargets.reset(); previous = nil }
            if let previous, previous.id != id { try backgroundTargets.forget(previous.id) }
        } catch {
            view.error = "未能更新后台刷新目标，请检查存储空间后重试。"; publish(); return
        }
        WidgetSnapshotPublisher.shared.selectSource(id)
        cancelSession(); view.selectedId = id; view.error = nil; intent.connected()
        do {
            bridge = try NativeLinkBridge(deviceId: deviceId, name: name)
            cache = try? IOSAssetCache()
            if try store.load(id) != nil { resumeSelected() }
            else {
                let opened = try bridge!.call(["op": "openPairing", "clientId": id])
                guard let code = opened["code"] as? String, let offer = opened["offer"] as? [String: Any] else { throw WidgetSnapshotError.invalid }
                self.offer = offer; view.pairingCode = code
                pairingDeadline = now + 60_000_000_000
                connect(pairing: true)
            }
        } catch { fail(retry: false, message: "无法开始连接，请检查设备身份或配对存储后重试。") }
        publish()
    }

    /// 保存后另建新socket认证；桌面保存尚在进行时用同一凭据有界退避。
    func resumeSelected() {
        guard (active && intent.requested) || backgroundRun != nil,
              let id = view.selectedId, endpoints[id] != nil else { return }
        do {
            if bridge == nil { bridge = try NativeLinkBridge(deviceId: deviceId, name: name) }
            guard let material = try store.load(id), let secret = material["secret"] as? String else { throw WidgetSnapshotError.invalid }
            offer = try bridge!.call(["op": "resume", "clientId": id, "secret": secret])["introduction"] as? [String: Any]
            guard offer != nil else { throw WidgetSnapshotError.invalid }
            if active, cache == nil { cache = try? IOSAssetCache() }
            connect(pairing: false)
        } catch { fail(retry: false, message: "无法读取配对凭据，请解锁后重试，或忘记此桌面后重新配对。") }
    }

    /// 一次只拥有一个连接，代次过滤所有旧socket与迟到写入回调。
    func connect(pairing: Bool) {
        clearLiveDisplay()
        guard let id = view.selectedId, let endpoint = endpoints[id], let offer else { return }
        socket?.close(); socket = nil; generation &+= 1; resetWatchProjection()
        failedAssets = []; view.assetWarning = cache == nil ? "图片缓存暂不可用，连接仍可同步文字与用量。" : nil
        let token = generation
        phase = pairing ? .pairHello : .resumeReply; deadline = now + 15_000_000_000
        view.status = pairing ? "等待在桌面输入手机配对码" : "正在认证桌面…"; view.connected = false
        let connection = LanSocket(endpoint: endpoint, queue: queue,
            limit: { [weak self] in (self?.phase == .streaming || self?.phase == .pausing) ? 98304 : 4096 },
            ready: { [weak self] in
                guard let self, self.generation == token else { return }
                do {
                    if pairing { self.deadline = self.pairingDeadline }
                    try self.socket?.send(offer, limit: 4096)
                } catch { self.fail(retry: true, message: "连接中断，正在重新发现桌面…") }
            }, frame: { [weak self] frame in
                guard let self, self.generation == token else { return }
                try self.received(frame)
            }, ended: { [weak self] reason in
                guard let self, self.generation == token else { return }
                if self.backgroundRun != nil, self.phase == .pausing { return }
                if self.phase == .pairClose { self.pairingCompleted(); return }
                self.fail(retry: reason != .invalid, message: reason == .invalid ? "认证或消息校验失败，请重试或重新配对。" : "连接中断，正在等待桌面恢复…")
            })
        socket = connection; connection.start(); setTickActive(true); publish()
    }

    /// 线帧只发送核心返回的内部对象，元信息没有type包装且不自报IP。
    func received(_ json: [String: Any]) throws {
        guard let bridge, let socket else { throw WidgetSnapshotError.invalid }
        switch phase {
        case .pairHello:
            let reply = try bridge.call(["op": "pairHello", "hello": json])
            guard let value = reply["reply"] as? [String: Any] else { throw WidgetSnapshotError.invalid }
            phase = .pairConfirmation; deadline = min(pairingDeadline ?? now, now + 15_000_000_000)
            try socket.send(value, limit: 4096)
        case .pairConfirmation:
            let pending = try bridge.call(["op": "pairConfirmation", "confirmation": json])
            guard let material = pending["material"] as? [String: Any], let commit = pending["commitId"] as? String else { throw WidgetSnapshotError.invalid }
            _ = try bridge.call(["op": "checkCommit", "commitId": commit])
            let saved = (try? store.save(material)) == true
            if saved, let id = material["clientId"] as? String {
                paired.insert(id)
                refreshPairedHosts()
                publish() // 即使随后过期留下单边记录，用户也能显式忘记后重新配对。
            }
            let result = try bridge.call(["op": "pairingStored", "commitId": commit, "stored": saved])
            guard let ack = result["ack"] as? [String: Any] else { throw WidgetSnapshotError.invalid }
            phase = .pairClose; deadline = now + 3_000_000_000
            try socket.send(ack, limit: 4096)
        case .resumeReply:
            let result = try bridge.call(["op": "resumeReply", "reply": json])
            guard let confirmation = result["confirmation"] as? [String: Any] else { throw WidgetSnapshotError.invalid }
            phase = .metadata
            let token = generation
            try socket.send(confirmation, limit: 4096) { [weak self] in
                guard let self, self.generation == token else { return }
                do {
                    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
                    try self.sendSecure(["deviceId": self.deviceId, "name": self.name, "platform": "ios", "appVersion": version])
                    self.phase = .streaming; self.lastInbound = self.now
                } catch { self.fail(retry: false, message: "无法发送设备信息，请重试。") }
            }
        case .streaming:
            let result = try bridge.call(["op": "open", "packet": json])
            guard let message = result["message"] as? [String: Any], let type = message["type"] as? String else { throw WidgetSnapshotError.invalid }
            lastInbound = now
            switch type {
            case "ping":
                WidgetSnapshotPublisher.shared.renew()
                guard let nonce = message["nonce"] as? NSNumber, CFGetTypeID(nonce) != CFBooleanGetTypeID() else { throw WidgetSnapshotError.invalid }
                try sendSecure(["type": "pong", "nonce": nonce])
                watchNonce = nonce; try reportWatch()
            case "snapshot": try acceptSnapshot(message)
            case "assetChunk":
                guard let chunk = message["chunk"] as? [String: Any] else { throw WidgetSnapshotError.invalid }
                try acceptAsset(chunk)
            case "assetUnavailable":
                guard let hash = message["hash"] as? String, hash == currentAsset?.hash else { throw WidgetSnapshotError.invalid }
                failedAssets.insert(hash); dropCurrentAsset(); try nextAsset()
            default: throw WidgetSnapshotError.invalid
            }
        case .pausing: break
        default: throw WidgetSnapshotError.invalid
        }
    }

    /// 首次配对socket收尾后才恢复；手机已保存不等于桌面已保存或当前已经在线。
    func pairingCompleted() {
        if let id = view.selectedId { paired.insert(id) }
        offer = nil; pairingDeadline = nil; view.pairingCode = nil
        socket?.close(); socket = nil; phase = .idle; deadline = nil
        scheduleRetry()
    }

    /// 同一已认证通道序号仅由共享Rust消费，写失败不能在原socket重发。
    func sendSecure(_ message: [String: Any], completion: @escaping () -> Void = {}) throws {
        guard let bridge, let socket,
              let packet = try bridge.call(["op": "seal", "message": message])["packet"] as? [String: Any] else { throw WidgetSnapshotError.invalid }
        try socket.send(packet, limit: 98304, completion: completion)
    }

    /// 单调期限覆盖配对、首次快照、心跳和单资源等待，不靠发送成功宣称在线。
    func tick() {
        if socket == nil, pairingDeadline == nil, deadline == nil, assetDeadline == nil { setTickActive(false); return }
        if let pairingDeadline, now >= pairingDeadline { fail(retry: false, message: "配对窗口已过期，请重新选择桌面开启新配对。"); return }
        if let deadline, now >= deadline {
            if phase == .pairClose { pairingCompleted() }
            else { fail(retry: true, message: "连接超时，正在等待桌面恢复…") }
            return
        }
        if phase == .streaming, now - lastInbound >= 45_000_000_000 { fail(retry: true, message: "桌面暂不可达，恢复网络后重新连接。"); return }
        if let assetDeadline, now >= assetDeadline, let currentAsset {
            failedAssets.insert(currentAsset.hash); dropCurrentAsset()
            view.assetWarning = "部分图片接收超时，重新连接后可补取。"; publish()
            // 旧响应仍可能在途，关闭并重新认证，避免它与下一资源接收器混合。
            fail(retry: true, message: "图片响应超时，正在恢复连接…")
        }
    }

    /// 网络重试有限且不重开密码窗口，mDNS更新与前台恢复会重新获取最新地址。
    func scheduleRetry() {
        guard active, let delay = intent.nextDelay() else { view.status = "暂未连接，请重新选择桌面重试"; publish(); return }
        retry?.cancel()
        let task = DispatchWorkItem { [weak self] in
            guard let self else { return }; self.retry = nil
            guard self.active, self.intent.requested else { return }
            if self.pairingDeadline != nil { self.connect(pairing: true) }
            else { self.resumeSelected() }
        }
        retry = task; queue.asyncAfter(deadline: .now() + delay, execute: task)
    }

    /// 协议/认证失败保留信任供用户显式处理，传输失败才在新socket进行恢复。
    func fail(retry shouldRetry: Bool, message: String) {
        if backgroundRun != nil { finishBackgroundRefresh(success: false); return }
        clearLiveDisplay()
        retry?.cancel(); retry = nil
        resetWatchProjection()
        generation &+= 1; socket?.close(); socket = nil; dropCurrentAsset()
        _ = try? bridge?.call(["op": "disconnect"])
        phase = .idle; deadline = nil; view.connected = false; view.error = message; view.status = "暂未连接"
        watch.setParent(active: false, generation: generation)
        if shouldRetry { scheduleRetry() }
        else { _ = try? bridge?.call(["op": "cancelPairing"]); pairingDeadline = nil; view.pairingCode = nil; offer = nil }
        publish()
    }

    /// 后台或切换桌面关闭整个密码窗口，清空实时投影；图片缓存与配对关系继续保留。
    func cancelSession() {
        clearLiveDisplay()
        resetWatchProjection()
        generation &+= 1; retry?.cancel(); retry = nil
        socket?.close(); socket = nil; _ = try? bridge?.call(["op": "cancelPairing"]); bridge?.close(); bridge = nil
        dropCurrentAsset(); pairingDeadline = nil; deadline = nil; offer = nil
        failedAssets = []; phase = .idle; view.pairingCode = nil; view.connected = false
        watch.setParent(active: false, generation: generation)
    }
}
