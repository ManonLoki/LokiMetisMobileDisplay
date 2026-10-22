import Foundation
import SwiftUI
import WidgetKit

/// 共享最近认证快照；连接暂停只撤销内存租约，保留供小组件浏览的上次同步结果。
final class WidgetSnapshotPublisher {
    static let shared = WidgetSnapshotPublisher()
    private struct Work {
        let revision: UInt64; let liveRevision: UInt64; let data: Data?; let source: String; let received: Int64
        let retainLive: Bool; let completion: ((Bool) -> Void)?
        let refreshTarget: WidgetRefreshTarget?
        let phoneId: String?
    }
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "LokiMetris.widget-snapshot")
    private var revision: UInt64 = 0
    private var liveRevision: UInt64 = 0
    private var pending: Work?
    private var clearPending = false
    private var selectedSource: String?
    private var sourceCheckPending = false
    private var forgottenSources: Set<String> = []
    private var scheduled = false
    private var latest: WidgetSnapshot?
    private var lastReload: UInt64 = 0
    private var lastDisplay: WidgetDisplaySnapshot?
    /// 只把“共享写入是否成功”投递给界面，合并连续结果。
    private let delivery = LanProjectionDelivery<Bool> { shared in
        WidgetDisplayState.shared.received(shared: shared)
    }

    /// 成功解密并完整验证的快照才进入共享发布，消息覆盖积压。
    func enqueue(_ message: [String: Any], sourceId: String, phoneId: String? = nil, receivedAtMs: Int64? = nil, refreshTarget: WidgetRefreshTarget? = nil) {
        guard message["type"] as? String == "snapshot",
              let data = try? JSONSerialization.data(withJSONObject: message), data.count <= WidgetSnapshot.maxBytes else { return }
        submit(data: data, source: sourceId, phoneId: phoneId, receivedAtMs: receivedAtMs, refreshTarget: refreshTarget)
    }

    /// 后台任务只有在合法摘要写入App Group后才成功，缓存不恢复前台在线投影。
    func publishInBackground(_ message: [String: Any], sourceId: String, phoneId: String? = nil, receivedAtMs: Int64? = nil, refreshTarget: WidgetRefreshTarget? = nil, completion: @escaping (Bool) -> Void) {
        guard message["type"] as? String == "snapshot",
              let data = try? JSONSerialization.data(withJSONObject: message), data.count <= WidgetSnapshot.maxBytes else {
            completion(false); return
        }
        submit(data: data, source: sourceId, phoneId: phoneId, receivedAtMs: receivedAtMs, retainLive: false, refreshTarget: refreshTarget, completion: completion)
    }

    /// 后台与断连停止续期；明确换目标或忘记配对时才清除共享摘要。
    func invalidate(clearShared: Bool = false) {
        if clearShared { submit(data: nil, source: "", clearShared: true); return }
        // 退后台只撤销续租和 live 投影；最后一份已认证快照仍须落盘。
        lock.lock(); liveRevision &+= 1; latest = nil
        delivery.submit(true); lock.unlock()
        queue.async { self.reload(nil, force: true) }
    }

    /// 冷启动没有内存中的旧目标，也须对照共享摘要；同源重连保留，换源清除。
    func selectSource(_ id: String) { submit(data: nil, source: "", selectedSource: id) }

    /// 只清除被忘记桌面的摘要，不影响另一个桌面留下的最近同步结果。
    func forgetSource(_ id: String) { submit(data: nil, source: "", forgottenSource: id) }

    /// 所有写入请求合并为一个待处理项，后到的覆盖先到的，由串行队列统一提交。
    private func submit(data: Data?, source: String, phoneId: String? = nil, receivedAtMs: Int64? = nil, clearShared: Bool = false, selectedSource: String? = nil, forgottenSource: String? = nil,
                        retainLive: Bool = true, refreshTarget: WidgetRefreshTarget? = nil, completion: ((Bool) -> Void)? = nil) {
        lock.lock(); revision &+= 1; liveRevision &+= 1
        clearPending = clearPending || clearShared
        if let selectedSource { self.selectedSource = selectedSource; sourceCheckPending = true }
        if let forgottenSource { forgottenSources.insert(forgottenSource) }
        let superseded = pending?.completion
        pending = Work(revision: revision, liveRevision: liveRevision, data: data, source: source, received: receivedAtMs ?? Date().epochMs,
                       retainLive: retainLive, completion: completion, refreshTarget: refreshTarget, phoneId: phoneId)
        if data == nil { delivery.submit(true) }
        let start = !scheduled; scheduled = true; lock.unlock()
        superseded?(false)
        if start { queue.async { self.drain() } }
    }

    /// 心跳只续当前内存摘要，失效后的心跳或过期摘要不能重新创建历史数据。
    func renew() {
        lock.lock(); let token = revision; let liveToken = liveRevision; lock.unlock()
        queue.async {
            self.lock.lock(); defer { self.lock.unlock() }
            guard self.revision == token, self.liveRevision == liveToken,
                  let next = self.latest?.renewed(atMs: Date().epochMs) else { return }
            self.latest = next
            do { _ = try WidgetContainer.store().saveIfNotOlder(next); self.reload(next.snapshot) }
            catch { self.delivery.submit(false) }
        }
    }

    /// 依次取出待处理项：解析、校验、在文件锁内写入，再通知小组件刷新。
    private func drain() {
        while true {
            lock.lock(); let work = pending; pending = nil
            let clearShared = clearPending; clearPending = false
            let checkSource = sourceCheckPending ? selectedSource : nil; sourceCheckPending = false
            let forgotten = forgottenSources; forgottenSources = []
            if work == nil { scheduled = false }; lock.unlock()
            guard let work else { return }
            var value: WidgetSnapshot?
            var displayCache: PhoneDisplayCache?
            var shared = true
            do {
                if let data = work.data {
                    let snapshot = try WidgetSnapshot.authenticatedMessage(data, sourceId: work.source, receivedAtMs: work.received)
                    if snapshot.isCached(atMs: Date().epochMs) { value = snapshot }
                    if let phoneId = work.phoneId,
                       let message = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        let full = try LanDisplaySnapshot.decode(message)
                        let envelope = WatchSnapshotEnvelope(version: 1, phoneId: phoneId,
                            sourceId: work.source, phoneReceivedAtMs: work.received, snapshot: full)
                        displayCache = PhoneDisplayCache(envelope: envelope, summaryOnly: false)
                        try displayCache?.validate()
                    }
                }
            } catch { shared = false }
            lock.lock()
            // 检查代次与磁盘提交共用锁，清除之后不允许迟到快照写回旧来源。
            let saving = work.revision == revision ? value : nil
            do {
                // 每轮最多定位一次共享容器，清除、换源、忘记与保存按原顺序提交。
                if clearShared || checkSource != nil || !forgotten.isEmpty || saving != nil {
                    let store = try WidgetContainer.store()
                    if clearShared { try store.clear() }
                    if let checkSource { try store.selectSource(checkSource) }
                    for id in forgotten { try store.forgetSource(id) }
                    if let saving { try store.saveAuthenticatedSnapshot(saving, refreshTarget: work.refreshTarget, displayCache: displayCache) }
                }
            } catch { shared = false }
            let current = work.revision == revision
            if current {
                let keepLive = work.retainLive && work.liveRevision == liveRevision
                latest = keepLive ? value : nil
                delivery.submit(shared)
                reload(value?.snapshot, force: value == nil || !keepLive)
            } else if clearShared || checkSource != nil || !forgotten.isEmpty {
                reload(nil, force: true)
            }
            lock.unlock()
            work.completion?(current && shared && value != nil)
        }
    }

    /// 强制刷新或展示内容变化时立即请求更新；相同投影的常规请求间隔至少 30 秒。
    private func reload(_ value: WidgetDisplaySnapshot?, force: Bool = false) {
        let now = DispatchTime.now().uptimeNanoseconds
        if force || lastDisplay != value || now - lastReload >= 30_000_000_000 {
            WidgetCenter.shared.reloadTimelines(ofKind: WidgetSnapshot.kind)
            lastDisplay = value; lastReload = now
        }
    }
}

/// 展示缓存由引擎独立恢复，此对象仅披露当前共享写入结果。
@MainActor
final class WidgetDisplayState: ObservableObject {
    static let shared = WidgetDisplayState()
    @Published private(set) var sharingError = false
    private init() {}
    /// 记录本次共享结果，写入 App Group 失败时标记错误；结果未变不触发重绘。
    func received(shared: Bool) { if sharingError == shared { sharingError = !shared } }
}
