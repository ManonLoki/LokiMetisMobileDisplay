import Foundation
import SwiftUI
import WidgetKit

/// 共享最近认证快照；连接暂停只撤销内存租约，保留供小组件浏览的上次同步结果。
final class WidgetSnapshotPublisher {
    static let shared = WidgetSnapshotPublisher()
    private struct Work {
        let revision: UInt64; let data: Data?; let source: String; let received: Int64
        let retainLive: Bool; let completion: ((Bool) -> Void)?
        let refreshTarget: WidgetRefreshTarget?
    }
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "LokiMetris.widget-snapshot")
    private var revision: UInt64 = 0
    private var pending: Work?
    private var clearPending = false
    private var selectedSource: String?
    private var sourceCheckPending = false
    private var forgottenSources: Set<String> = []
    private var scheduled = false
    private var latest: WidgetSnapshot?
    private var lastReload: UInt64 = 0
    private var lastDisplay: WidgetDisplaySnapshot?
    private let delivery = LanProjectionDelivery<(WidgetSnapshot?, Bool)> { value in
        WidgetDisplayState.shared.received(value.0, shared: value.1)
    }

    /// 成功解密并完整验证的快照才进入共享发布，消息覆盖积压。
    func enqueue(_ message: [String: Any], sourceId: String, refreshTarget: WidgetRefreshTarget? = nil) {
        guard message["type"] as? String == "snapshot",
              let data = try? JSONSerialization.data(withJSONObject: message), data.count <= WidgetSnapshot.maxBytes else { return }
        submit(data: data, source: sourceId, refreshTarget: refreshTarget)
    }

    /// 后台任务只有在合法摘要写入App Group后才成功，缓存不恢复前台在线投影。
    func publishInBackground(_ message: [String: Any], sourceId: String, refreshTarget: WidgetRefreshTarget? = nil, completion: @escaping (Bool) -> Void) {
        guard message["type"] as? String == "snapshot",
              let data = try? JSONSerialization.data(withJSONObject: message), data.count <= WidgetSnapshot.maxBytes else {
            completion(false); return
        }
        submit(data: data, source: sourceId, retainLive: false, refreshTarget: refreshTarget, completion: completion)
    }

    /// 后台与断连停止续期；明确换目标或忘记配对时才清除共享摘要。
    func invalidate(clearShared: Bool = false) { submit(data: nil, source: "", clearShared: clearShared) }

    /// 冷启动没有内存中的旧目标，也须对照共享摘要；同源重连保留，换源清除。
    func selectSource(_ id: String) { submit(data: nil, source: "", selectedSource: id) }

    /// 只清除被忘记桌面的摘要，不影响另一个桌面留下的最近同步结果。
    func forgetSource(_ id: String) { submit(data: nil, source: "", forgottenSource: id) }

    private func submit(data: Data?, source: String, clearShared: Bool = false, selectedSource: String? = nil, forgottenSource: String? = nil,
                        retainLive: Bool = true, refreshTarget: WidgetRefreshTarget? = nil, completion: ((Bool) -> Void)? = nil) {
        lock.lock(); revision &+= 1
        clearPending = clearPending || clearShared
        if let selectedSource { self.selectedSource = selectedSource; sourceCheckPending = true }
        if let forgottenSource { forgottenSources.insert(forgottenSource) }
        let superseded = pending?.completion
        pending = Work(revision: revision, data: data, source: source, received: Date().epochMs,
                       retainLive: retainLive, completion: completion, refreshTarget: refreshTarget)
        if data == nil { delivery.submit((nil, true)) }
        let start = !scheduled; scheduled = true; lock.unlock()
        superseded?(false)
        if start { queue.async { self.drain() } }
    }

    /// 心跳只续当前内存摘要，失效后的心跳或过期摘要不能重新创建历史数据。
    func renew() {
        lock.lock(); let token = revision; lock.unlock()
        queue.async {
            self.lock.lock(); let current = self.revision == token; self.lock.unlock()
            guard current, let next = self.latest?.renewed(atMs: Date().epochMs) else { return }
            self.lock.lock(); defer { self.lock.unlock() }
            guard self.revision == token else { return }
            self.latest = next
            do { _ = try WidgetContainer.store().saveIfNotOlder(next); self.reload(next.snapshot) }
            catch { self.delivery.submit((next, false)) }
        }
    }

    private func drain() {
        while true {
            lock.lock(); let work = pending; pending = nil
            let clearShared = clearPending; clearPending = false
            let checkSource = sourceCheckPending ? selectedSource : nil; sourceCheckPending = false
            let forgotten = forgottenSources; forgottenSources = []
            if work == nil { scheduled = false }; lock.unlock()
            guard let work else { return }
            var value: WidgetSnapshot?
            var shared = true
            do {
                if let data = work.data {
                    let snapshot = try WidgetSnapshot.authenticatedMessage(data, sourceId: work.source, receivedAtMs: work.received)
                    if snapshot.isLive(atMs: Date().epochMs) { value = snapshot }
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
                    if let saving { try store.saveAuthenticatedSnapshot(saving, refreshTarget: work.refreshTarget) }
                }
            } catch { shared = false }
            let current = work.revision == revision
            if current {
                latest = work.retainLive ? value : nil
                delivery.submit((work.retainLive ? value : nil, shared))
                reload(value?.snapshot, force: value == nil || !work.retainLive)
            } else if clearShared || checkSource != nil || !forgotten.isEmpty {
                reload(nil, force: true)
            }
            lock.unlock()
            work.completion?(current && shared && value != nil)
        }
    }

    /// 暂停立即请求读取上次同步结果；持续连接最多每30秒请求更新。
    private func reload(_ value: WidgetDisplaySnapshot?, force: Bool = false) {
        let now = DispatchTime.now().uptimeNanoseconds
        if force || lastDisplay != value || now - lastReload >= 30_000_000_000 {
            WidgetCenter.shared.reloadTimelines(ofKind: WidgetSnapshot.kind)
            lastDisplay = value; lastReload = now
        }
    }
}

/// 主App不再从App Group恢复展示数据，此对象仅披露当前共享结果。
@MainActor
final class WidgetDisplayState: ObservableObject {
    static let shared = WidgetDisplayState()
    @Published private(set) var snapshot: WidgetSnapshot?
    @Published private(set) var sharingError = false
    private init() {}
    /// 记录本次共享结果，写入 App Group 失败时标记错误。
    func received(_ value: WidgetSnapshot?, shared: Bool) { snapshot = value; sharingError = !shared }
}
