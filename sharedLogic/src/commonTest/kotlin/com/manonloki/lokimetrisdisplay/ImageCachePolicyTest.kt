package com.manonloki.lokimetrisdisplay

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class ImageCachePolicyTest {
    @Test fun candidatesPreserveReferencesAndExactLastUseOrdering() {
        val entries = listOf(ImageCacheEntry("new", 1, 1000.0002), ImageCacheEntry("protected", 1, 0.0),
            ImageCacheEntry("old", 1, 1000.0001), ImageCacheEntry("tie", 1, 1000.0002))
        val plan = ImageCachePolicy.plan(entries, setOf("protected"))
        assertEquals(listOf("old", "new", "tie"), plan.candidates.map { it.key })
        assertEquals(4, plan.occupancy.fileCount)
    }

    @Test fun onlyAndroidAndWatchEnforceFileCountAndExactBudgetIsAllowed() {
        val files = (0 until 513).map { ImageCacheEntry("$it", 0, it.toDouble()) }
        val plan = ImageCachePolicy.plan(files, emptySet())
        assertTrue(ImageCachePolicy.shouldEvict(plan.occupancy, ImageCacheProfile.ANDROID))
        assertTrue(ImageCachePolicy.shouldEvict(plan.occupancy, ImageCacheProfile.WATCH))
        assertFalse(ImageCachePolicy.shouldEvict(plan.occupancy, ImageCacheProfile.IPHONE))
        val next = ImageCachePolicy.removed(plan.occupancy, plan.candidates.first())
        assertFalse(ImageCachePolicy.shouldEvict(next, ImageCacheProfile.WATCH))
        val exact = ImageCachePolicy.plan(listOf(ImageCacheEntry("full", ImageCachePolicy.MAX_BYTES, 0.0)), emptySet())
        for (profile in ImageCacheProfile.entries) assertFalse(ImageCachePolicy.shouldEvict(exact.occupancy, profile))
    }

    @Test fun failedDeletionLeavesOccupancyUntilASuccessfulRemovalIsCommitted() {
        val plan = ImageCachePolicy.plan(listOf(ImageCacheEntry("old", 1, 0.0),
            ImageCacheEntry("current", ImageCachePolicy.MAX_BYTES, 1.0)), setOf("current"))
        val unchanged = plan.occupancy
        assertTrue(ImageCachePolicy.shouldEvict(unchanged, ImageCacheProfile.IPHONE))
        assertEquals(2, unchanged.fileCount)
        val removed = ImageCachePolicy.removed(unchanged, plan.candidates.single())
        assertFalse(ImageCachePolicy.shouldEvict(removed, ImageCacheProfile.IPHONE))
        assertEquals(1, removed.fileCount)
        assertTrue(ImageCachePolicy.shouldEvict(unchanged, ImageCacheProfile.IPHONE))
    }

    @Test fun protectedFilesRemainEvenWhenTheyAloneExceedBudget() {
        val plan = ImageCachePolicy.plan(listOf(ImageCacheEntry("current", ImageCachePolicy.MAX_BYTES + 1, 0.0)),
            setOf("current"))
        assertTrue(plan.candidates.isEmpty())
        assertTrue(ImageCachePolicy.shouldEvict(plan.occupancy, ImageCacheProfile.WATCH))
    }

    @Test fun byteTotalsRemainExactBeyondSignedAndUnsigned64BitBoundaries() {
        val entries = (0..2).map { ImageCacheEntry("$it", Long.MAX_VALUE, it.toDouble()) }
        var occupancy = ImageCachePolicy.plan(entries, emptySet()).occupancy
        for (entry in entries) {
            assertTrue(ImageCachePolicy.shouldEvict(occupancy, ImageCacheProfile.IPHONE))
            occupancy = ImageCachePolicy.removed(occupancy, entry)
        }
        assertFalse(ImageCachePolicy.shouldEvict(occupancy, ImageCacheProfile.IPHONE))
        assertEquals(0, occupancy.fileCount)
    }
}
