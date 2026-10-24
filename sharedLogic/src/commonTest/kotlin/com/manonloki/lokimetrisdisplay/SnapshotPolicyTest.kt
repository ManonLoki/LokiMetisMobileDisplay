package com.manonloki.lokimetrisdisplay

import com.manonloki.lokimetrisdisplay.storage.SnapshotAcceptancePolicy
import com.manonloki.lokimetrisdisplay.storage.SnapshotFreshnessPolicy
import com.manonloki.lokimetrisdisplay.storage.SnapshotStamp
import kotlin.test.*

/** 时间和来源接纳规则使用固定时刻，分别验证认证推送、迟到 HTTP 和租约过期。 */
class SnapshotPolicyTest {
    private val first = SnapshotStamp("first", 100)
    @Test fun authenticatedSwitchesSourceButHeartbeatAndHttpCannot() {
        val switched = SnapshotStamp("second", 50)
        assertTrue(SnapshotAcceptancePolicy.acceptAuthenticated(first, switched))
        assertFalse(SnapshotAcceptancePolicy.acceptSameSource(first, switched))
        assertFalse(SnapshotAcceptancePolicy.acceptFetched(first, switched, true, "second", 100))
        assertTrue(SnapshotAcceptancePolicy.acceptSameSource(null, first))
    }
    @Test fun equalTimeIsAllowedAndLateRequestsCannotOverwriteNewerWork() {
        assertTrue(SnapshotAcceptancePolicy.acceptFetched(first, first, true, "first", 100))
        assertFalse(SnapshotAcceptancePolicy.acceptFetched(first, first.copy(receivedAtMs = 101), true, "first", 99))
        assertFalse(SnapshotAcceptancePolicy.acceptFetched(first, first, false, "first", 100))
        assertFalse(SnapshotAcceptancePolicy.acceptSameSource(first, first.copy(receivedAtMs = 99)))
        assertTrue(SnapshotAcceptancePolicy.acceptFetched(null, first, true, "first", 0))
    }
    @Test fun completeDisplayWinsAtSameTimeButTimeAndSourceRemainPrimary() {
        assertFalse(SnapshotAcceptancePolicy.acceptDisplay(first, 2, first, 1))
        assertTrue(SnapshotAcceptancePolicy.acceptDisplay(first, 2, first.copy(receivedAtMs = 101), 0))
        assertTrue(SnapshotAcceptancePolicy.acceptDisplay(first, 2, SnapshotStamp("second", 50), 0))
    }
    @Test fun leaseExpiresWithoutDeletingCachedContentOrAllowingRevival() {
        assertTrue(SnapshotFreshnessPolicy.isLive(100, 45_100, 45_099))
        assertFalse(SnapshotFreshnessPolicy.isLive(100, 45_100, 45_100))
        assertTrue(SnapshotFreshnessPolicy.isCached(100, 45_100, 100_000))
        assertNull(SnapshotFreshnessPolicy.renewedDeadline(100, 45_100, 45_100))
        assertEquals(45_200L, SnapshotFreshnessPolicy.renewedDeadline(100, 45_100, 200))
        assertFalse(SnapshotFreshnessPolicy.isCached(100, 45_101, 100))
        assertFalse(SnapshotFreshnessPolicy.isCached(100, 45_100, 99))
        assertFalse(SnapshotFreshnessPolicy.validLease(Long.MAX_VALUE, Long.MAX_VALUE))
        val lastSafe = Long.MAX_VALUE - SnapshotFreshnessPolicy.LEASE_MS
        assertEquals(Long.MAX_VALUE, SnapshotFreshnessPolicy.renewedDeadline(lastSafe, Long.MAX_VALUE, lastSafe))
        assertNull(SnapshotFreshnessPolicy.renewedDeadline(lastSafe, Long.MAX_VALUE, lastSafe + 1))
        assertFalse(SnapshotFreshnessPolicy.isCached(0, 45_000, Long.MIN_VALUE))
    }
    @Test fun futureOrMissingTimeRefreshesAndEachPlatformKeepsItsOwnInterval() {
        assertTrue(SnapshotFreshnessPolicy.shouldRefresh(-1, 100, 300_000))
        assertTrue(SnapshotFreshnessPolicy.shouldRefresh(101, 100, 300_000))
        assertFalse(SnapshotFreshnessPolicy.shouldRefresh(100, 300_099, 300_000))
        assertTrue(SnapshotFreshnessPolicy.shouldRefresh(100, 300_100, 300_000))
        assertFalse(SnapshotFreshnessPolicy.shouldRefresh(100, 300_100, 900_000))
    }
}
