package com.manonloki.lokimetrisdisplay

import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.util.Locale

internal sealed interface DesktopDnsData {
    data class Pointer(val target: String) : DesktopDnsData
    data class Service(val port: Int, val host: String) : DesktopDnsData
    data class Text(val fields: Map<String, String>) : DesktopDnsData
    data class Address(val bytes: List<Byte>) : DesktopDnsData
}
internal data class DesktopDnsRecord(val name: String, val type: Int, val ttl: Long, val flush: Boolean, val data: DesktopDnsData)

/** DNS 压缩指针有环检测与总长度预算；所有偏移均针对整包，RDATA 另验完整边界。 */
internal object DesktopDnsCodec {
    const val SERVICE = "_loki-host._tcp.local."
    fun query(names: List<Pair<String, Int>> = listOf(SERVICE to 12)): ByteArray {
        require(names.size in 1..64)
        val output = ByteArrayOutputStream()
        repeat(4) { output.write(0) }; output.write(names.size ushr 8); output.write(names.size and 255); repeat(6) { output.write(0) }
        names.forEach { (name, type) ->
            name.trimEnd('.').split('.').forEach { label ->
                val bytes = label.toByteArray(Charsets.UTF_8); require(bytes.size in 1..63)
                output.write(bytes.size); output.write(bytes)
            }
            output.write(0); output.write(type ushr 8); output.write(type and 255); output.write(0); output.write(1)
        }
        return output.toByteArray()
    }
    fun parse(packet: ByteArray): List<DesktopDnsRecord> = Reader(packet).parse()
    private class Reader(private val bytes: ByteArray) {
        private var at = 0
        private fun u8(): Int { require(at < bytes.size); return bytes[at++].toInt() and 255 }
        private fun u16(): Int = (u8() shl 8) or u8()
        private fun u32(): Long = (u16().toLong() shl 16) or u16().toLong()
        private fun name(): String {
            var cursor = at; var consumed = -1; var total = 1
            val seen = mutableSetOf<Int>(); val labels = mutableListOf<String>()
            while (true) {
                require(cursor in bytes.indices && seen.add(cursor) && seen.size <= 128)
                val length = bytes[cursor++].toInt() and 255
                if (length == 0) { if (consumed < 0) consumed = cursor; break }
                if (length and 0xc0 == 0xc0) {
                    require(cursor < bytes.size)
                    val target = ((length and 63) shl 8) or (bytes[cursor++].toInt() and 255)
                    if (consumed < 0) consumed = cursor
                    require(target < cursor - 2)
                    cursor = target; continue
                }
                require(length in 1..63 && cursor + length <= bytes.size)
                total += length + 1; require(total <= 255)
                labels += Charsets.UTF_8.newDecoder().decode(ByteBuffer.wrap(bytes, cursor, length)).toString().lowercase(Locale.ROOT)
                cursor += length
            }
            at = consumed
            return labels.joinToString(".", postfix = ".")
        }
        fun parse(): List<DesktopDnsRecord> {
            require(bytes.size in 12..16_384)
            u16(); val flags = u16(); require(flags and 0x8000 != 0 && flags and 0x7a0f == 0)
            val questions = u16(); val answers = u16(); val authority = u16(); val additional = u16()
            require(questions <= 64 && answers + authority + additional <= 512)
            repeat(questions) { name(); u16(); u16() }
            val result = mutableListOf<DesktopDnsRecord>()
            repeat(answers + authority + additional) {
                val name = name(); val type = u16(); val klass = u16(); val ttl = u32(); val length = u16(); val end = at + length
                require(end <= bytes.size)
                val data = if (klass and 0x7fff != 1) null else when (type) {
                    12 -> DesktopDnsData.Pointer(name()).also { require(at == end) }
                    33 -> { require(length >= 7); u16(); u16(); val port = u16(); DesktopDnsData.Service(port, name()).also { require(at == end) } }
                    16 -> {
                        val fields = mutableMapOf<String, String>()
                        while (at < end) {
                            val count = u8(); require(at + count <= end)
                            val text = Charsets.UTF_8.newDecoder().decode(ByteBuffer.wrap(bytes, at, count)).toString(); at += count
                            val delimiter = text.indexOf('=')
                            if (delimiter >= 0) {
                                val key = text.substring(0, delimiter).lowercase(Locale.ROOT)
                                require(key.isNotEmpty() && key !in fields)
                                fields[key] = text.substring(delimiter + 1)
                            }
                        }
                        DesktopDnsData.Text(fields)
                    }
                    1, 28 -> { require(length == if (type == 1) 4 else 16); DesktopDnsData.Address(bytes.copyOfRange(at, end).toList()) }
                    else -> null
                }
                at = end
                if (data != null) result += DesktopDnsRecord(name, type, ttl, klass and 0x8000 != 0, data)
            }
            require(at == bytes.size)
            return result
        }
    }
}

/** 有界 TTL 缓存独立于网络，便于验证 goodbye、cache-flush 及不完整 DNS-SD 广告。 */
internal class DesktopDnsCache {
    private data class Entry(val record: DesktopDnsRecord, val receivedAt: Long, val expires: Long)
    private val records = mutableMapOf<Pair<String, Int>, MutableList<Entry>>()
    fun accept(values: List<DesktopDnsRecord>, now: Long) {
        expire(now)
        values.groupBy { it.name to it.type }.forEach { (key, incoming) ->
            val entries = records.getOrPut(key) { mutableListOf() }
            if (incoming.any { it.flush && it.ttl > 0 }) {
                val refreshed = incoming.filter { it.ttl > 0 }.map { it.data }.toSet()
                // RFC 6762 §10.2：分包广播的一秒内记录受保护；旧记录留一秒供后续包救回。
                entries.replaceAll { entry ->
                    if (entry.record.data !in refreshed && now - entry.receivedAt > 1000)
                        entry.copy(expires = minOf(entry.expires, now + 1000))
                    else entry
                }
            }
            incoming.forEach { record ->
                val existing = entries.indexOfFirst { it.record.data == record.data }
                if (record.ttl <= 0) {
                    // RFC 6762 §10.1：goodbye 只缩短已有精确记录，不新增空寿命记录。
                    if (existing >= 0) entries[existing] = entries[existing].copy(expires = minOf(entries[existing].expires, now + 1000))
                } else {
                    if (existing >= 0) entries.removeAt(existing)
                    if (entries.size < 64 && records.values.sumOf { it.size } < 512)
                        entries += Entry(record, now, now + minOf(record.ttl, 3600) * 1000)
                }
            }
            if (entries.isEmpty()) records.remove(key)
        }
    }
    fun expire(now: Long) { records.values.forEach { it.removeAll { entry -> entry.expires <= now } }; records.entries.removeAll { it.value.isEmpty() } }
    fun values(name: String, type: Int): List<DesktopDnsData> = records[name to type].orEmpty().map { it.record.data }
    fun questions(): List<Pair<String, Int>> {
        val names = values(DesktopDnsCodec.SERVICE, 12).filterIsInstance<DesktopDnsData.Pointer>().map { it.target }.take(16)
        return (listOf(DesktopDnsCodec.SERVICE to 12) + names.flatMap { listOf(it to 33, it to 16) } +
            names.flatMap { name -> values(name, 33).filterIsInstance<DesktopDnsData.Service>().flatMap { listOf(it.host to 1, it.host to 28) } }).distinct().take(64)
    }
}
