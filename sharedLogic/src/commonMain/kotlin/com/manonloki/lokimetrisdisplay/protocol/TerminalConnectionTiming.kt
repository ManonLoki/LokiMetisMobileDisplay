package com.manonloki.lokimetrisdisplay

/** 宿主连接所处的阶段；密码预算、认证序号与消息验证仍由 Rust 管理。 */
enum class TerminalSessionPhase {
    IDLE, PAIR_HELLO, PAIR_CONFIRMATION, PAIR_CLOSE, RESUME_REPLY, METADATA, STREAMING, PAUSING,
}

/** 共享层只选择到期原因；宿主负责关闭连接、资源清理、重试调度与显示反馈。 */
enum class TerminalSessionTimeout {
    NONE, PAIRING_EXPIRED, PAIRING_COMPLETED, PHASE_TIMEOUT, HEARTBEAT_TIMEOUT, ASSET_TIMEOUT,
}

/** 连接的共同预算、帧上限及超时优先级，不拥有系统时钟或网络 owner。 */
object TerminalSessionTimingPolicy {
    const val PAIRING_WINDOW_MS = 60_000L
    const val HANDSHAKE_TIMEOUT_MS = 15_000L
    const val FIRST_SNAPSHOT_TIMEOUT_MS = HANDSHAKE_TIMEOUT_MS
    const val PAIR_CLOSE_TIMEOUT_MS = 3_000L
    const val INBOUND_IDLE_TIMEOUT_MS = 45_000L
    const val ASSET_TIMEOUT_MS = 10_000L
    const val HANDSHAKE_FRAME_BYTES = 4096
    const val SECURE_FRAME_BYTES = 98_304

    fun frameLimit(phase: TerminalSessionPhase): Int = when (phase) {
        TerminalSessionPhase.STREAMING, TerminalSessionPhase.PAUSING -> SECURE_FRAME_BYTES
        else -> HANDSHAKE_FRAME_BYTES
    }

    /** 到点即过期；非法负值或时钟尚未到达期限时不会误触发。 */
    fun deadlineReached(nowMs: Long, deadlineMs: Long): Boolean =
        nowMs >= 0 && deadlineMs >= 0 && nowMs >= deadlineMs

    /** 先判断时钟顺序再相减，回退与 Long 边界都不会溢出或被当成超时。 */
    fun elapsedAtLeast(nowMs: Long, sinceMs: Long, budgetMs: Long): Boolean =
        sinceMs >= 0 && nowMs >= sinceMs && budgetMs >= 0 && nowMs - sinceMs >= budgetMs

    /** Apple 保留 UInt64 纳秒精确比较后传入 due；资源是否在途等门禁由宿主提供。 */
    fun timeout(
        phase: TerminalSessionPhase,
        pairingDue: Boolean,
        phaseDue: Boolean,
        heartbeatDue: Boolean,
        assetDue: Boolean,
    ): TerminalSessionTimeout = when {
        pairingDue -> TerminalSessionTimeout.PAIRING_EXPIRED
        phaseDue -> if (phase == TerminalSessionPhase.PAIR_CLOSE) TerminalSessionTimeout.PAIRING_COMPLETED
            else TerminalSessionTimeout.PHASE_TIMEOUT
        phase == TerminalSessionPhase.STREAMING && heartbeatDue -> TerminalSessionTimeout.HEARTBEAT_TIMEOUT
        assetDue -> TerminalSessionTimeout.ASSET_TIMEOUT
        else -> TerminalSessionTimeout.NONE
    }
}
