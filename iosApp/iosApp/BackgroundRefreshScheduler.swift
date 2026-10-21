import BackgroundTasks
import UIKit

/// 系统决定实际唤醒时间；`WidgetSnapshot.refreshInterval`（15 分钟）只是下一次允许执行的最早时间。
@MainActor
final class BackgroundRefreshScheduler {
    static let shared = BackgroundRefreshScheduler()
    static let taskIdentifier = "com.manonloki.lokimetrisdisplay.widget-refresh"

    private var registered = false
    private var model: LanLinkModel?
    private var running: RefreshExecution?

    private init() {}

    /// 在 App 构造阶段注册，确保冷启动收到后台任务时已有 handler。
    func register() {
        guard !registered else { return }
        registered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.taskIdentifier,
            using: .main
        ) { [weak self] task in
            guard let task = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            let execution = RefreshExecution(task: task)
            task.expirationHandler = { [weak self, execution] in
                // 到期可能来自其他队列，先同步记录，避免排到主线程前继续开始网络。
                guard execution.markExpired() else { return }
                Task { @MainActor [weak self] in
                    guard let self else {
                        execution.complete(success: false)
                        return
                    }
                    self.expire(execution)
                }
            }
            Task { @MainActor [weak self] in
                guard let self else {
                    execution.complete(success: false)
                    return
                }
                self.refresh(execution)
            }
        }
    }

    /// 绑定唯一 LAN owner；未配置时后台任务直接以失败结束。
    func configure(model: LanLinkModel) {
        self.model = model
    }

    /// 相同 identifier 的提交会替换原请求，所以始终最多保留一个待执行刷新。
    func scheduleNextRefresh() {
        guard registered, UIApplication.shared.backgroundRefreshStatus == .available else { return }
        let request = BGAppRefreshTaskRequest(identifier: Self.taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: WidgetSnapshot.refreshInterval)
        // 系统关闭后台刷新、配额暂满等情况无需向用户报错；下次后台转换会再申请。
        try? BGTaskScheduler.shared.submit(request)
    }

    private func refresh(_ execution: RefreshExecution) {
        // 尽早登记后续任务，保证本次成功、离线或到期后都仍有下一次机会。
        scheduleNextRefresh()
        guard !execution.isExpiredOrComplete, let model else {
            execution.complete(success: false)
            return
        }
        if let previous = running {
            running = nil
            previous.awaitCleanup()
            model.cancelBackgroundRefresh { previous.completeAfterCleanup() }
        }
        running = execution
        model.refreshInBackground { [weak self, execution] success in
            guard let self, self.running === execution else {
                execution.complete(success: false)
                return
            }
            self.running = nil
            execution.complete(success: success)
        }
    }

    private func expire(_ execution: RefreshExecution) {
        if running === execution {
            running = nil
            if let model {
                // 串行网络 owner 清理结束后再通知系统，避免清理尚未执行就被挂起。
                execution.awaitCleanup()
                model.cancelBackgroundRefresh { execution.completeAfterCleanup() }
                return
            }
        }
        execution.complete(success: false)
    }
}

/// 只有到期标记跨队列；锁同时保证系统 completion 在正常结束和到期竞态中只调用一次。
private final class RefreshExecution: @unchecked Sendable {
    private let task: BGAppRefreshTask
    private let lock = NSLock()
    private var expired = false
    private var completed = false
    private var awaitingCleanup = false

    init(task: BGAppRefreshTask) { self.task = task }

    var isExpiredOrComplete: Bool {
        lock.lock()
        defer { lock.unlock() }
        return expired || completed
    }

    /// 记录系统到期；已完成则返回 false，避免重复处理。
    func markExpired() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !completed else { return false }
        expired = true
        return true
    }

    /// 标记需等待旧连接清理，期间拦截迟到的完成回调。
    func awaitCleanup() {
        lock.lock()
        awaitingCleanup = true
        lock.unlock()
    }

    /// 清理结束后解除拦截，并以失败结束被替换的任务。
    func completeAfterCleanup() {
        lock.lock()
        awaitingCleanup = false
        lock.unlock()
        complete(success: false)
    }

    /// 保证系统 completion 只调用一次；已到期一律按失败上报。
    func complete(success: Bool) {
        lock.lock()
        // 被替换的旧任务仍可能到期或收到迟到回调；它们必须让已请求的清理先完成。
        guard !completed, !awaitingCleanup else {
            lock.unlock()
            return
        }
        completed = true
        let result = success && !expired
        lock.unlock()
        task.expirationHandler = nil
        task.setTaskCompleted(success: result)
    }
}
