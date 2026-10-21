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
        assertEquals("50%", cursor.quota?.monthly?.percentText)
        assertEquals(6, snapshot.tokens?.agents?.size)
        assertNull(snapshot.tokens?.agents?.firstOrNull { it.agent == "cursor" })
        assertEquals("12345", rows.last().tokenAgent?.amount?.total)
    }

    @Test fun matching_quota_stays_with_its_token_row_and_missing_accounts_are_not_added() {
        val snapshot = snapshot(tokens("WorkBuddy", "Claude-Code", "codex"), "claude")
        snapshot.validate()

        val rows = snapshot.displayUsageRows
        assertEquals(listOf("Codex", "Claude Code", "WorkBuddy"), rows.map { it.displayName })
        assertSame(snapshot.providerQuota?.providers?.single(), rows[1].quota)
        assertSame(snapshot.tokens?.agents?.get(1), rows[1].tokenAgent)
        assertEquals(1, rows.count { it.quota != null })
    }

    @Test fun quota_rows_survive_when_no_token_snapshot_is_available() {
        val snapshot = snapshot(null, "codex", "claude", "cursor", "grok")
        snapshot.validate()

        assertEquals(listOf("Codex", "Claude", "Cursor", "Grok"), snapshot.displayUsageRows.map { it.displayName })
        assertTrue(snapshot.displayUsageRows.all { it.tokenAgent == null && it.quota != null })
        assertNull(snapshot.tokens)
    }
}
