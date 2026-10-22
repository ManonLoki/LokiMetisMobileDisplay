package com.manonloki.lokimetrisdisplay

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class TerminalConnectionTimingTest {
    @Test fun budgetsPreserveTheConnectionProtocol() {
        assertEquals(60_000L, TerminalSessionTimingPolicy.PAIRING_WINDOW_MS)
        assertEquals(15_000L, TerminalSessionTimingPolicy.HANDSHAKE_TIMEOUT_MS)
        assertEquals(15_000L, TerminalSessionTimingPolicy.FIRST_SNAPSHOT_TIMEOUT_MS)
        assertEquals(3_000L, TerminalSessionTimingPolicy.PAIR_CLOSE_TIMEOUT_MS)
        assertEquals(45_000L, TerminalSessionTimingPolicy.INBOUND_IDLE_TIMEOUT_MS)
        assertEquals(10_000L, TerminalSessionTimingPolicy.ASSET_TIMEOUT_MS)
    }

    @Test fun onlyStreamingAndPausingUseTheSecureFrameLimit() {
        for (phase in TerminalSessionPhase.entries) {
            val expected = when (phase) {
                TerminalSessionPhase.STREAMING, TerminalSessionPhase.PAUSING -> 98_304
                else -> 4096
            }
            assertEquals(expected, TerminalSessionTimingPolicy.frameLimit(phase), phase.name)
        }
    }

    @Test fun simultaneousDeadlinesUsePairingThenPhaseThenHeartbeatThenAsset() {
        val phase = TerminalSessionPhase.STREAMING
        assertEquals(TerminalSessionTimeout.PAIRING_EXPIRED, timeout(phase, true, true, true, true))
        assertEquals(TerminalSessionTimeout.PHASE_TIMEOUT, timeout(phase, false, true, true, true))
        assertEquals(TerminalSessionTimeout.HEARTBEAT_TIMEOUT, timeout(phase, false, false, true, true))
        assertEquals(TerminalSessionTimeout.ASSET_TIMEOUT, timeout(phase, false, false, false, true))
        assertEquals(TerminalSessionTimeout.NONE, timeout(phase, false, false, false, false))
    }

    @Test fun pairCloseDeadlineCompletesPairingUnlessTheOverallWindowExpired() {
        assertEquals(TerminalSessionTimeout.PAIRING_COMPLETED,
            timeout(TerminalSessionPhase.PAIR_CLOSE, false, true, true, true))
        assertEquals(TerminalSessionTimeout.PAIRING_EXPIRED,
            timeout(TerminalSessionPhase.PAIR_CLOSE, true, true, true, true))
    }

    @Test fun inactiveHeartbeatAndPlatformAssetGatesDoNotInventTimeouts() {
        for (phase in TerminalSessionPhase.entries.filter { it != TerminalSessionPhase.STREAMING }) {
            assertEquals(TerminalSessionTimeout.NONE, timeout(phase, false, false, true, false), phase.name)
        }
        // iOS 仅在 currentAsset 存在时传 true，Android 保留 assetDeadline 自身的到期门禁。
        assertEquals(TerminalSessionTimeout.NONE,
            timeout(TerminalSessionPhase.STREAMING, false, false, false, false))
        assertEquals(TerminalSessionTimeout.ASSET_TIMEOUT,
            timeout(TerminalSessionPhase.IDLE, false, false, false, true))
    }

    @Test fun exactBoundariesAndClockRollbackAreSafeAtLongExtremes() {
        assertFalse(TerminalSessionTimingPolicy.deadlineReached(999, 1000))
        assertTrue(TerminalSessionTimingPolicy.deadlineReached(1000, 1000))
        assertTrue(TerminalSessionTimingPolicy.deadlineReached(Long.MAX_VALUE, Long.MAX_VALUE))
        assertFalse(TerminalSessionTimingPolicy.deadlineReached(-1, 0))
        assertFalse(TerminalSessionTimingPolicy.deadlineReached(0, -1))
        assertFalse(TerminalSessionTimingPolicy.elapsedAtLeast(45_999, 1000, 45_000))
        assertTrue(TerminalSessionTimingPolicy.elapsedAtLeast(46_000, 1000, 45_000))
        assertFalse(TerminalSessionTimingPolicy.elapsedAtLeast(999, 1000, 45_000))
        assertTrue(TerminalSessionTimingPolicy.elapsedAtLeast(Long.MAX_VALUE, 0, Long.MAX_VALUE))
        assertFalse(TerminalSessionTimingPolicy.elapsedAtLeast(Long.MAX_VALUE, Long.MIN_VALUE, 1))
        assertFalse(TerminalSessionTimingPolicy.elapsedAtLeast(1, 0, -1))
        assertFalse(TerminalSessionTimingPolicy.elapsedAtLeast(-1, 0, 0))
    }

    private fun timeout(
        phase: TerminalSessionPhase,
        pairingDue: Boolean,
        phaseDue: Boolean,
        heartbeatDue: Boolean,
        assetDue: Boolean,
    ) = TerminalSessionTimingPolicy.timeout(phase, pairingDue, phaseDue, heartbeatDue, assetDue)
}
