import Foundation

/// 主线程展示投递只持有最新值与一个待执行任务，慢UI不会积压旧快照或图片引用。
final class LanProjectionDelivery<Value> {
    private let lock = NSLock()
    private var latest: Value?
    private var scheduled = false
    private let consume: @MainActor (Value) -> Void

    /// 消费者固定在主队列，网络/文件owner可从自己的串行队列提交。
    init(consume: @escaping @MainActor (Value) -> Void) { self.consume = consume }

    /// 已有待投递任务时仅替换数据，不创建另一个任务。
    func submit(_ value: Value) {
        lock.lock(); latest = value
        let start = !scheduled; scheduled = true
        lock.unlock()
        if start { DispatchQueue.main.async { self.deliver() } }
    }

    /// 取出最新值后才执行UI消费，消费期间到来的更新最多生成下一项投递。
    @MainActor private func deliver() {
        lock.lock(); let value = latest; latest = nil; scheduled = false; lock.unlock()
        if let value { consume(value) }
    }
}
