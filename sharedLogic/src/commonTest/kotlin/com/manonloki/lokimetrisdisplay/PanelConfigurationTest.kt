package com.manonloki.lokimetrisdisplay

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse

class PanelConfigurationTest {
    @Test
    fun swiftDefaultsMatchTheSharedRestorationDefaults() {
        assertEquals(PanelConfiguration.restore(), PanelConfiguration.defaults())
    }

    @Test
    fun restoresIndependentCardVisibilityAndDisplayOptions() {
        val restored = PanelConfiguration.restore(false, false, "detailed", "2x2")
        assertFalse(restored.showUsage)
        assertFalse(restored.showHooks)
        assertEquals(UsageDetail.DETAILED, restored.usageDetail)
        assertEquals(HookLayout.GRID, restored.hookLayout)
        assertEquals(2, restored.hookLayout.columns)
        assertEquals(4, restored.hookLayout.pageSize)
    }

    @Test
    fun unknownSavedOptionsFallBackWithoutChangingCardVisibility() {
        assertEquals(PanelConfiguration(showHooks = false), PanelConfiguration.restore(showHooks = false, detail = "invalid", hookLayout = "3x3"))
        assertEquals(PanelConfiguration(), PanelConfiguration.restore())
    }

    @Test
    fun hookLayoutRoundTripsIndependentlyFromUsageOptions() {
        for (hookLayout in HookLayout.entries) {
            val saved = PanelConfiguration(showUsage = false, usageDetail = UsageDetail.DETAILED, hookLayout = hookLayout)
            assertEquals(saved, PanelConfiguration.restore(
                showUsage = saved.showUsage,
                showHooks = saved.showHooks,
                detail = saved.usageDetail.key,
                hookLayout = saved.hookLayout.key,
            ))
        }
    }

    @Test
    fun invalidHookLayoutPreservesOtherSavedOptions() {
        assertEquals(
            PanelConfiguration(showUsage = false, usageDetail = UsageDetail.DETAILED),
            PanelConfiguration.restore(showUsage = false, detail = "detailed", hookLayout = "GRID"),
        )
    }

    @Test
    fun singleLayoutCreatesOneHookPerPageInSourceOrder() {
        assertEquals(listOf(listOf("one"), listOf("two"), listOf("three")),
            HookLayout.SINGLE.pages(listOf("one", "two", "three")))
    }

    @Test
    fun gridLayoutPreservesSourceOrderAndPadsOnlyLastPage() {
        assertEquals(listOf(listOf(1, 2, 3, 4), listOf(5, 6, null, null)),
            HookLayout.GRID.pages((1..6).toList()))
        assertEquals(listOf(listOf(1, 2, 3, 4), listOf(5, 6, 7, 8)),
            HookLayout.GRID.pages((1..8).toList()))
    }

    @Test
    fun emptyHooksCreateOneFullPlaceholderPage() {
        for (layout in HookLayout.entries) {
            assertEquals(listOf(List<Int?>(layout.pageSize) { null }), layout.pages(emptyList<Int>()))
        }
    }

    @Test
    fun pagesCoverHookCountBoundariesWithoutLosingItems() {
        for (layout in HookLayout.entries) {
            for (count in listOf(0, 1, 3, 4, 5, 12)) {
                val hooks = (1..count).toList()
                val pages = layout.pages(hooks)
                val expectedPageCount = maxOf(1, (count + layout.pageSize - 1) / layout.pageSize)
                assertEquals(expectedPageCount, pages.size, "${layout.key}: $count Hooks")
                for (page in pages) assertEquals(layout.pageSize, page.size)
                assertEquals(hooks, pages.flatten().filterNotNull())
                assertEquals(List(expectedPageCount * layout.pageSize - count) { null },
                    pages.flatten().drop(count))
            }
        }
    }

    @Test
    fun nativePageQueriesKeepSourceOrderAndReturnSentinelForPaddedCells() {
        assertEquals(1, HookLayout.GRID.pageCount(0))
        assertEquals(listOf(-1, -1, -1, -1), (0..3).map { HookLayout.GRID.itemIndex(0, 0, it) })
        assertEquals(2, HookLayout.GRID.pageCount(5))
        assertEquals(listOf(0, 1, 2, 3), (0..3).map { HookLayout.GRID.itemIndex(5, 0, it) })
        assertEquals(listOf(4, -1, -1, -1), (0..3).map { HookLayout.GRID.itemIndex(5, 1, it) })
        assertEquals(5, HookLayout.SINGLE.pageCount(5))
        assertEquals(4, HookLayout.SINGLE.itemIndex(5, 4, 0))
    }

    @Test
    fun nativePageQueriesHandleInvalidAndMaximumInputsWithoutThrowing() {
        for (layout in HookLayout.entries) {
            assertEquals(1, layout.pageCount(-1))
            assertEquals(-1, layout.itemIndex(-1, 0, 0))
            assertEquals(-1, layout.itemIndex(12, -1, 0))
            assertEquals(-1, layout.itemIndex(12, layout.pageCount(12), 0))
            assertEquals(-1, layout.itemIndex(12, 0, -1))
            assertEquals(-1, layout.itemIndex(12, 0, layout.pageSize))
            assertEquals(-1, layout.itemIndex(12, Int.MAX_VALUE, Int.MAX_VALUE))
        }
        assertEquals(Int.MAX_VALUE, HookLayout.SINGLE.pageCount(Int.MAX_VALUE))
        assertEquals(Int.MAX_VALUE - 1, HookLayout.SINGLE.itemIndex(Int.MAX_VALUE, Int.MAX_VALUE - 1, 0))
        assertEquals(536_870_912, HookLayout.GRID.pageCount(Int.MAX_VALUE))
        assertEquals(Int.MAX_VALUE - 1, HookLayout.GRID.itemIndex(Int.MAX_VALUE, 536_870_911, 2))
        assertEquals(-1, HookLayout.GRID.itemIndex(Int.MAX_VALUE, 536_870_911, 3))
    }
}
