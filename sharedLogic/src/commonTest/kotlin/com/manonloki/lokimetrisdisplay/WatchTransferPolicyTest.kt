package com.manonloki.lokimetrisdisplay

import com.manonloki.lokimetrisdisplay.domain.TerminalAsset
import com.manonloki.lokimetrisdisplay.protocol.AssetTransferDescriptor
import com.manonloki.lokimetrisdisplay.protocol.AssetTransferManifest
import com.manonloki.lokimetrisdisplay.protocol.WatchChunkDecision
import com.manonloki.lokimetrisdisplay.protocol.WatchCommunicationPolicy
import com.manonloki.lokimetrisdisplay.protocol.WatchCompanionState
import com.manonloki.lokimetrisdisplay.protocol.WatchContactFact
import com.manonloki.lokimetrisdisplay.protocol.WatchContactObservation
import com.manonloki.lokimetrisdisplay.protocol.WatchMonotonicTime
import com.manonloki.lokimetrisdisplay.protocol.WatchPayloadDecision
import com.manonloki.lokimetrisdisplay.protocol.WatchPayloadKind
import com.manonloki.lokimetrisdisplay.protocol.WatchProtocolRules
import com.manonloki.lokimetrisdisplay.protocol.WatchTransferRules
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** 不接触系统时钟或 WCSession；覆盖完整无符号纳秒范围和协议边界。 */
class WatchTransferPolicyTest {
    private val session = "12345678-1234-4234-8234-123456789abc"
    private val other = "22345678-1234-4234-8234-123456789abc"
    private val hash = "a".repeat(64)
    private fun time(value: ULong): WatchMonotonicTime = WatchMonotonicTime((value shr 32).toInt(), value.toInt())

    @Test fun nanosecondBitsRoundTripAcrossSignedLongAndUnsignedMaximum() {
        for (value in listOf(0UL, 1UL, Long.MAX_VALUE.toULong(), Long.MAX_VALUE.toULong() + 1UL, ULong.MAX_VALUE)) {
            assertEquals(value, time(value).unsignedNanos())
        }
    }

    @Test fun foregroundLeaseRejectsOldSessionBackwardClockAndExactExpiryWithoutWraparound() {
        val active = assertNotNull(WatchCommunicationPolicy.activateLease(session))
        assertFalse(WatchCommunicationPolicy.reachable(active, time(1UL)))
        assertNull(WatchCommunicationPolicy.activateLease("invalid"))
        val base = ULong.MAX_VALUE - 45_000_000_000UL
        val received = assertNotNull(WatchCommunicationPolicy.receivedLease(active, session, time(base)))
        assertNull(active.lastContact)
        assertNull(WatchCommunicationPolicy.receivedLease(received, other, time(base + 1UL)))
        assertNull(WatchCommunicationPolicy.receivedLease(received, session, time(base - 1UL)))
        assertTrue(WatchCommunicationPolicy.reachable(received, time(ULong.MAX_VALUE - 1UL)))
        assertFalse(WatchCommunicationPolicy.reachable(received, time(ULong.MAX_VALUE)))
        assertFalse(WatchCommunicationPolicy.reachable(received, time(0UL)))
        assertFalse(WatchCommunicationPolicy.reachable(WatchCommunicationPolicy.inactiveLease(), time(base)))
    }

    @Test fun ackFactsKeepIndependentSyncAndRoundAgeUpWithoutChangingOldCopies() {
        val initial = WatchCommunicationPolicy.emptyFacts()
        val synced = assertNotNull(WatchCommunicationPolicy.receivedFacts(initial, time(1_000_000_000UL), true))
        val contacted = assertNotNull(WatchCommunicationPolicy.receivedFacts(synced, time(3_000_000_000UL), false))
        val report = WatchCommunicationPolicy.report(contacted, true, time(4_000_000_001UL))
        assertTrue(report.reachable)
        assertEquals(WatchContactObservation(2, 1001), report.contact)
        assertEquals(WatchContactObservation(1, 3001), report.sync)
        assertEquals(0L, initial.sequence)
        assertEquals(1L, synced.sequence)
        assertNull(WatchCommunicationPolicy.receivedFacts(contacted, time(1UL), false))
        val cleared = WatchCommunicationPolicy.clearFacts(contacted)
        assertEquals(2L, cleared.sequence)
        assertNull(cleared.contact)
        assertNull(cleared.sync)
        assertNotNull(contacted.contact)
        assertEquals(3L, WatchCommunicationPolicy.receivedFacts(cleared, time(0UL), false)?.sequence)
    }

    @Test fun observationUsesExactUnsignedTimeAndSevenDayCeiling() {
        val base = Long.MAX_VALUE.toULong() + 1UL
        val fact = WatchContactFact(1, time(base))
        assertEquals(WatchContactObservation(1, 1), WatchCommunicationPolicy.observation(fact, time(base + 1UL)))
        assertNull(WatchCommunicationPolicy.observation(fact, time(base - 1UL)))
        assertNotNull(WatchCommunicationPolicy.observation(fact, time(base + 604_800_000_000_000UL)))
        assertNull(WatchCommunicationPolicy.observation(fact, time(base + 604_800_000_000_001UL)))
        assertNull(WatchCommunicationPolicy.observation(WatchContactFact(1, time(0UL)), time(ULong.MAX_VALUE)))
        val current = WatchCompanionState(1, fact, fact)
        assertTrue(WatchCommunicationPolicy.report(current, true, time(base + 44_999_000_000UL)).reachable)
        assertFalse(WatchCommunicationPolicy.report(current, true, time(base + 44_999_000_001UL)).reachable)
    }

    @Test fun lastExactJsonSequenceIsAllowedOnceAndClearNeverResetsIt() {
        val nearLimit = WatchCompanionState(WatchCommunicationPolicy.MAX_SEQUENCE - 1, null, null)
        val last = assertNotNull(WatchCommunicationPolicy.receivedFacts(nearLimit, time(ULong.MAX_VALUE), true))
        assertEquals(WatchCommunicationPolicy.MAX_SEQUENCE, last.sequence)
        assertNull(WatchCommunicationPolicy.receivedFacts(last, time(ULong.MAX_VALUE), false))
        assertNull(WatchCommunicationPolicy.receivedFacts(WatchCommunicationPolicy.clearFacts(last), time(0UL), false))
    }

    @Test fun committedAuthorizedImageHasPriorityOverFrequentSnapshots() {
        val asset = AssetTransferDescriptor(hash, "image/gif", "1000000")
        val committed = AssetTransferManifest(listOf(asset), setOf(hash))
        val result = WatchTransferRules.nextPayload(committed, committed, true, setOf(hash), emptySet(), emptySet())
        assertEquals(WatchPayloadDecision(WatchPayloadKind.ASSET, 0), result)
        for (ack in listOf(true, false)) {
            assertEquals(WatchPayloadKind.SNAPSHOT, WatchTransferRules.nextPayload(committed, committed, true,
                setOf(hash), if (ack) setOf(hash) else emptySet(), if (ack) emptySet() else setOf(hash)).kind)
        }
        assertEquals(WatchPayloadKind.IDLE, WatchTransferRules.nextPayload(null, committed, false,
            setOf(hash), emptySet(), emptySet()).kind)
    }

    @Test fun imageTransferRequiresCommittedAndLatestReferenceAndExactMetadata() {
        val asset = AssetTransferDescriptor(hash, "image/gif", "18446744073709551615")
        val committed = AssetTransferManifest(listOf(asset), setOf(hash))
        assertEquals(WatchPayloadKind.SNAPSHOT, WatchTransferRules.nextPayload(committed,
            committed.copy(assets = listOf(asset.copy(byteLength = "18446744073709551614"))), true,
            setOf(hash), emptySet(), emptySet()).kind)
        assertEquals(WatchPayloadKind.SNAPSHOT, WatchTransferRules.nextPayload(committed,
            committed.copy(assets = listOf(asset.copy(mime = "image/png"))), true,
            setOf(hash), emptySet(), emptySet()).kind)
        assertEquals(WatchPayloadKind.SNAPSHOT, WatchTransferRules.nextPayload(
            committed.copy(referencedHashes = emptySet()), committed, true, setOf(hash), emptySet(), emptySet()).kind)
    }

    @Test fun exactChunkOffsetsLengthsAndTransferGenerationAreValidatedBeforeAppend() {
        assertTrue(WatchProtocolRules.validSnapshotBegin(session, hash, 96 * 1024L))
        for (size in listOf(0L, -1L, 96 * 1024L + 1, Long.MAX_VALUE)) {
            assertFalse(WatchProtocolRules.validSnapshotBegin(session, hash, size))
        }
        assertFalse(WatchProtocolRules.validSnapshotBegin("invalid", hash, 1))
        assertFalse(WatchProtocolRules.validSnapshotBegin(session, "../asset", 1))
        assertEquals(WatchChunkDecision(true, 16384, false),
            WatchProtocolRules.chunk(session, session, 16387, 0, 0, 16384))
        assertEquals(WatchChunkDecision(true, 16387, true),
            WatchProtocolRules.chunk(session, session, 16387, 16384, 16384, 3))
        assertFalse(WatchProtocolRules.chunk(session, other, 16387, 0, 0, 16384).valid)
        assertFalse(WatchProtocolRules.chunk(session, session, 16387, 16384, 0, 3).valid)
        assertFalse(WatchProtocolRules.chunk(session, session, 16387, 16384, Long.MAX_VALUE, 3).valid)
        assertFalse(WatchProtocolRules.chunk(session, session, 16387, 16384, 16384, 0).valid)
        assertFalse(WatchProtocolRules.chunk(session, session, 16387, 16384, 16384, 4).valid)
        assertFalse(WatchProtocolRules.chunk(session, session, 1, Int.MAX_VALUE, 0, Int.MAX_VALUE).valid)
    }

    @Test fun rpcAndDeviceMetadataStayBoundedClosedAndSeparateFromJson() {
        assertTrue(WatchProtocolRules.validRpcByteCount(32768))
        assertFalse(WatchProtocolRules.validRpcByteCount(32769))
        assertFalse(WatchProtocolRules.validRpcByteCount(Int.MAX_VALUE))
        assertTrue(WatchProtocolRules.validRequest(1, "snapshotChunk"))
        assertFalse(WatchProtocolRules.validRequest(Int.MAX_VALUE, "probe"))
        assertFalse(WatchProtocolRules.validRequest(1, "shell"))
        assertTrue(WatchProtocolRules.validReply("invalid"))
        assertFalse(WatchProtocolRules.validReply("success"))
        assertTrue(WatchProtocolRules.validDeviceInfo(session, "Watch", "1.0"))
        assertFalse(WatchProtocolRules.validDeviceInfo(session, " \t", "1.0"))
        assertFalse(WatchProtocolRules.validDeviceInfo(session, "Watch", "1\u0080"))
        assertFalse(WatchProtocolRules.validDeviceInfo(session, "Watch", "a".repeat(65)))
        assertTrue(WatchProtocolRules.validEnvelope(1, session, other, 1000, listOf(0, 999, 1000)))
        assertFalse(WatchProtocolRules.validEnvelope(1, session, session, 1000, emptyList()))
        assertFalse(WatchProtocolRules.validEnvelope(1, session, other, 1000, listOf(Long.MAX_VALUE)))
    }

    @Test fun assetBlocksAllowLargerThanSnapshotCapacityThroughExact32MiBTail() {
        val largerThanSnapshot = WatchProtocolRules.MAX_SNAPSHOT_BYTES + 3
        assertFalse(WatchProtocolRules.chunk(session, session, largerThanSnapshot, 0, 0, 16384).valid)
        assertEquals(WatchChunkDecision(true, 16384, false),
            WatchProtocolRules.assetChunk(session, session, largerThanSnapshot, 0, 0, 16384))
        assertEquals(WatchChunkDecision(true, largerThanSnapshot, true),
            WatchProtocolRules.assetChunk(session, session, largerThanSnapshot, 98304, 98304, 3))
        val maximum = TerminalAsset.MAX_LENGTH.toInt()
        assertEquals(WatchChunkDecision(true, maximum, true), WatchProtocolRules.assetChunk(
            session, session, maximum, maximum - 16384, maximum.toLong() - 16384, 16384))
        assertFalse(WatchProtocolRules.assetChunk(session, session, maximum + 1, 0, 0, 16384).valid)
        assertFalse(WatchProtocolRules.assetChunk(session, session, Int.MAX_VALUE, 0, 0, 16384).valid)
    }

    @Test fun rejectedAssetBlocksKeepOffsetAndCannotAcceptWrongGenerationOrOversizedTail() {
        val length = WatchProtocolRules.MAX_SNAPSHOT_BYTES + 3
        val rejected = WatchChunkDecision(false, 98304, false)
        assertEquals(rejected, WatchProtocolRules.assetChunk(session, other, length, 98304, 98304, 3))
        assertEquals(rejected, WatchProtocolRules.assetChunk(session, session, length, 98304, 98303, 3))
        assertEquals(rejected, WatchProtocolRules.assetChunk(session, session, length, 98304, Long.MAX_VALUE, 3))
        assertEquals(rejected, WatchProtocolRules.assetChunk(session, session, length, 98304, 98304, 4))
        assertEquals(rejected, WatchProtocolRules.assetChunk(session, session, length, 98304, 98304, 0))
        assertFalse(WatchProtocolRules.assetChunk(null, session, length, 0, 0, 16384).valid)
        assertFalse(WatchProtocolRules.assetChunk(session, session, length, -1, -1, 16384).valid)
        assertFalse(WatchProtocolRules.assetChunk(session, session, length, length, length.toLong(), 1).valid)
        assertFalse(WatchProtocolRules.assetChunk(session, session, length, Int.MAX_VALUE, 0, Int.MAX_VALUE).valid)
    }
}
