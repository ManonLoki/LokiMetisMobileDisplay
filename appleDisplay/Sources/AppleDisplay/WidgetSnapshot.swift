import Foundation
import SharedLogic

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
    static let leaseMs: Int64 = SnapshotFreshnessPolicy.shared.LEASE_MS
    /// BGAppRefresh 与 Timeline 统一申请 5 分钟目标间隔；实际唤醒仍由系统调度。
    static let refreshInterval: TimeInterval = 5 * 60

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
        guard schemaVersion == 2,
              SnapshotFreshnessPolicy.shared.validLease(receivedAtMs: receivedAtMs, validUntilMs: validUntilMs ?? -1),
              SharedValidation.isCanonicalUUID(sourceId) else { throw WidgetSnapshotError.invalid }
        try snapshot.validate()
    }

    /// 最近摘要不因断连或跨日消失；未来接收时间与超出正常租约的未来期限不可信。
    func isCached(atMs now: Int64) -> Bool {
        guard (try? validate()) != nil else { return false }
        return SnapshotFreshnessPolicy.shared.isCached(receivedAtMs: receivedAtMs, validUntilMs: validUntilMs ?? -1, nowMs: now)
    }

    /// 当前连接仍要求45秒租约；可展示缓存不代表可以恢复认证连接的续期资格。
    func isLive(atMs now: Int64) -> Bool {
        guard (try? validate()) != nil else { return false }
        return SnapshotFreshnessPolicy.shared.isLive(receivedAtMs: receivedAtMs, validUntilMs: validUntilMs ?? -1, nowMs: now)
    }
    /// 只有当前认证连接的心跳续摘要租约，旧快照本身不产生在线证明。
    func renewed(atMs now: Int64) -> Self? {
        guard (try? validate()) != nil,
              let deadline = SnapshotFreshnessPolicy.shared.renewedDeadline(receivedAtMs: receivedAtMs,
                  validUntilMs: validUntilMs ?? -1, nowMs: now) else { return nil }
        var next = self; next.validUntilMs = deadline.int64Value; return next
    }
    /// 保留真实接收时间，跨日缓存也不会被重新标作今日同步。
    var receivedDate: Date { Date(epochMs: receivedAtMs) }
    var stamp: SnapshotStamp { SnapshotStamp(sourceId: sourceId, receivedAtMs: receivedAtMs) }
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

/// Swift 仅保留原有 Codable 字段；展示与领域校验由 SharedLogic 维护。
struct WidgetDisplaySnapshot: Codable, Equatable {
    let version: Int
    let tokens: WidgetTokens?
    let tokenError: String?
    let hooksAvailable: Bool
    let hooks: [WidgetHook]
    var providerQuota: ProviderQuotaSnapshot? = nil
    /// nil 为旧桌面未声明；空数组表示明确停用所有 Agent。
    var enabledAgents: [String]? = nil
    var displayTokens: WidgetTokens? { tokens?.forDisplay(enabledAgents: enabledAgents) }
    var displayProviderQuota: ProviderQuotaSnapshot? { providerQuota?.forDisplay(enabledAgents: enabledAgents) }
    var displayUsageRows: [WidgetUsageRow] { WidgetUsageRow.project(tokens: tokens, quota: providerQuota, enabledAgents: enabledAgents) }

    var sharedValue: TerminalSnapshot {
        TerminalSnapshot(version: Int32(clamping: version), tokens: tokens?.sharedValue, tokenError: tokenError,
            hooksAvailable: hooksAvailable, hooks: hooks.map(\.sharedValue), assets: [], catalogError: nil,
            providerQuota: providerQuota?.sharedValue, enabledAgents: enabledAgents)
    }

    func validate() throws {
        guard sharedValue.isValid() else { throw WidgetSnapshotError.invalid }
    }

    /// 数量描述最近收到的摘要，不代表当前仍在线。
    var hooksText: String { hooksAvailable ? "Hooks \(hooks.count)" : "Hooks 未同步" }
}

/// u64 十进制字符串贯穿缓存与 UI，不经 Double 导致大数损失。
struct WidgetAmount: Codable, Equatable {
    enum Availability: String, Codable { case available, noRecords, unavailable }
    enum Completeness: String, Codable { case complete, partial, unknown }
    enum Confidence: String, Codable { case exact, derived, suspected }
    let total: String?
    let availability: Availability
    let completeness: Completeness
    let confidence: Confidence

    var sharedValue: TerminalAmount {
        TerminalAmount(total: total, availability: availability.rawValue,
            completeness: completeness.rawValue, confidence: confidence.rawValue)
    }

    func validate() throws {
        guard sharedValue.isValid() else { throw WidgetSnapshotError.invalid }
    }

    var text: String { sharedValue.text }
    var hasNumericValue: Bool { sharedValue.hasNumericValue }
    var compactText: String { TokenNumber.compact(text) }
    var exactText: String { TokenNumber.grouped(text) }
    /// 保留 Apple 现有紧凑分隔符，质量含义与其他终端共用。
    var quality: String {
        UsageDisplayPolicy.shared.amountQuality(completeness: completeness.rawValue,
            confidence: confidence.rawValue, separator: "·")
    }
}

/// 同轮总量与分量保留桌面的日期/时区，跨日后也不会标作“今日”。
struct WidgetTokens: Codable, Equatable {
    struct Day: Codable, Equatable {
        let date: String
        let zone: String
        let startMs: Int64
        let endMs: Int64
    }
    struct Agent: Codable, Equatable {
        let agent: String
        let amount: WidgetAmount
        var displayName: String { agentDisplayName(agent) }
        var sharedValue: TerminalAgent { TerminalAgent(agent: agent, amount: amount.sharedValue) }
    }
    let day: Day
    let observedMs: Int64
    let all: WidgetAmount
    let agents: [Agent]

    var sharedValue: TerminalTokens {
        TerminalTokens(day: TerminalDay(date: day.date, zone: day.zone, startMs: day.startMs, endMs: day.endMs),
            observedMs: observedMs, all: all.sharedValue, agents: agents.map(\.sharedValue))
    }

    /// 策略仅返回原始位置，总量、质量、日期与原始编码顺序保持不变。
    func forDisplay(enabledAgents: [String]?) -> Self {
        let indices = UsageDisplayPolicy.shared.visibleIndices(names: agents.map(\.agent), enabledAgents: enabledAgents)
        return Self(day: day, observedMs: observedMs, all: all,
                    agents: indices.map { agents[$0.intValue] })
    }

    func validate() throws {
        guard sharedValue.isValid() else { throw WidgetSnapshotError.invalid }
    }
}

/// 非 Codable 的 UI 行引用；共享策略决定筛选、合并、排序与 Cursor 默认零行。
enum WidgetUsageRow: Equatable, Identifiable {
    case agent(WidgetTokens.Agent, quota: ProviderQuotaEntry?)
    case quota(ProviderQuotaEntry)
    case cursorDefault

    static func project(tokens: WidgetTokens?, quota: ProviderQuotaSnapshot?, enabledAgents: [String]?) -> [Self] {
        let agents = tokens?.agents ?? []
        let providers = quota?.providers ?? []
        return UsageDisplayPolicy.shared.projectRows(tokensPresent: tokens != nil,
            tokenNames: agents.map(\.agent), quotaProviders: providers.map(\.provider), enabledAgents: enabledAgents).map { row in
                let tokenIndex = Int(row.tokenIndex), quotaIndex = Int(row.quotaIndex)
                let quota = quotaIndex >= 0 ? providers[quotaIndex] : nil
                if tokenIndex >= 0 { return .agent(agents[tokenIndex], quota: quota) }
                if let quota { return .quota(quota) }
                return .cursorDefault
            }
    }

    var id: String {
        switch self {
        case .agent(let agent, _): "agent:\(agent.agent)"
        case .quota(let quota): "quota:\(quota.provider)"
        case .cursorDefault: "default:" + UsageDisplayPolicy.shared.ZERO_DEFAULT_PROVIDER
        }
    }

    fileprivate var sourceName: String {
        switch self {
        case .agent(let agent, _): agent.agent
        case .quota(let quota): quota.provider
        case .cursorDefault: UsageDisplayPolicy.shared.ZERO_DEFAULT_PROVIDER
        }
    }

    var displayName: String {
        switch self {
        case .agent(let agent, _): agent.displayName
        case .quota(let quota): quota.label
        case .cursorDefault: agentDisplayName(sourceName)
        }
    }

    var tokenAmount: WidgetAmount? {
        if case .agent(let agent, _) = self { return agent.amount }
        return nil
    }

    var quotaEntry: ProviderQuotaEntry? {
        switch self {
        case .agent(_, let quota): quota
        case .quota(let quota): quota
        case .cursorDefault: nil
        }
    }

    enum Presentation: Equatable {
        case headline(tokenText: String)
        case quotaOnly(ProviderQuotaEntry)
    }

    /// SwiftUI 所需的枚举外壳；数字可用性和默认零由共享规则决定。
    var presentation: Presentation {
        if let text = tokenText { return .headline(tokenText: text) }
        switch self {
        case .agent(let agent, _): return .headline(tokenText: agent.amount.text)
        case .quota(let quota): return .quotaOnly(quota)
        case .cursorDefault: return .headline(tokenText: UsageDisplayPolicy.shared.ZERO_DEFAULT_TOKEN_TEXT)
        }
    }

    var tokenText: String? {
        UsageDisplayPolicy.shared.tokenText(sourceName: sourceName, amountText: tokenAmount?.text,
            hasNumericValue: tokenAmount?.hasNumericValue == true)
    }
}

/// 原生调用点和 Codable 类型保持稳定，算法只有 SharedLogic 中一份。
func agentDisplayName(_ raw: String) -> String { UsageDisplayPolicy.shared.agentDisplayName(raw: raw) }
/// 只共享 Agent 与四态，不共享可能含敏感信息的 Hook 正文和图片。
struct WidgetHook: Codable, Equatable {
    enum Behavior: String, Codable {
        case idle, running, asking, error
        var label: String { UsageDisplayPolicy.shared.hookLabel(behavior: rawValue) }
    }
    let agent: String
    let slot: Int
    let behavior: Behavior
    var sharedValue: TerminalHook {
        TerminalHook(agent: agent, slot: Int32(clamping: slot), behavior: behavior.rawValue,
            content: "", contentTruncated: false, image: nil)
    }
}

/// 原生 UI 的历史调用入口，精度与舍入规则只由共享格式器维护。
enum TokenNumber {
    static func grouped(_ raw: String) -> String { TokenFormatting.shared.exact(value: raw) }
    static func compact(_ raw: String) -> String { TokenFormatting.shared.compact(value: raw) }
}

/// Swift 保留既有线格式，完整额度约束和展示属性委托 Kotlin 模型。
struct ProviderQuotaSnapshot: Codable, Equatable {
    let observedAtUnix: Int64
    let providers: [ProviderQuotaEntry]
    var observedDate: Date { Date(timeIntervalSince1970: TimeInterval(observedAtUnix)) }
    var sharedValue: SharedLogic.ProviderQuotaSnapshot {
        SharedLogic.ProviderQuotaSnapshot(observedAtUnix: observedAtUnix, providers: providers.map(\.sharedValue))
    }
    func forDisplay(enabledAgents: [String]?) -> Self {
        let indices = UsageDisplayPolicy.shared.visibleIndices(names: providers.map(\.provider), enabledAgents: enabledAgents)
        return Self(observedAtUnix: observedAtUnix, providers: indices.map { providers[$0.intValue] })
    }
    func validate() throws {
        guard sharedValue.isValid() else { throw WidgetSnapshotError.invalid }
    }
}

struct ProviderQuotaEntry: Codable, Equatable {
    let provider: String
    let plan: String?
    let fiveHour: ProviderQuotaWindow?
    let weekly: ProviderQuotaWindow?
    var monthly: ProviderQuotaWindow? = nil
    var sharedValue: SharedLogic.ProviderQuotaEntry {
        SharedLogic.ProviderQuotaEntry(provider: provider, plan: plan, fiveHour: fiveHour?.sharedValue,
            weekly: weekly?.sharedValue, monthly: monthly?.sharedValue)
    }
    var label: String { sharedValue.label }
    var windows: [ProviderQuotaWindow] {
        sharedValue.windows.map { ProviderQuotaWindow(kind: $0.kind, usedTenths: Int($0.usedTenths), resetAtUnix: $0.resetAtUnix?.int64Value) }
    }
    var planLabel: String? { sharedValue.planLabel }
    var displayName: String { planLabel.map { "\(label)，套餐 \($0)" } ?? label }
    func validate() throws {
        guard sharedValue.isValid() else { throw WidgetSnapshotError.invalid }
    }
}

struct ProviderQuotaWindow: Codable, Equatable {
    let kind: String
    let usedTenths: Int
    let resetAtUnix: Int64?
    var sharedValue: SharedLogic.ProviderQuotaWindow {
        SharedLogic.ProviderQuotaWindow(kind: kind, usedTenths: Int32(clamping: usedTenths),
            resetAtUnix: resetAtUnix.map { KotlinLong(value: $0) })
    }
    var label: String { sharedValue.kindLabel }
    var resetDate: Date? { resetAtUnix.map { Date(timeIntervalSince1970: TimeInterval($0)) } }
    var remainingTenths: Int { Int(sharedValue.remainingTenths) }
    var percentText: String { sharedValue.percentText }
    var level: Int { Int(sharedValue.level) }
    func validate(kind expected: String) throws {
        guard sharedValue.isValid(expected: expected) else { throw WidgetSnapshotError.invalid }
    }
}
