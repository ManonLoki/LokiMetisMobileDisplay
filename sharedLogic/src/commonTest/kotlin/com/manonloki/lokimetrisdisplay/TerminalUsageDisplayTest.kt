package com.manonloki.lokimetrisdisplay

import kotlin.test.*

/** 面板排序同时覆盖Token与独立额度，保持统计值和线协议次序不变。 */
class TerminalUsageDisplayTest {
    private val amount = TerminalAmount("12345", "available", "complete", "exact")
    private fun tokens(vararg names: String) = TerminalTokens(
        TerminalDay("2026-10-22", "Asia/Shanghai", 1, 10), 9, amount,
        names.map { TerminalAgent(it, amount) },
    )
    private fun quota(provider: String) = ProviderQuotaEntry(
        provider, null, null,
        if (provider == "cursor") null else ProviderQuotaWindow("weekly", 250, null),
        if (provider == "cursor") ProviderQuotaWindow("monthly", 500, null) else null,
    )
    private fun snapshot(tokens: TerminalTokens?, vararg providers: String) = TerminalSnapshot(
        1, tokens, null, false, emptyList(), emptyList(), null,
        ProviderQuotaSnapshot(123, providers.map(::quota)),
    )

    @Test fun display_agents_prioritize_cursor_and_keep_other_agents_stable() {
        val tokens = tokens("Work_Buddy", "Hermes", "Grok Build", "OpenCode", "Cursor", "Claude-Code", "codex")
        val original = tokens.agents.toList()

        assertEquals(listOf("codex", "Claude-Code", "Cursor", "Grok Build", "Hermes", "OpenCode", "Work_Buddy"),
            tokens.displayAgents.map { it.agent })
        assertEquals(original, tokens.agents)
        assertSame(amount, tokens.all)
        tokens.displayAgents.forEach { assertSame(amount, it.amount) }
    }

    @Test fun cursor_with_quota_only_appears_before_grok_and_workbuddy_without_fabricating_tokens() {
        val snapshot = snapshot(tokens("WorkBuddy", "Hermes", "grok", "OpenCode", "Claude Code", "codex"),
            "codex", "claude", "cursor", "grok")
        snapshot.validate()

        val rows = snapshot.displayUsageRows
        assertEquals(listOf("Codex", "Claude Code", "Cursor", "Grok", "Hermes", "OpenCode", "WorkBuddy"),
            rows.map { it.displayName })
        val cursor = rows[2]
        assertNull(cursor.tokenAgent)
        assertEquals("0", cursor.tokenText)
        assertEquals("50%", cursor.quota?.monthly?.percentText)
        assertEquals(6, snapshot.tokens?.agents?.size)
        assertNull(snapshot.tokens?.agents?.firstOrNull { it.agent == "cursor" })
        assertEquals("12345", rows.last().tokenAgent?.amount?.total)
    }

    @Test fun matching_quota_stays_with_its_token_row_and_missing_cursor_displays_zero() {
        val snapshot = snapshot(tokens("WorkBuddy", "Claude-Code", "codex"), "claude")
        snapshot.validate()

        val rows = snapshot.displayUsageRows
        assertEquals(listOf("Codex", "Claude Code", "Cursor", "WorkBuddy"), rows.map { it.displayName })
        assertSame(snapshot.providerQuota?.providers?.single(), rows[1].quota)
        assertSame(snapshot.tokens?.agents?.get(1), rows[1].tokenAgent)
        assertEquals(1, rows.count { it.quota != null })
        assertNull(rows[2].tokenAgent)
        assertNull(rows[2].quota)
        assertEquals("0", rows[2].tokenText)
        assertEquals(listOf("WorkBuddy", "Claude-Code", "codex"), snapshot.tokens?.agents?.map { it.agent })
        assertSame(amount, snapshot.tokens?.all)
    }

    @Test fun quota_rows_survive_when_no_token_snapshot_is_available() {
        val snapshot = snapshot(null, "codex", "claude", "cursor", "grok")
        snapshot.validate()

        assertEquals(listOf("Codex", "Claude", "Cursor", "Grok"), snapshot.displayUsageRows.map { it.displayName })
        assertTrue(snapshot.displayUsageRows.all { it.tokenAgent == null && it.quota != null })
        assertNull(snapshot.tokens)
    }

    @Test fun cursor_missing_amount_displays_zero_without_changing_source_availability() {
        for (availability in listOf("noRecords", "unavailable")) {
            val amount = TerminalAmount(null, availability, "unknown", "exact")
            val row = TerminalUsageRow(TerminalAgent("Cursor", amount), null)
            assertEquals("0", row.tokenText)
            assertSame(amount, row.tokenAgent?.amount)
            assertNull(row.tokenAgent?.amount?.total)
            assertEquals(availability, row.tokenAgent?.amount?.availability)
        }
    }

    @Test fun cursor_real_zero_and_usage_are_retained_without_duplicate_fallback() {
        for (total in listOf("0", "12345")) {
            val amount = TerminalAmount(total, "available", "complete", "exact")
            val tokens = tokens("CUR-SOR", "workbuddy").copy(agents = listOf(TerminalAgent("CUR-SOR", amount)))
            val rows = snapshot(tokens).displayUsageRows
            assertEquals(1, rows.size)
            assertEquals(total, rows.single().tokenText)
        }
    }

    @Test fun missing_tokens_do_not_add_default_cursor_to_unsynced_snapshot() {
        assertTrue(snapshot(null).displayUsageRows.isEmpty())
    }
}
