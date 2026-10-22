package com.manonloki.lokimetrisdisplay

import kotlin.test.*

/** 只检验帧容量、平台在途写计数与计时边界，不模拟操作系统 socket 调度。 */
class TerminalFramePolicyTest {
    @Test fun queueLimitCountsPlatformInFlightFrameAndExactTimeoutBoundary() {
        assertTrue(TerminalWritePolicy.canEnqueue(7, false))
        assertFalse(TerminalWritePolicy.canEnqueue(8, false))
        assertTrue(TerminalWritePolicy.canEnqueue(6, true))
        assertFalse(TerminalWritePolicy.canEnqueue(7, true))
        assertFalse(TerminalWritePolicy.canEnqueue(Int.MAX_VALUE, true))
        assertFalse(TerminalWritePolicy.canEnqueue(-1, false))
        assertFalse(TerminalWritePolicy.timedOut(100, 2099))
        assertTrue(TerminalWritePolicy.timedOut(100, 2100))
        assertFalse(TerminalWritePolicy.timedOut(100, 99))
    }
    @Test fun capacityChecksCannotOverflowOrAcceptNegativeSizes() {
        assertTrue(TerminalFramePolicy.canAppend(TerminalFramePolicy.MAX_BUFFER_BYTES - 16_384, 16_384))
        assertFalse(TerminalFramePolicy.canAppend(TerminalFramePolicy.MAX_BUFFER_BYTES - 16_383, 16_384))
        assertFalse(TerminalFramePolicy.canAppend(Int.MAX_VALUE, 1))
        assertFalse(TerminalFramePolicy.canAppend(-1, 1))
        assertFalse(TerminalFramePolicy.canAppend(0, -1))
        assertFalse(TerminalFramePolicy.canAppend(0, 16_385))
    }
    @Test fun phaseLimitsApplyBeforePayloadAllocation() {
        assertTrue(TerminalFramePolicy.validPayloadLength(4096, 4096))
        assertFalse(TerminalFramePolicy.validPayloadLength(4097, 4096))
        assertTrue(TerminalFramePolicy.validPayloadLength(98_304, 98_304))
        for (length in listOf(-1L, 0L, 4_294_967_295L, Long.MAX_VALUE)) {
            assertFalse(TerminalFramePolicy.validPayloadLength(length, 98_304))
        }
    }
}
