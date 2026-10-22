package com.manonloki.lokimetrisdisplay

import java.io.ByteArrayOutputStream
import java.io.DataOutputStream
import kotlin.test.*

class DesktopDnsCodecTest {
    private fun name(value: String): ByteArray = ByteArrayOutputStream().apply {
        value.trimEnd('.').split('.').forEach { part -> val bytes = part.toByteArray(); write(bytes.size); write(bytes) }; write(0)
    }.toByteArray()
    private fun record(owner: ByteArray, type: Int, ttl: Int, body: ByteArray, flush: Boolean = false): ByteArray = ByteArrayOutputStream().apply {
        DataOutputStream(this).apply { write(owner); writeShort(type); writeShort(if (flush) 0x8001 else 1); writeInt(ttl); writeShort(body.size); write(body) }
    }.toByteArray()
    private fun response(records: List<ByteArray>): ByteArray = ByteArrayOutputStream().apply {
        DataOutputStream(this).apply { writeShort(0); writeShort(0x8400); writeShort(0); writeShort(records.size); writeInt(0); records.forEach(::write) }
    }.toByteArray()
    @Test fun compressedNamesResolveAcrossRecords() {
        val query = DesktopDnsCodec.query()
        val ownerPointer = byteArrayOf(0xc0.toByte(), 12)
        val instanceOffset = query.size + 12
        val instancePointer = byteArrayOf((0xc0 or (instanceOffset ushr 8)).toByte(), instanceOffset.toByte())
        val ptr = record(ownerPointer, 12, 120, byteArrayOf(4) + "Desk".toByteArray() + ownerPointer)
        val srv = record(instancePointer, 33, 120, byteArrayOf(0, 0, 0, 0, 0x1f, 0x90.toByte()) + name("host.local."), true)
        val packet = query + ptr + srv
        packet[2] = 0x84.toByte(); packet[7] = 2
        val parsed = DesktopDnsCodec.parse(packet)
        assertEquals(2, parsed.size)
        assertEquals(DesktopDnsData.Pointer("desk._loki-host._tcp.local."), parsed[0].data)
        assertEquals("desk._loki-host._tcp.local.", parsed[1].name)
        assertEquals(DesktopDnsData.Service(8080, "host.local."), parsed[1].data)
    }
    @Test fun malformedPointerLengthsAndDuplicateTxtFailClosed() {
        assertFails { DesktopDnsCodec.parse(response(listOf(record(byteArrayOf(0xc0.toByte(), 12), 1, 120, byteArrayOf(1, 2, 3, 4))))) }
        assertFails { DesktopDnsCodec.parse(response(listOf(record(name("host.local."), 1, 120, byteArrayOf(1, 2, 3))))) }
        val text = byteArrayOf(3) + "v=1".toByteArray() + byteArrayOf(3) + "v=2".toByteArray()
        assertFails { DesktopDnsCodec.parse(response(listOf(record(name("desk.local."), 16, 120, text)))) }
        val truncated = response(listOf(record(name("host.local."), 1, 120, byteArrayOf(1, 2, 3, 4)))).dropLast(1).toByteArray()
        assertFails { DesktopDnsCodec.parse(truncated) }
    }
    private fun address(lastByte: Int, ttl: Long = 120, flush: Boolean = false) = DesktopDnsRecord(
        "host.local.", 1, ttl, flush, DesktopDnsData.Address(listOf(10, 0, 0, lastByte).map(Int::toByte)))
    @Test fun ttlExpiryAndGoodbyeAllowOneSecondForRescue() {
        val cache = DesktopDnsCache(); val first = address(1, ttl = 2)
        cache.accept(listOf(first), 1000); cache.expire(2999); assertEquals(listOf(first.data), cache.values("host.local.", 1))
        cache.expire(3000); assertTrue(cache.values("host.local.", 1).isEmpty())
        cache.accept(listOf(first), 4000)
        cache.accept(listOf(first.copy(ttl = 0), address(2, ttl = 0)), 4100)
        assertEquals(listOf(first.data), cache.values("host.local.", 1))
        cache.expire(5099); assertEquals(listOf(first.data), cache.values("host.local.", 1))
        cache.accept(listOf(first), 5099); cache.expire(5100)
        assertEquals(listOf(first.data), cache.values("host.local.", 1))
        cache.accept(listOf(first.copy(ttl = 0)), 5200); cache.expire(6199)
        assertEquals(listOf(first.data), cache.values("host.local.", 1))
        cache.expire(6200); assertTrue(cache.values("host.local.", 1).isEmpty())
    }
    @Test fun splitCacheFlushPacketsPreserveRecordsReceivedWithinOneSecond() {
        val cache = DesktopDnsCache(); val first = address(1, flush = true); val second = address(2, flush = true)
        cache.accept(listOf(first), 4000); cache.accept(listOf(second), 4100)
        cache.expire(5100)
        assertEquals(setOf(first.data, second.data), cache.values("host.local.", 1).toSet())
        // Exactly one second is still within the protected window.
        cache.accept(listOf(address(3, flush = true)), 5100); cache.expire(6099)
        assertContains(cache.values("host.local.", 1), second.data)
        cache.expire(6100)
        assertFalse(first.data in cache.values("host.local.", 1))
        assertContains(cache.values("host.local.", 1), second.data)
    }
    @Test fun cacheFlushExpiresOnlyOldOmittedRecordsAfterOneSecond() {
        val cache = DesktopDnsCache(); val first = address(1); val second = address(2, flush = true)
        cache.accept(listOf(first), 4000); cache.accept(listOf(second), 5101)
        assertEquals(setOf(first.data, second.data), cache.values("host.local.", 1).toSet())
        cache.expire(6100); assertContains(cache.values("host.local.", 1), first.data)
        cache.expire(6101); assertEquals(listOf(second.data), cache.values("host.local.", 1))
    }
    @Test fun refreshInSameOrFollowingPacketRescuesRecordMarkedForFlush() {
        val cache = DesktopDnsCache(); val first = address(1); val second = address(2, flush = true)
        cache.accept(listOf(first), 4000)
        cache.accept(listOf(second, first), 5101)
        cache.expire(6101); assertEquals(setOf(first.data, second.data), cache.values("host.local.", 1).toSet())
        cache.accept(listOf(second), 7102)
        cache.accept(listOf(first.copy(flush = true)), 7202)
        cache.expire(8202); assertEquals(setOf(first.data, second.data), cache.values("host.local.", 1).toSet())
    }
    @Test fun incompleteAdvertisementsProduceTargetedQuestionsWithoutTrust() {
        val cache = DesktopDnsCache()
        cache.accept(listOf(DesktopDnsRecord(DesktopDnsCodec.SERVICE, 12, 120, false, DesktopDnsData.Pointer("desk._loki-host._tcp.local."))), 0)
        assertContains(cache.questions(), "desk._loki-host._tcp.local." to 33)
        assertContains(cache.questions(), "desk._loki-host._tcp.local." to 16)
        cache.accept(listOf(DesktopDnsRecord("desk._loki-host._tcp.local.", 33, 120, true, DesktopDnsData.Service(8080, "host.local."))), 1)
        assertContains(cache.questions(), "host.local." to 1)
    }
}
