package com.manonloki.lokimetrisdisplay

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.nio.ByteBuffer

/** 固定版本的有界私有格式；字段由裁剪模型逐项编码，无法意外序列化完整 Hook。 */
internal object AndroidWidgetCodec {
    private const val LEGACY_MAGIC = 0x4c575331
    /** v2 只有三个提供商及 5h/周窗口；v3 增加 Claude 与月窗口。 */
    private const val V2_MAGIC = 0x4c575332
    private const val MAGIC = 0x4c575333
    const val MAX_FILE_BYTES = AndroidWidgetSnapshot.MAX_BYTES + 8192
    data class State(val snapshot: AndroidWidgetSnapshot, val encryptedTarget: ByteArray?)

    fun encode(state: State): ByteArray = output { out ->
        state.snapshot.validate()
        out.writeInt(MAGIC)
        out.text(state.snapshot.sourceId, 36); out.writeLong(state.snapshot.receivedAtMs)
        val snapshot = state.snapshot.snapshot
        out.writeInt(snapshot.version)
        out.writeBoolean(snapshot.tokens != null)
        snapshot.tokens?.let { tokens ->
            out.text(tokens.day.date, 10); out.text(tokens.day.zone, 256)
            out.writeLong(tokens.day.startMs); out.writeLong(tokens.day.endMs); out.writeLong(tokens.observedMs)
            out.amount(tokens.all); out.writeInt(tokens.agents.size)
            tokens.agents.forEach { out.text(it.agent, 64); out.amount(it.amount) }
        }
        out.optionalText(snapshot.tokenError, 512); out.writeBoolean(snapshot.hooksAvailable)
        out.writeInt(snapshot.hooks.size)
        snapshot.hooks.forEach { out.text(it.agent, 64); out.writeInt(it.slot); out.text(it.behavior, 16) }
        val target = state.encryptedTarget
        out.writeInt(target?.size ?: 0)
        if (target != null) { require(target.size <= 4096); out.write(target) }
        out.writeBoolean(snapshot.providerQuota != null)
        snapshot.providerQuota?.let { quota ->
            out.writeLong(quota.observedAtUnix); out.writeInt(quota.providers.size)
            quota.providers.forEach { item ->
                out.text(item.provider, 16); out.optionalText(item.plan, 24)
                out.quotaWindow(item.fiveHour); out.quotaWindow(item.weekly); out.quotaWindow(item.monthly)
            }
        }
    }.also { require(it.size <= MAX_FILE_BYTES) }

    fun decode(bytes: ByteArray): State {
        require(bytes.size <= MAX_FILE_BYTES)
        return input(bytes) { data ->
            val magic = data.readInt(); require(magic == MAGIC || magic == V2_MAGIC || magic == LEGACY_MAGIC)
            val source = data.text(36); val received = data.readLong(); val version = data.readInt()
            val tokens = if (data.flag()) {
                val day = TerminalDay(data.text(10), data.text(256), data.readLong(), data.readLong())
                val observed = data.readLong(); val all = data.amount()
                TerminalTokens(day, observed, all, List(data.count(14)) { TerminalAgent(data.text(64), data.amount()) })
            } else null
            val tokenError = data.optionalText(512); val hooksAvailable = data.flag()
            val hooks = List(data.count(12)) { TerminalHook(data.text(64), data.readInt(), data.text(16), "", false, null) }
            val target = data.count(4096).let { count -> if (count == 0) null else ByteArray(count).also(data::readFully) }
            val quota = if (magic != LEGACY_MAGIC && data.flag()) ProviderQuotaSnapshot(data.readLong(),
                List(data.count(if (magic == MAGIC) 4 else 3)) {
                    ProviderQuotaEntry(data.text(16), data.optionalText(24), data.quotaWindow(), data.quotaWindow(), if (magic == MAGIC) data.quotaWindow() else null)
                }) else null
            State(AndroidWidgetSnapshot(source, received,
                TerminalSnapshot(version, tokens, tokenError, hooksAvailable, hooks, emptyList(), null, quota)).also { it.validate() }, target)
        }
    }

    fun encodeTarget(target: AndroidWidgetTarget): ByteArray = output { data ->
        target.validate()
        data.writeInt(target.version); data.text(target.sourceId, 36); data.text(target.deviceId, 36)
        data.text(target.host, 253); data.writeInt(target.port); data.text(target.key, 44); data.text(target.generation, 36)
    }

    fun decodeTarget(bytes: ByteArray): AndroidWidgetTarget = input(bytes) { data ->
        val version = data.readInt(); val source = data.text(36); val device = data.text(36)
        val host = data.text(253); val port = data.readInt(); val key = data.text(44); val generation = data.text(36)
        AndroidWidgetTarget(source, device, host, port, key, generation, version).also { it.validate() }
    }

    private fun output(write: (DataOutputStream) -> Unit): ByteArray = ByteArrayOutputStream().use { buffer ->
        DataOutputStream(buffer).use(write); buffer.toByteArray()
    }
    private fun <T> input(bytes: ByteArray, read: (DataInputStream) -> T): T =
        DataInputStream(ByteArrayInputStream(bytes)).use { data -> read(data).also { require(data.available() == 0) } }
    private fun DataOutputStream.text(value: String, limit: Int) {
        val bytes = value.toByteArray(Charsets.UTF_8); require(bytes.size <= limit)
        writeInt(bytes.size); write(bytes)
    }
    private fun DataInputStream.text(limit: Int): String {
        val count = count(limit); require(count <= available())
        return Charsets.UTF_8.newDecoder().decode(ByteBuffer.wrap(ByteArray(count).also(::readFully))).toString()
    }
    private fun DataOutputStream.optionalText(value: String?, limit: Int) { writeBoolean(value != null); if (value != null) text(value, limit) }
    private fun DataInputStream.optionalText(limit: Int): String? = if (flag()) text(limit) else null
    /** 可空窗口以显式标志保存，保留0%及重置秒数。 */
    private fun DataOutputStream.quotaWindow(value: ProviderQuotaWindow?) {
        writeBoolean(value != null)
        value?.let { text(it.kind, 8); writeInt(it.usedTenths); writeBoolean(it.resetAtUnix != null); it.resetAtUnix?.let(::writeLong) }
    }
    /** 旧格式不调用此入口，新格式仍受完整模型校验。 */
    private fun DataInputStream.quotaWindow(): ProviderQuotaWindow? = if (flag())
        ProviderQuotaWindow(text(8), readInt(), if (flag()) readLong() else null) else null
    private fun DataOutputStream.amount(value: TerminalAmount) {
        optionalText(value.total, 20); text(value.availability, 16); text(value.completeness, 16); text(value.confidence, 16)
    }
    private fun DataInputStream.amount(): TerminalAmount = TerminalAmount(optionalText(20), text(16), text(16), text(16))
    private fun DataInputStream.count(max: Int): Int = readInt().also { require(it in 0..max) }
    private fun DataInputStream.flag(): Boolean = readUnsignedByte().also { require(it in 0..1) } == 1
}
