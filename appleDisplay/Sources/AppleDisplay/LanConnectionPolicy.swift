import Foundation

/// 前台自动发现和有界退避预算；首次配对仍只由用户选择开启。
struct LanConnectionPolicy {
    private(set) var requested = false
    private(set) var attempts = 0

    /// 首次进入与返回前台都发现候选，无需用户先开启，也不依赖已有配对。
    mutating func enterForeground() { requested = true; attempts = 0 }

    /// 后台暂停；重试操作本身不能在后台启动网络。
    mutating func leaveForeground() { requested = false; attempts = 0 }
    /// 明确重试刷新当前前台连接预算，不修改共享Rust的密码窗口次数。
    mutating func discover() { attempts = 0 }
    /// 真实新端点或显式选择可以开启新一轮，普通相同广告不调用此方法。
    mutating func renewedEndpoint() { attempts = 0 }
    /// 收到可信完整快照后本轮成功，下一次传输断开拥有新预算。
    mutating func connected() { attempts = 0 }
    /// 只自动选取保存过信任的在线候选；无信任和已取消的首次配对都等待用户选择。
    func automaticSelection(selectedId: String?, paired: Set<String>, available: [String]) -> String? {
        guard requested, attempts < 8 else { return nil }
        if let selectedId { return paired.contains(selectedId) && available.contains(selectedId) ? selectedId : nil }
        return available.first(where: { paired.contains($0) })
    }
    /// 最多八次新socket尝试；只有明确恢复事件可以再次开启一轮。
    mutating func nextDelay() -> Double? {
        guard requested, attempts < 8 else { return nil }
        attempts += 1
        return min(8.0, 0.5 * pow(2, Double(attempts - 1)))
    }
}

/// UIKit在主线程确定的终端形态；不从名称推断，也不声明未知设备为手机。
enum LanDeviceFormFactor: String { case phone, tablet }

/// 单条认证连接的形态上报状态，缓存快照不能调用本入口。
struct LanDeviceFormFactorReport {
    let formFactor: LanDeviceFormFactor?
    private var reported = false
    /// 宿主只传入已从系统取得的类型，未知类型保持中性。
    init(formFactor: LanDeviceFormFactor?) { self.formFactor = formFactor }
    /// 新socket或会话终止后，下一次认证必须重新取得能力广告。
    mutating func reset() { reported = false }
    /// 兼容旧桌面，并确保每个当前连接最多发一份类型报告。
    mutating func afterAuthenticatedSnapshot(_ message: [String: Any]) throws -> [String: Any]? {
        let supported = try LanHostCapabilities.supports("deviceFormFactorV1", in: message)
        guard supported, !reported, let formFactor else { return nil }
        reported = true
        return ["type": "deviceFormFactor", "formFactor": formFactor.rawValue]
    }
}
