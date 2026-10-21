package com.manonloki.lokimetrisdisplay

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse

class PanelConfigurationTest {
    @Test
    fun restoresIndependentCardVisibilityAndDisplayOptions() {
        val restored = PanelConfiguration.restore(false, false, "detailed", "2x2", "2x2")
        assertFalse(restored.showUsage)
        assertFalse(restored.showHooks)
        assertEquals(UsageDetail.DETAILED, restored.usageDetail)
        assertEquals(UsageCardSize.LARGE, restored.usageSize)
        assertEquals(2, restored.usageSize.columns)
        assertEquals(HookLayout.GRID, restored.hookLayout)
        assertEquals(2, restored.hookLayout.columns)
        assertEquals(4, restored.hookLayout.pageSize)
    }

    @Test
    fun unknownSavedOptionsFallBackWithoutChangingCardVisibility() {
        assertEquals(PanelConfiguration(showHooks = false), PanelConfiguration.restore(showHooks = false, detail = "invalid", size = "3x3", hookLayout = "3x3"))
        assertEquals(PanelConfiguration(), PanelConfiguration.restore())
    }

    @Test
    fun oldSavedUsageSizeDoesNotChooseHookLayout() {
        val restored = PanelConfiguration.restore(size = "2x2")
        assertEquals(UsageCardSize.LARGE, restored.usageSize)
        assertEquals(HookLayout.SINGLE, restored.hookLayout)
        assertEquals(1, restored.hookLayout.columns)
        assertEquals(1, restored.hookLayout.pageSize)
    }

    @Test
    fun hookLayoutRoundTripsIndependentlyFromUsageOptions() {
        for (usageSize in UsageCardSize.entries) {
            for (hookLayout in HookLayout.entries) {
                val saved = PanelConfiguration(
                    showUsage = false,
                    usageDetail = UsageDetail.DETAILED,
                    usageSize = usageSize,
                    hookLayout = hookLayout,
                )
                assertEquals(saved, PanelConfiguration.restore(
                    showUsage = saved.showUsage,
                    showHooks = saved.showHooks,
                    detail = saved.usageDetail.key,
                    size = saved.usageSize.key,
                    hookLayout = saved.hookLayout.key,
                ))
            }
        }
    }

    @Test
    fun invalidHookLayoutPreservesOtherSavedOptions() {
        assertEquals(
            PanelConfiguration(showUsage = false, usageDetail = UsageDetail.DETAILED, usageSize = UsageCardSize.LARGE),
            PanelConfiguration.restore(showUsage = false, detail = "detailed", size = "2x2", hookLayout = "GRID"),
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
}
