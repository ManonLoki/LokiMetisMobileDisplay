import Foundation

/// 组件只保留展示投影，密码、Hook正文、图片和本机路径都没有可编码字段。
struct WidgetSnapshot: Codable, Equatable {
    static let kind = "LokiMetrisDisplay.Summary"
    static let maxBytes = 64 * 1024
    let schemaVersion: Int
    let sourceId: String
    let receivedAtMs: Int64
    let snapshot: WidgetDisplaySnapshot
    /// 仅当前认证连接可续期；租约到期后仍可作为最近同步摘要展示。
    var validUntilMs: Int64? = nil
    static let leaseMs: Int64 = 45_000
    /// BGAppRefresh 与 Timeline 统一申请 15 分钟间隔；实际唤醒仍由系统调度。
    static let refreshInterval: TimeInterval = 15 * 60

    /// 仅由成功解密的snapshot消息创建；解析失败不能触发文件覆盖。
    static func authenticatedMessage(_ data: Data, sourceId: String, receivedAtMs: Int64) throws -> Self {
        guard data.count <= maxBytes, receivedAtMs >= 0, receivedAtMs <= Int64.max - leaseMs else { throw WidgetSnapshotError.invalid }
        let message = try SharedJSON.decoder.decode(WidgetWireMessage.self, from: data)
        guard message.type == "snapshot" else { throw WidgetSnapshotError.invalid }
        let value = Self(schemaVersion: 2, sourceId: sourceId, receivedAtMs: receivedAtMs, snapshot: message.snapshot, validUntilMs: receivedAtMs + leaseMs)
        try value.validate()
        return value
    }

    /// 缓存与网络入口共用边界检查，未来格式与损坏值不能冒充当前事实。
    func validate() throws {
        guard schemaVersion == 2, receivedAtMs >= 0, receivedAtMs <= Int64.max - Self.leaseMs,
              let validUntilMs, validUntilMs >= receivedAtMs + Self.leaseMs,
              SharedValidation.isCanonicalUUID(sourceId) else { throw WidgetSnapshotError.invalid }
        try snapshot.validate()
    }

    /// 最近摘要不因断连或跨日消失；未来接收时间与超出正常租约的未来期限不可信。
    func isCached(atMs now: Int64) -> Bool {
        guard (try? validate()) != nil, now >= receivedAtMs, let validUntilMs else { return false }
        return validUntilMs <= now || validUntilMs - now <= Self.leaseMs
    }

    /// 当前连接仍要求45秒租约；可展示缓存不代表可以恢复认证连接的续期资格。
    func isLive(atMs now: Int64) -> Bool {
        guard isCached(atMs: now), let validUntilMs else { return false }
        return validUntilMs > now
    }
    /// 只有当前认证连接的心跳续摘要租约，旧快照本身不产生在线证明。
    func renewed(atMs now: Int64) -> Self? {
        guard isLive(atMs: now), now <= Int64.max - Self.leaseMs else { return nil }
        var next = self; next.validUntilMs = now + Self.leaseMs; return next
    }
    /// 保留真实接收时间，跨日缓存也不会被重新标作今日同步。
    var receivedDate: Date { Date(epochMs: receivedAtMs) }
}

/// App、组件与 Watch 共用的毫秒时间戳换算，避免各处重复手写截断规则。
extension Date {
    init(epochMs: Int64) { self.init(timeIntervalSince1970: Double(epochMs) / 1000) }
    var epochMs: Int64 { Int64(timeIntervalSince1970 * 1000) }
}

/// 组件与 Watch 共用的中文同步时间格式；静态保存，避免视图每次渲染重建 Locale。
enum SyncTimeFormat {
    static let locale = Locale(identifier: "zh_CN")
    /// 读屏使用的完整年月日时分。
    static let full = Date.FormatStyle.dateTime.locale(locale).year().month().day().hour().minute()
    /// 空间有限时省略年份。
    static let short = Date.FormatStyle.dateTime.locale(locale).month().day().hour().minute()
}

/// 线协议外壳只取snapshot，其他消息不参与组件持久化。
private struct WidgetWireMessage: Decodable {
    let type: String
    let snapshot: WidgetDisplaySnapshot
}

/// 稳定错误不含原始数据、密码或文件路径。
enum WidgetSnapshotError: Error { case invalid, unavailable, tooLarge }

/// 桌面完整快照投影；未知字段被丢弃，Hook释放用完整列表中的缺项表达。
struct WidgetDisplaySnapshot: Codable, Equatable {
    let version: Int
    let tokens: WidgetTokens?
    let tokenError: String?
    let hooksAvailable: Bool
    let hooks: [WidgetHook]
    var providerQuota: ProviderQuotaSnapshot? = nil

    /// 组件只接受当前版本、有界槽位以及一致的Token质量值。
    func validate() throws {
        guard version == 1, hooks.count <= 12,
              Set(hooks.map(\.slot)).count == hooks.count,
              hooks.allSatisfy({ (1...12).contains($0.slot) && $0.agent.utf8.count <= 64 && !$0.agent.isEmpty }),
              hooksAvailable || hooks.isEmpty, tokenError == nil || tokens == nil else { throw WidgetSnapshotError.invalid }
        try tokens?.validate()
        try providerQuota?.validate()
    }

    /// 数量描述最近收到的摘要，不代表当前仍在线。
    var hooksText: String { hooksAvailable ? "Hooks \(hooks.count)" : "Hooks 未同步" }
}

/// u64十进制字符串贯穿缓存与UI，不经Double导致大数损失。
struct WidgetAmount: Codable, Equatable {
    /// 值缺失原因与合法的零用量明确区分。
    enum Availability: String, Codable { case available, noRecords, unavailable }
    /// 共享桌面统计覆盖资格，不由小组件重新估计。
    enum Completeness: String, Codable { case complete, partial, unknown }
    /// 原始、推算和疑似冲突结果各自保留。
    enum Confidence: String, Codable { case exact, derived, suspected }
    let total: String?
    let availability: Availability
    let completeness: Completeness
    let confidence: Confidence

    /// 缺值不伪造零，拒绝非规范整数和越界值。
    func validate() throws {
        if availability == .available {
            guard let total, UInt64(total) != nil,
                  total.range(of: "^(0|[1-9][0-9]{0,19})$", options: .regularExpression) != nil else {
                throw WidgetSnapshotError.invalid
            }
        } else if total != nil { throw WidgetSnapshotError.invalid }
    }

    /// 所有尺寸共用精确显示语义；小尺寸仅通过SwiftUI缩放，不截断数字。
    var text: String {
        switch availability {
        case .available: return total ?? "—"
        case .noRecords: return "无记录"
        case .unavailable: return "不可用"
        }
    }

    var hasNumericValue: Bool { availability == .available && total != nil }
    var compactText: String { TokenNumber.compact(text) }
    var exactText: String { TokenNumber.grouped(text) }

    /// 部分、未知覆盖和推算/冲突均保留在小组件中，避免误读为精确总量。
    var quality: String {
        var parts: [String] = []
        if completeness == .partial { parts.append("部分") }
        if completeness == .unknown { parts.append("范围未知") }
        if confidence == .derived { parts.append("估算") }
        if confidence == .suspected { parts.append("待核对") }
        return parts.joined(separator: "·")
    }
}

/// 同轮总量与分量保留桌面的日期/时区，跨日后也不会标作“今日”。
struct WidgetTokens: Codable, Equatable {
    /// 日期与日界均来自同轮桌面统计，组件不替换时区。
    struct Day: Codable, Equatable {
        let date: String
        let zone: String
        let startMs: Int64
        let endMs: Int64
    }
    /// 单个Agent的数字与质量保持绑定。
    struct Agent: Codable, Equatable {
        let agent: String
        let amount: WidgetAmount
        var displayName: String { agentDisplayName(agent) }
    }
    let day: Day
    let observedMs: Int64
    let all: WidgetAmount
    let agents: [Agent]

    /// 非法日界、重复Agent或未知质量不进入组件；不重算桌面统计口径。
    func validate() throws {
        guard day.date.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}$", options: .regularExpression) != nil,
              day.zone.utf8.count <= 256, day.startMs < day.endMs,
              day.startMs <= observedMs, observedMs < day.endMs,
              agents.count <= 14, Set(agents.map(\.agent)).count == agents.count,
              agents.allSatisfy({ !$0.agent.isEmpty && $0.agent.utf8.count <= 64 }) else { throw WidgetSnapshotError.invalid }
        try all.validate()
        try agents.forEach { try $0.amount.validate() }
    }
}

/// 只规范展示名；网络标识与自定义名称保持原样。
func agentDisplayName(_ raw: String) -> String {
    switch normalizedAgentName(raw) {
    case "codex": "Codex"
    case "claude", "claudecode": "Claude Code"
    case "grok", "grokbuild": "Grok"
    case "workbuddy": "WorkBuddy"
    case "cursor": "Cursor"
    case "opencode": "OpenCode"
    case "hermes": "Hermes"
    case "openclaw": "OpenClaw"
    case "codebuddy": "CodeBuddy"
    case "qwencode": "Qwen Code"
    case "kimicode": "Kimi Code"
    case "qoder": "Qoder"
    case "gemini", "geminicli": "Gemini CLI"
    case "githubcopilot", "githubcopilotcli": "GitHub Copilot"
    default: raw
    }
}

/// 缺少接口的Agent不匹配到其他账户的额度。
func providerQuotaKey(for agent: String) -> String? {
    switch normalizedAgentName(agent) {
    case "codex": "codex"
    case "claude", "claudecode": "claude"
    case "cursor": "cursor"
    case "grok", "grokbuild": "grok"
    default: nil
    }
}

private func normalizedAgentName(_ raw: String) -> String {
    raw.lowercased().filter { !$0.isWhitespace && $0 != "_" && $0 != "-" }
}

/// 只共享Agent与四态，不共享可能含敏感信息的Hook正文和图片。
struct WidgetHook: Codable, Equatable {
    /// 四态只表示缓存中被接受的展示结果。
    enum Behavior: String, Codable {
        case idle, running, asking, error
        /// 中文状态明确用于缓存摘要，不意味着当前仍在执行。
        var label: String {
            switch self { case .idle: return "空闲"; case .running: return "运行"; case .asking: return "询问"; case .error: return "出错" }
        }
    }
    let agent: String
    let slot: Int
    let behavior: Behavior
}

/// 仅用于展示：整数商余取舍，不改动存储的 UInt64 原值。
enum TokenNumber {
    /// 纯数字字符串按千位加逗号；非数字原样返回。
    static func grouped(_ raw: String) -> String {
        guard !raw.isEmpty, raw.utf8.allSatisfy({ (48...57).contains($0) }) else { return raw }
        return raw.reversed().enumerated().map {
            $0.offset > 0 && $0.offset % 3 == 0 ? String($0.element) + "," : String($0.element)
        }.reversed().joined()
    }

    /// 千以上缩写为 K/M/B，仅用整数运算避免精度损失。
    static func compact(_ raw: String) -> String {
        guard !raw.isEmpty, raw.utf8.allSatisfy({ (48...57).contains($0) }),
              let value = UInt64(raw), value >= 1_000 else { return raw }
        let divisors: [UInt64] = [1_000, 1_000_000, 1_000_000_000]
        let suffixes = ["K", "M", "B"]
        var unit = value >= divisors[2] ? 2 : value >= divisors[1] ? 1 : 0
        while true {
            let divisor = divisors[unit]
            var whole = value / divisor
            // Remainder < 1e9, so scaling it cannot overflow even for UInt64.max.
            var hundredths = ((value % divisor) * 100 + divisor / 2) / divisor
            if hundredths == 100 { whole += 1; hundredths = 0 }
            if whole >= 1_000 && unit < 2 { unit += 1; continue }
            let fraction: String
            if hundredths == 0 { fraction = "" }
            else if hundredths % 10 == 0 { fraction = "." + String(hundredths / 10) }
            else { fraction = "." + (hundredths < 10 ? "0" : "") + String(hundredths) }
            return String(whole) + fraction + suffixes[unit]
        }
    }
}


/// 所有Apple终端接收同一份有界额度投影，不接收提供商登录材料。
struct ProviderQuotaSnapshot: Codable, Equatable {
    let observedAtUnix: Int64
    let providers: [ProviderQuotaEntry]
    /// 上游实际观测时间，与手机收到快照的时间分开显示。
    var observedDate: Date { Date(timeIntervalSince1970: TimeInterval(observedAtUnix)) }
    func validate() throws {
        let order = ["codex", "claude", "cursor", "grok"]
        guard observedAtUnix >= 0, providers.count <= order.count else { throw WidgetSnapshotError.invalid }
        var previous = -1
        for provider in providers {
            guard let index = order.firstIndex(of: provider.provider), index > previous else { throw WidgetSnapshotError.invalid }
            previous = index
            try provider.validate()
        }
    }
}

/// 五小时、周与月额度独立缺省，周或月额度不能因缺少短窗而消失；月额度只由 Cursor 提供。
struct ProviderQuotaEntry: Codable, Equatable {
    let provider: String
    let plan: String?
    let fiveHour: ProviderQuotaWindow?
    let weekly: ProviderQuotaWindow?
    /// 旧快照没有此字段，解码为空。
    var monthly: ProviderQuotaWindow? = nil
    var label: String { switch provider { case "codex": "Codex"; case "claude": "Claude"; case "cursor": "Cursor"; default: "Grok" } }
    /// 所有面板共用的展示顺序：每月、每周、5h，缺失窗口跳过。
    var windows: [ProviderQuotaWindow] { [monthly, weekly, fiveHour].compactMap { $0 } }
    var displayName: String { plan.map { "\(label) · \($0)" } ?? label }
    func validate() throws {
        guard !windows.isEmpty else { throw WidgetSnapshotError.invalid }
        if let plan {
            guard !plan.isEmpty, plan.utf8.count <= 24,
                  plan.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [32, 95, 45, 46].contains($0) }) else { throw WidgetSnapshotError.invalid }
        }
        try fiveHour?.validate(kind: "fiveHour"); try weekly?.validate(kind: "weekly"); try monthly?.validate(kind: "monthly")
    }
}

/// 以整数千分比保存上游已用比例，0%余额仍为有效数据。
struct ProviderQuotaWindow: Codable, Equatable {
    let kind: String
    let usedTenths: Int
    let resetAtUnix: Int64?
    var label: String { switch kind { case "monthly": "每月"; case "weekly": "每周"; default: "5h" } }
    var resetDate: Date? { resetAtUnix.map { Date(timeIntervalSince1970: TimeInterval($0)) } }
    var remainingTenths: Int { 1000 - usedTenths }
    var percentText: String { remainingTenths % 10 == 0 ? "\(remainingTenths / 10)%" : "\(remainingTenths / 10).\(remainingTenths % 10)%" }
    var level: Int { remainingTenths <= 200 ? 0 : remainingTenths <= 500 ? 1 : 2 }
    func validate(kind expected: String) throws {
        guard kind == expected, (0...1000).contains(usedTenths), resetAtUnix.map({ $0 >= 0 }) ?? true else { throw WidgetSnapshotError.invalid }
    }
}
