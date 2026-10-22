package com.manonloki.lokimetrisdisplay

/** 无符号纳秒时钟的完整 64 位表示；跨 Swift 时只搬运位，不经有符号 Long 或毫秒转换。 */
data class WatchMonotonicTime(val highBits: Int, val lowBits: Int) {
    internal fun unsignedNanos(): ULong = (highBits.toUInt().toULong() shl 32) or lowBits.toUInt().toULong()
}

/** 不可变状态保持 Swift struct 的复制语义，旧事实快照不会被另一 owner 的后续通信修改。 */
data class WatchForegroundState(val session: String?, val lastContact: WatchMonotonicTime?)
data class WatchContactFact(val sequence: Long, val at: WatchMonotonicTime)
data class WatchCompanionState(val sequence: Long, val contact: WatchContactFact?, val sync: WatchContactFact?)
data class WatchContactObservation(val sequence: Long, val ageMs: Long)
data class WatchCompanionReport(val reachable: Boolean, val contact: WatchContactObservation?, val sync: WatchContactObservation?)

/** 前台通信资格、实际 ACK 序号和独立完整同步证明；时间始终在无符号纳秒域中比较。 */
object WatchCommunicationPolicy {
    const val MAX_SEQUENCE = 9_007_199_254_740_991L
    private const val CONTACT_LEASE_NS = 45_000_000_000UL
    private const val MAX_AGE_MS = 604_800_000UL

    fun inactiveLease(): WatchForegroundState = WatchForegroundState(null, null)
    fun activateLease(session: String): WatchForegroundState? =
        if (TerminalValueRules.validDeviceId(session)) WatchForegroundState(session, null) else null

    /** 拒绝旧前台代次和倒退时钟，失败不产生任何新状态。 */
    fun receivedLease(current: WatchForegroundState, session: String, now: WatchMonotonicTime): WatchForegroundState? =
        if (current.session == session &&
            (current.lastContact == null || now.unsignedNanos() >= current.lastContact.unsignedNanos()))
            current.copy(lastContact = now) else null

    fun reachable(current: WatchForegroundState, now: WatchMonotonicTime): Boolean {
        val contact = current.lastContact ?: return false
        val nowNs = now.unsignedNanos()
        val contactNs = contact.unsignedNanos()
        return current.session != null && nowNs >= contactNs && nowNs - contactNs < CONTACT_LEASE_NS
    }

    fun emptyFacts(): WatchCompanionState = WatchCompanionState(0, null, null)
    fun clearFacts(current: WatchCompanionState): WatchCompanionState = current.copy(contact = null, sync = null)

    /** 不超过精确 JSON 整数上限；普通块 ACK 不更新完整快照同步事实。 */
    fun receivedFacts(current: WatchCompanionState, now: WatchMonotonicTime,
                      synchronized: Boolean): WatchCompanionState? {
        if (current.sequence !in 0L until MAX_SEQUENCE ||
            current.contact?.let { now.unsignedNanos() < it.at.unsignedNanos() } == true) return null
        val contact = WatchContactFact(current.sequence + 1, now)
        return WatchCompanionState(contact.sequence, contact, if (synchronized) contact else current.sync)
    }

    /** 年龄向上取整；先无符号相减，除法后加一，因此 UInt64 最大差值也不溢出。 */
    fun observation(fact: WatchContactFact?, now: WatchMonotonicTime): WatchContactObservation? {
        if (fact == null || now.unsignedNanos() < fact.at.unsignedNanos()) return null
        val nanos = now.unsignedNanos() - fact.at.unsignedNanos()
        val ageMs = nanos / 1_000_000UL + if (nanos % 1_000_000UL == 0UL) 0UL else 1UL
        return if (ageMs <= MAX_AGE_MS) WatchContactObservation(fact.sequence, ageMs.toLong()) else null
    }

    fun report(current: WatchCompanionState, reachable: Boolean, now: WatchMonotonicTime): WatchCompanionReport {
        val contact = observation(current.contact, now)
        return WatchCompanionReport(reachable && contact != null && contact.ageMs < 45_000,
            contact, if (contact == null) null else observation(current.sync, now))
    }
}

enum class WatchPayloadKind { ASSET, SNAPSHOT, IDLE }
data class WatchPayloadDecision(val kind: WatchPayloadKind, val assetIndex: Int)

/** 传输中的快照可提交完；图片必须仍有相同授权描述与当前引用，避免频繁快照饿死图片。 */
object WatchTransferRules {
    fun nextPayload(committed: AssetTransferManifest?, latest: AssetTransferManifest, snapshotPending: Boolean,
                    available: Set<String>, acknowledged: Set<String>, failed: Set<String>): WatchPayloadDecision {
        val index = if (committed == null) -1 else AssetTransferRules.pendingIndices(committed, acknowledged + failed)
            .firstOrNull { index ->
                val candidate = committed.assets[index]
                candidate.hash in available && AssetTransferRules.keepInFlight(candidate, latest)
            } ?: -1
        return if (index >= 0) WatchPayloadDecision(WatchPayloadKind.ASSET, index)
        else WatchPayloadDecision(if (snapshotPending) WatchPayloadKind.SNAPSHOT else WatchPayloadKind.IDLE, -1)
    }
}

data class WatchChunkDecision(val valid: Boolean, val nextOffset: Int, val complete: Boolean)

/** 配套线协议的语义与容量边界；JSON、SHA-256 和真实 Data 存储由宿主负责。 */
object WatchProtocolRules {
    const val CHUNK_SIZE = 16 * 1024
    const val MAX_RPC_BYTES = 32 * 1024
    const val MAX_SNAPSHOT_BYTES = 96 * 1024
    const val RPC_TIMEOUT_SECONDS = 8

    fun validDeviceInfo(deviceId: String, name: String, appVersion: String): Boolean =
        TerminalValueRules.validDeviceId(deviceId) && MdnsProtocol.nameError(name) == null &&
            appVersion.isNotEmpty() && appVersion.encodeToByteArray().size <= 64 && !TerminalValueRules.containsControl(appVersion)

    fun validEnvelope(version: Int, phoneId: String, sourceId: String, receivedAtMs: Long,
                      cachedImageTimes: List<Long>): Boolean =
        version == 1 && TerminalValueRules.validDeviceId(phoneId) && TerminalValueRules.validDeviceId(sourceId) &&
            phoneId != sourceId && receivedAtMs >= 0 && cachedImageTimes.all { it <= receivedAtMs }

    fun validRpcByteCount(count: Int): Boolean = count in 0..MAX_RPC_BYTES
    fun validRequest(version: Int, operation: String): Boolean = version == 1 && operation in
        listOf("probe", "requestSync", "pause", "snapshotBegin", "snapshotChunk", "assetBegin", "assetChunk")
    fun validReply(status: String): Boolean = status in
        listOf("ready", "accepted", "continue", "complete", "cached", "paused", "http", "unavailable", "invalid")

    /** 字节长度只可能在 96 KiB 内；超出 Long 范围的宿主 UInt64 映射到 Long.MAX_VALUE 仍被拒绝。 */
    fun validSnapshotBegin(id: String, hash: String, length: Long): Boolean =
        TerminalValueRules.validDeviceId(id) && TerminalValueRules.validContentHash(hash) && length in 1..MAX_SNAPSHOT_BYTES.toLong()

    /** 每块必须正好 16 KiB 或最终余量，不能重复、跳号、空块、超长或使用另一传输代次。 */
    fun chunk(transferId: String?, incomingId: String, length: Int, receivedBytes: Int,
              offset: Long, byteCount: Int): WatchChunkDecision =
        boundedChunk(transferId, incomingId, length, receivedBytes, offset, byteCount, MAX_SNAPSHOT_BYTES)

    /** 图片与快照共用严格块规则，完整图片仍允许原协议的 32 MiB 上限。 */
    fun assetChunk(transferId: String?, incomingId: String, length: Int, receivedBytes: Int,
                   offset: Long, byteCount: Int): WatchChunkDecision =
        boundedChunk(transferId, incomingId, length, receivedBytes, offset, byteCount, TerminalAsset.MAX_LENGTH.toInt())

    private fun boundedChunk(transferId: String?, incomingId: String, length: Int, receivedBytes: Int,
                             offset: Long, byteCount: Int, maximumLength: Int): WatchChunkDecision {
        val valid = transferId == incomingId && length in 1..maximumLength && receivedBytes in 0 until length &&
            offset == receivedBytes.toLong() && byteCount > 0 && byteCount == minOf(CHUNK_SIZE, length - receivedBytes)
        val next = if (valid) receivedBytes + byteCount else receivedBytes
        return WatchChunkDecision(valid, next, valid && next == length)
    }

}
