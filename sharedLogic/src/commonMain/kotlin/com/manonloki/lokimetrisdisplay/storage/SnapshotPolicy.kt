package com.manonloki.lokimetrisdisplay

/** 只包含接纳决策需要的来源与接收时间，不携带网络凭据或文件对象。 */
data class SnapshotStamp(val sourceId: String, val receivedAtMs: Long)

/** 平台在自己的锁内读当前值、调用规则、原子提交；共享层不持有可变缓存。 */
object SnapshotAcceptancePolicy {
    fun acceptAuthenticated(current: SnapshotStamp?, incoming: SnapshotStamp): Boolean =
        current == null || current.sourceId != incoming.sourceId || current.receivedAtMs <= incoming.receivedAtMs

    fun acceptSameSource(current: SnapshotStamp?, incoming: SnapshotStamp): Boolean =
        current == null || current.sourceId == incoming.sourceId && current.receivedAtMs <= incoming.receivedAtMs

    /** 完整目标比较由适配器传入；摘要缺失时的读取资格仍由平台存储事务决定。 */
    fun acceptFetched(current: SnapshotStamp?, incoming: SnapshotStamp, targetMatches: Boolean,
                      requestSourceId: String, startedAtMs: Long): Boolean =
        targetMatches && incoming.sourceId == requestSourceId && acceptSameSource(current, incoming) &&
            (current == null || startedAtMs < 0 || current.receivedAtMs <= startedAtMs)

    /** 同时间图文完整度更高的结果优先；不同来源只能由授权切换入口调用。 */
    fun acceptDisplay(current: SnapshotStamp?, currentPriority: Int,
                      incoming: SnapshotStamp, incomingPriority: Int): Boolean =
        acceptAuthenticated(current, incoming) &&
            (current == null || current.sourceId != incoming.sourceId || current.receivedAtMs != incoming.receivedAtMs ||
                incomingPriority >= currentPriority)
}

/** 租约只证明最近真实通信；过期后仍可展示缓存，不能凭缓存续租。 */
object SnapshotFreshnessPolicy {
    const val LEASE_MS = 45_000L

    fun validLease(receivedAtMs: Long, validUntilMs: Long): Boolean =
        receivedAtMs >= 0 && receivedAtMs <= Long.MAX_VALUE - LEASE_MS && validUntilMs >= receivedAtMs + LEASE_MS

    fun isCached(receivedAtMs: Long, validUntilMs: Long, nowMs: Long): Boolean =
        validLease(receivedAtMs, validUntilMs) && nowMs >= receivedAtMs &&
            (validUntilMs <= nowMs || validUntilMs - nowMs <= LEASE_MS)

    fun isLive(receivedAtMs: Long, validUntilMs: Long, nowMs: Long): Boolean =
        isCached(receivedAtMs, validUntilMs, nowMs) && validUntilMs > nowMs

    fun renewedDeadline(receivedAtMs: Long, validUntilMs: Long, nowMs: Long): Long? =
        if (isLive(receivedAtMs, validUntilMs, nowMs) && nowMs <= Long.MAX_VALUE - LEASE_MS) nowMs + LEASE_MS else null

    /** 负值表示没有接收记录；未来时间需要重新获取，间隔由平台调度约束决定。 */
    fun shouldRefresh(receivedAtMs: Long, nowMs: Long, intervalMs: Long): Boolean =
        receivedAtMs < 0 || nowMs < 0 || receivedAtMs > nowMs || intervalMs <= 0 || nowMs - receivedAtMs >= intervalMs
}
