package com.manonloki.lokimetrisdisplay

import kotlin.test.*

/** 桌面额度与Token无关，窗口独立缺省，严格拒绝坏值和无序/重复提供商。 */
class ProviderQuotaTest {
    private fun weekly(used: Int = 970) = ProviderQuotaEntry("codex", "pro", null, ProviderQuotaWindow("weekly", used, 1900000000))
    @Test fun weekly_only_keeps_progress_and_zero_balance() {
        val quota = ProviderQuotaSnapshot(123, listOf(weekly()))
        quota.validate(); assertNull(quota.providers.single().fiveHour)
        assertEquals("3%", quota.providers.single().weekly?.percentText)
        ProviderQuotaSnapshot(123, listOf(weekly(1000))).validate()
        assertEquals("0%", weekly(1000).weekly?.percentText)
    }
    @Test fun invalid_values_duplicates_and_private_plan_are_rejected() {
        for (values in listOf(listOf(weekly(1001)), listOf(weekly(), weekly()), listOf(weekly().copy(plan = "user@example.com")),
            listOf(weekly().copy(provider = "workbuddy")), listOf(weekly().copy(weekly = ProviderQuotaWindow("fiveHour", 50, null))))) {
            assertFailsWith<IllegalArgumentException> { ProviderQuotaSnapshot(123, values).validate() }
        }
        ProviderQuotaSnapshot(123, emptyList()).validate()
    }
    @Test fun claude_and_cursor_monthly_follow_catalog_order_and_labels() {
        val claude = ProviderQuotaEntry("claude", null, ProviderQuotaWindow("fiveHour", 300, null), ProviderQuotaWindow("weekly", 50, 1900000000))
        val cursor = ProviderQuotaEntry("cursor", "pro", null, null, ProviderQuotaWindow("monthly", 250, 1900000000))
        val grok = ProviderQuotaEntry("grok", null, null, ProviderQuotaWindow("weekly", 0, null))
        ProviderQuotaSnapshot(123, listOf(weekly(), claude, cursor, grok)).validate()
        assertFailsWith<IllegalArgumentException> { ProviderQuotaSnapshot(123, listOf(cursor, claude)).validate() }
        assertFailsWith<IllegalArgumentException> { ProviderQuotaSnapshot(123, listOf(cursor.copy(monthly = ProviderQuotaWindow("weekly", 1, null)))).validate() }
        assertEquals("Claude", claude.label)
        assertEquals(listOf("每周", "5h"), claude.windows.map { it.kindLabel })
        assertEquals(listOf("每月 75%"), cursor.windows.map { "${it.kindLabel} ${it.percentText}" })
        assertEquals("claude", UsageDisplayPolicy.providerQuotaKey("claude-code"))
        assertEquals("claude", UsageDisplayPolicy.providerQuotaKey("Claude Code"))
    }
    @Test fun remaining_color_thresholds_and_disconnect_clear_quota() {
        for ((remaining, level) in listOf(0 to 0, 200 to 0, 201 to 1, 500 to 1, 501 to 2, 1000 to 2)) {
            assertEquals(level, ProviderQuotaWindow("weekly", 1000 - remaining, null).level)
        }
        val snapshot = TerminalSnapshot(1, null, null, false, emptyList(), emptyList(), null, ProviderQuotaSnapshot(123, listOf(weekly())))
        val live = TerminalLinkView("id", "name", connected = true, snapshot = snapshot)
        assertNull(live.withoutLiveDisplay().snapshot)
        assertFalse(live.withoutLiveDisplay().connected)
    }
}
