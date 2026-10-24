package com.manonloki.lokimetrisdisplay.storage

import com.manonloki.lokimetrisdisplay.rules.normalizeComparisonText

/** 仅携带图片选择需要的事实，不包含 Hook 正文、图片字节或平台文件路径；-1 表示没有时间。 */
data class HookImageFact(
    val slot: Int,
    val agent: String,
    val imageHash: String?,
    val receivedAtMs: Long,
    val clearedAtMs: Long,
    val hasContent: Boolean,
)

/** 已通过宿主完整校验的图文投影元信息，不参与线协议或缓存文件编码。 */
data class HookImageCacheState(
    val phoneId: String,
    val sourceId: String,
    val receivedAtMs: Long,
    val summaryOnly: Boolean,
    val hooksAvailable: Boolean,
    val facts: List<HookImageFact>,
)

/** 宿主依选择映射原始 Hook 和资源描述；只有历史复用或清图会重建图片元信息。 */
enum class HookImageChoice { KEEP_CURRENT, USE_PREVIOUS, CLEAR }
data class HookImageDecision(val choice: HookImageChoice, val fact: HookImageFact)

/** 手机、Watch 共用的历史图片及清图墓碑规则；文件、编解码与系统传输仍由宿主负责。 */
object HookImageCachePolicy {
    /** 同一接收时刻：完整桌面图文 > 带历史图片/清图事实的摘要 > 纯摘要。 */
    fun priority(summaryOnly: Boolean, facts: List<HookImageFact>): Int =
        if (facts.any { it.receivedAtMs >= 0 || it.clearedAtMs >= 0 }) 1 else if (summaryOnly) 0 else 2

    /** 完整桌面快照不能混入历史内容；只为同手机、同来源、未倒退的摘要补图。 */
    fun mayMergeHistory(incoming: HookImageCacheState, previous: HookImageCacheState?): Boolean =
        previous != null && incoming.phoneId == previous.phoneId && incoming.sourceId == previous.sourceId &&
            previous.receivedAtMs <= incoming.receivedAtMs && incoming.facts.all {
                !it.hasContent && (it.imageHash == null || it.receivedAtMs >= 0)
            }

    /** 从上一版已验证的图像描述决定复用，时间相同的明确清图始终胜过图片。 */
    fun decide(incoming: HookImageFact, previous: HookImageCacheState,
               availableImageHashes: Set<String>): HookImageDecision {
        val old = previous.facts.firstOrNull { it.slot == incoming.slot }
        val currentTime = incoming.observedAtMs()
        if (old != null && normalizeComparisonText(old.agent) == normalizeComparisonText(incoming.agent)) {
            val oldTime = old.observedAtMs().takeIf { it >= 0 }
                ?: previous.receivedAtMs.takeIf {
                    old.imageHash != null || priority(previous.summaryOnly, previous.facts) == 2
                }
            if (oldTime != null && (old.imageHash == null || old.imageHash in availableImageHashes) &&
                (currentTime < 0 || oldTime > currentTime || oldTime == currentTime && old.imageHash == null)) {
                return HookImageDecision(HookImageChoice.USE_PREVIOUS, incoming.copy(
                    imageHash = old.imageHash,
                    receivedAtMs = if (old.imageHash == null) -1 else oldTime,
                    clearedAtMs = if (old.imageHash == null) oldTime else -1,
                    hasContent = false,
                ))
            }
        } else if (previous.hooksAvailable && (currentTime < 0 || currentTime <= previous.receivedAtMs)) {
            // 空槽或另一个 Agent 的确认是身份截止事实，更早的图片不能跨过它复活。
            return HookImageDecision(HookImageChoice.CLEAR, incoming.copy(
                imageHash = null, receivedAtMs = -1, clearedAtMs = previous.receivedAtMs, hasContent = false,
            ))
        }
        return HookImageDecision(HookImageChoice.KEEP_CURRENT, incoming)
    }

    /** 同时间的混合摘要必须保留每个已有槽位的观测截止，不能丢标记或以同时间图片覆盖清图。 */
    fun preservesHistory(incoming: List<HookImageFact>, previous: List<HookImageFact>): Boolean =
        previous.all { old ->
            val oldTime = old.observedAtMs()
            if (oldTime < 0) true else {
                val fact = incoming.firstOrNull { it.slot == old.slot &&
                    normalizeComparisonText(it.agent) == normalizeComparisonText(old.agent) }
                fact != null && fact.observedAtMs() >= oldTime &&
                    !(fact.observedAtMs() == oldTime && old.clearedAtMs >= 0 && fact.imageHash != null)
            }
        }

    /** 比较真实手机接收时间；同一时刻才比较图文完整度和历史事实。 */
    fun supersedes(incoming: HookImageCacheState, previous: HookImageCacheState?): Boolean {
        if (previous == null || incoming.phoneId != previous.phoneId || incoming.sourceId != previous.sourceId) return true
        val currentPriority = priority(previous.summaryOnly, previous.facts)
        val incomingPriority = priority(incoming.summaryOnly, incoming.facts)
        if (!SnapshotAcceptancePolicy.acceptDisplay(SnapshotStamp(previous.sourceId, previous.receivedAtMs), currentPriority,
                SnapshotStamp(incoming.sourceId, incoming.receivedAtMs), incomingPriority)) return false
        return incoming.receivedAtMs != previous.receivedAtMs || incomingPriority != 1 || currentPriority != 1 ||
            preservesHistory(incoming.facts, previous.facts)
    }

    private fun HookImageFact.observedAtMs(): Long = if (receivedAtMs >= 0) receivedAtMs else clearedAtMs
}
