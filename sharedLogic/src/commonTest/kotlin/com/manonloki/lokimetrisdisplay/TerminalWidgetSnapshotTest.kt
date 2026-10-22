package com.manonloki.lokimetrisdisplay

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFails
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** 共享测试覆盖摘要裁剪、数值质量和启用名单，不依赖 Android 存储或网络。 */
class TerminalWidgetSnapshotTest {
    private val source = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    private fun full(enabled: List<String>? = null) = TerminalSnapshot(
        version = 1,
        tokens = TerminalTokens(
            TerminalDay("2026-10-22", "Asia/Shanghai", 100, 500), 300,
            TerminalAmount("18446744073709551615", "available", "partial", "derived"), emptyList(),
        ),
        tokenError = null,
        hooksAvailable = true,
        hooks = listOf(TerminalHook("codex", 1, "running", "private body", true, "a".repeat(64))),
        assets = listOf(TerminalAsset("a".repeat(64), "image/png", 1024)),
        catalogError = "private error",
        enabledAgents = enabled,
    )

    @Test
    fun summaryRemovesPrivateContentAndPreservesSourceAndNumericQuality() {
        val original = full()
        val value = TerminalWidgetSnapshot.fromLive(source, 1000, original)
        assertEquals(source, value.sourceId)
        assertEquals(1000L, value.receivedAtMs)
        assertEquals(original.tokens, value.snapshot.tokens)
        assertEquals("部分 · 估算", value.snapshot.tokens?.all?.quality)
        assertEquals("", value.snapshot.hooks.single().content)
        assertFalse(value.snapshot.hooks.single().contentTruncated)
        assertNull(value.snapshot.hooks.single().image)
        assertTrue(value.snapshot.assets.isEmpty())
        assertNull(value.snapshot.catalogError)
        assertEquals("private body", original.hooks.single().content)
        assertEquals(1, original.assets.size)
    }

    @Test
    fun explicitEnabledListIsCopiedAndEmptyListKeepsAllRowsHidden() {
        val enabled = mutableListOf("codex", "cursor")
        val value = TerminalWidgetSnapshot.fromLive(source, 1000, full(enabled))
        enabled.clear()
        assertEquals(listOf("codex", "cursor"), value.snapshot.enabledAgents)
        assertEquals(listOf("Cursor"), value.snapshot.displayUsageRows.map { it.displayName })
        val hidden = TerminalWidgetSnapshot.fromLive(source, 1000, full(emptyList())).snapshot
        assertTrue(hidden.displayUsageRows.isEmpty())
        assertEquals("18446744073709551615", hidden.displayTokens?.all?.total)
    }

    @Test
    fun invalidMetadataAndUnredactedSnapshotsCannotEnterSummaryStorage() {
        assertFails { TerminalWidgetSnapshot(source, 1000, full()).validate() }
        assertFails { TerminalWidgetSnapshot.fromLive(source.uppercase(), 1000, full()) }
        assertFails { TerminalWidgetSnapshot.fromLive(source, -1, full()) }
        assertFails { TerminalWidgetSnapshot.fromLive(source, 1000, full().copy(version = 2)) }
    }
}
