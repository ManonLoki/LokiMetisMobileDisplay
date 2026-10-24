package com.manonloki.lokimetrisdisplay.storage

import com.manonloki.lokimetrisdisplay.rules.TerminalValueRules
import com.manonloki.lokimetrisdisplay.rules.canonicalUnsigned

/** 只承载授权相等性及来源绑定；地址、密钥编码与系统 URL 校验由连接适配层完成。 */
class WatchConfigurationTarget(
    val sourceId: String,
    val deviceId: String,
    private val generation: String,
    private val connection: RefreshConnection,
) {
    internal fun validFor(phoneId: String): Boolean = deviceId == phoneId && sourceId != phoneId &&
        TerminalValueRules.validDeviceId(sourceId) && TerminalValueRules.validDeviceId(deviceId) &&
        TerminalValueRules.validDeviceId(generation)

    internal fun sameConnection(other: WatchConfigurationTarget): Boolean =
        sourceId == other.sourceId && deviceId == other.deviceId && connection.sameConnection(other.connection)

    internal fun samePayload(other: WatchConfigurationTarget): Boolean =
        generation == other.generation && sameConnection(other)

    override fun toString(): String = "WatchConfigurationTarget(redacted)"
}

/** 修订号以规范 u64 十进制跨语言传输，不经过有符号 Long 或浮点数。 */
class WatchConfigurationState(
    val version: Int,
    val phoneId: String,
    val revision: String,
    val target: WatchConfigurationTarget?,
) {
    override fun toString(): String = "WatchConfigurationState(redacted)"
}

enum class WatchConfigurationAcceptance { REJECT, UNCHANGED, REPLACE }

/** 手机签发、Watch 接纳和缓存保留共用同一修订规则；nil target 是显式撤销事实。 */
object WatchConfigurationPolicy {
    const val MAX_BYTES = 4096

    private fun revision(value: String): ULong? =
        if (canonicalUnsigned(value)) value.toULongOrNull() else null

    fun valid(configuration: WatchConfigurationState): Boolean = configuration.version == 1 &&
        TerminalValueRules.validDeviceId(configuration.phoneId) && revision(configuration.revision) != null &&
        (configuration.target?.validFor(configuration.phoneId) ?: true)

    private fun sameTarget(left: WatchConfigurationTarget?, right: WatchConfigurationTarget?): Boolean =
        if (left == null || right == null) left == null && right == null else left.samePayload(right)

    /** 新手机由配套通道授权，独立计数；同手机的旧授权不能越过撤销或同号冲突。 */
    fun acceptance(incoming: WatchConfigurationState, previous: WatchConfigurationState?): WatchConfigurationAcceptance {
        if (!valid(incoming) || (previous != null && !valid(previous))) return WatchConfigurationAcceptance.REJECT
        if (previous == null || incoming.phoneId != previous.phoneId) return WatchConfigurationAcceptance.REPLACE
        val incomingRevision = revision(incoming.revision) ?: return WatchConfigurationAcceptance.REJECT
        val previousRevision = revision(previous.revision) ?: return WatchConfigurationAcceptance.REJECT
        return when {
            incomingRevision > previousRevision -> WatchConfigurationAcceptance.REPLACE
            incomingRevision == previousRevision && sameTarget(incoming.target, previous.target) -> WatchConfigurationAcceptance.UNCHANGED
            else -> WatchConfigurationAcceptance.REJECT
        }
    }

    /** 同一连接继续沿用原代次，避免每次重新构造目标都撤销在途请求。 */
    fun reusePreviousTarget(previous: WatchConfigurationTarget?, incoming: WatchConfigurationTarget?): Boolean =
        previous != null && incoming != null && previous.sameConnection(incoming)

    /** 平台先按共享规则稳定目标代次，再决定是否真的需要签发新修订。 */
    fun needsPublication(previous: WatchConfigurationState?, incomingTarget: WatchConfigurationTarget?, forceRevision: Boolean): Boolean =
        forceRevision || previous == null || !valid(previous) || !sameTarget(previous.target, incomingTarget)

    /** 先持久提交再发布；耗尽或损坏时没有可签发的新修订，禁止溢出回到零。 */
    fun nextRevision(persistedRevision: String, floorRevision: String): String? {
        val persisted = revision(persistedRevision) ?: return null
        val floor = revision(floorRevision) ?: return null
        val baseline = maxOf(persisted, floor)
        return if (baseline == ULong.MAX_VALUE) null else (baseline + 1UL).toString()
    }

    fun observedRevisionFloor(currentRevision: String, reportedRevision: String): String? {
        val current = revision(currentRevision) ?: return null
        val reported = revision(reportedRevision) ?: return null
        return maxOf(current, reported).toString()
    }

    /** 旧 Watch 回报不能轮换现有配置；同号或更高号的内容冲突必须签发更高修订。 */
    fun shouldReissue(currentRevision: String, reportedRevision: String, matchingHash: Boolean): Boolean {
        val current = revision(currentRevision) ?: return false
        val reported = revision(reportedRevision) ?: return false
        return reported >= current && !matchingHash
    }

    fun keepSnapshot(configuration: WatchConfigurationState, cachedPhoneId: String?, cachedSourceId: String?): Boolean =
        valid(configuration) && cachedPhoneId == configuration.phoneId &&
            (configuration.target == null || cachedSourceId == configuration.target.sourceId)

    fun keepTransfer(incoming: WatchConfigurationState, previous: WatchConfigurationState?, hasTransfer: Boolean): Boolean =
        valid(incoming) && hasTransfer && incoming.target != null &&
            (previous == null || previous.phoneId == incoming.phoneId) &&
            (previous?.target == null || previous.target.sourceId == incoming.target.sourceId)

    fun acceptsHTTPSource(configuration: WatchConfigurationState, sourceId: String): Boolean =
        valid(configuration) && configuration.target != null && configuration.target.sourceId == sourceId
}
